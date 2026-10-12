// RUN: circt-verilog --ir-hw --top=top --blackbox=ram %s | FileCheck %s
// REQUIRES: slang

// Each specialization of a black box is an external module under the module's
// own name, its localparams left out; each instance spells its parameter
// values out, and the contents are not imported.
// CHECK-DAG: hw.module.extern @ram<DATAW: i32, SIZE: i32, ADDRW: i32>(in %clk : i1, in %write : i1, in %waddr : i4, in %wdata : i8, in %raddr : i4, out rdata : i8) attributes {{{.*}}verilogName = "ram"}
// CHECK-DAG: hw.module.extern @ram_0<DATAW: i32, SIZE: i32, ADDRW: i32>(in %clk : i1, in %write : i1, in %waddr : i3, in %wdata : i16, in %raddr : i3, out rdata : i16) attributes {{{.*}}verilogName = "ram"}
// CHECK-LABEL: hw.module @top
// CHECK: hw.instance "r0" @ram<DATAW: i32 = 8, SIZE: i32 = 16, ADDRW: i32 = 4>(
// CHECK: hw.instance "r1" @ram_0<DATAW: i32 = 16, SIZE: i32 = 8, ADDRW: i32 = 3>(
// CHECK-NOT: seq.firmem

module ram #(parameter DATAW = 1, parameter SIZE = 4, parameter ADDRW = $clog2(SIZE)) (
  input wire clk, input wire write, input wire [ADDRW-1:0] waddr, input wire [DATAW-1:0] wdata,
  input wire [ADDRW-1:0] raddr, output wire [DATAW-1:0] rdata);
  localparam WORDS = SIZE;
  reg [DATAW-1:0] mem [0:WORDS-1];
  always @(posedge clk) if (write) mem[waddr] <= wdata;
  assign rdata = mem[raddr];
endmodule

module top (input wire clk, input wire w, input wire [3:0] a, input wire [7:0] d,
            output wire [7:0] q0, output wire [15:0] q1);
  ram #(.DATAW(8), .SIZE(16)) r0 (.clk, .write(w), .waddr(a), .wdata(d), .raddr(a), .rdata(q0));
  ram #(.DATAW(16), .SIZE(8)) r1 (.clk, .write(w), .waddr(a[2:0]), .wdata({d, d}), .raddr(a[2:0]), .rdata(q1));
endmodule
