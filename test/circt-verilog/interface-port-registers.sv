// RUN: circt-verilog %s | FileCheck %s
// REQUIRES: slang

// Members of an interface instance passed through interface ports without a
// modport, which a leaf module drives in an `always_ff` and reads back, are
// registers of the leaf whose values reach the module declaring the
// interface instance, also through a module that only forwards the port.

interface bus_if;
  logic       valid;
  logic [7:0] data;
  logic       ready;
endinterface

// CHECK-LABEL: hw.module private @Leaf(
// CHECK-NOT: llhd.
// CHECK-DAG: [[VALID:%.+]] = seq.firreg {{%.+}} clock %clk
// CHECK-DAG: [[DATA:%.+]] = seq.firreg {{%.+}} clock %clk
// CHECK: hw.output {{.*}}[[VALID]]
module Leaf (input logic clk, input logic rst, bus_if b);
  assign b.ready = 1'b1;
  always_ff @(posedge clk) begin
    if (rst) begin
      b.valid <= 1'b0;
      b.data  <= 8'h0;
    end else begin
      b.valid <= ~b.valid;
      b.data  <= b.data + 8'd1;
    end
  end
endmodule

// CHECK-LABEL: hw.module private @Mid(
// CHECK-NOT: llhd.
// CHECK: hw.instance "leaf" @Leaf(
module Mid (input logic clk, input logic rst, bus_if b);
  Leaf leaf (.clk(clk), .rst(rst), .b(b));
endmodule

// CHECK-LABEL: hw.module @InterfacePortRegisters(
// CHECK-NOT: llhd.
// CHECK: hw.instance "mid" @Mid(
// CHECK-NOT: llhd.
// CHECK: hw.output
module InterfacePortRegisters (input logic clk, input logic rst,
                               output logic valid, output logic [7:0] data,
                               output logic ready);
  bus_if bus ();
  Mid mid (.clk(clk), .rst(rst), .b(bus));
  assign valid = bus.valid;
  assign data  = bus.data;
  assign ready = bus.ready;
endmodule
