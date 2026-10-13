add_circt_dialect_library(CIRCTSeqTransforms
  ExternalizeClockGate.cpp
  HWMemSimImpl.cpp
  RegOfVecToMem.cpp
  RegConstProp.cpp
  LowerAggregateRegs.cpp
  RetimeFirMemReads.cpp
  LowerSeqCompRegCE.cpp
  LowerSeqHLMem.cpp
  LowerSeqFIFO.cpp
  LowerSeqShiftReg.cpp
  InferClockPorts.cpp

  DEPENDS
  CIRCTSeqTransformsIncGen

  LINK_LIBS PUBLIC
  CIRCTComb
  CIRCTEmit
  CIRCTHW
  CIRCTHWTransforms
  CIRCTSeq
  CIRCTSupport
  CIRCTSV
  CIRCTVerif
  MLIRIR
  MLIRPass
  MLIRTransformUtils
)
