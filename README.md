# WIP Sokol Backend for dvui

This project provides a [Sokol](https://github.com/floooh/sokol) backend for [dvui](https://github.com/david-vanderson/dvui). 

## Motivation

Sokol provides nice zig bindings with cross-platform 3D graphics API (including web compilation from zig through emscripten toolchain, with sokol supporting both webgl2 and webgpu). 
This can be great for quick starting 3D or 2D projects where custom rendering is need additionally to dvui UI features. 

### TODO / Not yet implemented:
* Fix Web version being extremely slow
* Render textures
* Touch events

## Building and Running

Native build:
```sh
zig build run -Doptimize=ReleaseFast
```

Web:
⚠️Extremely slow, mainly due to high number of __builtin_return_address which on web with emscripten poly-fil are crazy expensive: https://github.com/emscripten-core/emscripten/issues/19060
Temp fix is manual replacement of `_emscripten_return_address` with dummy/null function in generated js code after each compilation. TODO: figure out how to either automate it or even better how to get rid of __builtin_return_address being generated/used so much.
```sh
zig build run -Doptimize=ReleaseFast -Dtarget=wasm32-emscripten
```
