// RUN: circt-verilog %s | FileCheck %s --check-prefixes=CHECK,MEMON
// RUN: circt-verilog --detect-memories=1 %s | FileCheck %s --check-prefixes=CHECK,MEMON
// RUN: circt-verilog --detect-memories=0 %s | FileCheck %s --check-prefixes=CHECK,MEMOFF
// REQUIRES: slang
// Internal issue in Slang v3 about jump depending on uninitialised value.
// UNSUPPORTED: valgrind

// CHECK-LABEL: hw.module @Memory(in %clock : !seq.clock,
module Memory(
  input  bit clock,
  input  bit [3:0] waddr,
  input  bit [41:0] wdata,
  input  bit wenable,
  input  bit [3:0] raddr,
  output bit [41:0] rdata
);
  // MEMON-DAG: [[MEM:%.+]] = seq.firmem 0, 1, undefined, undefined : <16 x 42, mask 1>
  // MEMON-DAG: [[RDATA:%.+]] = seq.firmem.read_port [[MEM]][%raddr]
  // MEMON-DAG: seq.firmem.write_port [[MEM]][%waddr] = %wdata, clock %clock enable %wenable

  // MEMOFF-DAG: [[REG:%.+]] = seq.firreg [[NEXT:%.+]] clock %clock : !hw.array<16xi42>
  // MEMOFF-DAG: [[TMP:%.+]] = hw.array_inject [[REG]][%waddr], %wdata
  // MEMOFF-DAG: [[NEXT]] = comb.mux bin %wenable, [[TMP]], [[REG]]
  // MEMOFF-DAG: [[RDATA:%.+]] = hw.array_get [[REG]][%raddr]

  // CHECK: hw.output [[RDATA]]
  bit [41:0] storage [15:0];
  always_ff @(posedge clock)
    if (wenable)
      storage[waddr] <= wdata;
  assign rdata = storage[raddr];
endmodule

// One conditional write per column of the word is a write mask.
// CHECK-LABEL: hw.module @ColumnWrites(
module ColumnWrites(
  input  bit clock,
  input  bit write,
  input  bit [3:0] wren,
  input  bit [5:0] addr,
  input  bit [31:0] wdata,
  output bit [31:0] rdata
);
  // MEMON: %ram = seq.firmem 0, 1, undefined, undefined : <64 x 32, mask 4>
  // MEMON: seq.firmem.write_port %ram[{{%.+}}] = {{%.+}}, clock %clock enable {{%.+}} mask {{%.+}} : <64 x 32, mask 4>, i4
  bit [31:0] ram [0:63];
  always_ff @(posedge clock)
    if (write)
      for (int i = 0; i < 4; ++i)
        if (wren[i])
          ram[addr][i * 8 +: 8] <= wdata[i * 8 +: 8];
  assign rdata = ram[addr];
endmodule

// A registered read address is a write-first memory with a read latency of
// one; the port registers the address the register would have taken. A
// register with a power-on value, such as a `bit`, would not be taken in.
// CHECK-LABEL: hw.module @WriteFirst(
module WriteFirst(
  input  bit clock,
  input  bit write,
  input  bit read,
  input  bit [5:0] waddr,
  input  bit [5:0] raddr,
  input  bit [31:0] wdata,
  output bit [31:0] rdata
);
  // MEMON: %ram = seq.firmem 1, 1, new, undefined : <64 x 32, mask 1>
  // MEMON: seq.firmem.read_port %ram[[[ADDR:%.+]]], clock %clock :
  // MEMON: [[NEXT:%.+]] = comb.mux bin %read, %raddr, %raddr_r
  // MEMON: [[ADDR]] = comb.sub {{%.+}}, [[NEXT]]
  bit [31:0] ram [0:63];
  logic [5:0] raddr_r;
  always_ff @(posedge clock) begin
    if (write)
      ram[waddr] <= wdata;
    if (read)
      raddr_r <= raddr;
  end
  assign rdata = ram[raddr_r];
endmodule

// Registered read data is a read-first memory with a read latency of one,
// read at the address of a single-port RAM that it also writes.
// CHECK-LABEL: hw.module @ReadFirst(
module ReadFirst(
  input  bit clock,
  input  bit write,
  input  bit read,
  input  bit [3:0] wren,
  input  bit [5:0] addr,
  input  bit [31:0] wdata,
  output bit [31:0] rdata
);
  // MEMON: %ram = seq.firmem 1, 1, old, undefined : <64 x 32, mask 4>
  // MEMON: [[RDATA:%.+]] = seq.firmem.read_port %ram[{{%.+}}], clock %clock enable %read :
  // MEMON-NOT: seq.firreg
  // MEMON: hw.output [[RDATA]]
  bit [31:0] ram [0:63];
  logic [31:0] rdata_r;
  always_ff @(posedge clock) begin
    if (write)
      for (int i = 0; i < 4; ++i)
        if (wren[i])
          ram[addr][i * 8 +: 8] <= wdata[i * 8 +: 8];
    if (read)
      rdata_r <= ram[addr];
  end
  assign rdata = rdata_r;
endmodule
