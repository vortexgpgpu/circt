// RUN: circt-opt -hw-memory-sim %s | FileCheck %s
// RUN: circt-opt -hw-memory-sim='read-enable-mode=undefined' %s | FileCheck %s
// RUN: circt-opt -hw-memory-sim='read-enable-mode=ignore' %s | FileCheck %s
// RUN: circt-opt -hw-memory-sim='read-enable-mode=zero' %s | FileCheck %s --check-prefix=ZERO

sv.macro.decl @RANDOM
sv.macro.decl @ENABLE_INITIAL_MEM_
sv.macro.decl @RANDOMIZE_REG_INIT
sv.macro.decl @RANDOMIZE_MEM_INIT

hw.generator.schema @FIRRTLMem, "FIRRTL_Memory", ["depth", "numReadPorts", "numWritePorts", "numReadWritePorts", "readLatency", "writeLatency", "width", "readUnderWrite", "writeUnderWrite", "writeClockIDs", "initFilename", "initIsBinary", "initIsInline"]

// A memory that reads the data from before a write to the same address reads
// in the cycle the address arrives and registers the data, as a read-first
// block RAM does. No address is registered. The data of a disabled read
// holds, unless zeros are asked for: then the registered enable selects zero.
// ZERO-LABEL: hw.module private @ReadFirst(
// ZERO:         %Memory = sv.reg
// ZERO-NEXT:    [[ELEMENT:%.+]] = sv.array_index_inout %Memory[%R0_addr]
// ZERO-NEXT:    [[DATA:%.+]] = sv.read_inout [[ELEMENT]]
// ZERO-NEXT:    %_R0_data_d0 = sv.reg
// ZERO-NEXT:    %_R0_data_en_d0 = sv.reg
// ZERO-NEXT:    sv.always posedge %R0_clk {
// ZERO-NEXT:      sv.if %R0_en {
// ZERO-NEXT:        sv.passign %_R0_data_d0, [[DATA]]
// ZERO-NEXT:      }
// ZERO-NEXT:      sv.passign %_R0_data_en_d0, %R0_en
// ZERO-NEXT:    }
// ZERO-NEXT:    [[REG:%.+]] = sv.read_inout %_R0_data_d0
// ZERO-NEXT:    [[EN:%.+]] = sv.read_inout %_R0_data_en_d0
// ZERO-NEXT:    [[ZEROS:%.+]] = hw.constant 0 : i16
// ZERO-NEXT:    [[OUT:%.+]] = comb.mux [[EN]], [[REG]], [[ZEROS]] : i16
// ZERO:         hw.output [[OUT]]
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
// CHECK-NOT:     comb.mux
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

// With a longer latency, the address and enable are registered until the last
// cycle, and with zeros asked for, the enable once more to select them.
// CHECK-LABEL: hw.module private @ReadFirstLatency2(
// CHECK:         [[EN0:%.+]] = sv.read_inout %_R0_en_d0
// CHECK:         sv.if [[EN0]] {
// CHECK-NEXT:      sv.passign %_R0_data_d0
// CHECK-NOT:     comb.mux
// CHECK:         hw.output
// ZERO-LABEL: hw.module private @ReadFirstLatency2(
// ZERO:         [[EN0:%.+]] = sv.read_inout %_R0_en_d0
// ZERO:         sv.if [[EN0]] {
// ZERO-NEXT:      sv.passign %_R0_data_d0
// ZERO-NEXT:    }
// ZERO-NEXT:    sv.passign %_R0_data_en_d0, [[EN0]]
// ZERO:         [[EN1:%.+]] = sv.read_inout %_R0_data_en_d0
// ZERO:         [[OUT:%.+]] = comb.mux [[EN1]], {{%.+}}, {{%.+}} : i16
// ZERO:         hw.output [[OUT]]
hw.module.generated @ReadFirstLatency2, @FIRRTLMem(in %R0_addr : i4, in %R0_en : i1, in %R0_clk : i1, in %W0_addr : i4, in %W0_en : i1, in %W0_clk : i1, in %W0_data : i16, out R0_data : i16) attributes {depth = 16 : i64, numReadPorts = 1 : ui32, numReadWritePorts = 0 : ui32, numWritePorts = 1 : ui32, readLatency = 2 : ui32, readUnderWrite = 1 : i32, width = 16 : ui32, writeClockIDs = [0 : i32], writeLatency = 1 : ui32, writeUnderWrite = 0 : i32, initFilename = "", initIsBinary = false, initIsInline = false}
