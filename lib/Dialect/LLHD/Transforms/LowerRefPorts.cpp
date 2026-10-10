//===- LowerRefPorts.cpp - Turn signal reference ports into value ports ---===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Interface ports without a modport, and other `inout`-like connections, are
// imported as `!llhd.ref<T>` module ports. A module that only probes such a
// port reads a value and a module that only drives it once produces a value,
// so the reference can be replaced by an input or output port. A module that
// drives it once and also probes it (reading back an interface signal it
// drives) gets both: an output for the driven value and an input for the
// probed one. The probe or drive moves to the instantiation site, where the
// signal is local and can be promoted by Sig2Reg.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/HW/HWInstanceGraph.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/LLHD/LLHDOps.h"
#include "circt/Dialect/LLHD/LLHDPasses.h"
#include "mlir/IR/Builders.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "llhd-lower-ref-ports"

namespace circt {
namespace llhd {
#define GEN_PASS_DEF_LOWERREFPORTSPASS
#include "circt/Dialect/LLHD/LLHDPasses.h.inc"
} // namespace llhd
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace llhd;

namespace {
struct LowerRefPortsPass
    : public llhd::impl::LowerRefPortsPassBase<LowerRefPortsPass> {
  void runOnOperation() override;
  void processModule(hw::HWModuleOp module, hw::InstanceGraph &graph);
};

/// How a reference port is used inside its module.
struct PortUse {
  SmallVector<ProbeOp> probes;
  SmallVector<DriveOp> drives;
  bool other = false;
};
} // namespace

static PortUse classify(BlockArgument arg) {
  PortUse use;
  for (auto &operand : arg.getUses()) {
    auto *user = operand.getOwner();
    if (auto probe = dyn_cast<ProbeOp>(user)) {
      use.probes.push_back(probe);
      continue;
    }
    if (auto drive = dyn_cast<DriveOp>(user);
        drive && operand.getOperandNumber() == 0 && !drive.getEnable() &&
        drive.getTime().getDefiningOp<ConstantTimeOp>()) {
      use.drives.push_back(drive);
      continue;
    }
    use.other = true;
  }
  return use;
}

void LowerRefPortsPass::processModule(hw::HWModuleOp module,
                                      hw::InstanceGraph &graph) {
  if (module.isPublic())
    return;
  auto *node = graph.lookup(module);
  for (auto *use : node->uses())
    if (!use->getInstance<hw::InstanceOp>())
      return;

  auto *body = module.getBodyBlock();
  SmallVector<unsigned> readPorts;                      // input ids
  SmallVector<std::pair<unsigned, DriveOp>> writePorts; // input id, drive
  // Ports both probed and driven once keep their input (for the probed value)
  // and also get an output (for the driven one).
  llvm::SmallDenseSet<unsigned> readWritePorts;
  for (unsigned i = 0, e = module.getNumInputPorts(); i < e; ++i) {
    auto arg = body->getArgument(i);
    if (!isa<RefType>(arg.getType()))
      continue;
    auto use = classify(arg);
    if (use.other)
      continue;
    if (use.drives.empty() && !use.probes.empty()) {
      readPorts.push_back(i);
    } else if (use.drives.size() == 1) {
      writePorts.push_back({i, use.drives[0]});
      if (!use.probes.empty()) {
        readPorts.push_back(i);
        readWritePorts.insert(i);
      }
    }
  }
  if (readPorts.empty() && writePorts.empty())
    return;

  LLVM_DEBUG(llvm::dbgs() << "Lowering " << readPorts.size() << " read and "
                          << writePorts.size() << " write ref ports of "
                          << module.getModuleName() << "\n");

  // The names of the outputs created for driven ports, taken before an input
  // that stays for the probed value is renamed.
  SmallDenseMap<unsigned, StringAttr> writeNames;
  for (auto [i, drive] : writePorts)
    writeNames[i] = module.getInputNameAttr(i);

  // Read-only ports: retype to the nested value type, probes become the value.
  // An input that also had a drive keeps the probed value under a new name.
  auto type = module.getHWModuleType();
  SmallVector<hw::ModulePort> ports(type.getPorts());
  for (auto i : readPorts) {
    auto arg = body->getArgument(i);
    auto valueType = cast<RefType>(arg.getType()).getNestedType();
    for (auto *user : llvm::make_early_inc_range(arg.getUsers())) {
      auto probe = dyn_cast<ProbeOp>(user);
      if (!probe)
        continue; // the drive of a read-write port, lowered below
      probe.replaceAllUsesWith(arg);
      probe.erase();
    }
    arg.setType(valueType);
    auto &port = ports[type.getPortIdForInputId(i)];
    port.type = valueType;
    if (readWritePorts.contains(i))
      port.name = StringAttr::get(&getContext(), port.name.getValue() + "_in");
  }
  module.setHWModuleType(hw::ModuleType::get(&getContext(), ports));

  // Write-only ports: the driven value becomes a new output.
  SmallVector<TimeAttr> writeDelays;
  if (!writePorts.empty()) {
    SmallVector<std::pair<unsigned, hw::PortInfo>> insertOutputs;
    SmallVector<unsigned> eraseInputs;
    SmallVector<Value> newOutputs;
    unsigned numOutputs = module.getNumOutputPorts();
    for (auto [i, drive] : writePorts) {
      hw::PortInfo info;
      info.name = writeNames.lookup(i);
      info.type = drive.getValue().getType();
      info.dir = hw::ModulePort::Direction::Output;
      insertOutputs.push_back({numOutputs, info});
      if (!readWritePorts.contains(i))
        eraseInputs.push_back(i);
      newOutputs.push_back(drive.getValue());
      auto timeOp = drive.getTime().getDefiningOp<ConstantTimeOp>();
      writeDelays.push_back(timeOp.getValueAttr());
      drive.erase();
      if (timeOp->use_empty())
        timeOp->erase();
    }
    module.modifyPorts({}, insertOutputs, eraseInputs, {});
    // modifyPorts updates the signature; erase the dead block arguments and
    // append the new values to the terminator.
    for (auto i : llvm::reverse(eraseInputs))
      body->eraseArgument(i);
    auto outputOp = cast<hw::OutputOp>(body->getTerminator());
    SmallVector<Value> operands(outputOp.getOperands());
    operands.append(newOutputs);
    outputOp->setOperands(operands);
  }

  // Update every instance.
  for (auto *use : llvm::make_early_inc_range(node->uses())) {
    auto inst = use->getInstance<hw::InstanceOp>();
    OpBuilder builder(inst);
    for (auto i : readPorts)
      inst.setOperand(
          i, ProbeOp::create(builder, inst.getLoc(), inst.getOperand(i)));
    if (writePorts.empty())
      continue;
    SmallVector<Value> operands;
    SmallVector<Value> refs;
    unsigned w = 0;
    for (unsigned i = 0, e = inst.getNumOperands(); i < e; ++i) {
      if (w < writePorts.size() && writePorts[w].first == i) {
        ++w;
        if (!readWritePorts.contains(i)) {
          refs.push_back(inst.getOperand(i));
          continue;
        }
        // The operand is already the probe created above; drive the probed
        // signal from the new output.
        refs.push_back(inst.getOperand(i).getDefiningOp<ProbeOp>().getSignal());
      }
      operands.push_back(inst.getOperand(i));
    }
    auto newInst = hw::InstanceOp::create(
        builder, inst.getLoc(), module, inst.getInstanceNameAttr(), operands,
        inst.getParameters(), inst.getInnerSymAttr());
    for (auto attr : inst->getDiscardableAttrs())
      newInst->setAttr(attr.getName(), attr.getValue());
    unsigned oldResults = inst.getNumResults();
    for (unsigned r = 0; r < oldResults; ++r)
      inst.getResult(r).replaceAllUsesWith(newInst.getResult(r));
    builder.setInsertionPointAfter(newInst);
    for (unsigned k = 0; k < refs.size(); ++k) {
      auto time =
          ConstantTimeOp::create(builder, inst.getLoc(), writeDelays[k]);
      DriveOp::create(builder, inst.getLoc(), refs[k],
                      newInst.getResult(oldResults + k), time, Value());
    }
    use->getParent()->addInstance(newInst, node);
    use->erase();
    inst.erase();
  }
}

void LowerRefPortsPass::runOnOperation() {
  auto &graph = getAnalysis<hw::InstanceGraph>();
  // Children first: lowering a child's ports turns the parent's forwarding of
  // its own reference port into a probe or drive at the instance.
  SmallVector<hw::HWModuleOp> order;
  for (auto *node : llvm::post_order(&graph))
    if (auto module =
            dyn_cast_or_null<hw::HWModuleOp>(node->getModule().getOperation()))
      order.push_back(module);
  for (auto module : order)
    processModule(module, graph);
  markAnalysesPreserved<hw::InstanceGraph>();
}
