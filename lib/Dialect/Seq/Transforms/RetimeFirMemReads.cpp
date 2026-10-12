//===- RetimeFirMemReads.cpp - Registered addresses into memory reads -----===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// An asynchronous read whose address comes from registers is the same as a
// synchronous read of the address those registers are about to take, if the
// read sees the words written on the same edge. Folding the registers into the
// read makes the memory one a block RAM can hold.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/Seq/SeqOps.h"
#include "circt/Dialect/Seq/SeqPasses.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/IR/ImplicitLocOpBuilder.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"
#include "mlir/Pass/Pass.h"

namespace circt {
namespace seq {
#define GEN_PASS_DEF_RETIMEFIRMEMREADS
#include "circt/Dialect/Seq/SeqPasses.h.inc"
} // namespace seq
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace seq;

namespace {
struct RetimeFirMemReadsPass
    : public circt::seq::impl::RetimeFirMemReadsBase<RetimeFirMemReadsPass> {
  using RetimeFirMemReadsBase::RetimeFirMemReadsBase;
  void runOnOperation() override;
};
} // namespace

/// Whether `value` is computed only from constants and registers on `clock`
/// with no asynchronous reset, through logic without side effects.
static bool isFromRegisters(Value value, Value clock,
                            DenseMap<Value, bool> &cache) {
  if (auto it = cache.find(value); it != cache.end())
    return it->second;
  bool result = false;
  auto *op = value.getDefiningOp();
  if (auto reg = dyn_cast_or_null<FirRegOp>(op)) {
    result = reg.getClk() == clock && !reg.getIsAsync();
  } else if (op && op->getNumRegions() == 0 && isMemoryEffectFree(op) &&
             !isa<FirMemReadOp, FirMemReadWriteOp>(op)) {
    cache[value] = false;
    result = llvm::all_of(op->getOperands(), [&](Value operand) {
      return isFromRegisters(operand, clock, cache);
    });
  }
  return cache[value] = result;
}

/// The value `value` takes after the next edge: its logic on the registers'
/// next values, their synchronous resets applied.
static Value getNext(Value value, ImplicitLocOpBuilder &b,
                     DenseMap<Value, Value> &nexts) {
  if (auto it = nexts.find(value); it != nexts.end())
    return it->second;
  auto *op = value.getDefiningOp();
  Value result;
  if (auto reg = dyn_cast<FirRegOp>(op)) {
    result = reg.getNext();
    if (reg.hasReset())
      result = b.createOrFold<comb::MuxOp>(reg.getReset(), reg.getResetValue(),
                                           result);
  } else if (op->getNumOperands() == 0) {
    result = value;
  } else {
    IRMapping mapping;
    for (auto operand : op->getOperands())
      mapping.map(operand, getNext(operand, b, nexts));
    auto *clone = b.clone(*op, mapping);
    result = clone->getResult(cast<OpResult>(value).getResultNumber());
  }
  return nexts[value] = result;
}

void RetimeFirMemReadsPass::runOnOperation() {
  SmallVector<FirMemOp> memories;
  getOperation().walk([&](FirMemOp memory) {
    if (memory.getReadLatency() == 0 && memory.getWriteLatency() == 1)
      memories.push_back(memory);
  });

  for (auto memory : memories) {
    auto type = memory.getType();
    if (type.getDepth() * type.getWidth() < minBits)
      continue;
    SmallVector<FirMemReadOp> reads;
    SmallVector<FirMemWriteOp> writes;
    bool other = false;
    for (auto *user : memory->getUsers()) {
      if (auto read = dyn_cast<FirMemReadOp>(user))
        reads.push_back(read);
      else if (auto write = dyn_cast<FirMemWriteOp>(user))
        writes.push_back(write);
      else
        other = true;
    }
    if (other || reads.empty())
      continue;

    // The clock of the writes, or of a read address's registers if there are
    // no writes.
    Value clock;
    for (auto write : writes) {
      if (clock && write.getClk() != clock) {
        clock = {};
        break;
      }
      clock = write.getClk();
    }
    if (!clock && !writes.empty())
      continue;
    if (!clock)
      if (auto reg = reads[0].getAddress().getDefiningOp<FirRegOp>())
        clock = reg.getClk();
    if (!clock)
      continue;

    DenseMap<Value, bool> cache;
    if (!llvm::all_of(reads, [&](FirMemReadOp read) {
          return isFromRegisters(read.getAddress(), clock, cache);
        }))
      continue;

    // Each read reads the next address on the clock's edge.
    DenseMap<Value, Value> nexts;
    for (auto read : reads) {
      ImplicitLocOpBuilder b(read.getLoc(), read);
      auto address = getNext(read.getAddress(), b, nexts);
      auto retimed = FirMemReadOp::create(b, memory, address, clock, Value{});
      read.getData().replaceAllUsesWith(retimed.getData());
      read.erase();
    }
    memory.setReadLatency(1);
    memory.setRuw(RUW::New);
  }
}
