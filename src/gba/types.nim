import heapqueue

import display, regs

type
  GBA* = ref object
    bus*: Bus
    display*: Display
    apu*: APU
    cpu*: CPU
    ppu*: PPU
    keypad*: Keypad
    interrupts*: Interrupts
    timer*: Timer
    dma*: DMA
    serial*: Serial
    scheduler*: Scheduler

  APU* = ref object
    gba*: GBA
    channel1*: Channel

  Channel* = ref object of RootObj
    scheduler*: Scheduler

  Bus* = ref object
    gba*: GBA
    bios*: array[0x4000, uint8]
    iwram*: array[0x40000, uint8]
    ewram*: array[0x08000, uint8]
    rom*: array[0x02000000, uint8]
    mmio*: MMIO
    save*: Save

  MMIO* = ref object
    gba*: GBA

  Save* = ref object
    gba*: GBA

  CPU* = ref object
    gba*: GBA
    r*: array[16, uint32]
    cpsr*: PSR
    spsr*: PSR
    halted*: bool
    interrupt*: proc(cpu: var CPU)

  PPU* = ref object
    gba*: GBA
    pram*: array[0x400, uint8]
    vram*: array[0x18000, uint8]
    oam*: array[0x400, uint8]

  Keypad* = ref object
    gba*: GBA

  Interrupts* = ref object
    gba*: GBA
    ime*: bool
    regIe*: InterruptFlags
    regIf*: InterruptFlags

  Timer* = ref object
    gba*: GBA
    overflowProcs*: array[4, proc()]

  DMA* = ref object
    gba*: GBA

  Serial* = ref object
    gba*: GBA

  Scheduler* = ref object
    events*: HeapQueue[Event]
    cycles*: uint64
    nextEvent*: uint64

  Event* = object
    cycles*: uint64
    callback*: proc()
    eventType*: EventType

  EventType* = enum
    default
    ppu
    apu
    apuChannel1
    apuChannel2
    apuChannel3
    apuChannel4
    timer0
    timer1
    timer2
    timer3
    interrupt

  Mode* = enum
    usr = 0b10000
    fiq = 0b10001
    irq = 0b10010
    svc = 0b10011
    abt = 0b10111
    und = 0b11011
    sys = 0b11111

  PSR* = object
    mode* {.bitsize:5.}: Mode
    thumb* {.bitsize:1.}: bool
    fiqDisable* {.bitsize:1.}: bool
    irqDisable* {.bitsize:1.}: bool
    reserved* {.bitsize:20.}: cuint
    overflow*{.bitsize:1.}: bool
    carry* {.bitsize:1.}: bool
    zero* {.bitsize:1.}: bool
    negative* {.bitsize:1.}: bool

converter toU32*(psr: PSR): uint32 = cast[uint32](psr)
converter toPsr*(u32: uint32): PSR = cast[PSR](u32)
