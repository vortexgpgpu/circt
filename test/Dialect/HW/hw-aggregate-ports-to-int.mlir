// RUN: circt-opt %s --hw-aggregate-ports-to-int | FileCheck %s

// Array and struct ports take integers of the same bits: the module bitcasts
// at its boundary, and so does each instance.
// CHECK-LABEL: hw.module.extern @Ext(in %a : i8, out b : i6)
hw.module.extern @Ext(in %a : !hw.array<2xi4>, out b : !hw.struct<x: i2, y: i4>)

// CHECK-LABEL: hw.module @Leaf(in %a : i8, in %n : i3, out b : i4)
// CHECK-NEXT:    %[[A:.+]] = hw.bitcast %a : (i8) -> !hw.array<2xi4>
// CHECK:         %[[B:.+]] = hw.array_get %[[A]]
// CHECK-NEXT:    hw.output %[[B]] : i4
hw.module @Leaf(in %a : !hw.array<2xi4>, in %n : i3, out b : i4) {
  %c0 = hw.constant 0 : i1
  %b = hw.array_get %a[%c0] : !hw.array<2xi4>, i1
  hw.output %b : i4
}

// CHECK-LABEL: hw.module @Top(in %a : i8, out b : i4, out c : i6)
// CHECK:         %[[A:.+]] = hw.bitcast %a : (i8) -> !hw.array<2xi4>
// CHECK:         %[[A2:.+]] = hw.bitcast %[[A]] : (!hw.array<2xi4>) -> i8
// CHECK:         %leaf.b = hw.instance "leaf" @Leaf(a: %[[A2]]: i8, n: %{{.+}}: i3) -> (b: i4)
// CHECK:         %[[A3:.+]] = hw.bitcast %[[A]] : (!hw.array<2xi4>) -> i8
// CHECK:         %[[E:.+]] = hw.instance "ext" @Ext(a: %[[A3]]: i8) -> (b: i6)
// CHECK:         %[[ES:.+]] = hw.bitcast %[[E]] : (i6) -> !hw.struct<x: i2, y: i4>
// CHECK:         %[[EI:.+]] = hw.bitcast %[[ES]] : (!hw.struct<x: i2, y: i4>) -> i6
// CHECK:         hw.output %leaf.b, %[[EI]] : i4, i6
hw.module @Top(in %a : !hw.array<2xi4>, out b : i4, out c : !hw.struct<x: i2, y: i4>) {
  %n = hw.constant 0 : i3
  %b = hw.instance "leaf" @Leaf(a: %a: !hw.array<2xi4>, n: %n: i3) -> (b: i4)
  %c = hw.instance "ext" @Ext(a: %a: !hw.array<2xi4>) -> (b: !hw.struct<x: i2, y: i4>)
  hw.output %b, %c : i4, !hw.struct<x: i2, y: i4>
}
