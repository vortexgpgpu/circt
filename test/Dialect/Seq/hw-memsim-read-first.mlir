// RUN: circt-opt -hw-memory-sim %s | FileCheck %s

sv.macro.decl @RANDOM
sv.macro.decl @ENABLE_INITIAL_MEM_
sv.macro.decl @RANDOMIZE_REG_INIT
sv.macro.decl @RANDOMIZE_MEM_INIT

hw.generator.schema @FIRRTLMem, "FIRRTL_Memory", ["depth", "numReadPorts", "numWritePorts", "numReadWritePorts", "readLatency", "writeLatency", "width", "readUnderWrite", "writeUnderWrite", "writeClockIDs", "initFilename", "initIsBinary", "initIsInline"]

// A memory that reads the data from before a write to the same address reads
// in the cycle the address arrives and registers the data, as a read-first
// block RAM does; the data holds while the port is disabled. No address is
// registered.
// CHECK-LABEL: hw.module private @ReadFirst(
// CHECK-NOT:     _R0_addr_d0
// CHECK:         %Memory = sv.reg
// CHECK-NEXT:    [[ELEMENT:%.+]] = sv.array_index_inout %Memory[%R0_addr]
// CHECK-NEXT:    [[DATA:%.+]] = sv.read_inout [[ELEMENT]]
// CHECK-NEXT:    %_R0_data_d0 = sv.reg
// CHECK-NEXT:    sv.always posedge %R0_clk {
// CHECK-NEXT:      sv.if %R0_en {
// CHECK-NEXT:        sv.passign %_R0_data_d0, [[DATA]]
// CHECK:         [[OUT:%.+]] = sv.read_inout %_R0_data_d0
// CHECK:         hw.output [[OUT]]
hw.module.generated @ReadFirst, @FIRRTLMem(in %R0_addr : i4, in %R0_en : i1, in %R0_clk : i1, in %W0_addr : i4, in %W0_en : i1, in %W0_clk : i1, in %W0_data : i16, out R0_data : i16) attributes {depth = 16 : i64, numReadPorts = 1 : ui32, numReadWritePorts = 0 : ui32, numWritePorts = 1 : ui32, readLatency = 1 : ui32, readUnderWrite = 1 : i32, width = 16 : ui32, writeClockIDs = [0 : i32], writeLatency = 1 : ui32, writeUnderWrite = 0 : i32, initFilename = "", initIsBinary = false, initIsInline = false}

// Ports that the same value clocks use the same clock, so that a synthesis
// tool sees one clock domain and keeps the read-first behavior; with clocks it
// must take as independent, a read colliding with a write is undefined.
// CHECK-LABEL: hw.module private @ReadFirstCommonClock(
// CHECK:         sv.always posedge %R0_clk {
// CHECK-NEXT:      sv.if %R0_en {
// CHECK:         sv.always posedge %R0_clk {
// CHECK-NEXT:      sv.if %W0_en {
// CHECK-NOT:     posedge %W0_clk
hw.module.generated @ReadFirstCommonClock, @FIRRTLMem(in %R0_addr : i4, in %R0_en : i1, in %R0_clk : i1, in %W0_addr : i4, in %W0_en : i1, in %W0_clk : i1, in %W0_data : i16, out R0_data : i16) attributes {clockIDs = [0 : i32, 0 : i32], depth = 16 : i64, numReadPorts = 1 : ui32, numReadWritePorts = 0 : ui32, numWritePorts = 1 : ui32, readLatency = 1 : ui32, readUnderWrite = 1 : i32, width = 16 : ui32, writeClockIDs = [0 : i32], writeLatency = 1 : ui32, writeUnderWrite = 0 : i32, initFilename = "", initIsBinary = false, initIsInline = false}

// Ports clocked by different values keep their own clocks.
// CHECK-LABEL: hw.module private @ReadFirstTwoClocks(
// CHECK:         sv.always posedge %R0_clk {
// CHECK:         sv.always posedge %W0_clk {
hw.module.generated @ReadFirstTwoClocks, @FIRRTLMem(in %R0_addr : i4, in %R0_en : i1, in %R0_clk : i1, in %W0_addr : i4, in %W0_en : i1, in %W0_clk : i1, in %W0_data : i16, out R0_data : i16) attributes {clockIDs = [0 : i32, 1 : i32], depth = 16 : i64, numReadPorts = 1 : ui32, numReadWritePorts = 0 : ui32, numWritePorts = 1 : ui32, readLatency = 1 : ui32, readUnderWrite = 1 : i32, width = 16 : ui32, writeClockIDs = [1 : i32], writeLatency = 1 : ui32, writeUnderWrite = 0 : i32, initFilename = "", initIsBinary = false, initIsInline = false}
