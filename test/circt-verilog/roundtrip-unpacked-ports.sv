// RUN: circt-verilog --preserve-unpacked-ports %s | circt-opt -export-verilog -o /dev/null | FileCheck %s
// REQUIRES: slang
// UNSUPPORTED: valgrind

// The unpacked array ports of a top-level module keep their elements in place:
// z[0] is b and z[1] is a[1].

// CHECK-LABEL: module top(
// CHECK-NEXT:    input  [7:0] a[0:1],
// CHECK-NEXT:                 b,
// CHECK-NEXT:    output [7:0] z[0:1]
// CHECK:         wire [7:0] {{ *}}[[A1:_GEN[_0-9]*]];
// CHECK:         wire [7:0] {{ *}}[[A:_GEN[_0-9]*]][0:1];
// CHECK-NEXT:    assign [[A]] = a;
// CHECK-NEXT:    wire [1:0][7:0] [[P:_GEN[_0-9]*]] = {{[{][{]}}[[A]][1'h0]}, {[[A]][1'h1]{{[}][}]}};
// CHECK-NEXT:    wire [1:0][7:0] [[Z:_GEN[_0-9]*]] = {{[{][{]}}b}, {[[A1]]{{[}][}]}};
// CHECK-NEXT:    assign [[A1]] = [[P]][1'h0];
// CHECK-NEXT:    assign z = '{[[Z]][1'h1], [[Z]][1'h0]};
module top(input logic [7:0] a [0:1], input logic [7:0] b,
           output logic [7:0] z [0:1]);
  assign z[0] = b;
  assign z[1] = a[1];
endmodule
