# WIP Sokol Backend for dvui

This project provides a [Sokol](https://github.com/floooh/sokol) backend for [dvui](https://github.com/david-vanderson/dvui). 

## Motivation

Sokol provides nice zig bindings with cross-platform 3D graphics API (including web compilation from zig through emscripten toolchain, with sokol supporting both webgl2 and webgpu). 
This can be great for quick starting 3D or 2D projects where custom rendering is need additionally to dvui UI features. 

### Not yet implemented:
* Web compilation support
* Render textures
* Touch events

## Building and Running

Native build:
```sh
zig build run -Doptimize=ReleaseFast
```

❌ Web  (not yet implemented):
```sh
zig build run -Doptimize=ReleaseFast -Dtarget=wasm32-emscripten
```
