// RUN: circt-opt %s --split-input-file --verify-diagnostics --pass-pipeline='builtin.module(seq-retime-firmem-reads)' | FileCheck %s
// RUN: circt-opt %s --verify-diagnostics --pass-pipeline='builtin.module(seq-retime-firmem-reads{report=%t.rpt})' -o /dev/null
// RUN: FileCheck %s --check-prefix=REPORT < %t.rpt
// RUN: circt-opt %s --pass-pipeline='builtin.module(seq-retime-firmem-reads{disable})' 2>&1 | FileCheck %s --check-prefix=DISABLED

// A memory that asks for block RAM is converted without `mode=auto`; one that
// asks for distributed RAM and one without a hint are left alone.
// CHECK-LABEL: hw.module @Hints
// CHECK:       %blk = seq.firmem 1, 1, new, undefined
// CHECK:       %dist = seq.firmem 0, 1, undefined, undefined
// CHECK:       %none = seq.firmem 0, 1, undefined, undefined
// REPORT-DAG:  Hints.blk 64x32 ram_style=block converted
// REPORT-DAG:  Hints.dist 64x32 ram_style=distributed kept (hint)
// REPORT-DAG:  Hints.none 64x32 no-hint kept (no hint, mode off)
// REPORT-DAG:  Hints.m20k 64x32 ramstyle=m20k, no_rw_check converted
// DISABLED:    warning: asks for block RAM (ram_style=block), but memory read retiming is disabled
// DISABLED:    warning: asks for block RAM (ramstyle=m20k, no_rw_check), but memory read retiming is disabled
hw.module @Hints(in %clk : !seq.clock, in %we : i1, in %waddr : i6, in %wdata : i32, in %raddr : i6, out q0 : i32, out q1 : i32, out q2 : i32, out q3 : i32) {
  %ra = seq.firreg %raddr clock %clk : i6
  %blk = seq.firmem name "blk" 0, 1, undefined, undefined {sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">]} : <64 x 32, mask 1>
  seq.firmem.write_port %blk[%waddr] = %wdata, clock %clk enable %we : <64 x 32, mask 1>
  %q0 = seq.firmem.read_port %blk[%ra], clock %clk : <64 x 32, mask 1>
  %dist = seq.firmem name "dist" 0, 1, undefined, undefined {sv.attributes = [#sv.attribute<"ram_style" = "\22distributed\22">]} : <64 x 32, mask 1>
  seq.firmem.write_port %dist[%waddr] = %wdata, clock %clk enable %we : <64 x 32, mask 1>
  %q1 = seq.firmem.read_port %dist[%ra], clock %clk : <64 x 32, mask 1>
  %none = seq.firmem name "none" 0, 1, undefined, undefined : <64 x 32, mask 1>
  seq.firmem.write_port %none[%waddr] = %wdata, clock %clk enable %we : <64 x 32, mask 1>
  %q2 = seq.firmem.read_port %none[%ra], clock %clk : <64 x 32, mask 1>
  %m20k = seq.firmem name "m20k" 0, 1, undefined, undefined {sv.attributes = [#sv.attribute<"ramstyle" = "\22M20K, no_rw_check\22">]} : <64 x 32, mask 1>
  seq.firmem.write_port %m20k[%waddr] = %wdata, clock %clk enable %we : <64 x 32, mask 1>
  %q3 = seq.firmem.read_port %m20k[%ra], clock %clk : <64 x 32, mask 1>
  hw.output %q0, %q1, %q2, %q3 : i32, i32, i32, i32
}

// -----

// A block RAM request that cannot be honored is an error naming the reason.
// REPORT-DAG: Bad.port 64x32 ram_style=block ERROR (address depends on input 'raddr')
hw.module @Bad(in %clk : !seq.clock, in %we : i1, in %waddr : i6, in %wdata : i32, in %raddr : i6, out q : i32) {
  // expected-error @below {{asks for block RAM (ram_style=block), but its asynchronous read cannot be made synchronous: address depends on input 'raddr'}}
  %port = seq.firmem name "port" 0, 1, undefined, undefined {sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">]} : <64 x 32, mask 1>
  seq.firmem.write_port %port[%waddr] = %wdata, clock %clk enable %we : <64 x 32, mask 1>
  %q = seq.firmem.read_port %port[%raddr], clock %clk : <64 x 32, mask 1>
  hw.output %q : i32
}

// -----

// REPORT-DAG: Async.areg 64x32 ram_style=block ERROR (address register 'ra' (seq.firreg) has an asynchronous reset)
hw.module @Async(in %clk : !seq.clock, in %reset : i1, in %we : i1, in %waddr : i6, in %wdata : i32, in %raddr : i6, out q : i32) {
  %c0_i6 = hw.constant 0 : i6
  %ra = seq.firreg %raddr clock %clk reset async %reset, %c0_i6 : i6
  // expected-error @below {{address register 'ra' (seq.firreg) has an asynchronous reset}}
  %areg = seq.firmem name "areg" 0, 1, undefined, undefined {sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">]} : <64 x 32, mask 1>
  seq.firmem.write_port %areg[%waddr] = %wdata, clock %clk enable %we : <64 x 32, mask 1>
  %q = seq.firmem.read_port %areg[%ra], clock %clk : <64 x 32, mask 1>
  hw.output %q : i32
}
