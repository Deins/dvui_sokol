# Sokol Backend for dvui

This project provides a [Sokol](https://github.com/floooh/sokol) backend for [dvui](https://github.com/david-vanderson/dvui). 

## Motivation

Sokol provides nice zig bindings with cross-platform 3D graphics API (including web compilation from zig through emscripten toolchain, with sokol supporting both webgl2 and webgpu). 
This can be great for quick starting 3D or 2D projects where custom rendering is need additionally to dvui UI features. 

### TODO / Not yet implemented:
* Render textures
* Touch events
* Optimize buffer handling (currently each drawTriangles allocates and frees, slow on web where createBuffer can take 0.5ms)
* Example of mixing sokol & dvui rendering
* Investigate how to do non-continuous rendering and sleep when no activity happens

## Building and Running

Native build:
```sh
zig build run -Doptimize=ReleaseFast
```

Web:
```sh
zig build run -Doptimize=ReleaseFast -Dtarget=wasm32-emscripten
```
