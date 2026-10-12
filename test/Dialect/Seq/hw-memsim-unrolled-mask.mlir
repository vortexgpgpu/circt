// RUN: circt-opt -pass-pipeline="builtin.module(hw-memory-sim{disable-mem-randomization disable-reg-randomization})" %s | FileCheck %s

// Without local variables, a masked write is one statement per mask bit
// rather than a loop over them.
module attributes {circt.loweringOptions = "disallowLocalVariables"} {
sv.macro.decl @ENABLE_INITIAL_MEM_
sv.macro.decl @ENABLE_INITIAL_REG_
sv.macro.decl @RANDOM
hw.generator.schema @FIRRTLMem, "FIRRTL_Memory", ["depth", "numReadPorts", "numWritePorts", "numReadWritePorts", "readLatency", "writeLatency", "width", "readUnderWrite", "writeUnderWrite", "writeClockIDs", "initFilename", "initIsBinary", "initIsInline"]

// CHECK-LABEL: hw.module private @Masked
// CHECK-NOT:     sv.for
// CHECK-COUNT-4: sv.passign %{{.+}}, %{{.+}} : i8
// CHECK-NOT:     sv.for
hw.module.generated @Masked, @FIRRTLMem(in %R0_addr: i4, in %R0_en: i1, in %R0_clk: i1, in %W0_addr: i4, in %W0_en: i1, in %W0_clk: i1, in %W0_data: i32, in %W0_mask: i4, out R0_data: i32) attributes {depth = 16 : i64, maskGran = 8 : ui32, numReadPorts = 1 : ui32, numReadWritePorts = 0 : ui32, numWritePorts = 1 : ui32, readLatency = 1 : ui32, readUnderWrite = 0 : i32, width = 32 : ui32, writeClockIDs = [0 : i32], writeLatency = 1 : ui32, writeUnderWrite = 1 : i32, initFilename = "", initIsBinary = false, initIsInline = false}
}
