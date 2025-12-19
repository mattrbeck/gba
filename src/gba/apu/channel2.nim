import ../scheduler, ../types

const
  waveDuty: array[4, array[8, int16]] = [
    [-8'i16, -8'i16, -8'i16, -8'i16, -8'i16, -8'i16, -8'i16, +8'i16], # 12.5%
    [+8'i16, -8'i16, -8'i16, -8'i16, -8'i16, -8'i16, -8'i16, +8'i16], # 25%
    [+8'i16, -8'i16, -8'i16, -8'i16, -8'i16, +8'i16, +8'i16, +8'i16], # 50%
    [-8'i16, +8'i16, +8'i16, +8'i16, +8'i16, +8'i16, +8'i16, -8'i16], # 75%
  ]

type
  Channel2* = ref object of RootObj
    scheduler*: Scheduler
    # Wave duty (NR21)
    duty*: int
    lengthLoad*: int
    waveDutyPosition*: int
    # Volume envelope (NR22)
    initialVolume*: int
    envelopeIncrease*: bool
    envelopePeriod*: int
    envelopeTimer*: int
    currentVolume*: int
    # Frequency (NR23/NR24)
    frequency*: uint32
    lengthEnable*: bool
    # State
    enabled*: bool
    dacEnabled*: bool
    lengthCounter*: int

proc newChannel2*(scheduler: Scheduler): Channel2 =
  new result
  result.scheduler = scheduler
  result.duty = 0
  result.waveDutyPosition = 0
  result.frequency = 0
  result.currentVolume = 0
  result.enabled = false
  result.dacEnabled = false

proc frequencyTimer*(channel: Channel2): uint32 =
  (0x800'u32 - channel.frequency) * 16

proc scheduleReload(channel: Channel2)

proc stepWaveGeneration(channel: Channel2): proc() =
  proc callback() =
    channel.waveDutyPosition = (channel.waveDutyPosition + 1) and 7
    channel.scheduleReload()
  callback

proc scheduleReload(channel: Channel2) =
  if channel.enabled:
    channel.scheduler.schedule(channel.frequencyTimer(), channel.stepWaveGeneration(), apuChannel2)

proc lengthStep*(channel: Channel2) =
  if channel.lengthEnable and channel.lengthCounter > 0:
    channel.lengthCounter -= 1
    if channel.lengthCounter == 0:
      channel.enabled = false

proc envelopeStep*(channel: Channel2) =
  channel.envelopeTimer -= 1
  if channel.envelopeTimer <= 0:
    channel.envelopeTimer = if channel.envelopePeriod > 0: channel.envelopePeriod else: 8

    if channel.envelopePeriod > 0:
      if channel.envelopeIncrease and channel.currentVolume < 15:
        channel.currentVolume += 1
      elif not channel.envelopeIncrease and channel.currentVolume > 0:
        channel.currentVolume -= 1

proc getAmplitude*(channel: Channel2): float32 =
  if channel.enabled and channel.dacEnabled:
    float32(waveDuty[channel.duty][channel.waveDutyPosition] * channel.currentVolume) / 120.0
  else:
    0.0

proc trigger*(channel: Channel2) =
  if not channel.dacEnabled:
    return

  channel.enabled = true

  # Reload length counter
  if channel.lengthCounter == 0:
    channel.lengthCounter = 64

  # Reload frequency timer
  channel.scheduler.clear(apuChannel2)
  channel.scheduleReload()

  # Reload envelope
  channel.envelopeTimer = if channel.envelopePeriod > 0: channel.envelopePeriod else: 8
  channel.currentVolume = channel.initialVolume

# Register writes
proc writeNR21*(channel: Channel2, value: uint8) =
  channel.duty = int(value shr 6)
  channel.lengthLoad = int(value and 0x3F)
  channel.lengthCounter = 64 - channel.lengthLoad

proc writeNR22*(channel: Channel2, value: uint8) =
  channel.initialVolume = int(value shr 4)
  channel.envelopeIncrease = (value and 0x08) != 0
  channel.envelopePeriod = int(value and 0x07)
  channel.dacEnabled = (value and 0xF8) != 0
  if not channel.dacEnabled:
    channel.enabled = false

proc writeNR23*(channel: Channel2, value: uint8) =
  channel.frequency = (channel.frequency and 0x700) or value.uint32

proc writeNR24*(channel: Channel2, value: uint8) =
  channel.frequency = (channel.frequency and 0xFF) or ((value.uint32 and 0x07) shl 8)
  channel.lengthEnable = (value and 0x40) != 0

  # Trigger
  if (value and 0x80) != 0:
    channel.trigger()

# Register reads
proc readNR21*(channel: Channel2): uint8 =
  0x3F'u8 or (channel.duty.uint8 shl 6)

proc readNR22*(channel: Channel2): uint8 =
  (channel.initialVolume.uint8 shl 4) or
  (if channel.envelopeIncrease: 0x08 else: 0x00) or
  channel.envelopePeriod.uint8

proc readNR23*(channel: Channel2): uint8 =
  0xFF'u8  # Write-only

proc readNR24*(channel: Channel2): uint8 =
  0xBF'u8 or (if channel.lengthEnable: 0x40 else: 0x00)
