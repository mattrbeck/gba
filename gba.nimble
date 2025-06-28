# Package

version       = "0.1.0"
author        = "Matthew Beck"
description   = "A proof-of-concept gba emulator in nim"
license       = "MIT"
srcDir        = "src"
bin           = @["gba"]

# Dependencies

requires "nim >= 1.6.0"
requires "sdl2 >= 2.0.4"

task wasm, "wasm":
  exec "nim c -d:emscripten -d:wasm -d:release src/gba.nim"

task test, "test":
  exec "nim c -r tests/runner.nim"

