// RUN: circt-opt --seq-unroll-mem-latency --split-input-file --verify-diagnostics %s

// A read-write port's read and write would need different delays of one
// address and one mode.
hw.module @firmemRdWr(in %clk: !seq.clock, in %en: i1, in %addr: i4, in %wdata: i42, in %wmode: i1) {
  %mem = seq.firmem 42, 69, undefined, port_order : <12 x 42>
  // expected-error @below {{cannot unroll the latencies of a read-write port}}
  %0 = seq.firmem.read_write_port %mem[%addr] = %wdata if %wmode, clock %clk enable %en : <12 x 42>
}

// -----

// A read at latency 0 sees a write committed in the cycle its address was
// issued ("new"); "old" needs the data registered, not the address delayed.
hw.module @firmemRuwOld(in %clk: !seq.clock, in %en: i1, in %addr: i4, in %wdata: i42) {
  // expected-error @below {{cannot unroll the read latency of a memory with read-under-write 'old'}}
  %mem = seq.firmem 1, 1, old, port_order : <12 x 42>
  %0 = seq.firmem.read_port %mem[%addr], clock %clk enable %en : <12 x 42>
  seq.firmem.write_port %mem[%addr] = %wdata, clock %clk enable %en : <12 x 42>
}
