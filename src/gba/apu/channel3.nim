import ../scheduler, ../types

type
  Channel3* = ref object of RootObj
    scheduler*: Scheduler
    # Wave RAM (2 banks of 16 bytes each)
    waveRam*: array[2, array[16, uint8]]
    waveRamBank*: int  # 0 or 1
    waveRamDimension*: int  # 0 = single bank 32 samples, 1 = dual bank 64 samples
    waveRamPosition*: int  # 0-31 or 0-63
    waveRamSampleBuffer*: uint8
    # Volume (NR32)
    volumeCode*: int  # 0-3
    volumeForce*: bool
    # Length (NR31)
    lengthLoad*: int
    lengthCounter*: int
    lengthEnable*: bool
    # Frequency (NR33/NR34)
    frequency*: uint32
    # State
    enabled*: bool
    dacEnabled*: bool

proc newChannel3*(scheduler: Scheduler): Channel3 =
  new result
  result.scheduler = scheduler
  result.waveRamPosition = 0
  result.volumeCode = 0
  result.frequency = 0
  result.enabled = false
  result.dacEnabled = false
  # Initialize wave RAM with alternating pattern
  for bank in 0..1:
    for i in 0..<16:
      result.waveRam[bank][i] = if (i and 1) == 0: 0x00 else: 0xFF

proc frequencyTimer*(channel: Channel3): uint32 =
  (0x800'u32 - channel.frequency) * 8  # Different from channels 1/2

proc scheduleReload(channel: Channel3)

proc stepWaveGeneration(channel: Channel3): proc() =
  proc callback() =
    # Increment position cyclically
    let maxPos = if channel.waveRamDimension == 0: 31 else: 63
    channel.waveRamPosition = (channel.waveRamPosition + 1) and maxPos

    # Determine which bank and byte to read from
    let bank = if channel.waveRamDimension == 0: channel.waveRamBank else: (channel.waveRamPosition div 32)
    let byteIdx = (channel.waveRamPosition and 31) div 2
    let nibbleIdx = (channel.waveRamPosition and 31) and 1

    # Extract 4-bit sample
    let byte = channel.waveRam[bank][byteIdx]
    channel.waveRamSampleBuffer = if nibbleIdx == 0: (byte shr 4) else: (byte and 0x0F)

    channel.scheduleReload()
  callback

proc scheduleReload(channel: Channel3) =
  if channel.enabled:
    channel.scheduler.schedule(channel.frequencyTimer(), channel.stepWaveGeneration(), apuChannel3)

proc lengthStep*(channel: Channel3) =
  if channel.lengthEnable and channel.lengthCounter > 0:
    channel.lengthCounter -= 1
    if channel.lengthCounter == 0:
      channel.enabled = false

proc getAmplitude*(channel: Channel3): float32 =
  if not channel.enabled or not channel.dacEnabled:
    return 0.0

  # Get volume multiplier
  let multiplier = if channel.volumeForce:
    3  # 75%
  else:
    case channel.volumeCode
    of 0: 0  # Mute
    of 1: 4  # 100%
    of 2: 2  # 50%
    of 3: 1  # 25%
    else: 0

  # Convert 4-bit sample (0-15) to signed (-8 to 7) and apply volume
  let sample = channel.waveRamSampleBuffer.int - 8
  float32(sample * 4 * multiplier) / 120.0

proc trigger*(channel: Channel3) =
  if not channel.dacEnabled:
    return

  channel.enabled = true

  # Reload length counter
  if channel.lengthCounter == 0:
    channel.lengthCounter = 256

  # Reload frequency timer
  channel.scheduler.clear(apuChannel3)
  channel.waveRamPosition = 0
  channel.scheduleReload()

# Register writes
proc writeNR30*(channel: Channel3, value: uint8) =
  channel.dacEnabled = (value and 0x80) != 0
  channel.waveRamDimension = int((value shr 5) and 0x01)
  channel.waveRamBank = int((value shr 6) and 0x01)

  if not channel.dacEnabled:
    channel.enabled = false

proc writeNR31*(channel: Channel3, value: uint8) =
  channel.lengthLoad = int(value)
  channel.lengthCounter = 256 - channel.lengthLoad

proc writeNR32*(channel: Channel3, value: uint8) =
  channel.volumeCode = int((value shr 5) and 0x03)
  channel.volumeForce = (value and 0x80) != 0

proc writeNR33*(channel: Channel3, value: uint8) =
  channel.frequency = (channel.frequency and 0x700) or value.uint32

proc writeNR34*(channel: Channel3, value: uint8) =
  channel.frequency = (channel.frequency and 0xFF) or ((value.uint32 and 0x07) shl 8)
  channel.lengthEnable = (value and 0x40) != 0

  # Trigger
  if (value and 0x80) != 0:
    channel.trigger()

# Register reads
proc readNR30*(channel: Channel3): uint8 =
  0x7F'u8 or
  (if channel.dacEnabled: 0x80 else: 0x00)

proc readNR31*(channel: Channel3): uint8 =
  0xFF'u8  # Write-only

proc readNR32*(channel: Channel3): uint8 =
  0x9F'u8 or
  (channel.volumeCode.uint8 shl 5) or
  (if channel.volumeForce: 0x80 else: 0x00)

proc readNR33*(channel: Channel3): uint8 =
  0xFF'u8  # Write-only

proc readNR34*(channel: Channel3): uint8 =
  0xBF'u8 or (if channel.lengthEnable: 0x40 else: 0x00)

# Wave RAM access
proc writeWaveRam*(channel: Channel3, index: int, value: uint8) =
  let bank = if channel.waveRamDimension == 0: channel.waveRamBank else: (index div 16)
  let offset = index and 15
  channel.waveRam[bank][offset] = value

proc readWaveRam*(channel: Channel3, index: int): uint8 =
  let bank = if channel.waveRamDimension == 0: channel.waveRamBank else: (index div 16)
  let offset = index and 15
  channel.waveRam[bank][offset]
