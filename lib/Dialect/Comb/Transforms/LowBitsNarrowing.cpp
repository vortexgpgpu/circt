//===- LowBitsNarrowing.cpp - Narrow add and sub from their low zeros -----===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// The low bits of a sum where all operands but one are known zero are that
// operand's low bits: nothing carries out of them. The adder only needs the
// bits above.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/Comb/CombPasses.h"
#include "circt/Dialect/HW/HWOps.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"
#include "llvm/Support/KnownBits.h"

using namespace circt;
using namespace circt::comb;
using namespace mlir;

namespace circt {
namespace comb {
#define GEN_PASS_DEF_COMBLOWBITSNARROWING
#include "circt/Dialect/Comb/Passes.h.inc"
} // namespace comb
} // namespace circt

/// The number of low bits of `v` known to be zero.
static unsigned lowZeros(Value v) {
  return computeKnownBits(v).Zero.countTrailingOnes();
}

/// `op` on the bits of its operands from `low` up, with the low bits of
/// `lowOperand` (or zeros) below.
template <typename OpTy>
static void narrow(OpTy op, unsigned low, Value lowOperand,
                   PatternRewriter &rewriter) {
  auto loc = op.getLoc();
  unsigned width = op.getType().getIntOrFloatBitWidth();
  SmallVector<Value> highs;
  for (auto operand : op->getOperands())
    highs.push_back(
        ExtractOp::create(rewriter, loc, operand, low, width - low));
  Value high;
  if constexpr (std::is_same_v<OpTy, SubOp>)
    high = SubOp::create(rewriter, loc, highs[0], highs[1], op.getTwoState());
  else
    high = OpTy::create(rewriter, loc, highs, op.getTwoState());
  Value lows =
      lowOperand
          ? Value(ExtractOp::create(rewriter, loc, lowOperand, 0, low))
          : Value(hw::ConstantOp::create(rewriter, loc, APInt::getZero(low)));
  rewriter.replaceOpWithNewOp<ConcatOp>(op, ValueRange{high, lows});
}

namespace {
/// `a + b + ...` where the low bits of all operands but one are zero.
struct AddNarrow : OpRewritePattern<AddOp> {
  using OpRewritePattern::OpRewritePattern;
  LogicalResult matchAndRewrite(AddOp op,
                                PatternRewriter &rewriter) const override {
    unsigned width = op.getType().getIntOrFloatBitWidth();
    // The operand with the fewest low zeros keeps its low bits; the others'
    // fewest bound how many there are.
    Value lowOperand;
    unsigned fewest = width, low = width;
    for (auto operand : op.getOperands()) {
      unsigned zeros = lowZeros(operand);
      if (zeros < fewest) {
        low = fewest;
        fewest = zeros;
        lowOperand = operand;
      } else {
        low = std::min(low, zeros);
      }
    }
    if (fewest >= low)
      lowOperand = {};
    if (low == 0 || low >= width)
      return failure();
    narrow(op, low, lowOperand, rewriter);
    return success();
  }
};

/// `a - b` where the low bits of `b` are zero.
struct SubNarrow : OpRewritePattern<SubOp> {
  using OpRewritePattern::OpRewritePattern;
  LogicalResult matchAndRewrite(SubOp op,
                                PatternRewriter &rewriter) const override {
    unsigned width = op.getType().getIntOrFloatBitWidth();
    unsigned low = lowZeros(op.getRhs());
    if (low == 0 || low >= width)
      return failure();
    narrow(op, low, op.getLhs(), rewriter);
    return success();
  }
};

struct CombLowBitsNarrowingPass
    : comb::impl::CombLowBitsNarrowingBase<CombLowBitsNarrowingPass> {
  void runOnOperation() override {
    RewritePatternSet patterns(&getContext());
    patterns.add<AddNarrow, SubNarrow>(&getContext());
    if (failed(applyPatternsGreedily(getOperation(), std::move(patterns))))
      signalPassFailure();
  }
};
} // namespace
