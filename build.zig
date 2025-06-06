const std = @import("std");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;
const Dependency = Build.Dependency;
const sokol = @import("sokol");

const WebGFX = enum {
    WEBGL,
    WEBGL2,
    WGPU,
};
var web_gfx = WebGFX.WGPU;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    web_gfx = b.option(WebGFX, "web_gfx", "graphics backend to use for web builds") orelse .WGPU;

    // note that the sokol dependency is built with `.with_sokol_imgui = true`
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = false,
        .wgpu = web_gfx == .WGPU and target.result.cpu.arch.isWasm(),
    });
    const sokol_module = dep_sokol.module("sokol");
    // const dep_cimgui = b.dependency("cimgui", .{
    //     .target = target,
    //     .optimize = optimize,
    // });

    // inject the cimgui header search path into the sokol C library compile step
    // dep_sokol.artifact("sokol_clib").addIncludePath(dep_cimgui.path("src"));

    // const mod_zalgebra = b.dependency("zalgebra", .{}).module("zalgebra");

    // const mod_shaders = b.createModule(.{
    //     .root_source_file = b.path("shaders/all.zig"),
    //     .imports = &.{
    //         .{ .name = "sokol", .module = dep_sokol.module("sokol") },
    //         .{ .name = "zalgebra", .module = mod_zalgebra },
    //     },
    // });

    const dvui_sokol_backend = b.addModule("dvui_sokol", .{
        .root_source_file = b.path("src/dvui_sokol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = sokol_module },
        },
    });

    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .custom });
    const dvui_module = dvui_dep.module("dvui");
    @import("dvui").linkBackend(dvui_module, dvui_sokol_backend);
    // const dvui_module = dvui_dep.module("dvui_raylib");

    // main module with sokol and cimgui imports
    const mod_main = b.createModule(.{
        .root_source_file = b.path("examples/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = sokol_module },
            // .{ .name = "cimgui", .module = dep_cimgui.module("cimgui") },
            // .{ .name = "zalgebra", .module = mod_zalgebra },
            // .{ .name = "shaders", .module = mod_shaders },
            .{ .name = "dvui", .module = dvui_module },
        },
    });

    // from here on different handling for native vs wasm builds
    if (target.result.cpu.arch.isWasm()) {
        try buildWasm(b, mod_main, dep_sokol, null);
    } else {
        try buildNative(b, mod_main);
    }
}

fn buildNative(b: *Build, mod: *Build.Module) !void {
    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = mod,
    });
    b.installArtifact(exe);
    b.step("run", "Run demo").dependOn(&b.addRunArtifact(exe).step);
}

fn buildWasm(b: *Build, mod: *Build.Module, dep_sokol: *Dependency, dep_cimgui: ?*Dependency) !void {
    // build the main file into a library, this is because the WASM 'exe'
    // needs to be linked in a separate build step with the Emscripten linker
    const demo = b.addStaticLibrary(.{
        .name = "demo",
        .root_module = mod,
    });

    // get the Emscripten SDK dependency from the sokol dependency
    const dep_emsdk = dep_sokol.builder.dependency("emsdk", .{});

    // need to inject the Emscripten system header include path into
    // the cimgui C library otherwise the C/C++ code won't find
    // C stdlib headers
    const emsdk_incl_path = dep_emsdk.path("upstream/emscripten/cache/sysroot/include");
    if (dep_cimgui) |cimgui| cimgui.artifact("cimgui_clib").addSystemIncludePath(emsdk_incl_path);

    // all C libraries need to depend on the sokol library, when building for
    // WASM this makes sure that the Emscripten SDK has been setup before
    // C compilation is attempted (since the sokol C library depends on the
    // Emscripten SDK setup step)
    if (dep_cimgui) |cimgui| cimgui.artifact("cimgui_clib").step.dependOn(&dep_sokol.artifact("sokol_clib").step);

    const extra_args: []const []const u8 = if (mod.optimize == .Debug) &.{
        "-sSTACK_SIZE=2097152", // larger 2MB stack
        "-sASSERTIONS",
        "-gsource-map",
        "-O0",
        // "-sTOTAL_MEMORY=1024MB",
        "-sALLOW_MEMORY_GROWTH",
        "-msimd128",
        // "-fsanitize=undefined",
    } else &.{
        "-sSTACK_SIZE=2097152", // larger 2MB stack
        "-sALLOW_MEMORY_GROWTH",
        "-msimd128",
    };

    // create a build step which invokes the Emscripten linker
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = demo,
        .target = mod.resolved_target.?,
        .optimize = mod.optimize.?,
        .emsdk = dep_emsdk,
        .use_webgl2 = web_gfx == .WEBGL2,
        .use_webgpu = web_gfx == .WGPU,
        .release_use_closure = web_gfx != .WGPU, // wgpu don't work in release with closure, see: https://github.com/emscripten-core/emscripten/issues/20415
        .use_emmalloc = true,
        .use_filesystem = false,
        .shell_file_path = dep_sokol.path("src/sokol/web/shell.html"),
        // .shell_file_path = b.path("src/shell_simple.html"),
        .release_use_lto = true,
        .extra_args = extra_args,
        // .use_offset_converter = true,
    });
    // ...and a special run step to start the web build output via 'emrun'
    const run = sokol.emRunStep(b, .{ .name = "demo", .emsdk = dep_emsdk });
    run.step.dependOn(&link_step.step);
    b.step("run", "Run demo").dependOn(&run.step);
}
