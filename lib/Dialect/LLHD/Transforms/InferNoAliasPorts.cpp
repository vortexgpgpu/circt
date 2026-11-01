//===- InferNoAliasPorts.cpp - Mark reference ports no other port aliases -===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Marks the reference ports of private modules that are bound, at every
// instance, to a signal no other reference port of the instance is bound to.
// The members of an interface instance passed through an interface port are
// distinct variables, so a process that drives several of them can have its
// drives promoted and hoisted like those of signals declared in the module.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/HW/HWInstanceGraph.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/LLHD/LLHDOps.h"
#include "circt/Dialect/LLHD/LLHDPasses.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "llhd-infer-noalias-ports"

namespace circt {
namespace llhd {
#define GEN_PASS_DEF_INFERNOALIASPORTSPASS
#include "circt/Dialect/LLHD/LLHDPasses.h.inc"
} // namespace llhd
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace llhd;

namespace {
struct InferNoAliasPortsPass
    : public llhd::impl::InferNoAliasPortsPassBase<InferNoAliasPortsPass> {
  void runOnOperation() override;
};

/// The storage a reference operand of an instance is bound to: a signal
/// declared in the instantiating module, a reference port of that module, or
/// something unknown (a null root).
struct Binding {
  Value root;
  bool isPort = false;
  bool noAlias = false;
};
} // namespace

static Binding getBinding(Value ref) {
  auto root = getReferenceRoot(ref);
  if (root.getDefiningOp<SignalOp>())
    return {root};
  if (isModuleRefPort(root))
    return {root, true, isNoAliasPort(root)};
  return {};
}

/// Whether two bindings may refer to overlapping storage. A signal declared in
/// a module is not reachable through its ports, and a port marked
/// `llhd.noalias` is bound to a signal no other port is bound to.
static bool mayAlias(const Binding &a, const Binding &b) {
  if (!a.root || !b.root || a.root == b.root)
    return true;
  return a.isPort && b.isPort && !a.noAlias && !b.noAlias;
}

void InferNoAliasPortsPass::runOnOperation() {
  auto &graph = getAnalysis<hw::InstanceGraph>();
  auto *context = &getContext();
  auto noAliasName = StringAttr::get(context, kNoAliasAttrName);
  auto unit = UnitAttr::get(context);

  // Parents first: a port forwarded from the instantiating module is known not
  // to alias another one only once that module's ports are marked.
  SmallVector<hw::HWModuleOp> order;
  for (auto *node : llvm::post_order(&graph))
    if (auto module =
            dyn_cast_or_null<hw::HWModuleOp>(node->getModule().getOperation()))
      order.push_back(module);

  for (auto module : llvm::reverse(order)) {
    SmallVector<unsigned> refInputs;
    for (unsigned i = 0, e = module.getNumInputPorts(); i < e; ++i)
      if (isa<RefType>(module.getInputTypes()[i]))
        refInputs.push_back(i);
    if (refInputs.empty())
      continue;

    // Ports of a public module, or of one used by something other than an
    // instance, may be bound to anything.
    llvm::SmallDenseSet<unsigned> noAlias(refInputs.begin(), refInputs.end());
    auto *node = graph.lookup(module);
    if (module.isPublic())
      noAlias.clear();
    for (auto *use : node->uses()) {
      auto inst = use->getInstance<hw::InstanceOp>();
      if (!inst) {
        noAlias.clear();
        break;
      }
      SmallVector<Binding> bindings;
      for (auto i : refInputs)
        bindings.push_back(getBinding(inst.getOperand(i)));
      for (auto [a, i] : llvm::enumerate(refInputs))
        for (auto b : llvm::seq<size_t>(0, refInputs.size()))
          if (a != b && mayAlias(bindings[a], bindings[b]))
            noAlias.erase(i);
    }

    LLVM_DEBUG(llvm::dbgs()
               << module.getModuleName() << ": " << noAlias.size() << " of "
               << refInputs.size() << " reference ports unaliased\n");
    SmallVector<Attribute> attrs(module.getAllPortAttrs());
    attrs.resize(module.getNumPorts());
    bool changed = false;
    for (auto i : refInputs) {
      auto portId = module.getPortIdForInputId(i);
      NamedAttrList portAttrs(cast_or_null<DictionaryAttr>(attrs[portId]));
      bool marked = noAlias.contains(i);
      if (marked == bool(portAttrs.get(noAliasName)))
        continue;
      if (marked)
        portAttrs.set(noAliasName, unit);
      else
        portAttrs.erase(noAliasName);
      attrs[portId] = portAttrs.getDictionary(context);
      changed = true;
    }
    if (changed) {
      for (auto &attr : attrs)
        if (!attr)
          attr = DictionaryAttr::get(context);
      module.setAllPortAttrs(attrs);
    }
  }
  markAllAnalysesPreserved();
}
