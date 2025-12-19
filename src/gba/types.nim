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
    channel1*: RootRef  # Will be Channel1 from apu/channel1.nim
    channel2*: RootRef  # Will be Channel2 from apu/channel2.nim
    channel3*: RootRef  # Will be Channel3 from apu/channel3.nim
    channel4*: RootRef  # Will be Channel4 from apu/channel4.nim
    fifoA*: RootRef     # Will be FIFOChannel from apu/fifo.nim
    fifoB*: RootRef     # Will be FIFOChannel from apu/fifo.nim
    # Control registers
    psgVolumeLeft*: int
    psgVolumeRight*: int
    psgVolume*: int
    psgMasterEnable*: bool
    soundBias*: uint16

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
    storage*: Storage
    romPath*: string
    dirty*: bool

  StorageType* = enum
    None
    SRAM
    Flash64
    Flash128
    EEPROM

  Storage* = ref object of RootObj
    dirty*: bool

  SRAMStorage* = ref object of Storage
    memory*: array[0x8000, uint8]  # 32KB

  FlashStorage* = ref object of Storage
    memory*: seq[uint8]  # 64KB or 128KB
    state*: FlashState
    bank*: uint8
    is128k*: bool

  FlashState* = enum
    FlashReady
    FlashCmd1
    FlashCmd2
    FlashIdentification
    FlashPrepareWrite
    FlashPrepareErase
    FlashSetBank

  EEPROMStorage* = ref object of Storage
    memory*: seq[uint8]
    addressBits*: int  # 6 for 4K, 14 for 64K
    buffer*: uint64
    bufferSize*: int
    state*: EEPROMState
    address*: uint16
    readBits*: int
    writeBits*: int

  EEPROMState* = enum
    EEPROMReady
    EEPROMAddress
    EEPROMRead
    EEPROMWrite

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
    regIe*: INTERRUPT
    regIf*: INTERRUPT

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
    saveWrite

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
