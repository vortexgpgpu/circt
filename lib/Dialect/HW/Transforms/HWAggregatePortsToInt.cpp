//===- HWAggregatePortsToInt.cpp - Aggregate ports as integers ------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Gives array and struct ports integer types of the same bits, bitcasting at
// the module boundary and at each instance.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/HW/HWPasses.h"
#include "mlir/IR/Builders.h"
#include "mlir/Pass/Pass.h"

namespace circt {
namespace hw {
#define GEN_PASS_DEF_HWAGGREGATEPORTSTOINT
#include "circt/Dialect/HW/Passes.h.inc"
} // namespace hw
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace hw;

namespace {
struct HWAggregatePortsToIntPass
    : public circt::hw::impl::HWAggregatePortsToIntBase<
          HWAggregatePortsToIntPass> {
  void runOnOperation() override;
};
} // namespace

/// The integer type of the same bits as an array or struct type, or null.
static Type getIntegerFor(Type type) {
  if (!isa<hw::ArrayType, hw::StructType, hw::UnionType>(type))
    return {};
  auto width = hw::getBitWidth(type);
  if (width < 0)
    return {};
  return IntegerType::get(type.getContext(), width);
}

void HWAggregatePortsToIntPass::runOnOperation() {
  auto top = getOperation();
  auto *context = &getContext();
  DenseSet<StringAttr> changed;

  for (auto module : top.getOps<hw::HWModuleLike>()) {
    if (!isa<hw::HWModuleOp, hw::HWModuleExternOp>(module))
      continue;
    auto ports = module.getHWModuleType().getPorts();
    SmallVector<hw::ModulePort> newPorts(ports.begin(), ports.end());
    bool any = false;
    for (auto &port : newPorts)
      if (auto type = getIntegerFor(port.type)) {
        port.type = type;
        any = true;
      }
    if (!any)
      continue;
    changed.insert(module.getModuleNameAttr());

    if (auto hwModule = dyn_cast<hw::HWModuleOp>(module.getOperation())) {
      auto *body = hwModule.getBodyBlock();
      OpBuilder b = OpBuilder::atBlockBegin(body);
      for (auto arg : body->getArguments()) {
        auto type = getIntegerFor(arg.getType());
        if (!type)
          continue;
        auto oldType = arg.getType();
        arg.setType(type);
        auto cast = hw::BitcastOp::create(b, arg.getLoc(), oldType, arg);
        arg.replaceAllUsesExcept(cast, cast);
      }
      auto *output = body->getTerminator();
      b.setInsertionPoint(output);
      for (auto &operand : output->getOpOperands())
        if (auto type = getIntegerFor(operand.get().getType()))
          operand.set(
              hw::BitcastOp::create(b, output->getLoc(), type, operand.get()));
    }
    module.setHWModuleType(hw::ModuleType::get(context, newPorts));
  }

  // Each instance of a changed module casts its operands and results.
  SmallVector<hw::InstanceOp> instances;
  top.walk([&](hw::InstanceOp instance) {
    if (changed.contains(instance.getModuleNameAttr().getAttr()))
      instances.push_back(instance);
  });
  for (auto instance : instances) {
    OpBuilder b(instance);
    SmallVector<Value> operands;
    for (auto operand : instance.getInputs()) {
      if (auto type = getIntegerFor(operand.getType()))
        operand = hw::BitcastOp::create(b, instance.getLoc(), type, operand);
      operands.push_back(operand);
    }
    SmallVector<Type> resultTypes;
    for (auto type : instance.getResultTypes())
      resultTypes.push_back(getIntegerFor(type) ? getIntegerFor(type) : type);
    auto newInstance = hw::InstanceOp::create(
        b, instance.getLoc(), resultTypes, instance.getInstanceNameAttr(),
        instance.getModuleNameAttr(), operands, instance.getArgNamesAttr(),
        instance.getResultNamesAttr(), instance.getParametersAttr(),
        instance.getInnerSymAttr(), instance.getDoNotPrintAttr());
    newInstance->setDiscardableAttrs(instance->getDiscardableAttrDictionary());
    b.setInsertionPointAfter(newInstance);
    for (auto [old, result] :
         llvm::zip(instance.getResults(), newInstance.getResults())) {
      Value value = result;
      if (old.getType() != result.getType())
        value =
            hw::BitcastOp::create(b, instance.getLoc(), old.getType(), result);
      old.replaceAllUsesWith(value);
    }
    instance.erase();
  }
}
