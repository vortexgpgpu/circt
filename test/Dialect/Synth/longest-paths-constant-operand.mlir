// RUN: circt-opt %s --pass-pipeline='builtin.module(synth-print-longest-path-analysis{test=true})' -o /dev/null 2>&1 | FileCheck %s

// The analysis times an operation by lowering a copy of it; a constant
// operand stays a constant in the copy. A remainder by 24 is then a circuit
// of the dividend's bits, not a 32-bit divider the lowering cannot emulate.
// CHECK-NOT: error
// CHECK: endPoint=Object($root.x[0]), startPoint=Object($root.a[{{[0-9]+}}], delay={{[1-9][0-9]*}}
hw.module private @modConst(in %a : i32, out x : i1) {
  %c24 = hw.constant 24 : i32
  %r = comb.modu %a, %c24 : i32
  %x = comb.extract %r from 4 : (i32) -> i1
  hw.output %x : i1
}
