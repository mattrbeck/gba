import ../scheduler, ../types

type
  Channel4* = ref object of RootObj
    scheduler*: Scheduler
    # Noise LFSR
    lfsr*: uint16
    # Length (NR41)
    lengthLoad*: int
    lengthCounter*: int
    lengthEnable*: bool
    # Volume envelope (NR42)
    initialVolume*: int
    envelopeIncrease*: bool
    envelopePeriod*: int
    envelopeTimer*: int
    currentVolume*: int
    # Noise control (NR43)
    clockShift*: int
    widthMode*: bool  # 0 = 15-bit, 1 = 7-bit
    divisorCode*: int
    # State
    enabled*: bool
    dacEnabled*: bool

proc newChannel4*(scheduler: Scheduler): Channel4 =
  new result
  result.scheduler = scheduler
  result.lfsr = 0x7FFF
  result.currentVolume = 0
  result.enabled = false
  result.dacEnabled = false

proc getDivisor(divisorCode: int): int =
  if divisorCode == 0: 8
  else: divisorCode * 16

proc frequencyTimer*(channel: Channel4): uint32 =
  let divisor = getDivisor(channel.divisorCode)
  uint32(divisor shl channel.clockShift)

proc scheduleReload(channel: Channel4)

proc stepNoise(channel: Channel4): proc() =
  proc callback() =
    # LFSR noise generation
    let bit0 = channel.lfsr and 1
    let bit1 = (channel.lfsr shr 1) and 1
    let newBit = bit0 xor bit1

    # Shift right
    channel.lfsr = channel.lfsr shr 1

    # Place new bit at position 14
    channel.lfsr = channel.lfsr or (newBit shl 14)

    # If width mode, also place at position 6 (7-bit LFSR)
    if channel.widthMode:
      channel.lfsr = (channel.lfsr and 0xFF7F'u16) or (newBit shl 6)

    channel.scheduleReload()
  callback

proc scheduleReload(channel: Channel4) =
  if channel.enabled:
    channel.scheduler.schedule(channel.frequencyTimer(), channel.stepNoise(), apuChannel4)

proc lengthStep*(channel: Channel4) =
  if channel.lengthEnable and channel.lengthCounter > 0:
    channel.lengthCounter -= 1
    if channel.lengthCounter == 0:
      channel.enabled = false

proc envelopeStep*(channel: Channel4) =
  channel.envelopeTimer -= 1
  if channel.envelopeTimer <= 0:
    channel.envelopeTimer = if channel.envelopePeriod > 0: channel.envelopePeriod else: 8

    if channel.envelopePeriod > 0:
      if channel.envelopeIncrease and channel.currentVolume < 15:
        channel.currentVolume += 1
      elif not channel.envelopeIncrease and channel.currentVolume > 0:
        channel.currentVolume -= 1

proc getAmplitude*(channel: Channel4): float32 =
  if not channel.enabled or not channel.dacEnabled:
    return 0.0

  # Output is inverted bit 0 of LFSR, scaled by volume
  let output = if (channel.lfsr and 1) == 0: 8 else: -8
  float32(output * channel.currentVolume) / 120.0

proc trigger*(channel: Channel4) =
  if not channel.dacEnabled:
    return

  channel.enabled = true

  # Reload length counter
  if channel.lengthCounter == 0:
    channel.lengthCounter = 64

  # Initialize LFSR
  channel.lfsr = 0x7FFF

  # Reload frequency timer
  channel.scheduler.clear(apuChannel4)
  channel.scheduleReload()

  # Reload envelope
  channel.envelopeTimer = if channel.envelopePeriod > 0: channel.envelopePeriod else: 8
  channel.currentVolume = channel.initialVolume

# Register writes
proc writeNR41*(channel: Channel4, value: uint8) =
  channel.lengthLoad = int(value and 0x3F)
  channel.lengthCounter = 64 - channel.lengthLoad

proc writeNR42*(channel: Channel4, value: uint8) =
  channel.initialVolume = int(value shr 4)
  channel.envelopeIncrease = (value and 0x08) != 0
  channel.envelopePeriod = int(value and 0x07)
  channel.dacEnabled = (value and 0xF8) != 0
  if not channel.dacEnabled:
    channel.enabled = false

proc writeNR43*(channel: Channel4, value: uint8) =
  channel.clockShift = int(value shr 4)
  channel.widthMode = (value and 0x08) != 0
  channel.divisorCode = int(value and 0x07)

proc writeNR44*(channel: Channel4, value: uint8) =
  channel.lengthEnable = (value and 0x40) != 0

  # Trigger
  if (value and 0x80) != 0:
    channel.trigger()

# Register reads
proc readNR41*(channel: Channel4): uint8 =
  0xFF'u8  # Write-only

proc readNR42*(channel: Channel4): uint8 =
  (channel.initialVolume.uint8 shl 4) or
  (if channel.envelopeIncrease: 0x08 else: 0x00) or
  channel.envelopePeriod.uint8

proc readNR43*(channel: Channel4): uint8 =
  (channel.clockShift.uint8 shl 4) or
  (if channel.widthMode: 0x08 else: 0x00) or
  channel.divisorCode.uint8

proc readNR44*(channel: Channel4): uint8 =
  0xBF'u8 or (if channel.lengthEnable: 0x40 else: 0x00)
