// RUN: circt-opt %s --hw-flatten-modules="hw-inline-all=false hw-inline-empty=false hw-inline-no-outputs=false hw-inline-single-use=false hw-inline-small=false hw-inline-marked" | FileCheck %s

// Only the module marked `hw.inline` is inlined, although it has state; the
// unmarked one stays, although it is small and used once.
// CHECK-NOT:   hw.module private @Marked
// CHECK-LABEL: hw.module private @Unmarked
// CHECK-LABEL: hw.module @Top
// CHECK:       %m2Fr = seq.firreg %a clock %clk
// CHECK:       hw.instance "u" @Unmarked
hw.module private @Marked(in %clk : !seq.clock, in %a : i4, out b : i4) attributes {hw.inline} {
  %r = seq.firreg %a clock %clk : i4
  hw.output %r : i4
}
hw.module private @Unmarked(in %a : i4, out b : i4) {
  hw.output %a : i4
}
hw.module @Top(in %clk : !seq.clock, in %a : i4, out b : i4, out c : i4) {
  %b = hw.instance "m" @Marked(clk: %clk : !seq.clock, a: %a : i4) -> (b : i4)
  %c = hw.instance "u" @Unmarked(a: %a : i4) -> (b : i4)
  hw.output %b, %c : i4, i4
}
