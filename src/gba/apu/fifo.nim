type
  FIFOChannel* = ref object of RootObj
    fifo*: array[32, int8]  # FIFO buffer
    readPos*: int
    writePos*: int
    size*: int
    latch*: int16  # Current sample being output (scaled to -256..256)
    volume*: int  # 0 = 50%, 1 = 100% (used as shift amount)
    timerSelect*: int  # 0 or 1 (which timer triggers this channel)
    enableRight*: bool  # Route to right speaker
    enableLeft*: bool   # Route to left speaker

proc newFIFOChannel*(): FIFOChannel =
  new result
  result.readPos = 0
  result.writePos = 0
  result.size = 0
  result.latch = 0
  result.volume = 0
  result.timerSelect = 0
  result.enableRight = false
  result.enableLeft = false

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
  fifo.latch = 0

proc timerOverflow*(fifo: FIFOChannel) =
  # Called when the selected timer overflows
  # Pop a sample from FIFO and output it (scaled by 2)
  if fifo.size > 0:
    fifo.latch = fifo.pop().int16 shl 1  # Scale from -128..127 to -256..254
  else:
    fifo.latch = 0

proc needsRefill*(fifo: FIFOChannel): bool =
  # Request DMA refill when FIFO has 16 or fewer bytes
  fifo.size <= 16

proc getAmplitude*(fifo: FIFOChannel): int16 =
  # Returns latch value in range -256..256 (before volume shift)
  return fifo.latch

proc write32*(fifo: FIFOChannel, value: uint32) =
  # Write 4 bytes to FIFO (called by DMA)
  # Use cast to reinterpret unsigned bytes as signed int8
  fifo.push(cast[int8](uint8(value and 0xFF)))
  fifo.push(cast[int8](uint8((value shr 8) and 0xFF)))
  fifo.push(cast[int8](uint8((value shr 16) and 0xFF)))
  fifo.push(cast[int8](uint8((value shr 24) and 0xFF)))
