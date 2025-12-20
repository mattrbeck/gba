import types

var
  siocnt: uint16   # 0x128 - Serial I/O Control
  siodata8: uint8  # 0x12A - 8-bit Serial Data

proc newSerial*(gba: GBA): Serial =
  new result
  result.gba = gba

proc `[]`*(serial: Serial, address: SomeInteger): uint8 =
  case address
  of 0x120..0x127: 0  # SIODATA32 / SIOMULTI0-3 (not implemented)
  of 0x128: uint8(siocnt and 0xFF)
  of 0x129: uint8(siocnt shr 8)
  of 0x12A: siodata8
  of 0x12B: 0  # SIODATA8 high byte (unused)
  else: 0

proc `[]=`*(serial: Serial, address: SomeInteger, value: uint8) =
  case address
  of 0x120..0x127: discard  # SIODATA32 / SIOMULTI0-3 (not implemented)
  of 0x128:
    siocnt = (siocnt and 0xFF00) or value.uint16
  of 0x129:
    siocnt = (siocnt and 0x00FF) or (value.uint16 shl 8)
  of 0x12A: siodata8 = value
  of 0x12B: discard  # SIODATA8 high byte (unused)
  else: discard
