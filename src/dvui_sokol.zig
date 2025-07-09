const std = @import("std");

const dvui = @import("dvui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const ss = sokol.shape;
const slog = std.log.scoped(.dvui_sokol);
const shader = @import("dvui.sokol.glsl.zig");

const is_wasm = @import("builtin").target.cpu.arch.isWasm();

pub const kind: dvui.enums.Backend = .custom;

pub const SokolBackend = @This();
pub const Context = *SokolBackend;

/// Batch all draws into large buffers and defer rendering  at the end of frame.
/// More efficient than current fallback of creating buffers for each draw.
/// Additionally allows easier inter-mixing of user side sokol rendering calls/state with dvui calls
const batch = false;
const defer_texture_destruction = batch; // due to batch rendering at end of frame, texture use after free can occur - defer texture destruction to end of frame
const render_textures = false;
const render_texture_format = sg.PixelFormat.RGBA8;
const render_texture_sample_count = 1;

// ============================================================================
//      Global State
// ============================================================================
var gpa_instance = if (is_wasm) void else std.heap.GeneralPurposeAllocator(.{}){};
var ctx: SokolBackend = undefined;

// ============================================================================
//      Context
// ============================================================================
const DrawCall = struct {
    scissor: dvui.Rect.Physical,
    texture: sg.Image, // NOTE: upper bit of id is used for interpolation, needs to be cleared before passing to sokol
    idx_offset: u32,
    vtx_offset: u32,
    idx_size: u16,
    vtx_size: u16,
};

// todo: pass this alloc to sokol as well
gpa: std.mem.Allocator, // allocator used for init and long term (more than one frame) allocations
arena: std.mem.Allocator = undefined,
win: dvui.Window,

// rendering
pip: sg.Pipeline = .{},
pass_action: sg.PassAction = .{},
sampler_nearest: sg.Sampler,
sampler_linear: sg.Sampler,
default_texture: sg.Image, // white 1x1 texture used as default when no texture is given
texture_targets: std.ArrayListUnmanaged(sg.Image) = .{},
// batch things into buffers and only render them at the end of frame
draw_calls: std.ArrayListUnmanaged(DrawCall) = .{},
idx_data: std.ArrayListUnmanaged(u16) = .{},
vtx_data: std.ArrayListUnmanaged(dvui.Vertex) = .{},
idx_buf: sg.Buffer = .{},
vtx_buf: sg.Buffer = .{},

texture_destruction_chain: if (defer_texture_destruction) ?*ImageChain else void = if (defer_texture_destruction) null else undefined,

const ImageChain = struct {
    texture: sg.Image = .{ .id = 0 },
    next: ?*ImageChain = null,
};

// ============================================================================
//      Backend
// ============================================================================

pub fn nanoTime(_: *SokolBackend) i128 {
    return std.time.nanoTimestamp();
}

pub fn sleep(_: *SokolBackend, ns: u64) void {
    std.time.sleep(ns);
}

pub fn backend(self: *SokolBackend) dvui.Backend {
    return dvui.Backend.init(self);
}

pub fn begin(self: *SokolBackend, arena: std.mem.Allocator) void {
    self.arena = arena;

    if (!batch) {
        sg.beginPass(.{ .action = ctx.pass_action, .swapchain = sokol.glue.swapchain() });
        sg.applyPipeline(ctx.pip);
        const ubo = shader.Ubo{ .framebuffer_size = .{ sapp.widthf(), sapp.heightf() } };
        sg.applyUniforms(shader.UB_UBO, sg.asRange(&ubo));
    }
}

pub fn end(self: *SokolBackend) void {
    if (batch) {
        sg.beginPass(.{ .action = ctx.pass_action, .swapchain = sokol.glue.swapchain() });
        sg.applyPipeline(ctx.pip);
        const ubo = shader.Ubo{ .framebuffer_size = .{ sapp.widthf(), sapp.heightf() } };
        sg.applyUniforms(shader.UB_UBO, sg.asRange(&ubo));

        // resize buffers if needed
        if (sg.queryBufferSize(ctx.idx_buf) < (ctx.idx_data.items.len * @sizeOf(u16))) {
            sg.destroyBuffer(ctx.idx_buf);
            ctx.idx_buf = sg.makeBuffer(.{
                .usage = .{ .index_buffer = true, .stream_update = true },
                .size = std.mem.alignForward(u32, @intCast(ctx.idx_data.items.len * @sizeOf(u16)), 1024 * 64),
                .label = "dvui",
            });
        }
        if (sg.queryBufferSize(ctx.vtx_buf) < (ctx.vtx_data.items.len * @sizeOf(dvui.Vertex))) {
            sg.destroyBuffer(ctx.vtx_buf);
            ctx.vtx_buf = sg.makeBuffer(.{
                .usage = .{ .vertex_buffer = true, .stream_update = true },
                .size = std.mem.alignForward(u32, @intCast(ctx.vtx_data.items.len * @sizeOf(dvui.Vertex)), 1024 * 64),
                .label = "dvui",
            });
        }

        sg.updateBuffer(self.idx_buf, sg.asRange(self.idx_data.items));
        sg.updateBuffer(self.vtx_buf, sg.asRange(self.vtx_data.items));

        var prev_scissor = dvui.Rect.Physical{ .x = 0, .y = 0, .w = 0, .h = 0 };
        var bind = sg.Bindings{
            .vertex_buffers = [_]sg.Buffer{self.vtx_buf} ++ ([_]sg.Buffer{.{}} ** 7),
            .index_buffer = self.idx_buf,
            .images = [_]sg.Image{self.default_texture} ++ ([_]sg.Image{.{}} ** 15),
            .samplers = [_]sg.Sampler{ctx.sampler_linear} ++ ([_]sg.Sampler{.{}} ** 15),
        };
        for (self.draw_calls.items) |draw| {
            if (!prev_scissor.equals(draw.scissor)) {
                sg.applyScissorRectf(draw.scissor.x, draw.scissor.y, draw.scissor.w, draw.scissor.h, true);
                prev_scissor = draw.scissor;
            }
            bind.samplers[0] = if (draw.texture.id & (1 << 31) == 0) ctx.sampler_nearest else ctx.sampler_linear;
            bind.images[0] = sg.Image{ .id = draw.texture.id & ~@as(u32, (1 << 31)) };
            bind.index_buffer_offset = @intCast(draw.idx_offset * @sizeOf(u16));
            bind.vertex_buffer_offsets[0] = @intCast(draw.vtx_offset * @sizeOf(dvui.Vertex));
            sg.applyBindings(bind);
            sg.draw(0, @intCast(draw.idx_size), 1);
        }

        ctx.idx_data.clearRetainingCapacity();
        ctx.vtx_data.clearRetainingCapacity();
        ctx.draw_calls.clearRetainingCapacity();
    }

    // destroy textures
    if (defer_texture_destruction) {
        while (ctx.texture_destruction_chain) |tc| {
            sg.destroyImage(tc.texture);
            ctx.texture_destruction_chain = tc.next;
        }
    }
    sg.endPass();
}

/// Return size of the window in physical pixels.  For a 300x200 retina
/// window (so actually 600x400), this should return 600x400.
pub fn pixelSize(_: *SokolBackend) dvui.Size.Physical {
    return .{ .w = sapp.widthf(), .h = sapp.heightf() };
}

/// Return size of the window in logical pixels.  For a 300x200 retina
/// window (so actually 600x400), this should return 300x200.
pub fn windowSize(_: *SokolBackend) dvui.Size.Natural {
    const scale = 1.0 / sapp.dpiScale();
    return .{ .w = sapp.widthf() * scale, .h = sapp.heightf() * scale };
}

// TODO: double check if this should be dpi scale or something else
pub fn contentScale(_: *SokolBackend) f32 {
    return 1.0;
}

pub fn drawClippedTriangles(self: *SokolBackend, texture: ?dvui.Texture, vtx: []const dvui.Vertex, idx: []const u16, clipr: ?dvui.Rect.Physical) void {
    if (batch) {
        const idx_offset = self.idx_data.items.len;
        const vtx_offset = self.vtx_data.items.len;
        self.idx_data.appendSlice(self.gpa, idx) catch return;
        self.vtx_data.appendSlice(self.gpa, vtx) catch return;
        self.draw_calls.append(self.gpa, .{
            .scissor = clipr orelse .{ .x = 0, .y = 0, .w = sapp.widthf(), .h = sapp.heightf() },
            .texture = if (texture) |t| sg.Image{ .id = @intCast(@intFromPtr(t.ptr)) } else self.default_texture,
            .idx_offset = @intCast(idx_offset),
            .vtx_offset = @intCast(vtx_offset),
            .idx_size = @intCast(idx.len),
            .vtx_size = @intCast(vtx.len),
        }) catch return;
        return;
    }

    if (clipr) |c| {
        sg.applyScissorRectf(c.x, c.y, c.w, c.h, true);
    } else {
        sg.applyScissorRectf(0, 0, sapp.widthf(), sapp.heightf(), true);
    }

    // TODO: we are lazy here, buffers are created for each draw and discarded, benchmark if reusing buffers or building one large buffer for multiple calls is beneficial
    const vtx_buf = sg.makeBuffer(.{
        .usage = .{ .vertex_buffer = true },
        .data = sg.asRange(vtx),
        .label = "dvui",
    });
    defer sg.destroyBuffer(vtx_buf);
    const idx_buf = sg.makeBuffer(.{
        .usage = .{ .index_buffer = true, .vertex_buffer = false },
        .data = sg.asRange(idx),
        .label = "dvui",
    });
    defer sg.destroyBuffer(idx_buf);

    var bind = sg.Bindings{
        .vertex_buffers = [_]sg.Buffer{vtx_buf} ++ ([_]sg.Buffer{.{}} ** 7),
        .index_buffer = idx_buf,
    };
    if (texture) |tex| {
        // see comment in textureCreate about bitmasking
        const img: sg.Image = .{ .id = @intCast(@intFromPtr(tex.ptr) & (~@as(u32, 1 << 31))) };
        bind.images[0] = img;
        bind.samplers[0] = if (@intFromPtr(tex.ptr) & (1 << 31) == 0) ctx.sampler_nearest else ctx.sampler_linear;
    } else {
        bind.images[0] = ctx.default_texture;
        bind.samplers[0] = ctx.sampler_nearest;
    }
    sg.applyBindings(bind);
    sg.draw(0, @intCast(idx.len), 1);
}

/// Create a `dvui.Texture` from the given `pixels` in RGBA.
pub fn textureCreate(self: *SokolBackend, pixels: [*]const u8, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) dvui.Texture {
    _ = self; // autofix
    var img_desc = sg.ImageDesc{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = .RGBA8,
        .label = "dvui",
    };
    img_desc.data.subimage[0][0] = .{ .ptr = pixels, .size = width * height * 4 };
    const image = sg.makeImage(img_desc);

    // very hacky, but I don't want to create & store metadata just for interpolation - as sokol ids are incremental, use last bit of id for this info
    var id = image.id;
    std.debug.assert((id & (1 << 31)) == 0);
    switch (interpolation) {
        .nearest => {},
        .linear => id |= 1 << 31,
    }
    return .{ .ptr = @ptrFromInt(id), .width = width, .height = height };
}

pub fn textureDestroy(self: *SokolBackend, texture: dvui.Texture) void {
    const img: sg.Image = .{ .id = @intCast(@intFromPtr(texture.ptr) & (~@as(u32, (1 << 31)))) };
    if (!defer_texture_destruction) {
        sg.destroyImage(img);
    } else {
        const tc = self.arena.create(ImageChain) catch |err| {
            slog.err("defered texture destruction err: {}", .{err});
            // risky but sokol on most platforms handles this gracefully in release builds
            sg.destroyImage(img);
            return;
        };
        tc.* = .{ .texture = img, .next = ctx.texture_destruction_chain };
        self.texture_destruction_chain = tc;
    }
}

pub fn textureCreateTarget(self: *SokolBackend, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) !dvui.TextureTarget {
    if (!render_textures) return error.TextureCreate;

    var target_idx: u32 = 0;
    for (self.texture_targets.items, 0..) |target, i| {
        if (target.id != 0) continue;
        target_idx = @intCast(i);
        break;
    }
    if (target_idx == 0) {
        (self.texture_targets.addOne(self.gpa) catch return error.TextureCreate).* = .{};
        target_idx = @intCast(self.texture_targets.items.len - 1);
    }

    std.debug.assert(width > 0 and height > 0);
    const img_desc = sg.ImageDesc{
        .usage = .{ .render_attachment = true },
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = render_texture_format,
        .sample_count = render_texture_sample_count,
        .label = "dvui-target",
    };
    const image = sg.makeImage(img_desc);

    var id = image.id;
    std.debug.assert((id & (1 << 31)) == 0); // interpolation bit
    switch (interpolation) {
        .nearest => {},
        .linear => id |= 1 << 31,
    }
    self.texture_targets.items[target_idx].id = id;
    return .{
        .width = width,
        .height = height,
        .ptr = @ptrFromInt(target_idx + 1), // +1 to avoid null pointer
    };
}

/// Read pixel data (RGBA) from `texture` into `pixels_out`.
pub fn textureReadTarget(self: *SokolBackend, texture: dvui.TextureTarget, pixels_out: [*]u8) !void {
    _ = self; // autofix
    _ = texture; // autofix
    _ = pixels_out; // autofix
    return error.TextureRead; // sokol does not support reading from texture targets
}

/// Convert texture target made with `textureCreateTarget` into return texture
/// as if made by `textureCreate`.  After this call, texture target will not be
/// used by dvui.
pub fn textureFromTarget(self: *SokolBackend, texture: dvui.TextureTarget) dvui.Texture {
    _ = self; // autofix
    return .{ .ptr = texture.ptr, .width = texture.width, .height = texture.height };
}

/// Render future `drawClippedTriangles` to the passed `texture` (or screen
/// if null).
pub fn renderTarget(self: *SokolBackend, texture: ?dvui.TextureTarget) void {
    _ = self; // autofix
    _ = texture; // autofix
}

/// Get clipboard content (text only)
pub fn clipboardText(_: *SokolBackend) error{OutOfMemory}![]const u8 {
    return sapp.getClipboardString();
}

/// Set clipboard content (text only)
pub fn clipboardTextSet(self: *SokolBackend, text: []const u8) error{OutOfMemory}!void {
    const zero_terminated = try self.arena.allocSentinel(u8, text.len, 0);
    defer self.arena.free(zero_terminated);
    @memcpy(zero_terminated, text);
    sapp.setClipboardString(zero_terminated);
}

/// Called by `dvui.refresh` when it is called from a background
/// thread.  Used to wake up the gui thread.  It only has effect if you
/// are using `dvui.Window.waitTime` or some other method of waiting until
/// a new event comes in.
pub fn refresh(_: *SokolBackend) void {}

// TODO: review if this is available in sokol
pub fn openURL(self: *SokolBackend, url: []const u8) !void {
    _ = self; // autofix
    _ = url; // autofix
    return;
}

pub fn preferredColorScheme(self: SokolBackend) ?dvui.enums.ColorScheme {
    _ = self; // autofix
    return null;
}

// ============================================================================
//      App setup and callbacks
// ============================================================================

pub export fn init() void {
    sg.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = sokol.log.func },
        // TODO: pass zig allocator to C
        //.allocator = gpa,
    });

    ctx.sampler_nearest = sg.makeSampler(.{ .mag_filter = .NEAREST, .min_filter = .NEAREST, .label = "dvui" });
    ctx.sampler_linear = sg.makeSampler(.{ .mag_filter = .LINEAR, .min_filter = .LINEAR, .label = "dvui" });

    ctx.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
    };

    var layout = sg.VertexLayoutState{};
    layout.buffers[0] = .{ .stride = @sizeOf(dvui.Vertex) };
    layout.attrs[0] = .{ .buffer_index = 0, .format = .FLOAT2, .offset = @offsetOf(dvui.Vertex, "pos") };
    layout.attrs[1] = .{ .buffer_index = 0, .format = .UBYTE4N, .offset = @offsetOf(dvui.Vertex, "col") };
    layout.attrs[2] = .{ .buffer_index = 0, .format = .FLOAT2, .offset = @offsetOf(dvui.Vertex, "uv") };

    // premultiplied alpha blending
    const blend = sg.BlendState{
        .enabled = true,
        .op_rgb = .ADD,
        .src_factor_rgb = .ONE,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .op_alpha = .ADD,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
    };
    ctx.pip = sg.makePipeline(.{
        .label = "dvui",
        .shader = sg.makeShader(shader.sokolShaderDesc(sg.queryBackend())),
        .layout = layout,
        .index_type = .UINT16,
        .cull_mode = .FRONT, // optional. But due to screen-space coordinate mismatch y is flipped in shader causing triangle order to also flip. Means we cull front not back as usual
        .color_count = 1,
        .colors = [_]sg.ColorTargetState{.{ .blend = blend }} ++ [_]sg.ColorTargetState{.{}} ** 3,
    });

    // make default white texture
    var img_desc = sg.ImageDesc{
        .width = 1,
        .height = 1,
        .pixel_format = .RGBA8,
        .label = "dvui",
    };
    img_desc.data.subimage[0][0] = .{ .ptr = &[4]u8{ 0xff, 0xff, 0xff, 0xff }, .size = 4 };
    ctx.default_texture = sg.makeImage(img_desc);

    if (batch) {
        ctx.vtx_buf = sg.makeBuffer(.{
            .usage = .{ .vertex_buffer = true, .stream_update = true },
            .size = 1024 * 512,
            .label = "dvui",
        });
        ctx.idx_buf = sg.makeBuffer(.{
            .usage = .{ .index_buffer = true, .stream_update = true },
            .size = 1024 * 1024,
            .label = "dvui",
        });
    }

    ctx.win = dvui.Window.init(@src(), ctx.gpa, backend(&ctx), .{}) catch |err| std.debug.panic("Dvui failed to initialize: {}", .{err});

    if (dvui.App.get()) |app| if (app.initFn) |initFn| initFn(&ctx.win) catch |err| std.debug.panic("App init failed: {}", .{err});
}

pub export fn cleanup() void {
    if (dvui.App.get()) |app| if (app.deinitFn) |deinitFn| deinitFn();

    if (batch) {
        sg.destroyBuffer(ctx.vtx_buf);
        sg.destroyBuffer(ctx.idx_buf);

        ctx.idx_data.deinit(ctx.gpa);
        ctx.vtx_data.deinit(ctx.gpa);
        ctx.draw_calls.deinit(ctx.gpa);
    }

    sg.destroyPipeline(ctx.pip);
    ctx.win.deinit();
    // simgui.shutdown();
    sg.shutdown();
}

pub export fn frame() void {
    zigFrame() catch |err| {
        @branchHint(.cold);
        slog.err("Frame failed: {}", .{err});
        sapp.requestQuit();
    };
}

// frame that can throw errors
pub fn zigFrame() !void {
    try ctx.win.begin(std.time.nanoTimestamp());

    if (dvui.App.get()) |app| {
        if (try app.frameFn() == .close) sapp.requestQuit();
    }

    // marks end of dvui frame, don't call dvui functions after this
    // - sends all dvui stuff to backend for rendering, must be called before renderPresent()
    const end_micros = try ctx.win.end(.{});
    const wait_event_micros = ctx.win.waitTime(end_micros, null);
    _ = wait_event_micros; // autofix
    sg.commit();
    // std.time.sleep(std.time.ns_per_us * wait_event_micros);
}

export fn event(_ev: [*c]const sapp.Event) void {
    const ev = _ev.?.*;
    var consumed = false;
    // TODO: what to do with errors - unreachable for now
    switch (ev.type) {
        .KEY_DOWN => consumed = ctx.win.addEventKey(.{ .action = .down, .code = convertKeycode(ev.key_code), .mod = mod(ev.modifiers) }) catch unreachable,
        .KEY_UP => consumed = ctx.win.addEventKey(.{ .action = .up, .code = convertKeycode(ev.key_code), .mod = mod(ev.modifiers) }) catch unreachable,
        .MOUSE_DOWN => consumed = ctx.win.addEventMouseButton(button(ev.mouse_button), .press) catch unreachable,
        .MOUSE_UP => consumed = ctx.win.addEventMouseButton(button(ev.mouse_button), .release) catch unreachable,
        .MOUSE_MOVE => consumed = ctx.win.addEventMouseMotion(.{ .x = ev.mouse_x, .y = ev.mouse_y }) catch unreachable,
        .MOUSE_SCROLL => {
            const scale = 120 / 30;
            if (ctx.win.addEventMouseWheel(ev.scroll_x * scale, .horizontal) catch unreachable) consumed = true;
            if (ctx.win.addEventMouseWheel(ev.scroll_y * scale, .vertical) catch unreachable) consumed = true;
        },
        .CHAR => {
            var utf8_bytes: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(@intCast(ev.char_code), &utf8_bytes) catch |err| {
                slog.err("Failed to encode char code {} to utf8: {}", .{ ev.char_code, err });
                return;
            };
            if (ctx.win.addEventText(utf8_bytes[0..utf8_len]) catch |err| {
                slog.err("Failed to add text event: {}", .{err});
                return;
            }) consumed = true;
        },
        // .CHAR => consumed |= ctx.win.addEventText(@ptrCast(&ev.char_code))
        // TODO: touch events
        else => {},
    }
}

pub fn main() !void {
    const app = dvui.App.get() orelse return error.DvuiAppNotDefined;

    const gpa = if (!is_wasm) gpa_instance.allocator() else std.heap.c_allocator;
    ctx.gpa = gpa;

    defer _ = if (!is_wasm) if (gpa_instance.deinit() != .ok) @panic("memory leak!");

    const init_opts = app.config.get();

    var icon_desc = sapp.IconDesc{ .sokol_default = true }; // use sokol default as default unless app provided icon is successfully loaded
    if (init_opts.icon) |icon| {
        // decode icon image
        var w: c_int = undefined;
        var h: c_int = undefined;
        var channels_in_file: c_int = undefined;
        const pixels = dvui.c.stbi_load_from_memory(icon.ptr, @as(c_int, @intCast(icon.len)), &w, &h, &channels_in_file, 4);
        if (pixels != null) {
            // set icon
            icon_desc.sokol_default = false;
            icon_desc.images[0] = .{ .width = w, .height = h, .pixels = .{ .ptr = pixels, .size = @intCast(w * h * channels_in_file) } };
            sapp.setIcon(icon_desc);
        } else {
            slog.err("Failed to decode icon!", .{});
        }
    }

    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .window_title = init_opts.title,
        .width = @intFromFloat(init_opts.size.w),
        .height = @intFromFloat(init_opts.size.h),
        .icon = icon_desc,
        .logger = .{ .func = sokol.log.func },
        .enable_clipboard = true,
        .enable_dragndrop = false, // TODO: implement if dvui supports it
        .high_dpi = true,
        .swap_interval = if (init_opts.vsync) 1 else 0,
        //.sample_count = 4, // msaa

        .win32_console_attach = true,
        .win32_console_utf8 = true,
    });
}

// ============================================================================
//      Web Backend specific
// ============================================================================

pub usingnamespace if (!is_wasm) struct {} else struct {
    // extern c allocator plumbed by emscripten, std.heap.c_allocator should work, but this is easier
    extern fn malloc(size: usize) ?*anyopaque;
    extern fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
    extern fn free(ptr: ?*anyopaque) void;

    pub const wasm = struct {
        pub fn wasm_add_noto_font() void {
            slog.err("wasm_add_noto_font is not implemented in dvui_sokol.zig", .{});
        }
    };

    pub fn downloadData(name: []const u8, data: []const u8) !void {
        _ = name; // autofix
        _ = data; // autofix
    }

    pub fn setCursor(self: *SokolBackend, cursor: dvui.enums.Cursor) void {
        _ = self; // autofix
        _ = cursor; // autofix
    }

    pub fn openFilePicker(id: dvui.WidgetId, accept: ?[]const u8, multiple: bool) void {
        _ = id; // autofix
        _ = accept; // autofix
        _ = multiple; // autofix
    }

    pub fn getFileName(id: dvui.WidgetId, file_index: usize) ?[:0]const u8 {
        _ = id; // autofix
        _ = file_index; // autofix
        return "";
    }

    pub fn getFileSize(id: dvui.WidgetId, file_index: usize) ?usize {
        _ = id; // autofix
        _ = file_index; // autofix
        return 0;
    }

    pub fn readFileData(id: dvui.WidgetId, file_index: usize, data: [*]u8) void {
        _ = id; // autofix
        _ = file_index; // autofix
        _ = data; // autofix
    }

    pub fn getNumberOfFilesAvailable(id: dvui.WidgetId) usize {
        _ = id; // autofix
        return 0;
    }

    pub export fn dvui_c_alloc(size: usize) ?*anyopaque {
        // return @ptrCast(std.heap.c_allocator.alloc(u8, size) catch null);
        return malloc(size);
    }
    export fn dvui_c_realloc_sized(_ptr: ?*anyopaque, oldsize: usize, newsize: usize) ?*anyopaque {
        _ = oldsize; // autofix
        return realloc(_ptr, newsize);
        // if (_ptr == null) {
        //     return dvui_c_alloc(newsize);
        // }
        // const ptr: [*]u8 = @ptrCast(_ptr);
        // if (newsize == 0) {
        //     dvui_c_free(ptr);
        //     return null;
        // }
        // // TODO: figure out if realloc can be plumbed directly, for now allocate and copy
        // const new_mem: [*]u8 = @ptrCast(dvui_c_alloc(newsize) orelse return null);
        // @memcpy(new_mem[0..oldsize], ptr[0..oldsize]);
        // dvui_c_free(ptr);
        // return new_mem;
    }

    pub export fn dvui_c_free(ptr: ?*anyopaque) void {
        free(ptr);
    }

    export fn dvui_c_panic(msg: [*c]const u8) noreturn {
        slog.err("PANIC: {s}", .{msg});
        unreachable;
    }

    export fn dvui_c_sqrt(x: f64) f64 {
        return @sqrt(x);
    }

    export fn dvui_c_pow(x: f64, y: f64) f64 {
        return @exp(@log(x) * y);
    }

    export fn dvui_c_ldexp(x: f64, n: c_int) f64 {
        return x * @exp2(@as(f64, @floatFromInt(n)));
    }

    export fn dvui_c_floor(x: f64) f64 {
        return @floor(x);
    }

    export fn dvui_c_ceil(x: f64) f64 {
        return @ceil(x);
    }

    export fn dvui_c_fmod(x: f64, y: f64) f64 {
        return @mod(x, y);
    }

    export fn dvui_c_cos(x: f64) f64 {
        return @cos(x);
    }

    export fn dvui_c_acos(x: f64) f64 {
        return std.math.acos(x);
    }

    export fn dvui_c_fabs(x: f64) f64 {
        return @abs(x);
    }

    export fn dvui_c_strlen(x: [*c]const u8) usize {
        return std.mem.len(x);
    }

    export fn dvui_c_memcpy(dest: [*c]u8, src: [*c]const u8, n: usize) [*c]u8 {
        @memcpy(dest[0..n], src[0..n]);
        return dest;
    }

    export fn dvui_c_memmove(dest: [*c]u8, src: [*c]const u8, n: usize) [*c]u8 {
        //log.debug("dvui_c_memmove dest {*} src {*} {d}", .{ dest, src, n });
        const buf = dvui.currentWindow().arena().alloc(u8, n) catch unreachable;
        @memcpy(buf, src[0..n]);
        @memcpy(dest[0..n], buf);
        return dest;
    }

    export fn dvui_c_memset(dest: [*c]u8, x: u8, n: usize) [*c]u8 {
        @memset(dest[0..n], x);
        return dest;
    }

    /// zig allocators etc. use @returnAddress() a lot
    /// but emscripten its is crazy expensive, so we override it with a no-op
    export fn emscripten_return_address(_: i32) callconv(.C) ?*anyopaque {
        return null;
    }
};
// ============================================================================
//      Event utils
// ============================================================================

pub fn convertKeycode(keycode: sapp.Keycode) dvui.enums.Key {
    return switch (keycode) {
        .INVALID => .unknown,
        .SPACE => .space,
        .APOSTROPHE => .apostrophe,
        .COMMA => .comma,
        .MINUS => .minus,
        .PERIOD => .period,
        .SLASH => .slash,
        ._0 => .zero,
        ._1 => .one,
        ._2 => .two,
        ._3 => .three,
        ._4 => .four,
        ._5 => .five,
        ._6 => .six,
        ._7 => .seven,
        ._8 => .eight,
        ._9 => .nine,
        .SEMICOLON => .semicolon,
        .EQUAL => .equal,
        .A => .a,
        .B => .b,
        .C => .c,
        .D => .d,
        .E => .e,
        .F => .f,
        .G => .g,
        .H => .h,
        .I => .i,
        .J => .j,
        .K => .k,
        .L => .l,
        .M => .m,
        .N => .n,
        .O => .o,
        .P => .p,
        .Q => .q,
        .R => .r,
        .S => .s,
        .T => .t,
        .U => .u,
        .V => .v,
        .W => .w,
        .X => .x,
        .Y => .y,
        .Z => .z,
        .LEFT_BRACKET => .left_bracket,
        .BACKSLASH => .backslash,
        .RIGHT_BRACKET => .right_bracket,
        .GRAVE_ACCENT => .grave,
        .WORLD_1 => .unknown, // todo: what is this?
        .WORLD_2 => .unknown, // todo: what is this?
        .ESCAPE => .escape,
        .ENTER => .enter,
        .TAB => .tab,
        .BACKSPACE => .backspace,
        .INSERT => .insert,
        .DELETE => .delete,
        .RIGHT => .right,
        .LEFT => .left,
        .DOWN => .down,
        .UP => .up,
        .PAGE_UP => .page_up,
        .PAGE_DOWN => .page_down,
        .HOME => .home,
        .END => .end,
        .CAPS_LOCK => .caps_lock,
        .SCROLL_LOCK => .scroll_lock,
        .NUM_LOCK => .num_lock,
        .PRINT_SCREEN => .unknown,
        .PAUSE => .pause,
        .F1 => .f1,
        .F2 => .f2,
        .F3 => .f3,
        .F4 => .f4,
        .F5 => .f5,
        .F6 => .f6,
        .F7 => .f7,
        .F8 => .f8,
        .F9 => .f9,
        .F10 => .f10,
        .F11 => .f11,
        .F12 => .f12,
        .F13 => .f13,
        .F14 => .f14,
        .F15, .F16, .F17, .F18, .F19, .F20, .F21, .F22, .F23, .F24, .F25 => .unknown,
        .KP_0 => .kp_0,
        .KP_1 => .kp_1,
        .KP_2 => .kp_2,
        .KP_3 => .kp_3,
        .KP_4 => .kp_4,
        .KP_5 => .kp_5,
        .KP_6 => .kp_6,
        .KP_7 => .kp_7,
        .KP_8 => .kp_8,
        .KP_9 => .kp_9,
        .KP_DECIMAL => .kp_decimal,
        .KP_DIVIDE => .kp_divide,
        .KP_MULTIPLY => .kp_multiply,
        .KP_SUBTRACT => .kp_subtract,
        .KP_ADD => .kp_add,
        .KP_ENTER => .kp_enter,
        .KP_EQUAL => .kp_equal,
        .LEFT_SHIFT => .left_shift,
        .LEFT_CONTROL => .left_control,
        .LEFT_ALT => .left_alt,
        .LEFT_SUPER => .unknown, // todo: double check
        .RIGHT_SHIFT => .right_shift,
        .RIGHT_CONTROL => .right_control,
        .RIGHT_ALT => .right_alt,
        .RIGHT_SUPER => .unknown, // todo: double check
        .MENU => .menu,
    };
}

pub fn mod(m: u32) dvui.enums.Mod {
    var res: u16 = 0;
    if (m & sapp.modifier_shift != 0) res |= @intFromEnum(dvui.enums.Mod.lshift);
    if (m & sapp.modifier_ctrl != 0) res |= @intFromEnum(dvui.enums.Mod.lcontrol);
    if (m & sapp.modifier_alt != 0) res |= @intFromEnum(dvui.enums.Mod.lalt);
    // TODO: unsure about this one
    if (m & sapp.modifier_super != 0) res |= @intFromEnum(dvui.enums.Mod.lcommand);
    return @enumFromInt(res);
}

pub fn button(b: sapp.Mousebutton) dvui.enums.Button {
    return switch (b) {
        .LEFT => .left,
        .RIGHT => .right,
        .MIDDLE => .middle,
        .INVALID => .none,
    };
}
