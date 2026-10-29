// RUN: circt-opt --llhd-sig2reg -cse %s | FileCheck %s

func.func @getTime() -> !llhd.time {
  %time = llhd.constant_time <1ns, 0d, 0e>
  return %time : !llhd.time
}

hw.module @basic(in %init : i32, in %cond : i1, in %in0 : i32, in %in1 : i32, out prb1 : i32, out prb2 : i32, out prb3 : i32, out prb4 : i32, out prb5 : i32, out prb6 : i32, out prb7 : i32) {
  %opaque_time = func.call @getTime() : () -> !llhd.time
  %epsilon = llhd.constant_time <0ns, 0d, 1e>
  %delta = llhd.constant_time <0ns, 1d, 0e>

  // Promoted without delay op
  %sig1 = llhd.sig %init : <i32>
  // Promoted with delay op
  %sig2 = llhd.sig %init : <i32>
  // Not promoted because time is opaque, can support if the delay op takes a
  // time value instead of attribute
  %sig3 = llhd.sig %init : <i32>
  // Promoted to %init because no drive present
  %sig4 = llhd.sig %init : <i32>
  // Not promoted because of drive condition
  %sig5 = llhd.sig %init : <i32>
  // Not promoted because a user is in a nested region
  %sig6 = llhd.sig %init : <i32>
  // Not promoted because of multiple drivers
  %sig7 = llhd.sig %init : <i32>

  llhd.drv %sig1, %in0 after %epsilon : i32
  // CHECK: [[DELAY:%.+]] = llhd.delay %in0 by <0ns, 1d, 0e> : i32
  llhd.drv %sig2, %in0 after %delta : i32
  llhd.drv %sig3, %in0 after %opaque_time : i32

  llhd.drv %sig5, %in0 after %epsilon if %cond : i32

  scf.if %cond {
    llhd.drv %sig6, %in0 after %epsilon : i32
  }
  
  llhd.drv %sig7, %in0 after %epsilon : i32
  llhd.drv %sig7, %in1 after %delta : i32

  %prb1 = llhd.prb %sig1 : i32
  %prb2 = llhd.prb %sig2 : i32
  // CHECK: [[PRB3:%.+]] = llhd.prb %sig3
  %prb3 = llhd.prb %sig3 : i32
  %prb4 = llhd.prb %sig4 : i32
  // CHECK: [[PRB5:%.+]] = llhd.prb %sig5
  %prb5 = llhd.prb %sig5 : i32
  // CHECK: [[PRB6:%.+]] = llhd.prb %sig6
  %prb6 = llhd.prb %sig6 : i32
  // CHECK: [[PRB7:%.+]] = llhd.prb %sig7
  %prb7 = llhd.prb %sig7 : i32

  // CHECK: hw.output %in0, [[DELAY]], [[PRB3]], %init, [[PRB5]], [[PRB6]], [[PRB7]] :
  hw.output %prb1, %prb2, %prb3, %prb4, %prb5, %prb6, %prb7 : i32, i32, i32, i32, i32, i32, i32
}

// CHECK-LABEL: hw.module @aliasStatic
hw.module @aliasStatic(in %init : i4, in %in0 : i1, in %in1 : i1, out out: i4) {
  // CHECK-NEXT: [[C_2_I4:%.+]] = hw.constant -2 : i4
  // CHECK-NEXT: [[V0:%.+]] = comb.and %init, [[C_2_I4]] : i4
  // CHECK-NEXT: [[C0_I3:%.+]] = hw.constant 0 : i3
  // CHECK-NEXT: [[V1:%.+]] = comb.concat [[C0_I3]], %in1 : i3, i1
  // CHECK-NEXT: [[V2:%.+]] = comb.or [[V1]], [[V0]] : i4
  // CHECK-NEXT: [[C1_I4:%.+]] = hw.constant 1 : i4
  // CHECK-NEXT: [[C_3_I4:%.+]] = hw.constant -3 : i4
  // CHECK-NEXT: [[V3:%.+]] = comb.and [[V2]], [[C_3_I4]] : i4
  // CHECK-NEXT: [[V4:%.+]] = comb.concat [[C0_I3]], %in0 : i3, i1
  // CHECK-NEXT: [[V5:%.+]] = comb.shl [[V4]], [[C1_I4]] : i4
  // CHECK-NEXT: [[V6:%.+]] = comb.or [[V5]], [[V3]] : i4
  // CHECK-NEXT: [[C2_I4:%.+]] = hw.constant 2 : i4
  // CHECK-NEXT: [[C_5_I4:%.+]] = hw.constant -5 : i4
  // CHECK-NEXT: [[V7:%.+]] = comb.and [[V6]], [[C_5_I4]] : i4
  // CHECK-NEXT: [[V8:%.+]] = comb.shl [[V1]], [[C2_I4]] : i4
  // CHECK-NEXT: [[V9:%.+]] = comb.or [[V8]], [[V7]] : i4
  // CHECK-NEXT: hw.output [[V9]] : i4

  %0 = llhd.constant_time <0ns, 0d, 1e>
  %true = hw.constant true
  %c1_c2 = hw.constant 1 : i2
  %c0_c2 = hw.constant 0 : i2
  %false = hw.constant false
  %out = llhd.sig %init : <i4>
  %3 = llhd.sig.extract %out from %c1_c2 : <i4> -> <i2>
  %6 = llhd.sig.extract %3 from %false : <i2> -> <i1>
  %7 = llhd.sig.extract %3 from %true : <i2> -> <i1>
  llhd.drv %6, %in0 after %0 : i1
  llhd.drv %7, %in1 after %0 : i1
  %4 = llhd.sig.extract %out from %c0_c2 : <i4> -> <i1>
  llhd.drv %4, %in1 after %0 : i1
  %5 = llhd.prb %out : i4
  hw.output %5 : i4
}

// CHECK-LABEL: hw.module @aliasDynamicSuccess
hw.module @aliasDynamicSuccess(in %init : i8, in %in0 : i1, in %in1 : i1, in %idx0 : i2, in %idx1 : i1, out out: i8) {
  // CHECK-NEXT: [[C1_I8:%.+]] = hw.constant 1 : i8
  // CHECK-NEXT: [[C0_I8:%.+]] = hw.constant 0 : i8
  // CHECK-NEXT: [[C0_I6:%.+]] = hw.constant 0 : i6
  // CHECK-NEXT: [[V0:%.+]] = comb.concat [[C0_I6]], %idx0 : i6, i2
  // CHECK-NEXT: [[V1:%.+]] = comb.add [[V0]], [[C0_I8]] : i8
  // CHECK-NEXT: [[C0_I7:%.+]] = hw.constant 0 : i7
  // CHECK-NEXT: [[V2:%.+]] = comb.concat [[C0_I7]], %idx1 : i7, i1
  // CHECK-NEXT: [[V3:%.+]] = comb.add [[V1]], [[V2]] : i8
  // CHECK-NEXT: [[V4:%.+]] = comb.shl [[C1_I8]], [[V3]] : i8
  // CHECK-NEXT: [[C_1_I8:%.+]] = hw.constant -1 : i8
  // CHECK-NEXT: [[V5:%.+]] = comb.xor [[V4]], [[C_1_I8]] : i8
  // CHECK-NEXT: [[V6:%.+]] = comb.and %init, [[V5]] : i8
  // CHECK-NEXT: [[V7:%.+]] = comb.concat [[C0_I7]], %in0 : i7, i1
  // CHECK-NEXT: [[V8:%.+]] = comb.shl [[V7]], [[V3]] : i8
  // CHECK-NEXT: [[V9:%.+]] = comb.or [[V8]], [[V6]] : i8
  // CHECK-NEXT: [[C4_I8:%.+]] = hw.constant 4 : i8
  // CHECK-NEXT: [[V10:%.+]] = comb.add [[V0]], [[C4_I8]] : i8
  // CHECK-NEXT: [[V11:%.+]] = comb.shl [[C1_I8]], [[V10]] : i8
  // CHECK-NEXT: [[V12:%.+]] = comb.xor [[V11]], [[C_1_I8]] : i8
  // CHECK-NEXT: [[V13:%.+]] = comb.and [[V9]], [[V12]] : i8
  // CHECK-NEXT: [[V14:%.+]] = comb.concat [[C0_I7]], %in1 : i7, i1
  // CHECK-NEXT: [[V15:%.+]] = comb.shl [[V14]], [[V10]] : i8
  // CHECK-NEXT: [[V16:%.+]] = comb.or [[V15]], [[V13]] : i8
  // CHECK-NEXT: hw.output [[V16]] : i8

  %0 = llhd.constant_time <0ns, 0d, 1e>
  %c4_c3 = hw.constant 4 : i3
  %c0_c3 = hw.constant 0 : i3
  %out = llhd.sig %init : <i8>
  %3 = llhd.sig.extract %out from %c0_c3 : <i8> -> <i4>
  %4 = llhd.sig.extract %out from %c4_c3 : <i8> -> <i4>
  %5 = llhd.sig.extract %3 from %idx0 : <i4> -> <i2>
  %6 = llhd.sig.extract %5 from %idx1 : <i2> -> <i1>
  %7 = llhd.sig.extract %4 from %idx0 : <i4> -> <i1>
  llhd.drv %6, %in0 after %0 : i1
  llhd.drv %7, %in1 after %0 : i1
  %8 = llhd.prb %out : i8
  hw.output %8 : i8
}

// CHECK-LABEL: hw.module @aliasDynamicFailure
hw.module @aliasDynamicFailure(in %init : i4, in %in0 : i1, in %in1 : i1, in %idx0 : i1, in %idx1 : i1, out out: i4) {
  // CHECK-NEXT: [[TIME:%.+]] = llhd.constant_time <0ns, 0d, 1e>
  // CHECK-NEXT: [[C_2_I2:%.+]] = hw.constant -2 : i2
  // CHECK-NEXT: [[C0_I2:%.+]] = hw.constant 0 : i2
  // CHECK-NEXT: [[OUT:%.+]] = llhd.sig %init : <i4>
  // CHECK-NEXT: [[V1:%.+]] = llhd.sig.extract [[OUT]] from [[C0_I2]] : <i4> -> <i2>
  // CHECK-NEXT: [[V2:%.+]] = llhd.sig.extract [[OUT]] from [[C_2_I2]] : <i4> -> <i2>
  // CHECK-NEXT: [[V3:%.+]] = llhd.sig.extract [[V1]] from %idx0 : <i2> -> <i1>
  // CHECK-NEXT: [[V4:%.+]] = llhd.sig.extract [[V2]] from %idx0 : <i2> -> <i1>
  // CHECK-NEXT: [[V5:%.+]] = llhd.sig.extract [[V2]] from %idx1 : <i2> -> <i1>
  // CHECK-NEXT: llhd.drv [[V3]], %in0 after [[TIME]] : i1
  // CHECK-NEXT: llhd.drv [[V4]], %in1 after [[TIME]] : i1
  // CHECK-NEXT: llhd.drv [[V5]], %in0 after [[TIME]] : i1
  // CHECK-NEXT: [[V6:%.+]] = llhd.prb [[OUT]] : i4
  // CHECK-NEXT: hw.output [[V6]] : i4

  %0 = llhd.constant_time <0ns, 0d, 1e>
  %c2_c2 = hw.constant 2 : i2
  %c0_c2 = hw.constant 0 : i2
  %out = llhd.sig %init : <i4>
  %3 = llhd.sig.extract %out from %c0_c2 : <i4> -> <i2>
  %4 = llhd.sig.extract %out from %c2_c2 : <i4> -> <i2>
  %5 = llhd.sig.extract %3 from %idx0 : <i2> -> <i1>
  %6 = llhd.sig.extract %4 from %idx0 : <i2> -> <i1>
  %7 = llhd.sig.extract %4 from %idx1 : <i2> -> <i1>
  llhd.drv %5, %in0 after %0 : i1
  llhd.drv %6, %in1 after %0 : i1
  llhd.drv %7, %in0 after %0 : i1
  %8 = llhd.prb %out : i4
  hw.output %8 : i4
}

// CHECK-LABEL: @RemoveDriveOnlySignals
hw.module @RemoveDriveOnlySignals(in %d: i42, in %e: i1) {
  %0 = hw.constant 0 : i42
  %1 = llhd.constant_time <0ns, 0d, 1e>
  // CHECK-NOT: llhd.sig
  %a = llhd.sig %0 : <i42>
  %b = llhd.sig %0 : <i42>
  // CHECK-NOT: llhd.drv
  llhd.drv %a, %d after %1 : i42
  llhd.drv %b, %d after %1 if %e : i42
  // CHECK: hw.output
}

// CHECK-LABEL: hw.module @UninitializedFullDrive
hw.module @UninitializedFullDrive(in %value : i4, out out : i4) {
  %time = llhd.constant_time <0ns, 0d, 1e>
  // CHECK-NOT: llhd.sig
  %sig = llhd.sig : <i4>
  llhd.drv %sig, %value after %time : i4
  %read = llhd.prb %sig : i4
  // CHECK: hw.output %value : i4
  hw.output %read : i4
}

// A signal with one immediate whole-value drive is replaced by the driven
// value; probes of projections become the matching aggregate accesses.
// CHECK-LABEL: @SingleWholeDrive
hw.module @SingleWholeDrive(in %v : !hw.array<2xi8>, out a : i8, out b : i4, out c : !hw.array<2xi8>) {
  %t = llhd.constant_time <0ns, 0d, 1e>
  %false = hw.constant false
  %c2_i3 = hw.constant 2 : i3
  %init = hw.aggregate_constant [0 : i8, 0 : i8] : !hw.array<2xi8>
  // CHECK-NOT: llhd.
  // CHECK: [[A:%.+]] = hw.array_get %v[%false]
  // CHECK: [[B:%.+]] = comb.extract [[A]] from 2
  // CHECK: hw.output [[A]], [[B]], %v
  %x = llhd.sig %init : <!hw.array<2xi8>>
  llhd.drv %x, %v after %t : !hw.array<2xi8>
  %e = llhd.sig.array_get %x[%false] : <!hw.array<2xi8>>
  %a = llhd.prb %e : i8
  %s = llhd.sig.extract %e from %c2_i3 : <i8> -> <i4>
  %b = llhd.prb %s : i4
  %c = llhd.prb %x : !hw.array<2xi8>
  hw.output %a, %b, %c : i8, i4, !hw.array<2xi8>
}

// The SV attributes of a promoted signal move to the register holding its
// value, or else to a wire of the signal's name.
// CHECK-LABEL: hw.module @KeepAttributes
hw.module @KeepAttributes(in %clk : !seq.clock, in %a : i8, in %b : i8, out prod : i8, out q : i8) {
  %epsilon = llhd.constant_time <0ns, 0d, 1e>
  %c0_i8 = hw.constant 0 : i8
  // CHECK: [[MUL:%.+]] = comb.mul %a, %b
  // CHECK: [[PROD:%prod]] = hw.wire [[MUL]] {{ *}}{sv.attributes = [#sv.attribute<"use_dsp" = "\22yes\22">]} : i8
  %prod = llhd.sig name "prod" %c0_i8 {sv.attributes = [#sv.attribute<"use_dsp" = "\22yes\22">]} : <i8>
  %0 = comb.mul %a, %b : i8
  llhd.drv %prod, %0 after %epsilon : i8
  // CHECK: [[Q:%.+]] = seq.firreg [[PROD]] clock %clk {sv.attributes = [#sv.attribute<"keep" = "\22true\22">]} : i8
  %q = llhd.sig name "q" %c0_i8 {sv.attributes = [#sv.attribute<"keep" = "\22true\22">]} : <i8>
  %1 = llhd.prb %prod : i8
  %2 = seq.firreg %1 clock %clk : i8
  llhd.drv %q, %2 after %epsilon : i8
  %3 = llhd.prb %prod : i8
  %4 = llhd.prb %q : i8
  // CHECK: hw.output [[PROD]], [[Q]]
  hw.output %3, %4 : i8, i8
}

// A signal that a register drives, and that an `initial` block drives once
// with a constant, holds the register, preset to the constant.
// CHECK-LABEL: hw.module @InitialConstant
hw.module @InitialConstant(in %clk : !seq.clock, in %d : i8, out q : i8) {
  %epsilon = llhd.constant_time <0ns, 0d, 1e>
  %c5_i8 = hw.constant 5 : i8
  // CHECK-NOT: llhd.
  // CHECK: [[Q:%.+]] = seq.firreg %d clock %clk preset 5 : i8
  // CHECK: hw.output [[Q]]
  %q = llhd.sig : <i8>
  llhd.drv %q, %c5_i8 after %epsilon : i8
  %0 = seq.firreg %d clock %clk : i8
  llhd.drv %q, %0 after %epsilon : i8
  %1 = llhd.prb %q : i8
  hw.output %1 : i8
}

// A RAM filled with a constant, by a loop or an assignment pattern, is a
// register array preset to it: element 0 in the low bits.
// CHECK-LABEL: hw.module @InitialAggregate
hw.module @InitialAggregate(in %clk : !seq.clock, in %we : i1, in %wa : i2, in %wd : i8, in %ra : i2, out rd : i8) {
  %epsilon = llhd.constant_time <0ns, 0d, 1e>
  %init = hw.aggregate_constant [0 : i8, 0 : i8, 1 : i8, 2 : i8] : !hw.array<4xi8>
  // CHECK-NOT: llhd.
  // CHECK: [[INJ:%.+]] = hw.array_inject [[RAM:%.+]][%wa], %wd
  // CHECK: [[RD:%.+]] = hw.array_get [[RAM]][%ra]
  // CHECK: [[NEXT:%.+]] = comb.mux bin %we, [[INJ]], [[RAM]]
  // CHECK: [[RAM]] = seq.firreg [[NEXT]] clock %clk preset 258 : !hw.array<4xi8>
  // CHECK: hw.output [[RD]]
  %ram = llhd.sig : <!hw.array<4xi8>>
  %0 = llhd.prb %ram : !hw.array<4xi8>
  llhd.drv %ram, %init after %epsilon : !hw.array<4xi8>
  %1 = hw.array_inject %0[%wa], %wd : !hw.array<4xi8>, i2
  %2 = hw.array_get %0[%ra] : !hw.array<4xi8>, i2
  %3 = comb.mux bin %we, %1, %4 : !hw.array<4xi8>
  %4 = seq.firreg %3 clock %clk : !hw.array<4xi8>
  llhd.drv %ram, %4 after %epsilon : !hw.array<4xi8>
  hw.output %2 : i8
}

// A RAM an `initial` block loads from a file is a register array that records
// the file. Ascending ranges load from the last element of the array down.
// CHECK-LABEL: hw.module @InitialFileLoad
hw.module @InitialFileLoad(in %clk : !seq.clock, in %we : i1, in %wa : i2, in %wd : i8, in %ra : i2, out rd : i8, out rd2 : i8) {
  %epsilon = llhd.constant_time <0ns, 0d, 1e>
  %file = sim.string.literal "init.hex"
  %file2 = sim.string.literal "init.bin"
  // CHECK-NOT: llhd.
  // CHECK-NOT: sim.
  // CHECK: seq.firreg {{%.+}} clock %clk {seq.firmem_init = #seq.firmem.init<"init.hex", false, true>, seq.firmem_init_reversed} : !hw.array<4xi8>
  // CHECK: seq.firreg {{%.+}} clock %clk {seq.firmem_init = #seq.firmem.init<"init.bin", true, true>} : !hw.array<4xi8>
  %ram = llhd.sig : <!hw.array<4xi8>>
  %0 = llhd.prb %ram : !hw.array<4xi8>
  %1 = llhd.process -> !hw.array<4xi8> {
    %l = sim.sv.readmem %file, %0 {dimDescending = array<i1: false>, dimLows = array<i64: 0>} : !hw.array<4xi8>
    llhd.halt %l : !hw.array<4xi8>
  }
  llhd.drv %ram, %1 after %epsilon : !hw.array<4xi8>
  %2 = hw.array_inject %0[%wa], %wd : !hw.array<4xi8>, i2
  %3 = hw.array_get %0[%ra] : !hw.array<4xi8>, i2
  %4 = comb.mux bin %we, %2, %5 : !hw.array<4xi8>
  %5 = seq.firreg %4 clock %clk : !hw.array<4xi8>
  llhd.drv %ram, %5 after %epsilon : !hw.array<4xi8>

  // Descending ranges load from the first element up.
  %ram2 = llhd.sig : <!hw.array<4xi8>>
  %6 = llhd.prb %ram2 : !hw.array<4xi8>
  %7 = llhd.process -> !hw.array<4xi8> {
    %l = sim.sv.readmem %file2, %6 {isBinary = true, dimDescending = array<i1: true>, dimLows = array<i64: 0>} : !hw.array<4xi8>
    llhd.halt %l : !hw.array<4xi8>
  }
  llhd.drv %ram2, %7 after %epsilon : !hw.array<4xi8>
  %8 = hw.array_inject %6[%wa], %wd : !hw.array<4xi8>, i2
  %9 = hw.array_get %6[%ra] : !hw.array<4xi8>, i2
  %10 = comb.mux bin %we, %8, %11 : !hw.array<4xi8>
  %11 = seq.firreg %10 clock %clk : !hw.array<4xi8>
  llhd.drv %ram2, %11 after %epsilon : !hw.array<4xi8>
  hw.output %3, %9 : i8, i8
}

// A RAM without an initial value keeps a register without one.
// CHECK-LABEL: hw.module @NoInitial
hw.module @NoInitial(in %clk : !seq.clock, in %we : i1, in %wa : i2, in %wd : i8, in %ra : i2, out rd : i8) {
  %epsilon = llhd.constant_time <0ns, 0d, 1e>
  // CHECK-NOT: llhd.
  // CHECK: seq.firreg {{%.+}} clock %clk : !hw.array<4xi8>
  %ram = llhd.sig : <!hw.array<4xi8>>
  %0 = llhd.prb %ram : !hw.array<4xi8>
  %1 = hw.array_inject %0[%wa], %wd : !hw.array<4xi8>, i2
  %2 = hw.array_get %0[%ra] : !hw.array<4xi8>, i2
  %3 = comb.mux bin %we, %1, %4 : !hw.array<4xi8>
  %4 = seq.firreg %3 clock %clk : !hw.array<4xi8>
  llhd.drv %ram, %4 after %epsilon : !hw.array<4xi8>
  hw.output %2 : i8
}

// A constant a signal is driven with, other than by a register and an
// `initial` block, is not an initial value.
// CHECK-LABEL: hw.module @NotInitial
hw.module @NotInitial(in %clk : !seq.clock, in %d : i8, in %en : i1, out q : i8) {
  %epsilon = llhd.constant_time <0ns, 0d, 1e>
  %c5_i8 = hw.constant 5 : i8
  // CHECK: llhd.sig
  // CHECK: seq.firreg %d clock %clk : i8
  %q = llhd.sig : <i8>
  llhd.drv %q, %c5_i8 after %epsilon if %en : i8
  %0 = seq.firreg %d clock %clk : i8
  llhd.drv %q, %0 after %epsilon : i8
  %1 = llhd.prb %q : i8
  hw.output %1 : i8
}
