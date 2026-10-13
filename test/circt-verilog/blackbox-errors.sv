// RUN: split-file %s %t
// RUN: circt-verilog --ir-hw --blackbox=mcell %t/type-param.sv | FileCheck %s --check-prefix=DEFAULT
// RUN: not circt-verilog --ir-hw --blackbox=mcell %t/type-param-overridden.sv 2>&1 | FileCheck %s --check-prefix=TYPE
// RUN: not circt-verilog --ir-hw --blackbox=ram %t/hier-ref.sv 2>&1 | FileCheck %s --check-prefix=HIER
// REQUIRES: slang

//--- type-param.sv
// A type parameter left at its default is derived by the module itself.
// DEFAULT: hw.module.extern @mcell<W: i32>(in %d : i5, out q : i5)
// DEFAULT: hw.instance "c0" @mcell<W: i32 = 5>(
module mcell #(parameter W = 2, parameter type T = logic [W-1:0]) (input T d, output T q);
  assign q = d;
endmodule
module top (input logic [4:0] d, output logic [4:0] q);
  mcell #(.W(5)) c0 (.d, .q);
endmodule

//--- type-param-overridden.sv
// An instance cannot pass a type to a black box.
// TYPE: error: black box type parameter `T` is overridden; only value parameters can be passed
module mcell #(parameter type T = logic [3:0], parameter W = 2) (input T d, output T q);
  assign q = d;
endmodule
module top (input logic [7:0] d, output logic [7:0] q);
  mcell #(.T(logic [7:0]), .W(5)) c0 (.d, .q);
endmodule

//--- hier-ref.sv
// The contents of a black box are not imported.
// HIER: error: hierarchical reference to `r` through black box `ram` is not supported
module ram (input logic clk, input logic [7:0] d, output logic [7:0] q);
  logic [7:0] r;
  always_ff @(posedge clk) r <= d;
  assign q = r;
endmodule
module top (input logic clk, input logic [7:0] d, output logic [7:0] q, output logic [7:0] peek);
  ram r0 (.clk, .d, .q);
  assign peek = r0.r;
endmodule
