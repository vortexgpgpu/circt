// RUN: circt-opt -verify-diagnostics --hw-convert-bitcasts=allow-partial-conversion=false --split-input-file %s

hw.module @unsupported(in %i: i1, out o : i1) {
  // expected-error @+1 {{has unsupported output type}}
  %a = hw.bitcast %i : (i1) -> !hw.enum<A, B>
  // expected-error @+1 {{has unsupported input type}}
  %o = hw.bitcast %a : (!hw.enum<A, B>) -> i1
  hw.output %o : i1
}
