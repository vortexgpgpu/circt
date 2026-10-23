// RUN: circt-opt %s --pass-pipeline='builtin.module(hw.module(synth-lower-variadic))' | FileCheck %s

// The timing-aware lowering asks the analysis for the delay of a divider,
// which it cannot lower to AIG. The divider becomes a start point, and no
// error is reported.
// CHECK-LABEL: hw.module @Divider
// CHECK-NOT: error
// CHECK: comb.divu
hw.module @Divider(in %a: i8, in %b: i8, in %c: i8, in %d: i8, out f: i8) {
  %q = comb.divu %a, %b : i8
  %0 = synth.aig.and_inv %q, %c, %d, %a : i8
  hw.output %0 : i8
}
