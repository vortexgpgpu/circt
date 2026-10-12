//===- LowerAggregateRegs.cpp - Aggregate registers as integers -----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// A register of an array or struct type keeps its bits as an integer, so that
// the aggregate operations around it can be lowered to bit operations.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/Seq/SeqOps.h"
#include "circt/Dialect/Seq/SeqPasses.h"
#include "mlir/IR/ImplicitLocOpBuilder.h"
#include "mlir/Pass/Pass.h"

namespace circt {
namespace seq {
#define GEN_PASS_DEF_LOWERAGGREGATEREGS
#include "circt/Dialect/Seq/SeqPasses.h.inc"
} // namespace seq
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace seq;

namespace {
struct LowerAggregateRegsPass
    : public circt::seq::impl::LowerAggregateRegsBase<LowerAggregateRegsPass> {
  void runOnOperation() override;
};
} // namespace

void LowerAggregateRegsPass::runOnOperation() {
  SmallVector<FirRegOp> regs;
  getOperation().walk([&](FirRegOp reg) {
    if (!isa<IntegerType>(reg.getType()))
      regs.push_back(reg);
  });
  for (auto reg : regs) {
    auto width = hw::getBitWidth(reg.getType());
    if (width <= 0)
      continue;
    ImplicitLocOpBuilder b(reg.getLoc(), reg);
    auto intType = b.getIntegerType(width);
    auto toInteger = [&](Value value) -> Value {
      return b.createOrFold<hw::BitcastOp>(intType, value);
    };
    FirRegOp lowered;
    if (reg.hasReset())
      lowered = FirRegOp::create(
          b, toInteger(reg.getNext()), reg.getClk(), reg.getNameAttr(),
          reg.getReset(), toInteger(reg.getResetValue()), reg.getInnerSymAttr(),
          reg.getIsAsync(), reg.getPresetAttr());
    else
      lowered = FirRegOp::create(b, toInteger(reg.getNext()), reg.getClk(),
                                 reg.getNameAttr(), reg.getInnerSymAttr(),
                                 reg.getPresetAttr());
    lowered->setDialectAttrs(reg->getDialectAttrs());
    reg.getResult().replaceAllUsesWith(
        b.createOrFold<hw::BitcastOp>(reg.getType(), lowered));
    reg.erase();
  }
}
