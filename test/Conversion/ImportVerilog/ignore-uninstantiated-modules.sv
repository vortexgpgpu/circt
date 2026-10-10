// RUN: circt-verilog --ir-moore --top=Top --ignore-uninstantiated-modules %s | FileCheck %s
// RUN: not circt-verilog --ir-moore --top=Top %s 2>&1 | FileCheck %s --check-prefix=ERR
// REQUIRES: slang

package cfg_pkg;
  localparam int ID_WIDTH = 1;
endpackage

// A helper that is only valid when cfg_pkg::ID_WIDTH is wide, and is not
// instantiated in this configuration: slang still checks it unless
// uninstantiated modules are ignored.
module Helper import cfg_pkg::*; (input logic [7:0] a, output logic [ID_WIDTH-1:0] y);
  localparam int GW = ID_WIDTH - 32;
  // ERR: error: value must be positive
  wire [31:0] g = 32'(GW'(a));
  assign y = ID_WIDTH'(g);
endmodule

// CHECK-LABEL: moore.module @Top(
// CHECK-NOT: moore.module @Helper
module Top(input logic [7:0] a, output logic [7:0] y);
  assign y = a;
endmodule
