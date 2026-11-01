// RUN: circt-opt --llhd-infer-noalias-ports %s | FileCheck %s

// Ports bound to distinct signals at every instance are marked, also when they
// are forwarded through a module whose own ports are marked.

// CHECK-LABEL: hw.module private @Leaf
// CHECK-SAME: in %a : !llhd.ref<i8> {llhd.noalias}
// CHECK-SAME: in %b : !llhd.ref<i8> {llhd.noalias}
// CHECK-SAME: in %c : i8)
hw.module private @Leaf(in %a : !llhd.ref<i8>, in %b : !llhd.ref<i8>, in %c : i8) {
}

// CHECK-LABEL: hw.module private @Mid
// CHECK-SAME: in %a : !llhd.ref<i8> {llhd.noalias}
// CHECK-SAME: in %b : !llhd.ref<i8> {llhd.noalias}
hw.module private @Mid(in %a : !llhd.ref<i8>, in %b : !llhd.ref<i8>) {
  %c0 = hw.constant 0 : i8
  hw.instance "leaf" @Leaf(a: %a: !llhd.ref<i8>, b: %b: !llhd.ref<i8>, c: %c0: i8) -> ()
}

// CHECK-LABEL: hw.module @Top
// CHECK-SAME: in %p : !llhd.ref<i8>)
hw.module @Top(in %p : !llhd.ref<i8>) {
  %c0 = hw.constant 0 : i8
  %x = llhd.sig %c0 : <i8>
  %y = llhd.sig %c0 : <i8>
  hw.instance "mid0" @Mid(a: %x: !llhd.ref<i8>, b: %y: !llhd.ref<i8>) -> ()
  // A signal declared in a module is never bound to one of its ports.
  hw.instance "mid1" @Mid(a: %x: !llhd.ref<i8>, b: %p: !llhd.ref<i8>) -> ()
}

// One signal bound to two ports, directly or through projections, marks
// neither; a third port bound to another signal is marked.
// CHECK-LABEL: hw.module private @SameSignal
// CHECK-SAME: in %a : !llhd.ref<i4>, in %b : !llhd.ref<i4>, in %c : !llhd.ref<i8> {llhd.noalias})
hw.module private @SameSignal(in %a : !llhd.ref<i4>, in %b : !llhd.ref<i4>, in %c : !llhd.ref<i8>) {
}
hw.module @UseSameSignal() {
  %c0 = hw.constant 0 : i8
  %c0_i3 = hw.constant 0 : i3
  %c4_i3 = hw.constant 4 : i3
  %x = llhd.sig %c0 : <i8>
  %y = llhd.sig %c0 : <i8>
  %lo = llhd.sig.extract %x from %c0_i3 : <i8> -> <i4>
  %hi = llhd.sig.extract %x from %c4_i3 : <i8> -> <i4>
  hw.instance "s" @SameSignal(a: %lo: !llhd.ref<i4>, b: %hi: !llhd.ref<i4>, c: %y: !llhd.ref<i8>) -> ()
}

// Ports of a public module may be bound to the same signal: the ports they are
// forwarded to are not marked, nor are the ports of the public module itself.
// CHECK-LABEL: hw.module private @FromPublic
// CHECK-SAME: in %a : !llhd.ref<i8>, in %b : !llhd.ref<i8>)
hw.module private @FromPublic(in %a : !llhd.ref<i8>, in %b : !llhd.ref<i8>) {
}
// CHECK-LABEL: hw.module @Public
// CHECK-SAME: in %a : !llhd.ref<i8>, in %b : !llhd.ref<i8>)
hw.module @Public(in %a : !llhd.ref<i8>, in %b : !llhd.ref<i8> {llhd.noalias}) {
  hw.instance "f" @FromPublic(a: %a: !llhd.ref<i8>, b: %b: !llhd.ref<i8>) -> ()
}

// A stale mark is removed when a port may alias another one.
// CHECK-LABEL: hw.module private @Stale
// CHECK-SAME: in %a : !llhd.ref<i8>, in %b : !llhd.ref<i8>)
hw.module private @Stale(in %a : !llhd.ref<i8> {llhd.noalias}, in %b : !llhd.ref<i8> {llhd.noalias}) {
}
hw.module @UseStale() {
  %c0 = hw.constant 0 : i8
  %x = llhd.sig %c0 : <i8>
  %y = llhd.sig %c0 : <i8>
  hw.instance "s0" @Stale(a: %x: !llhd.ref<i8>, b: %y: !llhd.ref<i8>) -> ()
  hw.instance "s1" @Stale(a: %x: !llhd.ref<i8>, b: %x: !llhd.ref<i8>) -> ()
}
