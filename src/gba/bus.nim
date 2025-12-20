import bitops, strutils

import types, util, mmio, save, ppu, apu

# Timings for rom are estimated for game compatibility.
const accessTimingTable = [
  [1, 1, 3, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2], # 8-bit and 16-bit accesses
  [1, 1, 6, 1, 1, 2, 2, 1, 4, 4, 4, 4, 4, 4, 4, 4], # 32-bit accesses
]

var accessCycleCount = 0

proc newBus*(gba: GBA, biosPath, romPath: string): Bus =
  new result
  result.gba = gba
  result.mmio = newMMIO(gba)
  for i in 0 ..< result.rom.len:
    var oob = 0xFFFF and (i shr 1)
    result.rom[i] = uint8((oob shr (8 * (i and 1))))
  var
    biosFile = open(biosPath)
    romFile = open(romPath)
  discard readBytes(biosFile, result.bios, 0, len(result.bios))
  discard readBytes(romFile, result.rom, 0, len(result.rom))
  close(biosFile)
  close(romFile)
  # Initialize save system after ROM is loaded (for auto-detection)
  result.save = newSave(gba, result.rom, romPath)

# Increment the access cycle count for the cycles needed by this memory region.
proc countCycles[T: uint8 | uint16 | uint32](page: SomeInteger) {.inline.} =
  when T is uint32: accessCycleCount += accessTimingTable[1][page]
  else:             accessCycleCount += accessTimingTable[0][page]

# Get and reset the access cycle count.
proc accessCycles*(): int {.inline.} =
  result = accessCycleCount
  accessCycleCount = 0

proc read*[T: uint8 | uint16 | uint32](bus: Bus, index: uint32): T =
  let
    aligned = index.clearMasked(sizeof(T) - 1) # uint32:3, uint16:1
    page = index.bitsliced(24..27)
  countCycles[T](page)
  result = case page
    of 0x0: cast[ptr T](addr bus.bios[aligned and 0x3FFF])[]
    of 0x2: cast[ptr T](addr bus.iwram[aligned and 0x3FFFF])[]
    of 0x3: cast[ptr T](addr bus.ewram[aligned and 0x7FFF])[]
    of 0x4:
      let mmioAddr = aligned and 0xFFFFFF
      when T is uint8: bus.mmio[mmioAddr]
      elif T is uint16: bus.mmio[mmioAddr].T or (bus.mmio[mmioAddr + 1].T shl 8)
      elif T is uint32: bus.mmio[mmioAddr].T or (bus.mmio[mmioAddr + 1].T shl 8) or
                        (bus.mmio[mmioAddr + 2].T shl 16) or (bus.mmio[mmioAddr + 3].T shl 24)
    of 0x5: cast[ptr T](addr bus.gba.ppu.pram[aligned and 0x3FF])[]
    of 0x6:
      var address = aligned and 0x1FFFF
      if address > 0x17FFF: address -= 0x8000
      cast[ptr T](addr bus.gba.ppu.vram[address])[]
    of 0x7: cast[ptr T](addr bus.gba.ppu.oam[aligned and 0x3FF])[]
    of 0x8, 0x9,
       0xA, 0xB,
       0xC, 0xD: cast[ptr T](addr bus.rom[aligned and 0x01FFFFFF])[]
    of 0xE, 0xF: cast[T](bus.save[aligned])
    else: quit "Unmapped " & $T & " read: " & aligned.toHex(8)

proc `[]=`*[T: uint8 | uint16 | uint32](bus: Bus, index: uint32, value: T) =
  let
    aligned = index.clearMasked(sizeof(T) - 1) # uint32:3, uint16:1
    page = index.bitsliced(24..27)
  countCycles[T](page)
  case page
  of 0x2: cast[ptr T](addr bus.iwram[aligned and 0x3FFFF])[] = value
  of 0x3: cast[ptr T](addr bus.ewram[aligned and 0x7FFF])[] = value
  of 0x4:
      let mmioAddr = aligned and 0xFFFFFF
      # Special handling for FIFO 32-bit writes (used by DMA)
      when T is uint32:
        if mmioAddr == 0xA0:
          bus.gba.apu.writeFIFO_A(value)
          return
        elif mmioAddr == 0xA4:
          bus.gba.apu.writeFIFO_B(value)
          return
      # Normal MMIO byte-level writes
      bus.mmio[mmioAddr] = cast[uint8](value)
      when T is uint16 or T is uint32:
        bus.mmio[mmioAddr + 1] = cast[uint8](value shr 8)
      when T is uint32:
        bus.mmio[mmioAddr + 2] = cast[uint8](value shr 16)
        bus.mmio[mmioAddr + 3] = cast[uint8](value shr 24)
  of 0x5:
    when T is uint8: # byte writes are duplicated into both sides of a halfword
      cast[ptr uint16](addr bus.gba.ppu.pram[aligned and 0x3FE])[] = value.uint16 * 0x0101'u16
    else:
      cast[ptr T](addr bus.gba.ppu.pram[aligned and 0x3FF])[] = value
  of 0x6:
    var address = aligned and 0x1FFFF
    if address >= 0x18000: address = address and 0x8000
    when T is uint8:
      let limit = if isBitmap(): 0x14000'u32 else: 0x10000'u32
      if address >= limit: return # byte writes have limited range
      let value = value.uint16 * 0x0101'u16 # byte writes are duplicated across halfwords
      address = address and not 1'u32 # byte writes are aligned as halfwords
      cast[ptr uint16](addr bus.gba.ppu.vram[address])[] = value
    else:
      cast[ptr T](addr bus.gba.ppu.vram[address])[] = value
  of 0x7:
    when T is not uint8: # byte writes are not permitted
      cast[ptr T](addr bus.gba.ppu.oam[aligned and 0x3FF])[] = value
  of 0x8, 0x9, 0xA, 0xB, 0xC, 0xD: discard # ROM - writes ignored
  of 0xE, 0xF: bus.save[aligned] = cast[uint8](value)
  else: echo "Unmapped " & $T & " write: " & index.toHex(8) & " = " & value.toHex(sizeof(T) * 2)

proc readRotate*[T: uint16 | uint32](bus: Bus, index: uint32): uint32 =
  let
    value = bus.read[:T](index).uint32
    shift = (index and (sizeof(T) - 1)) shl 3
  result = (value shr shift) or (value shl (32 - shift))

# LDRSH Rd,[odd] --> LDRSB Rd,[odd] ;sign-expand BYTE value
proc readSigned*[T: uint8 | uint16](bus: Bus, index: uint32): uint32 =
  if T is uint8 or index.bit(0):
    signExtend[uint32](bus.read[:uint8](index), 7)
  else:
    signExtend[uint32](bus.read[:uint16](index), 15)
