// RUN: circt-translate --import-verilog %s | FileCheck %s
// REQUIRES: slang

// An operand propagated to the type of the expression it is part of is extended
// according to that type, whatever its own signedness (IEEE 1800-2017
// § 11.8.2): `4'(I)` is signed, as `I` is, but `4'(I) - b` is unsigned since
// `b` is, so `4'(I)` is zero-extended to the five bits of the assignment.

// CHECK-LABEL: moore.module @Propagated
module Propagated(input logic [3:0] b, output logic [4:0] y, output logic [4:0] z);
  localparam int I = 9;
  // CHECK-DAG: [[NINE:%.+]] = moore.constant 9 : l5
  // CHECK-DAG: [[B:%.+]] = moore.zext {{%.+}} : l4 -> l5
  // CHECK-DAG: moore.sub [[NINE]], [[B]] : l5
  assign y = 4'(I) - b;
  // A signed expression sign-extends its signed operands.
  // CHECK-DAG: [[MINUS7:%.+]] = moore.constant -7 : l5
  // CHECK-DAG: moore.add [[MINUS7]], {{%.+}} : l5
  assign z = 4'(I) + 5'sd1;
endmodule
