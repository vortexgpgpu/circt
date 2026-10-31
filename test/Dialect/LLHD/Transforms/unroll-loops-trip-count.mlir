// RUN: circt-opt --llhd-unroll-loops %s | FileCheck %s --check-prefix=DEFAULT
// RUN: circt-opt --llhd-unroll-loops=max-trip-count=1025 %s | FileCheck %s --check-prefix=MORE
// RUN: circt-opt --llhd-unroll-loops=max-trip-count=3 %s | FileCheck %s --check-prefix=FEWER

// A loop of 1024 iterations is left by default (1024 or more are), unrolled
// with a larger max-trip-count; one of 3 is left with max-trip-count=3.

// DEFAULT-LABEL: @Loop1024
// DEFAULT:         cf.cond_br
// MORE-LABEL:    @Loop1024
// MORE-NOT:        cf.cond_br
// MORE-COUNT-1024: comb.add {{%.+}}, %c42_i42
// MORE-NOT:        comb.add
// MORE:            llhd.yield
hw.module @Loop1024(out x : i42) {
  %c0_i42 = hw.constant 0 : i42
  %c1_i42 = hw.constant 1 : i42
  %c1024_i42 = hw.constant 1024 : i42
  %c42_i42 = hw.constant 42 : i42
  %0 = llhd.combinational -> i42 {
    cf.br ^header(%c0_i42, %c0_i42 : i42, i42)
  ^header(%i: i42, %x: i42):
    %1 = comb.icmp slt %i, %c1024_i42 : i42
    cf.cond_br %1, ^body, ^exit
  ^body:
    %2 = comb.add %x, %c42_i42 : i42
    %ip = comb.add %i, %c1_i42 : i42
    cf.br ^header(%ip, %2 : i42, i42)
  ^exit:
    llhd.yield %x : i42
  }
  hw.output %0 : i42
}

// DEFAULT-LABEL: @Loop3
// DEFAULT-NOT:     cf.cond_br
// DEFAULT:         llhd.yield
// FEWER-LABEL:   @Loop3
// FEWER:           cf.cond_br
hw.module @Loop3(out x : i42) {
  %c0_i42 = hw.constant 0 : i42
  %c1_i42 = hw.constant 1 : i42
  %c3_i42 = hw.constant 3 : i42
  %c42_i42 = hw.constant 42 : i42
  %0 = llhd.combinational -> i42 {
    cf.br ^header(%c0_i42, %c0_i42 : i42, i42)
  ^header(%i: i42, %x: i42):
    %1 = comb.icmp slt %i, %c3_i42 : i42
    cf.cond_br %1, ^body, ^exit
  ^body:
    %2 = comb.add %x, %c42_i42 : i42
    %ip = comb.add %i, %c1_i42 : i42
    cf.br ^header(%ip, %2 : i42, i42)
  ^exit:
    llhd.yield %x : i42
  }
  hw.output %0 : i42
}
