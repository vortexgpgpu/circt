//===- RegConstProp.cpp - Constant register bits ----------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Finds the register bits that only ever hold one constant and replaces them
// with it, by an optimistic fixpoint over the bits of the module's values.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/Seq/SeqOps.h"
#include "circt/Dialect/Seq/SeqPasses.h"
#include "mlir/IR/ImplicitLocOpBuilder.h"
#include "mlir/IR/Matchers.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/DenseMap.h"

namespace circt {
namespace seq {
#define GEN_PASS_DEF_REGCONSTPROP
#include "circt/Dialect/Seq/SeqPasses.h.inc"
} // namespace seq
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace seq;

namespace {

/// What is known of a bit: nothing yet, a constant, or that it varies.
enum class Bit : uint8_t { Undefined, Zero, One, Varying };
using Bits = SmallVector<Bit>;

static Bit meet(Bit a, Bit b) {
  if (a == Bit::Undefined)
    return b;
  if (b == Bit::Undefined || a == b)
    return a;
  return Bit::Varying;
}

static bool isConstant(Bit bit) { return bit == Bit::Zero || bit == Bit::One; }

class Analysis {
public:
  explicit Analysis(hw::HWModuleOp module);

  /// Iterates to a fixpoint; with `defined`, a register bit nothing defines
  /// varies, so that no constant rests on an undefined value.
  void solve(bool defined);
  const Bits &get(Value value);

  SmallVector<FirRegOp> registers;
  DenseMap<Value, Bits> state;

private:
  Bits compute(Value value);
  Bits fold(Operation *op, unsigned resultNumber, unsigned width);
  /// The values `compute` reads whatever their bits, in the order it reads
  /// them; none for an op whose reads depend on the bits it reads first.
  void staticReads(Value value, SmallVectorImpl<Value> &reads);
  /// A value's bits known or being computed.
  const Bits *lookup(Value value);
  /// Varying bits of a width, in place of a value not computed yet.
  const Bits &placeholder(unsigned width);

  /// Held by pointer, as the bits of a value are read while others are added.
  DenseMap<Value, std::unique_ptr<Bits>> cache;
  /// While `compute` runs: the first value it read that is not computed yet.
  bool computing = false;
  Value missing;
  DenseMap<unsigned, std::unique_ptr<Bits>> placeholders;
};

struct RegConstPropPass
    : public circt::seq::impl::RegConstPropBase<RegConstPropPass> {
  void runOnOperation() override;
};

} // namespace

static unsigned elementWidth(Type arrayType) {
  return hw::getBitWidth(
      hw::type_cast<hw::ArrayType>(arrayType).getElementType());
}

/// The bits of a constant, low bit first.
static Bits bitsOf(const APInt &value) {
  Bits bits(value.getBitWidth());
  for (unsigned i = 0; i < bits.size(); ++i)
    bits[i] = value[i] ? Bit::One : Bit::Zero;
  return bits;
}

Analysis::Analysis(hw::HWModuleOp module) {
  module.walk([&](FirRegOp reg) {
    auto width = hw::getBitWidth(reg.getType());
    if (width <= 0 || reg.getInnerSymAttr())
      return;
    registers.push_back(reg);
    // A register starts from its reset or preset value, if it has one.
    Bits bits(width, Bit::Undefined);
    if (auto preset = reg.getPresetAttr())
      bits = bitsOf(preset.getValue());
    state[reg] = bits;
  });
}

void Analysis::solve(bool defined) {
  if (defined)
    for (auto &[reg, bits] : state)
      for (auto &bit : bits)
        if (bit == Bit::Undefined)
          bit = Bit::Varying;
  for (bool changed = true; changed;) {
    changed = false;
    cache.clear();
    for (auto reg : registers) {
      auto &bits = state[reg];
      auto next = get(reg.getNext());
      Bits reset;
      if (reg.hasReset())
        reset = get(reg.getResetValue());
      for (unsigned i = 0; i < bits.size(); ++i) {
        auto bit = meet(bits[i], next[i]);
        if (!reset.empty())
          bit = meet(bit, reset[i]);
        if (defined && bit == Bit::Undefined)
          bit = Bit::Varying;
        if (bit != bits[i]) {
          bits[i] = bit;
          changed = true;
        }
      }
    }
  }
}

const Bits *Analysis::lookup(Value value) {
  if (auto reg = value.getDefiningOp<FirRegOp>())
    if (auto it = state.find(reg); it != state.end())
      return &it->second;
  if (auto it = cache.find(value); it != cache.end())
    return it->second.get();
  return nullptr;
}

const Bits &Analysis::placeholder(unsigned width) {
  auto &slot = placeholders[width];
  if (!slot)
    slot = std::make_unique<Bits>(width, Bit::Varying);
  return *slot;
}

/// Computes `root` and the values it reads depth first, as a recursion over
/// the reads would, but without one: logic chains far more values than a
/// thread's stack holds frames. A value whose bits depend on other bits of
/// itself, a cycle of the logic between words though not between bits, reads
/// as varying while it is computed: the conservative answer, where the search
/// would not end. Each value is computed once the values it reads are: those
/// it reads whatever their bits first, in order; then `compute` runs, and a
/// read of a value not computed yet stops it (it reads varying bits in its
/// place), that value is computed, and `compute` runs again.
const Bits &Analysis::get(Value root) {
  if (auto *bits = lookup(root))
    return *bits;
  if (computing) {
    if (!missing)
      missing = root;
    return placeholder(std::max<int64_t>(hw::getBitWidth(root.getType()), 0));
  }
  struct Frame {
    Value value;
    SmallVector<Value, 4> reads;
    unsigned next = 0;
  };
  SmallVector<Frame> frames;
  auto enter = [&](Value value) {
    auto width = std::max<int64_t>(hw::getBitWidth(value.getType()), 0);
    cache[value] = std::make_unique<Bits>(width, Bit::Varying);
    frames.push_back({value, {}, 0});
    staticReads(value, frames.back().reads);
  };
  enter(root);
  while (!frames.empty()) {
    auto &frame = frames.back();
    if (frame.next < frame.reads.size()) {
      Value read = frame.reads[frame.next++];
      if (!lookup(read))
        enter(read);
      continue;
    }
    Value value = frame.value;
    computing = true;
    missing = {};
    auto bits = compute(value);
    computing = false;
    if (missing) {
      enter(missing);
      continue;
    }
    *cache[value] = std::move(bits);
    frames.pop_back();
  }
  return *cache[root];
}

void Analysis::staticReads(Value value, SmallVectorImpl<Value> &reads) {
  auto *op = value.getDefiningOp();
  if (!op || hw::getBitWidth(value.getType()) <= 0)
    return;
  // The last operand of these first: the low bits.
  if (isa<comb::ConcatOp, hw::ArrayCreateOp, hw::ArrayConcatOp,
          hw::StructCreateOp>(op)) {
    reads.append(op->operand_begin(), op->operand_end());
    std::reverse(reads.begin(), reads.end());
    return;
  }
  if (isa<comb::AndOp, comb::OrOp, comb::XorOp>(op)) {
    reads.append(op->operand_begin(), op->operand_end());
    return;
  }
  if (isa<comb::ExtractOp, comb::ReplicateOp, hw::BitcastOp,
          hw::StructExtractOp>(op))
    reads.push_back(op->getOperand(0));
}

Bits Analysis::compute(Value value) {
  auto width = std::max<int64_t>(hw::getBitWidth(value.getType()), 0);
  Bits varying(width, Bit::Varying);
  auto *op = value.getDefiningOp();
  if (!op || width == 0)
    return varying;

  // The bits of `operands`, the last one in the low bits.
  auto appendReversed = [&](ValueRange operands) {
    Bits result;
    for (auto operand : llvm::reverse(operands)) {
      auto &bits = get(operand);
      result.append(bits.begin(), bits.end());
    }
    return result;
  };
  auto slice = [&](Value input, unsigned low) {
    auto &bits = get(input);
    return Bits(bits.begin() + low, bits.begin() + low + width);
  };

  if (auto constant = dyn_cast<hw::ConstantOp>(op))
    return bitsOf(constant.getValue());
  if (auto concat = dyn_cast<comb::ConcatOp>(op))
    return appendReversed(concat.getInputs());
  if (auto extract = dyn_cast<comb::ExtractOp>(op))
    return slice(extract.getInput(), extract.getLowBit());
  if (auto replicate = dyn_cast<comb::ReplicateOp>(op)) {
    Bits result;
    auto &bits = get(replicate.getInput());
    while (result.size() < unsigned(width))
      result.append(bits.begin(), bits.end());
    return result;
  }
  if (auto bitcast = dyn_cast<hw::BitcastOp>(op))
    return get(bitcast.getInput());
  if (isa<comb::AndOp, comb::OrOp, comb::XorOp>(op)) {
    SmallVector<const Bits *> operands;
    for (auto operand : op->getOperands())
      operands.push_back(&get(operand));
    Bits result(width);
    for (unsigned i = 0; i < unsigned(width); ++i) {
      bool any0 = false, any1 = false, anyVarying = false, anyUndefined = false;
      unsigned ones = 0;
      for (auto *bits : operands) {
        auto bit = (*bits)[i];
        any0 |= bit == Bit::Zero;
        any1 |= bit == Bit::One;
        anyVarying |= bit == Bit::Varying;
        anyUndefined |= bit == Bit::Undefined;
        ones += bit == Bit::One;
      }
      if (isa<comb::AndOp>(op) && any0)
        result[i] = Bit::Zero;
      else if (isa<comb::OrOp>(op) && any1)
        result[i] = Bit::One;
      else if (anyVarying)
        result[i] = Bit::Varying;
      else if (anyUndefined)
        result[i] = Bit::Undefined;
      else if (isa<comb::XorOp>(op))
        result[i] = ones % 2 ? Bit::One : Bit::Zero;
      else
        result[i] = isa<comb::AndOp>(op) ? Bit::One : Bit::Zero;
    }
    return result;
  }
  if (auto mux = dyn_cast<comb::MuxOp>(op)) {
    auto cond = get(mux.getCond())[0];
    if (cond == Bit::One)
      return get(mux.getTrueValue());
    if (cond == Bit::Zero)
      return get(mux.getFalseValue());
    auto result = get(mux.getTrueValue());
    auto &other = get(mux.getFalseValue());
    for (unsigned i = 0; i < result.size(); ++i)
      result[i] = meet(result[i], other[i]);
    return result;
  }
  // Array element 0 is in the low bits, as the first operand of a create or a
  // concatenation is in the high ones.
  if (auto create = dyn_cast<hw::ArrayCreateOp>(op))
    return appendReversed(create.getInputs());
  if (auto concat = dyn_cast<hw::ArrayConcatOp>(op))
    return appendReversed(concat.getInputs());
  if (auto get = dyn_cast<hw::ArrayGetOp>(op)) {
    auto array = get.getInput();
    auto ew = elementWidth(array.getType());
    auto size = hw::type_cast<hw::ArrayType>(array.getType()).getNumElements();
    auto &index = this->get(get.getIndex());
    if (llvm::all_of(index, isConstant)) {
      uint64_t i = 0;
      for (unsigned b = 0; b < index.size(); ++b)
        i |= uint64_t(index[b] == Bit::One) << b;
      if (i >= size)
        return varying;
      return slice(array, i * ew);
    }
    // Any element may be read.
    auto &bits = this->get(array);
    Bits result(width, Bit::Undefined);
    for (unsigned e = 0; e < size; ++e)
      for (unsigned i = 0; i < ew; ++i)
        result[i] = meet(result[i], bits[e * ew + i]);
    if (llvm::any_of(index, [](Bit b) { return b == Bit::Varying; }))
      for (auto &bit : result)
        if (bit == Bit::Undefined)
          bit = Bit::Varying;
    return result;
  }
  APInt index;
  if (auto arraySlice = dyn_cast<hw::ArraySliceOp>(op);
      arraySlice &&
      matchPattern(arraySlice.getLowIndex(), m_ConstantInt(&index))) {
    auto input = arraySlice.getInput();
    auto size = hw::type_cast<hw::ArrayType>(input.getType()).getNumElements();
    auto length =
        hw::type_cast<hw::ArrayType>(arraySlice.getType()).getNumElements();
    // A slice past the end of the array reads undefined elements.
    if (index.getZExtValue() > size - length)
      return varying;
    return slice(input, index.getZExtValue() * elementWidth(input.getType()));
  }
  // A struct's first field is in the high bits.
  if (auto create = dyn_cast<hw::StructCreateOp>(op))
    return appendReversed(create.getInput());
  if (auto extract = dyn_cast<hw::StructExtractOp>(op)) {
    auto type = hw::type_cast<hw::StructType>(extract.getInput().getType());
    unsigned low = 0;
    auto elements = type.getElements();
    for (unsigned i = extract.getFieldIndex() + 1; i < elements.size(); ++i)
      low += hw::getBitWidth(elements[i].type);
    return slice(extract.getInput(), low);
  }
  if (op->getNumRegions() == 0 && mlir::isPure(op) &&
      isa<IntegerType>(value.getType()))
    return fold(op, cast<OpResult>(value).getResultNumber(), width);
  return varying;
}

/// The bits of a pure op's result from its operands', once they are all
/// constants; undefined while any is.
Bits Analysis::fold(Operation *op, unsigned resultNumber, unsigned width) {
  Bits varying(width, Bit::Varying);
  SmallVector<Attribute> operands;
  bool undefined = false;
  for (auto operand : op->getOperands()) {
    auto type = dyn_cast<IntegerType>(operand.getType());
    if (!type)
      return varying;
    auto &bits = get(operand);
    if (llvm::any_of(bits, [](Bit b) { return b == Bit::Varying; }))
      return varying;
    if (llvm::any_of(bits, [](Bit b) { return b == Bit::Undefined; })) {
      undefined = true;
      continue;
    }
    APInt value(bits.size(), 0);
    for (unsigned i = 0; i < bits.size(); ++i)
      value.setBitVal(i, bits[i] == Bit::One);
    operands.push_back(IntegerAttr::get(type, value));
  }
  if (undefined)
    return Bits(width, Bit::Undefined);
  SmallVector<OpFoldResult> results;
  if (failed(op->fold(operands, results)) || results.empty())
    return varying;
  auto result = results[resultNumber];
  if (auto attr = dyn_cast_or_null<IntegerAttr>(dyn_cast<Attribute>(result)))
    return bitsOf(attr.getValue());
  if (auto folded = dyn_cast<Value>(result))
    return get(folded);
  return varying;
}

void RegConstPropPass::runOnOperation() {
  auto module = getOperation();
  Analysis analysis(module);
  if (analysis.registers.empty())
    return markAllAnalysesPreserved();
  analysis.solve(/*defined=*/false);
  analysis.solve(/*defined=*/true);

  for (auto reg : analysis.registers) {
    auto &bits = analysis.state[reg];
    if (llvm::none_of(bits, isConstant))
      continue;
    ImplicitLocOpBuilder b(reg.getLoc(), reg);
    unsigned width = bits.size();
    auto intType = b.getIntegerType(width);
    auto toInteger = [&](Value value) -> Value {
      return value.getType() == intType
                 ? value
                 : b.createOrFold<hw::BitcastOp>(intType, value);
    };

    // The varying bits stay in a narrower register.
    SmallVector<std::pair<unsigned, unsigned>> runs;
    for (unsigned lo = 0; lo < width;) {
      unsigned hi = lo;
      while (hi + 1 < width && isConstant(bits[hi + 1]) == isConstant(bits[lo]))
        ++hi;
      runs.push_back({lo, hi});
      lo = hi + 1;
    }
    auto keep = [&](Value value) -> Value {
      SmallVector<Value> parts;
      for (auto [lo, hi] : llvm::reverse(runs))
        if (!isConstant(bits[lo]))
          parts.push_back(
              b.createOrFold<comb::ExtractOp>(value, lo, hi - lo + 1));
      return b.createOrFold<comb::ConcatOp>(parts);
    };
    Value narrow;
    if (llvm::any_of(bits, [](Bit bit) { return !isConstant(bit); })) {
      Attribute preset;
      if (auto attr = reg.getPresetAttr()) {
        std::optional<APInt> value;
        for (auto [lo, hi] : llvm::reverse(runs)) {
          if (isConstant(bits[lo]))
            continue;
          auto part = attr.getValue().extractBits(hi - lo + 1, lo);
          value = value ? value->concat(part) : part;
        }
        preset =
            b.getIntegerAttr(b.getIntegerType(value->getBitWidth()), *value);
      }
      auto next = keep(toInteger(reg.getNext()));
      FirRegOp narrowReg;
      if (reg.hasReset())
        narrowReg = FirRegOp::create(
            b, next, reg.getClk(), reg.getNameAttr(), reg.getReset(),
            keep(toInteger(reg.getResetValue())), hw::InnerSymAttr{},
            reg.getIsAsync(), preset);
      else
        narrowReg = FirRegOp::create(b, next, reg.getClk(), reg.getNameAttr(),
                                     hw::InnerSymAttr{}, preset);
      // Keep the synthesis attributes the register was declared with.
      narrowReg->setDialectAttrs(reg->getDialectAttrs());
      narrow = narrowReg;
    }

    // The register's value, its constant bits put back.
    SmallVector<Value> parts;
    unsigned offset = hw::getBitWidth(narrow ? narrow.getType() : intType);
    for (auto [lo, hi] : llvm::reverse(runs)) {
      unsigned count = hi - lo + 1;
      if (isConstant(bits[lo])) {
        APInt value(count, 0);
        for (unsigned i = lo; i <= hi; ++i)
          value.setBitVal(i - lo, bits[i] == Bit::One);
        parts.push_back(hw::ConstantOp::create(b, value));
      } else {
        offset -= count;
        parts.push_back(b.createOrFold<comb::ExtractOp>(narrow, offset, count));
      }
    }
    Value value = b.createOrFold<comb::ConcatOp>(parts);
    if (value.getType() != reg.getType())
      value = b.createOrFold<hw::BitcastOp>(reg.getType(), value);
    reg.getResult().replaceAllUsesWith(value);
    reg.erase();
  }
}
