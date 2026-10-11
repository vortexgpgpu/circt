// RUN: circt-opt %s -export-verilog -verify-diagnostics | FileCheck %s

// Verilog does not assign between packed and unpacked arrays, so bitcasts to
// and from unpacked arrays are emitted element by element.

// CHECK-LABEL: module Ports(
// CHECK-NEXT:    input  [7:0] a[0:1],
// CHECK-NEXT:    output [7:0] y[0:1],
// CHECK:         wire [7:0] {{ *}}[[A:_GEN[_0-9]*]][0:1];
// CHECK-NEXT:    assign [[A]] = a;
// CHECK-NEXT:    wire [1:0][7:0] [[P:_GEN[_0-9]*]] = {{[{][{]}}[[A]][1'h1]}, {[[A]][1'h0]{{[}][}]}};
// CHECK-NEXT:    assign y = '{[[P]][1'h0], [[P]][1'h1]};
// CHECK-NEXT:    assign s = [[P]][1'h1] + [[P]][1'h0];
hw.module @Ports(in %a : !hw.uarray<2xi8>, out y : !hw.uarray<2xi8>, out s : i8) {
  %0 = hw.bitcast %a : (!hw.uarray<2xi8>) -> !hw.array<2xi8>
  %true = hw.constant true
  %false = hw.constant false
  %1 = hw.array_get %0[%true] : !hw.array<2xi8>, i1
  %2 = hw.array_get %0[%false] : !hw.array<2xi8>, i1
  %3 = comb.add %1, %2 : i8
  %4 = hw.bitcast %0 : (!hw.array<2xi8>) -> !hw.uarray<2xi8>
  hw.output %4, %3 : !hw.uarray<2xi8>, i8
}

// Nested unpacked dimensions are copied one level at a time, and a bitcast
// that also changes the shape goes through the packed array of the same
// dimensions.

// CHECK-LABEL: module Nested(
// CHECK-NEXT:    input  [3:0]  b[0:1][0:1],
// CHECK-NEXT:    output [15:0] w
// CHECK:         wire [3:0] [[B:_GEN[_0-9]*]][0:1][0:1];
// CHECK-NEXT:    assign [[B]] = b;
// CHECK-NEXT:    wire [3:0] [[B1:_GEN[_0-9]*]][0:1];
// CHECK-NEXT:    assign [[B1]] = [[B]][1'h1];
// CHECK-NEXT:    wire [3:0] [[B0:_GEN[_0-9]*]][0:1];
// CHECK-NEXT:    assign [[B0]] = [[B]][1'h0];
// CHECK-NEXT:    assign w =
// CHECK-NEXT:      /*cast(bit[15:0])*/{{.*}}[[B1]][1'h1]{{.*}}[[B1]][1'h0]{{.*}}
// CHECK-NEXT:      {{.*}}[[B0]][1'h1]{{.*}}[[B0]][1'h0]{{.*}};
hw.module @Nested(in %b : !hw.uarray<2xuarray<2xi4>>, out w : i16) {
  %0 = hw.bitcast %b : (!hw.uarray<2xuarray<2xi4>>) -> i16
  hw.output %0 : i16
}
