//===- RegOfVecToMem.cpp - Convert Register Arrays to Memories -----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This transformation pass converts register arrays that follow memory access
// patterns to seq.firmem operations.
//
// The next value of such a register is a chain of conditional writes of one
// element, all at the same address, and the register is otherwise only read
// one element at a time. A write may replace part of the element only: a
// memory with column write enables, coded as one conditional write per column,
// becomes a memory with a write mask.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/Seq/SeqOps.h"
#include "circt/Dialect/Seq/SeqPasses.h"
#include "mlir/Analysis/SliceAnalysis.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/IR/ImplicitLocOpBuilder.h"
#include "mlir/IR/Matchers.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SetVector.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/Debug.h"
#include <numeric>

#define DEBUG_TYPE "reg-of-vec-to-mem"

using namespace circt;
using namespace seq;
using namespace hw;

namespace circt {
namespace seq {
#define GEN_PASS_DEF_REGOFVECTOMEM
#include "circt/Dialect/Seq/SeqPasses.h.inc"
} // namespace seq
} // namespace circt

namespace {

/// A condition, as a conjunction of values that are true or false.
using Condition = SmallVector<std::pair<Value, bool>, 2>;

/// One conditional write of an element of the array.
struct ElementWrite {
  hw::ArrayInjectOp inject;
  Condition cond;
};

/// Where a bit of a written element comes from.
struct BitSource {
  enum Kind { Old, Const, Leaf } kind;
  /// For `Leaf`, the value the bit is taken from.
  Value leaf;
  /// For `Old`, the bit of the element; for `Leaf`, the bit of `leaf`; for
  /// `Const`, the bit's value.
  unsigned bit;

  bool operator==(const BitSource &other) const {
    return kind == other.kind && leaf == other.leaf && bit == other.bit;
  }
};
using BitSources = SmallVector<BitSource>;

/// The analysis of one register array.
class MemoryAnalysis {
public:
  explicit MemoryAnalysis(FirRegOp reg) : reg(reg) {}

  /// Whether the register is used as a memory; fills in the accessors below.
  bool analyze();

  /// Replace the register by a memory.
  void createFirMemory(SmallVectorImpl<Operation *> &opsToErase);

private:
  /// Collect the writes that make up `value`, a version of the array.
  FailureOr<ArrayRef<ElementWrite>> peelWrites(Value value);
  /// Where the bits of a value written by `write` come from.
  FailureOr<ArrayRef<BitSource>> getBitSources(Value value,
                                               hw::ArrayInjectOp inject);
  /// Whether `value` is computed from the array.
  bool dependsOnArray(Value value);
  Value materialize(ImplicitLocOpBuilder &builder, const Condition &cond);
  Value materializeBits(ImplicitLocOpBuilder &builder, unsigned writeIdx,
                        unsigned low, unsigned width);

  FirRegOp reg;
  uint64_t depth = 0, width = 0;
  Value writeAddr;
  SmallVector<ElementWrite> writes;
  /// Indexed by write, then by bit of the element.
  SmallVector<BitSources> writeBits;
  /// Reads of the array outside its write chain.
  SmallVector<hw::ArrayGetOp> reads;

  /// How each read becomes a port of the memory.
  struct ReadPort {
    hw::ArrayGetOp read;
    Value addr;
    Value enable;
    /// The register the read data is registered in, if the memory takes it.
    FirRegOp dataReg;
  };
  SmallVector<ReadPort> ports;
  unsigned readLatency = 0;
  seq::RUW readUnderWrite = seq::RUW::Undefined;
  void planReadPorts();
  /// Reads of the element being written, inside the write chain.
  SmallPtrSet<Operation *, 8> elementReads;
  /// The ops that assemble written elements from it.
  SmallPtrSet<Operation *, 16> elementOps;

  DenseMap<Value, SmallVector<ElementWrite>> peeled;
  DenseMap<Value, BitSources> sources;
  DenseMap<Value, bool> dependsCache;
  SmallPtrSet<Value, 8> versions;
};

class RegOfVecToMemPass : public impl::RegOfVecToMemBase<RegOfVecToMemPass> {
public:
  void runOnOperation() override;
};

} // end anonymous namespace

FailureOr<ArrayRef<ElementWrite>> MemoryAnalysis::peelWrites(Value value) {
  if (auto it = peeled.find(value); it != peeled.end())
    return ArrayRef<ElementWrite>(it->second);

  SmallVector<ElementWrite> result;
  if (value == reg.getResult()) {
    // The array as the register holds it: no writes yet.
  } else if (auto inject = value.getDefiningOp<hw::ArrayInjectOp>()) {
    auto prefix = peelWrites(inject.getInput());
    if (failed(prefix))
      return failure();
    result.append(prefix->begin(), prefix->end());
    result.push_back({inject, {}});
  } else if (auto mux = value.getDefiningOp<comb::MuxOp>()) {
    auto onTrue = peelWrites(mux.getTrueValue());
    if (failed(onTrue))
      return failure();
    SmallVector<ElementWrite> trueWrites(onTrue->begin(), onTrue->end());
    auto onFalse = peelWrites(mux.getFalseValue());
    if (failed(onFalse))
      return failure();
    // Both arms extend a common sequence of writes; the rest of each arm only
    // happens under its side of the condition.
    unsigned common = 0;
    while (common < trueWrites.size() && common < onFalse->size() &&
           trueWrites[common].inject == (*onFalse)[common].inject &&
           trueWrites[common].cond == (*onFalse)[common].cond)
      ++common;
    result.append(trueWrites.begin(), trueWrites.begin() + common);
    for (auto write : ArrayRef(trueWrites).drop_front(common)) {
      write.cond.push_back({mux.getCond(), true});
      result.push_back(write);
    }
    for (auto write : onFalse->drop_front(common)) {
      write.cond.push_back({mux.getCond(), false});
      result.push_back(write);
    }
  } else {
    return failure();
  }

  versions.insert(value);
  return ArrayRef<ElementWrite>(peeled[value] = std::move(result));
}

bool MemoryAnalysis::dependsOnArray(Value value) {
  if (value == reg.getResult() || versions.contains(value))
    return true;
  if (auto it = dependsCache.find(value); it != dependsCache.end())
    return it->second;
  auto *op = value.getDefiningOp();
  // Registers and other ops with regions break the combinational path.
  bool result = false;
  if (op && op->getNumRegions() == 0 && !isa<FirRegOp, CompRegOp>(op)) {
    dependsCache[value] = false;
    result = llvm::any_of(op->getOperands(), [&](Value operand) {
      return dependsOnArray(operand);
    });
  }
  return dependsCache[value] = result;
}

FailureOr<ArrayRef<BitSource>>
MemoryAnalysis::getBitSources(Value value, hw::ArrayInjectOp inject) {
  if (auto it = sources.find(value); it != sources.end())
    return ArrayRef<BitSource>(it->second);
  auto type = dyn_cast<IntegerType>(value.getType());
  if (!type)
    return failure();
  unsigned bits = type.getWidth();

  BitSources result;
  auto *op = value.getDefiningOp();
  if (op && dependsOnArray(value))
    elementOps.insert(op);
  APInt constant;
  if (matchPattern(value, mlir::m_ConstantInt(&constant))) {
    for (unsigned i = 0; i < bits; ++i)
      result.push_back({BitSource::Const, {}, constant[i]});
  } else if (auto get = dyn_cast_or_null<hw::ArrayGetOp>(op);
             get && dependsOnArray(value)) {
    // The element as the previous writes left it.
    if (get.getInput() != inject.getInput() || get.getIndex() != writeAddr) {
      LLVM_DEBUG(llvm::dbgs() << "  Read of another element: " << get << "\n");
      return failure();
    }
    elementReads.insert(get);
    for (unsigned i = 0; i < bits; ++i)
      result.push_back({BitSource::Old, {}, i});
  } else if (auto extract = dyn_cast_or_null<comb::ExtractOp>(op)) {
    auto input = getBitSources(extract.getInput(), inject);
    if (failed(input))
      return failure();
    auto low = extract.getLowBit();
    result.append(input->begin() + low, input->begin() + low + bits);
  } else if (auto concat = dyn_cast_or_null<comb::ConcatOp>(op)) {
    // Operands are listed from the most significant one.
    for (auto operand : llvm::reverse(concat.getInputs())) {
      auto input = getBitSources(operand, inject);
      if (failed(input))
        return failure();
      result.append(input->begin(), input->end());
    }
  } else if (isa_and_nonnull<comb::OrOp, comb::AndOp>(op)) {
    // Masking, and merging masked parts: per bit, all operands but one must
    // be the neutral constant of the operation.
    bool isOr = isa<comb::OrOp>(op);
    // Copies: computing an operand's sources may rehash the cache.
    SmallVector<BitSources> inputs;
    for (auto operand : op->getOperands()) {
      auto input = getBitSources(operand, inject);
      if (failed(input))
        return failure();
      inputs.emplace_back(input->begin(), input->end());
    }
    for (unsigned i = 0; i < bits; ++i) {
      std::optional<BitSource> bit;
      bool absorbed = false, combined = false;
      for (auto &input : inputs) {
        auto source = input[i];
        if (source.kind == BitSource::Const) {
          absorbed |= source.bit == unsigned(isOr);
          continue;
        }
        combined |= bit && !(*bit == source);
        bit = source;
      }
      if (absorbed || !bit) {
        result.push_back(
            {BitSource::Const, {}, unsigned(absorbed ? isOr : !isOr)});
      } else if (!combined) {
        result.push_back(*bit);
      } else if (!dependsOnArray(value)) {
        // Bits combined from values independent of the array are a value of
        // their own.
        result.push_back({BitSource::Leaf, value, i});
      } else {
        LLVM_DEBUG(llvm::dbgs()
                   << "  Bit " << i << " of " << value << " has two sources\n");
        return failure();
      }
    }
  } else if (!dependsOnArray(value)) {
    for (unsigned i = 0; i < bits; ++i)
      result.push_back({BitSource::Leaf, value, i});
  } else {
    return failure();
  }

  // A bit of the element may only stay in place.
  for (auto [i, source] : llvm::enumerate(result))
    if (source.kind == BitSource::Old && value == inject.getElement() &&
        source.bit != i)
      return failure();
  return ArrayRef<BitSource>(sources[value] = std::move(result));
}

bool MemoryAnalysis::analyze() {
  LLVM_DEBUG(llvm::dbgs() << "Analyzing register: " << reg << "\n");
  auto arrayType = dyn_cast<hw::ArrayType>(reg.getType());
  if (!arrayType || !isa<IntegerType>(arrayType.getElementType()))
    return false;
  depth = arrayType.getNumElements();
  width = cast<IntegerType>(arrayType.getElementType()).getWidth();
  if (width == 0)
    return false;

  auto peeledWrites = peelWrites(reg.getNext());
  if (failed(peeledWrites) || peeledWrites->empty()) {
    LLVM_DEBUG(llvm::dbgs() << "  Next value is not a chain of writes\n");
    return false;
  }
  writes.assign(peeledWrites->begin(), peeledWrites->end());

  writeAddr = writes.front().inject.getIndex();
  for (auto &write : writes) {
    if (write.inject.getIndex() != writeAddr) {
      LLVM_DEBUG(llvm::dbgs() << "  Writes to more than one address\n");
      return false;
    }
    if (dependsOnArray(writeAddr) || llvm::any_of(write.cond, [&](auto term) {
          return dependsOnArray(term.first);
        })) {
      LLVM_DEBUG(llvm::dbgs() << "  Write address or enable read the array\n");
      return false;
    }
    // The element is assembled from the bits of the element as the previous
    // writes left it, and from values independent of the array.
    auto element = write.inject.getElement();
    if (!isa<IntegerType>(element.getType()))
      return false;
    sources.clear();
    auto bits = getBitSources(element, write.inject);
    if (failed(bits)) {
      LLVM_DEBUG(llvm::dbgs()
                 << "  Cannot follow the bits of " << element << "\n");
      return false;
    }
    writeBits.emplace_back(bits->begin(), bits->end());
  }

  // Every other use of the register must be a read of one element. A read of
  // the element being written may also be a read port: a single-port RAM
  // reads and writes at one address.
  auto inWriteChain = [&](Operation *op) {
    return elementOps.contains(op) ||
           (op->getNumResults() == 1 && versions.count(op->getResult(0)));
  };
  for (auto *user : reg.getResult().getUsers()) {
    if (elementReads.contains(user)
            ? llvm::all_of(user->getUsers(), inWriteChain)
            : inWriteChain(user))
      continue;
    auto get = dyn_cast<hw::ArrayGetOp>(user);
    if (!get) {
      LLVM_DEBUG(llvm::dbgs() << "  Array used by " << *user << "\n");
      return false;
    }
    reads.push_back(get);
  }
  if (reads.empty()) {
    LLVM_DEBUG(llvm::dbgs() << "  Array never read\n");
    return false;
  }

  // Nothing but the register itself may observe the write chain.
  SetVector<Operation *> chain;
  mlir::ForwardSliceOptions options;
  // The filter also applies to the root, the register.
  options.filter = [&](Operation *op) {
    return op == reg || !llvm::is_contained(reads, op);
  };
  getForwardSlice(reg.getOperation(), &chain, options);
  chain.remove(reg);
  for (auto *op : chain)
    for (auto *user : op->getUsers())
      if (user != reg && !chain.contains(user)) {
        LLVM_DEBUG(llvm::dbgs()
                   << "  Write chain observed by " << *user << "\n");
        return false;
      }
  planReadPorts();
  return true;
}

/// Whether a register is a plain pipeline register on the memory's clock.
static bool isPlainRegister(FirRegOp reg, Value clock) {
  return reg && reg.getClk() == clock && !reg.getReset() && !reg.getPreset();
}

/// The enable of a register whose next value is `value` when enabled and
/// which holds otherwise; null if it does not hold.
static Value getHoldEnable(FirRegOp reg, Value value) {
  if (reg.getNext() == value)
    return {};
  auto mux = reg.getNext().getDefiningOp<comb::MuxOp>();
  if (mux && mux.getTrueValue() == value &&
      mux.getFalseValue() == reg.getResult())
    return mux.getCond();
  return {};
}

void MemoryAnalysis::planReadPorts() {
  auto clock = reg.getClk();
  // A block RAM registers either the read data or the read address. A memory
  // takes the register in only if every read registers the same way, since
  // the read latency and read-under-write behaviour are the memory's.
  SmallVector<ReadPort> dataPorts, addrPorts, asyncPorts;
  for (auto read : reads) {
    asyncPorts.push_back({read, read.getIndex(), {}, {}});

    // Read-first: the data read is registered. A single-port RAM's read is
    // also the element its writes start from.
    SmallVector<Operation *> dataUsers;
    for (auto *user : read->getUsers())
      if (!elementOps.contains(user))
        dataUsers.push_back(user);
    if (dataUsers.size() == 1) {
      auto *user = dataUsers.front();
      auto dataReg = dyn_cast<FirRegOp>(user);
      if (!dataReg)
        if (auto mux = dyn_cast<comb::MuxOp>(user); mux && mux->hasOneUse())
          dataReg = dyn_cast<FirRegOp>(*mux->getUsers().begin());
      if (isPlainRegister(dataReg, clock) &&
          (dataReg.getNext() == read.getResult() ||
           getHoldEnable(dataReg, read.getResult())))
        dataPorts.push_back({read, read.getIndex(),
                             getHoldEnable(dataReg, read.getResult()),
                             dataReg});
    }

    // Write-first: the read address is registered, possibly through an
    // index computation of the register alone.
    Value index = read.getIndex();
    Operation *indexOp = index.getDefiningOp();
    FirRegOp addrReg = dyn_cast_or_null<FirRegOp>(indexOp);
    if (!addrReg && indexOp && isa<comb::CombDialect>(indexOp->getDialect()) &&
        indexOp->getNumResults() == 1) {
      for (auto operand : indexOp->getOperands()) {
        if (matchPattern(operand, mlir::m_Constant()))
          continue;
        auto operandReg = operand.getDefiningOp<FirRegOp>();
        if (!operandReg || (addrReg && operandReg != addrReg)) {
          addrReg = {};
          break;
        }
        addrReg = operandReg;
      }
    }
    if (isPlainRegister(addrReg, clock) && addrReg != reg) {
      // The memory registers the address the register would have taken, so
      // the port is always enabled and the register can stay as it is.
      Value addr = addrReg.getNext();
      if (indexOp != addrReg) {
        OpBuilder builder(read);
        IRMapping mapping;
        mapping.map(addrReg.getResult(), addrReg.getNext());
        addr = builder.clone(*indexOp, mapping)->getResult(0);
      }
      addrPorts.push_back({read, addr, {}, {}});
    }
  }

  bool takeAddrRegs =
      dataPorts.size() != reads.size() && addrPorts.size() == reads.size();
  if (dataPorts.size() == reads.size()) {
    ports = std::move(dataPorts);
    readLatency = 1;
    readUnderWrite = seq::RUW::Old;
  } else if (takeAddrRegs) {
    ports = std::move(addrPorts);
    readLatency = 1;
    readUnderWrite = seq::RUW::New;
  } else {
    ports = std::move(asyncPorts);
  }
  // Index computations cloned for ports not taken are unused.
  if (!takeAddrRegs)
    for (auto &port : addrPorts)
      if (port.addr != port.read.getIndex() && port.addr.use_empty())
        if (auto *op = port.addr.getDefiningOp(); op && !isa<FirRegOp>(op))
          op->erase();
}

Value MemoryAnalysis::materialize(ImplicitLocOpBuilder &builder,
                                  const Condition &cond) {
  Value result;
  for (auto [value, polarity] : cond) {
    Value term = value;
    if (!polarity)
      term = comb::XorOp::create(builder, value,
                                 hw::ConstantOp::create(builder, APInt(1, 1)));
    result = result ? comb::AndOp::create(builder, result, term) : term;
  }
  return result ? result : hw::ConstantOp::create(builder, APInt(1, 1));
}

Value MemoryAnalysis::materializeBits(ImplicitLocOpBuilder &builder,
                                      unsigned writeIdx, unsigned low,
                                      unsigned bits) {
  // Runs of bits from consecutive bits of one value, least significant first.
  SmallVector<Value> parts;
  auto &sourceBits = writeBits[writeIdx];
  for (unsigned i = low; i < low + bits;) {
    auto first = sourceBits[i];
    unsigned end = i + 1;
    while (end < low + bits) {
      auto next = sourceBits[end];
      if (next.kind != first.kind || next.leaf != first.leaf ||
          (first.kind == BitSource::Leaf ? next.bit != first.bit + (end - i)
                                         : next.bit != first.bit))
        break;
      ++end;
    }
    unsigned len = end - i;
    if (first.kind == BitSource::Leaf) {
      parts.push_back(builder.createOrFold<comb::ExtractOp>(
          builder.getIntegerType(len), first.leaf, first.bit));
    } else {
      // A constant bit, or one the write does not replace, whose value the
      // mask makes irrelevant.
      parts.push_back(hw::ConstantOp::create(
          builder, first.kind == BitSource::Const && first.bit
                       ? APInt::getAllOnes(len)
                       : APInt::getZero(len)));
    }
    i = end;
  }
  std::reverse(parts.begin(), parts.end());
  return builder.createOrFold<comb::ConcatOp>(parts);
}

void MemoryAnalysis::createFirMemory(SmallVectorImpl<Operation *> &opsToErase) {
  ImplicitLocOpBuilder builder(reg.getLoc(), reg);

  // A bit is written by the writes that do not keep it; the last of them
  // wins.
  auto writersOf = [&](unsigned bit) {
    SmallVector<unsigned, 4> writers;
    for (unsigned w = 0; w < writes.size(); ++w)
      if (writeBits[w][bit].kind != BitSource::Old)
        writers.push_back(w);
    return writers;
  };

  // The mask granularity: the widest columns whose bits share their writers.
  unsigned granularity = width;
  unsigned runStart = 0;
  auto runWriters = writersOf(0);
  for (unsigned bit = 1; bit <= width; ++bit) {
    if (bit < width) {
      auto writers = writersOf(bit);
      if (writers == runWriters)
        continue;
      runWriters = std::move(writers);
    }
    granularity = std::gcd(granularity, bit - runStart);
    runStart = bit;
  }
  unsigned maskWidth = width / granularity;

  auto memName = reg.getNameAttr();
  if (!memName || memName.empty())
    memName = builder.getStringAttr("mem");
  auto memType = FirMemType::get(builder.getContext(), depth, width, maskWidth);
  auto firMem = seq::FirMemOp::create(
      builder, memType, readLatency, /*writeLatency=*/1, readUnderWrite,
      /*writeUnderWrite=*/seq::WUW::Undefined,
      /*name=*/memName, /*innerSym=*/hw::InnerSymAttr{},
      /*init=*/seq::FirMemInitAttr{}, /*prefix=*/StringAttr{},
      /*outputFile=*/Attribute{});
  // Carry over dialect attributes such as the `(* ram_style *)` the register
  // was declared with.
  firMem->setDialectAttrs(reg->getDialectAttrs());

  // FIRRTL currently uses a 1-bit address for a single element memory,
  // however HW arrays use 0-bit addresses. To bridge this gap, create a 1-bit
  // address equal to 0 if our address is 0-bit.
  auto fixZeroWidthAddr = [&](Value addr) -> Value {
    if (addr.getType().getIntOrFloatBitWidth() == 0)
      return hw::ConstantOp::create(builder, builder.getI1Type(), 0);
    return addr;
  };

  auto clock = reg.getClk();
  for (auto &port : ports) {
    Value enable =
        port.enable ? port.enable
                    : hw::ConstantOp::create(builder, builder.getI1Type(), 1);
    Value data = FirMemReadOp::create(
        builder, firMem, fixZeroWidthAddr(port.addr), clock, enable);
    if (port.dataReg) {
      // The register is erased with the write chain it now hangs from.
      port.dataReg.getResult().replaceAllUsesWith(data);
    } else {
      port.read.getResult().replaceAllUsesWith(data);
    }
  }

  SmallVector<Value> conds;
  for (auto &write : writes)
    conds.push_back(materialize(builder, write.cond));
  Value enable = builder.createOrFold<comb::OrOp>(conds, false);

  // Assemble data and mask one column at a time.
  SmallVector<Value> dataParts, maskBits;
  for (unsigned col = 0; col < maskWidth; ++col) {
    unsigned low = col * granularity;
    auto writers = writersOf(low);
    Value data, mask;
    for (auto w : writers) {
      Value part = materializeBits(builder, w, low, granularity);
      data =
          data ? builder.createOrFold<comb::MuxOp>(conds[w], part, data) : part;
      mask = mask ? builder.createOrFold<comb::OrOp>(mask, conds[w], false)
                  : conds[w];
    }
    if (!data) {
      data = hw::ConstantOp::create(builder, APInt::getZero(granularity));
      mask = hw::ConstantOp::create(builder, APInt(1, 0));
    }
    dataParts.push_back(data);
    maskBits.push_back(mask);
  }
  std::reverse(dataParts.begin(), dataParts.end());
  std::reverse(maskBits.begin(), maskBits.end());
  Value data = builder.createOrFold<comb::ConcatOp>(dataParts);
  Value mask;
  if (maskWidth > 1)
    mask = builder.createOrFold<comb::ConcatOp>(maskBits);
  else
    enable = maskBits.front();
  FirMemWriteOp::create(builder, firMem, fixZeroWidthAddr(writeAddr), clock,
                        enable, data, mask);

  // The write chain and the replaced reads are now unused.
  SetVector<Operation *> chain;
  mlir::ForwardSliceOptions options;
  getForwardSlice(reg.getOperation(), &chain, options);
  chain.remove(reg);
  opsToErase.push_back(reg);
  for (auto *op : llvm::reverse(chain))
    opsToErase.push_back(op);
}

void RegOfVecToMemPass::runOnOperation() {
  SmallVector<FirRegOp> arrayRegs;
  getOperation().walk([&](FirRegOp reg) {
    if (isa<hw::ArrayType>(reg.getType()))
      arrayRegs.push_back(reg);
  });

  SmallVector<Operation *> opsToErase;
  for (auto reg : arrayRegs) {
    MemoryAnalysis analysis(reg);
    if (analysis.analyze())
      analysis.createFirMemory(opsToErase);
  }

  for (auto *op : opsToErase)
    op->dropAllUses();
  for (auto *op : opsToErase)
    op->erase();
}
