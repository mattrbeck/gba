import strformat, times
import sdl2

const
  WIDTH* = 240
  HEIGHT* = 160
  SCALE* = 4

type
  Display* = ref object
    window: WindowPtr
    renderer: RendererPtr
    texture: TexturePtr
    microseconds: int32
    frames: int32
    lastTime: DateTime
    seconds: int

when defined(emscripten):
  proc emscripten_run_script(script: cstring) {.header: "<emscripten.h>".}

proc newDisplay*(): Display =
  new result
  result.window = createWindow("gba", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, WIDTH * SCALE, HEIGHT * SCALE, SDL_WINDOW_SHOWN)
  result.renderer = result.window.createRenderer(-1, Renderer_Accelerated)
  result.texture = result.renderer.createTexture(SDL_PIXELFORMAT_BGR555, SDL_TEXTUREACCESS_STREAMING, WIDTH, HEIGHT)
  discard result.renderer.setLogicalSize(WIDTH, HEIGHT)
  result.lastTime = now()
  result.seconds = result.lastTime.second

proc updateDrawCount(display: Display) =
  let currentTime = now()
  display.microseconds += int32((currentTime - display.lastTime).inMicroseconds())
  display.lastTime = currentTime
  display.frames += 1
  if currentTime.second != display.seconds:
    let fps = display.frames * 1_000_000 / display.microseconds
    when defined(emscripten):
      emscripten_run_script(fmt"reportFps({fps:.2f})")
    else:
      display.window.setTitle(cstring(fmt"gba - {fps:.2f}"))
    display.microseconds = 0
    display.frames = 0
    display.seconds = currentTime.second

proc draw*(display: Display, buffer: array[0x9600, uint16]) =
  display.texture.updateTexture(nil, unsafeAddr buffer, WIDTH * sizeof(uint16))
  display.renderer.clear
  display.renderer.copy display.texture, nil, nil
  display.renderer.present
  display.updateDrawCount()
