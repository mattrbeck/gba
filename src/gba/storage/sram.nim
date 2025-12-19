import ../types

proc newSRAM*(): SRAMStorage =
  new result
  # Initialize memory with 0xFF (standard for empty flash/SRAM)
  for i in 0..<result.memory.len:
    result.memory[i] = 0xFF
  result.dirty = false

proc `[]`*(sram: SRAMStorage, address: uint32): uint8 =
  # Mask address to 15 bits (0x7FFF) for 32KB
  sram.memory[address and 0x7FFF]

proc `[]=`*(sram: SRAMStorage, address: uint32, value: uint8) =
  # Mask address to 15 bits (0x7FFF) for 32KB
  sram.memory[address and 0x7FFF] = value
  sram.dirty = true
