// RUN: circt-opt %s --pass-pipeline='builtin.module(hw.module(seq-lower-aggregate-regs))' | FileCheck %s

// An aggregate register keeps an integer of the same bits, its next and reset
// values bitcast to it and its value bitcast back.
// CHECK-LABEL: hw.module @Regs
hw.module @Regs(in %clk : !seq.clock, in %rst : i1, in %d : !hw.array<2xi4>, out q : !hw.array<2xi4>, out p : !hw.struct<a: i1, b: i3>) {
  // CHECK-DAG: %[[D:.+]] = hw.bitcast %d : (!hw.array<2xi4>) -> i8
  // CHECK-DAG: %[[R:.+]] = seq.firreg %[[D]] clock %clk reset sync %rst, %{{.+}} : i8
  // CHECK-DAG: %[[Q:.+]] = hw.bitcast %[[R]] : (i8) -> !hw.array<2xi4>
  %init = hw.aggregate_constant [1 : i4, 2 : i4] : !hw.array<2xi4>
  %q = seq.firreg %d clock %clk reset sync %rst, %init {name = "q"} : !hw.array<2xi4>
  // CHECK-DAG: %p = seq.firreg %{{.+}} clock %clk : i4
  %p = seq.firreg %p clock %clk {name = "p"} : !hw.struct<a: i1, b: i3>
  // CHECK: hw.output %[[Q]], %{{.+}} : !hw.array<2xi4>, !hw.struct<a: i1, b: i3>
  hw.output %q, %p : !hw.array<2xi4>, !hw.struct<a: i1, b: i3>
}
