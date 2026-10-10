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
// probed one. A module that drives disjoint constant slices of it (the bits,
// array elements or struct fields it owns, while others drive the rest) gets
// one output per slice. The probe or drive moves to the instantiation site,
// where the signal is local and can be promoted by Sig2Reg.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/HW/HWInstanceGraph.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/LLHD/LLHDOps.h"
#include "circt/Dialect/LLHD/LLHDPasses.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/IR/Matchers.h"
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
  /// Drives of constant projections of the port, one drive per projection.
  SmallVector<std::pair<Operation *, DriveOp>> sliceDrives;
  bool other = false;
};

/// A value the module drives into a port, which becomes an output: either the
/// whole port (`projection` is null) or one constant slice of it.
struct WriteEntry {
  unsigned input;
  DriveOp drive;
  Operation *projection = nullptr;
  StringAttr name;
};
} // namespace

/// A drive the pass can move to the instantiation site: its delay is constant
/// and it has no enable.
static bool isPlainDrive(DriveOp drive, unsigned operandNumber) {
  return operandNumber == 0 && !drive.getEnable() &&
         drive.getTime().getDefiningOp<ConstantTimeOp>();
}

/// The constant index operand of a projection, if it has one.
static Value getProjectionIndex(Operation *op) {
  if (auto extract = dyn_cast<SigExtractOp>(op))
    return extract.getLowBit();
  if (auto get = dyn_cast<SigArrayGetOp>(op))
    return get.getIndex();
  return {};
}

/// A projection of the port selecting a constant slice, that is driven exactly
/// once and used in no other way.
static DriveOp getSliceDrive(Operation *op) {
  if (!isa<SigExtractOp, SigArrayGetOp, SigStructExtractOp>(op))
    return {};
  if (auto index = getProjectionIndex(op))
    if (!index.getDefiningOp<hw::ConstantOp>())
      return {};
  if (!op->getResult(0).hasOneUse())
    return {};
  auto &use = *op->getResult(0).getUses().begin();
  auto drive = dyn_cast<DriveOp>(use.getOwner());
  if (!drive || !isPlainDrive(drive, use.getOperandNumber()) ||
      drive->getBlock() != op->getBlock())
    return {};
  return drive;
}

/// Name of the output carrying the value driven into a slice of a port.
static StringAttr getSliceName(StringAttr port, Operation *op) {
  std::string suffix;
  if (auto field = dyn_cast<SigStructExtractOp>(op))
    suffix = field.getField().str();
  else if (auto index = getProjectionIndex(op))
    suffix = std::to_string(
        index.getDefiningOp<hw::ConstantOp>().getValue().getZExtValue());
  return StringAttr::get(port.getContext(), port.getValue() + "_" + suffix);
}

/// Whether the slices driven through `sliceDrives` are pairwise disjoint.
static bool
slicesAreDisjoint(ArrayRef<std::pair<Operation *, DriveOp>> slices) {
  SmallVector<std::pair<uint64_t, uint64_t>> bits; // [low, high)
  llvm::SmallDenseSet<std::pair<StringAttr, int64_t>> elements;
  for (auto [op, drive] : slices) {
    if (auto extract = dyn_cast<SigExtractOp>(op)) {
      auto low = extract.getLowBit()
                     .getDefiningOp<hw::ConstantOp>()
                     .getValue()
                     .getZExtValue();
      auto width =
          hw::getBitWidth(extract.getResult().getType().getNestedType());
      for (auto [l, h] : bits)
        if (low < h && l < low + width)
          return false;
      bits.push_back({low, low + width});
      continue;
    }
    std::pair<StringAttr, int64_t> key;
    if (auto field = dyn_cast<SigStructExtractOp>(op))
      key = {field.getFieldAttr(), -1};
    else
      key = {StringAttr{}, (int64_t)getProjectionIndex(op)
                               .getDefiningOp<hw::ConstantOp>()
                               .getValue()
                               .getZExtValue()};
    if (!elements.insert(key).second)
      return false;
  }
  return true;
}

static PortUse classify(BlockArgument arg) {
  PortUse use;
  for (auto &operand : arg.getUses()) {
    auto *user = operand.getOwner();
    if (auto probe = dyn_cast<ProbeOp>(user)) {
      use.probes.push_back(probe);
      continue;
    }
    // Only drives in the module body itself can become outputs: one in a
    // process happens under its control flow, with a value local to it.
    if (user->getBlock() != arg.getOwner()) {
      use.other = true;
      continue;
    }
    if (auto drive = dyn_cast<DriveOp>(user);
        drive && isPlainDrive(drive, operand.getOperandNumber())) {
      use.drives.push_back(drive);
      continue;
    }
    if (auto drive = getSliceDrive(user)) {
      use.sliceDrives.push_back({user, drive});
      continue;
    }
    use.other = true;
  }
  // Outputs follow the order of the slices in the module.
  llvm::sort(use.sliceDrives, [](auto &a, auto &b) {
    return a.first->isBeforeInBlock(b.first);
  });
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
  SmallVector<unsigned> readPorts; // input ids
  SmallVector<WriteEntry> writes;
  // Inputs that remain after lowering: probed ports keep theirs (for the
  // probed value) even when they are also driven.
  llvm::SmallDenseSet<unsigned> keptInputs;
  for (unsigned i = 0, e = module.getNumInputPorts(); i < e; ++i) {
    auto arg = body->getArgument(i);
    if (!isa<RefType>(arg.getType()))
      continue;
    auto use = classify(arg);
    if (use.other)
      continue;
    auto name = module.getInputNameAttr(i);
    // An unused port reads nothing: it becomes a value input like any port
    // that is only probed.
    if (use.drives.empty() && use.sliceDrives.empty()) {
      readPorts.push_back(i);
      keptInputs.insert(i);
    } else if (use.drives.size() == 1 && use.sliceDrives.empty()) {
      writes.push_back({i, use.drives[0], nullptr, name});
      if (!use.probes.empty()) {
        readPorts.push_back(i);
        keptInputs.insert(i);
      }
    } else if (use.drives.empty() && use.probes.empty() &&
               slicesAreDisjoint(use.sliceDrives)) {
      for (auto [op, drive] : use.sliceDrives)
        writes.push_back({i, drive, op, getSliceName(name, op)});
    }
  }
  if (readPorts.empty() && writes.empty())
    return;

  LLVM_DEBUG(llvm::dbgs() << "Lowering " << readPorts.size() << " read and "
                          << writes.size() << " write ref ports of "
                          << module.getModuleName() << "\n");

  // Recreate the driven slices at every instantiation site while the module's
  // projections still exist.
  DenseMap<Operation *, SmallVector<Value>> instanceTargets;
  for (auto *use : node->uses()) {
    auto inst = use->getInstance<hw::InstanceOp>();
    OpBuilder builder(inst);
    auto &targets = instanceTargets[inst];
    for (auto &write : writes) {
      Value ref = inst.getOperand(write.input);
      if (write.projection) {
        IRMapping mapping;
        mapping.map(body->getArgument(write.input), ref);
        if (auto index = getProjectionIndex(write.projection))
          mapping.map(index,
                      builder.clone(*index.getDefiningOp())->getResult(0));
        ref = builder.clone(*write.projection, mapping)->getResult(0);
      }
      targets.push_back(ref);
    }
  }

  // Read ports: retype to the nested value type, probes become the value. An
  // input that also had a drive keeps the probed value under a new name.
  auto type = module.getHWModuleType();
  SmallVector<hw::ModulePort> ports(type.getPorts());
  llvm::SmallDenseSet<unsigned> drivenInputs;
  for (auto &write : writes)
    drivenInputs.insert(write.input);
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
    if (drivenInputs.contains(i))
      port.name = StringAttr::get(&getContext(), port.name.getValue() + "_in");
  }
  module.setHWModuleType(hw::ModuleType::get(&getContext(), ports));

  // Driven ports and slices: the driven values become new outputs.
  SmallVector<TimeAttr> writeDelays;
  SmallVector<unsigned> eraseInputs;
  if (!writes.empty()) {
    SmallVector<std::pair<unsigned, hw::PortInfo>> insertOutputs;
    SmallVector<Value> newOutputs;
    unsigned numOutputs = module.getNumOutputPorts();
    for (auto &write : writes) {
      hw::PortInfo info;
      info.name = write.name;
      info.type = write.drive.getValue().getType();
      info.dir = hw::ModulePort::Direction::Output;
      insertOutputs.push_back({numOutputs, info});
      newOutputs.push_back(write.drive.getValue());
      auto timeOp = write.drive.getTime().getDefiningOp<ConstantTimeOp>();
      writeDelays.push_back(timeOp.getValueAttr());
      write.drive.erase();
      if (timeOp->use_empty())
        timeOp->erase();
      if (write.projection) {
        auto index = getProjectionIndex(write.projection);
        write.projection->erase();
        if (index && index.use_empty())
          index.getDefiningOp()->erase();
      }
    }
    for (auto i : drivenInputs)
      if (!keptInputs.contains(i))
        eraseInputs.push_back(i);
    llvm::sort(eraseInputs);
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
  llvm::SmallDenseSet<unsigned> erased(eraseInputs.begin(), eraseInputs.end());
  for (auto *use : llvm::make_early_inc_range(node->uses())) {
    auto inst = use->getInstance<hw::InstanceOp>();
    OpBuilder builder(inst);
    auto targets = instanceTargets.lookup(inst);
    for (auto i : readPorts)
      inst.setOperand(
          i, ProbeOp::create(builder, inst.getLoc(), inst.getOperand(i)));
    if (writes.empty())
      continue;
    SmallVector<Value> operands;
    for (unsigned i = 0, e = inst.getNumOperands(); i < e; ++i)
      if (!erased.contains(i))
        operands.push_back(inst.getOperand(i));
    auto newInst = hw::InstanceOp::create(
        builder, inst.getLoc(), module, inst.getInstanceNameAttr(), operands,
        inst.getParameters(), inst.getInnerSymAttr());
    for (auto attr : inst->getDiscardableAttrs())
      newInst->setAttr(attr.getName(), attr.getValue());
    unsigned oldResults = inst.getNumResults();
    for (unsigned r = 0; r < oldResults; ++r)
      inst.getResult(r).replaceAllUsesWith(newInst.getResult(r));
    builder.setInsertionPointAfter(newInst);
    for (unsigned k = 0; k < writes.size(); ++k) {
      auto time =
          ConstantTimeOp::create(builder, inst.getLoc(), writeDelays[k]);
      DriveOp::create(builder, inst.getLoc(), targets[k],
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
