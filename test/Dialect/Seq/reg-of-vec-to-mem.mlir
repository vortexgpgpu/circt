// RUN: circt-opt %s --seq-reg-of-vec-to-mem | FileCheck %s

// CHECK-LABEL: hw.module private @complex_mem
hw.module private @complex_mem(in %CLK : i1, in %D : i46, in %ADR : i13, in %WE : i1, in %ME : i1, out Q : i46) {
    %true = hw.constant true
    %c0_i46 = hw.constant 0 : i46
    %0 = comb.xor %WE, %true : i1
    %1 = comb.and %ME, %0 : i1
    %2 = hw.array_get %mem_core[%ADR] : !hw.array<8192xi46>, i13
    %3 = comb.xor %1, %true : i1
    %4 = comb.mux %3, %c0_i46, %2 : i46
    %5 = seq.to_clock %CLK
    %6 = comb.mux %1, %4, %Q_int : i46
    %Q_int = seq.firreg %6 clock %5 : i46
    // NOTE: The transformation cannot identify the memory read enable signal.
    %7 = comb.and %ME, %WE : i1
    %8 = hw.array_inject %mem_core[%ADR], %D : !hw.array<8192xi46>, i13
    %9 = comb.mux %7, %8, %mem_core : !hw.array<8192xi46>
    %mem_core = seq.firreg %9 clock %5 : !hw.array<8192xi46>
    hw.output %Q_int : i46
}

// CHECK: %[[clock:.+]] = seq.to_clock %CLK
// CHECK: %[[V6:.+]] = comb.and %ME, %WE : i1
// CHECK: %mem_core = seq.firmem 0, 1, undefined, undefined : <8192 x 46, mask 1>
// CHECK: %[[READ:.+]] = seq.firmem.read_port %mem_core[%ADR], clock %[[clock]] enable %true
// CHECK: seq.firmem.write_port %mem_core[%ADR] = %D, clock %[[clock]] enable %[[V6]]
// CHECK-NOT: seq.firreg %{{.*}} : !hw.array<8192xi46>
// CHECK-NOT: hw.array_get
// CHECK-NOT: hw.array_inject

// Simple test case
// CHECK-LABEL: hw.module @simple_mem
hw.module @simple_mem(in %clk : i1, in %addr : i2, in %data : i8, in %we : i1, out out : i8) {
    %clock = seq.to_clock %clk
    %true = hw.constant true
    %read = hw.array_get %mem[%addr] : !hw.array<4xi8>, i2
    %write = hw.array_inject %mem[%addr], %data : !hw.array<4xi8>, i2
    %next = comb.mux %we, %write, %mem : !hw.array<4xi8>
    %mem = seq.firreg %next clock %clock : !hw.array<4xi8>
    hw.output %read : i8
}

// CHECK: %[[clock:.+]] = seq.to_clock %clk
// CHECK: %mem = seq.firmem 0, 1, undefined, undefined : <4 x 8, mask 1>
// CHECK: %[[READ:.+]] = seq.firmem.read_port %mem[%addr], clock %[[clock]] enable %true
// CHECK: seq.firmem.write_port %mem[%addr] = %data, clock %[[clock]] enable %we
// CHECK: hw.output %[[READ]] : i8
// CHECK-NOT: seq.firreg %{{.*}} : !hw.array<8192xi46>
// CHECK-NOT: hw.array_get
// CHECK-NOT: hw.array_inject


hw.module @single_el_mem(in %clk : i1, in %addr : i0, in %data : i8, in %we : i1) {
    %clock = seq.to_clock %clk
    %read = hw.array_get %msingel[%addr] : !hw.array<1xi8>, i0
    %write = hw.array_inject %msingel[%addr], %data : !hw.array<1xi8>, i0
    %next = comb.mux %we, %write, %msingel : !hw.array<1xi8>
    %msingel = seq.firreg %next clock %clock : !hw.array<1xi8>
}

// CHECK: %[[clock:.+]] = seq.to_clock %clk
// CHECK: %msingel = seq.firmem 0, 1, undefined, undefined : <1 x 8, mask 1>
// CHECK: %[[TRUE:.+]] = hw.constant true
// CHECK: %[[FALSE:.+]] = hw.constant false
// CHECK: %[[READ:.+]] = seq.firmem.read_port %msingel[%[[FALSE]]], clock %[[clock]] enable %[[TRUE]]
// CHECK: %[[FALSE:.+]] = hw.constant false
// CHECK: seq.firmem.write_port %msingel[%[[FALSE]]] = %data, clock %[[clock]] enable %we
// CHECK-NOT: seq.firreg %{{.*}} : !hw.array<8192xi46>
// CHECK-NOT: hw.array_get
// CHECK-NOT: hw.array_inject

// Test that transformation is skipped when mux has multiple uses
// CHECK-LABEL: hw.module @shared_mux_test(
hw.module @shared_mux_test(in %clk: i1, in %addr: i2, in %data: i8, in %we: i1, out other_out: !hw.array<4xi8>) {
  %clock = seq.to_clock %clk
  %write = hw.array_inject %mem[%addr], %data : !hw.array<4xi8>, i2
  %next = comb.mux %we, %write, %mem : !hw.array<4xi8>
  // CHECK: %mem = seq.firreg %{{.*}} clock %{{.*}} : !hw.array<4xi8>
  %mem = seq.firreg %next clock %clock : !hw.array<4xi8>
  
  // Mux result used elsewhere - should prevent transformation
  hw.output %next : !hw.array<4xi8>
}

// Test that transformation is skipped when register has multiple uses
// CHECK-LABEL: hw.module @shared_reg_test(
hw.module @shared_reg_test(in %clk: i1, in %addr: i2, in %data: i8, in %we: i1, out reg_out: !hw.array<4xi8>, out read_out: i8) {
  %clock = seq.to_clock %clk
  %read = hw.array_get %mem[%addr] : !hw.array<4xi8>, i2
  %write = hw.array_inject %mem[%addr], %data : !hw.array<4xi8>, i2
  %next = comb.mux %we, %write, %mem : !hw.array<4xi8>
  // CHECK: %mem = seq.firreg %{{.*}} clock %{{.*}} : !hw.array<4xi8>
  %mem = seq.firreg %next clock %clock : !hw.array<4xi8>
  
  // Register used elsewhere - should prevent transformation
  hw.output %mem, %read : !hw.array<4xi8>, i8
}
// The memory keeps the SV attributes its register was declared with.
// CHECK-LABEL: hw.module @mem_attributes
// CHECK: seq.firmem 0, 1, undefined, undefined {sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">]} : <4 x 8, mask 1>
hw.module @mem_attributes(in %clk : i1, in %addr : i2, in %data : i8, in %we : i1, out out : i8) {
    %clock = seq.to_clock %clk
    %read = hw.array_get %mem[%addr] : !hw.array<4xi8>, i2
    %write = hw.array_inject %mem[%addr], %data : !hw.array<4xi8>, i2
    %next = comb.mux %we, %write, %mem : !hw.array<4xi8>
    %mem = seq.firreg %next clock %clock {sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">]} : !hw.array<4xi8>
    hw.output %read : i8
}

// Registered read data that is also written back: the write takes the data
// from the read port that replaces the register.
// CHECK-LABEL: hw.module @data_reg_write_data
// CHECK: %mem = seq.firmem 1, 1, old, undefined : <4 x 8, mask 1>
// CHECK: [[RDATA:%.+]] = seq.firmem.read_port %mem[%raddr], clock %{{.+}} enable %re
// CHECK: seq.firmem.write_port %mem[%waddr] = [[RDATA]], clock %{{.+}} enable %we
// CHECK-NOT: seq.firreg
// CHECK: hw.output [[RDATA]] : i8
hw.module @data_reg_write_data(in %clk : i1, in %raddr : i2, in %waddr : i2, in %re : i1, in %we : i1, out out : i8) {
  %clock = seq.to_clock %clk
  %read = hw.array_get %mem[%raddr] : !hw.array<4xi8>, i2
  %hold = comb.mux %re, %read, %rdata_r : i8
  %rdata_r = seq.firreg %hold clock %clock : i8
  %write = hw.array_inject %mem[%waddr], %rdata_r : !hw.array<4xi8>, i2
  %next = comb.mux %we, %write, %mem : !hw.array<4xi8>
  %mem = seq.firreg %next clock %clock : !hw.array<4xi8>
  hw.output %rdata_r : i8
}

// Column writes, one of them of a slice of the registered read data.
// CHECK-LABEL: hw.module @data_reg_column_write
// CHECK: %mem = seq.firmem 1, 1, old, undefined : <4 x 16, mask 2>
// CHECK: [[RDATA:%.+]] = seq.firmem.read_port %mem[%raddr], clock %{{.+}} enable %re
// CHECK-DAG: [[LO:%.+]] = comb.extract [[RDATA]] from 0 : (i16) -> i8
// CHECK-DAG: [[HI:%.+]] = comb.extract %wdata from 8 : (i16) -> i8
// CHECK-DAG: [[DATA:%.+]] = comb.concat [[HI]], [[LO]] : i8, i8
// CHECK-DAG: [[MASK:%.+]] = comb.concat %we1, %we0 : i1, i1
// CHECK: seq.firmem.write_port %mem[%waddr] = [[DATA]], clock %{{.+}} enable %{{.+}} mask [[MASK]]
// CHECK-NOT: seq.firreg
// CHECK: hw.output [[RDATA]] : i16
hw.module @data_reg_column_write(in %clk : i1, in %raddr : i2, in %waddr : i2, in %re : i1, in %we0 : i1, in %we1 : i1, in %wdata : i16, out out : i16) {
  %clock = seq.to_clock %clk
  %read = hw.array_get %mem[%raddr] : !hw.array<4xi16>, i2
  %hold = comb.mux %re, %read, %rdata_r : i16
  %rdata_r = seq.firreg %hold clock %clock : i16
  // Column 0 from the read data.
  %old0 = hw.array_get %mem[%waddr] : !hw.array<4xi16>, i2
  %keep0 = comb.extract %old0 from 8 : (i16) -> i8
  %new0 = comb.extract %rdata_r from 0 : (i16) -> i8
  %elem0 = comb.concat %keep0, %new0 : i8, i8
  %write0 = hw.array_inject %mem[%waddr], %elem0 : !hw.array<4xi16>, i2
  %v0 = comb.mux %we0, %write0, %mem : !hw.array<4xi16>
  // Column 1 from the write data.
  %old1 = hw.array_get %v0[%waddr] : !hw.array<4xi16>, i2
  %keep1 = comb.extract %old1 from 0 : (i16) -> i8
  %new1 = comb.extract %wdata from 8 : (i16) -> i8
  %elem1 = comb.concat %new1, %keep1 : i8, i8
  %write1 = hw.array_inject %v0[%waddr], %elem1 : !hw.array<4xi16>, i2
  %next = comb.mux %we1, %write1, %v0 : !hw.array<4xi16>
  %mem = seq.firreg %next clock %clock : !hw.array<4xi16>
  hw.output %rdata_r : i16
}

// The registered read data enables the write.
// CHECK-LABEL: hw.module @data_reg_write_enable
// CHECK: %mem = seq.firmem 1, 1, old, undefined : <4 x 1, mask 1>
// CHECK: [[RDATA:%.+]] = seq.firmem.read_port %mem[%raddr], clock %{{.+}} enable %re
// CHECK: seq.firmem.write_port %mem[%waddr] = %wdata, clock %{{.+}} enable [[RDATA]]
// CHECK-NOT: seq.firreg
// CHECK: hw.output [[RDATA]] : i1
hw.module @data_reg_write_enable(in %clk : i1, in %raddr : i2, in %waddr : i2, in %re : i1, in %wdata : i1, out out : i1) {
  %clock = seq.to_clock %clk
  %read = hw.array_get %mem[%raddr] : !hw.array<4xi1>, i2
  %hold = comb.mux %re, %read, %rdata_r : i1
  %rdata_r = seq.firreg %hold clock %clock : i1
  %write = hw.array_inject %mem[%waddr], %wdata : !hw.array<4xi1>, i2
  %next = comb.mux %rdata_r, %write, %mem : !hw.array<4xi1>
  %mem = seq.firreg %next clock %clock : !hw.array<4xi1>
  hw.output %rdata_r : i1
}

// A version of the array observed outside the write chain keeps the register.
// CHECK-LABEL: hw.module @version_observed
// CHECK-NOT: seq.firmem
// CHECK: %mem = seq.firreg
// CHECK: hw.output
hw.module @version_observed(in %clk : i1, in %addr : i2, in %data : i8, in %we : i1, out out : i8, out next : !hw.array<4xi8>) {
  %clock = seq.to_clock %clk
  %read = hw.array_get %mem[%addr] : !hw.array<4xi8>, i2
  %write = hw.array_inject %mem[%addr], %data : !hw.array<4xi8>, i2
  %next = comb.mux %we, %write, %mem : !hw.array<4xi8>
  %mem = seq.firreg %next clock %clock : !hw.array<4xi8>
  hw.output %read, %next : i8, !hw.array<4xi8>
}

// The element a write starts from observed outside the write chain keeps the
// register.
// CHECK-LABEL: hw.module @element_observed
// CHECK-NOT: seq.firmem
// CHECK: %mem = seq.firreg
// CHECK: hw.output
hw.module @element_observed(in %clk : i1, in %raddr : i2, in %waddr : i2, in %data : i8, in %we : i1, out out : i8, out low : i4) {
  %clock = seq.to_clock %clk
  %read = hw.array_get %mem[%raddr] : !hw.array<4xi8>, i2
  %old = hw.array_get %mem[%waddr] : !hw.array<4xi8>, i2
  %keep = comb.extract %old from 0 : (i8) -> i4
  %new = comb.extract %data from 4 : (i8) -> i4
  %elem = comb.concat %new, %keep : i4, i4
  %write = hw.array_inject %mem[%waddr], %elem : !hw.array<4xi8>, i2
  %next = comb.mux %we, %write, %mem : !hw.array<4xi8>
  %mem = seq.firreg %next clock %clock : !hw.array<4xi8>
  hw.output %read, %keep : i8, i4
}
