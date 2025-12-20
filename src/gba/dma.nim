import types, regs

# DMA register state (no bus dependencies to avoid circular imports)
# Actual transfers are handled by dma_controller.nim

type
  DMAState* = object
    sad*: uint32        # Source address
    dad*: uint32        # Destination address
    cnt_l*: uint16      # Word count
    cnt_h*: DMACNT      # Control register
    src*: uint32        # Internal source pointer
    dst*: uint32        # Internal destination pointer

var
  dmaState*: array[4, DMAState]

proc newDMA*(gba: GBA): DMA =
  new result
  result.gba = gba

# Check if a DMA channel is configured for FIFO refill
proc isFifoRefillDMA*(channel: int, fifoAddress: uint32): bool =
  let state = dmaState[channel]
  result = state.cnt_h.enable and
           state.cnt_h.timing == special and
           state.dad == fifoAddress

# Get DMA configuration for transfer
proc getDMAConfig*(channel: int): tuple[src, dst: uint32, len: uint16, ctrl: DMACNT] =
  let state = dmaState[channel]
  (state.src, state.dst, state.cnt_l, state.cnt_h)

# Update DMA internal pointers after transfer
proc updateDMAPointers*(channel: int, newSrc, newDst: uint32) =
  dmaState[channel].src = newSrc
  dmaState[channel].dst = newDst

# Disable DMA channel after transfer (if not repeating)
proc finalizeDMA*(channel: int) =
  let state = addr dmaState[channel]
  if state.cnt_h.dstCtrl == DmaAddressControl.reload:
    state.dst = state.dad
  if not state.cnt_h.repeat or state.cnt_h.timing == DmaStartTiming.immediate:
    state.cnt_h.enable = false

# Trigger callback for immediate DMA (set by dma_controller)
var immediateDMATrigger*: proc(gba: GBA, channel: int) {.nimcall.}

proc `[]`*(dma: DMA, address: SomeInteger): uint8 =
  let
    dmaAddr = address - 0xB0
    channel = dmaAddr div 12
    reg = dmaAddr mod 12
  case reg:
  of 0..3: read(dmaState[channel].sad, address and 3)
  of 4..7: read(dmaState[channel].dad, address and 3)
  of 8..9: read(dmaState[channel].cnt_l, address and 1)
  of 10..11: read(dmaState[channel].cnt_h, address and 1)
  else: 0

proc `[]=`*(dma: DMA, address: SomeInteger, value: uint8) =
  let
    dmaAddr = address - 0xB0
    channel = dmaAddr div 12
    reg = dmaAddr mod 12
  case reg:
  of 0..3: write(dmaState[channel].sad, value, address and 3)
  of 4..7: write(dmaState[channel].dad, value, address and 3)
  of 8..9: write(dmaState[channel].cnt_l, value, address and 1)
  of 10..11:
    let wasEnabled = dmaState[channel].cnt_h.enable
    write(dmaState[channel].cnt_h, value, address and 1)
    if dmaState[channel].cnt_h.enable and not wasEnabled:
      # DMA enabled - initialize internal pointers
      dmaState[channel].src = dmaState[channel].sad
      dmaState[channel].dst = dmaState[channel].dad
      # Trigger immediate DMA if configured
      if dmaState[channel].cnt_h.timing == immediate and immediateDMATrigger != nil:
        immediateDMATrigger(dma.gba, int(channel))
  else: discard
