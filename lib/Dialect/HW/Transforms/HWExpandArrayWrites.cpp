//===- HWExpandArrayWrites.cpp - Conditional array writes to selects ------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/HW/HWPasses.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

namespace circt {
namespace hw {
#define GEN_PASS_DEF_HWEXPANDARRAYWRITES
#include "circt/Dialect/HW/Passes.h.inc"
} // namespace hw
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace hw;

namespace {
/// `value` with every read `get(array, index)` within `depth` ops of it
/// replaced by `element`: the value element k is written with, where i == k.
/// Only the ops between such a read and `value` are copied, at most `budget`
/// of them; null if there are more.
static Value forwardElement(Value value, Value array, Value index,
                            Value element, unsigned depth,
                            PatternRewriter &rewriter,
                            DenseMap<Value, Value> &copies, unsigned &budget) {
  if (auto it = copies.find(value); it != copies.end())
    return it->second;
  Operation *op = value.getDefiningOp();
  Value result = value;
  if (auto get = dyn_cast_or_null<ArrayGetOp>(op);
      get && get.getInput() == array && get.getIndex() == index) {
    result = element;
  } else if (depth > 0 && op && op->getNumRegions() == 0 &&
             op->getNumResults() == 1 &&
             isa<comb::CombDialect, HWDialect>(op->getDialect())) {
    SmallVector<Value> operands;
    bool changed = false;
    for (Value operand : op->getOperands()) {
      Value forwarded = forwardElement(operand, array, index, element,
                                       depth - 1, rewriter, copies, budget);
      if (!forwarded)
        return {};
      changed |= forwarded != operand;
      operands.push_back(forwarded);
    }
    if (changed) {
      if (budget == 0)
        return {};
      --budget;
      Operation *copy = rewriter.clone(*op);
      copy->setOperands(operands);
      result = copy->getResult(0);
    }
  }
  copies[value] = result;
  return result;
}

/// mux(c, inject(x, i, v), x) -> create(mux(c & i == k, v, x[k]) for each k),
/// and the same with the mux's operands swapped and `c` inverted. Where `v`
/// reads x[i] -- a read-modify-write of the element, as a loop setting one
/// field of x[i] per iteration lowers to -- element k's copy reads x[k]: the
/// same value where it is selected, without the dynamic read, so a chain of
/// such writes is not a chain of index muxes.
struct ConditionalWrite : public OpRewritePattern<comb::MuxOp> {
  ConditionalWrite(MLIRContext *context, unsigned maxElements)
      : OpRewritePattern(context), maxElements(maxElements) {}

  /// How far from the written value its read of x[i] is looked for, and the
  /// ops copied per element at most to forward x[k] instead.
  static constexpr unsigned kForwardDepth = 8, kForwardBudget = 32;

  LogicalResult matchAndRewrite(comb::MuxOp op,
                                PatternRewriter &rewriter) const override {
    auto inject = op.getTrueValue().getDefiningOp<ArrayInjectOp>();
    Value array = op.getFalseValue();
    bool writeWhenTrue = true;
    if (!inject || inject.getInput() != array) {
      inject = op.getFalseValue().getDefiningOp<ArrayInjectOp>();
      array = op.getTrueValue();
      writeWhenTrue = false;
      if (!inject || inject.getInput() != array)
        return failure();
    }
    if (!inject->hasOneUse())
      return failure();
    auto numElements = type_cast<ArrayType>(array.getType()).getNumElements();
    if (numElements == 0 || numElements > maxElements)
      return failure();

    auto loc = op.getLoc();
    bool twoState = op.getTwoState();
    Value cond = op.getCond();
    if (!writeWhenTrue)
      cond = comb::createOrFoldNot(rewriter, loc, cond, twoState);
    auto indexWidth = cast<IntegerType>(inject.getIndex().getType()).getWidth();
    // `hw.array_create` takes its elements from the highest index down.
    SmallVector<Value> elements;
    for (size_t k = numElements; k-- > 0;) {
      auto index = ConstantOp::create(rewriter, loc, APInt(indexWidth, k));
      auto hit = rewriter.createOrFold<comb::ICmpOp>(
          loc, comb::ICmpPredicate::eq, inject.getIndex(), index, twoState);
      auto select =
          rewriter.createOrFold<comb::AndOp>(loc, cond, hit, twoState);
      auto old = rewriter.createOrFold<ArrayGetOp>(loc, array, index);
      DenseMap<Value, Value> copies;
      unsigned budget = kForwardBudget;
      Value written =
          forwardElement(inject.getElement(), array, inject.getIndex(), old,
                         kForwardDepth, rewriter, copies, budget);
      if (!written)
        written = inject.getElement();
      elements.push_back(rewriter.createOrFold<comb::MuxOp>(
          loc, select, written, old, twoState));
    }
    rewriter.replaceOpWithNewOp<ArrayCreateOp>(op, elements);
    return success();
  }

  unsigned maxElements;
};

struct HWExpandArrayWritesPass
    : public circt::hw::impl::HWExpandArrayWritesBase<HWExpandArrayWritesPass> {
  using HWExpandArrayWritesBase::HWExpandArrayWritesBase;
  void runOnOperation() override {
    RewritePatternSet patterns(&getContext());
    patterns.add<ConditionalWrite>(&getContext(), maxElements);
    if (failed(applyPatternsGreedily(getOperation(), std::move(patterns))))
      signalPassFailure();
  }
};
} // namespace
