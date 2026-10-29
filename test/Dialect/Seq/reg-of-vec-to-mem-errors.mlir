// RUN: circt-opt %s --seq-reg-of-vec-to-mem --verify-diagnostics --split-input-file

// A register array loaded from a file must be a memory: a register cannot be
// loaded from one.
hw.module @file_init_not_memory(in %clk : i1, in %addr : i2, in %data : i8, in %we : i1, out out : i8, out next : !hw.array<4xi8>) {
  %clock = seq.to_clock %clk
  %read = hw.array_get %mem[%addr] : !hw.array<4xi8>, i2
  %write = hw.array_inject %mem[%addr], %data : !hw.array<4xi8>, i2
  %next = comb.mux %we, %write, %mem : !hw.array<4xi8>
  // expected-error @below {{register array loaded from a file is not a memory; only a memory can be loaded from a file}}
  %mem = seq.firreg %next clock %clock {seq.firmem_init = #seq.firmem.init<"init.hex", false, true>} : !hw.array<4xi8>
  hw.output %read, %next : i8, !hw.array<4xi8>
}
