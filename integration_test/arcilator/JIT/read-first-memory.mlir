// RUN: arcilator %s --run --jit-entry=main | FileCheck --match-full-lines %s
// RUN: circt-opt %s --seq-reg-of-vec-to-mem | FileCheck %s --check-prefix=MEM
// RUN: circt-opt %s --seq-reg-of-vec-to-mem | arcilator --run --jit-entry=main | FileCheck --match-full-lines %s
// REQUIRES: arcilator-jit

// A register array read into an enabled data register simulates the same as
// the read-first memory it is detected as: a read of the address being written
// returns the old data, and the data holds while the read is disabled.

// MEM: seq.firmem 1, 1, old, undefined
// MEM: seq.firmem.read_port {{.+}} enable %re

// CHECK:      rdata = 00
// CHECK-NEXT: rdata = 11
// CHECK-NEXT: rdata = 11
// CHECK-NEXT: rdata = 11
// CHECK-NEXT: rdata = 33
// CHECK-NEXT: rdata = 44

hw.module @ReadFirst(in %clk : i1, in %raddr : i2, in %waddr : i2, in %wdata : i8, in %re : i1, in %we : i1, out rdata : i8) {
  %clock = seq.to_clock %clk
  %read = hw.array_get %mem[%raddr] : !hw.array<4xi8>, i2
  %hold = comb.mux %re, %read, %rdata_r : i8
  %rdata_r = seq.firreg %hold clock %clock : i8
  %write = hw.array_inject %mem[%waddr], %wdata : !hw.array<4xi8>, i2
  %next = comb.mux %we, %write, %mem : !hw.array<4xi8>
  %mem = seq.firreg %next clock %clock : !hw.array<4xi8>
  hw.output %rdata_r : i8
}

func.func @cycle(%model : !arc.sim.instance<@ReadFirst>, %raddr : i2, %waddr : i2, %wdata : i8, %re : i1, %we : i1) {
  %zero = arith.constant 0 : i1
  %one = arith.constant 1 : i1
  arc.sim.set_input %model, "raddr" = %raddr : i2, !arc.sim.instance<@ReadFirst>
  arc.sim.set_input %model, "waddr" = %waddr : i2, !arc.sim.instance<@ReadFirst>
  arc.sim.set_input %model, "wdata" = %wdata : i8, !arc.sim.instance<@ReadFirst>
  arc.sim.set_input %model, "re" = %re : i1, !arc.sim.instance<@ReadFirst>
  arc.sim.set_input %model, "we" = %we : i1, !arc.sim.instance<@ReadFirst>
  arc.sim.set_input %model, "clk" = %one : i1, !arc.sim.instance<@ReadFirst>
  arc.sim.step %model : !arc.sim.instance<@ReadFirst>
  arc.sim.set_input %model, "clk" = %zero : i1, !arc.sim.instance<@ReadFirst>
  arc.sim.step %model : !arc.sim.instance<@ReadFirst>
  %rdata = arc.sim.get_port %model, "rdata" : i8, !arc.sim.instance<@ReadFirst>
  arc.sim.emit "rdata", %rdata : i8
  return
}

func.func @main() {
  %f = arith.constant 0 : i1
  %t = arith.constant 1 : i1
  %a1 = arith.constant 1 : i2
  %a2 = arith.constant 2 : i2
  %d11 = arith.constant 17 : i8
  %d22 = arith.constant 34 : i8
  %d33 = arith.constant 51 : i8
  %d44 = arith.constant 68 : i8
  arc.sim.instantiate @ReadFirst as %model {
    // Write 0x11 to 1.
    func.call @cycle(%model, %a1, %a1, %d11, %f, %t) : (!arc.sim.instance<@ReadFirst>, i2, i2, i8, i1, i1) -> ()
    // Read 1 while writing 0x22 to it: the old data.
    func.call @cycle(%model, %a1, %a1, %d22, %t, %t) : (!arc.sim.instance<@ReadFirst>, i2, i2, i8, i1, i1) -> ()
    // Disabled while writing 0x33 to 1: the data holds.
    func.call @cycle(%model, %a1, %a1, %d33, %f, %t) : (!arc.sim.instance<@ReadFirst>, i2, i2, i8, i1, i1) -> ()
    // Disabled while writing 0x44 to 2.
    func.call @cycle(%model, %a2, %a2, %d44, %f, %t) : (!arc.sim.instance<@ReadFirst>, i2, i2, i8, i1, i1) -> ()
    // Read 1 and 2.
    func.call @cycle(%model, %a1, %a1, %d11, %t, %f) : (!arc.sim.instance<@ReadFirst>, i2, i2, i8, i1, i1) -> ()
    func.call @cycle(%model, %a2, %a1, %d11, %t, %f) : (!arc.sim.instance<@ReadFirst>, i2, i2, i8, i1, i1) -> ()
  }
  return
}
