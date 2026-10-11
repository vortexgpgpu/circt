// RUN: circt-translate --import-verilog %s | FileCheck %s
// RUN: circt-verilog --ir-hw %s | FileCheck %s --check-prefix=HW
// REQUIRES: slang

// The `(* ... *)` attributes of variable and net declarations become SV
// attributes on the declaring op, and survive the lowering to the core
// dialects: on the memory, register or wire that the declaration becomes.

// CHECK-LABEL: moore.module @Attributes
// HW-LABEL: hw.module @Attributes
module Attributes(input logic clk, we, input logic [1:0] addr,
                  input logic [7:0] a, b, output logic [7:0] q, r, p);
  // CHECK: %ram = moore.variable {sv.attributes = [#sv.attribute<"rw_addr_collision" = "\22yes\22">, #sv.attribute<"ram_style" = "\22block\22">]} : <uarray<4 x l8>>
  // HW-DAG: %ram = seq.firmem {{.*}} {sv.attributes = [#sv.attribute<"rw_addr_collision" = "\22yes\22">, #sv.attribute<"ram_style" = "\22block\22">]} : <4 x 8, mask 1>
  (* rw_addr_collision = "yes" *) (* ram_style = "block" *) reg [7:0] ram [0:3];
  // CHECK: %keep_r = moore.variable {sv.attributes = [#sv.attribute<"keep" = "\22true\22">]} : <l8>
  // HW-DAG: %keep_r = seq.firreg {{.*}} {sv.attributes = [#sv.attribute<"keep" = "\22true\22">]} : i8
  (* keep = "true" *) reg [7:0] keep_r;
  // CHECK: %prod = moore.net wire {{.*}} {sv.attributes = [#sv.attribute<"use_dsp" = "\22yes\22">]} : <l8>
  // HW-DAG: %prod = hw.wire {{.*}} {sv.attributes = [#sv.attribute<"use_dsp" = "\22yes\22">]} : i8
  (* use_dsp = "yes" *) wire [7:0] prod = a * b;
  // CHECK: %stall = moore.net wire {{.*}} {sv.attributes = [#sv.attribute<"max_fanout" = "64">]} : <l1>
  // HW-DAG: %stall = hw.wire {{.*}} {sv.attributes = [#sv.attribute<"max_fanout" = "64">]} : i1
  (* max_fanout = 64 *) wire stall = we & a[0];
  always @(posedge clk) begin
    if (we) ram[addr] <= b;
    q <= ram[addr];
    keep_r <= stall ? a : keep_r;
  end
  assign r = keep_r;
  assign p = prod;
endmodule
