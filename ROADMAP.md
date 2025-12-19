# GBA Emulator Enhancement Roadmap

## Overview
This roadmap details the plan to bring the Nim GBA emulator to feature parity with the Crystal "crab" reference implementation at https://github.com/mattrbeck/crab.

**Current Status**: ~65-70% complete
**Target Status**: ~95% complete (matching Crystal reference)

## Gap Analysis

### Components Comparison

| Component | Nim Status | Crystal Status | Gap |
|-----------|------------|----------------|-----|
| CPU Core | 95% ✓ | 95% ✓ | Minor edge cases |
| ARM Instructions | 95% ✓ | 95% ✓ | None |
| Thumb Instructions | 95% ✓ | 95% ✓ | None |
| Memory Bus | 100% ✓ | 100% ✓ | None |
| PPU - Basic Modes | 60% | 100% | Affine, blending, windowing |
| PPU - Mode 0 | ✓ | ✓ | None |
| PPU - Mode 1 | Partial | ✓ | Affine background |
| PPU - Mode 2 | ✗ | ✓ | Complete mode |
| PPU - Mode 3 | ✓ | ✓ | None |
| PPU - Mode 4 | ✓ | ✓ | None |
| PPU - Mode 5 | ✗ | ✓ | Complete mode |
| PPU - Affine Sprites | ✗ | ✓ | Complete feature |
| PPU - Blending | ✗ | ✓ | Complete feature |
| PPU - Windowing | ✗ | ✓ | Complete feature |
| PPU - Mosaic | ✗ | ✗ | N/A (not in Crystal) |
| APU - PSG Channels | 10% | 100% | All 4 channels |
| APU - Direct Sound | ✗ | ✓ | Both FIFO channels |
| DMA | 85% | 100% | FIFO audio mode |
| Timers | 95% ✓ | 100% ✓ | Minor |
| Interrupts | 100% ✓ | 100% ✓ | None |
| Scheduler | 100% ✓ | 100% ✓ | None |
| Input/Keypad | 100% ✓ | 100% ✓ | None |
| Save - SRAM | ✗ | ✓ | Complete implementation |
| Save - Flash | ✗ | ✓ | Complete implementation |
| Save - EEPROM | ✗ | ✓ | Complete implementation |
| Serial | 5% | 5% | N/A (neither impl) |
| RTC/GPIO | ✗ | ✓ | Optional feature |
| Waitloop Detection | ✗ | ✓ | Performance feature |

### Critical Missing Features
1. **PPU Advanced Features** (30% of remaining work)
   - Affine transformations for backgrounds
   - Affine transformations for sprites
   - Alpha blending (3 modes)
   - Windowing (3 window types)
   - Background modes 2 and 5

2. **APU Complete Implementation** (35% of remaining work)
   - PSG channels 1-4 (sweep, square, wave, noise)
   - Direct Sound FIFO channels A & B
   - Frame sequencer
   - Proper mixing and synchronization

3. **Save Game Support** (25% of remaining work)
   - SRAM (32KB battery-backed RAM)
   - Flash (64KB/128KB with state machine)
   - EEPROM (4K/64K with serial protocol)
   - Auto-detection and file I/O

4. **DMA Audio Mode** (5% of remaining work)
   - FIFO refill integration with APU

5. **Optional Features** (5% of remaining work)
   - RTC/GPIO for specific cartridges
   - Waitloop detection for performance

## Implementation Phases

### Phase 1: Save Game Support (CRITICAL)
**Priority**: HIGH - Required for most games to be playable
**Estimated Complexity**: Medium
**Files to Create/Modify**: `src/gba/storage/sram.nim`, `flash.nim`, `eeprom.nim`

**Tasks**:
1. Create storage module structure
2. Implement SRAM (simplest)
3. Implement Flash with state machine
4. Implement EEPROM with serial protocol
5. Add auto-detection logic
6. Integrate with bus read/write
7. Add periodic save to disk

**Reference Files**:
- `/tmp/crab/src/crab/gba/storage/sram.cr`
- `/tmp/crab/src/crab/gba/storage/flash.cr`
- `/tmp/crab/src/crab/gba/storage/eeprom.cr`

### Phase 2: APU Complete Implementation (HIGH IMPACT)
**Priority**: HIGH - Major missing feature
**Estimated Complexity**: High
**Files to Modify**: `src/gba/apu.nim` + new channel files

**Tasks**:
1. Implement PSG Channel 1 (sweep + square wave)
2. Implement PSG Channel 2 (square wave)
3. Implement PSG Channel 3 (wave RAM)
4. Implement PSG Channel 4 (noise)
5. Implement frame sequencer (512 Hz)
6. Implement Direct Sound FIFO channels A & B
7. Implement proper sample mixing
8. Add APU register mappings
9. Integrate with timer system
10. Add audio synchronization

**Reference Files**:
- `/tmp/crab/src/crab/gba/apu.cr`
- `/tmp/crab/src/crab/gba/apu/*.cr` (channel implementations)

### Phase 3: PPU Affine Transformations
**Priority**: HIGH - Required for many games
**Estimated Complexity**: Medium-High
**Files to Modify**: `src/gba/ppu.nim`

**Tasks**:
1. Add affine background rendering (modes 1-2)
2. Add affine sprite transformations
3. Implement rotation matrix math (PA, PB, PC, PD)
4. Add double-size sprite mode
5. Complete background mode 2
6. Add background mode 5 (bitmap affine)
7. Test with affine-heavy games

**Reference Files**:
- `/tmp/crab/src/crab/gba/ppu.cr` (affine methods)

### Phase 4: PPU Blending Effects
**Priority**: MEDIUM - Visual polish for many games
**Estimated Complexity**: Medium
**Files to Modify**: `src/gba/ppu.nim`

**Tasks**:
1. Implement blend target selection (1st/2nd target)
2. Add alpha blending mode (EVA/EVB coefficients)
3. Add brightness increase mode (EVY coefficient)
4. Add brightness decrease mode (EVY coefficient)
5. Integrate with layer compositing
6. Add BLDCNT register handling
7. Add BLDALPHA and BLDY register handling

**Reference Files**:
- `/tmp/crab/src/crab/gba/ppu.cr` (blend methods)

### Phase 5: PPU Windowing
**Priority**: MEDIUM - Required for some games
**Estimated Complexity**: Medium
**Files to Modify**: `src/gba/ppu.nim`

**Tasks**:
1. Implement Window 0 bounds checking
2. Implement Window 1 bounds checking
3. Implement Object Window (sprite-based)
4. Add window control registers (WININ, WINOUT)
5. Add window enable bits per layer
6. Integrate with rendering pipeline
7. Add window bounds registers (WIN0H, WIN0V, WIN1H, WIN1V)

**Reference Files**:
- `/tmp/crab/src/crab/gba/ppu.cr` (window methods)

### Phase 6: DMA Audio Mode
**Priority**: MEDIUM - Needed for APU to work properly
**Estimated Complexity**: Low
**Files to Modify**: `src/gba/dma.nim`

**Tasks**:
1. Add FIFO special timing mode
2. Integrate with APU FIFO buffers
3. Add automatic 4-word transfers
4. Test with audio-heavy games

**Reference Files**:
- `/tmp/crab/src/crab/gba/dma.cr`

### Phase 7: Optional Enhancements
**Priority**: LOW - Nice to have
**Estimated Complexity**: Varies

**Tasks**:
1. **RTC/GPIO Support**:
   - Add GPIO module
   - Add RTC state machine
   - Integrate with specific cartridges

2. **Waitloop Detection**:
   - Add instruction analysis
   - Implement loop detection cache
   - Add fast-forward capability

3. **CPU Edge Cases**:
   - Review test suite results
   - Fix any failing edge cases

**Reference Files**:
- `/tmp/crab/src/crab/gba/gpio.cr`
- `/tmp/crab/src/crab/gba/rtc.cr`
- `/tmp/crab/src/crab/gba/waitloop.cr`

## Implementation Strategy

### For Each Phase:
1. **Study Reference**: Read Crystal implementation thoroughly
2. **Design**: Plan Nim equivalent structures
3. **Implement Core**: Write minimal working version
4. **Test**: Verify basic functionality
5. **Refine**: Add edge cases and polish
6. **Integrate**: Connect with existing systems
7. **Commit**: Make atomic git commit with clear message

### Code Translation Guidelines:
- **Crystal → Nim equivalents**:
  - `getter/setter` → proc or field access
  - `@[AlwaysInline]` → `{.inline.}`
  - Macros → Nim template/macro
  - `bit(n)` → `1 shl n`
  - `[]` indexing → `[]` indexing (same)
  - Classes → `ref object`

### Testing Strategy:
- Test each component independently before integration
- Use existing test ROMs where available
- Verify against known-good games
- Check for regressions in already-working games

## Success Metrics

### After Phase 1 (Saves):
- Games can save/load progress
- All three save types work
- Save files compatible with other emulators

### After Phase 2 (APU):
- Full sound output on all games
- Music and sound effects working
- Audio synchronized with video

### After Phase 3 (Affine):
- Games using Mode 7-style effects work
- Rotating/scaling backgrounds render correctly
- Affine sprites work (Super Mario Advance, etc.)

### After Phase 4-5 (Blending/Windows):
- Visual effects render correctly
- Transparency effects work
- Games look accurate to hardware

### After Phase 6 (DMA Audio):
- No audio gaps or glitches
- DMA-based audio timing correct

### After All Phases:
- **Target Game Compatibility**: 85-90% of GBA library
- **Passes Test Suites**: gba-suite, armwrestler
- **Playable Games**: All major titles at full speed

## Estimated Total Work

| Phase | Complexity | Est. Lines | Priority |
|-------|------------|------------|----------|
| Phase 1: Saves | Medium | ~400 | CRITICAL |
| Phase 2: APU | High | ~600 | HIGH |
| Phase 3: Affine | Medium-High | ~300 | HIGH |
| Phase 4: Blending | Medium | ~200 | MEDIUM |
| Phase 5: Windowing | Medium | ~200 | MEDIUM |
| Phase 6: DMA Audio | Low | ~50 | MEDIUM |
| Phase 7: Optional | Varies | ~300 | LOW |
| **TOTAL** | - | **~2,050** | - |

Current codebase: ~2,500 lines
After completion: ~4,550 lines (similar to Crystal's ~7,836 with shared GB code removed)

## Next Steps

1. Begin Phase 1 (Save Game Support)
2. Implement SRAM, Flash, EEPROM
3. Test with games that use each save type
4. Commit atomic changes
5. Move to Phase 2 (APU)
6. Continue through phases systematically

This roadmap prioritizes features by impact on game compatibility and playability, focusing on critical missing features first before adding polish and optional enhancements.
