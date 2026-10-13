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
/// mux(c, inject(x, i, v), x) -> create(mux(c & i == k, v, x[k]) for each k),
/// and the same with the mux's operands swapped and `c` inverted.
struct ConditionalWrite : public OpRewritePattern<comb::MuxOp> {
  ConditionalWrite(MLIRContext *context, unsigned maxElements)
      : OpRewritePattern(context), maxElements(maxElements) {}

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
      elements.push_back(rewriter.createOrFold<comb::MuxOp>(
          loc, select, inject.getElement(), old, twoState));
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
