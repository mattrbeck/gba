import ../types

const
  ENTER_IDENT = 0x90'u8
  EXIT_IDENT = 0xF0'u8
  PREPARE_ERASE = 0x80'u8
  ERASE_ALL = 0x10'u8
  ERASE_CHUNK = 0x30'u8
  PREPARE_WRITE = 0xA0'u8
  SET_BANK = 0xB0'u8

proc newFlash*(is128k: bool): FlashStorage =
  new result
  let size = if is128k: 0x20000 else: 0x10000  # 128KB or 64KB
  result.memory = newSeq[uint8](size)
  # Initialize with 0xFF (standard for empty flash)
  for i in 0..<size:
    result.memory[i] = 0xFF
  result.state = FlashReady
  result.bank = 0
  result.is128k = is128k
  result.dirty = false

proc chipId*(flash: FlashStorage): uint16 =
  # Return chip ID based on size
  if flash.is128k:
    0x1362'u16  # Sanyo
  else:
    0x1B32'u16  # Panasonic

proc `[]`*(flash: FlashStorage, address: uint32): uint8 =
  let address16 = address and 0xFFFF  # Mask to 16 bits

  if flash.state == FlashIdentification:
    # Return chip ID bytes
    if address16 == 0:
      return uint8(flash.chipId and 0xFF)
    elif address16 == 1:
      return uint8(flash.chipId shr 8)
    return 0xFF

  # Normal read - apply bank offset for 128k flash
  let offset = if flash.is128k: flash.bank.uint32 * 0x10000 else: 0'u32
  flash.memory[offset + address16]

proc `[]=`*(flash: FlashStorage, address: uint32, value: uint8) =
  let address16 = address and 0xFFFF  # Mask to 16 bits

  case flash.state
  of FlashReady:
    if address16 == 0x5555 and value == 0xAA:
      flash.state = FlashCmd1

  of FlashCmd1:
    if address16 == 0x2AAA and value == 0x55:
      flash.state = FlashCmd2
    else:
      flash.state = FlashReady

  of FlashCmd2:
    if address16 == 0x5555:
      case value
      of ENTER_IDENT:
        flash.state = FlashIdentification
      of EXIT_IDENT:
        flash.state = FlashReady
      of PREPARE_ERASE:
        flash.state = FlashPrepareErase
      of PREPARE_WRITE:
        flash.state = FlashPrepareWrite
      of SET_BANK:
        flash.state = FlashSetBank
      else:
        flash.state = FlashReady
    else:
      flash.state = FlashReady

  of FlashIdentification:
    if address16 == 0x5555 and value == 0xAA:
      flash.state = FlashCmd1

  of FlashPrepareErase:
    if address16 == 0x5555 and value == 0xAA:
      flash.state = FlashCmd1
    elif value == ERASE_ALL:
      # Erase entire chip
      let offset = if flash.is128k: flash.bank.uint32 * 0x10000 else: 0'u32
      for i in 0..<0x10000:
        flash.memory[offset + i.uint32] = 0xFF
      flash.dirty = true
      flash.state = FlashReady
    elif value == ERASE_CHUNK:
      # Erase 4KB sector
      let sectorStart = address16 and 0xF000  # Align to 4KB boundary
      let offset = if flash.is128k: flash.bank.uint32 * 0x10000 else: 0'u32
      for i in 0..<0x1000:
        flash.memory[offset + sectorStart + i.uint32] = 0xFF
      flash.dirty = true
      flash.state = FlashReady
    else:
      flash.state = FlashReady

  of FlashPrepareWrite:
    # Write single byte using AND operation (flash can only flip 1s to 0s)
    let offset = if flash.is128k: flash.bank.uint32 * 0x10000 else: 0'u32
    flash.memory[offset + address16] = flash.memory[offset + address16] and value
    flash.dirty = true
    flash.state = FlashReady

  of FlashSetBank:
    if flash.is128k:
      flash.bank = value and 1  # Only bit 0 matters for 128k (2 banks)
    flash.state = FlashReady
