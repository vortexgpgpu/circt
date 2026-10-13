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
#include "circt/Dialect/HW/HWInstanceGraph.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/HW/HWPasses.h"
#include "circt/Dialect/SV/SVAttributes.h"
#include "circt/Dialect/Seq/SeqOps.h"
#include "circt/Dialect/Seq/SeqPasses.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/IR/ImplicitLocOpBuilder.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassManager.h"
#include "mlir/Support/FileUtilities.h"
#include "llvm/Support/ToolOutputFile.h"

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

/// What the design asks of a memory.
enum class Hint { None, Block, Distributed };
} // namespace

/// The memory style the synthesis attributes of `op` ask for.
static std::pair<Hint, std::string> getHint(Operation *op) {
  auto attrs = sv::getSVAttributes(op);
  if (!attrs)
    return {Hint::None, ""};
  for (auto attr : attrs.getAsRange<sv::SVAttributeAttr>()) {
    auto name = attr.getName().getValue();
    if (name != "ram_style" && name != "ramstyle" && name != "syn_ramstyle")
      continue;
    if (!attr.getExpression())
      continue;
    auto text = attr.getExpression().getValue().trim().trim('"').lower();
    auto spelled = (name + "=" + text).str();
    // Each tool's names for a synchronous block RAM, and for distributed RAM
    // or plain logic. A value may list several styles ("M20K, no_rw_check").
    StringRef value(text);
    for (auto style : {"block", "block_ram", "bram", "ultra", "m9k", "m10k",
                       "m20k", "m144k", "m-ram", "mram"})
      if (value.contains(style))
        return {Hint::Block, spelled};
    for (auto style :
         {"distributed", "registers", "logic", "mlab", "select_ram", "lutram"})
      if (value.contains(style))
        return {Hint::Distributed, spelled};
  }
  return {Hint::None, ""};
}

/// A name for `value` in a diagnostic.
static std::string describe(Value value) {
  std::string text;
  llvm::raw_string_ostream os(text);
  if (auto arg = dyn_cast<BlockArgument>(value)) {
    if (auto module = dyn_cast<hw::HWModuleOp>(arg.getOwner()->getParentOp())) {
      os << "input '" << module.getInputName(arg.getArgNumber()) << "'";
      return text;
    }
    os << "block argument";
    return text;
  }
  auto *op = value.getDefiningOp();
  if (auto name = op->getAttrOfType<StringAttr>("name"); name && !name.empty())
    os << "'" << name.getValue() << "' (" << op->getName() << ")";
  else
    os << op->getName() << " at " << op->getLoc();
  return text;
}

/// Whether `value` is computed only from constants and registers on `clock`
/// with no asynchronous reset, through logic without side effects. If not,
/// `reason` says what it depends on instead.
static bool isFromRegisters(Value value, Value clock,
                            DenseMap<Value, bool> &cache, std::string &reason) {
  if (auto it = cache.find(value); it != cache.end())
    return it->second;
  bool result = false;
  auto *op = value.getDefiningOp();
  if (auto reg = dyn_cast_or_null<FirRegOp>(op)) {
    result = reg.getClk() == clock && !reg.getIsAsync();
    if (!result && reason.empty())
      reason = "address register " + describe(value) +
               (reg.getIsAsync() ? " has an asynchronous reset"
                                 : " is on another clock");
  } else if (op && op->getNumRegions() == 0 && isMemoryEffectFree(op) &&
             !isa<FirMemReadOp, FirMemReadWriteOp>(op)) {
    cache[value] = false;
    result = llvm::all_of(op->getOperands(), [&](Value operand) {
      return isFromRegisters(operand, clock, cache, reason);
    });
  } else if (reason.empty()) {
    reason = "address depends on " + describe(value);
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

/// The clock of `memory`'s reads once retimed, or a reason it has none.
static FailureOr<Value> getClock(FirMemOp memory,
                                 MutableArrayRef<FirMemReadOp> reads,
                                 ArrayRef<FirMemWriteOp> writes,
                                 std::string &reason) {
  Value clock;
  for (auto write : writes) {
    if (clock && write.getClk() != clock) {
      reason = "writes on several clocks";
      return failure();
    }
    clock = write.getClk();
  }
  if (!clock)
    if (auto reg = reads[0].getAddress().getDefiningOp<FirRegOp>())
      clock = reg.getClk();
  if (!clock) {
    reason = "no writes, and the first read's address is not a register";
    return failure();
  }
  return clock;
}

/// Whether `value` is computed from constants and registers without an
/// asynchronous reset, through logic without side effects, across module
/// boundaries: up through a module's inputs to every instance of it, and down
/// through an instance's results into its module. The private modules crossed
/// are added to `crossed`. A later check on the inlined design decides; this
/// one only finds the modules that keep a memory from its address registers.
static bool isFromRegistersAcross(Value value, hw::InstanceGraph &graph,
                                  DenseMap<Value, bool> &cache,
                                  SmallPtrSetImpl<Operation *> &crossed) {
  if (auto it = cache.find(value); it != cache.end())
    return it->second;
  cache[value] = false;
  bool result = false;
  if (auto arg = dyn_cast<BlockArgument>(value)) {
    auto module = dyn_cast<hw::HWModuleOp>(arg.getOwner()->getParentOp());
    auto *node = module ? graph.lookup(module) : nullptr;
    if (node && module.isPrivate() && node->getNumUses() != 0) {
      crossed.insert(module);
      result = llvm::all_of(node->uses(), [&](igraph::InstanceRecord *use) {
        auto inst =
            dyn_cast_or_null<hw::InstanceOp>(use->getInstance().getOperation());
        return inst &&
               isFromRegistersAcross(inst.getOperand(arg.getArgNumber()), graph,
                                     cache, crossed);
      });
    }
  } else if (auto inst = value.getDefiningOp<hw::InstanceOp>()) {
    auto module = dyn_cast_or_null<hw::HWModuleOp>(
        graph.lookup(inst.getReferencedModuleNameAttr())
            ->getModule()
            .getOperation());
    if (module && module.isPrivate()) {
      crossed.insert(module);
      auto output = cast<hw::OutputOp>(module.getBodyBlock()->getTerminator());
      result = isFromRegistersAcross(
          output.getOperand(cast<OpResult>(value).getResultNumber()), graph,
          cache, crossed);
    }
  } else if (auto reg = value.getDefiningOp<FirRegOp>()) {
    result = !reg.getIsAsync();
  } else if (auto *op = value.getDefiningOp();
             op && op->getNumRegions() == 0 && isMemoryEffectFree(op) &&
             !isa<FirMemReadOp, FirMemReadWriteOp>(op)) {
    result = llvm::all_of(op->getOperands(), [&](Value operand) {
      return isFromRegistersAcross(operand, graph, cache, crossed);
    });
  }
  return cache[value] = result;
}

void RetimeFirMemReadsPass::runOnOperation() {
  if (mode != "off" && mode != "auto") {
    getOperation().emitError("seq-retime-firmem-reads: mode must be off or "
                             "auto, not '")
        << mode << "'";
    return signalPassFailure();
  }

  // Whether this run converts `memory` if it can.
  auto wanted = [&](FirMemOp memory) {
    if (memory.getReadLatency() != 0 || memory.getWriteLatency() != 1 ||
        disable)
      return false;
    auto type = memory.getType();
    switch (getHint(memory).first) {
    case Hint::Block:
      return true;
    case Hint::Distributed:
      return false;
    case Hint::None:
      return mode == "auto" && type.getDepth() * type.getWidth() >= minBits;
    }
    return false;
  };

  // A memory's address registers may be in another module than the memory:
  // a RAM wrapper reads at an address it receives on a port. Inline the
  // modules between them, and only those, so that one module holds both.
  std::string inlinedText;
  if (inlineModules) {
    auto &graph = getAnalysis<hw::InstanceGraph>();
    SmallPtrSet<Operation *, 16> marked;
    DenseMap<Value, bool> cache;
    getOperation().walk([&](FirMemOp memory) {
      if (!wanted(memory))
        return;
      for (auto *user : memory->getUsers()) {
        auto read = dyn_cast<FirMemReadOp>(user);
        if (!read)
          continue;
        SmallPtrSet<Operation *, 8> crossed;
        if (isFromRegistersAcross(read.getAddress(), graph, cache, crossed))
          marked.insert(crossed.begin(), crossed.end());
      }
    });
    if (!marked.empty()) {
      SmallVector<StringRef> names;
      for (auto *module : marked) {
        module->setAttr("hw.inline", UnitAttr::get(&getContext()));
        names.push_back(cast<hw::HWModuleOp>(module).getModuleName());
      }
      llvm::sort(names);
      inlinedText = "# inlined to bring memories and their address registers "
                    "together: " +
                    llvm::join(names, " ") + "\n";
      hw::FlattenModulesOptions options;
      options.inlineAll = false;
      options.inlineEmpty = false;
      options.inlineNoOutputs = false;
      options.inlineSingleUse = false;
      options.inlineSmall = false;
      options.inlineMarked = true;
      OpPassManager pm("builtin.module");
      pm.addPass(hw::createFlattenModules(options));
      if (failed(runPipeline(pm, getOperation())))
        return signalPassFailure();
      for (auto module : getOperation().getOps<hw::HWModuleOp>())
        module->removeAttr("hw.inline");
    }
  }

  std::string reportText = inlinedText;
  llvm::raw_string_ostream reportOS(reportText);
  bool failed = false;
  bool changed = !inlinedText.empty();

  for (auto module : getOperation().getOps<hw::HWModuleOp>()) {
    SmallVector<FirMemOp> memories;
    module.walk([&](FirMemOp memory) {
      if (memory.getReadLatency() == 0 && memory.getWriteLatency() == 1)
        memories.push_back(memory);
    });

    for (auto memory : memories) {
      auto type = memory.getType();
      uint64_t bits = type.getDepth() * type.getWidth();
      auto hinted = getHint(memory);
      auto hint = hinted.first;
      auto spelled = hinted.second;
      std::string name = memory.getName() ? memory.getName()->str() : "";
      if (name.empty())
        name = "<unnamed>";
      auto line = [&](StringRef decision, StringRef why) {
        reportOS << module.getModuleName() << "." << name << " "
                 << type.getDepth() << "x" << type.getWidth() << " "
                 << (spelled.empty() ? "no-hint" : spelled) << " " << decision;
        if (!why.empty())
          reportOS << " (" << why << ")";
        reportOS << "\n";
      };

      if (hint == Hint::Distributed) {
        line("kept", "hint");
        continue;
      }
      if (disable) {
        if (hint == Hint::Block)
          memory.emitWarning("asks for block RAM (")
              << spelled << "), but memory read retiming is disabled";
        line("kept", "disabled");
        continue;
      }
      if (hint == Hint::None && mode == "off") {
        line("kept", "no hint, mode off");
        continue;
      }
      if (hint == Hint::None && bits < minBits) {
        line("kept", "fewer than min-bits");
        continue;
      }

      // Whether the memory can be converted, and if not, why not.
      std::string reason;
      SmallVector<FirMemReadOp> reads;
      SmallVector<FirMemWriteOp> writes;
      for (auto *user : memory->getUsers()) {
        if (auto read = dyn_cast<FirMemReadOp>(user))
          reads.push_back(read);
        else if (auto write = dyn_cast<FirMemWriteOp>(user))
          writes.push_back(write);
        else if (reason.empty())
          reason = "has a read-write port";
      }
      if (reason.empty() && reads.empty())
        reason = "has no reads";
      Value clock;
      if (reason.empty()) {
        auto found = getClock(memory, reads, writes, reason);
        if (succeeded(found))
          clock = *found;
      }
      DenseMap<Value, bool> cache;
      if (reason.empty())
        for (auto read : reads)
          if (!isFromRegisters(read.getAddress(), clock, cache, reason))
            break;

      if (!reason.empty()) {
        line(hint == Hint::Block ? "ERROR" : "kept", reason);
        if (hint == Hint::Block) {
          memory.emitError("asks for block RAM (")
              << spelled << "), but its asynchronous read cannot be made "
              << "synchronous: " << reason;
          failed = true;
        }
        continue;
      }

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
      changed = true;
      line("converted", "");
    }
  }

  if (!report.empty()) {
    std::string error;
    auto file = mlir::openOutputFile(report, &error);
    if (!file) {
      getOperation().emitError(error);
      return signalPassFailure();
    }
    file->os() << reportText;
    file->keep();
  }
  if (failed)
    return signalPassFailure();
  if (!changed)
    markAllAnalysesPreserved();
}
