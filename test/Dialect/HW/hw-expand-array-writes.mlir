// RUN: circt-opt --hw-expand-array-writes %s | FileCheck %s
// RUN: circt-opt --hw-expand-array-writes=max-elements=2 %s | FileCheck %s --check-prefix=SMALL

// `if (c) x[i] = v` becomes a select per element on c & i == k.
// CHECK-LABEL: hw.module @Write
// CHECK-DAG:   %[[I0:.+]] = comb.icmp eq %i, %c0_i2
// CHECK-DAG:   %[[S0:.+]] = comb.and %c, %[[I0]]
// CHECK-DAG:   %[[X0:.+]] = hw.array_get %x[%c0_i2]
// CHECK-DAG:   %[[E0:.+]] = comb.mux %[[S0]], %v, %[[X0]]
// CHECK-DAG:   %[[I2:.+]] = comb.icmp eq %i, %c-2_i2
// CHECK-DAG:   %[[S2:.+]] = comb.and %c, %[[I2]]
// CHECK-DAG:   %[[X2:.+]] = hw.array_get %x[%c-2_i2]
// CHECK-DAG:   %[[E2:.+]] = comb.mux %[[S2]], %v, %[[X2]]
// CHECK:       %[[R:.+]] = hw.array_create %[[E2]], %{{.+}}, %[[E0]]
// CHECK:       hw.output %[[R]]
// SMALL-LABEL: hw.module @Write
// SMALL:       hw.array_inject
hw.module @Write(in %x : !hw.array<3xi8>, in %c : i1, in %i : i2, in %v : i8, out o : !hw.array<3xi8>) {
  %0 = hw.array_inject %x[%i], %v : !hw.array<3xi8>, i2
  %1 = comb.mux %c, %0, %x : !hw.array<3xi8>
  hw.output %1 : !hw.array<3xi8>
}

// The write on the false side: the selects use ~c.
// CHECK-LABEL: hw.module @WriteWhenFalse
// CHECK:       %[[NC:.+]] = comb.xor %c, %true
// CHECK:       comb.and %[[NC]],
// CHECK-NOT:   hw.array_inject
hw.module @WriteWhenFalse(in %x : !hw.array<2xi8>, in %c : i1, in %i : i1, in %v : i8, out o : !hw.array<2xi8>) {
  %0 = hw.array_inject %x[%i], %v : !hw.array<2xi8>, i1
  %1 = comb.mux %c, %x, %0 : !hw.array<2xi8>
  hw.output %1 : !hw.array<2xi8>
}

// A write whose result is also used elsewhere stays.
// CHECK-LABEL: hw.module @SharedWrite
// CHECK:       hw.array_inject
// CHECK:       comb.mux
hw.module @SharedWrite(in %x : !hw.array<2xi8>, in %c : i1, in %i : i1, in %v : i8, out o : !hw.array<2xi8>, out p : !hw.array<2xi8>) {
  %0 = hw.array_inject %x[%i], %v : !hw.array<2xi8>, i1
  %1 = comb.mux %c, %0, %x : !hw.array<2xi8>
  hw.output %1, %0 : !hw.array<2xi8>, !hw.array<2xi8>
}
