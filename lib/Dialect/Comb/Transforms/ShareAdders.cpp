//===- ShareAdders.cpp - One adder for the arms of a mux ------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// A mux between two sums of a common operand is that operand plus the mux of
// the other operands: one adder instead of two. A difference is a sum of the
// negated subtrahend when that negation is free, a constant or a mux of
// constants.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/Comb/CombPasses.h"
#include "circt/Dialect/HW/HWOps.h"
#include "mlir/IR/Matchers.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

using namespace circt;
using namespace circt::comb;
using namespace mlir;

namespace circt {
namespace comb {
#define GEN_PASS_DEF_COMBSHAREADDERS
#include "circt/Dialect/Comb/Passes.h.inc"
} // namespace comb
} // namespace circt

/// Whether `-value` is free: `value` is a constant or a mux tree of constants.
static bool isFreeToNegate(Value value) {
  if (matchPattern(value, m_Constant()))
    return true;
  auto mux = value.getDefiningOp<MuxOp>();
  return mux && isFreeToNegate(mux.getTrueValue()) &&
         isFreeToNegate(mux.getFalseValue());
}

/// `-value`, for a value that is free to negate.
static Value negate(PatternRewriter &rewriter, Location loc, Value value) {
  APInt constant;
  if (matchPattern(value, m_ConstantInt(&constant)))
    return hw::ConstantOp::create(rewriter, loc, -constant);
  auto mux = value.getDefiningOp<MuxOp>();
  return MuxOp::create(
      rewriter, loc, mux.getCond(), negate(rewriter, loc, mux.getTrueValue()),
      negate(rewriter, loc, mux.getFalseValue()), mux.getTwoState());
}

namespace {
/// An arm of the mux as `base + offset` or `base - offset`.
struct Term {
  Value base, offset;
  bool negative;
};

/// The ways to read `value` as a sum or difference with one operand as base.
static SmallVector<Term, 2> getTerms(Value value) {
  if (auto add = value.getDefiningOp<AddOp>(); add && add.getNumOperands() == 2)
    return {{add.getOperand(0), add.getOperand(1), false},
            {add.getOperand(1), add.getOperand(0), false}};
  if (auto sub = value.getDefiningOp<SubOp>())
    return {{sub.getLhs(), sub.getRhs(), true}};
  return {};
}

struct MuxOfSums : OpRewritePattern<MuxOp> {
  using OpRewritePattern::OpRewritePattern;
  LogicalResult matchAndRewrite(MuxOp mux,
                                PatternRewriter &rewriter) const override {
    if (!mux.getType().isInteger())
      return failure();
    // Sharing pays only if the two adders go away.
    auto onTrue = mux.getTrueValue(), onFalse = mux.getFalseValue();
    if (!onTrue.hasOneUse() || !onFalse.hasOneUse() || onTrue == onFalse)
      return failure();
    auto loc = mux.getLoc();
    for (auto t : getTerms(onTrue)) {
      for (auto f : getTerms(onFalse)) {
        if (t.base != f.base)
          continue;
        Value trueOffset = t.offset, falseOffset = f.offset;
        bool negative = t.negative && f.negative;
        if (t.negative != f.negative) {
          // The difference is a sum of the negated subtrahend.
          auto &subtrahend = t.negative ? trueOffset : falseOffset;
          if (!isFreeToNegate(subtrahend))
            continue;
          subtrahend = negate(rewriter, loc, subtrahend);
        }
        auto offset = MuxOp::create(rewriter, loc, mux.getCond(), trueOffset,
                                    falseOffset, mux.getTwoState());
        if (negative)
          rewriter.replaceOpWithNewOp<SubOp>(mux, t.base, offset);
        else
          rewriter.replaceOpWithNewOp<AddOp>(mux, t.base, offset);
        return success();
      }
    }
    return failure();
  }
};

struct CombShareAddersPass
    : comb::impl::CombShareAddersBase<CombShareAddersPass> {
  void runOnOperation() override {
    RewritePatternSet patterns(&getContext());
    patterns.add<MuxOfSums>(&getContext());
    if (failed(applyPatternsGreedily(getOperation(), std::move(patterns))))
      signalPassFailure();
  }
};
} // namespace
