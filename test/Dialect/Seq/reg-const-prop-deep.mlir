// The analysis follows a value's bits through as many ops as the logic chains,
// without recursion: a register reset to 1 and loaded with itself through
// 200000 ANDs with 1 and 200000 muxes that select it is always 1, where one
// stack frame per op would overflow the stack. The companion Python script
// emits the module; this file carries no IR.

// RUN: %python %S/reg-const-prop-deep.py 200000 > %t.mlir
// RUN: circt-opt %t.mlir --pass-pipeline='builtin.module(hw.module(seq-reg-const-prop))' -o %t.out.mlir
// RUN: FileCheck %s < %t.out.mlir

// CHECK-LABEL: hw.module @Deep
// CHECK-NOT:   seq.firreg
// CHECK:       hw.output %true{{(_[0-9]+)?}} : i1
