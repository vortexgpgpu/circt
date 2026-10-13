// RUN: circt-opt %s --pass-pipeline='builtin.module(seq-retime-firmem-reads{mode=auto})' | FileCheck %s
// RUN: circt-opt %s --pass-pipeline='builtin.module(seq-retime-firmem-reads{mode=auto min-bits=65536})' | FileCheck %s --check-prefix=SMALL
// RUN: circt-opt %s --seq-retime-firmem-reads | FileCheck %s --check-prefix=OFF

// None of these memories has a hint: by default they are left alone.
// OFF-NOT: seq.firmem 1,

// Three reads at registered addresses: plain, held with a synchronous reset,
// and logic of two registers. Each reads the next address on the clock; the
// memory reads new data.
// CHECK-LABEL: hw.module @Registered
// CHECK:       %mem = seq.firmem 1, 1, new, undefined : <1024 x 32, mask 1>
// CHECK-DAG:   seq.firmem.read_port %mem[%raddr], clock %clk : <1024 x 32, mask 1>
// CHECK-DAG:   %[[HELD:.+]] = comb.mux %hold, %ra1, %{{.+}} : i10
// CHECK-DAG:   %[[A1:.+]] = comb.mux %reset, %c3_i10, %[[HELD]] : i10
// CHECK-DAG:   seq.firmem.read_port %mem[%[[A1]]], clock %clk : <1024 x 32, mask 1>
// CHECK-DAG:   %[[HN:.+]] = comb.extract %raddr from 1 : (i10) -> i9
// CHECK-DAG:   %[[A2:.+]] = comb.concat %[[HN]], %{{.+}} : i9, i1
// CHECK-DAG:   seq.firmem.read_port %mem[%[[A2]]], clock %clk : <1024 x 32, mask 1>
// SMALL-LABEL: hw.module @Registered
// SMALL:       seq.firmem 0, 1, undefined, undefined
hw.module @Registered(in %clk : !seq.clock, in %reset : i1, in %we : i1, in %waddr : i10, in %wdata : i32, in %raddr : i10, in %hold : i1, out q0 : i32, out q1 : i32, out q2 : i32) {
  %c3_i10 = hw.constant 3 : i10
  %c21_i10 = hw.constant 21 : i10
  %true = hw.constant true
  %mem = seq.firmem 0, 1, undefined, undefined : <1024 x 32, mask 1>
  seq.firmem.write_port %mem[%waddr] = %wdata, clock %clk enable %we : <1024 x 32, mask 1>
  %ra0 = seq.firreg %raddr clock %clk : i10
  %x = comb.xor %raddr, %c21_i10 : i10
  %n1 = comb.mux %hold, %ra1, %x : i10
  %ra1 = seq.firreg %n1 clock %clk reset sync %reset, %c3_i10 : i10
  %hin = comb.extract %raddr from 1 : (i10) -> i9
  %b0 = comb.extract %raddr from 0 : (i10) -> i1
  %lon = comb.xor %b0, %true : i1
  %hi = seq.firreg %hin clock %clk : i9
  %lo = seq.firreg %lon clock %clk : i1
  %a2 = comb.concat %hi, %lo : i9, i1
  %q0 = seq.firmem.read_port %mem[%ra0], clock %clk : <1024 x 32, mask 1>
  %q1 = seq.firmem.read_port %mem[%ra1], clock %clk : <1024 x 32, mask 1>
  %q2 = seq.firmem.read_port %mem[%a2], clock %clk : <1024 x 32, mask 1>
  hw.output %q0, %q1, %q2 : i32, i32, i32
}

// A read enable from registers is retimed like the address. Any other is
// dropped: the data of a disabled read is undefined.
// CHECK-LABEL: hw.module @ReadEnable
// CHECK:       %mem = seq.firmem 1, 1, new, undefined : <1024 x 32, mask 1>
// CHECK-DAG:   seq.firmem.read_port %mem[%raddr], clock %clk enable %ren : <1024 x 32, mask 1>
// CHECK-DAG:   seq.firmem.read_port %mem[%raddr], clock %clk : <1024 x 32, mask 1>
hw.module @ReadEnable(in %clk : !seq.clock, in %we : i1, in %waddr : i10, in %wdata : i32, in %raddr : i10, in %ren : i1, out q0 : i32, out q1 : i32) {
  %mem = seq.firmem 0, 1, undefined, undefined : <1024 x 32, mask 1>
  seq.firmem.write_port %mem[%waddr] = %wdata, clock %clk enable %we : <1024 x 32, mask 1>
  %ra = seq.firreg %raddr clock %clk : i10
  %en = seq.firreg %ren clock %clk : i1
  %q0 = seq.firmem.read_port %mem[%ra], clock %clk enable %en : <1024 x 32, mask 1>
  %q1 = seq.firmem.read_port %mem[%ra], clock %clk enable %ren : <1024 x 32, mask 1>
  hw.output %q0, %q1 : i32, i32
}

// Left alone: an address not from a register, a register with an
// asynchronous reset, and writes on another clock.
// CHECK-LABEL: hw.module @Unchanged
// CHECK-COUNT-3: seq.firmem 0, 1, undefined, undefined
hw.module @Unchanged(in %clk : !seq.clock, in %clk2 : !seq.clock, in %reset : i1, in %we : i1, in %waddr : i10, in %wdata : i32, in %raddr : i10, out q0 : i32, out q1 : i32, out q2 : i32) {
  %c0_i10 = hw.constant 0 : i10
  %m0 = seq.firmem 0, 1, undefined, undefined : <1024 x 32, mask 1>
  seq.firmem.write_port %m0[%waddr] = %wdata, clock %clk enable %we : <1024 x 32, mask 1>
  %q0 = seq.firmem.read_port %m0[%raddr], clock %clk : <1024 x 32, mask 1>
  %m1 = seq.firmem 0, 1, undefined, undefined : <1024 x 32, mask 1>
  seq.firmem.write_port %m1[%waddr] = %wdata, clock %clk enable %we : <1024 x 32, mask 1>
  %ra = seq.firreg %raddr clock %clk reset async %reset, %c0_i10 : i10
  %q1 = seq.firmem.read_port %m1[%ra], clock %clk : <1024 x 32, mask 1>
  %m2 = seq.firmem 0, 1, undefined, undefined : <1024 x 32, mask 1>
  seq.firmem.write_port %m2[%waddr] = %wdata, clock %clk2 enable %we : <1024 x 32, mask 1>
  %rb = seq.firreg %raddr clock %clk : i10
  %q2 = seq.firmem.read_port %m2[%rb], clock %clk : <1024 x 32, mask 1>
  hw.output %q0, %q1, %q2 : i32, i32, i32
}
