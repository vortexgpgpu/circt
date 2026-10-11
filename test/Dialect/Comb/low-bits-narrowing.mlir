// RUN: circt-opt %s --comb-low-bits-narrowing | FileCheck %s

// The low 4 bits of `b` are zero: the sum's are `a`'s.
// CHECK-LABEL: hw.module @AddOne
// CHECK:         [[B:%.+]] = comb.concat %x
// CHECK-DAG:     [[AH:%.+]] = comb.extract %a from 4 : (i8) -> i4
// CHECK-DAG:     [[BH:%.+]] = comb.extract [[B]] from 4 : (i8) -> i4
// CHECK:         [[H:%.+]] = comb.add [[AH]], [[BH]] : i4
// CHECK:         [[AL:%.+]] = comb.extract %a from 0 : (i8) -> i4
// CHECK:         [[R:%.+]] = comb.concat [[H]], [[AL]] : i4, i4
// CHECK:         hw.output [[R]]
hw.module @AddOne(in %a : i8, in %x : i4, out y : i8) {
  %c0_i4 = hw.constant 0 : i4
  %b = comb.concat %x, %c0_i4 : i4, i4
  %y = comb.add %a, %b : i8
  hw.output %y : i8
}

// A mux of constants: the low 2 bits of both arms are zero, so the sum's low
// 2 bits are `a`'s and the upper bits come from a 6-bit add.
// CHECK-LABEL: hw.module @AddMux
// CHECK:         comb.add {{.*}} : i6
// CHECK:         comb.concat {{.*}} : i6, i2
hw.module @AddMux(in %a : i8, in %s : i1, out y : i8) {
  %c4 = hw.constant 4 : i8
  %c16 = hw.constant 16 : i8
  %m = comb.mux %s, %c4, %c16 : i8
  %y = comb.add %a, %m : i8
  hw.output %y : i8
}

// Both operands have 2 low zeros: the sum's low bits are zero.
// CHECK-LABEL: hw.module @AddAll
// CHECK:         [[Z:%.+]] = hw.constant 0 : i2
// CHECK:         [[H:%.+]] = comb.add {{.*}} : i6
// CHECK:         comb.concat [[H]], [[Z]] : i6, i2
hw.module @AddAll(in %x : i6, in %z : i6, out y : i8) {
  %c0_i2 = hw.constant 0 : i2
  %a = comb.concat %x, %c0_i2 : i6, i2
  %b = comb.concat %z, %c0_i2 : i6, i2
  %y = comb.add %a, %b : i8
  hw.output %y : i8
}

// `a` has 2 low zeros and `b` 3: the low 3 bits are `a`'s.
// CHECK-LABEL: hw.module @AddFewest
// CHECK:         [[H:%.+]] = comb.add {{.*}} : i5
// CHECK:         [[L:%.+]] = comb.extract [[A:%.+]] from 0 : (i8) -> i3
// CHECK:         comb.concat [[H]], [[L]] : i5, i3
hw.module @AddFewest(in %x : i6, in %z : i5, out y : i8) {
  %c0_i2 = hw.constant 0 : i2
  %c0_i3 = hw.constant 0 : i3
  %a = comb.concat %x, %c0_i2 : i6, i2
  %b = comb.concat %z, %c0_i3 : i5, i3
  %y = comb.add %a, %b : i8
  hw.output %y : i8
}

// Two operands with nonzero low bits: nothing to narrow.
// CHECK-LABEL: hw.module @AddNone
// CHECK:         comb.add %a, %b : i8
hw.module @AddNone(in %a : i8, in %b : i8, out y : i8) {
  %y = comb.add %a, %b : i8
  hw.output %y : i8
}

// The subtrahend's low 3 bits are zero: no borrow out of the minuend's.
// CHECK-LABEL: hw.module @Sub
// CHECK:         [[AH:%.+]] = comb.extract %a from 3 : (i8) -> i5
// CHECK:         [[H:%.+]] = comb.sub [[AH]], {{%.+}} : i5
// CHECK:         [[AL:%.+]] = comb.extract %a from 0 : (i8) -> i3
// CHECK:         comb.concat [[H]], [[AL]] : i5, i3
hw.module @Sub(in %a : i8, in %x : i5, out y : i8) {
  %c0_i3 = hw.constant 0 : i3
  %b = comb.concat %x, %c0_i3 : i5, i3
  %y = comb.sub %a, %b : i8
  hw.output %y : i8
}

// Only the minuend's low bits are zero: a borrow comes out of them.
// CHECK-LABEL: hw.module @SubMinuend
// CHECK:         comb.sub {{%.+}}, %b : i8
hw.module @SubMinuend(in %x : i5, in %b : i8, out y : i8) {
  %c0_i3 = hw.constant 0 : i3
  %a = comb.concat %x, %c0_i3 : i5, i3
  %y = comb.sub %a, %b : i8
  hw.output %y : i8
}
