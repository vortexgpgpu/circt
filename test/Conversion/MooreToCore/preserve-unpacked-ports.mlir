// RUN: circt-opt %s --convert-moore-to-core=preserve-unpacked-ports | FileCheck %s
// RUN: circt-opt %s --convert-moore-to-core | FileCheck %s --check-prefix=PACKED

// The unpacked array ports of a top-level module keep their type, bitcast to
// and from the packed array the body works on.

// CHECK-LABEL: hw.module @Top
// CHECK-SAME: in %a : !hw.uarray<2xi8>
// CHECK-SAME: in %b : !hw.uarray<2xuarray<3xi4>>
// CHECK-SAME: in %c : i8
// CHECK-SAME: out y : !hw.uarray<2xi8>
// CHECK-SAME: out z : i8
// CHECK-NEXT: [[A:%.+]] = hw.bitcast %a : (!hw.uarray<2xi8>) -> !hw.array<2xi8>
// CHECK-NEXT: [[B:%.+]] = hw.bitcast %b : (!hw.uarray<2xuarray<3xi4>>) -> !hw.array<2xarray<3xi4>>
// CHECK: hw.instance "leaf" @Leaf(a: [[A]]: !hw.array<2xi8>, b: [[B]]: !hw.array<2xarray<3xi4>>)
// CHECK: [[Y:%.+]] = hw.bitcast %leaf.y : (!hw.array<2xi8>) -> !hw.uarray<2xi8>
// CHECK: hw.output [[Y]], %c : !hw.uarray<2xi8>, i8

// PACKED-LABEL: hw.module @Top
// PACKED-SAME: in %a : !hw.array<2xi8>
// PACKED-SAME: out y : !hw.array<2xi8>
moore.module @Top(in %a : !moore.uarray<2 x i8>, in %b : !moore.uarray<2 x uarray<3 x i4>>, in %c : !moore.i8, out y : !moore.uarray<2 x i8>, out z : !moore.i8) {
  %leaf.y = moore.instance "leaf" @Leaf(a: %a: !moore.uarray<2 x i8>, b: %b: !moore.uarray<2 x uarray<3 x i4>>) -> (y: !moore.uarray<2 x i8>)
  moore.output %leaf.y, %c : !moore.uarray<2 x i8>, !moore.i8
}

// An instantiated module keeps packed ports, so its instances need no casts.

// CHECK-LABEL: hw.module private @Leaf
// CHECK-SAME: in %a : !hw.array<2xi8>
// CHECK-SAME: out y : !hw.array<2xi8>
moore.module private @Leaf(in %a : !moore.uarray<2 x i8>, in %b : !moore.uarray<2 x uarray<3 x i4>>, out y : !moore.uarray<2 x i8>) {
  moore.output %a : !moore.uarray<2 x i8>
}
