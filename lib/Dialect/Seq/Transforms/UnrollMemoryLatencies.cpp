//===- UnrollMemoryLatencies.cpp - seq.shiftreg lowering ------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/SV/SVOps.h"
#include "circt/Dialect/Seq/SeqOps.h"
#include "circt/Dialect/Seq/SeqPasses.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"
#include "llvm/ADT/TypeSwitch.h"

namespace circt {
namespace seq {
#define GEN_PASS_DEF_UNROLLMEMORYLATENCIES
#include "circt/Dialect/Seq/SeqPasses.h.inc"
} // namespace seq
} // namespace circt

using namespace circt;
using namespace seq;

namespace {
struct UnrollMemoryLatenciesPass
    : public circt::seq::impl::UnrollMemoryLatenciesBase<
          UnrollMemoryLatenciesPass> {
  void runOnOperation() override;

private:
  /// `value` delayed by `delay` cycles: a shift register, or the value itself
  /// for no delay (a `seq.shiftreg` needs at least one element).
  static Value delayed(OpBuilder &builder, Location loc, IntegerAttr delay,
                       Value value, Value clk, Value ce) {
    if (delay.getInt() <= 0)
      return value;
    return seq::ShiftRegOp::create(builder, loc, delay, value, clk, ce, {}, {},
                                   {}, {}, {});
  }

  /// Delays all of the addresses in the given value range using the given delay
  /// and stores the delayed addresses in the given vector.
  void delayAddresses(OpBuilder &builder, Location loc, Value clk, Value ce,
                      MutableOperandRange addrs, IntegerAttr delayAttr) const {

    builder.setInsertionPoint(addrs.getOwner());

    // My understanding is that when multiple addresses are given, the same
    // data is written to each location. Therefore we must delay all of the
    // addresses individually.
    for (auto &addr : addrs)
      // delay the addr
      addr.set(delayed(builder, loc, delayAttr, addr.get(), clk, ce));
  }

  /// Unrolling for the HLMem write ports. This reduces the latency attribute
  /// of the port to 1 and implements that latency as a delay of n-1 on its
  /// data and address inputs.
  void hlMemOpWritePortUnrolling(seq::WritePortOp &op,
                                 OpBuilder &builder) const {

    // Compute the new latency attributes
    IntegerAttr latencyAttr = op.getLatencyAttr();
    IntegerAttr delayAttr =
        IntegerAttr::get(latencyAttr.getType(), latencyAttr.getInt() - 1);
    IntegerAttr oneAttr = IntegerAttr::get(latencyAttr.getType(), 1);

    // Retrieve all useful arguments
    OpOperand &data = op.getInDataMutable();
    OpOperand &wrEn = op.getWrEnMutable();
    MutableOperandRange addrs = op.getAddressesMutable();
    Value clk = op.getMemory().getDefiningOp()->getOperand(0);

    builder.setInsertionPointAfter(op);

    // A global clock enable for all ports that is always true
    Value ce = builder.createOrFold<hw::ConstantOp>(op.getLoc(),
                                                    builder.getI1Type(), 1);

    // Delay all of the addresses
    delayAddresses(builder, op.getLoc(), clk, ce, addrs, delayAttr);

    // delay the data
    data.set(delayed(builder, op.getLoc(), delayAttr, data.get(), clk, ce));

    // delay the write enable
    wrEn.set(delayed(builder, op.getLoc(), delayAttr, wrEn.get(), clk, ce));

    // Update the latency
    op.setLatencyAttr(oneAttr);
  }

  /// Unrolling for the HLMem Read ports. This reduces the latency attribute
  /// of the port to 0 and implements that latency as a delay of n, modeled
  /// as a shift-register, on its address input.
  void hlMemOpReadPortUnrolling(seq::ReadPortOp &op, OpBuilder &builder) const {
    // Compute the new latency attributes
    IntegerAttr latencyAttr = op.getLatencyAttr();
    IntegerAttr zeroAttr = IntegerAttr::get(latencyAttr.getType(), 0);

    // Retrieve all useful arguments
    MutableOperandRange addrs = op.getAddressesMutable();
    MutableOperandRange rdEn = op.getRdEnMutable();
    Value clk = op.getMemory().getDefiningOp()->getOperand(0);

    builder.setInsertionPointAfter(op);

    // A global clock enable for all ports that is always true
    Value ce = builder.createOrFold<hw::ConstantOp>(op.getLoc(),
                                                    builder.getI1Type(), 1);

    // Same as write port, delay all of the addresses
    delayAddresses(builder, op.getLoc(), clk, ce, addrs, latencyAttr);

    // delay the read enable
    for (auto &rden : rdEn)
      rden.set(delayed(builder, op.getLoc(), latencyAttr, rden.get(), clk, ce));

    op.setLatencyAttr(zeroAttr);
  }

  /// Unrolling for FirMem latencies. Unlike HLMem, FirMem stores
  /// latencies it the memory declaration op rather than the ports themselves.
  /// This makes the unrolling a little more annoying, as we need to do fetch
  /// all of the ports from the memory itself, i.e. walk its users to find the
  /// all of the relevant ports to delay before updating the memory declaration
  /// to have its new delays. The actual port updates are identical to those
  /// done in the HLMem ports.
  void unrollFirMemWritePort(seq::FirMemWriteOp &op, IntegerAttr delayAttr,
                             Value ce, OpBuilder &builder) const {

    // Retrieve all of the relevant arguments
    OpOperand &addr = op.getAddressMutable();
    OpOperand &data = op.getDataMutable();
    MutableOperandRange ens = op.getEnableMutable();
    Value clk = op.getClk();

    // Delay the address, data, and enable inputs
    data.set(delayed(builder, op.getLoc(), delayAttr, data.get(), clk, ce));

    addr.set(delayed(builder, op.getLoc(), delayAttr, addr.get(), clk, ce));

    for (auto &en : ens)
      en.set(delayed(builder, op.getLoc(), delayAttr, en.get(), clk, ce));

    // The mask belongs to the same write as the data.
    for (auto &mask : op.getMaskMutable())
      mask.set(delayed(builder, op.getLoc(), delayAttr, mask.get(), clk, ce));
  }

  /// Performs the latency unrolling of an individual read port
  void unrollFirMemReadPort(seq::FirMemReadOp &op, IntegerAttr delayRdAttr,
                            Value ce, OpBuilder &builder) const {
    // Retrieve all of the relevant arguments
    OpOperand &addr = op.getAddressMutable();
    MutableOperandRange ens = op.getEnableMutable();
    Value clk = op.getClk();

    addr.set(delayed(builder, op.getLoc(), delayRdAttr, addr.get(), clk, ce));

    for (auto &en : ens)
      en.set(delayed(builder, op.getLoc(), delayRdAttr, en.get(), clk, ce));
  }

  /// Fails on what a delayed address cannot model: a read-write port (its
  /// read and its write would need different delays of one address and mode)
  /// and a read-under-write "old" policy with read latency > 0 (a read at
  /// latency 0 sees the memory after a write committed in the cycle its
  /// address was issued, i.e. "new").
  LogicalResult firMemOpUnrolling(seq::FirMemOp &mem,
                                  OpBuilder &builder) const {
    if (mem.getReadLatency() > 0 && mem.getRuw() == seq::RUW::Old)
      return mem.emitOpError("cannot unroll the read latency of a memory "
                             "with read-under-write 'old'");
    for (auto *user : mem->getUsers())
      if (isa<seq::FirMemReadWriteOp>(user))
        return user->emitOpError("cannot unroll the latencies of a "
                                 "read-write port");

    // Retrieve read and write latencies
    IntegerAttr wrLatency = mem.getWriteLatencyAttr();
    IntegerAttr rdLatency = mem.getReadLatencyAttr();
    IntegerAttr delayRdAttr = builder.getI64IntegerAttr(rdLatency.getInt());
    IntegerAttr delayWrAttr = builder.getI64IntegerAttr(wrLatency.getInt() - 1);
    IntegerAttr zeroAttr = builder.getI32IntegerAttr(0);
    IntegerAttr oneAttr = builder.getI32IntegerAttr(1);

    builder.setInsertionPointAfter(mem);

    // A global clock enable for all ports that is always true
    Value ce = builder.createOrFold<hw::ConstantOp>(mem.getLoc(),
                                                    builder.getI1Type(), 1);

    // Find all of the relevant ports and update them
    for (auto *user : mem->getUsers()) {
      // Figure out what type of port it is an unroll it
      TypeSwitch<Operation *, void>(user)
          .Case<seq::FirMemWriteOp>([&](auto port) {
            unrollFirMemWritePort(port, delayWrAttr, ce, builder);
          })
          .Case<seq::FirMemReadOp>([&](auto port) {
            unrollFirMemReadPort(port, delayRdAttr, ce, builder);
          })
          .Default([](auto) { /*ignore non-port users*/ });
    }

    // Update the memory's latency attributes
    mem.setReadLatencyAttr(zeroAttr);
    mem.setWriteLatencyAttr(oneAttr);
    return success();
  }
};

} // namespace

void UnrollMemoryLatenciesPass::runOnOperation() {
  auto top = getOperation();
  OpBuilder builder(top);

  // Match over all hlmemport ops and firmem ops
  top->walk([&](Operation *op) {
    TypeSwitch<Operation *>(op)
        .Case<seq::WritePortOp>(
            [&](auto &wrop) { hlMemOpWritePortUnrolling(wrop, builder); })
        .Case<seq::ReadPortOp>(
            [&](auto &rdop) { hlMemOpReadPortUnrolling(rdop, builder); })
        .Case<seq::FirMemOp>(
            [&](auto &firmem) {
              if (failed(firMemOpUnrolling(firmem, builder)))
                signalPassFailure();
            })
        .Default([](auto) {});
  });
}
