import bitops, strformat, strutils, std/macros

import bus, cpu, types, util

proc immediateOffset(instr: uint32, carryOut: var bool): uint32 =
  result = ror[false](instr.bitSliced(0..7), 2 * instr.bitSliced(8..11), carryOut)

proc rotateRegister[immediate: static bool](cpu: CPU, instr: uint32, carryOut: var bool): uint32 =
  let
    reg = instr.bitSliced(0..3)
    shiftType = instr.bitSliced(5..6)
    shiftAmount = if immediate: instr.bitSliced(7..11)
                  else: cpu.r[instr.bitSliced(8..11)] and 0xFF
  result = shift[immediate](shiftType, cpu.r[reg], shiftAmount, carryOut)

converter psrToU32(psr: PSR): uint32 = cast[uint32](psr)

proc unimplemented(gba: GBA, instr: uint32) =
  quit "Unimplemented opcode: 0x" & instr.toHex(8)

proc multiply[accumulate, set_cond: static bool](gba: GBA, instr: uint32) =
  let
    rd = instr.bitsliced(16..19)
    rn = instr.bitsliced(12..15)
    rs = instr.bitsliced(8..11)
    rm = instr.bitsliced(0..3)
  var value = gba.cpu.r[rm] * gba.cpu.r[rs]
  if accumulate: value += gba.cpu.r[rn]
  gba.cpu.setReg(rd, value)
  if set_cond: setNegAndZeroFlags(gba.cpu, value)
  if rd != 15: gba.cpu.stepArm()

proc multiply_long[signed, accumulate, set_cond: static bool](gba: GBA, instr: uint32) =
  quit "Unimplemented instruction: MultipleLong<" & $signed & "," & $accumulate & "," & $set_cond & ">(0x" & instr.toHex(8) & ")"

proc single_data_swap[word: static bool](gba: GBA, instr: uint32) =
  quit "Unimplemented instruction: SingleDataSwap<" & $instr & ">(0x" & instr.toHex(8) & ")"

proc branch_exchange(gba: GBA, instr: uint32) =
  let address = gba.cpu.r[instr.bitsliced(0..3)]
  gba.cpu.cpsr.thumb = bool(address and 1)
  gba.cpu.setReg(15, address)

proc halfword_data_transfer[pre, add, immediate, writeback, load: static bool, op: static uint32](gba: GBA, instr: uint32) =
  let
    rn = instr.bitSliced(16..19)
    rd = instr.bitSliced(12..15)
    offset_high = instr.bitSliced(8..11)
    rm = instr.bitSliced(0..3)
    offset = if immediate: (offset_high shl 4) or rm
             else: gba.cpu.r[rm]
  var address = gba.cpu.r[rn]
  if pre:
    if add: address += offset
    else: address -= offset
  case op
  of 0b00: quit fmt"SWP instruction ({instr.toHex(8)})"
  of 0b01: # LDRH / STRH
    if load:
      gba.cpu.setReg(rd, gba.bus.readRotate[:uint16](address))
    else:
      var value = gba.cpu.r[rd]
      # When R15 is the source register (Rd) of a register store (STR) instruction, the stored
      # value will be address of the instruction plus 12.
      if rd == 15: value += 4
      gba.bus[address] = uint16(value and 0xFFFF)
  of 0b10: # LDRSB
    gba.cpu.setReg(rd, signExtend[uint32](gba.bus.read[:uint8](address).uint32, 7))
  else: quit fmt"unhandled halfword transfer op: {op}"
  if not pre:
    if add: address += offset
    else: address -= offset
  # Post-index is always a writeback; don't writeback if value is loaded to base
  if (writeback or not(pre)) and not(load and rn == rd): gba.cpu.setReg(rn, address)
  if not(load and rd == 15): gba.cpu.stepArm()

proc single_data_transfer[immediate, pre, add, byte, writeback, load, bit4: static bool](gba: GBA, instr: uint32) =
  if immediate and bit4: quit "LDR/STR: Cannot shift by a register. TODO: Probably should throw undefined exception"
  var shifterCarryOut = gba.cpu.cpsr.carry
  let
    rn = instr.bitSliced(16..19)
    rd = instr.bitsliced(12..15)
    offset = if immediate: rotateRegister[not(bit4)](gba.cpu, instr.bitSliced(0..11), shifterCarryOut)
             else: instr.bitSliced(0..11)
  var address = gba.cpu.r[rn]
  if pre:
    if add: address += offset
    else: address -= offset
  if load:
    let value = if byte: gba.bus.read[:uint8](address).uint32
                else: gba.bus.readRotate[:uint32](address)
    gba.cpu.setReg(rd, value)
  else:
    var value = gba.cpu.r[rd]
    # When R15 is the source register (Rd) of a register store (STR) instruction, the stored
    # value will be address of the instruction plus 12.
    if rd == 15: value += 4
    if byte: value = uint8(value and 0xFF)
    gba.bus[address] = value
  if not pre:
    if add: address += offset
    else: address -= offset
  # Post-index is always a writeback; don't writeback if value is loaded to base
  if (writeback or not(pre)) and not(load and rn == rd): gba.cpu.setReg(rn, address)
  if rd != 15: gba.cpu.stepArm()

proc block_data_transfer[pre, add, psr_user, writeback, load: static bool](gba: GBA, instr: uint32) =
  if load and psr_user and instr.testBit(15): quit fmt"TODO: Implement LDMS w/ r15 in the list ({instr.toHex(8)})"
  let
    rn = instr.bitsliced(16..19)
    currentMode = gba.cpu.cpsr.mode
  if psr_user: gba.cpu.mode = Mode.usr
  var
    firstTransfer = false
    address = gba.cpu.r[rn]
    list = instr.bitsliced(0..15)
    setBits = countSetBits(list)
  if setBits == 0: # odd behavior on empty list, tested in gba-suite
    setBits = 16
    list = 0x8000
  let
    finalAddress = if add: address + uint32(setBits * 4)
                   else: address - uint32(setBits * 4)
  # compensate for direction and pre-increment
  if add and pre: address += 4
  elif not(add):
    address = finalAddress
    if not(pre): address += 4
  for i in 0 .. 15:
    if list.testBit(i):
      if load:
        gba.cpu.setReg(i, gba.bus.read[:uint32](address))
      else:
        var value = gba.cpu.r[i]
        if i == 15: value += 4
        gba.bus[address] = gba.cpu.r[i]
      address += 4
      if writeback and not(firstTransfer) and not(load and list.testBit(rn)): gba.cpu.setReg(rn, finalAddress)
      firstTransfer = true
  if psr_user: gba.cpu.mode = currentMode
  if not(load and list.testBit(15)): gba.cpu.stepArm()

proc branch[link: static bool](gba: GBA, instr: uint32) =
  var offset = instr.bitSliced(0..23)
  if offset.testBit(23): offset = offset or 0xFF000000'u32
  if link: gba.cpu.setReg(14, gba.cpu.r[15] - 4)
  gba.cpu.setReg(15, gba.cpu.r[15] + offset * 4)

proc software_interrupt(gba: GBA, instr: uint32) =
  quit "Unimplemented instruction: SoftwareInterrupt<>(0x" & instr.toHex(8) & ")"

proc status_transfer[immediate, spsr, msr: static bool](gba: GBA, instr: uint32) =
  let
    rd = instr.bitsliced(12..15)
    mode = gba.cpu.cpsr.mode
    hasSpsr = mode != Mode.sys and mode != Mode.usr
  if msr:
    var mask = 0x00000000'u32
    if instr.testBit(19): mask = mask or 0xFF000000'u32
    if instr.testBit(16): mask = mask or 0x000000FF'u32
    if not(spsr) and mode == Mode.usr: mask = mask and 0x000000FF'u32
    var
      barrelOut: bool
      value = if immediate: immediateOffset(instr.bitSliced(0..11), barrelOut)
              else: gba.cpu.r[instr.bitsliced(0..3)]
    value = value and mask
    if spsr:
      if hasSpsr:
        gba.cpu.spsr = cast[PSR]((cast[uint32](gba.cpu.spsr) and not(mask)) or value)
    else:
      let thumb = gba.cpu.cpsr.thumb
      if instr.testBit(16): gba.cpu.mode = Mode(value and 0x1F)
      gba.cpu.cpsr = cast[PSR]((cast[uint32](gba.cpu.cpsr) and not(mask)) or value)
      gba.cpu.cpsr.thumb = thumb
  else:
    let value = if spsr and hasSpsr: gba.cpu.spsr
                else: gba.cpu.cpsr
    gba.cpu.setReg(rd, value)
  if not(not(msr) and rd == 15): gba.cpu.stepArm()

proc data_processing[immediate: static bool, op: static uint32, set_cond, bit4: static bool](gba: GBA, instr: uint32) =
  var shifterCarryOut = gba.cpu.cpsr.carry
  let
    rn = instr.bitSliced(16..19)
    rd = instr.bitSliced(12..15)
    op2 = if immediate: immediateOffset(instr.bitSliced(0..11), shifterCarryOut)
          else: rotateRegister[not(bit4)](gba.cpu, instr.bitSliced(0..11), shifterCarryOut)
  case op
  of 0x0: # and
    gba.cpu.setReg(rd, gba.cpu.r[rn] and op2)
    if set_cond:
      setNegAndZeroFlags(gba.cpu, gba.cpu.r[rd])
      gba.cpu.cpsr.carry = shifterCarryOut
    if rd != 15: gba.cpu.stepArm()
  of 0x1: # xor
    gba.cpu.setReg(rd, gba.cpu.r[rn] xor op2)
    if set_cond:
      setNegAndZeroFlags(gba.cpu, gba.cpu.r[rd])
      gba.cpu.cpsr.carry = shifterCarryOut
    if rd != 15: gba.cpu.stepArm()
  of 0x2: # sub
    gba.cpu.setReg(rd, gba.cpu.sub(gba.cpu.r[rn], op2, set_cond))
    if rd != 15: gba.cpu.stepArm()
  of 0x4: # add
    gba.cpu.setReg(rd, gba.cpu.add(gba.cpu.r[rn], op2, set_cond))
    if rd != 15: gba.cpu.stepArm()
  of 0x8: # tst
    let value = gba.cpu.r[rn] and op2
    if set_cond:
      setNegAndZeroFlags(gba.cpu, value)
      gba.cpu.cpsr.carry = shifterCarryOut
    gba.cpu.stepArm()
  of 0xA: # cmp
    discard gba.cpu.sub(gba.cpu.r[rn], op2, set_cond)
    gba.cpu.stepArm()
  of 0xC: # orr
    gba.cpu.setReg(rd, gba.cpu.r[rn] or op2)
    if set_cond:
      setNegAndZeroFlags(gba.cpu, gba.cpu.r[rd])
      gba.cpu.cpsr.carry = shifterCarryOut
    if rd != 15: gba.cpu.stepArm()
  of 0xD: # mov
    gba.cpu.setReg(rd, op2)
    if set_cond:
      setNegAndZeroFlags(gba.cpu, gba.cpu.r[rd])
      gba.cpu.cpsr.carry = shifterCarryOut
    if rd != 15: gba.cpu.stepArm()
  else: quit "DataProcessing<" & $immediate & "," & $op & "," & $set_cond & ">(0x" & instr.toHex(8) & ")"

# todo: move this back to nice block creation if the compile time is ever reduced...
macro lutBuilder(): untyped =
  result = newTree(nnkBracket)
  for i in 0'u32 ..< 4096'u32:
    if (i and 0b111111001111) == 0b000000001001:
      result.add newTree(nnkBracketExpr, bindSym"multiply", i.testBit(5).newLit(), i.testBit(4).newLit())
    elif (i and 0b111110001111) == 0b000010001001:
      result.add newTree(nnkBracketExpr, bindSym"multiply_long", i.testBit(6).newLit(), i.testBit(5).newLit(), i.testBit(4).newLit())
    elif (i and 0b111110111111) == 0b000100001001:
      result.add newTree(nnkBracketExpr, bindSym"single_data_swap", i.testBit(6).newLit())
    elif (i and 0b111111111111) == 0b000100100001:
      result.add bindSym"branch_exchange"
    elif (i and 0b111000001001) == 0b000000001001:
      result.add newTree(nnkBracketExpr, bindSym"halfword_data_transfer", i.testBit(8).newLit(), i.testBit(7).newLit(), i.testBit(6).newLit(), i.testBit(5).newLit(), i.testBit(4).newLit(), newLit (i shr 1) and 0b11)
    elif (i and 0b111000000001) == 0b011000000001:
      result.add newNilLit() # undefined instruction
    elif (i and 0b110000000000) == 0b010000000000:
      result.add newTree(nnkBracketExpr, bindSym"single_data_transfer", i.testBit(9).newLit(), i.testBit(8).newLit(), i.testBit(7).newLit(), i.testBit(6).newLit(), i.testBit(5).newLit(), i.testBit(4).newLit(), i.testBit(0).newLit())
    elif (i and 0b111000000000) == 0b100000000000:
      result.add newTree(nnkBracketExpr, bindSym"block_data_transfer", i.testBit(8).newLit(), i.testBit(7).newLit(), i.testBit(6).newLit(), i.testBit(5).newLit(), i.testBit(4).newLit())
    elif (i and 0b111000000000) == 0b101000000000:
      result.add newTree(nnkBracketExpr, bindSym"branch", i.testBit(8).newLit())
    elif (i and 0b111000000000) == 0b110000000000:
      result.add newNilLit() # coprocessor data transfer
    elif (i and 0b111100000001) == 0b111000000000:
      result.add newNilLit() # coprocessor data operation
    elif (i and 0b111100000001) == 0b111000000001:
      result.add newNilLit() # coprocessor register transfer
    elif (i and 0b111100000000) == 0b111100000000:
      result.add bindSym"software_interrupt"
    elif (i and 0b110110010000) == 0b000100000000:
      result.add newTree(nnkBracketExpr, bindSym"status_transfer", i.testBit(9).newLit(), i.testBit(6).newLit(), i.testBit(5).newLit())
    elif (i and 0b110000000000) == 0b000000000000:
      result.add newTree(nnkBracketExpr, bindSym"data_processing", i.testBit(9).newLit(), newLit((i shr 5) and 0xF), i.testBit(4).newLit(), i.testBit(0).newLit())
    else:
      result.add bindSym"unimplemented"

const lut = lutBuilder()

proc execArm*(gba: GBA, instr: uint32) =
  if gba.cpu.checkCond(instr.bitSliced(28..31)):
    lut[((instr shr 16) and 0x0FF0) or ((instr shr 4) and 0xF)](gba, instr)
  else:
    gba.cpu.stepArm()
