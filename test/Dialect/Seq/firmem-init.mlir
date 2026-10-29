// RUN: circt-opt --lower-seq-firmem %s | FileCheck %s --check-prefix=LOWER
// RUN: firtool --format=mlir --disable-all-randomization --lowering-options=locationInfoStyle=none %s | FileCheck %s --check-prefix=SV
// RUN: firtool --format=mlir --disable-all-randomization --lowering-options=locationInfoStyle=none,disallowLocalVariables %s | FileCheck %s --check-prefix=UNROLL

// A memory starts out with the contents it is declared with: every word set to
// its preset, then the words its file holds. They are the contents synthesis
// loads into a block RAM too, so no macro guards them.

// LOWER: hw.module.generated @preset_4x8, @FIRRTLMem({{.*}}) attributes {{{.*}}preset = 5 : i8
// LOWER: hw.module.generated @both_4x8, @FIRRTLMem({{.*}}) attributes {{{.*}}initFilename = "init.hex"{{.*}}preset = 0 : i8
// LOWER: hw.module.generated @plain_4x8, @FIRRTLMem({{.*}}) attributes {
// LOWER-NOT: preset =

// SV-LABEL: module preset_4x8(
// SV-NOT:     `ifdef
// SV:         initial begin
// SV-NEXT:      for (logic [2:0] i = 3'h0; i < 3'h4; i += 3'h1) begin
// SV-NEXT:        Memory[i[1:0]] = 8'h5;
// SV-NEXT:      end
// SV-NEXT:    end // initial
// SV-LABEL: module both_4x8(
// SV-NOT:     `ifdef
// SV:         initial begin
// SV-NEXT:      for (logic [2:0] i = 3'h0; i < 3'h4; i += 3'h1) begin
// SV-NEXT:        Memory[i[1:0]] = 8'h0;
// SV-NEXT:      end
// SV-NEXT:      $readmemh("init.hex", Memory);
// SV-NEXT:    end // initial
// SV-LABEL: module file_4x8(
// SV-NOT:     `ifdef
// SV:         initial
// SV-NEXT:      $readmemb("init.bin", Memory);
// SV-LABEL: module plain_4x8(
// SV-NOT:     initial

// Without local variables, the preset is one statement per word.
// UNROLL-LABEL: module preset_4x8(
// UNROLL:         initial begin
// UNROLL-NEXT:      Memory[2'h0] = 8'h5;
// UNROLL-NEXT:      Memory[2'h1] = 8'h5;
// UNROLL-NEXT:      Memory[2'h2] = 8'h5;
// UNROLL-NEXT:      Memory[2'h3] = 8'h5;
// UNROLL-NEXT:    end // initial

hw.module @Memories(in %clk : !seq.clock, in %addr : i2, in %data : i8, in %we : i1, out a : i8, out b : i8, out c : i8, out d : i8) {
  %true = hw.constant true
  %preset = seq.firmem 1, 1, undefined, undefined {preset = 5 : i8} : <4 x 8>
  %0 = seq.firmem.read_port %preset[%addr], clock %clk enable %true : <4 x 8>
  seq.firmem.write_port %preset[%addr] = %data, clock %clk enable %we : <4 x 8>
  %both = seq.firmem 1, 1, undefined, undefined {init = #seq.firmem.init<"init.hex", false, true>, preset = 0 : i8} : <4 x 8>
  %1 = seq.firmem.read_port %both[%addr], clock %clk enable %true : <4 x 8>
  seq.firmem.write_port %both[%addr] = %data, clock %clk enable %we : <4 x 8>
  %file = seq.firmem 1, 1, undefined, undefined {init = #seq.firmem.init<"init.bin", true, true>} : <4 x 8>
  %2 = seq.firmem.read_port %file[%addr], clock %clk enable %true : <4 x 8>
  seq.firmem.write_port %file[%addr] = %data, clock %clk enable %we : <4 x 8>
  %plain = seq.firmem 1, 1, undefined, undefined : <4 x 8>
  %3 = seq.firmem.read_port %plain[%addr], clock %clk enable %true : <4 x 8>
  seq.firmem.write_port %plain[%addr] = %data, clock %clk enable %we : <4 x 8>
  hw.output %0, %1, %2, %3 : i8, i8, i8, i8
}
