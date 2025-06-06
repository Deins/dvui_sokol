# Sokol Backend for dvui

This project provides a [Sokol](https://github.com/floooh/sokol) backend for [dvui](https://github.com/david-vanderson/dvui). 

## Motivation

Sokol provides nice zig bindings with cross-platform 3D graphics API (including web compilation from zig through emscripten toolchain, with sokol supporting both webgl2 and webgpu). 
This can be great for quick starting 3D or 2D projects where custom rendering is need additionally to dvui UI features. 


### 🚧 Not yet implemented / TODO 🚧
* Render textures
* Touch events
* Example of mixing sokol & dvui rendering
* Fix: defered/batched rendering crashes in debug build due to premature texture destruction 

### ❌ Not supported ❌
* vsync off - vsync is always on
* variable frame rate - might be possible, but currently unsupported

## Build & Run

### Native:
```sh
zig build run -Doptimize=ReleaseFast
```

### WEB
#### WebGPU
```sh
zig build run -Doptimize=ReleaseFast -Dtarget=wasm32-emscripten
```
#### WebGL2
```
zig build run -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast -Dweb_gfx=WEBGL2
```

