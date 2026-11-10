// RUN: circt-opt --llhd-sig2reg %s | FileCheck %s

func.func private @unknown_time() -> !llhd.time
func.func private @use_signal(%arg0: !llhd.ref<i42>)

// CHECK-LABEL: @RemoveUnprobed
hw.module @RemoveUnprobed(in %d: i42, in %e: i1) {
  %0 = hw.constant 0 : i42
  // CHECK-NOT: llhd.sig
  %a = llhd.sig %0 : <i42>
  %b = llhd.sig %0 : <i42>
  // CHECK-NOT: llhd.drv
  llhd.assign %a, %d : i42
  llhd.assign %b, %d if %e : i42
  // CHECK: hw.output
}

// CHECK-LABEL: hw.module @RemoveUnprobedMultiplyDriven
hw.module @RemoveUnprobedMultiplyDriven(in %a : i42, in %b : i42) {
  // CHECK-NOT: llhd.sig
  %x = llhd.sig %a : <i42>
  %t = llhd.constant_time <0ns, 1d>
  llhd.assign %x, %a : i42
  llhd.drv %x, %b after %t : i42
  // CHECK: hw.output
}

// CHECK-LABEL: hw.module @SkipDrivenFromDifferentBlock
hw.module @SkipDrivenFromDifferentBlock(in %a : i42, in %c : i1, out o : i42) {
  // CHECK: [[SIG:%.+]] = llhd.sig
  %x = llhd.sig %a : <i42>
  scf.if %c {
    // CHECK: llhd.assign [[SIG]], %a
    llhd.assign %x, %a : i42
  }
  // CHECK: [[PRB:%.+]] = llhd.prb [[SIG]]
  %p = llhd.prb %x : i42
  // CHECK: hw.output [[PRB]]
  hw.output %p : i42
}

// CHECK-LABEL: hw.module @SkipUnsupportedUser
hw.module @SkipUnsupportedUser(in %a : i42, out o : i42) {
  // CHECK: [[SIG:%.+]] = llhd.sig
  %x = llhd.sig %a : <i42>
  // CHECK: llhd.assign [[SIG]], %a
  llhd.assign %x, %a : i42
  // CHECK: func.call @use_signal([[SIG]])
  func.call @use_signal(%x) : (!llhd.ref<i42>) -> ()
  // CHECK: [[PRB:%.+]] = llhd.prb [[SIG]]
  %p = llhd.prb %x : i42
  // CHECK: hw.output [[PRB]]
  hw.output %p : i42
}

// CHECK-LABEL: hw.module @SkipMultipleDrivers
hw.module @SkipMultipleDrivers(in %a : i42, in %b : i42, out o : i42) {
  // CHECK: [[SIG:%.+]] = llhd.sig
  %x = llhd.sig %a : <i42>
  %t = llhd.constant_time <0ns, 1d>
  // CHECK: llhd.assign [[SIG]], %a
  llhd.assign %x, %a : i42
  // CHECK: llhd.drv [[SIG]], %b
  llhd.drv %x, %b after %t : i42
  // CHECK: [[PRB:%.+]] = llhd.prb [[SIG]]
  %p = llhd.prb %x : i42
  // CHECK: hw.output [[PRB]]
  hw.output %p : i42
}

// CHECK-LABEL: hw.module @SkipConditionalDrive
hw.module @SkipConditionalDrive(in %a : i42, in %c : i1, out o : i42) {
  // CHECK: [[SIG:%.+]] = llhd.sig
  %x = llhd.sig %a : <i42>
  // CHECK: llhd.assign [[SIG]], %a if %c
  llhd.assign %x, %a if %c : i42
  // CHECK: [[PRB:%.+]] = llhd.prb [[SIG]]
  %p = llhd.prb %x : i42
  // CHECK: hw.output [[PRB]]
  hw.output %p : i42
}

// CHECK-LABEL: hw.module @SkipDelayedDriveWithInit
hw.module @SkipDelayedDriveWithInit(in %a : i42, in %b : i42, out o : i42) {
  // CHECK: [[SIG:%.+]] = llhd.sig
  %x = llhd.sig %a : <i42>
  %t = llhd.constant_time <1ns, 0d>
  // CHECK: llhd.drv [[SIG]], %b
  llhd.drv %x, %b after %t : i42
  // CHECK: [[PRB:%.+]] = llhd.prb [[SIG]]
  %p = llhd.prb %x : i42
  // CHECK: hw.output [[PRB]]
  hw.output %p : i42
}

// CHECK-LABEL: hw.module @SkipNonConstantDriveDelay
hw.module @SkipNonConstantDriveDelay(in %b : i42, out o : i42) {
  // CHECK: [[SIG:%.+]] = llhd.sig :
  %x = llhd.sig : <i42>
  %t = func.call @unknown_time() : () -> !llhd.time
  // CHECK: llhd.drv [[SIG]], %b
  llhd.drv %x, %b after %t : i42
  // CHECK: [[PRB:%.+]] = llhd.prb [[SIG]]
  %p = llhd.prb %x : i42
  // CHECK: hw.output [[PRB]]
  hw.output %p : i42
}

// CHECK-LABEL: hw.module @SkipUndrivenWithoutInit
hw.module @SkipUndrivenWithoutInit(out o : i42) {
  // CHECK: [[SIG:%.+]] = llhd.sig :
  %x = llhd.sig : <i42>
  // CHECK: [[PRB:%.+]] = llhd.prb [[SIG]]
  %p = llhd.prb %x : i42
  // CHECK: hw.output [[PRB]]
  hw.output %p : i42
}

// CHECK-LABEL: hw.module @SkipUndrivenWithNonConstantInit
hw.module @SkipUndrivenWithNonConstantInit(in %a : i42, out o : i42) {
  // CHECK: [[SIG:%.+]] = llhd.sig %a
  %x = llhd.sig %a : <i42>
  // CHECK: [[PRB:%.+]] = llhd.prb [[SIG]]
  %p = llhd.prb %x : i42
  // CHECK: hw.output [[PRB]]
  hw.output %p : i42
}

// CHECK-LABEL: hw.module @PromoteUndrivenWithConstantInit
hw.module @PromoteUndrivenWithConstantInit(out o : i42) {
  // CHECK-NOT: llhd.sig
  // CHECK: [[C:%.+]] = hw.constant 9 : i42
  %c = hw.constant 9 : i42
  %x = llhd.sig %c : <i42>
  %p = llhd.prb %x : i42
  // CHECK: hw.output [[C]]
  hw.output %p : i42
}

// CHECK-LABEL: hw.module @PromoteAssign
hw.module @PromoteAssign(in %a : i42, in %b : i42, out o1 : i42, out o2 : i42) {
  // CHECK-NOT: llhd.sig
  %x = llhd.sig %a : <i42>
  llhd.assign %x, %b : i42
  %p1 = llhd.prb %x : i42
  %p2 = llhd.prb %x : i42
  // CHECK: hw.output %b, %b
  hw.output %p1, %p2 : i42, i42
}

// CHECK-LABEL: hw.module @PromoteDelayedDrive
hw.module @PromoteDelayedDrive(in %b : i42, out o : i42) {
  // CHECK-NOT: llhd.sig
  // CHECK-NOT: llhd.drv
  %x = llhd.sig : <i42>
  %t = llhd.constant_time <1ns, 0d>
  llhd.drv %x, %b after %t : i42
  %p = llhd.prb %x : i42
  // CHECK: [[DLY:%.+]] = llhd.delay %b by <1ns, 0d> : i42
  // CHECK: hw.output [[DLY]]
  hw.output %p : i42
}

// A signal with one immediate whole-value drive is replaced by the driven
// value; probes of projections become the matching aggregate accesses.
// CHECK-LABEL: @SingleWholeDrive
hw.module @SingleWholeDrive(in %v : !hw.array<2xi8>, out a : i8, out b : i4, out c : !hw.array<2xi8>) {
  %false = hw.constant false
  %c2_i3 = hw.constant 2 : i3
  %init = hw.aggregate_constant [0 : i8, 0 : i8] : !hw.array<2xi8>
  // CHECK-NOT: llhd.
  // CHECK: [[A:%.+]] = hw.array_get %v[%false]
  // CHECK: [[B:%.+]] = comb.extract [[A]] from 2
  // CHECK: hw.output [[A]], [[B]], %v
  %x = llhd.sig %init : <!hw.array<2xi8>>
  llhd.assign %x, %v : !hw.array<2xi8>
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
  %c0_i8 = hw.constant 0 : i8
  // CHECK: [[MUL:%.+]] = comb.mul %a, %b
  // CHECK: [[PROD:%prod]] = hw.wire [[MUL]] {{ *}}{sv.attributes = [#sv.attribute<"use_dsp" = "\22yes\22">]} : i8
  %prod = llhd.sig name "prod" %c0_i8 {sv.attributes = [#sv.attribute<"use_dsp" = "\22yes\22">]} : <i8>
  %0 = comb.mul %a, %b : i8
  llhd.assign %prod, %0 : i8
  // CHECK: [[Q:%.+]] = seq.firreg [[PROD]] clock %clk {sv.attributes = [#sv.attribute<"keep" = "\22true\22">]} : i8
  %q = llhd.sig name "q" %c0_i8 {sv.attributes = [#sv.attribute<"keep" = "\22true\22">]} : <i8>
  %1 = llhd.prb %prod : i8
  %2 = seq.firreg %1 clock %clk : i8
  llhd.assign %q, %2 : i8
  %3 = llhd.prb %prod : i8
  %4 = llhd.prb %q : i8
  // CHECK: hw.output [[PROD]], [[Q]]
  hw.output %3, %4 : i8, i8
}

// An integer register's starting value is Deseq's to preset (it sees the same
// constant drive); Sig2Reg leaves both drives alone.
// CHECK-LABEL: hw.module @InitialConstant
hw.module @InitialConstant(in %clk : !seq.clock, in %d : i8, out q : i8) {
  %c5_i8 = hw.constant 5 : i8
  // CHECK: llhd.sig
  // CHECK: llhd.assign %q, %c5_i8
  // CHECK: seq.firreg %d clock %clk : i8
  %q = llhd.sig : <i8>
  llhd.assign %q, %c5_i8 : i8
  %0 = seq.firreg %d clock %clk : i8
  llhd.assign %q, %0 : i8
  %1 = llhd.prb %q : i8
  hw.output %1 : i8
}

// A RAM filled with a constant, by a loop or an assignment pattern, is a
// register array preset to it: element 0 in the low bits.
// CHECK-LABEL: hw.module @InitialAggregate
hw.module @InitialAggregate(in %clk : !seq.clock, in %we : i1, in %wa : i2, in %wd : i8, in %ra : i2, out rd : i8) {
  %init = hw.aggregate_constant [0 : i8, 0 : i8, 1 : i8, 2 : i8] : !hw.array<4xi8>
  // CHECK-NOT: llhd.
  // CHECK: [[INJ:%.+]] = hw.array_inject [[RAM:%.+]][%wa], %wd
  // CHECK: [[RD:%.+]] = hw.array_get [[RAM]][%ra]
  // CHECK: [[NEXT:%.+]] = comb.mux bin %we, [[INJ]], [[RAM]]
  // CHECK: [[RAM]] = seq.firreg [[NEXT]] clock %clk preset 258 : !hw.array<4xi8>
  // CHECK: hw.output [[RD]]
  %ram = llhd.sig : <!hw.array<4xi8>>
  %0 = llhd.prb %ram : !hw.array<4xi8>
  llhd.assign %ram, %init : !hw.array<4xi8>
  %1 = hw.array_inject %0[%wa], %wd : !hw.array<4xi8>, i2
  %2 = hw.array_get %0[%ra] : !hw.array<4xi8>, i2
  %3 = comb.mux bin %we, %1, %4 : !hw.array<4xi8>
  %4 = seq.firreg %3 clock %clk : !hw.array<4xi8>
  llhd.assign %ram, %4 : !hw.array<4xi8>
  hw.output %2 : i8
}

// A RAM an `initial` block loads from a file is a register array that records
// the file. Ascending ranges load from the last element of the array down.
// CHECK-LABEL: hw.module @InitialFileLoad
hw.module @InitialFileLoad(in %clk : !seq.clock, in %we : i1, in %wa : i2, in %wd : i8, in %ra : i2, out rd : i8, out rd2 : i8) {
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
  llhd.assign %ram, %1 : !hw.array<4xi8>
  %2 = hw.array_inject %0[%wa], %wd : !hw.array<4xi8>, i2
  %3 = hw.array_get %0[%ra] : !hw.array<4xi8>, i2
  %4 = comb.mux bin %we, %2, %5 : !hw.array<4xi8>
  %5 = seq.firreg %4 clock %clk : !hw.array<4xi8>
  llhd.assign %ram, %5 : !hw.array<4xi8>

  // Descending ranges load from the first element up.
  %ram2 = llhd.sig : <!hw.array<4xi8>>
  %6 = llhd.prb %ram2 : !hw.array<4xi8>
  %7 = llhd.process -> !hw.array<4xi8> {
    %l = sim.sv.readmem %file2, %6 {isBinary = true, dimDescending = array<i1: true>, dimLows = array<i64: 0>} : !hw.array<4xi8>
    llhd.halt %l : !hw.array<4xi8>
  }
  llhd.assign %ram2, %7 : !hw.array<4xi8>
  %8 = hw.array_inject %6[%wa], %wd : !hw.array<4xi8>, i2
  %9 = hw.array_get %6[%ra] : !hw.array<4xi8>, i2
  %10 = comb.mux bin %we, %8, %11 : !hw.array<4xi8>
  %11 = seq.firreg %10 clock %clk : !hw.array<4xi8>
  llhd.assign %ram2, %11 : !hw.array<4xi8>
  hw.output %3, %9 : i8, i8
}

// A RAM without an initial value keeps a register without one.
// CHECK-LABEL: hw.module @NoInitial
hw.module @NoInitial(in %clk : !seq.clock, in %we : i1, in %wa : i2, in %wd : i8, in %ra : i2, out rd : i8) {
  // CHECK-NOT: llhd.
  // CHECK: seq.firreg {{%.+}} clock %clk : !hw.array<4xi8>
  %ram = llhd.sig : <!hw.array<4xi8>>
  %0 = llhd.prb %ram : !hw.array<4xi8>
  %1 = hw.array_inject %0[%wa], %wd : !hw.array<4xi8>, i2
  %2 = hw.array_get %0[%ra] : !hw.array<4xi8>, i2
  %3 = comb.mux bin %we, %1, %4 : !hw.array<4xi8>
  %4 = seq.firreg %3 clock %clk : !hw.array<4xi8>
  llhd.assign %ram, %4 : !hw.array<4xi8>
  hw.output %2 : i8
}

// A constant a signal is driven with, other than by a register and an
// `initial` block, is not an initial value.
// CHECK-LABEL: hw.module @NotInitial
hw.module @NotInitial(in %clk : !seq.clock, in %d : i8, in %en : i1, out q : i8) {
  %c5_i8 = hw.constant 5 : i8
  // CHECK: llhd.sig
  // CHECK: seq.firreg %d clock %clk : i8
  %q = llhd.sig : <i8>
  llhd.assign %q, %c5_i8 if %en : i8
  %0 = seq.firreg %d clock %clk : i8
  llhd.assign %q, %0 : i8
  %1 = llhd.prb %q : i8
  hw.output %1 : i8
}
