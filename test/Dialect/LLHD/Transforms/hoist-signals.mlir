// RUN: circt-opt --llhd-hoist-signals %s | FileCheck %s

// CHECK-LABEL: @SimpleProbesInProcessOp
hw.module @SimpleProbesInProcessOp() {
  %c0_i42 = hw.constant 0 : i42
  %a = llhd.sig %c0_i42 : <i42>
  // CHECK: llhd.sig
  // CHECK-NEXT: [[A:%.+]] = llhd.prb %a
  // CHECK-NEXT: llhd.process
  llhd.process {
    // CHECK-NOT: llhd.prb
    %0 = llhd.prb %a : i42
    // CHECK-NEXT: call @use_i42([[A]])
    func.call @use_i42(%0) : (i42) -> ()
    llhd.wait ^bb1
  ^bb1:
    // CHECK: ^bb1:
    // CHECK-NOT: llhd.prb
    %1 = llhd.prb %a : i42
    // CHECK-NEXT: call @use_i42([[A]])
    func.call @use_i42(%1) : (i42) -> ()
    llhd.halt
  }
}

// CHECK-LABEL: @SimpleProbesInCombinationalOp
hw.module @SimpleProbesInCombinationalOp() {
  %c0_i42 = hw.constant 0 : i42
  %a = llhd.sig %c0_i42 : <i42>
  // CHECK: llhd.sig
  // CHECK-NEXT: [[A:%.+]] = llhd.prb %a
  // CHECK-NEXT: llhd.combinational -> i42
  llhd.combinational -> i42 {
    // CHECK-NOT: llhd.prb
    %0 = llhd.prb %a : i42
    // CHECK-NEXT: call @use_i42([[A]])
    func.call @use_i42(%0) : (i42) -> ()
    // CHECK-NEXT: llhd.yield [[A]]
    llhd.yield %0 : i42
  }
}

// CHECK-LABEL: @DontHoistProbesAcrossSideEffects
hw.module @DontHoistProbesAcrossSideEffects() {
  %c0_i42 = hw.constant 0 : i42
  %a = llhd.sig %c0_i42 : <i42>
  // CHECK: llhd.process
  llhd.process {
    // CHECK-NEXT: llhd.assign
    llhd.assign %a, %c0_i42 : i42
    // CHECK-NEXT: llhd.prb %a
    llhd.prb %a : i42
    cf.br ^bb1
  ^bb1:
    // CHECK: ^bb1:
    // CHECK-NEXT: llhd.prb %a
    llhd.prb %a : i42
    llhd.wait ^bb2
  ^bb2:
    // CHECK: ^bb2:
    // CHECK-NEXT: call @maybe_side_effecting
    func.call @maybe_side_effecting() : () -> ()
    // CHECK-NEXT: llhd.prb %a
    llhd.prb %a : i42
    llhd.halt
  }
}

// CHECK-LABEL: @DontHoistProbesIfLeakingAcrossWait
hw.module @DontHoistProbesIfLeakingAcrossWait() {
  %c0_i42 = hw.constant 0 : i42
  %a = llhd.sig %c0_i42 : <i42>
  // CHECK: llhd.process
  llhd.process {
    // CHECK-NEXT: [[A:%.+]] = llhd.prb %a
    %0 = llhd.prb %a : i42
    llhd.wait ^bb1
  ^bb1:
    // CHECK: ^bb1:
    // CHECK-NEXT: call @use_i42([[A]])
    func.call @use_i42(%0) : (i42) -> ()
    llhd.halt
  }
  // CHECK: llhd.process
  llhd.process {
    // CHECK-NEXT: llhd.prb %a
    %0 = llhd.prb %a : i42
    cf.br ^bb1(%0 : i42)
  ^bb1(%1: i42):
    // CHECK: ^bb1([[A:%.+]]: i42):
    llhd.wait ^bb2
  ^bb2:
    // CHECK: ^bb2:
    // CHECK-NEXT: call @use_i42([[A]])
    func.call @use_i42(%1) : (i42) -> ()
    llhd.halt
  }
}

// CHECK-LABEL: @DontHoistLocalSignals
hw.module @DontHoistLocalSignals() {
  %c0_i42 = hw.constant 0 : i42
  // CHECK: llhd.process
  llhd.process {
    %a = llhd.sig %c0_i42 : <i42>
    llhd.wait ^bb1
  ^bb1:
    // CHECK: ^bb1:
    // CHECK-NEXT: llhd.prb %a
    // CHECK-NEXT: llhd.assign %a
    llhd.prb %a : i42
    llhd.assign %a, %c0_i42 : i42
    llhd.halt
  }
}

// CHECK-LABEL: @SimpleDrives
hw.module @SimpleDrives(in %u: i42, in %v: i42, in %w: i42) {
  // CHECK: [[DEL:%.+]] = llhd.constant_time <0ns, 1d>
  // CHECK: [[NS:%.+]] = llhd.constant_time <1ns, 0d>
  %0 = llhd.constant_time <0ns, 1d>
  %1 = llhd.constant_time <1ns, 0d>
  %c0_i42 = hw.constant 0 : i42
  %a = llhd.sig %c0_i42 : <i42>
  %b = llhd.sig %c0_i42 : <i42>
  %c = llhd.sig %c0_i42 : <i42>
  %d = llhd.sig %c0_i42 : <i42>
  // CHECK: [[RES:%.+]]:7 = llhd.process -> i42, i42, i42, i42, !llhd.time, i42, i1 {
  %2 = llhd.process -> i42 {
    // CHECK-NEXT: cf.br ^bb1
    cf.br ^bb1
  ^bb1:
    // CHECK-NEXT: ^bb1:
    // CHECK-NOT: llhd.drv
    llhd.drv %a, %u after %0 : i42
    llhd.drv %b, %u after %0 : i42
    llhd.drv %c, %u after %0 : i42
    llhd.drv %d, %u after %0 : i42
    // CHECK-NEXT: llhd.wait yield (%w, %u, %u, %u, [[DEL]], %u, %true : i42, i42, i42, i42, !llhd.time, i42, i1), ^bb2
    llhd.wait yield (%w : i42), ^bb2
  ^bb2:
    // CHECK-NEXT: ^bb2:
    // CHECK-NEXT: cf.br ^bb3
    cf.br ^bb3
  ^bb3:
    // CHECK-NEXT: ^bb3:
    // CHECK-NOT: llhd.drv
    llhd.drv %a, %u after %0 : i42
    llhd.drv %b, %v after %0 : i42
    llhd.drv %c, %u after %1 : i42
    // CHECK-NEXT: llhd.halt %w, %u, %v, %u, [[NS]], {{%c0_i42.*}}, %false : i42, i42, i42, i42, !llhd.time, i42, i1
    llhd.halt %w : i42
  }
  // CHECK-NEXT: }
  // CHECK-NEXT: llhd.drv %a, [[RES]]#1 after [[DEL]] :
  // CHECK-NEXT: llhd.drv %b, [[RES]]#2 after [[DEL]] :
  // CHECK-NEXT: llhd.drv %c, [[RES]]#3 after [[RES]]#4 :
  // CHECK-NEXT: llhd.drv %d, [[RES]]#5 after [[DEL]] if [[RES]]#6 :
  // CHECK-NEXT: call @use_i42([[RES]]#0)
  func.call @use_i42(%2) : (i42) -> ()
}

// CHECK-LABEL: @DontHoistDrivesAcrossSideEffects
hw.module @DontHoistDrivesAcrossSideEffects() {
  %c0_i42 = hw.constant 0 : i42
  %a = llhd.sig %c0_i42 : <i42>
  // CHECK: llhd.process
  llhd.process {
    // CHECK-NEXT: llhd.assign %a
    llhd.assign %a, %c0_i42 : i42
    // CHECK-NEXT: call @maybe_side_effecting
    func.call @maybe_side_effecting() : () -> ()
    llhd.halt
  }
}

// CHECK-LABEL: @DontHoistDrivesOfSlotsWithUnsavoryUsers
hw.module @DontHoistDrivesOfSlotsWithUnsavoryUsers(in %c: !llhd.ref<i42>) {
  %c0_i42 = hw.constant 0 : i42
  %a = llhd.sig %c0_i42 : <i42>
  %b = llhd.sig %c0_i42 : <i42>
  // Unsavory uses outside of process don't affect hoistability.
  // CHECK: call @use_inout_i42(%a)
  func.call @use_inout_i42(%a) : (!llhd.ref<i42>) -> ()
  // CHECK: llhd.process
  llhd.process {
    // CHECK-NOT: llhd.assign
    llhd.assign %a, %c0_i42 : i42
    // CHECK-NEXT: llhd.halt
    llhd.halt
  }
  // CHECK: llhd.process
  llhd.process {
    // CHECK-NEXT: call @use_inout_i42(%b)
    func.call @use_inout_i42(%b) : (!llhd.ref<i42>) -> ()
    // CHECK-NEXT: llhd.assign %b
    llhd.assign %b, %c0_i42 : i42
    // CHECK-NEXT: llhd.halt
    llhd.halt
  }
  // Drives to a reference port of the module are hoisted too.
  // CHECK: llhd.process
  llhd.process {
    // CHECK-NEXT: llhd.halt
    llhd.assign %c, %c0_i42 : i42
    llhd.halt
  }
  // CHECK: llhd.assign %c
}

// CHECK-LABEL: @OnlyHoistLastDrive
hw.module @OnlyHoistLastDrive(in %u: i42, in %v: i42) {
  %c0_i42 = hw.constant 0 : i42
  %a = llhd.sig %c0_i42 : <i42>
  %b = llhd.sig %c0_i42 : <i42>
  // CHECK: [[RES:%.+]]:2 = llhd.process -> i42, i42
  llhd.process {
    // CHECK-NEXT: llhd.assign %a, %u
    llhd.assign %a, %u : i42
    // CHECK-NEXT: llhd.assign %b, %v
    llhd.assign %b, %v : i42
    // CHECK-NOT: llhd.assign %a, %v
    llhd.assign %a, %v : i42
    // CHECK-NOT: llhd.assign %b, %u
    llhd.assign %b, %u : i42
    // CHECK-NEXT: llhd.halt %v, %u : i42, i42
    llhd.halt
  }
  // CHECK: llhd.assign %a, [[RES]]#0
  // CHECK: llhd.assign %b, [[RES]]#1
}

// CHECK-LABEL: @HoistProbesOutOfIf
hw.module @HoistProbesOutOfIf(in %u: i42, in %v: i1) {
  // CHECK: llhd.sig
  %a = llhd.sig %u : <i42>
  // CHECK-NEXT: [[A:%.+]] = llhd.prb %a
  // CHECK-NEXT: scf.if
  scf.if %v {
    // CHECK-NOT: llhd.prb
    %0 = llhd.prb %a : i42
    // CHECK-NEXT: call @use_i42([[A]])
    func.call @use_i42(%0) : (i42) -> ()
    // CHECK-NEXT: } else {
  } else {
    // CHECK-NOT: llhd.prb
    %1 = llhd.prb %a : i42
    // CHECK-NEXT: call @use_i42([[A]])
    func.call @use_i42(%1) : (i42) -> ()
  }
}

// See https://github.com/llvm/circt/issues/9348.
// CHECK-LABEL: @NonUniformDelayValues
hw.module @NonUniformDelayValues(in %b : i42) {
  %0 = llhd.constant_time <1ns, 0d>
  %1 = llhd.constant_time <2ns, 0d>
  %a = llhd.sig %b : <i42>
  // CHECK: [[RES:%.+]]:3 = llhd.process -> i42, !llhd.time, i1
  // CHECK: llhd.drv %a, [[RES]]#0 after [[RES]]#1 if [[RES]]#2 : i42
  llhd.process {
    llhd.drv %a, %b after %0 : i42
    llhd.wait delay %0, ^bb1
  ^bb1:
    llhd.drv %a, %b after %1 : i42
    llhd.wait delay %1, ^bb2
  ^bb2:
    llhd.halt
  }
}

// See https://github.com/llvm/circt/issues/9420.
// CHECK-LABEL: @DontHoistMultipleDrivesWithDifferentDelays
hw.module @DontHoistMultipleDrivesWithDifferentDelays(in %v0: i42, in %v1: i42, in %v2: i42) {
  %0 = llhd.constant_time <5ns, 0d>
  %1 = llhd.constant_time <10ns, 0d>
  %a = llhd.sig %v0 : <i42>
  // CHECK: llhd.process
  llhd.process {
    // CHECK-NEXT: llhd.drv %a, %v1
    // CHECK-NEXT: llhd.drv %a, %v2
    llhd.drv %a, %v1 after %0 : i42
    llhd.drv %a, %v2 after %1 : i42
    llhd.halt
  }
}

// See https://github.com/llvm/circt/issues/9420.
// CHECK-LABEL: @DontHoistAcrossSideEffects
hw.module @DontHoistAcrossSideEffects(in %v0: i42, in %v1: i42, in %v2: i42) {
  %0 = llhd.constant_time <1ns, 0d>
  %a = llhd.sig %v0 : <i42>
  llhd.process {
    // CHECK: llhd.drv %a, %v1
    llhd.drv %a, %v1 after %0 : i42
    // CHECK-NEXT: call @maybe_side_effecting
    func.call @maybe_side_effecting() : () -> ()
    // CHECK-NEXT: llhd.wait
    llhd.wait ^bb1
  ^bb1:
    // CHECK: llhd.drv %a, %v2
    llhd.drv %a, %v2 after %0 : i42
    // CHECK-NEXT: llhd.halt
    llhd.halt
  }
}

// Drive a signal of type f64 (Verilog `real`) across a wait boundary. The
// hoister must be able to materialize a default f64 constant for the yield.
// CHECK-LABEL: @RealSignalDriveAcrossWait
hw.module @RealSignalDriveAcrossWait(in %v : f64) {
  %0 = llhd.constant_time <1ns, 0d>
  %cst = arith.constant 0.0 : f64
  %a = llhd.sig %cst : <f64>
  // CHECK: llhd.process -> f64
  // CHECK: llhd.drv %a
  llhd.process {
    llhd.drv %a, %v after %0 : f64
    llhd.wait delay %0, ^bb1
  ^bb1:
    llhd.halt
  }
}

// Signals with types that don't have a materializable default constant (like
// `index`) should not be hoisted. The drives remain inside the process as-is.
// CHECK-LABEL: @UnsupportedTypeNotHoisted
hw.module @UnsupportedTypeNotHoisted(in %v : index) {
  %0 = llhd.constant_time <1ns, 0d>
  %c0 = arith.constant 0 : index
  %a = llhd.sig %c0 : <index>
  // CHECK: llhd.process
  llhd.process {
    // CHECK: llhd.drv %a, %v after
    llhd.drv %a, %v after %0 : index
    llhd.wait delay %0, ^bb1
  ^bb1:
    llhd.halt
  }
}

// A signal driven only in non-halt/wait blocks should not be hoisted, even
// when other signals in the same process are hoistable. The drive collection
// only considers blocks with halt/wait terminators, so the first signal ends
// up without a drive set entry and must be skipped.
// CHECK-LABEL: @DriveOnlyInNonSuspendBlock
hw.module @DriveOnlyInNonSuspendBlock(in %v : f64, in %w : i42, in %c : i1) {
  %cst = arith.constant 0.0 : f64
  %c0 = hw.constant 0 : i42
  %a = llhd.sig %cst : <f64>
  %b = llhd.sig %c0 : <i42>
  // CHECK: llhd.process
  llhd.process {
    // This f64 drive is only in ^bb0 (ends with cond_br, not halt/wait).
    // CHECK: llhd.assign %a, %v
    llhd.assign %a, %v : f64
    cf.cond_br %c, ^bb1, ^bb2
  ^bb1:
    cf.br ^bb2
  ^bb2:
    // This i42 drive IS in the halt block, so it gets hoisted.
    llhd.assign %b, %w : i42
    llhd.halt
  }
}

// A drive to a projection of a signal declared outside the process can be
// hoisted, as long as the projection itself is defined outside the process.
// CHECK-LABEL: @HoistProjectionDrive
hw.module @HoistProjectionDrive(in %x : i5) {
  %c0_i1 = hw.constant 0 : i1
  %sig = llhd.sig : <!hw.array<2xi5>>
  // CHECK: [[ELT:%.+]] = llhd.sig.array_get %sig
  %elt = llhd.sig.array_get %sig[%c0_i1] : <!hw.array<2xi5>>
  // CHECK: [[TMP:%.+]] = llhd.process -> i5 {
  llhd.process {
    cf.br ^bb1
  ^bb1:
    // CHECK-NOT: llhd.assign
    // CHECK: llhd.wait yield (%x : i5), ^bb1
    llhd.assign %elt, %x : i5
    llhd.wait ^bb1
  }
  // CHECK: llhd.assign [[ELT]], [[TMP]]
}

// Drives to provably disjoint projections of the same signal are independent
// and can be hoisted separately.
// CHECK-LABEL: @HoistDisjointProjectionDrives
hw.module @HoistDisjointProjectionDrives(in %x : i5, in %y : i5) {
  %c0_i1 = hw.constant 0 : i1
  %c1_i1 = hw.constant 1 : i1
  %sig = llhd.sig : <!hw.array<2xi5>>
  // CHECK: [[E0:%.+]] = llhd.sig.array_get %sig
  // CHECK: [[E1:%.+]] = llhd.sig.array_get %sig
  %e0 = llhd.sig.array_get %sig[%c0_i1] : <!hw.array<2xi5>>
  %e1 = llhd.sig.array_get %sig[%c1_i1] : <!hw.array<2xi5>>
  // CHECK: [[TMP:%.+]]:2 = llhd.process -> i5, i5 {
  llhd.process {
    cf.br ^bb1
  ^bb1:
    // CHECK-NOT: llhd.assign
    // CHECK: llhd.wait yield (%x, %y : i5, i5), ^bb1
    llhd.assign %e0, %x : i5
    llhd.assign %e1, %y : i5
    llhd.wait ^bb1
  }
  // CHECK: llhd.assign [[E0]], [[TMP]]#0
  // CHECK: llhd.assign [[E1]], [[TMP]]#1
}

// A drive to a projection and a drive to the signal it projects into overlap.
// Hoisting them into separate drives would lose their relative order, so
// neither may be hoisted.
// CHECK-LABEL: @NoHoistProjectionAliasingRoot
hw.module @NoHoistProjectionAliasingRoot(in %x : !hw.array<2xi5>, in %y : i5) {
  %c0_i1 = hw.constant 0 : i1
  %sig = llhd.sig : <!hw.array<2xi5>>
  %elt = llhd.sig.array_get %sig[%c0_i1] : <!hw.array<2xi5>>
  // CHECK: llhd.process {
  llhd.process {
    cf.br ^bb1
  ^bb1:
    // CHECK: llhd.assign %sig, %x
    // CHECK: llhd.assign {{%.+}}, %y
    llhd.assign %sig, %x : !hw.array<2xi5>
    llhd.assign %elt, %y : i5
    llhd.wait ^bb1
  }
}

// Partially overlapping projections of the same signal must not be hoisted.
// CHECK-LABEL: @NoHoistOverlappingProjections
hw.module @NoHoistOverlappingProjections(in %x : i5, in %y : i10) {
  %c0_i4 = hw.constant 0 : i4
  %sig = llhd.sig : <i10>
  %lo = llhd.sig.extract %sig from %c0_i4 : <i10> -> <i5>
  // CHECK: llhd.process {
  llhd.process {
    cf.br ^bb1
  ^bb1:
    // CHECK: llhd.assign %sig, %y
    // CHECK: llhd.assign {{%.+}}, %x
    llhd.assign %sig, %y : i10
    llhd.assign %lo, %x : i5
    llhd.wait ^bb1
  }
}

// Projections with a dynamic index may alias each other, so drives to two of
// them must not be hoisted.
// CHECK-LABEL: @NoHoistDynamicProjections
hw.module @NoHoistDynamicProjections(in %i : i1, in %j : i1, in %x : i5, in %y : i5) {
  %sig = llhd.sig : <!hw.array<2xi5>>
  %ei = llhd.sig.array_get %sig[%i] : <!hw.array<2xi5>>
  %ej = llhd.sig.array_get %sig[%j] : <!hw.array<2xi5>>
  // CHECK: llhd.process {
  llhd.process {
    cf.br ^bb1
  ^bb1:
    // CHECK: llhd.assign {{%.+}}, %x
    // CHECK: llhd.assign {{%.+}}, %y
    llhd.assign %ei, %x : i5
    llhd.assign %ej, %y : i5
    llhd.wait ^bb1
  }
}

// A single dynamically indexed projection is the only slot of its root signal,
// so all drives through it target the same storage and can be hoisted.
// CHECK-LABEL: @HoistSingleDynamicProjection
hw.module @HoistSingleDynamicProjection(in %i : i1, in %x : i5) {
  %sig = llhd.sig : <!hw.array<2xi5>>
  // CHECK: [[ELT:%.+]] = llhd.sig.array_get %sig
  %ei = llhd.sig.array_get %sig[%i] : <!hw.array<2xi5>>
  // CHECK: [[TMP:%.+]] = llhd.process -> i5 {
  llhd.process {
    cf.br ^bb1
  ^bb1:
    // CHECK-NOT: llhd.assign
    // CHECK: llhd.wait yield (%x : i5), ^bb1
    llhd.assign %ei, %x : i5
    llhd.wait ^bb1
  }
  // CHECK: llhd.assign [[ELT]], [[TMP]]
}


func.func private @use_i42(%arg0: i42)
func.func private @use_inout_i42(%arg0: !llhd.ref<i42>)
func.func private @maybe_side_effecting()

// Drives to a constant field projection of a signal declared outside the
// process are hoisted like drives to the signal itself.
// CHECK-LABEL: @HoistFieldDrive
hw.module @HoistFieldDrive(in %v : i8) {
  %false = hw.constant false
  %init = hw.aggregate_constant [0 : i8, 0 : i8] : !hw.array<2xi8>
  %x = llhd.sig %init : <!hw.array<2xi8>>
  // CHECK: [[E:%.+]] = llhd.sig.array_get %x[%false]
  %e = llhd.sig.array_get %x[%false] : <!hw.array<2xi8>>
  // CHECK: [[P:%.+]] = llhd.process -> i8
  llhd.process {
    cf.br ^bb1
  ^bb1:
    // CHECK-NOT: llhd.drv
    // CHECK: llhd.wait yield
    %n = comb.add %v, %v : i8
    llhd.assign %e, %n : i8
    llhd.wait (%v : i8), ^bb1
  }
  // CHECK: llhd.assign [[E]], [[P]]
}

// A process that also accesses a reference port of the module (a block
// argument, with no defining op): the port refers to storage outside of the
// module and cannot alias the module's own signal, so the drive is hoisted.
// CHECK-LABEL: @FieldDriveWithRefArgument
hw.module @FieldDriveWithRefArgument(in %v : i8, in %r : !llhd.ref<i8>) {
  %false = hw.constant false
  %init = hw.aggregate_constant [0 : i8, 0 : i8] : !hw.array<2xi8>
  %x = llhd.sig %init : <!hw.array<2xi8>>
  // CHECK: [[E:%.+]] = llhd.sig.array_get
  %e = llhd.sig.array_get %x[%false] : <!hw.array<2xi8>>
  // CHECK: [[P:%.+]] = llhd.process -> i8 {
  // CHECK-NOT: llhd.drv
  // CHECK: llhd.wait yield
  llhd.process {
    cf.br ^bb1
  ^bb1:
    %a = llhd.prb %r : i8
    %n = comb.add %v, %a : i8
    llhd.assign %e, %n : i8
    llhd.wait (%v : i8), ^bb1
  }
  // CHECK: llhd.assign [[E]], [[P]]
}

// Drives at the end of a combinational process (one `always_comb` per element
// of an array, as a generate loop produces) are hoisted like those before a
// process's wait: the value becomes a result of the combinational process and
// the drive moves out of it.
// CHECK-LABEL: @HoistCombinationalFieldDrives
hw.module @HoistCombinationalFieldDrives(in %c : i1, in %a : i8, in %b : i8, out o : !hw.array<2xi8>) {
  %false = hw.constant false
  %true = hw.constant true
  %init = hw.aggregate_constant [0 : i8, 0 : i8] : !hw.array<2xi8>
  %x = llhd.sig %init : <!hw.array<2xi8>>
  // CHECK: [[E0:%.+]] = llhd.sig.array_get %x[%false]
  %e0 = llhd.sig.array_get %x[%false] : <!hw.array<2xi8>>
  // CHECK: [[V0:%.+]] = llhd.combinational -> i8 {
  // CHECK-NOT: llhd.drv
  // CHECK: llhd.yield {{%.+}} : i8
  // CHECK: llhd.assign [[E0]], [[V0]]
  llhd.combinational {
    cf.cond_br %c, ^bb1, ^bb2(%b : i8)
  ^bb1:
    %s = comb.add %a, %b : i8
    cf.br ^bb2(%s : i8)
  ^bb2(%v: i8):
    llhd.assign %e0, %v : i8
    llhd.yield
  }
  // CHECK: [[E1:%.+]] = llhd.sig.array_get %x[%true]
  %e1 = llhd.sig.array_get %x[%true] : <!hw.array<2xi8>>
  // CHECK: [[V1:%.+]] = llhd.combinational -> i8 {
  // CHECK: llhd.assign [[E1]], [[V1]]
  llhd.combinational {
    %n = comb.xor %a, %b : i8
    llhd.assign %e1, %n : i8
    llhd.yield
  }
  %o = llhd.prb %x : !hw.array<2xi8>
  hw.output %o : !hw.array<2xi8>
}

// Drives to a reference port of the module are hoisted as long as the process
// accesses no other port, which might be bound to the same signal.
// CHECK-LABEL: @HoistPortDrive
hw.module @HoistPortDrive(in %c : i1, in %a : i8, in %b : i8, in %p : !llhd.ref<i8>) {
  // CHECK: [[V:%.+]] = llhd.combinational -> i8 {
  // CHECK-NOT: llhd.drv
  // CHECK: llhd.assign %p, [[V]]
  llhd.combinational {
    cf.cond_br %c, ^bb1, ^bb2
  ^bb1:
    llhd.assign %p, %a : i8
    llhd.yield
  ^bb2:
    llhd.assign %p, %b : i8
    llhd.yield
  }
}

// Two ports driven in one process may be bound to the same signal; their
// drives stay ordered inside the process.
// CHECK-LABEL: @PortDrivesMayAlias
hw.module @PortDrivesMayAlias(in %a : i8, in %b : i8, in %p : !llhd.ref<i8>, in %q : !llhd.ref<i8>) {
  // CHECK: llhd.combinational {
  // CHECK-NEXT: llhd.assign %p
  // CHECK-NEXT: llhd.assign %q
  llhd.combinational {
    llhd.assign %p, %a : i8
    llhd.assign %q, %b : i8
    llhd.yield
  }
}

// Another port passed to a call may be bound to the same signal and driven by
// the callee; the drive stays ordered after the call.
func.func private @drivePort(%arg0: !llhd.ref<i8>)

// CHECK-LABEL: @PortCallMayAlias
hw.module @PortCallMayAlias(in %a : i8, in %p : !llhd.ref<i8>, in %q : !llhd.ref<i8>) {
  // CHECK: llhd.process {
  // CHECK-NEXT: func.call @drivePort(%q)
  // CHECK-NEXT: llhd.assign %p, %a
  // CHECK-NEXT: llhd.halt
  llhd.process {
    func.call @drivePort(%q) : (!llhd.ref<i8>) -> ()
    llhd.assign %p, %a : i8
    llhd.halt
  }
}

// A reference selected by control flow and only probed in the merge block is
// probed in each predecessor instead, and the probes then leave the process.
// CHECK-LABEL: @ProbeSelectedReference
hw.module @ProbeSelectedReference(in %c : i1, in %p : !llhd.ref<i8>, in %q : !llhd.ref<i8>, out o : i8) {
  // CHECK-DAG: [[P:%.+]] = llhd.prb %p : i8
  // CHECK-DAG: [[Q:%.+]] = llhd.prb %q : i8
  // CHECK: llhd.combinational -> i8 {
  // CHECK-NEXT: cf.cond_br %c, ^bb1([[P]] : i8), ^bb1([[Q]] : i8)
  // CHECK-NEXT: ^bb1([[V:%.+]]: i8):
  // CHECK-NEXT: llhd.yield [[V]] : i8
  %0 = llhd.combinational -> i8 {
    cf.cond_br %c, ^bb1(%p : !llhd.ref<i8>), ^bb1(%q : !llhd.ref<i8>)
  ^bb1(%r: !llhd.ref<i8>):
    %v = llhd.prb %r : i8
    llhd.yield %v : i8
  }
  hw.output %0 : i8
}

// Ports marked `llhd.noalias` are bound to signals no other port is bound to:
// the drives of a process accessing several of them are hoisted, also next to
// one unmarked port.
// CHECK-LABEL: @HoistNoAliasPortDrives
hw.module @HoistNoAliasPortDrives(in %a : i8, in %b : i8, in %p : !llhd.ref<i8> {llhd.noalias}, in %q : !llhd.ref<i8> {llhd.noalias}, in %r : !llhd.ref<i8>) {
  // CHECK: llhd.combinational -> i8, i8, i8 {
  // CHECK-NOT: llhd.{{drv|assign}}
  // CHECK: }
  // CHECK-DAG: llhd.assign %p
  // CHECK-DAG: llhd.assign %q
  // CHECK-DAG: llhd.assign %r
  llhd.combinational {
    %0 = llhd.prb %q : i8
    %1 = comb.add %0, %b : i8
    llhd.assign %p, %a : i8
    llhd.assign %q, %1 : i8
    llhd.assign %r, %b : i8
    llhd.yield
  }
}

// An unmarked port next to another unmarked port keeps its drive in the
// process; the marked port's drive is hoisted.
// CHECK-LABEL: @NoAliasPortNextToAliasedPorts
hw.module @NoAliasPortNextToAliasedPorts(in %a : i8, in %b : i8, in %p : !llhd.ref<i8> {llhd.noalias}, in %q : !llhd.ref<i8>, in %r : !llhd.ref<i8>) {
  // CHECK: llhd.combinational -> i8 {
  // CHECK-NEXT: llhd.assign %q
  // CHECK-NEXT: llhd.assign %r
  // CHECK: llhd.assign %p
  llhd.combinational {
    llhd.assign %p, %a : i8
    llhd.assign %q, %a : i8
    llhd.assign %r, %b : i8
    llhd.yield
  }
}
