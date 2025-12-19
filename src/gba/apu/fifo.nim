type
  FIFOChannel* = ref object of RootObj
    fifo*: array[32, int8]  # FIFO buffer
    readPos*: int
    writePos*: int
    size*: int
    sample*: int8  # Current sample being output
    volume*: int  # 0 = 50%, 1 = 100%
    timerSelect*: int  # 0 or 1 (which timer triggers this channel)
    enabled*: bool

proc newFIFOChannel*(): FIFOChannel =
  new result
  result.readPos = 0
  result.writePos = 0
  result.size = 0
  result.sample = 0
  result.volume = 0
  result.timerSelect = 0
  result.enabled = false

proc push*(fifo: FIFOChannel, value: int8) =
  if fifo.size < 32:
    fifo.fifo[fifo.writePos] = value
    fifo.writePos = (fifo.writePos + 1) and 31
    fifo.size += 1

proc pop*(fifo: FIFOChannel): int8 =
  if fifo.size > 0:
    result = fifo.fifo[fifo.readPos]
    fifo.readPos = (fifo.readPos + 1) and 31
    fifo.size -= 1
  else:
    result = 0

proc reset*(fifo: FIFOChannel) =
  fifo.readPos = 0
  fifo.writePos = 0
  fifo.size = 0
  fifo.sample = 0

proc timerOverflow*(fifo: FIFOChannel) =
  # Called when the selected timer overflows
  # Pop a sample from FIFO and output it
  if fifo.size > 0:
    fifo.sample = fifo.pop()

proc needsRefill*(fifo: FIFOChannel): bool =
  # Request DMA refill when FIFO has 16 or fewer bytes
  fifo.size <= 16

proc getAmplitude*(fifo: FIFOChannel): float32 =
  if not fifo.enabled:
    return 0.0

  # Volume is either 50% or 100%
  let volumeMultiplier = if fifo.volume == 0: 0.5 else: 1.0
  float32(fifo.sample) / 128.0 * volumeMultiplier

proc write32*(fifo: FIFOChannel, value: uint32) =
  # Write 4 bytes to FIFO (called by DMA)
  fifo.push(int8(value and 0xFF))
  fifo.push(int8((value shr 8) and 0xFF))
  fifo.push(int8((value shr 16) and 0xFF))
  fifo.push(int8((value shr 24) and 0xFF))
