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
