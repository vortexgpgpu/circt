//===----------------------------------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file implements a generic LUT mapper pass using the cut-based rewriting
// framework. It performs technology mapping by converting combinational logic
// networks into implementations using K-input lookup tables (LUTs).
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/Seq/SeqOps.h"
#include "circt/Dialect/Synth/Transforms/CutRewriter.h"
#include "circt/Dialect/Synth/Transforms/SynthPasses.h"
#include "circt/Support/LLVM.h"
#include "circt/Support/TruthTable.h"
#include "mlir/IR/Builders.h"
#include "mlir/Pass/Pass.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "synth-generic-lut-mapper"

using namespace circt;
using namespace circt::synth;

namespace circt {
namespace synth {
#define GEN_PASS_DEF_GENERICLUTMAPPER
#include "circt/Dialect/Synth/Transforms/SynthPasses.h.inc"
} // namespace synth
} // namespace circt

//===----------------------------------------------------------------------===//
// Generic LUT Pattern
//===----------------------------------------------------------------------===//

/// A generic K-input LUT pattern that can implement any boolean function
/// with up to K inputs using a lookup table.
struct GenericLUT : public CutRewritePattern {
  unsigned k; // Maximum number of inputs for this LUT
  SmallVector<DelayType, 8> cachedDelays; // Pre-computed unit delays

  GenericLUT(mlir::MLIRContext *context, unsigned k)
      : CutRewritePattern(context), k(k), cachedDelays(k, 1) {}

  std::optional<MatchResult> match(CutEnumerator &enumerator,
                                   const Cut &cut) const override {
    const auto &network = enumerator.getLogicNetwork();
    // This pattern can implement any cut with at most k inputs
    if (cut.getInputSize() > k || cut.getOutputSize(network) != 1)
      return std::nullopt;

    // Create match result with a reference to cached delays
    return MatchResult(
        1.0, ArrayRef<DelayType>(cachedDelays).take_front(cut.getInputSize()));
  }

  llvm::FailureOr<Operation *> rewrite(mlir::OpBuilder &rewriter,
                                       CutEnumerator &enumerator,
                                       const Cut &cut) const override {
    const auto &network = enumerator.getLogicNetwork();
    // NOTE: Don't use NPN since it's unnecessary.
    const auto &truthTableOpt = cut.getTruthTable();
    if (!truthTableOpt)
      return failure();
    const auto &truthTable = *truthTableOpt;
    LLVM_DEBUG({
      llvm::dbgs() << "Rewriting cut with " << cut.getInputSize()
                   << " inputs and " << cut.getInputSize()
                   << " operations to a generic LUT with " << k << " inputs.\n";
      cut.dump(llvm::dbgs(), network);
      llvm::dbgs() << "Truth table details:\n";
      truthTable.dump(llvm::dbgs());
    });

    SmallVector<bool> lutTable;
    // Convert the truth table to a LUT table
    for (uint32_t i = 0; i < truthTable.table.getBitWidth(); ++i)
      lutTable.push_back(truthTable.table[i]);

    // Reverse the inputs to match the LUT input order
    SmallVector<Value> lutInputs;
    lutInputs.reserve(cut.inputs.size());
    for (auto i : llvm::reverse(cut.inputs))
      lutInputs.push_back(network.getValue(i));

    auto *rootOp = network.getGate(cut.getRootIndex()).getOperation();
    assert(rootOp && "cut root must be a valid operation");

    // Generate comb.truth table operation.
    auto truthTableOp = comb::TruthTableOp::create(rewriter, rootOp->getLoc(),
                                                   lutInputs, lutTable);

    // Replace the root operation with the truth table operation
    return truthTableOp.getOperation();
  }

  unsigned getNumOutputs() const override { return 1; }

  StringRef getPatternName() const override { return "GenericLUT"; }
};

//===----------------------------------------------------------------------===//
// Carry Chain Arrival Model
//===----------------------------------------------------------------------===//

/// When the word-level operations a LUT mapper leaves to an FPGA's carry
/// chains and distributed RAMs deliver their bits, in LUT levels: a LUT that
/// computes propagate and generate, then a level per carry block from the
/// input bit's block to the output bit's; an adder or comparator over at most
/// K input bits is one K-LUT; an equality is a tree of K-LUTs over its bits;
/// a read of a memory of latency 0 is a LUT RAM of 2^K words and a level of
/// multiplexers per doubling beyond it, from the address. Other combinational
/// operations (products, quotients) are at least a level after their latest
/// operand; a register starts a path.
///
/// A module mapped apart from the rest of its hierarchy can be told when its
/// boundary signals arrive, in the same LUT levels: `synth.input_arrival_times`
/// on an `hw.module` for its input ports, `synth.output_arrival_times` on an
/// `hw.instance` for its results. Each is an array with an entry per port, a
/// `DenseI64ArrayAttr` of per-bit arrival times (one element for every bit,
/// none for 0). Without them those signals start a path, at 0.
struct CarryChainArrivalModel : public ArrivalTimeModel {
  unsigned lutSize, carryBits;

  CarryChainArrivalModel(unsigned lutSize, unsigned carryBits)
      : lutSize(lutSize), carryBits(carryBits) {}

  /// Bit `bit` of port `index` in a boundary arrival attribute.
  static DelayType boundary(Attribute attr, unsigned index, unsigned bit) {
    auto ports = dyn_cast_or_null<ArrayAttr>(attr);
    if (!ports || index >= ports.size())
      return 0;
    auto bits = dyn_cast<mlir::DenseI64ArrayAttr>(ports[index]);
    if (!bits || bits.empty())
      return 0;
    return bits[bits.size() == 1 ? 0 : std::min<size_t>(bit, bits.size() - 1)];
  }

  DelayType getArgumentArrivalTime(BlockArgument argument,
                                   unsigned bit) const override {
    auto *parent = argument.getOwner()->getParentOp();
    if (!isa_and_nonnull<hw::HWModuleOp>(parent))
      return 0;
    return boundary(parent->getAttr("synth.input_arrival_times"),
                    argument.getArgNumber(), bit);
  }

  /// Levels from input bit `in` of a carry chain to output bit `out`.
  DelayType carry(unsigned in, unsigned out) const {
    return 2 + out / carryBits - in / carryBits;
  }

  /// Levels of a tree of K-LUTs over `n` signals.
  DelayType lutTree(uint64_t n) const {
    DelayType levels = 0;
    for (uint64_t reach = 1; reach < n; reach *= lutSize)
      ++levels;
    return levels;
  }

  DelayType getArrivalTime(
      OpResult result, unsigned bit,
      llvm::function_ref<std::optional<DelayType>(Value, unsigned)> arrival)
      const override {
    Operation *op = result.getOwner();
    // The non-constant bits of the operands up to bit `top`: arrival, index.
    using Bits = SmallVectorImpl<std::pair<DelayType, unsigned>>;
    auto inputBits = [&](unsigned top, Bits &bits) {
      for (Value operand : op->getOperands()) {
        int64_t width = hw::getBitWidth(operand.getType());
        for (int64_t i = 0; i < width && i <= top; ++i)
          if (auto time = arrival(operand, i))
            bits.push_back({*time, i});
      }
    };
    // A carry chain to bit `out`, or one LUT over few bits.
    auto chain = [&](ArrayRef<std::pair<DelayType, unsigned>> bits,
                     unsigned out) {
      DelayType time = 0;
      for (auto [inTime, in] : bits)
        time = std::max(time, inTime + (bits.size() <= lutSize
                                            ? 1
                                            : carry(in, out)));
      return time;
    };
    SmallVector<std::pair<DelayType, unsigned>> bits;
    if (isa<comb::AddOp, comb::SubOp>(op)) {
      inputBits(bit, bits);
      return chain(bits, bit);
    }
    if (auto icmp = dyn_cast<comb::ICmpOp>(op)) {
      inputBits(~0u, bits);
      if (bits.empty())
        return 0;
      auto predicate = icmp.getPredicate();
      if (predicate == comb::ICmpPredicate::eq ||
          predicate == comb::ICmpPredicate::ne ||
          predicate == comb::ICmpPredicate::ceq ||
          predicate == comb::ICmpPredicate::cne ||
          predicate == comb::ICmpPredicate::weq ||
          predicate == comb::ICmpPredicate::wne) {
        DelayType time = 0;
        for (auto [inTime, in] : bits)
          time = std::max(time, inTime);
        return time + 1 + lutTree(llvm::divideCeil(bits.size(), lutSize));
      }
      // The chain ends at the highest bit that is not constant.
      unsigned top = 0;
      for (auto [inTime, in] : bits)
        top = std::max(top, in);
      return chain(bits, top);
    }
    if (auto read = dyn_cast<seq::FirMemReadOp>(op)) {
      auto memory = read.getMemory().getDefiningOp<seq::FirMemOp>();
      if (!memory || memory.getReadLatency() != 0)
        return 0;
      DelayType levels =
          1 + std::max<int64_t>(
                  0, (int64_t)llvm::Log2_64_Ceil(memory.getType().getDepth()) -
                         (int64_t)lutSize);
      DelayType time = 0;
      for (int64_t i = 0, e = hw::getBitWidth(read.getAddress().getType());
           i < e; ++i)
        if (auto inTime = arrival(read.getAddress(), i))
          time = std::max(time, *inTime + levels);
      if (Value enable = read.getEnable())
        if (auto inTime = arrival(enable, 0))
          time = std::max(time, *inTime + 1);
      return time;
    }
    if (isa<hw::InstanceOp>(op))
      return boundary(op->getAttr("synth.output_arrival_times"),
                      result.getResultNumber(), bit);
    if (isa<comb::CombDialect>(op->getDialect())) {
      inputBits(~0u, bits);
      DelayType time = 0;
      for (auto [inTime, in] : bits)
        time = std::max(time, inTime + 1);
      return time;
    }
    return 0;
  }
};

//===----------------------------------------------------------------------===//
// Generic LUT Mapper Pass
//===----------------------------------------------------------------------===//

struct GenericLUTMapperPass
    : public impl::GenericLutMapperBase<GenericLUTMapperPass> {
  using GenericLutMapperBase<GenericLUTMapperPass>::GenericLutMapperBase;

  void runOnOperation() override {
    auto module = getOperation();
    // Create the cut rewriter options
    CutRewriterOptions options;
    options.strategy = strategy;
    options.maxCutInputSize = maxLutSize;
    options.maxCutSizePerRoot = maxCutsPerRoot;
    options.allowNoMatch = false;
    options.attachDebugTiming = test;
    std::optional<CarryChainArrivalModel> arrivalTimeModel;
    if (carryBlockSize) {
      arrivalTimeModel.emplace(maxLutSize, carryBlockSize);
      options.arrivalTimeModel = &*arrivalTimeModel;
    }

    // Create the pattern for generic K-LUT
    SmallVector<std::unique_ptr<CutRewritePattern>, 4> patterns;
    patterns.push_back(
        std::make_unique<GenericLUT>(module->getContext(), maxLutSize));

    // Create the pattern set
    CutRewritePatternSet patternSet(std::move(patterns));

    // Create the cut rewriter
    CutRewriter rewriter(options, patternSet);

    // Apply the rewriting
    if (failed(rewriter.run(module)))
      return signalPassFailure();

    const auto &stats = rewriter.getStats();
    numCutsCreated += stats.numCutsCreated;
    numCutSetsCreated += stats.numCutSetsCreated;
    numCutsRewritten += stats.numCutsRewritten;
  }
};
