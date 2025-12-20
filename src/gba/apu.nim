import math, sdl2/audio
from sdl2 import delay

import scheduler, types
import apu/[resampler, channel1, channel2, channel3, channel4, fifo]

const
  cpuClock = 2 ^ 24
  channels = 2  # Stereo
  bufferSize = 1024
  sampleRate = 32768  # Hz
  samplePeriod = cpuClock div sampleRate
  frameSequencerRate = 512  # Hz
  frameSequencerPeriod = cpuClock div frameSequencerRate
  freqDelta = 0.002

var
  frameSequencerStage = 0
  audioSpec: AudioSpec
  obtainedSpec: AudioSpec
  dev: AudioDeviceID
  bufferPos: int
  buffer = newSeq[float32]()
  resample = newResampler[float32](buffer)
  lastFreq = sampleRate

# Forward declarations
proc getSample(apu: APU): proc()
proc tickFrameSequencer(apu: APU): proc()

# Update APU type in types.nim - we'll add the fields we need
proc newAPU*(gba: GBA): APU =
  new result
  result.gba = gba

  # Initialize all channels
  result.channel1 = newChannel1(gba.scheduler)
  result.channel2 = newChannel2(gba.scheduler)
  result.channel3 = newChannel3(gba.scheduler)
  result.channel4 = newChannel4(gba.scheduler)
  result.fifoA = newFIFOChannel()
  result.fifoB = newFIFOChannel()

  # Initialize SDL audio
  audioSpec.freq = sampleRate
  audioSpec.format = AUDIO_F32
  audioSpec.channels = channels
  audioSpec.samples = bufferSize
  audioSpec.callback = nil
  audioSpec.userdata = nil

  dev = openAudioDevice(nil, 0, addr audioSpec, addr obtainedSpec, SDL_AUDIO_ALLOW_FREQUENCY_CHANGE)
  pauseAudioDevice(dev, 0)

  resample.setFreqs(sampleRate, obtainedSpec.freq)

  # Schedule sampling and frame sequencer
  gba.scheduler.schedule(samplePeriod, result.getSample(), EventType.apu)
  gba.scheduler.schedule(frameSequencerPeriod, result.tickFrameSequencer(), EventType.apu)

  # Initialize control registers
  result.psgVolumeLeft = 7
  result.psgVolumeRight = 7
  result.psgMasterEnable = true
  result.soundBias = 0x200

proc getSample(apu: APU): proc() =
  proc callback() =
    apu.gba.scheduler.schedule(samplePeriod, apu.getSample(), EventType.apu)

    # Mix all channels
    var sample: float32 = 0.0

    # PSG channels (divide by 4 to account for all channels)
    sample += Channel1(apu.channel1).getAmplitude() * 0.25
    sample += Channel2(apu.channel2).getAmplitude() * 0.25
    sample += Channel3(apu.channel3).getAmplitude() * 0.25
    sample += Channel4(apu.channel4).getAmplitude() * 0.25

    # Direct Sound channels
    sample += FIFOChannel(apu.fifoA).getAmplitude() * 0.5
    sample += FIFOChannel(apu.fifoB).getAmplitude() * 0.5

    # Apply master volume (simplified)
    sample *= 0.5

    bufferPos += 1
    resample.write(sample)

    if bufferPos >= bufferSize:
      when defined(emscripten):
        let fillLevel = getQueuedAudioSize(dev)
        lastFreq = int((1 + (int(2 * (int(fillLevel) div sizeof(float32)) - bufferSize) / bufferSize) * freqDelta) * float(lastFreq))
        resample.setFreqs(lastFreq, obtainedSpec.freq)
      else:
        while getQueuedAudioSize(dev) > bufferSize * sizeof(float32) * 2:
          delay(1)
      discard queueAudio(dev, unsafeAddr resample.output[0], uint32(resample.output.len * sizeof(float32)))
      bufferPos = 0
      resample.output.setLen(0)
  callback

proc tickFrameSequencer(apu: APU): proc() =
  proc callback() =
    apu.gba.scheduler.schedule(frameSequencerPeriod, apu.tickFrameSequencer(), EventType.apu)

    case frameSequencerStage
    of 0, 4:  # Length
      Channel1(apu.channel1).lengthStep()
      Channel2(apu.channel2).lengthStep()
      Channel3(apu.channel3).lengthStep()
      Channel4(apu.channel4).lengthStep()
    of 2, 6:  # Length + Sweep
      Channel1(apu.channel1).lengthStep()
      Channel2(apu.channel2).lengthStep()
      Channel3(apu.channel3).lengthStep()
      Channel4(apu.channel4).lengthStep()
      Channel1(apu.channel1).sweepStep()
    of 7:  # Envelope
      Channel1(apu.channel1).envelopeStep()
      Channel2(apu.channel2).envelopeStep()
      Channel4(apu.channel4).envelopeStep()
    else:
      discard

    frameSequencerStage = (frameSequencerStage + 1) and 7
  callback

# Timer overflow notification (called by timer.nim)
proc timerOverflow*(apu: APU, timerNum: int) =
  # Trigger FIFO sample output for channels using this timer
  if FIFOChannel(apu.fifoA).timerSelect == timerNum:
    FIFOChannel(apu.fifoA).timerOverflow()
  if FIFOChannel(apu.fifoB).timerSelect == timerNum:
    FIFOChannel(apu.fifoB).timerOverflow()

# Check if FIFO needs refill (called by timer.nim for DMA)
proc needsFifoRefill*(apu: APU, timerNum: int, fifoAddress: var uint32): bool =
  if FIFOChannel(apu.fifoA).timerSelect == timerNum and FIFOChannel(apu.fifoA).needsRefill():
    fifoAddress = 0x040000A0
    return true
  if FIFOChannel(apu.fifoB).timerSelect == timerNum and FIFOChannel(apu.fifoB).needsRefill():
    fifoAddress = 0x040000A4
    return true
  return false

# Register reads/writes
proc `[]`*(apu: APU, address: uint32): uint8 =
  case address
  # Channel 1 (Sweep + Square)
  of 0x60: Channel1(apu.channel1).readNR10()
  of 0x62: Channel1(apu.channel1).readNR11()
  of 0x63: Channel1(apu.channel1).readNR12()
  of 0x64: Channel1(apu.channel1).readNR13()
  of 0x65: Channel1(apu.channel1).readNR14()

  # Channel 2 (Square)
  of 0x68: Channel2(apu.channel2).readNR21()
  of 0x69: Channel2(apu.channel2).readNR22()
  of 0x6C: Channel2(apu.channel2).readNR23()
  of 0x6D: Channel2(apu.channel2).readNR24()

  # Channel 3 (Wave)
  of 0x70: Channel3(apu.channel3).readNR30()
  of 0x72: Channel3(apu.channel3).readNR31()
  of 0x73: Channel3(apu.channel3).readNR32()
  of 0x74: Channel3(apu.channel3).readNR33()
  of 0x75: Channel3(apu.channel3).readNR34()

  # Channel 4 (Noise)
  of 0x78: Channel4(apu.channel4).readNR41()
  of 0x79: Channel4(apu.channel4).readNR42()
  of 0x7C: Channel4(apu.channel4).readNR43()
  of 0x7D: Channel4(apu.channel4).readNR44()

  # Wave RAM
  of 0x90..0x9F: Channel3(apu.channel3).readWaveRam(int(address - 0x90))

  # Control registers
  of 0x80:  # SOUNDCNT_L low
    (apu.psgVolumeRight.uint8 and 0x07) or
    ((apu.psgVolumeLeft.uint8 and 0x07) shl 4)
  of 0x81:  # SOUNDCNT_L high
    0xFF  # Channel enables (write-only)

  of 0x82:  # SOUNDCNT_H low
    (apu.psgVolume.uint8 and 0x03) or
    (FIFOChannel(apu.fifoA).volume.uint8 shl 2) or
    (FIFOChannel(apu.fifoB).volume.uint8 shl 3)
  of 0x83:  # SOUNDCNT_H high
    (if FIFOChannel(apu.fifoA).enabled: 0x01 else: 0x00).uint8 or
    (if FIFOChannel(apu.fifoB).enabled: 0x02 else: 0x00) or
    (FIFOChannel(apu.fifoA).timerSelect.uint8 shl 2) or
    (FIFOChannel(apu.fifoB).timerSelect.uint8 shl 3)

  of 0x84:  # SOUNDCNT_X
    (if apu.psgMasterEnable: 0x80 else: 0x00).uint8 or
    (if Channel1(apu.channel1).enabled: 0x01 else: 0x00) or
    (if Channel2(apu.channel2).enabled: 0x02 else: 0x00) or
    (if Channel3(apu.channel3).enabled: 0x04 else: 0x00) or
    (if Channel4(apu.channel4).enabled: 0x08 else: 0x00)

  of 0x88:  # SOUNDBIAS low
    uint8(apu.soundBias and 0xFF)
  of 0x89:  # SOUNDBIAS high
    uint8((apu.soundBias shr 8) and 0xFF)

  else:
    0

proc `[]=`*(apu: APU, address: uint32, value: uint8) =
  case address
  # Channel 1 (Sweep + Square)
  of 0x60: Channel1(apu.channel1).writeNR10(value)
  of 0x62: Channel1(apu.channel1).writeNR11(value)
  of 0x63: Channel1(apu.channel1).writeNR12(value)
  of 0x64: Channel1(apu.channel1).writeNR13(value)
  of 0x65: Channel1(apu.channel1).writeNR14(value)

  # Channel 2 (Square)
  of 0x68: Channel2(apu.channel2).writeNR21(value)
  of 0x69: Channel2(apu.channel2).writeNR22(value)
  of 0x6C: Channel2(apu.channel2).writeNR23(value)
  of 0x6D: Channel2(apu.channel2).writeNR24(value)

  # Channel 3 (Wave)
  of 0x70: Channel3(apu.channel3).writeNR30(value)
  of 0x72: Channel3(apu.channel3).writeNR31(value)
  of 0x73: Channel3(apu.channel3).writeNR32(value)
  of 0x74: Channel3(apu.channel3).writeNR33(value)
  of 0x75: Channel3(apu.channel3).writeNR34(value)

  # Channel 4 (Noise)
  of 0x78: Channel4(apu.channel4).writeNR41(value)
  of 0x79: Channel4(apu.channel4).writeNR42(value)
  of 0x7C: Channel4(apu.channel4).writeNR43(value)
  of 0x7D: Channel4(apu.channel4).writeNR44(value)

  # Wave RAM
  of 0x90..0x9F: Channel3(apu.channel3).writeWaveRam(int(address - 0x90), value)

  # Control registers
  of 0x80:  # SOUNDCNT_L low
    apu.psgVolumeRight = int(value and 0x07)
    apu.psgVolumeLeft = int((value shr 4) and 0x07)
  of 0x81:  # SOUNDCNT_L high (channel enables - ignored for now)
    discard

  of 0x82:  # SOUNDCNT_H low
    apu.psgVolume = int(value and 0x03)
    FIFOChannel(apu.fifoA).volume = int((value shr 2) and 0x01)
    FIFOChannel(apu.fifoB).volume = int((value shr 3) and 0x01)
  of 0x83:  # SOUNDCNT_H high
    FIFOChannel(apu.fifoA).enabled = (value and 0x01) != 0
    FIFOChannel(apu.fifoB).enabled = (value and 0x02) != 0
    FIFOChannel(apu.fifoA).timerSelect = int((value shr 2) and 0x01)
    FIFOChannel(apu.fifoB).timerSelect = int((value shr 3) and 0x01)
    if (value and 0x08) != 0: FIFOChannel(apu.fifoA).reset()
    if (value and 0x10) != 0: FIFOChannel(apu.fifoB).reset()

  of 0x84:  # SOUNDCNT_X
    apu.psgMasterEnable = (value and 0x80) != 0
    if not apu.psgMasterEnable:
      # Disable all channels
      Channel1(apu.channel1).enabled = false
      Channel2(apu.channel2).enabled = false
      Channel3(apu.channel3).enabled = false
      Channel4(apu.channel4).enabled = false

  of 0x88:  # SOUNDBIAS low
    apu.soundBias = (apu.soundBias and 0xFF00) or value.uint16
  of 0x89:  # SOUNDBIAS high
    apu.soundBias = (apu.soundBias and 0x00FF) or (value.uint16 shl 8)

  # FIFO writes
  of 0xA0..0xA3:  # FIFO_A
    discard  # Handled by DMA via write32
  of 0xA4..0xA7:  # FIFO_B
    discard  # Handled by DMA via write32

  else:
    discard

# Special methods for FIFO DMA writes
proc writeFIFO_A*(apu: APU, value: uint32) =
  FIFOChannel(apu.fifoA).write32(value)

proc writeFIFO_B*(apu: APU, value: uint32) =
  FIFOChannel(apu.fifoB).write32(value)
