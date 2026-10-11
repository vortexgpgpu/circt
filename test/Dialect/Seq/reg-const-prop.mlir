// RUN: circt-opt %s --pass-pipeline='builtin.module(hw.module(seq-reg-const-prop))' | FileCheck %s

// CHECK-LABEL: hw.module @Hold
hw.module @Hold(in %clk : !seq.clock, in %rst : i1, in %en : i1, out q : i4) {
  %c3_i4 = hw.constant 3 : i4
  // Reset to 3 and then either loaded with 3 or held: always 3.
  // CHECK-NOT: seq.firreg
  // CHECK: hw.output %c3_i4
  %m = comb.mux %en, %c3_i4, %r : i4
  %r = seq.firreg %m clock %clk reset sync %rst, %c3_i4 : i4
  hw.output %r : i4
}

// CHECK-LABEL: hw.module @Partial
hw.module @Partial(in %clk : !seq.clock, in %d : i4, out q : i8) {
  %c0_i4 = hw.constant 0 : i4
  // Only the low half varies, and stays in a register.
  // CHECK: [[NEXT:%.+]] = comb.extract {{%.+}} from 0 : (i8) -> i4
  // CHECK: %r = seq.firreg [[NEXT]] clock %clk : i4
  // CHECK: [[Q:%.+]] = comb.concat %c0_i4{{.*}}, %r : i4, i4
  // CHECK: hw.output [[Q]]
  %cat = comb.concat %c0_i4, %d : i4, i4
  %r = seq.firreg %cat clock %clk : i8
  hw.output %r : i8
}

// CHECK-LABEL: hw.module @Loop
hw.module @Loop(in %clk : !seq.clock, in %rst : i1, in %en : i1, out q : !hw.array<2xi4>) {
  %c5_i4 = hw.constant 5 : i4
  %c0_i1 = hw.constant 0 : i1
  // Two registers feeding each other through an array, both reset to 5.
  // CHECK-NOT: seq.firreg
  %a = seq.firreg %bget clock %clk reset sync %rst, %c5_i4 : i4
  %arr = hw.array_create %a, %a : i4
  %b = seq.firreg %arr clock %clk preset 0x55 : !hw.array<2xi4>
  %bget = hw.array_get %b[%c0_i1] : !hw.array<2xi4>, i1
  hw.output %b : !hw.array<2xi4>
}

// CHECK-LABEL: hw.module @Undefined
hw.module @Undefined(in %clk : !seq.clock, in %rst : i1, out q : i4) {
  %c1_i4 = hw.constant 1 : i4
  // `h` holds its undefined initial value; `r` takes it after reset, so
  // neither is a constant.
  // CHECK: %h = seq.firreg %h clock %clk : i4
  // CHECK: %r = seq.firreg %h clock %clk reset sync %rst, %c1_i4 : i4
  %h = seq.firreg %h clock %clk : i4
  %r = seq.firreg %h clock %clk reset sync %rst, %c1_i4 : i4
  hw.output %r : i4
}

// CHECK-LABEL: hw.module @Counter
hw.module @Counter(in %clk : !seq.clock, in %rst : i1, out q : i4) {
  %c0_i4 = hw.constant 0 : i4
  %c1_i4 = hw.constant 1 : i4
  // CHECK: %r = seq.firreg {{%.+}} clock %clk reset sync %rst, %c0_i4 : i4
  %sum = comb.add %r, %c1_i4 : i4
  %r = seq.firreg %sum clock %clk reset sync %rst, %c0_i4 : i4
  hw.output %r : i4
}
