// RUN: circt-opt --seq-unroll-mem-latency %s | FileCheck %s

// CHECK-LABEL: hw.module @hlmem

// CHECK: %mem = seq.hlmem @mem %clk, %rst : <4xi32>
// CHECK: [[C0:%.+]] = hw.constant 0 : i2
// CHECK: %true = hw.constant true
// CHECK: [[C42:%.+]] = hw.constant 42 : i32
// CHECK: [[S0:%.+]] = seq.shiftreg[68] [[C0]], %clk, %true_0 : i2  
// CHECK: [[S1:%.+]] = seq.shiftreg[68] [[C42]], %clk, %true_0 : i32  
// CHECK: [[SEN:%.+]] = seq.shiftreg[68] %true, %clk, %true_0 : i1  
// CHECK: seq.write %mem[[[S0]]] [[S1]] wren [[SEN]] {latency = 1 : i64} : !seq.hlmem<4xi32>
// CHECK: %true_0 = hw.constant true
// CHECK: [[S2:%.+]] = seq.shiftreg[42] [[C0]], %clk, %true_1 : i2  
// CHECK: [[SEN1:%.+]] = seq.shiftreg[42] %true, %clk, %true_1 : i1  
// CHECK: [[RD_DATA:%.+]] = seq.read %mem[[[S2]]] rden [[SEN1]] {latency = 0 : i64} : !seq.hlmem<4xi32>
// CHECK: %true_1 = hw.constant true
// CHECK: hw.output [[RD_DATA]] : i32
hw.module @hlmem(in %clk : !seq.clock, in %rst : i1, out "rd": i32) {
  %mem = seq.hlmem @mem %clk, %rst : <4xi32>

  %c0_i2 = hw.constant 0 : i2
  %c1_i1 = hw.constant 1 : i1
  %c42_i32 = hw.constant 42 : i32
  
  seq.write %mem[%c0_i2] %c42_i32 wren %c1_i1 { latency = 69 } : !seq.hlmem<4xi32>
  %rddata = seq.read %mem[%c0_i2] rden %c1_i1 { latency = 42 } : !seq.hlmem<4xi32>
  hw.output %rddata : i32
}

// CHECK-LABEL: hw.module @hlmemManyAddr

// CHECK: %mem = seq.hlmem @mem %clk, %rst : <4x4x4xi32>
// CHECK: %true = hw.constant true
// CHECK: [[C42:%.+]] = hw.constant 42 : i32
// CHECK: [[SADDR0:%.+]] = seq.shiftreg[68] %addr0, %clk, %true_0 : i2  
// CHECK: [[SADDR1:%.+]] = seq.shiftreg[68] %addr1, %clk, %true_0 : i2  
// CHECK: [[SADDR2:%.+]] = seq.shiftreg[68] %addr2, %clk, %true_0 : i2  
// CHECK: [[S1:%.+]] = seq.shiftreg[68] [[C42]], %clk, %true_0 : i32  
// CHECK: [[SEN:%.+]] = seq.shiftreg[68] %true, %clk, %true_0 : i1  
// CHECK: seq.write %mem[[[SADDR0]], [[SADDR1]], [[SADDR2]]] [[S1]] wren [[SEN]] {latency = 1 : i64} : !seq.hlmem<4x4x4xi32>
// CHECK: %true_0 = hw.constant true
// CHECK: [[SADDR3:%.+]] = seq.shiftreg[42] %addr0, %clk, %true_1 : i2  
// CHECK: [[SADDR4:%.+]] = seq.shiftreg[42] %addr1, %clk, %true_1 : i2  
// CHECK: [[SADDR5:%.+]] = seq.shiftreg[42] %addr2, %clk, %true_1 : i2   
// CHECK: [[SEN1:%.+]] = seq.shiftreg[42] %true, %clk, %true_1 : i1  
// CHECK: [[RD_DATA:%.+]] = seq.read %mem[[[SADDR3]], [[SADDR4]], [[SADDR5]]] rden [[SEN1]] {latency = 0 : i64} : !seq.hlmem<4x4x4xi32>
// CHECK: %true_1 = hw.constant true
// CHECK: hw.output [[RD_DATA]] : i32
hw.module @hlmemManyAddr(in %clk : !seq.clock, in %rst : i1, in %addr0 : i2, in %addr1 : i2, in %addr2 : i2, out "rd": i32) {
  %mem = seq.hlmem @mem %clk, %rst : !seq.hlmem<4x4x4xi32>

  %c1_i1 = hw.constant 1 : i1
  %c42_i32 = hw.constant 42 : i32
  
  seq.write %mem[%addr0, %addr1, %addr2] %c42_i32 wren %c1_i1 { latency = 69 } : !seq.hlmem<4x4x4xi32>
  %rddata = seq.read %mem[%addr0, %addr1, %addr2] rden %c1_i1 { latency = 42 } : !seq.hlmem<4x4x4xi32>
  hw.output %rddata : i32
}

// CHECK-LABEL: hw.module @firmem

// CHECK: %mem = seq.firmem 0, 1, undefined, port_order : <12 x 42>
// CHECK: %true = hw.constant true
// CHECK: [[S3:%.+]] = seq.shiftreg[68] %wdata, %clk, %true : i42  
// CHECK: [[S4:%.+]] = seq.shiftreg[68] %addr, %clk, %true : i4  
// CHECK: [[SEN:%.+]] = seq.shiftreg[68] %en, %clk, %true : i1  
// CHECK: [[S5:%.+]] = seq.shiftreg[42] %addr, %clk, %true : i4  
// CHECK: [[SEN1:%.+]] = seq.shiftreg[42] %en, %clk, %true : i1  
// CHECK: [[RD:%.+]] = seq.firmem.read_port %mem[[[S5]]], clock %clk enable [[SEN1]] : <12 x 42>
// CHECK: seq.firmem.write_port %mem[[[S4]]] = [[S3]], clock %clk enable [[SEN]] : <12 x 42>
hw.module @firmem(in %clk: !seq.clock, in %rst: i1, in %en: i1, in %addr: i4, in %wdata: i42, in %wmode: i1) {
  %mem = seq.firmem 42, 69, undefined, port_order : <12 x 42>
  %0 = seq.firmem.read_port %mem[%addr], clock %clk enable %en : <12 x 42>
  seq.firmem.write_port %mem[%addr] = %wdata, clock %clk enable %en : <12 x 42>
}

// Read latency 0 and write latency 1 need no delay (a seq.shiftreg needs at
// least one element), so running the pass twice changes nothing.
// CHECK-LABEL: hw.module @firmemLatency01
// CHECK-NOT: seq.shiftreg
// CHECK: seq.firmem.read_port %mem[%addr], clock %clk enable %en
// CHECK: seq.firmem.write_port %mem[%addr] = %wdata, clock %clk enable %en
hw.module @firmemLatency01(in %clk: !seq.clock, in %en: i1, in %addr: i4, in %wdata: i42) {
  %mem = seq.firmem 0, 1, undefined, port_order : <12 x 42>
  %0 = seq.firmem.read_port %mem[%addr], clock %clk enable %en : <12 x 42>
  seq.firmem.write_port %mem[%addr] = %wdata, clock %clk enable %en : <12 x 42>
}

// The write mask is delayed with the write's address, data and enable.
// CHECK-LABEL: hw.module @firmemMask
// CHECK-DAG: [[A:%.+]] = seq.shiftreg[2] %addr
// CHECK-DAG: [[D:%.+]] = seq.shiftreg[2] %wdata
// CHECK-DAG: [[M:%.+]] = seq.shiftreg[2] %mask
// CHECK: seq.firmem.write_port %mem[[[A]]] = [[D]], clock %clk mask [[M]]
hw.module @firmemMask(in %clk: !seq.clock, in %addr: i4, in %wdata: i42, in %mask: i3) {
  %mem = seq.firmem 0, 3, undefined, port_order : <12 x 42, mask 3>
  seq.firmem.write_port %mem[%addr] = %wdata, clock %clk mask %mask : <12 x 42, mask 3>, i3
}
