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

// A cycle between words, though not between bits: bit 0 of %w comes from bit 1
// of %w. The analysis must end, and find the register's constant bit.
// CHECK-LABEL: hw.module @WordCycle
// CHECK:         %r = seq.firreg %{{.+}} clock %clk : i1
hw.module @WordCycle(in %clk : !seq.clock, in %a : i1, out o : i2) {
  %false = hw.constant false
  %hi = comb.extract %w from 1 : (i2) -> i1
  %w = comb.concat %a, %hi : i1, i1
  %next = comb.concat %false, %a : i1, i1
  %r = seq.firreg %next clock %clk : i2
  %o = comb.xor %r, %w : i2
  hw.output %o : i2
}

// A narrowed register keeps the synthesis attributes it was declared with.
// CHECK-LABEL: hw.module @Attributes
// CHECK: %r = seq.firreg {{%.+}} clock %clk {sv.attributes = [#sv.attribute<"keep" = "\22true\22">]} : i4
hw.module @Attributes(in %clk : !seq.clock, in %d : i4, out q : i8) {
  %c0_i4 = hw.constant 0 : i4
  %cat = comb.concat %c0_i4, %d : i4, i4
  %r = seq.firreg %cat clock %clk {sv.attributes = [#sv.attribute<"keep" = "\22true\22">]} : i8
  hw.output %r : i8
}

// A slice reaching past the end of the array reads undefined elements, not the
// constant element it starts at and whatever follows.
// CHECK-LABEL: hw.module @SlicePastEnd
// CHECK: %q = seq.firreg {{%.+}} clock %clk : !hw.array<2xi8>
hw.module @SlicePastEnd(in %clk : !seq.clock, in %d : i8, out o : !hw.array<2xi8>) {
  %c0_i8 = hw.constant 0 : i8
  %c3_i2 = hw.constant 3 : i2
  %next = hw.array_create %c0_i8, %d, %d, %d : i8
  %r = seq.firreg %next clock %clk : !hw.array<4xi8>
  %s = hw.array_slice %r[%c3_i2] : (!hw.array<4xi8>) -> !hw.array<2xi8>
  %q = seq.firreg %s clock %clk : !hw.array<2xi8>
  hw.output %q : !hw.array<2xi8>
}
