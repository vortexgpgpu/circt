# Emits a register whose next value is a chain of N ANDs and then N muxes over
# its own value (see reg-const-prop-deep.mlir).
import sys

n = int(sys.argv[1])
print("hw.module @Deep(in %clk : !seq.clock, in %rst : i1, in %a : i1, out q : i1) {")
print("  %true = hw.constant true")
prev = "%r"
for i in range(n):
    print(f"  %x{i} = comb.and {prev}, %true : i1")
    prev = f"%x{i}"
for i in range(n):
    print(f"  %m{i} = comb.mux %true, {prev}, %a : i1")
    prev = f"%m{i}"
print(f"  %r = seq.firreg {prev} clock %clk reset sync %rst, %true : i1")
print("  hw.output %r : i1")
print("}")
