import ../types

proc newEEPROM*(addressBits: int): EEPROMStorage =
  new result
  # 6 bits = 512 bytes (4K), 14 bits = 8192 bytes (64K)
  let size = 1 shl (addressBits + 3)  # addressBits is for 64-bit blocks
  result.memory = newSeq[uint8](size)
  # Initialize with 0xFF
  for i in 0..<size:
    result.memory[i] = 0xFF
  result.addressBits = addressBits
  result.buffer = 0
  result.bufferSize = 0
  result.state = EEPROMReady
  result.address = 0
  result.readBits = 0
  result.writeBits = 0
  result.dirty = false

proc reset*(eeprom: EEPROMStorage) =
  eeprom.buffer = 0
  eeprom.bufferSize = 0
  eeprom.state = EEPROMReady
  eeprom.readBits = 0
  eeprom.writeBits = 0

proc `[]`*(eeprom: EEPROMStorage, dmaLength: uint32): uint8 =
  # Reading returns bits during read operations
  if eeprom.state == EEPROMRead:
    # First 4 bits are always 0
    if eeprom.readBits < 4:
      eeprom.readBits += 1
      return 0

    # Next 64 bits come from memory
    if eeprom.readBits < 68:
      let bitInBlock = eeprom.readBits - 4
      let byteOffset = eeprom.address.int * 8 + (bitInBlock div 8)
      let bitInByte = 7 - (bitInBlock mod 8)
      let bit = (eeprom.memory[byteOffset] shr bitInByte) and 1
      eeprom.readBits += 1

      if eeprom.readBits >= 68:
        eeprom.reset()

      return bit

  return 1  # Default high

proc `[]=`*(eeprom: EEPROMStorage, dmaLength: uint32, value: uint8) =
  # Only bit 0 matters for serial communication
  let bit = value and 1

  case eeprom.state
  of EEPROMReady:
    # Accumulate bits to determine command
    eeprom.buffer = (eeprom.buffer shl 1) or bit.uint64
    eeprom.bufferSize += 1

    if eeprom.bufferSize >= 2:
      # Check for command pattern
      let cmd = eeprom.buffer and 3
      if cmd == 0b11:  # Read command
        eeprom.state = EEPROMAddress
        eeprom.buffer = 0
        eeprom.bufferSize = 0
      elif cmd == 0b10:  # Write command
        eeprom.state = EEPROMAddress
        eeprom.buffer = 0
        eeprom.bufferSize = 0
        # Check if we need to detect size from DMA length
        if eeprom.addressBits == 0:
          # DMA length of 9 = 6-bit addressing, 17 = 14-bit addressing
          if dmaLength == 9:
            eeprom.addressBits = 6
            eeprom.memory.setLen(1 shl (6 + 3))
          elif dmaLength == 17:
            eeprom.addressBits = 14
            eeprom.memory.setLen(1 shl (14 + 3))

  of EEPROMAddress:
    # Accumulate address bits
    eeprom.buffer = (eeprom.buffer shl 1) or bit.uint64
    eeprom.bufferSize += 1

    if eeprom.bufferSize >= eeprom.addressBits:
      # Address complete
      eeprom.address = eeprom.buffer.uint16
      eeprom.buffer = 0
      eeprom.bufferSize = 0

      # Transition based on which command we came from
      # (we need to track this - for now, check next state)
      # Read has already been handled by transitioning to read mode
      # Write needs to collect 64 bits of data
      eeprom.state = EEPROMWrite

  of EEPROMWrite:
    # Accumulate 64 bits of data
    eeprom.buffer = (eeprom.buffer shl 1) or bit.uint64
    eeprom.writeBits += 1

    if eeprom.writeBits >= 64:
      # Write the 64-bit block to memory
      for i in 0..<8:
        let byteIdx = eeprom.address.int * 8 + i
        eeprom.memory[byteIdx] = uint8((eeprom.buffer shr ((7 - i) * 8)) and 0xFF)

      eeprom.dirty = true
      eeprom.reset()

  of EEPROMRead:
    # Shouldn't write during read
    eeprom.reset()

# Helper to set read mode after address is received
proc setReadMode*(eeprom: EEPROMStorage) =
  if eeprom.state == EEPROMAddress and eeprom.bufferSize >= eeprom.addressBits:
    eeprom.address = eeprom.buffer.uint16
    eeprom.state = EEPROMRead
    eeprom.readBits = 0
    eeprom.buffer = 0
    eeprom.bufferSize = 0
