import bitops, strutils

import types, util, display, interrupts, regs, scheduler

using ppu: PPU

const
  width = 240
  height = 160

type
  Buffer[width, height: static int, T] = array[width * height, T]
  FrameBuffer = Buffer[width, height, uint16]
  Scanline = array[width, uint16]
  SpritePixel = object # metadata about a sprite at a pixel
    priority: uint16
    palette: uint16
    blends: bool
    window: bool
  Sprite* {.packed.} = object
    # attr0
    top {.bitsize:8.}: cuint
    objMode {.bitsize:2.}: ObjMode
    gfxMode {.bitsize:2.}: GfxMode
    mosaic {.bitsize:1.}: bool
    colorMode {.bitsize:1.}: ColorMode
    shape {.bitsize:2.}: SpriteShape
    # attr1
    left {.bitsize:9.}: cuint
    affineIdx {.bitsize:5.}: cuint
    size {.bitsize:2.}: cuint
    # attr2
    baseTileIdx {.bitsize:10.}: cuint
    priority {.bitsize:2.}: cuint
    paletteBank {.bitsize:4.}: cuint
    # buffer for affine params, which are interlaced in oam
    affineBuffer {.bitsize:16.}: cuint
  ObjMode = enum
    normal, affine, disabled, double
  GfxMode = enum
    none, blend, window, forbiddenMode
  ColorMode = enum
    fourBpp, eightBpp
  SpriteShape = enum
    square, wide, tall, forbiddenShape

const
  spriteSizes: array[SpriteShape, array[4, tuple[width, height: uint]]] = [
    square: [(8'u, 8'u), (16'u, 16'u), (32'u, 32'u), (64'u, 64'u)],
    wide: [(16'u, 8'u), (32'u, 8'u), (32'u, 16'u), (64'u, 32'u)],
    tall: [(8'u, 16'u), (8'u, 32'u), (16'u, 32'u), (32'u, 64'u)],
    forbiddenShape: [(0'u, 0'u), (0'u, 0'u), (0'u, 0'u), (0'u, 0'u)]
  ]

var
  framebuffer: FrameBuffer
  layerBuffers: array[4, Scanline]
  spriteBuffer: array[width, SpritePixel]
  windowBuffer: array[width, bool]  # Tracks object window pixels

  dispcnt: DISPCNT
  greenSwap: uint16
  dispstat: DISPSTAT
  vcount: uint8
  bgcnts: array[4, BGCNT]
  bghofs: array[4, BGOFS]
  bgvofs: array[4, BGOFS]
  bgaff: array[2, array[4, uint16]]
  bgref: array[2, array[2, uint32]]
  win0h: WINBOUND
  win1h: WINBOUND
  win0v: WINBOUND
  win1v: WINBOUND
  winin: WININ
  winout: WINOUT
  mosaic: MOSAIC
  bldcnt: BLDCNT
  bldalpha: BLDALPHA
  bldy: BLDY

proc startLine(ppu: PPU): proc()
proc startHblank(ppu: PPU): proc()
proc endHblank(ppu: PPU): proc()

proc newPPU*(gba: GBA): PPU =
  new result
  result.gba = gba
  result.startLine()()

proc isBitmap*(): bool = dispcnt.mode >= 3

# from tonc https://www.coranac.com/tonc/text/regbg.htm
proc seIndex(tileX, tileY, screenSize: SomeInteger): SomeInteger =
  result = tileX + tileY * 32
  if tileX >= 32: result += 0x03E0
  if tileY >= 32 and screenSize == 0b11: result += 0x0400

proc hFlip(sprite: Sprite): bool = bit(sprite.affineIdx, 3)
proc vFlip(sprite: Sprite): bool = bit(sprite.affineIdx, 4)

proc renderTextLayer(ppu; layer: SomeInteger) =
  if not dispcnt.controlBits.bit(layer): return
  let
    bgcnt = bgcnts[layer]
    bghof = bghofs[layer].offset
    bgvof = bgvofs[layer].offset
    screenBase = bgcnt.screenBase * 0x800
    charBase = bgcnt.charBase * 0x4000
    (bgWidth, bgHeight) = case bgcnt.screenSize
      of 0: (0x100'u32, 0x100'u32) # 32x32 tiles
      of 1: (0x200'u32, 0x100'u32) # 64x32 tiles
      of 2: (0x100'u32, 0x200'u32) # 32x64 tiles
      of 3: (0x200'u32, 0x200'u32) # 64x64 tiles
      else: quit "Invalid bgcnt screensize " & $bgcnt.screenSize
    effectiveY = (vcount.uint32 + bgvof) mod bgHeight
    tileY = effectiveY shr 3
  for col in 0'u32 ..< width.uint32:
    let
      effectiveX = (col + bghof) mod bgWidth
      tileX = effectiveX shr 3
      screenEntry = read[uint16](ppu.vram, screenBase, seIndex(tileX, tileY, bgcnt.screenSize))
      tileId = screenEntry.bitsliced(0..9)
      x = (effectiveX and 7) xor (7 * screenEntry.bitsliced(10..10))
      y = (effectiveY and 7) xor (7 * screenEntry.bitsliced(11..11))
    var paletteIndex: uint16
    if bgcnt.colorMode:  # 8bpp (256 color)
      paletteIndex = ppu.vram[charBase + tileId * 0x40 + y * 8 + x].uint16
    else:  # 4bpp (16 color with palette banking)
      let paletteBank = screenEntry.bitsliced(12..15).uint8
      paletteIndex = (ppu.vram[charBase + tileId * 0x20 + y * 4 + (x shr 1)] shr ((x and 1) * 4)) and 0xF
      if paletteIndex > 0: paletteIndex += paletteBank shl 4
    layerBuffers[layer][col] = paletteIndex

proc renderAffineLayer(ppu; layer: SomeInteger) =
  if not dispcnt.controlBits.bit(layer): return
  let
    bgcnt = bgcnts[layer]
    affIdx = layer - 2  # BG2 uses aff[0], BG3 uses aff[1]

    # Get affine parameters (signed 8.8 fixed-point)
    pa = cast[int16](bgaff[affIdx][0]).int32
    pb = cast[int16](bgaff[affIdx][1]).int32
    pc = cast[int16](bgaff[affIdx][2]).int32
    pd = cast[int16](bgaff[affIdx][3]).int32

    # Get reference points (signed 28.8 fixed-point)
    refX = cast[int32](bgref[affIdx][0])
    refY = cast[int32](bgref[affIdx][1])

    # Screen and character bases
    screenBase = bgcnt.screenBase * 0x800
    charBase = bgcnt.charBase * 0x4000

    # Size in tiles (always square for affine)
    sizeTiles = 16'u32 shl bgcnt.screenSize  # 16, 32, 64, 128 tiles
    sizePixels = sizeTiles shl 3  # Convert to pixels

  # Internal X/Y start at reference point for this scanline
  var
    intX = refX
    intY = refY

  for col in 0'u32 ..< width.uint32:
    # Convert from 8.8 fixed-point to pixel coordinates
    let
      x = intX shr 8
      y = intY shr 8

    # Increment by dx/dy
    intX += pa
    intY += pc

    # Check bounds (with optional wrapping)
    var inBounds = true
    var pixelX = x
    var pixelY = y

    if bgcnt.affineWrap:
      # Wrap around
      pixelX = pixelX mod sizePixels.int32
      pixelY = pixelY mod sizePixels.int32
      if pixelX < 0: pixelX += sizePixels.int32
      if pixelY < 0: pixelY += sizePixels.int32
    else:
      # Check if in bounds
      if x < 0 or x >= sizePixels.int32 or y < 0 or y >= sizePixels.int32:
        inBounds = false

    if inBounds:
      # Get tile and pixel within tile
      let
        tileX = pixelX.uint32 shr 3
        tileY = pixelY.uint32 shr 3
        tileId = ppu.vram[screenBase + tileY * sizeTiles + tileX]
        pixX = pixelX.uint32 and 7
        pixY = pixelY.uint32 and 7
        palIdx = ppu.vram[charBase + tileId.uint32 * 0x40 + pixY * 8 + pixX]

      layerBuffers[layer][col] = palIdx
    else:
      layerBuffers[layer][col] = 0

proc getPaletteIdx(ppu; sprite: Sprite, isAffine: bool, width, height, internalX, internalY: SomeInteger): uint16 =
  const spriteBase = 0x10000'u
  let widthInTiles = width shr 3
  var
    internalX = internalX
    internalY = internalY
  # Only apply hFlip/vFlip for non-affine sprites (affine sprites use those bits for affine index)
  if not isAffine:
    if sprite.hFlip(): internalX = width - internalX - 1
    if sprite.vFlip(): internalY = height - internalY - 1
  let tileX = internalX and 7
  let tileY = internalY and 7
  if sprite.colorMode == fourBpp:
    const tileWidth = 0x20'u
    let tileNum =
      if dispcnt.obj1d:
        sprite.baseTileIdx + (internalY shr 3) * widthInTiles + (internalX shr 3)
      else:
        sprite.baseTileIdx + (internalY shr 3) * 32           + (internalX shr 3)
    let bytesIntoTile = tileY * 4 + (tileX shr 1)
    let palettes = read[uint8](ppu.vram, spriteBase, tileWidth * tileNum + bytesIntoTile)
    result = (palettes shr ((tileX and 1) * 4)) and 0xF
    if result > 0: # pixel isn't transparent
      result = result + (sprite.paletteBank.uint16 shl 4) # adjust for bank
  else: # eightBpp
    const tileWidth = 0x40'u  # 8bpp tiles are twice as large (64 bytes vs 32 bytes)
    var tileNum = (sprite.baseTileIdx shr 1).uint32  # Tile ID is divided by 2 for 8bpp
    tileNum =
      if dispcnt.obj1d:
        tileNum + (internalY shr 3).uint32 * widthInTiles.uint32 + (internalX shr 3).uint32
      else:
        tileNum + (internalY shr 3).uint32 * 32                   + (internalX shr 3).uint32
    let bytesIntoTile = (tileY * 8 + tileX).uint32  # 8 bytes per row (8 pixels * 1 byte each)
    result = read[uint8](ppu.vram, spriteBase, tileWidth * tileNum + bytesIntoTile).uint16

proc renderSprites(ppu) =
  if not dispcnt.controlBits.bit(4): return
  let sprites = cast[array[128, Sprite]](ppu.oam)
  for idx, sprite in sprites:
    if sprite.objMode == disabled: continue
    if sprite.gfxMode == forbiddenMode: continue
    if sprite.shape == forbiddenShape: continue
    var (width, height) = spriteSizes[sprite.shape][sprite.size]
    let (origWidth, origHeight) = (width, height)

    # Get affine parameters if needed
    var pa, pb, pc, pd: int32
    if sprite.objMode == affine or sprite.objMode == double:
      # Read affine parameters from OAM
      let affIdx = sprite.affineIdx.int * 4
      pa = cast[int16](sprites[affIdx].affineBuffer).int32
      pb = cast[int16](sprites[affIdx + 1].affineBuffer).int32
      pc = cast[int16](sprites[affIdx + 2].affineBuffer).int32
      pd = cast[int16](sprites[affIdx + 3].affineBuffer).int32

      # Double-size mode doubles the sprite bounding box
      if sprite.objMode == double:
        width = width * 2
        height = height * 2
    else:
      # Identity matrix for non-affine sprites
      pa = 0x100
      pb = 0
      pc = 0
      pd = 0x100

    # Handle Y coordinate wrapping: Y values 0-255 can wrap around the 160-line screen
    # Treat Y >= 160 as negative offsets (e.g., Y=240 is -16)
    let spriteY = if sprite.top >= 160: sprite.top.int32 - 256 else: sprite.top.int32
    let spriteBottom = spriteY + height.int32

    # Check if current scanline intersects with sprite
    if vcount.int32 >= spriteY and vcount.int32 < spriteBottom:
      let internalY = (vcount.int32 - spriteY)
      for screenX in max(0'u, sprite.left) ..< min(240'u, sprite.left + width.uint):
        let internalX = (screenX - sprite.left).int32

        var texX, texY: int32
        if sprite.objMode == affine or sprite.objMode == double:
          # Transform from sprite space to texture space
          let
            ix = internalX - (width.int32 div 2)
            iy = internalY - (height.int32 div 2)
          texX = ((pa * ix + pb * iy) shr 8) + (origWidth.int32 div 2)
          texY = ((pc * ix + pd * iy) shr 8) + (origHeight.int32 div 2)
        else:
          texX = internalX
          texY = internalY

        # Check if transformed coordinate is in bounds
        if texX < 0 or texX >= origWidth.int32 or texY < 0 or texY >= origHeight.int32:
          continue

        # Handle object window mode
        let isAffine = sprite.objMode == affine or sprite.objMode == double
        if sprite.gfxMode == window:
          let palette = ppu.getPaletteIdx(sprite, isAffine, origWidth, origHeight, texX.uint, texY.uint)
          if palette > 0:
            windowBuffer[screenX] = true
        else:
          let spritePixel = SpritePixel(
            priority: sprite.priority.uint16,
            palette: ppu.getPaletteIdx(sprite, isAffine, origWidth, origHeight, texX.uint, texY.uint),
            blends: sprite.gfxMode == blend,
            window: false
          )
          let existing = spriteBuffer[screenX]
          if spritePixel.priority < existing.priority or existing.palette == 0:
            spriteBuffer[screenX] = spritePixel

proc blendColors(top, bot: uint16, eva, evb: int): uint16 =
  # Extract RGB components from BGR555 format
  let
    topR = (top and 0x1F).int
    topG = ((top shr 5) and 0x1F).int
    topB = ((top shr 10) and 0x1F).int
    botR = (bot and 0x1F).int
    botG = ((bot shr 5) and 0x1F).int
    botB = ((bot shr 10) and 0x1F).int

  # Apply blending formula: (top * EVA + bot * EVB) / 16
  let
    blendR = min(31, (topR * eva + botR * evb) shr 4)
    blendG = min(31, (topG * eva + botG * evb) shr 4)
    blendB = min(31, (topB * eva + botB * evb) shr 4)

  # Repack to BGR555
  result = blendR.uint16 or (blendG.uint16 shl 5) or (blendB.uint16 shl 10)

proc brightenColor(color: uint16, evy: int): uint16 =
  # Extract RGB components
  let
    r = (color and 0x1F).int
    g = ((color shr 5) and 0x1F).int
    b = ((color shr 10) and 0x1F).int

  # Apply brightness increase: color + (white - color) * EVY / 16
  let
    brightR = r + (((31 - r) * evy) shr 4)
    brightG = g + (((31 - g) * evy) shr 4)
    brightB = b + (((31 - b) * evy) shr 4)

  # Repack to BGR555
  result = brightR.uint16 or (brightG.uint16 shl 5) or (brightB.uint16 shl 10)

proc darkenColor(color: uint16, evy: int): uint16 =
  # Extract RGB components
  let
    r = (color and 0x1F).int
    g = ((color shr 5) and 0x1F).int
    b = ((color shr 10) and 0x1F).int

  # Apply brightness decrease: color - color * EVY / 16
  let
    darkR = r - ((r * evy) shr 4)
    darkG = g - ((g * evy) shr 4)
    darkB = b - ((b * evy) shr 4)

  # Repack to BGR555
  result = darkR.uint16 or (darkG.uint16 shl 5) or (darkB.uint16 shl 10)

proc isFirstTarget(layer: int, isSprite: bool): bool =
  if isSprite:
    return bldcnt.objFirst
  else:
    case layer
    of 0: return bldcnt.bg0First
    of 1: return bldcnt.bg1First
    of 2: return bldcnt.bg2First
    of 3: return bldcnt.bg3First
    else: return false

proc isSecondTarget(layer: int, isSprite: bool): bool =
  if isSprite:
    return bldcnt.objSecond
  else:
    case layer
    of 0: return bldcnt.bg0Second
    of 1: return bldcnt.bg1Second
    of 2: return bldcnt.bg2Second
    of 3: return bldcnt.bg3Second
    else: return false

proc inWindowBounds(x, y: int, horizontal, vertical: WINBOUND): bool =
  # Window bounds can wrap around screen edges
  let
    x1 = horizontal.startPos.int
    x2 = horizontal.endPos.int
    y1 = vertical.startPos.int
    y2 = vertical.endPos.int
    inX = if x2 >= x1: (x >= x1 and x < x2) else: (x >= x1 or x < x2)
    inY = if y2 >= y1: (y >= y1 and y < y2) else: (y >= y1 or y < y2)
  result = inX and inY

proc getWindowEnables(col: int): tuple[enableBits: uint8, effectsEnabled: bool] =
  # Check windows in priority order: WIN0 -> WIN1 -> OBJ -> OUT

  # Window 0
  if dispcnt.window0 and inWindowBounds(col, vcount.int, win0h, win0v):
    return (winin.win0enable.uint8, winin.win0effects)

  # Window 1
  if dispcnt.window1 and inWindowBounds(col, vcount.int, win1h, win1v):
    return (winin.win1enable.uint8, winin.win1effects)

  # Object window
  if dispcnt.windowObj and windowBuffer[col]:
    return (winout.winObjEnable.uint8, winout.winObjEffects)

  # Outside windows (if any window is enabled)
  if dispcnt.window0 or dispcnt.window1 or dispcnt.windowObj:
    return (winout.winOutEnable.uint8, winout.winOutEffects)

  # No windows - all layers enabled
  return (0x1F'u8, true)  # All 5 layers (BG0-3 + OBJ) enabled

proc calculateColor(pram: array[0x400, uint8], col: SomeInteger, enableBits: uint8, effectsEnabled: bool): uint16 =
  let spritePixel = spriteBuffer[col]
  let
    objEnabled = enableBits.bit(4)
    bg0Enabled = enableBits.bit(0)
    bg1Enabled = enableBits.bit(1)
    bg2Enabled = enableBits.bit(2)
    bg3Enabled = enableBits.bit(3)
  var
    topColor: uint16 = 0
    botColor: uint16 = 0
    topIsFirst = false
    topIsSprite = false
    foundTop = false
    foundBot = false

  # Find top and bottom layers for blending (respecting window enables)
  for priority in 0'u32 ..< 4'u32:
    if objEnabled and spritePixel.priority == priority and spritePixel.palette > 0:
      let color = read[uint16](pram, 0x200'u16, spritePixel.palette)
      if not foundTop:
        topColor = color
        topIsFirst = isFirstTarget(0, true) or spritePixel.blends
        topIsSprite = true
        foundTop = true
        if bldcnt.effect == none or not effectsEnabled or (not topIsFirst and not spritePixel.blends):
          return topColor
      elif not foundBot and effectsEnabled and (topIsFirst or (topIsSprite and spritePixel.blends)) and isSecondTarget(0, true):
        botColor = color
        foundBot = true
        break

    for layer in 0 ..< 4:
      let bgcnt = bgcnts[layer]
      let layerEnabled = case layer
        of 0: bg0Enabled
        of 1: bg1Enabled
        of 2: bg2Enabled
        of 3: bg3Enabled
        else: false

      if layerEnabled and bgcnt.priority == priority:
        let palette = layerBuffers[layer][col]
        if palette > 0:
          let color = read[uint16](pram, 0'u16, palette)
          if not foundTop:
            topColor = color
            topIsFirst = isFirstTarget(layer, false)
            topIsSprite = false
            foundTop = true
            if bldcnt.effect == none or not effectsEnabled or not topIsFirst:
              return topColor
          elif not foundBot and effectsEnabled and topIsFirst and isSecondTarget(layer, false):
            botColor = color
            foundBot = true
            break

  # Check if backdrop is the second target (palette index 0)
  if foundTop and topIsFirst and effectsEnabled and not foundBot and bldcnt.bdSecond:
    botColor = read[uint16](pram, 0'u16, 0)
    foundBot = true

  # Apply blending if we found a top layer that's a first target and effects are enabled
  if foundTop and topIsFirst and effectsEnabled:
    case bldcnt.effect
    of blend:
      if foundBot:
        # Alpha blend between top and bottom
        let eva = min(16, bldalpha.eva.int)
        let evb = min(16, bldalpha.evb.int)
        return blendColors(topColor, botColor, eva, evb)
      else:
        return topColor
    of bright:
      # Brightness increase
      let evy = min(16, bldy.evy.int)
      return brightenColor(topColor, evy)
    of dark:
      # Brightness decrease
      let evy = min(16, bldy.evy.int)
      return darkenColor(topColor, evy)
    of none:
      return topColor

  # If no layer found, return backdrop color
  if not foundTop:
    return read[uint16](pram, 0'u16, 0)

  return topColor

proc composite(pram: array[0x400, uint8], scanline: ptr Scanline) =
  for col in 0 ..< width:
    let (enableBits, effectsEnabled) = getWindowEnables(col)
    scanline[col] = calculateColor(pram, col, enableBits, effectsEnabled)

proc getLine(buffer: var FrameBuffer, row: SomeInteger): ptr Scanline =
  result = cast[ptr array[buffer.width, buffer.T]](addr buffer[buffer.width * row])
  for pixel in result[].mitems: pixel = 0

proc draw(ppu: PPU) =
  ppu.gba.display.draw(framebuffer)

proc scanline(ppu: PPU) =
  let
    row = int(vcount)
    rowBase = row * width
  var scanline = framebuffer.getLine(row)
  for col in 0 ..< width:
    spriteBuffer[col] = SpritePixel(priority: 4)
    windowBuffer[col] = false
  for layer in 0 ..< 4:
    for pixel in layerBuffers[layer].mitems:
      pixel = 0
  case dispcnt.mode
  of 0:
    # Mode 0: 4 text backgrounds
    for layer in 0 ..< 4:
      ppu.renderTextLayer(layer)
    ppu.renderSprites()
    composite(ppu.pram, scanline)
  of 1:
    # Mode 1: 2 text backgrounds + 1 affine background
    ppu.renderTextLayer(0)
    ppu.renderTextLayer(1)
    ppu.renderAffineLayer(2)
    ppu.renderSprites()
    composite(ppu.pram, scanline)
  of 2:
    # Mode 2: 2 affine backgrounds
    ppu.renderAffineLayer(2)
    ppu.renderAffineLayer(3)
    ppu.renderSprites()
    composite(ppu.pram, scanline)
  of 3:
    # Mode 3: 240x160 16-bit bitmap
    for col in 0 ..< width:
      scanline[col] = cast[ptr FrameBuffer](addr ppu.vram)[rowBase + col]
  of 4:
    # Mode 4: 240x160 8-bit indexed bitmap
    let base = if dispcnt.page: 0xA000 else: 0
    for col in 0 ..< width:
      let palIdx = ppu.vram[base + rowBase + col]
      scanline[col] = cast[ptr FrameBuffer](addr ppu.pram)[palIdx]
  of 5:
    # Mode 5: 160x128 16-bit bitmap
    if vcount < 128:
      let base = if dispcnt.page: 0xA000 else: 0
      for col in 0 ..< 160:
        scanline[col] = cast[ptr FrameBuffer](addr ppu.vram)[base div 2 + row * 160 + col]
      for col in 160 ..< width:
        scanline[col] = 0
    else:
      for col in 0 ..< width:
        scanline[col] = 0
  else: echo "Unsupported background mode " & $dispcnt.mode

proc startLine(ppu: PPU): proc() = (proc() =
  ppu.gba.scheduler.schedule(960, startHblank(ppu), EventType.ppu))

proc startHblank(ppu: PPU): proc() = (proc() =
  dispstat.hblank = true
  if dispstat.hblankEnable:
    ppu.gba.interrupts.regIf.hblank = true
    ppu.gba.interrupts.scheduleCheck()
  if vcount < height: ppu.scanline()
  ppu.gba.scheduler.schedule(272, endHblank(ppu), EventType.ppu))

proc endHblank(ppu: PPU): proc() = (proc() =
  dispstat.hblank = false
  vcount = (vcount + 1) mod 228
  dispstat.vcount = dispstat.vcountTarget == vcount
  if dispstat.vcountEnable and dispstat.vcount: ppu.gba.interrupts.regIf.vcount = true
  if vcount == 0:
    dispstat.vblank = false
  elif vcount == height:
    dispstat.vblank = true
    if dispstat.vblankEnable: ppu.gba.interrupts.regIf.vblank = true
    ppu.draw()
  ppu.gba.interrupts.scheduleCheck()
  ppu.gba.scheduler.schedule(0, startLine(ppu), EventType.ppu))

proc `[]`*(ppu: PPU, address: SomeInteger): uint8 =
  case address:
  of 0x00..0x01: read(dispcnt, address and 1)
  of 0x02..0x03: read(greenSwap, address and 1)
  of 0x04..0x05: read(dispstat, address and 1)
  of 0x06..0x07: (if address.bit(0): 0'u8 else: vcount)
  of 0x08..0x0F: read(bgcnts[(address - 0x08) div 2], address and 1)
  of 0x10..0x1F:
    let layer = (address - 0x10) div 4
    if address.bit(1): read(bgvofs[layer], address and 1)
    else:              read(bghofs[layer], address and 1)
  of 0x20..0x3F:
    let
      bgNum = (address - 0x20) div 16
      offset = address and 0xF
    if offset < 8: read(bgaff[bgNum][offset div 2], address and 1)
    else:          read(bgref[bgNum][(offset - 8) div 4], address and 3)
  of 0x40..0x41: read(win0h, address and 1)
  of 0x42..0x43: read(win1h, address and 1)
  of 0x44..0x45: read(win0v, address and 1)
  of 0x46..0x47: read(win1v, address and 1)
  of 0x48..0x49: read(winin, address and 1)
  of 0x4A..0x4B: read(winout, address and 1)
  of 0x4C..0x4D: read(mosaic, address and 1)
  of 0x50..0x51: read(bldcnt, address and 1)
  of 0x52..0x53: read(bldalpha, address and 1)
  of 0x54..0x55: read(bldy, address and 1)
  else: echo "Unmapped PPU read: " & address.toHex(4); 0

proc `[]=`*(ppu: PPU, address: SomeInteger, value: uint8) =
  case address:
  of 0x00..0x01: write(dispcnt, value, address and 1)
  of 0x02..0x03: write(greenSwap, value, address and 1)
  of 0x04..0x05: write(dispstat, value, address and 1)
  of 0x06..0x07: discard # vcount
  of 0x08..0x0F: write(bgcnts[(address - 0x08) div 2], value, address and 1)
  of 0x10..0x1F:
    let layer = (address - 0x10) div 4
    if address.bit(1): write(bgvofs[layer], value, address and 1)
    else:              write(bghofs[layer], value, address and 1)
  of 0x20..0x3F:
    let
      bgNum = (address - 0x20) div 16
      offset = address and 0xF
    if offset < 8: write(bgaff[bgNum][offset div 2], value, address and 1)
    else:          write(bgref[bgNum][(offset - 8) div 4], value, address and 3)
  of 0x40..0x41: write(win0h, value, address and 1)
  of 0x42..0x43: write(win1h, value, address and 1)
  of 0x44..0x45: write(win0v, value, address and 1)
  of 0x46..0x47: write(win1v, value, address and 1)
  of 0x48..0x49: write(winin, value, address and 1)
  of 0x4A..0x4B: write(winout, value, address and 1)
  of 0x4C..0x4D: write(mosaic, value, address and 1)
  of 0x50..0x51: write(bldcnt, value, address and 1)
  of 0x52..0x53: write(bldalpha, value, address and 1)
  of 0x54..0x55: write(bldy, value, address and 1)
  else: echo "Unmapped PPU write: ", address.toHex(8), " = ", value.toHex(2)
