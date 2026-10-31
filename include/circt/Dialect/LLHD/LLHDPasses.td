//===----------------------------------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_DIALECT_LLHD_LLHDPASSES_TD
#define CIRCT_DIALECT_LLHD_LLHDPASSES_TD

include "mlir/Pass/PassBase.td"

def InlineCallsPass : Pass<"llhd-inline-calls", "ModuleOp"> {
  let summary = "Inline all function calls in HW modules";
  let description = [{
    Inlines `func.call` operations nested within `llhd.combinational`,
    `llhd.process`, and `llhd.final` ops within `hw.module`s. The `func.func`
    definitions are left untouched. After the inlining, MLIR's symbol DCE pass
    may be used to eliminate the function definitions where possible. Recursive
    calls are left unchanged.

    This pass expects the `llhd-wrap-procedural-ops` pass to have already run.
    Otherwise call ops immediately in the module body, a graph region, cannot be
    inlined at all since the graph region cannot accommodate the function's
    control flow.
  }];
  let statistics = [
    Statistic<
      "numInlined", "calls-inlined", "Number of call ops that were inlined"
    >,
  ];
}

def InferNoAliasPortsPass : Pass<"llhd-infer-noalias-ports",
                                 "mlir::ModuleOp"> {
  let summary = "Mark reference ports that no other port aliases";
  let description = [{
    A reference port of a module may be bound to the same signal as another of
    its reference ports, so Mem2Reg and HoistSignals cannot promote or hoist
    the drives of a process that accesses more than one port: the drives of
    two such ports may have to stay ordered. When every instance of a private
    module is known, the signal each port is bound to can be traced: to a
    signal declared in the instantiating module, or to a port of that module,
    which only aliases another of its ports if neither is marked. A port that
    is bound, at every instance, to a signal no other reference port of the
    instance is bound to is marked `llhd.noalias`, which lets these passes
    treat it like a signal declared outside the process. Modules are
    processed parents first; the marks of a previous run are recomputed.
  }];
}

def LowerRefPortsPass : Pass<"llhd-lower-ref-ports", "mlir::ModuleOp"> {
  let summary = "Replace signal reference ports with value ports";
  let description = [{
    Interface ports without a modport and other `inout`-like connections are
    imported as `!llhd.ref<T>` module ports. If a private module only probes
    such a port, it becomes an input of type `T` and the probe moves to every
    instantiation. If the module only drives it, once and unconditionally, the
    driven value becomes a new output and the drive moves to every
    instantiation. Modules are processed children first, so references that
    are only forwarded through a hierarchy of modules are lowered all the way
    up to the module that declares the signal, where Sig2Reg can promote it.
  }];
}

def Sig2Reg : Pass<"llhd-sig2reg", "hw::HWModuleOp"> {
  let summary = "promote LLHD signals to SSA values";
  let description = [{
    A signal that a register drives, and that is also driven once with the
    value it starts out with, as an `initial` block assigns it, holds the
    register: the starting value becomes the register's preset, or, loaded
    from a file by `$readmemh`/`$readmemb`, the file the register array is
    loaded from, and the signal is promoted to the register's value.
  }];

  let dependentDialects = ["circt::hw::HWDialect", "circt::comb::CombDialect",
                           "circt::seq::SeqDialect"];
}

def Mem2RegPass : Pass<"llhd-mem2reg"> {
  let summary = "Promotes memory and signal slots into values.";
  let dependentDialects = [
    "comb::CombDialect",
    "hw::HWDialect",
    "mlir::cf::ControlFlowDialect",
  ];
}

def HoistSignalsPass : Pass<"llhd-hoist-signals"> {
  let summary = "Hoist probes and promote drives to process results";
  let dependentDialects = ["mlir::arith::ArithDialect"];
}

def LowerProcessesPass : Pass<"llhd-lower-processes", "hw::HWModuleOp"> {
  let summary = "Convert process ops to combinational ops where possible";
}

def DeseqPass : Pass<"llhd-deseq", "hw::HWModuleOp"> {
  let summary = "Convert sequential processes to registers";
  let dependentDialects = [
    "comb::CombDialect",
    "hw::HWDialect",
    "seq::SeqDialect",
  ];
}

def CombineDrivesPass : Pass<"llhd-combine-drives", "hw::HWModuleOp"> {
  let summary = "Combine scalar drives into aggregate drives";
  let description = [{
    If individual drives cover all of an aggregate signal's fields, merge them
    into a single drive of the whole aggregate value.
  }];
  let dependentDialects = [
    "comb::CombDialect",
    "hw::HWDialect",
  ];
}

def WrapProceduralOpsPass : Pass<"llhd-wrap-procedural-ops", "hw::HWModuleOp"> {
  let summary = "Wrap procedural ops in modules to make them inlinable";
  let description = [{
    Operations such as `func.call` or `scf.if` may appear in an `hw.module` body
    directly. They cannot be inlined into the module though, since the inlined
    function or result of converting the SCF ops to the CF dialect may create
    control-flow operations with multiple blocks. This pass wraps such
    operations in `llhd.combinational` ops to give them an SSACFG region to
    inline into.
  }];
  let dependentDialects = [
    "llhd::LLHDDialect",
  ];
  let statistics = [
    Statistic<
      "numOpsWrapped", "ops-wrapped", "Number of procedural ops wrapped"
    >,
  ];
}

def RemoveControlFlowPass : Pass<"llhd-remove-control-flow", "hw::HWModuleOp"> {
  let summary = "Remove acyclic control flow and replace block args with muxes";
  let description = [{
    Remove the control flow in `llhd.combinational` operations by merging all
    blocks into the entry block and replacing block arguments with multiplexers.
    This requires the control flow to be acyclic, for example by unrolling all
    loops beforehand. Additionally, since this moves operations from
    conditionally executed blocks into the unconditionally executed entry block,
    all operations must be side-effect free.
  }];
  let dependentDialects = [
    "comb::CombDialect",
    "hw::HWDialect",
    "mlir::cf::ControlFlowDialect",
  ];
}

def UnrollLoopsPass : Pass<"llhd-unroll-loops", "hw::HWModuleOp"> {
  let summary = "Unroll control flow loops with static bounds";
  let description = [{
    Unroll loops in `llhd.combinational` and `llhd.process` operations by
    replicating the loop body and replacing induction variables with constants.
    The loop bounds must be known at compile time. Loops in processes, such as
    a reset loop over the elements of an array register in a clocked process,
    must be unrolled before `llhd-deseq` can detect the register. A loop of
    `max-trip-count` iterations or more is left as it is.
  }];
  let options = [
    Option<"maxTripCount", "max-trip-count", "unsigned", "1024",
           "Unroll only the loops of fewer iterations">
  ];
}

#endif // CIRCT_DIALECT_LLHD_LLHDPASSES_TD
