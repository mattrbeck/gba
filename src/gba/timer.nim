import types, interrupts, regs, scheduler, apu

const
  periods = [1'u16, 64, 256, 1024]
  events = [timer0, timer1, timer2, timer3]

var
  reload: array[4, uint16]
  tmcnt: array[4, TMCNT]
  counter: array[4, uint16]
  cycleEnabled: array[4, uint64]

proc overflow(timer: Timer, num: SomeInteger): proc()

proc newTimer*(gba: GBA): Timer =
  new result
  result.gba = gba
  result.overflowProcs = [overflow(result, 0), overflow(result, 1), overflow(result, 2), overflow(result, 3)]

proc cyclesUntilOverflow(num: SomeInteger): uint64 =
  periods[tmcnt[num].freq].uint64 * (0x10000'u64 - counter[num])

proc scheduleTimer(timer: Timer, num: SomeInteger) =
  cycleEnabled[num] = timer.gba.scheduler.cycles
  timer.gba.scheduler.schedule(cyclesUntilOverflow(num), timer.overflowProcs[num], events[num])

proc overflow(timer: Timer, num: SomeInteger): proc() = (proc() =
  counter[num] = reload[num]
  if num < 3 and tmcnt[num + 1].cascade and tmcnt[num + 1].enable:
    counter[num + 1] += 1
    if counter[num + 1] == 0: timer.overflowProcs[num + 1]()

  # Handle APU FIFO sample output and DMA refills
  timer.gba.apu.timerOverflow(num)
  timer.gba.apu.checkFifoRefill(num)

  if tmcnt[num].irq:
    case num:
    of 0: timer.gba.interrupts.regIf.timer0 = true
    of 1: timer.gba.interrupts.regIf.timer1 = true
    of 2: timer.gba.interrupts.regIf.timer2 = true
    of 3: timer.gba.interrupts.regIf.timer3 = true
    else: quit "Bad timer number. Impossible case."
    timer.gba.interrupts.scheduleCheck()
  if not tmcnt[num].cascade:
    scheduleTimer(timer, num))

proc getCurrentCounter(timer: Timer, num: SomeInteger): uint16 =
  result = counter[num]
  if tmcnt[num].enable and not tmcnt[num].cascade:
    let cycles = timer.gba.scheduler.cycles - cycleEnabled[num]
    result += uint16(cycles div periods[tmcnt[num].freq])

proc updateCounter(timer: Timer, num: SomeInteger) =
  counter[num] = getCurrentCounter(timer, num)
  cycleEnabled[num] = timer.gba.scheduler.cycles # todo: some precision is lost

proc `[]`*(timer: Timer, address: SomeInteger): uint8 =
  let
    num = (address - 0x100) div 4
    val16 = if not address.bit(1): getCurrentCounter(timer, num)
            else:                  tmcnt[num]
  read(val16, address and 1)

proc `[]=`*(timer: Timer, address: SomeInteger, value: uint8) =
  let num = (address - 0x100) div 4
  if not address.bit(1): # reload
    write(reload[num], value, address and 1)
  elif not address.bit(0): # control (top 8 bits aren't used)
    updateCounter(timer, num)
    let
      wasEnabled = tmcnt[num].enable
      wasCascade = tmcnt[num].cascade
    write(tmcnt[num], value, 0) # all writes are to byte 0
    if tmcnt[num].enable:
      if tmcnt[num].cascade: # timer is a cascade, stop counting
        timer.gba.scheduler.clear(events[num])
      elif not wasEnabled or wasCascade: # timer enabled or cascade disabled
        if not wasEnabled: counter[num] = reload[num]
        scheduleTimer(timer, num)
    elif wasEnabled: # disabled, clear scheduler
      timer.gba.scheduler.clear(events[num])
