import strutils, os, strformat
import types
import storage/[sram, flash, eeprom]

proc detectStorageType(rom: openArray[uint8]): StorageType =
  # Scan ROM for save type markers (common practice in GBA games)
  var romStr = ""
  for i in 0..<min(rom.len, 0x1000000):  # Search first 16MB
    if rom[i] >= 32 and rom[i] < 127:  # Printable ASCII
      romStr.add(chr(rom[i]))
      if romStr.len > 20:
        romStr = romStr[1..^1]  # Keep only last 20 chars

      # Check for markers
      if "EEPROM_V" in romStr:
        return StorageType.EEPROM
      elif "FLASH1M_V" in romStr or "FLASH_V128" in romStr:
        return StorageType.Flash128
      elif "FLASH_V" in romStr or "FLASH512_V" in romStr:
        return StorageType.Flash64
      elif "SRAM_V" in romStr:
        return StorageType.SRAM

  # Default to SRAM if no marker found
  return StorageType.SRAM

proc newSave*(gba: GBA, romPath: string = ""): Save =
  new result
  result.gba = gba
  result.romPath = romPath
  result.dirty = false

  # Detect storage type from ROM
  let storageType = detectStorageType(gba.bus.rom)

  # Create appropriate storage
  case storageType
  of StorageType.None:
    result.storage = nil
  of StorageType.SRAM:
    echo "Detected SRAM save type"
    result.storage = newSRAM()
  of StorageType.Flash64:
    echo "Detected Flash 64KB save type"
    result.storage = newFlash(false)
  of StorageType.Flash128:
    echo "Detected Flash 128KB save type"
    result.storage = newFlash(true)
  of StorageType.EEPROM:
    echo "Detected EEPROM save type"
    # Start with 0 address bits - will be detected from DMA length
    result.storage = newEEPROM(0)

  # Try to load existing save file
  if romPath != "" and result.storage != nil:
    let savePath = romPath.changeFileExt("sav")
    if fileExists(savePath):
      try:
        let data = readFile(savePath)
        echo &"Loading save file: {savePath} ({data.len} bytes)"

        # Load data into appropriate storage type
        if result.storage of SRAMStorage:
          let sram = SRAMStorage(result.storage)
          for i in 0..<min(data.len, sram.memory.len):
            sram.memory[i] = data[i].uint8
        elif result.storage of FlashStorage:
          let flash = FlashStorage(result.storage)
          for i in 0..<min(data.len, flash.memory.len):
            flash.memory[i] = data[i].uint8
        elif result.storage of EEPROMStorage:
          let eeprom = EEPROMStorage(result.storage)
          # Detect EEPROM size from save file size
          if data.len == 0x200:
            eeprom.addressBits = 6
          elif data.len == 0x2000:
            eeprom.addressBits = 14
          if eeprom.memory.len != data.len:
            eeprom.memory.setLen(data.len)
          for i in 0..<data.len:
            eeprom.memory[i] = data[i].uint8

        result.storage.dirty = false
      except IOError:
        echo "Failed to load save file: ", getCurrentExceptionMsg()

proc writeSaveFile*(save: Save) =
  if save.storage == nil or save.romPath == "":
    return

  if not save.storage.dirty:
    return

  let savePath = save.romPath.changeFileExt("sav")

  try:
    # Get data from appropriate storage type
    var data: string
    if save.storage of SRAMStorage:
      let sram = SRAMStorage(save.storage)
      data = newString(sram.memory.len)
      for i in 0..<sram.memory.len:
        data[i] = chr(sram.memory[i])
    elif save.storage of FlashStorage:
      let flash = FlashStorage(save.storage)
      data = newString(flash.memory.len)
      for i in 0..<flash.memory.len:
        data[i] = chr(flash.memory[i])
    elif save.storage of EEPROMStorage:
      let eeprom = EEPROMStorage(save.storage)
      data = newString(eeprom.memory.len)
      for i in 0..<eeprom.memory.len:
        data[i] = chr(eeprom.memory[i])

    writeFile(savePath, data)
    save.storage.dirty = false
    echo &"Saved to: {savePath}"
  except IOError:
    echo "Failed to write save file: ", getCurrentExceptionMsg()

proc `[]`*(save: Save, address: uint32): uint8 =
  if save.storage == nil:
    return 0

  if save.storage of SRAMStorage:
    return SRAMStorage(save.storage)[address]
  elif save.storage of FlashStorage:
    return FlashStorage(save.storage)[address]
  elif save.storage of EEPROMStorage:
    # EEPROM reads need DMA length (not available here, default to 0)
    return EEPROMStorage(save.storage)[0]
  else:
    return 0

proc `[]=`*(save: Save, address: uint32, value: uint8) =
  if save.storage == nil:
    return

  if save.storage of SRAMStorage:
    SRAMStorage(save.storage)[address] = value
  elif save.storage of FlashStorage:
    FlashStorage(save.storage)[address] = value
  elif save.storage of EEPROMStorage:
    # EEPROM writes need DMA length (not available here, default to 0)
    EEPROMStorage(save.storage)[0] = value

# Special accessors for EEPROM with DMA length
proc readEEPROM*(save: Save, dmaLength: uint32): uint8 =
  if save.storage != nil and save.storage of EEPROMStorage:
    return EEPROMStorage(save.storage)[dmaLength]
  return 0

proc writeEEPROM*(save: Save, dmaLength: uint32, value: uint8) =
  if save.storage != nil and save.storage of EEPROMStorage:
    EEPROMStorage(save.storage)[dmaLength] = value
