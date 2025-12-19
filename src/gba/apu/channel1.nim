import ../scheduler, ../types

const
  waveDuty: array[4, array[8, int16]] = [
    [-8'i16, -8'i16, -8'i16, -8'i16, -8'i16, -8'i16, -8'i16, +8'i16], # 12.5%
    [+8'i16, -8'i16, -8'i16, -8'i16, -8'i16, -8'i16, -8'i16, +8'i16], # 25%
    [+8'i16, -8'i16, -8'i16, -8'i16, -8'i16, +8'i16, +8'i16, +8'i16], # 50%
    [-8'i16, +8'i16, +8'i16, +8'i16, +8'i16, +8'i16, +8'i16, -8'i16], # 75%
  ]

type
  Channel1* = ref object of RootObj
    scheduler*: Scheduler
    # Sweep (NR10)
    sweepPeriod*: int
    sweepNegate*: bool
    sweepShift*: int
    sweepTimer*: int
    sweepEnabled*: bool
    frequencyShadow*: uint32
    negateUsed*: bool
    # Wave duty (NR11)
    duty*: int
    lengthLoad*: int
    waveDutyPosition*: int
    # Volume envelope (NR12)
    initialVolume*: int
    envelopeIncrease*: bool
    envelopePeriod*: int
    envelopeTimer*: int
    currentVolume*: int
    # Frequency (NR13/NR14)
    frequency*: uint32
    lengthEnable*: bool
    # State
    enabled*: bool
    dacEnabled*: bool
    lengthCounter*: int

proc newChannel1*(scheduler: Scheduler): Channel1 =
  new result
  result.scheduler = scheduler
  result.duty = 0
  result.waveDutyPosition = 0
  result.frequency = 0
  result.currentVolume = 0
  result.enabled = false
  result.dacEnabled = false

proc frequencyTimer*(channel: Channel1): uint32 =
  (0x800'u32 - channel.frequency) * 16

proc scheduleReload(channel: Channel1)

proc stepWaveGeneration(channel: Channel1): proc() =
  proc callback() =
    channel.waveDutyPosition = (channel.waveDutyPosition + 1) and 7
    channel.scheduleReload()
  callback

proc scheduleReload(channel: Channel1) =
  if channel.enabled:
    channel.scheduler.schedule(channel.frequencyTimer(), channel.stepWaveGeneration(), apuChannel1)

proc calculateFrequency(channel: Channel1): uint32 =
  let shifted = channel.frequencyShadow shr channel.sweepShift
  if channel.sweepNegate:
    channel.negateUsed = true
    channel.frequencyShadow - shifted
  else:
    channel.frequencyShadow + shifted

proc sweepStep*(channel: Channel1) =
  # Decrement timer
  channel.sweepTimer -= 1
  if channel.sweepTimer <= 0:
    # Reload timer
    channel.sweepTimer = if channel.sweepPeriod > 0: channel.sweepPeriod else: 8

    # Perform frequency calculation if enabled
    if channel.sweepEnabled and channel.sweepPeriod > 0:
      let newFreq = channel.calculateFrequency()

      # Check overflow
      if newFreq > 0x7FF:
        channel.enabled = false
      else:
        # Update frequencies
        channel.frequencyShadow = newFreq
        channel.frequency = newFreq

        # Do overflow check again
        discard channel.calculateFrequency()
        if channel.calculateFrequency() > 0x7FF:
          channel.enabled = false

proc lengthStep*(channel: Channel1) =
  if channel.lengthEnable and channel.lengthCounter > 0:
    channel.lengthCounter -= 1
    if channel.lengthCounter == 0:
      channel.enabled = false

proc envelopeStep*(channel: Channel1) =
  channel.envelopeTimer -= 1
  if channel.envelopeTimer <= 0:
    channel.envelopeTimer = if channel.envelopePeriod > 0: channel.envelopePeriod else: 8

    if channel.envelopePeriod > 0:
      if channel.envelopeIncrease and channel.currentVolume < 15:
        channel.currentVolume += 1
      elif not channel.envelopeIncrease and channel.currentVolume > 0:
        channel.currentVolume -= 1

proc getAmplitude*(channel: Channel1): float32 =
  if channel.enabled and channel.dacEnabled:
    float32(waveDuty[channel.duty][channel.waveDutyPosition] * channel.currentVolume) / 120.0
  else:
    0.0

proc trigger*(channel: Channel1) =
  if not channel.dacEnabled:
    return

  channel.enabled = true

  # Reload length counter
  if channel.lengthCounter == 0:
    channel.lengthCounter = 64

  # Reload frequency timer
  channel.scheduler.clear(apuChannel1)
  channel.scheduleReload()

  # Reload envelope
  channel.envelopeTimer = if channel.envelopePeriod > 0: channel.envelopePeriod else: 8
  channel.currentVolume = channel.initialVolume

  # Reset sweep
  channel.frequencyShadow = channel.frequency
  channel.sweepTimer = if channel.sweepPeriod > 0: channel.sweepPeriod else: 8
  channel.sweepEnabled = channel.sweepPeriod > 0 or channel.sweepShift > 0
  channel.negateUsed = false

  # Perform initial frequency calculation
  if channel.sweepShift > 0:
    let newFreq = channel.calculateFrequency()
    if newFreq > 0x7FF:
      channel.enabled = false

# Register writes
proc writeNR10*(channel: Channel1, value: uint8) =
  channel.sweepPeriod = int((value shr 4) and 0x07)
  channel.sweepNegate = (value and 0x08) != 0
  channel.sweepShift = int(value and 0x07)

  # If negate was used and we switch to addition, disable channel
  if channel.negateUsed and not channel.sweepNegate:
    channel.enabled = false

proc writeNR11*(channel: Channel1, value: uint8) =
  channel.duty = int(value shr 6)
  channel.lengthLoad = int(value and 0x3F)
  channel.lengthCounter = 64 - channel.lengthLoad

proc writeNR12*(channel: Channel1, value: uint8) =
  channel.initialVolume = int(value shr 4)
  channel.envelopeIncrease = (value and 0x08) != 0
  channel.envelopePeriod = int(value and 0x07)
  channel.dacEnabled = (value and 0xF8) != 0
  if not channel.dacEnabled:
    channel.enabled = false

proc writeNR13*(channel: Channel1, value: uint8) =
  channel.frequency = (channel.frequency and 0x700) or value.uint32

proc writeNR14*(channel: Channel1, value: uint8) =
  channel.frequency = (channel.frequency and 0xFF) or ((value.uint32 and 0x07) shl 8)
  channel.lengthEnable = (value and 0x40) != 0

  # Trigger
  if (value and 0x80) != 0:
    channel.trigger()

# Register reads
proc readNR10*(channel: Channel1): uint8 =
  0x80'u8 or
  (channel.sweepPeriod.uint8 shl 4) or
  (if channel.sweepNegate: 0x08 else: 0x00) or
  channel.sweepShift.uint8

proc readNR11*(channel: Channel1): uint8 =
  0x3F'u8 or (channel.duty.uint8 shl 6)

proc readNR12*(channel: Channel1): uint8 =
  (channel.initialVolume.uint8 shl 4) or
  (if channel.envelopeIncrease: 0x08 else: 0x00) or
  channel.envelopePeriod.uint8

proc readNR13*(channel: Channel1): uint8 =
  0xFF'u8  # Write-only

proc readNR14*(channel: Channel1): uint8 =
  0xBF'u8 or (if channel.lengthEnable: 0x40 else: 0x00)
