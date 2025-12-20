import types, dma, bus, interrupts, regs, apu
import apu/fifo

# DMA Controller - handles actual memory transfers
# This module can safely import both bus and dma, breaking the circular dependency

const
  transferBytes: array[DmaChunkSize, uint32] = [2'u32, 4]
  addressAdjustments: array[DmaAddressControl, uint32] = [1'u32, 0xFFFFFFFF'u32, 0, 1]

proc performDMATransfer*(gba: GBA, channel: int) =
  let (src, dst, len, ctrl) = getDMAConfig(channel)

  if ctrl.srcCtrl == DmaAddressControl.reload:
    echo "Prohibited source address control"
    return

  let
    transferSize = transferBytes[ctrl.transfer]
    srcDelta = transferSize * addressAdjustments[ctrl.srcCtrl]
    dstDelta = transferSize * addressAdjustments[ctrl.dstCtrl]

  var currentSrc = src
  var currentDst = dst

  # Perform the transfer
  for idx in 0 ..< int(len):
    if ctrl.transfer == DmaChunkSize.halfword:
      gba.bus[currentDst] = bus.read[uint16](gba.bus, currentSrc)
    else:
      gba.bus[currentDst] = bus.read[uint32](gba.bus, currentSrc)
    currentSrc += srcDelta
    currentDst += dstDelta

  # Update internal pointers
  updateDMAPointers(channel, currentSrc, currentDst)

  # Finalize transfer (handle reload, disable if needed)
  finalizeDMA(channel)

  # Trigger interrupt if enabled
  if ctrl.irq:
    case channel:
    of 0: gba.interrupts.regIf.dma0 = true
    of 1: gba.interrupts.regIf.dma1 = true
    of 2: gba.interrupts.regIf.dma2 = true
    of 3: gba.interrupts.regIf.dma3 = true
    else: quit "Bad dma channel. Impossible case."
    gba.interrupts.scheduleCheck()

# FIFO refill - transfer 4 words (16 bytes) from DMA source to FIFO
proc performFifoRefill*(gba: GBA, fifoAddress: uint32) =
  for channel in 1..2:  # Only DMA1 and DMA2 can do sound DMA
    if isFifoRefillDMA(channel, fifoAddress):
      let (src, dst, len, ctrl) = getDMAConfig(channel)
      var currentSrc = src

      # Transfer 4 words to refill FIFO
      for i in 0 ..< 4:
        let value = bus.read[uint32](gba.bus, currentSrc)
        gba.bus[dst] = value
        currentSrc += 4

      # Update source pointer
      updateDMAPointers(channel, currentSrc, dst)
      return

# Check and perform FIFO refills for a given timer
proc checkAndPerformFifoRefills(gba: GBA, timerNum: int) {.nimcall.} =
  # Check if FIFO A needs refill and uses this timer
  if FIFOChannel(gba.apu.fifoA).timerSelect == timerNum and FIFOChannel(gba.apu.fifoA).needsRefill():
    performFifoRefill(gba, 0x040000A0)

  # Check if FIFO B needs refill and uses this timer
  if FIFOChannel(gba.apu.fifoB).timerSelect == timerNum and FIFOChannel(gba.apu.fifoB).needsRefill():
    performFifoRefill(gba, 0x040000A4)

# Initialize the DMA controller
proc initDMAController*() =
  # Set the immediate DMA trigger callback
  immediateDMATrigger = proc(gba: GBA, channel: int) {.nimcall.} =
    performDMATransfer(gba, channel)

  # Set the FIFO refill callback
  fifoRefillCallback = checkAndPerformFifoRefills
