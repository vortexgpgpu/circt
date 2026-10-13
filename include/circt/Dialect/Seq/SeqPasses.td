//===-- SeqPasses.td - Seq pass definition file ------------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file contains definitions for passes that work on the Seq dialect.
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_DIALECT_SEQ_SEQPASSES
#define CIRCT_DIALECT_SEQ_SEQPASSES

include "mlir/Pass/PassBase.td"

def LowerSeqCompRegCE : Pass<"lower-seq-compreg-ce", "hw::HWModuleOp"> {
  let summary = "Lower seq.compreg.ce to seq.compreg";
  let description = [{
    Lowers seq.compreg.ce to a seq.compreg with the clock enable signal
    built into the next logic, i.e. `next := mux(clock_enable, next, current)`
  }];
  let dependentDialects = ["circt::comb::CombDialect, circt::hw::HWDialect"];
}

def LowerSeqFIFO : Pass<"lower-seq-fifo", "hw::HWModuleOp"> {
  let summary = "Lower seq.fifo ops";
  let dependentDialects = [
    "circt::hw::HWDialect",
    "circt::comb::CombDialect",
    "circt::verif::VerifDialect"
  ];
}

def LowerSeqHLMem: Pass<"lower-seq-hlmem", "hw::HWModuleOp"> {
  let summary = "Lowers seq.hlmem operations.";
  let dependentDialects = ["circt::sv::SVDialect"];
}

def ExternalizeClockGate: Pass<"externalize-clock-gate", "mlir::ModuleOp"> {
  let summary = "Convert seq.clock_gate ops into hw.module.extern instances";
  let dependentDialects = ["circt::hw::HWDialect", "circt::comb::CombDialect"];
  let options = [
    Option<"moduleName", "name", "std::string", "\"CKG\"",
           "Name of the external clock gate module">,
    Option<"inputName", "input", "std::string", "\"I\"",
           "Name of the clock input">,
    Option<"outputName", "output", "std::string", "\"O\"",
           "Name of the gated clock output">,
    Option<"enableName", "enable", "std::string", "\"E\"",
           "Name of the enable input">,
    Option<"testEnableName", "test-enable", "std::string", "\"TE\"",
           "Name of the optional test enable input">,
    Option<"instName", "instance-name", "std::string", "\"ckg\"",
           "Name of the generated instances">
  ];
  let statistics = [
    Statistic<"numClockGatesConverted", "num-clock-gates-converted",
      "Number of clock gates converted to external module instances">
  ];
}

def HWMemSimImpl : Pass<"hw-memory-sim", "ModuleOp"> {
  let summary = "Implement FIRRTMMem memories nodes with simulation model";
  let description = [{
    This pass replaces generated module nodes of type FIRRTLMem with a model
    suitable for simulation.
  }];

  let dependentDialects = [
    "circt::emit::EmitDialect",
    "circt::hw::HWDialect",
    "circt::sv::SVDialect",
  ];

  let options = [
    Option<"disableMemRandomization", "disable-mem-randomization", "bool", "false",
            "Disable emission of memory randomization code">,
    Option<"disableRegRandomization", "disable-reg-randomization", "bool", "false",
            "Disable emission of register randomization code">,
    Option<"replSeqMem", "repl-seq-mem", "bool",
                "false", "Prepare seq mems for macro replacement">,
    Option<"readEnableMode", "read-enable-mode", "::circt::seq::ReadEnableMode",
           "::circt::seq::ReadEnableMode::Undefined",
           "specify the behaviour of the read enable signal", [{
              ::llvm::cl::values(
              clEnumValN(::circt::seq::ReadEnableMode::Ignore, "ignore",
                         "Ignore the read enable signal"),
              clEnumValN(::circt::seq::ReadEnableMode::Zero, "zero",
                         "Output zeros when reads are disabled"),
              clEnumValN(::circt::seq::ReadEnableMode::Undefined, "undefined",
                         "Output X when reads are disbled"))
           }]>,
    Option<"addMuxPragmas", "add-mux-pragmas", "bool", "false",
            "Add mux pragmas to memory reads">,
    Option<"addVivadoRAMAddressConflictSynthesisBugWorkaround",
           "add-vivado-ram-address-conflict-synthesis-bug-workaround", "bool", "false",
            "Add a vivado attribute to specify a ram style of an array register">

   ];
}

def LowerSeqShiftReg : Pass<"lower-seq-shiftreg", "hw::HWModuleOp"> {
  let summary = "Lower seq.shiftreg ops";
  let description = [{
    Default pass for lowering shift register operations. This will lower
    into a chain of `seq.compreg.ce` operations.
    Note that this is _not_ guaranteed to be a performant implementation,
    but instead a default, fallback lowering path which is guaranteed to
    provide a semantically valid path to verilog emissions.
    Users are expected to provide a custom lowering pass to maps `seq.shiftreg`
    operations to target-specific primitives.
  }];
  let dependentDialects = ["circt::hw::HWDialect"];
}

def RegOfVecToMem : Pass<"seq-reg-of-vec-to-mem", "hw::HWModuleOp"> {
  let summary = "Convert register arrays to FIRRTL memories";
  let description = [{
    This pass identifies register arrays that follow memory access patterns
    and converts them to seq.firmem operations. It looks for patterns where:
    1. A register array is updated via array_inject operations
    2. The array is read via array_get operations  
    3. Updates are controlled by enable signals through mux operations
    4. Read and write operations use the same clock
  }];
}

def LowerAggregateRegs : Pass<"seq-lower-aggregate-regs", "hw::HWModuleOp"> {
  let summary = "Keep the value of an aggregate register as an integer";
  let description = [{
    Replaces each `seq.firreg` of an array or struct type with a register of
    an integer of the same bits, bitcast from the next value and to the
    register's uses, its reset and preset values bitcast alike. Aggregate
    operations on the value can then be lowered to bit extracts and
    concatenations (`hw-convert-bitcasts`, `hw-aggregate-to-comb`), as for a
    Verilog-2005 emitter that has no packed arrays or structs.
  }];
  let dependentDialects = ["circt::hw::HWDialect"];
}

def RetimeFirMemReads : Pass<"seq-retime-firmem-reads", "mlir::ModuleOp"> {
  let summary = "Fold the registers of an asynchronous read's address into it";
  let description = [{
    A `seq.firmem` whose reads are asynchronous (read latency 0) and whose
    every read address is computed from registers on the clock of its writes
    reads the same words a cycle earlier instead: each read becomes a read of
    latency 1, clocked by that clock, at the address the registers' next
    values give, and the memory reads its writes' new data (`ruw = new`), as
    the asynchronous read sees a word written on the edge that also moves the
    address. Holds and synchronous resets of the registers are part of their
    next values, so the read is exact on every cycle after the first edge;
    before it, the read holds the memory's power-on output.

    This is what a block RAM or an SRAM macro needs: they only read
    synchronously, so an asynchronous read is otherwise mapped to distributed
    RAM or logic. The address registers are often in another module than
    the memory, which receives the address on a port: the pass inlines the
    private modules between a memory it converts and its address registers
    (`hw-flatten-modules` with `hw-inline-marked`), and only those, unless
    `inline` is off.

    Which memories are converted is the design's decision, stated with the
    synthesis attribute tools already read (`sv.attributes` on the memory):
    - `ram_style = "block"` (also `ramstyle = "M20K"`, `"block"`,
      `syn_ramstyle = "block_ram"`, ...): the memory is converted. If it
      cannot be, the pass fails with the reason: a read-write port, writes on
      several clocks, an address register with an asynchronous reset or on
      another clock, or an address that depends on anything but such
      registers and constants (a module input, a memory read, ...).
    - `ram_style = "distributed"` (also `"registers"`, `"logic"`, `"MLAB"`,
      ...): the memory is left alone.
    - no such attribute: `mode` decides. `off` leaves the memory alone;
      `auto` converts it if it can and it has at least `min-bits` bits.

    `disable` turns the pass off, hints included, warning for each memory
    whose hint it leaves unhonored; it is for comparisons only. `report`
    names a file that receives one line per asynchronous-read memory: its
    size, hint, the decision and its reason.
  }];
  let options = [
    Option<"mode", "mode", "std::string", "\"off\"",
           "Memories without a hint: off (leave alone) or auto">,
    Option<"minBits", "min-bits", "uint64_t", "0",
           "In auto mode, leave unhinted memories of fewer bits alone">,
    Option<"disable", "disable", "bool", "false",
           "Convert nothing, not even memories that ask for block RAM">,
    Option<"report", "report", "std::string", "\"\"",
           "Write a line per asynchronous-read memory to this file">,
    Option<"inlineModules", "inline", "bool", "true",
           "Inline the modules between a memory and its address registers">,
  ];
  let dependentDialects = ["circt::hw::HWDialect", "circt::comb::CombDialect"];
}

def RegConstProp : Pass<"seq-reg-const-prop", "hw::HWModuleOp"> {
  let summary = "Replace the register bits that only hold one constant";
  let description = [{
    Finds the bits of `seq.firreg` registers that only ever hold one constant
    and replaces them with it, keeping the other bits in a narrower register.
    A bit holds a constant `c` when its preset and reset values, if any, are
    `c`, and its next value is `c` or the bit itself, through the module's
    logic, given what is found of the other registers' bits. The analysis is an
    optimistic fixpoint over every bit, like sparse conditional constant
    propagation, so a register that keeps a constant through a feedback loop of
    enables and holds is found. A bit that no constant ever defines, such as a
    register holding its undefined initial value, is not one.

    Synthesis tools do this on flip-flops; it matters before registers are
    turned into something they cannot see through, such as memories.
  }];
  let dependentDialects = ["circt::comb::CombDialect", "circt::hw::HWDialect"];
}

def InferClockPorts : Pass<"seq-infer-clock-ports", "mlir::ModuleOp"> {
  let summary = "Infer `!seq.clock` types for `i1` ports used as clocks";
  let description = [{
    Walks backwards from every `seq.to_clock` through the instance hierarchy
    and retypes the `i1` module and instance ports it passes through to
    `!seq.clock`. Input ports are promoted whenever they are used as a clock;
    output ports only if they are driven by a clock, so combinational logic on
    a clock path (e.g. a gated clock) stays `i1`. Remaining non-clock uses of a
    promoted value are rewired through a single `seq.from_clock`.
  }];
  let dependentDialects = [
    "circt::hw::HWDialect",
    "circt::seq::SeqDialect"
  ];
  let options = [
    Option<"promotePublicPorts", "promote-public-ports", "bool", "true",
           "Also retype ports of publicly visible modules">
  ];
  let statistics = [
    Statistic<"numInputPortsPromoted", "num-input-ports-promoted",
      "Number of input ports retyped to !seq.clock">,
    Statistic<"numOutputPortsPromoted", "num-output-ports-promoted",
      "Number of output ports retyped to !seq.clock">,
    Statistic<"numCastsRemoved", "num-casts-removed",
      "Number of seq.to_clock casts eliminated">
  ];
}

#endif // CIRCT_DIALECT_SEQ_SEQPASSES
