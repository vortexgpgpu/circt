// RUN: circt-opt %s --comb-share-adders | FileCheck %s

// CHECK-LABEL: hw.module @Sums
// CHECK:         [[M:%.+]] = comb.mux %c, %b, %d : i8
// CHECK:         [[S:%.+]] = comb.add %a, [[M]] : i8
// CHECK:         hw.output [[S]]
hw.module @Sums(in %c : i1, in %a : i8, in %b : i8, in %d : i8, out y : i8) {
  %0 = comb.add %a, %b : i8
  %1 = comb.add %d, %a : i8
  %y = comb.mux %c, %0, %1 : i8
  hw.output %y : i8
}

// CHECK-LABEL: hw.module @Differences
// CHECK:         [[M:%.+]] = comb.mux %c, %b, %d : i8
// CHECK:         [[S:%.+]] = comb.sub %a, [[M]] : i8
// CHECK:         hw.output [[S]]
hw.module @Differences(in %c : i1, in %a : i8, in %b : i8, in %d : i8, out y : i8) {
  %0 = comb.sub %a, %b : i8
  %1 = comb.sub %a, %d : i8
  %y = comb.mux %c, %0, %1 : i8
  hw.output %y : i8
}

// `a + u` or `a - u` for a mux of constants `u`: `a` plus `u` or `-u`.
// CHECK-LABEL: hw.module @PlusMinus
// CHECK-DAG:     [[U:%.+]] = comb.mux %n, %c4_i8, %c8_i8 : i8
// CHECK-DAG:     [[NU:%.+]] = comb.mux %n, %c-4_i8, %c-8_i8 : i8
// CHECK:         [[M:%.+]] = comb.mux %q, [[U]], [[NU]] : i8
// CHECK:         [[S:%.+]] = comb.add %a, [[M]] : i8
// CHECK:         hw.output [[S]]
hw.module @PlusMinus(in %q : i1, in %n : i1, in %a : i8, out y : i8) {
  %c4_i8 = hw.constant 4 : i8
  %c8_i8 = hw.constant 8 : i8
  %u = comb.mux %n, %c4_i8, %c8_i8 : i8
  %0 = comb.add %a, %u : i8
  %1 = comb.sub %a, %u : i8
  %y = comb.mux %q, %0, %1 : i8
  hw.output %y : i8
}

// Negating a variable subtrahend is not free: two adders stay.
// CHECK-LABEL: hw.module @Variable
// CHECK:         comb.add %a, %b
// CHECK:         comb.sub %a, %d
hw.module @Variable(in %c : i1, in %a : i8, in %b : i8, in %d : i8, out y : i8) {
  %0 = comb.add %a, %b : i8
  %1 = comb.sub %a, %d : i8
  %y = comb.mux %c, %0, %1 : i8
  hw.output %y : i8
}

// A sum used elsewhere stays: sharing would not remove it.
// CHECK-LABEL: hw.module @Used
// CHECK:         comb.mux %c, %0, %1
hw.module @Used(in %c : i1, in %a : i8, in %b : i8, in %d : i8, out y : i8, out z : i8) {
  %0 = comb.add %a, %b : i8
  %1 = comb.add %a, %d : i8
  %y = comb.mux %c, %0, %1 : i8
  hw.output %y, %0 : i8, i8
}
