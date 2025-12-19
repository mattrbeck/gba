import os
import sdl2
import times

import gba/[types, display, scheduler, bus, cpu, ppu, apu, dma, timer, serial, keypad, interrupts, util, save]

proc scheduleSaveWrite(gba: GBA) =
  # Schedule next save write (~60 times per second)
  const saveInterval = 280896'u64  # cycles between saves
  proc saveWriteCallback() =
    writeSaveFile(gba.bus.save)
    scheduleSaveWrite(gba)
  gba.scheduler.schedule(saveInterval, saveWriteCallback, saveWrite)

proc newGBA(bios, rom: string): GBA =
  new result
  result.display = newDisplay()
  result.scheduler = newScheduler()
  result.bus = newBus(result, bios, rom)
  result.cpu = newCPU(result)
  result.ppu = newPPU(result)
  result.apu = newAPU(result)
  result.dma = newDMA(result)
  result.timer = newTimer(result)
  result.serial = newSerial(result)
  result.keypad = newKeypad(result)
  result.interrupts = newInterrupts(result)
  # Start periodic save writing
  scheduleSaveWrite(result)

when defined(emscripten):
  type em_arg_callback_func = proc(data: pointer) {.cdecl.}
  proc emscripten_set_main_loop(fun: proc() {.cdecl.}, fps, simulate_infinite_loop: cint) {.header: "<emscripten.h>".}
  proc emscripten_set_main_loop_arg(fun: em_arg_callback_func, arg: pointer, fps, simulate_infinite_loop: cint) {.header: "<emscripten.h>".}
  proc emscripten_cancel_main_loop() {.header: "<emscripten.h>".}
  proc emscripten_get_now(): float {.header: "<emscripten.h>".}

var cycleCount = 0
var time: float = 0
const cyclesPerSecond = 16777216

# Return real-time number of seconds as a relative value.
proc getTime(): float =
  when defined(emscripten): emscripten_get_now() / 1000
  else: epochTime()

# Run for given number of cycles adjusted for extra cycles in previous frame.
proc runCycles(gba: GBA, cycles: int) =
  while likely(cycleCount < cycles):
    let accessCycles = gba.cpu.tick()
    gba.scheduler.tick(accessCycles)
    cycleCount += accessCycles
  cycleCount -= cycles

# Handle and pass along key input.
proc checkKeyInput(gba: GBA) =
  var event = sdl2.defaultEvent
  while pollEvent(event):
    case event.kind
    of QuitEvent: quit "quit event"
    of KeyDown, KeyUp: gba.keypad.keyEvent(cast[KeyboardEventObj](event))
    else: discard

# Run roughly one frame from the emulator, regardless of host device's
# refresh rate. After running the emulator, handle any input.
proc loop(gba: GBA) {.cdecl.} =
  let curTime = getTime()
  let elapsed = curTime - time
  time = curTime
  let cyclesToRun = int(elapsed * cyclesPerSecond)
  runCycles(gba, cyclesToRun)
  checkKeyInput(gba)

discard sdl2.init(INIT_EVERYTHING)

when defined(emscripten):
  proc initFromEmscripten() {.exportc.} =
    emscripten_cancel_main_loop() # cancel the main loop if it's running
    cycleCount = 0 # reset the cycle count
    # todo: memory is leaked when each new rom is loaded
    var gba = newGBA("bios.bin", "rom.gba")
    time = getTime()
    emscripten_set_main_loop_arg(cast[em_arg_callback_func](loop), cast[pointer](gba), -1, 1)
else:
  if paramCount() != 2: quit "Run with ./gba /path/to/bios /path/to/rom"
  var gba = newGBA(paramStr(1), paramStr(2))
  time = getTime()
  while true:
    loop(gba)
    sleepUntilEndOfFrame()
