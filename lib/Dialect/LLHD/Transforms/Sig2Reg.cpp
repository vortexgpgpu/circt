//===----------------------------------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Promote LLHD signals to SSA values.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/LLHD/LLHDOps.h"
#include "circt/Dialect/LLHD/LLHDPasses.h"
#include "circt/Dialect/SV/SVAttributes.h"
#include "circt/Dialect/Seq/SeqOps.h"
#include "circt/Dialect/Sim/SimOps.h"
#include "mlir/IR/Matchers.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "llhd-sig2reg"

namespace circt {
namespace llhd {
#define GEN_PASS_DEF_SIG2REGPASS
#include "circt/Dialect/LLHD/LLHDPasses.h.inc"
} // namespace llhd
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace llhd;

/// Keep the SV attributes of a promoted signal, e.g. `(* ram_style *)` or
/// `(* use_dsp *)`, which would otherwise disappear with it: a register that
/// holds the signal's value takes them over, and any other value is passed
/// through a wire of the signal's name that carries them.
static Value keepAttributes(llhd::SignalOp sigOp, Value value,
                            OpBuilder &builder) {
  auto svAttrs = sv::getSVAttributes(sigOp);
  if (!svAttrs || svAttrs.empty())
    return value;
  if (auto *defOp = value.getDefiningOp();
      defOp && isa<seq::FirRegOp, seq::CompRegOp>(defOp)) {
    sv::addSVAttributes(
        defOp, llvm::to_vector(svAttrs.getAsRange<sv::SVAttributeAttr>()));
    return value;
  }
  auto wire =
      hw::WireOp::create(builder, sigOp.getLoc(), value, sigOp.getNameAttr());
  sv::setSVAttributes(wire, svAttrs);
  return wire;
}

/// Whether a drive takes effect immediately: a blocking `llhd.assign`, or an
/// `llhd.drv` without any delay.
static bool isImmediate(llhd::DriveLikeOp drive) {
  if (!drive.getTime())
    return true;
  auto timeOp = drive.getTime().getDefiningOp<llhd::ConstantTimeOp>();
  if (!timeOp)
    return false;
  auto time = timeOp.getValue();
  return time.getTime() == 0 && time.getDelta() == 0;
}

namespace {

/// Represents an offset of an interval relative to a root interval. All values
/// describe number of bits, not elements.
struct Offset {
  Offset(uint64_t min, uint64_t max, ArrayRef<Value> dynamic)
      : min(min), max(max), dynamic(dynamic) {}

  Offset(uint64_t idx) : min(idx), max(idx) {}

  // The lower bound of the offset known statically.
  uint64_t min = 0;
  // The upper bound of the offset known statically.
  uint64_t max = -1;
  // A list of SSA values used to compute the final offset.
  SmallVector<Value> dynamic;

  /// Returns if we know the exact offset statically.
  bool isStatic() const { return min == max; }
};

/// Represents an alias interval within a root interval that is written to or
/// read from. All values refer to number of bits, not elements.
struct Interval {
  Interval(const Offset &low, uint64_t bitwidth, Value value,
           llhd::TimeAttr delay = llhd::TimeAttr())
      : low(low), bitwidth(bitwidth), value(value), delay(delay) {}

  // The offset of the interval relative to the root interval (i.e. all the bits
  // of the original signal).
  Offset low;
  // The width of the interval.
  uint64_t bitwidth;
  // The value written to this interval or the OpResult of a read.
  Value value;
  // The delay with which the value is written. Null if the value is assigned
  // immediately.
  llhd::TimeAttr delay;
};

class SigPromoter {
public:
  SigPromoter(llhd::SignalOp sigOp) : sigOp(sigOp) {}

  // Start at the signal operation and traverse all alias operations to compute
  // all the intervals and sort them by ascending offset.
  LogicalResult computeIntervals() {
    SmallVector<std::pair<Operation *, Offset>> stack;

    for (auto *user : sigOp->getUsers())
      stack.emplace_back(user, Offset(0));

    while (!stack.empty()) {
      auto currAndOffset = stack.pop_back_val();
      auto *curr = currAndOffset.first;
      auto offset = currAndOffset.second;

      if (curr->getBlock() != sigOp->getBlock()) {
        LLVM_DEBUG(llvm::dbgs() << "  - User in other block, skipping...\n\n");
        return failure();
      }

      auto result =
          TypeSwitch<Operation *, LogicalResult>(curr)
              .Case<llhd::ProbeOp>([&](llhd::ProbeOp probeOp) {
                auto bw = hw::getBitWidth(probeOp.getResult().getType());
                if (bw <= 0)
                  return failure();

                readIntervals.emplace_back(offset, bw, probeOp.getResult());
                return success();
              })
              .Case<llhd::DriveOp>([&](llhd::DriveOp driveOp) {
                if (driveOp.getEnable()) {
                  LLVM_DEBUG(llvm::dbgs()
                             << "  - Conditional driver, skipping...\n\n");
                  return failure();
                }

                auto timeOp =
                    driveOp.getTime().getDefiningOp<llhd::ConstantTimeOp>();
                if (!timeOp) {
                  LLVM_DEBUG(llvm::dbgs()
                             << "  - Unknown drive delay, skipping...\n\n");
                  return failure();
                }

                auto bw = hw::getBitWidth(driveOp.getValue().getType());
                if (bw <= 0)
                  return failure();

                intervals.emplace_back(offset, bw, driveOp.getValue(),
                                       timeOp.getValueAttr());
                return success();
              })
              .Case<llhd::AssignOp>([&](llhd::AssignOp assignOp) {
                if (assignOp.getEnable()) {
                  LLVM_DEBUG(llvm::dbgs()
                             << "  - Conditional assignment, skipping...\n\n");
                  return failure();
                }

                auto bw = hw::getBitWidth(assignOp.getValue().getType());
                if (bw <= 0)
                  return failure();

                intervals.emplace_back(offset, bw, assignOp.getValue());
                return success();
              })
              .Case<llhd::SigExtractOp>([&](llhd::SigExtractOp extractOp) {
                if (auto constOp =
                        extractOp.getLowBit().getDefiningOp<hw::ConstantOp>();
                    constOp && offset.isStatic()) {
                  for (auto *user : extractOp->getUsers())
                    stack.emplace_back(
                        user,
                        Offset(constOp.getValue().getZExtValue() + offset.min));

                  return success();
                }

                auto bw = hw::getBitWidth(
                    cast<llhd::RefType>(extractOp.getInput().getType())
                        .getNestedType());
                if (bw <= 0)
                  return failure();

                SmallVector<Value> indices(offset.dynamic);
                indices.push_back(extractOp.getLowBit());

                for (auto *user : extractOp->getUsers())
                  stack.emplace_back(
                      user, Offset(offset.min, offset.max + bw - 1, indices));

                return success();
              })
              .Default([](auto *op) {
                LLVM_DEBUG(llvm::dbgs() << "  - User that is not a probe or "
                                           "drive, skipping...\n    "
                                        << *op << "\n\n");
                return failure();
              });

      if (failed(result))
        return failure();

      toDelete.push_back(curr);
    }

    llvm::sort(intervals, [](const Interval &a, const Interval &b) {
      return a.low.min < b.low.min;
    });

    LLVM_DEBUG({
      llvm::dbgs() << "  - Detected intervals:\n";
      dumpIntervals(llvm::dbgs(), 4);
    });

    return success();
  }

#ifndef NDEBUG

  /// Print the list of intervals in a readable format for debugging.
  void dumpIntervals(llvm::raw_ostream &os, unsigned indent = 0) {
    os << llvm::indent(indent) << "[\n";
    for (const auto &interval : intervals) {
      os << llvm::indent(indent + 2) << "<from [" << interval.low.min << ", "
         << interval.low.max << "]\n";
      os << llvm::indent(indent + 3) << "width " << interval.bitwidth << "\n";

      for (auto idx : interval.low.dynamic)
        os << llvm::indent(indent + 3) << idx << "\n";

      os << llvm::indent(indent + 3) << "value: " << interval.value << "\n";
      if (interval.delay)
        os << llvm::indent(indent + 3) << "delay: " << interval.delay << "\n";
      os << llvm::indent(indent + 2) << ">,\n";
    }
    os << llvm::indent(indent) << "]\n";
  }

#endif

  /// Check if we can promote the entire signal according to the current
  /// limitations of the pass.
  bool isPromotable() {
    // A delayed write leaves the initial value visible until it takes effect,
    // which the promoted value cannot express; see Sig2RegPass::promote.
    if (llvm::any_of(intervals, [](auto &interval) { return interval.delay; }))
      return false;
    // The signal captures a non-constant initial value only once, so it does
    // not equal that value at all times; see Sig2RegPass::promote.
    if (sigOp.getInit() && !matchPattern(sigOp.getInit(), m_Constant()))
      return false;
    if (!sigOp.getInit()) {
      auto bw = hw::getBitWidth(sigOp.getType().getNestedType());
      return intervals.size() == 1 && intervals.front().low.isStatic() &&
             intervals.front().low.min == 0 &&
             intervals.front().bitwidth == bw && !intervals.front().delay;
    }
    for (unsigned i = 0; i < intervals.size(); ++i) {
      if (i >= intervals.size() - 1)
        break;

      if (intervals[i].low.max + intervals[i].bitwidth - 1 >
          intervals[i + 1].low.min) {
        LLVM_DEBUG({
          llvm::dbgs() << "  - Potentially overlapping drives, skipping...\n\n";
        });
        return false;
      }
    }

    return true;
  }

  /// Promote the signal. This builds the necessary operations, replaces the
  /// values, and removes the signal and signal value handling operations.
  void promote() {
    auto bw = hw::getBitWidth(sigOp.getType().getNestedType());
    assert(bw > 0 && "bw must be known and non-zero");

    OpBuilder builder(sigOp);
    Value val = sigOp.getInit();
    Location loc = sigOp->getLoc();
    auto type = builder.getIntegerType(bw);
    if (!val) {
      // A single immediate drive covering every bit defines the signal without
      // needing an initial value.
      val = builder.createOrFold<hw::BitcastOp>(loc, type,
                                                intervals.front().value);
    } else {
      val = builder.createOrFold<hw::BitcastOp>(loc, type, val);

      // Handle the writes by starting with the signal init value and injecting
      // the written values at the right offsets.
      for (auto interval : intervals) {
        Value invMask = hw::ConstantOp::create(
            builder, loc, APInt::getAllOnes(interval.bitwidth));

        if (uint64_t(bw) > interval.bitwidth) {
          Value pad = hw::ConstantOp::create(
              builder, loc, APInt::getZero(bw - interval.bitwidth));
          invMask = builder.createOrFold<comb::ConcatOp>(loc, pad, invMask);
        }

        Value amt = buildDynamicIndex(builder, loc, interval.low.min,
                                      interval.low.dynamic, bw);
        invMask = builder.createOrFold<comb::ShlOp>(loc, invMask, amt);
        Value allOnes =
            hw::ConstantOp::create(builder, loc, APInt::getAllOnes(bw));
        Value mask = builder.createOrFold<comb::XorOp>(loc, invMask, allOnes);
        val = builder.createOrFold<comb::AndOp>(loc, val, mask);

        Value assignVal = builder.createOrFold<hw::BitcastOp>(
            loc, builder.getIntegerType(interval.bitwidth), interval.value);

        if (uint64_t(bw) > interval.bitwidth) {
          Value pad = hw::ConstantOp::create(
              builder, loc, APInt::getZero(bw - interval.bitwidth));
          assignVal = builder.createOrFold<comb::ConcatOp>(loc, pad, assignVal);
        }

        assignVal = builder.createOrFold<comb::ShlOp>(loc, assignVal, amt);
        if (interval.delay)
          assignVal = builder.createOrFold<llhd::DelayOp>(loc, assignVal,
                                                          interval.delay);
        val = builder.createOrFold<comb::OrOp>(loc, assignVal, val);
      }
    }

    val = keepAttributes(sigOp, val, builder);

    // Handle the reads by extracting right number of bits at the right offset.
    for (auto interval : readIntervals) {
      if (interval.low.isStatic()) {
        Value read = builder.createOrFold<comb::ExtractOp>(
            loc, builder.getIntegerType(interval.bitwidth), val,
            interval.low.min);
        read = builder.createOrFold<hw::BitcastOp>(
            loc, interval.value.getType(), read);
        if (read != interval.value) {
          interval.value.replaceAllUsesWith(read);
        }
        continue;
      }

      Value read = buildDynamicIndex(builder, loc, interval.low.min,
                                     interval.low.dynamic, bw);
      read = builder.createOrFold<comb::ShrUOp>(loc, val, read);
      read = builder.createOrFold<comb::ExtractOp>(
          loc, builder.getIntegerType(interval.bitwidth), read, 0);
      read = builder.createOrFold<hw::BitcastOp>(loc, interval.value.getType(),
                                                 read);
      if (read != interval.value) {
        interval.value.replaceAllUsesWith(read);
      }
    }

    // Delete all operations operating on signal values.
    for (auto *op : llvm::reverse(toDelete))
      op->erase();

    sigOp->erase();
  }

private:
  /// Given a static offset and a list of dynamic offset values, materialize an
  /// SSA value that adds all these offsets together and is an integer with the
  /// given 'width'.
  Value buildDynamicIndex(OpBuilder &builder, Location loc,
                          uint64_t constOffset, ArrayRef<Value> indices,
                          uint64_t width) {
    Value index = hw::ConstantOp::create(
        builder, loc, builder.getIntegerType(width), constOffset);

    for (auto idx : indices) {
      auto bw = hw::getBitWidth(idx.getType());
      Value pad =
          hw::ConstantOp::create(builder, loc, APInt::getZero(width - bw));
      idx = builder.createOrFold<comb::ConcatOp>(loc, pad, idx);
      index = builder.createOrFold<comb::AddOp>(loc, index, idx);
    }

    return index;
  }

  // The signal to be promoted.
  llhd::SignalOp sigOp;
  // Intervals written to.
  SmallVector<Interval> intervals;
  // Intervals read from.
  SmallVector<Interval> readIntervals;
  // Operations to delete after promotion is done.
  SmallVector<Operation *> toDelete;
};
} // namespace

/// Promote a signal that has exactly one unconditional, immediate drive of its
/// whole value, and is otherwise only probed, either directly or through
/// static projections (array elements, struct fields, bit slices). Reads are
/// rebuilt from the driven value with the matching aggregate ops, keeping the
/// value's structure instead of flattening the signal into one bit vector.
static LogicalResult promoteSingleWholeDrive(llhd::SignalOp sigOp) {
  llhd::DriveLikeOp drive;
  SmallVector<std::pair<Operation *, SmallVector<Operation *>>> probes;
  SmallVector<Operation *> projections;
  SmallVector<std::pair<Value, SmallVector<Operation *>>> worklist;
  worklist.push_back({sigOp.getResult(), {}});
  while (!worklist.empty()) {
    auto [value, path] = worklist.pop_back_val();
    for (auto &use : value.getUses()) {
      auto *user = use.getOwner();
      if (user->getBlock() != sigOp->getBlock())
        return failure();
      if (auto driveOp = dyn_cast<llhd::DriveLikeOp>(user)) {
        if (use.getOperandNumber() != 0 || !path.empty() || drive ||
            driveOp.getEnable() || !isImmediate(driveOp))
          return failure();
        drive = driveOp;
        continue;
      }
      if (isa<llhd::ProbeOp>(user)) {
        probes.push_back({user, path});
        continue;
      }
      bool isStatic =
          TypeSwitch<Operation *, bool>(user)
              .Case<llhd::SigArrayGetOp>([](auto op) {
                return matchPattern(op.getIndex(), m_Constant());
              })
              .Case<llhd::SigExtractOp>([](auto op) {
                return matchPattern(op.getLowBit(), m_Constant());
              })
              .Case<llhd::SigStructExtractOp>([](auto) { return true; })
              .Default([](auto) { return false; });
      if (!isStatic)
        return failure();
      projections.push_back(user);
      auto subPath = path;
      subPath.push_back(user);
      worklist.push_back({user->getResult(0), subPath});
    }
  }
  if (!drive)
    return failure();

  // Rebuild every probed value from the driven value.
  OpBuilder sigBuilder(drive);
  Value driven = keepAttributes(sigOp, drive.getValue(), sigBuilder);
  // The value of each projection, built once for all the probes through it.
  DenseMap<Operation *, Value> projected;
  for (auto &[probe, path] : probes) {
    OpBuilder builder(probe);
    Value value = driven;
    for (auto *proj : path) {
      if (auto known = projected.lookup(proj)) {
        value = known;
        continue;
      }
      auto loc = proj->getLoc();
      if (auto op = dyn_cast<llhd::SigArrayGetOp>(proj)) {
        value = builder.createOrFold<hw::ArrayGetOp>(loc, value, op.getIndex());
      } else if (auto op = dyn_cast<llhd::SigStructExtractOp>(proj)) {
        value = builder.createOrFold<hw::StructExtractOp>(loc, value,
                                                          op.getFieldAttr());
      } else {
        auto ext = cast<llhd::SigExtractOp>(proj);
        IntegerAttr low;
        matchPattern(ext.getLowBit(), m_Constant(&low));
        auto width = hw::getBitWidth(
            cast<llhd::RefType>(ext.getResult().getType()).getNestedType());
        value = builder.createOrFold<comb::ExtractOp>(
            loc, builder.getIntegerType(width), value,
            low.getValue().getZExtValue());
      }
      projected[proj] = value;
    }
    probe->getResult(0).replaceAllUsesWith(value);
    probe->erase();
  }
  drive.erase();
  for (auto *op : llvm::reverse(projections))
    op->erase();
  sigOp.erase();
  return success();
}

/// The bits of a constant integer or aggregate value, as an integer attribute
/// of its width, or null if the value is not a constant.
static IntegerAttr getConstantBits(Value value) {
  Attribute attr;
  if (!matchPattern(value, m_Constant(&attr)))
    return {};
  if (auto intAttr = dyn_cast<IntegerAttr>(attr))
    return intAttr;
  APInt bits;
  auto fields = dyn_cast<ArrayAttr>(attr);
  if (!fields ||
      failed(hw::aggregateAttrToAPInt(value.getType(), fields, bits)))
    return {};
  return IntegerAttr::get(
      IntegerType::get(value.getContext(), bits.getBitWidth()), bits);
}

/// The `$readmemh`/`$readmemb` an `initial` block loads a whole signal with:
/// a process that runs once and yields the contents loaded from a file into
/// the signal as it starts out. Null if `value` is not such a load.
static sim::SVReadMemOp getInitialFileLoad(Value value, llhd::SignalOp sigOp) {
  auto result = dyn_cast<OpResult>(value);
  auto process =
      result ? dyn_cast<llhd::ProcessOp>(result.getOwner()) : llhd::ProcessOp{};
  if (!process || !process.getBody().hasOneBlock())
    return {};
  auto halt = dyn_cast<llhd::HaltOp>(process.getBody().front().getTerminator());
  if (!halt)
    return {};
  auto load = halt.getYieldOperands()[result.getResultNumber()]
                  .getDefiningOp<sim::SVReadMemOp>();
  // The whole file, without start or finish address or slice, loaded into a
  // memory of one dimension, which addresses its elements.
  if (!load || load.getStartAddr() || load.getFinishAddr() ||
      load.getSliceLeft() || load.getSliceRight() || load.getEnumValues() ||
      load.getDimDescending().size() != 1 ||
      !load.getFilename().getDefiningOp<sim::StringConstantOp>())
    return {};
  // The load starts from the signal as it starts out.
  auto probe = load.getMemory().getDefiningOp<llhd::ProbeOp>();
  if (!probe || probe.getSignal() != sigOp.getResult() ||
      probe->getBlock() != sigOp->getBlock())
    return {};
  return load;
}

/// Fold the value a signal starts out with into the register that drives it.
/// A register drives the signal, and an `initial` block drives it once with
/// its first value: a constant, which becomes the register's preset, or the
/// contents of a file, which the register array records to be loaded from.
/// Without the second drive, the register holds the signal on its own.
static LogicalResult foldInitialDrive(llhd::SignalOp sigOp) {
  // Two drives of the whole signal, and no drive of a part of it.
  SmallVector<llhd::DriveLikeOp, 2> drives;
  SmallVector<Value> worklist{sigOp.getResult()};
  while (!worklist.empty()) {
    auto value = worklist.pop_back_val();
    for (auto &use : value.getUses()) {
      auto *user = use.getOwner();
      if (auto drive = dyn_cast<llhd::DriveLikeOp>(user)) {
        if (value != sigOp.getResult() || use.getOperandNumber() != 0 ||
            drive.getEnable() || drive->getBlock() != sigOp->getBlock())
          return failure();
        drives.push_back(drive);
      } else if (!isa<llhd::ProbeOp>(user)) {
        for (auto result : user->getResults())
          if (isa<llhd::RefType>(result.getType()))
            worklist.push_back(result);
      }
    }
  }
  if (drives.size() != 2)
    return failure();

  // Both drives take effect immediately, at the start for the initial one.
  auto regDrive = drives[0], initDrive = drives[1];
  if (!regDrive.getValue().getDefiningOp<seq::FirRegOp>())
    std::swap(regDrive, initDrive);
  auto reg = regDrive.getValue().getDefiningOp<seq::FirRegOp>();
  if (!reg || !isImmediate(regDrive) || !isImmediate(initDrive))
    return failure();

  if (auto bits = getConstantBits(initDrive.getValue())) {
    LLVM_DEBUG(llvm::dbgs()
               << "  - Folding the initial value into " << reg << "\n");
    reg.setPresetAttr(bits);
    initDrive.erase();
    return success();
  }

  auto load = getInitialFileLoad(initDrive.getValue(), sigOp);
  auto arrayType = hw::type_dyn_cast<hw::ArrayType>(reg.getType());
  if (!load || !arrayType)
    return failure();
  LLVM_DEBUG(llvm::dbgs() << "  - Folding the initial file load into " << reg
                          << "\n");
  auto filename = load.getFilename().getDefiningOp<sim::StringConstantOp>();
  reg->setAttr(seq::getRegFileInitAttrName(),
               seq::FirMemInitAttr::get(reg.getContext(),
                                        filename.getLiteralAttr(),
                                        load.getIsBinary(),
                                        /*isInline=*/true));
  // A file loads a memory from its lowest address up. The first element of an
  // array is its right bound, the highest address of an ascending range.
  if (!load.getDimDescending()[0])
    reg->setAttr(seq::getRegFileInitReversedAttrName(),
                 UnitAttr::get(reg.getContext()));
  // The process goes once it loads nothing else and does nothing besides.
  auto process =
      cast<llhd::ProcessOp>(cast<OpResult>(initDrive.getValue()).getOwner());
  initDrive.erase();
  if (process->use_empty() &&
      llvm::all_of(process.getBody().front(), [](Operation &op) {
        return isa<sim::SVReadMemOp, llhd::HaltOp>(op) || isPure(&op);
      })) {
    process.erase();
    if (filename->use_empty())
      filename.erase();
  }
  return success();
}


namespace {
struct Sig2RegPass : public llhd::impl::Sig2RegPassBase<Sig2RegPass> {
  void runOnOperation() override;
  bool promote(SignalOp op);
  SmallVector<SignalOp> signalsToErase;
};
} // namespace

void Sig2RegPass::runOnOperation() {
  LLVM_DEBUG(llvm::dbgs() << "Promoting signals to values in "
                          << getOperation().getModuleName() << "\n");
  for (auto op : llvm::make_early_inc_range(getOperation().getOps<SignalOp>())) {
    // A register array or preset an `initial` block fills is folded into the
    // register first; then a signal with a single whole-value drive, whose
    // probes may go through static projections, is rebuilt from the driven
    // value; anything else goes to the plain promoter, and what that skips to
    // the interval promoter, which combines immediate partial writes.
    (void)foldInitialDrive(op);
    if (succeeded(promoteSingleWholeDrive(op))) {
      ++numPromoted;
      continue;
    }
    if (promote(op))
      continue;
    SigPromoter promoter(op);
    if (succeeded(promoter.computeIntervals()) && promoter.isPromotable()) {
      promoter.promote();
      --numSkipped;
      ++numIntervalPromoted;
    }
  }
  for (auto op : signalsToErase)
    op.erase();
  signalsToErase.clear();
}

bool Sig2RegPass::promote(SignalOp op) {
  // Find the single drive, and check if there are any probes or multiple drives
  // of this signal. Bail on unknown users.
  DriveLikeOp drive;
  bool multipleDrives = false;
  bool anyProbe = false;
  for (auto *user : op->getUsers()) {
    if (isa<ProbeOp>(user)) {
      anyProbe = true;
      continue;
    }

    if (auto driveOp = dyn_cast<DriveLikeOp>(user)) {
      if (driveOp->getBlock() != op->getBlock()) {
        LLVM_DEBUG(llvm::dbgs() << "- Skipping " << op
                                << " (driven from different block)\n");
        ++numSkipped;
        return false;
      }
      if (drive)
        multipleDrives = true;
      drive = driveOp;
      continue;
    }

    // Unknown user.
    LLVM_DEBUG(llvm::dbgs() << "- Skipping " << op << " (unsupported user "
                            << user->getName() << ")\n");
    ++numSkipped;
    return false;
  }

  // Remove unprobed signals.
  if (!anyProbe) {
    LLVM_DEBUG(llvm::dbgs() << "- Removing unprobed " << op << "\n");
    ++numUnused;
    SmallPtrSet<Operation *, 8> erased;
    for (auto *user : llvm::make_early_inc_range(op->getUsers()))
      if (erased.insert(user).second)
        user->erase();
    signalsToErase.push_back(op);
    return true;
  }

  // If there are multiple drives, we cannot come up with a clean replacement
  // value.
  if (multipleDrives) {
    LLVM_DEBUG(llvm::dbgs() << "- Skipping " << op << " (multiple drives)\n");
    ++numSkipped;
    return false;
  }

  // We can't promote conditional drives.
  if (drive && drive.getEnable()) {
    LLVM_DEBUG(llvm::dbgs() << "- Skipping " << op << " (conditional drive)\n");
    ++numSkipped;
    return false;
  }

  // Determine the value to replace the signal with.
  Value value;
  if (drive) {
    value = drive.getValue();
    if (drive.getTime()) {
      if (op.getInit()) {
        LLVM_DEBUG(llvm::dbgs()
                   << "- Skipping " << op
                   << " (delayed drive to signal with initializer)\n");
        ++numSkipped;
        return false;
      }
      TimeAttr delay;
      if (!matchPattern(drive.getTime(), m_Constant(&delay))) {
        LLVM_DEBUG(llvm::dbgs()
                   << "- Skipping " << op << " (non-constant drive delay)\n");
        ++numSkipped;
        return false;
      }
      OpBuilder builder(drive);
      value = DelayOp::create(builder, drive.getLoc(), value, delay);
    }
  } else {
    value = op.getInit();
    if (!value) {
      LLVM_DEBUG(llvm::dbgs()
                 << "- Skipping " << op << " (undriven with no initializer)\n");
      ++numSkipped;
      return false;
    }

    // The signal captures its initial value once. Only a constant initializer
    // is guaranteed to equal the signal's value at all times.
    if (!matchPattern(value, m_Constant())) {
      LLVM_DEBUG(llvm::dbgs() << "- Skipping " << op
                              << " (undriven with non-constant initializer)\n");
      ++numSkipped;
      return false;
    }
  }

  // Replace all probes with this value, and remove all users, which are only
  // probes and drives at this point.
  LLVM_DEBUG({
    llvm::dbgs() << "- Replacing " << op << " with ";
    value.printAsOperand(llvm::dbgs(), OpPrintingFlags());
    llvm::dbgs() << "\n";
  });
  {
    OpBuilder builder(op);
    if (auto *defOp = value.getDefiningOp();
        defOp && defOp->getBlock() == op->getBlock() &&
        op->isBeforeInBlock(defOp))
      builder.setInsertionPointAfter(defOp);
    value = keepAttributes(op, value, builder);
  }
  SmallPtrSet<Operation *, 8> erased;
  for (auto *user : llvm::make_early_inc_range(op->getUsers())) {
    if (auto probeOp = dyn_cast<ProbeOp>(user))
      probeOp.replaceAllUsesWith(value);
    if (erased.insert(user).second)
      user->erase();
  }
  signalsToErase.push_back(op);
  ++numPromoted;
  return true;
}
