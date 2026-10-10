// RUN: circt-verilog --ir-moore %s | FileCheck %s
// REQUIRES: slang

// Interface ports connected to elements of interface instance arrays. The
// array elements must be expanded before the module instances that bind them
// are lowered, just like scalar interface instances.

interface bus_if;
  logic valid;
  logic [7:0] data;
  modport master(output valid, output data);
  modport slave(input valid, input data);
endinterface

// Bare (modport-less) interface port.
module BareProducer(input logic v, input logic [7:0] d, bus_if bus);
  assign bus.valid = v;
  assign bus.data = d;
endmodule

// Modport interface port.
module Consumer(bus_if.slave bus, output logic [7:0] q);
  assign q = bus.valid ? bus.data : 8'h0;
endmodule

// CHECK-LABEL: moore.module @ArrayElementPorts(
module ArrayElementPorts(input logic v, input logic [7:0] d,
                         output logic [7:0] q0, output logic [7:0] q1);
  bus_if links[2]();
  // CHECK-DAG: moore.instance "p0" @BareProducer(
  // CHECK-DAG: moore.instance "p1" @BareProducer(
  // CHECK-DAG: moore.instance "c0" @Consumer(
  // CHECK-DAG: moore.instance "c1" @Consumer(
  BareProducer p0(.v(v), .d(d), .bus(links[0]));
  BareProducer p1(.v(~v), .d(~d), .bus(links[1]));
  Consumer c0(.bus(links[0]), .q(q0));
  Consumer c1(.bus(links[1]), .q(q1));
endmodule

// CHECK-LABEL: moore.module @NestedArrayElementPorts(
module NestedArrayElementPorts(input logic v, input logic [7:0] d,
                               output logic [7:0] q);
  bus_if grid[2][2]();
  // CHECK-DAG: moore.instance "p" @BareProducer(
  // CHECK-DAG: moore.instance "c" @Consumer(
  BareProducer p(.v(v), .d(d), .bus(grid[1][0]));
  Consumer c(.bus(grid[1][0]), .q(q));
endmodule
