// RUN: circt-opt %s -export-verilog -verify-diagnostics | FileCheck %s
// RUN: circt-opt %s --test-apply-lowering-options='options=disallowSizeCasts,explicitBitcast' -export-verilog -verify-diagnostics | FileCheck %s --check-prefix=NOCAST

// A multiplication of sign extensions is emitted as the signed multiplication
// of the narrower values, at the width of the result.
// CHECK-LABEL: module SignedMultiply(
// Without size casts, as in Verilog-2005, the extended values are multiplied.
// NOCAST-LABEL: module SignedMultiply(
// NOCAST: assign p = {{[{][{]}}34{s}}, x} * {{[{][{]}}33{y[32]}}, y};
// NOCAST: assign q = {{[{][{]}}8{u[7]}}, u} * {8'h0, u};
// NOCAST: assign r = {{[{][{]}}7{s}}, s, u} * {{[{][{]}}8{u[7]}}, u};
hw.module @SignedMultiply(in %s : i1, in %x : i32, in %y : i33, in %u : i8, out p : i66, out q : i16, out r : i16) {
  // `{s, x}` sign extended, times `y` sign extended from its own sign bit.
  // CHECK: assign p = $unsigned(66'($signed({s, x}) * $signed(y)));
  %rs = comb.replicate %s : (i1) -> i34
  %a = comb.concat %rs, %x : i34, i32
  %ys = comb.extract %y from 32 : (i33) -> i1
  %ry = comb.replicate %ys : (i1) -> i33
  %b = comb.concat %ry, %y : i33, i33
  %p = comb.mul %a, %b : i66
  // Only one operand is a sign extension: an unsigned multiplication.
  // CHECK: assign q = {{[{][{]}}8{u[7]}}, u} * {8'h0, u};
  %us = comb.extract %u from 7 : (i8) -> i1
  %ru = comb.replicate %us : (i1) -> i8
  %c = comb.concat %ru, %u : i8, i8
  %c0_i8 = hw.constant 0 : i8
  %d = comb.concat %c0_i8, %u : i8, i8
  %q = comb.mul %c, %d : i16
  // A sign bit already in the concatenation is not repeated.
  // CHECK: assign r = $unsigned(16'($signed({s, u}) * $signed(u)));
  %rs7 = comb.replicate %s : (i1) -> i7
  %e = comb.concat %rs7, %s, %u : i7, i1, i8
  %ru2 = comb.replicate %us : (i1) -> i8
  %f = comb.concat %ru2, %u : i8, i8
  %r = comb.mul %e, %f : i16
  hw.output %p, %q, %r : i66, i16, i16
}
