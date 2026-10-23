// RUN: circt-opt %s --pass-pipeline='builtin.module(synth-print-longest-path-analysis{test=true})' -o /dev/null 2>&1 | FileCheck %s

// A read of latency 0 is combinational from its address: a 128-word
// distributed RAM is a tree of 7 multiplexer levels, and the stored word is
// a start point of its own. (Inverters are free.)
// CHECK-DAG: endPoint=Object($root.x[0]), startPoint=Object($root.a[3], delay=7{{[,)]}}
// CHECK-DAG: endPoint=Object($root.x[0]), startPoint=Object($root.ram.read_port[0], delay=0{{[,)]}}
// A write's address is an end point of every stored bit, as its data and
// enable are.
// CHECK-DAG: endPoint=Object($root.ram.write_port[0]), startPoint=Object($root.b[2], delay=0{{[,)]}}
// A registered read samples its address: an end point of the read.
// CHECK-DAG: endPoint=Object($root.rom.read_port[1]), startPoint=Object($root.a[5], delay=0{{[,)]}}
hw.module private @memory(in %clk : !seq.clock, in %a : i7, in %b : i7,
                          in %d : i4, in %we : i1, out x : i4, out y : i4) {
  %ram = seq.firmem 0, 1, undefined, undefined : <128 x 4>
  %rom = seq.firmem 1, 1, undefined, undefined : <128 x 4>
  %na = synth.aig.and_inv not %a : i7
  %nb = synth.aig.and_inv not %b : i7
  %nd = synth.aig.and_inv not %d : i4
  %r = seq.firmem.read_port %ram[%na], clock %clk : <128 x 4>
  %x = synth.aig.and_inv not %r : i4
  seq.firmem.write_port %ram[%nb] = %nd, clock %clk enable %we : <128 x 4>
  %y = seq.firmem.read_port %rom[%na], clock %clk : <128 x 4>
  hw.output %x, %y : i4, i4
}
