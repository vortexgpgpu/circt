// RUN: circt-opt --llhd-lower-ref-ports %s | FileCheck %s

// A reference port that is only probed becomes an input; one that is only
// driven becomes an output. Forwarding through an intermediate module is
// lowered all the way up to the module declaring the signals.

// CHECK-LABEL: hw.module private @Leaf
// CHECK-SAME: in %a : i8
// CHECK-SAME: out b : i8
// CHECK-NOT: llhd.
// CHECK: [[SUM:%.+]] = comb.add %a, %a
// CHECK: hw.output [[SUM]]
hw.module private @Leaf(in %a : !llhd.ref<i8>, in %b : !llhd.ref<i8>) {
  %t = llhd.constant_time <0ns, 0d, 1e>
  %0 = llhd.prb %a : i8
  %1 = comb.add %0, %0 : i8
  llhd.drv %b, %1 after %t : i8
}

// CHECK-LABEL: hw.module private @Mid
// CHECK-SAME: in %a : i8
// CHECK-SAME: out b : i8
// CHECK: %leaf.b = hw.instance "leaf" @Leaf(a: %a: i8) -> (b: i8)
// CHECK: hw.output %leaf.b
hw.module private @Mid(in %a : !llhd.ref<i8>, in %b : !llhd.ref<i8>) {
  hw.instance "leaf" @Leaf(a: %a: !llhd.ref<i8>, b: %b: !llhd.ref<i8>) -> ()
}

// CHECK-LABEL: hw.module @Top
// CHECK: [[P:%.+]] = llhd.prb %x
// CHECK: %mid.b = hw.instance "mid" @Mid(a: [[P]]: i8) -> (b: i8)
// CHECK: llhd.drv %y, %mid.b after
hw.module @Top(in %v : i8, out r : i8) {
  %t = llhd.constant_time <0ns, 0d, 1e>
  %c0 = hw.constant 0 : i8
  %x = llhd.sig %c0 : <i8>
  %y = llhd.sig %c0 : <i8>
  llhd.drv %x, %v after %t : i8
  hw.instance "mid" @Mid(a: %x: !llhd.ref<i8>, b: %y: !llhd.ref<i8>) -> ()
  %r = llhd.prb %y : i8
  hw.output %r : i8
}

// A port probed and driven once becomes an input for the probed value and an
// output for the driven one. The instance probes the signal into the input and
// drives it from the output, with the drive's delay.
// CHECK-LABEL: hw.module private @ReadWrite(in %a_in : i8, out a : i8)
// CHECK-NEXT: hw.output %a_in : i8
hw.module private @ReadWrite(in %a : !llhd.ref<i8>) {
  %t = llhd.constant_time <0ns, 0d, 1e>
  %0 = llhd.prb %a : i8
  llhd.drv %a, %0 after %t : i8
}
// CHECK-LABEL: hw.module @UseReadWrite
// CHECK: %x = llhd.sig
// CHECK: [[P:%.+]] = llhd.prb %x : i8
// CHECK: [[A:%.+]] = hw.instance "rw" @ReadWrite(a_in: [[P]]: i8) -> (a: i8)
// CHECK: [[T:%.+]] = llhd.constant_time <0ns, 0d, 1e>
// CHECK: llhd.drv %x, [[A]] after [[T]] : i8
hw.module @UseReadWrite() {
  %c0 = hw.constant 0 : i8
  %x = llhd.sig %c0 : <i8>
  hw.instance "rw" @ReadWrite(a: %x: !llhd.ref<i8>) -> ()
}

// An unused reference port becomes a value input.
// CHECK-LABEL: hw.module private @Unused(in %a : i8)
hw.module private @Unused(in %a : !llhd.ref<i8>) {
}
// CHECK-LABEL: hw.module @UseUnused
// CHECK: [[P:%.+]] = llhd.prb %x : i8
// CHECK: hw.instance "u" @Unused(a: [[P]]: i8) -> ()
hw.module @UseUnused() {
  %c0 = hw.constant 0 : i8
  %x = llhd.sig %c0 : <i8>
  hw.instance "u" @Unused(a: %x: !llhd.ref<i8>) -> ()
}

// A module that drives disjoint constant slices of a port (the bits it owns,
// others driving the rest) gets one output per slice; each instance drives the
// same slice of its signal.
// CHECK-LABEL: hw.module private @Slices(in %v : i2, in %w : i1, out p_0 : i2, out p_5 : i1)
// CHECK-NEXT: hw.output %v, %w : i2, i1
hw.module private @Slices(in %p : !llhd.ref<i8>, in %v : i2, in %w : i1) {
  %t = llhd.constant_time <0ns, 0d, 1e>
  %c0 = hw.constant 0 : i3
  %c5 = hw.constant 5 : i3
  %0 = llhd.sig.extract %p from %c0 : <i8> -> <i2>
  llhd.drv %0, %v after %t : i2
  %1 = llhd.sig.extract %p from %c5 : <i8> -> <i1>
  llhd.drv %1, %w after %t : i1
}
// CHECK-LABEL: hw.module @UseSlices
// CHECK: [[S0:%.+]] = llhd.sig.extract %x from {{%.+}} : <i8> -> <i2>
// CHECK: [[S5:%.+]] = llhd.sig.extract %x from {{%.+}} : <i8> -> <i1>
// CHECK: %s.p_0, %s.p_5 = hw.instance "s" @Slices(v: %v: i2, w: %w: i1) -> (p_0: i2, p_5: i1)
// CHECK: llhd.drv [[S0]], %s.p_0
// CHECK: llhd.drv [[S5]], %s.p_5
hw.module @UseSlices(in %v : i2, in %w : i1) {
  %c0 = hw.constant 0 : i8
  %x = llhd.sig %c0 : <i8>
  hw.instance "s" @Slices(p: %x: !llhd.ref<i8>, v: %v: i2, w: %w: i1) -> ()
}

// Struct fields work the same way.
// CHECK-LABEL: hw.module private @FieldSlice(in %v : i4, out p_b : i4)
hw.module private @FieldSlice(in %p : !llhd.ref<!hw.struct<a: i4, b: i4>>, in %v : i4) {
  %t = llhd.constant_time <0ns, 0d, 1e>
  %0 = llhd.sig.struct_extract %p["b"] : <!hw.struct<a: i4, b: i4>>
  llhd.drv %0, %v after %t : i4
}
// CHECK-LABEL: hw.module @UseFieldSlice
// CHECK: [[B:%.+]] = llhd.sig.struct_extract %x["b"] : <!hw.struct<a: i4, b: i4>>
// CHECK: %f.p_b = hw.instance "f" @FieldSlice(v: %v: i4) -> (p_b: i4)
// CHECK: llhd.drv [[B]], %f.p_b
hw.module @UseFieldSlice(in %v : i4) {
  %c0 = hw.constant 0 : i8
  %0 = hw.bitcast %c0 : (i8) -> !hw.struct<a: i4, b: i4>
  %x = llhd.sig %0 : <!hw.struct<a: i4, b: i4>>
  hw.instance "f" @FieldSlice(p: %x: !llhd.ref<!hw.struct<a: i4, b: i4>>, v: %v: i4) -> ()
}

// Overlapping slices keep the reference port.
// CHECK-LABEL: hw.module private @OverlappingSlices(in %p : !llhd.ref<i8>
hw.module private @OverlappingSlices(in %p : !llhd.ref<i8>, in %v : i2) {
  %t = llhd.constant_time <0ns, 0d, 1e>
  %c0 = hw.constant 0 : i3
  %c1 = hw.constant 1 : i3
  %0 = llhd.sig.extract %p from %c0 : <i8> -> <i2>
  llhd.drv %0, %v after %t : i2
  %1 = llhd.sig.extract %p from %c1 : <i8> -> <i2>
  llhd.drv %1, %v after %t : i2
}
hw.module @UseOverlappingSlices(in %v : i2) {
  %c0 = hw.constant 0 : i8
  %x = llhd.sig %c0 : <i8>
  hw.instance "o" @OverlappingSlices(p: %x: !llhd.ref<i8>, v: %v: i2) -> ()
}

// A drive inside a process happens under the process's control flow; the port
// stays a reference.
// CHECK-LABEL: hw.module private @DriveInProcess(in %p : !llhd.ref<i8>
hw.module private @DriveInProcess(in %p : !llhd.ref<i8>, in %v : i8) {
  %t = llhd.constant_time <0ns, 0d, 1e>
  llhd.process {
    llhd.drv %p, %v after %t : i8
    llhd.halt
  }
}
hw.module @UseDriveInProcess(in %v : i8) {
  %c0 = hw.constant 0 : i8
  %x = llhd.sig %c0 : <i8>
  hw.instance "d" @DriveInProcess(p: %x: !llhd.ref<i8>, v: %v: i8) -> ()
}
