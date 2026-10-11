// RUN: circt-opt --lower-seq-firmem %s | FileCheck %s --check-prefix=LOWER
// RUN: circt-opt --lower-seq-to-sv --hw-memory-sim %s | FileCheck %s --check-prefix=SIM
// RUN: circt-opt --lower-seq-to-sv '--hw-memory-sim=add-vivado-ram-address-conflict-synthesis-bug-workaround=true' %s | FileCheck %s --check-prefix=VIVADO

// The SV attributes of a memory are part of its configuration: memories that
// differ only in them get separate generated modules, whose memory array
// carries them, and the instances do not.

// LOWER: hw.module.generated @block_4x8, @FIRRTLMem({{.*}}) attributes {{{.*}}sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">]
// LOWER: hw.module.generated @lut_4x8, @FIRRTLMem({{.*}}) attributes {{{.*}}sv.attributes = [#sv.attribute<"ram_style" = "\22distributed\22">]
// LOWER-LABEL: hw.module @Memories
// LOWER: hw.instance "block_ext" @block_4x8({{.*}}) -> (R0_data: i8){{$}}
// LOWER: hw.instance "block2_ext" @block_4x8({{.*}}) -> (R0_data: i8){{$}}
// LOWER: hw.instance "lut_ext" @lut_4x8({{.*}}) -> (R0_data: i8){{$}}

// SIM-LABEL: hw.module private @block_4x8
// SIM: %Memory = sv.reg {sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">]}
// SIM-LABEL: hw.module private @lut_4x8
// SIM: %Memory = sv.reg {sv.attributes = [#sv.attribute<"ram_style" = "\22distributed\22">]}

// The Vivado workaround adds `rw_addr_collision` to a registered-read memory
// with several ports, without dropping the `ram_style` the design chose.
// VIVADO-LABEL: hw.module private @block_4x8
// VIVADO: %Memory = sv.reg {sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">, #sv.attribute<"rw_addr_collision" = "\22yes\22">]}
// VIVADO-LABEL: hw.module private @lut_4x8
// VIVADO: %Memory = sv.reg {sv.attributes = [#sv.attribute<"ram_style" = "\22distributed\22">, #sv.attribute<"rw_addr_collision" = "\22yes\22">]}

hw.module @Memories(in %clk : !seq.clock, in %addr : i2, in %data : i8, in %we : i1, out a : i8, out b : i8, out c : i8) {
  %true = hw.constant true
  %block = seq.firmem 1, 1, undefined, undefined {sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">]} : <4 x 8>
  %0 = seq.firmem.read_port %block[%addr], clock %clk enable %true : <4 x 8>
  seq.firmem.write_port %block[%addr] = %data, clock %clk enable %we : <4 x 8>
  %block2 = seq.firmem 1, 1, undefined, undefined {sv.attributes = [#sv.attribute<"ram_style" = "\22block\22">]} : <4 x 8>
  %1 = seq.firmem.read_port %block2[%addr], clock %clk enable %true : <4 x 8>
  seq.firmem.write_port %block2[%addr] = %data, clock %clk enable %we : <4 x 8>
  %lut = seq.firmem 1, 1, undefined, undefined {sv.attributes = [#sv.attribute<"ram_style" = "\22distributed\22">]} : <4 x 8>
  %2 = seq.firmem.read_port %lut[%addr], clock %clk enable %true : <4 x 8>
  seq.firmem.write_port %lut[%addr] = %data, clock %clk enable %we : <4 x 8>
  hw.output %0, %1, %2 : i8, i8, i8
}
