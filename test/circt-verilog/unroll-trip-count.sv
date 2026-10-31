// RUN: circt-verilog %s | FileCheck %s --check-prefix=DEFAULT
// RUN: circt-verilog --max-unroll-trip-count=2048 %s | FileCheck %s --check-prefix=MORE
// REQUIRES: slang

// A combinational loop of 1100 iterations is left a process by default (loops
// of 1024 iterations or more are not unrolled); --max-unroll-trip-count lets
// the import unroll it into logic.

// DEFAULT-LABEL: hw.module @Reduce
// DEFAULT:         llhd.combinational
// MORE-LABEL:    hw.module @Reduce
// MORE-NOT:        llhd.combinational
// MORE:            hw.output
module Reduce(input logic [1099:0] a, input logic [1099:0] b, output logic y);
  always_comb begin
    y = 1'b0;
    for (int i = 0; i < 1100; ++i)
      y |= a[i] & b[1099 - i];
  end
endmodule
