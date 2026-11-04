// RUN: circt-opt --pass-pipeline='builtin.module(hw.module(synth-generic-lut-mapper{test=true carry-block-size=8}))' %s | FileCheck %s --check-prefixes CHECK,ARR
// RUN: circt-opt --pass-pipeline='builtin.module(hw.module(synth-generic-lut-mapper{test=true}))' %s | FileCheck %s --check-prefixes CHECK,ZERO

// A carry chain's bits arrive two LUT levels after their operands' block and
// a level per 8-bit carry block above it; an adder of at most six input bits
// is one LUT. Without a carry block size they arrive at 0.
// CHECK-LABEL: hw.module @carry_bits
// CHECK:       %[[S15:.+]] = comb.extract %{{.+}} from 15 : (i16) -> i1
// CHECK:       comb.truth_table {{.*}}%[[S15]]
// ARR-SAME:    test.arrival_times = [4]
// ZERO-SAME:   test.arrival_times = [1]
// CHECK:       %[[S3:.+]] = comb.extract %{{.+}} from 3 : (i16) -> i1
// CHECK:       comb.truth_table {{.*}}%[[S3]]
// ARR-SAME:    test.arrival_times = [3]
// ZERO-SAME:   test.arrival_times = [1]
// CHECK:       %[[T2:.+]] = comb.extract %{{.+}} from 2 : (i3) -> i1
// CHECK:       comb.truth_table {{.*}}%[[T2]]
// ARR-SAME:    test.arrival_times = [2]
// ZERO-SAME:   test.arrival_times = [1]
hw.module @carry_bits(in %a : i16, in %b : i16, in %p : i3, in %q : i3,
                      in %c : i1, in %d : i1,
                      out y : i1, out z : i1, out n : i1) {
  %s = comb.add %a, %b : i16
  %s15 = comb.extract %s from 15 : (i16) -> i1
  %0 = synth.aig.and_inv %s15, %c : i1
  %1 = synth.aig.and_inv %0, %d : i1
  %s3 = comb.extract %s from 3 : (i16) -> i1
  %2 = synth.aig.and_inv %s3, %c : i1
  %t = comb.add %p, %q : i3
  %t2 = comb.extract %t from 2 : (i3) -> i1
  %3 = synth.aig.and_inv %t2, %c : i1
  hw.output %1, %2, %3 : i1, i1, i1
}

// An order comparison's chain ends at its highest non-constant bit: a 16-bit
// compare against a zero-extended 9-bit value is two blocks (3 levels), and
// a LUT RAM of 64 words is one level after its address, of 256 words three.
// CHECK-LABEL: hw.module @compare_and_ram
// ARR:         test.arrival_times = [4]
// ARR:         test.arrival_times = [2]
// ARR:         test.arrival_times = [4]
hw.module @compare_and_ram(in %clk : !seq.clock, in %a : i9, in %b : i9,
                           in %c : i1, out lt : i1, out r64 : i1,
                           out r256 : i1) {
  %c0_i7 = hw.constant 0 : i7
  %wa = comb.concat %c0_i7, %a : i7, i9
  %wb = comb.concat %c0_i7, %b : i7, i9
  %lt = comb.icmp ult %wa, %wb : i16
  %0 = synth.aig.and_inv %lt, %c : i1
  %m64 = seq.firmem 0, 1, undefined, undefined : <64 x 1>
  %a6 = comb.extract %a from 0 : (i9) -> i6
  %r64 = seq.firmem.read_port %m64[%a6], clock %clk : <64 x 1>
  %1 = synth.aig.and_inv %r64, %c : i1
  %m256 = seq.firmem 0, 1, undefined, undefined : <256 x 1>
  %a8 = comb.extract %a from 0 : (i9) -> i8
  %r256 = seq.firmem.read_port %m256[%a8], clock %clk : <256 x 1>
  %2 = synth.aig.and_inv %r256, %c : i1
  hw.output %0, %1, %2 : i1, i1, i1
}

// A late carry selects between two cones of one LUT level each: the mapper
// keeps it out of those cones, in the last LUT. Its operand cone comes later
// in the block than the gates that read it, and is visited first.
// CHECK-LABEL: hw.module @late_select
// ARR:         %[[SEL:.+]] = comb.extract %{{.+}} from 15 : (i16) -> i1
// ARR:         comb.truth_table {{.*}}%[[SEL]] -> {{.*}}test.arrival_times = [5]
// ZERO:        comb.truth_table {{.*}} -> {{.*}}test.arrival_times = [2]
hw.module @late_select(in %a : i16, in %b : i16, in %x : i6, in %y : i6,
                       in %e : i1, out o : i1) {
  %s = comb.add %ae, %b : i16
  %sel = comb.extract %s from 15 : (i16) -> i1
  %x0 = comb.extract %x from 0 : (i6) -> i1
  %x1 = comb.extract %x from 1 : (i6) -> i1
  %x2 = comb.extract %x from 2 : (i6) -> i1
  %x3 = comb.extract %x from 3 : (i6) -> i1
  %x4 = comb.extract %x from 4 : (i6) -> i1
  %x5 = comb.extract %x from 5 : (i6) -> i1
  %y0 = comb.extract %y from 0 : (i6) -> i1
  %y1 = comb.extract %y from 1 : (i6) -> i1
  %y2 = comb.extract %y from 2 : (i6) -> i1
  %y3 = comb.extract %y from 3 : (i6) -> i1
  %y4 = comb.extract %y from 4 : (i6) -> i1
  %y5 = comb.extract %y from 5 : (i6) -> i1
  %0 = synth.aig.and_inv %x0, %x1 : i1
  %1 = synth.aig.and_inv %x2, %x3 : i1
  %2 = synth.aig.and_inv %x4, %x5 : i1
  %3 = synth.aig.and_inv %0, %1 : i1
  %X = synth.aig.and_inv %3, %2 : i1
  %4 = synth.aig.and_inv %y0, %y1 : i1
  %5 = synth.aig.and_inv %y2, %y3 : i1
  %6 = synth.aig.and_inv %y4, %y5 : i1
  %7 = synth.aig.and_inv %4, %5 : i1
  %Y = synth.aig.and_inv %7, %6 : i1
  %8 = synth.aig.and_inv %sel, %X : i1
  %9 = synth.aig.and_inv not %sel, %Y : i1
  %o = synth.aig.and_inv not %8, not %9 : i1
  // The adder's operand, after its readers: a LUT over a and e.
  %a0 = comb.extract %a from 0 : (i16) -> i1
  %a0e = synth.aig.and_inv %a0, %e : i1
  %ahi = comb.extract %a from 1 : (i16) -> i15
  %ae = comb.concat %ahi, %a0e : i15, i1
  hw.output %o : i1
}

// A module mapped apart from its hierarchy: its input port `sel` arrives at
// level 5 (from its instances' drivers), and its instance's output `late` at
// level 4. Both select between cones of a LUT level each, so the mapper keeps
// them for the last LUT: 6 and 5. Without the attributes they arrive at 0.
// CHECK-LABEL: hw.module @late_ports
// ARR:         comb.truth_table {{.*}}%sel -> {{.*}}test.arrival_times = [6]
// ARR:         %[[L:[0-9]+]] = comb.extract %src.late from 1
// ARR-NEXT:    comb.truth_table %[[L]], {{.*}}test.arrival_times = [5]
// ZERO:        comb.truth_table {{.*}} -> {{.*}}test.arrival_times = [2]
// ZERO:        comb.truth_table {{.*}} -> {{.*}}test.arrival_times = [2]
hw.module.extern @Source(out late : i2)
hw.module @late_ports(in %x : i6, in %y : i6, in %sel : i1, out o : i1,
                      out p : i1) attributes {
    synth.input_arrival_times = [array<i64>, array<i64>, array<i64: 5>]} {
  %x0 = comb.extract %x from 0 : (i6) -> i1
  %x1 = comb.extract %x from 1 : (i6) -> i1
  %x2 = comb.extract %x from 2 : (i6) -> i1
  %x3 = comb.extract %x from 3 : (i6) -> i1
  %x4 = comb.extract %x from 4 : (i6) -> i1
  %x5 = comb.extract %x from 5 : (i6) -> i1
  %y0 = comb.extract %y from 0 : (i6) -> i1
  %y1 = comb.extract %y from 1 : (i6) -> i1
  %y2 = comb.extract %y from 2 : (i6) -> i1
  %y3 = comb.extract %y from 3 : (i6) -> i1
  %y4 = comb.extract %y from 4 : (i6) -> i1
  %y5 = comb.extract %y from 5 : (i6) -> i1
  %0 = synth.aig.and_inv %x0, %x1 : i1
  %1 = synth.aig.and_inv %x2, %x3 : i1
  %2 = synth.aig.and_inv %x4, %x5 : i1
  %3 = synth.aig.and_inv %0, %1 : i1
  %X = synth.aig.and_inv %3, %2 : i1
  %4 = synth.aig.and_inv %y0, %y1 : i1
  %5 = synth.aig.and_inv %y2, %y3 : i1
  %6 = synth.aig.and_inv %y4, %y5 : i1
  %7 = synth.aig.and_inv %4, %5 : i1
  %Y = synth.aig.and_inv %7, %6 : i1
  %8 = synth.aig.and_inv %sel, %X : i1
  %9 = synth.aig.and_inv not %sel, %Y : i1
  %o = synth.aig.and_inv not %8, not %9 : i1
  // Bit 1 of the instance's output is late; bit 0 is not.
  %late = hw.instance "src" @Source() -> (late: i2) {
      synth.output_arrival_times = [array<i64: 0, 4>]}
  %l = comb.extract %late from 1 : (i2) -> i1
  %10 = synth.aig.and_inv %l, %X : i1
  %11 = synth.aig.and_inv not %l, %Y : i1
  %p = synth.aig.and_inv not %10, not %11 : i1
  hw.output %o, %p : i1, i1
}
