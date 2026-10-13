// RUN: circt-opt %s --seq-retime-firmem-reads | FileCheck %s
// RUN: circt-opt %s --seq-retime-firmem-reads=inline=false --verify-diagnostics -o /dev/null

// The RAM wrapper reads at an address it receives on a port; its parent
// registers it. The wrapper is inlined, and only it: @Other keeps its
// hierarchy. The read then becomes synchronous.
// CHECK-LABEL: hw.module private @Other
// CHECK-NOT:   hw.module private @Wrap
// CHECK-LABEL: hw.module @Top
// CHECK:       %[[NEXT:.+]] = comb.mux %en, %base, %ra : i6
// CHECK:       %{{.+}} = seq.firmem name "m/ram" 1, 1, new, undefined
// CHECK:       seq.firmem.read_port %{{.+}}[%[[NEXT]]], clock %clk
// CHECK:       hw.instance "o" @Other
hw.module private @Wrap(in %clk : !seq.clock, in %we : i1, in %wa : i6, in %wd : i32, in %ra : i6, out rd : i32) {
  // expected-error @below {{asks for block RAM (ram_style=block), but its asynchronous read cannot be made synchronous: address depends on input 'ra'}}
  %ram = seq.firmem name "ram" 0, 1, undefined, undefined {sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">]} : <64 x 32, mask 1>
  seq.firmem.write_port %ram[%wa] = %wd, clock %clk enable %we : <64 x 32, mask 1>
  %rd = seq.firmem.read_port %ram[%ra], clock %clk : <64 x 32, mask 1>
  hw.output %rd : i32
}
hw.module private @Other(in %clk : !seq.clock, in %x : i8, out y : i8) {
  %r = seq.firreg %x clock %clk : i8
  hw.output %r : i8
}
hw.module @Top(in %clk : !seq.clock, in %en : i1, in %we : i1, in %wa : i6, in %wd : i32, in %base : i6, in %x : i8, out rd : i32, out y : i8) {
  %next = comb.mux %en, %base, %ra : i6
  %ra = seq.firreg %next clock %clk : i6
  %rd = hw.instance "m" @Wrap(clk: %clk : !seq.clock, we: %we : i1, wa: %wa : i6, wd: %wd : i32, ra: %ra : i6) -> (rd : i32)
  %y = hw.instance "o" @Other(clk: %clk : !seq.clock, x: %x : i8) -> (y : i8)
  hw.output %rd, %y : i32, i8
}
