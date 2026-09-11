// SPDX-License-Identifier: BSL-1.0

//! The window example, in a browser: a canvas, and every event it produces.
//!
//! Open `zig-out/web` after `zig build example-web`, served rather than as a
//! file. Every line this prints goes to the page's log and to the console.
//!
//! **This is the shape a page wants**, and it is worth naming because it is
//! not the shape of a program with a `main`:
//!
//!   * **The exports are the entry points.** `init` once, `frame` once per
//!     animation frame, `deinit` at the end - called by the page, whenever the
//!     page decides. Nothing here runs on its own.
//!   * **The loop body is the desktop one.** `frame` pumps, drains the queue
//!     and draws, exactly as the inside of `window.zig`'s `while` does. Only
//!     the `while` itself has moved into the browser.
//!   * **The state is global.** There is no `main` to own it on its stack, and
//!     a `Context` must not move once it has a window - a module-scope `var`
//!     is the honest way to say "this lasts as long as the page does".
//!
//! `web_loop.zig` is the other shape, for a browser that can suspend a module.
//!
//! Things worth trying, with the canvas focused:
//!
//!   F  fullscreen, and back
//!   L  lock the pointer - the square then follows the motion, without edges
//!   R  unaccelerated motion, where the browser has it
//!   T  type into the canvas, through the input method; escape stops
//!   M  fill the page, and give the space back
//!   C  the next cursor shape, and H hides it
//!
//! and dropping a file on the canvas, plugging in a controller and pressing a
//! button on it, and zooming the page with ctrl and plus.

const std = @import("std");

const platform = @import("fluxion_platform");
const webgl = @import("fluxion_webgl");
const c = webgl.enums;

/// Lines to the page, and panics that say what they were.
pub const std_options: std.Options = .{ .logFn = platform.web.logFn };
pub const panic = platform.web.panic;

const gpa = std.heap.wasm_allocator;

var ctx: platform.Context = undefined;
var win: platform.Window = undefined;
var gl: webgl.Context = undefined;

/// Where the square is drawn, in CSS pixels. The pointer, or - while it is
/// locked - wherever its motion has carried the square.
var marker: [2]f64 = .{ 0, 0 };
/// Between `.surface_lost` and `.surface_created` there is nothing to draw
/// with, and a draw call would only fill the console with errors.
var drawing = true;
var shape: usize = 0;
var last_pad: platform.gamepad.State = .{};
var moves: u64 = 0;

/// Open the context and the window. Called once, by the page.
///
/// Answers false rather than trapping, so the page can say why on screen.
export fn init() bool {
    start() catch |err| {
        std.log.err("could not start: {t}", .{err});
        return false;
    };
    return true;
}

fn start() !void {
    ctx = try platform.Context.init(gpa, .{});
    errdefer ctx.deinit();

    // OpenGL ES 3.0 is WebGL 2. The page made the context already - see
    // `index.html` - and this finds it, and says what it really is.
    win = try ctx.createWindow(.{
        .title = "fluxion-platform: web",
        .width = 960,
        .height = 540,
        .gl = .{ .api = .opengl_es, .major = 3, .minor = 0 },
    });
    errdefer win.destroy();

    gl = .init();

    const size = win.size();
    const fb = win.framebufferSize();
    std.log.info("{t}: {d}x{d} CSS px, {d}x{d} px, scale {d:.2}", .{
        ctx.backend(), size[0], size[1], fb[0], fb[1], win.contentScale()[0],
    });
    if (win.contextConfig()) |config| std.log.info("context  {f}", .{config});
    std.log.info("drawing  {f}", .{gl.version});
    for (ctx.monitors()) |*mon| {
        std.log.info("monitor  {f}, scale {d:.2}, work area {d}x{d}", .{
            mon.*, mon.scale_x, mon.work_area.width, mon.work_area.height,
        });
    }
    std.log.info("F fullscreen, L lock the pointer, R raw motion, T type, M fill the page, C cursor, H hide it", .{});
    marker = .{ @floatFromInt(size[0] / 2), @floatFromInt(size[1] / 2) };
}

/// One frame: the body of a desktop loop, without the loop.
export fn frame() bool {
    ctx.pump() catch |err| {
        std.log.err("pump failed: {t}", .{err});
        return false;
    };
    while (ctx.poll()) |ev| handle(ev);

    watchPad();
    draw();
    // Nothing to swap on a page - the browser shows the frame when this
    // returns - but a loop written for the desktop calls it, and it is
    // accepted so that the loop needs no change.
    win.swapBuffers() catch {};
    return !win.shouldClose();
}

export fn deinit() void {
    win.destroy();
    ctx.deinit();
}

fn handle(ev: platform.Event) void {
    switch (ev) {
        .key => |k| {
            std.log.info("key      {f} {t} [{f}] virtual {f} {f}", .{ k.key, k.action, k.mods, k.virtual, k.scancode });
            // A key with a modifier held is somebody typing - AltGr and M is
            // `<` on a Hungarian keyboard - and not a command. AltGr is right
            // alt, which a browser does not count as a modifier at all.
            const chord = k.mods.control or k.mods.alt or k.mods.super or ctx.key(.right_alt);
            if (k.action == .press and !chord) command(k.key);
        },
        .char => |ch| {
            var utf8: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(ch.codepoint, &utf8) catch 0;
            std.log.info("char     U+{X:0>4} '{s}'", .{ ch.codepoint, utf8[0..len] });
        },
        .preedit => std.log.info("preedit  {f}", .{ctx.preedit()}),

        .mouse_button => |b| std.log.info("button   {t} {t} at {d:.0},{d:.0}", .{ b.button, b.action, b.x, b.y }),
        .cursor => |cur| {
            if (win.cursorMode() == .disabled) {
                // No position while locked, only motion, and the square goes
                // where the motion takes it - clamped, or it would leave.
                const size = win.size();
                marker[0] = std.math.clamp(marker[0] + cur.dx, 0, @as(f64, @floatFromInt(size[0])));
                marker[1] = std.math.clamp(marker[1] + cur.dy, 0, @as(f64, @floatFromInt(size[1])));
            } else {
                marker = .{ cur.x, cur.y };
            }
            // Every move would bury everything else, so one line in sixty.
            moves += 1;
            if (moves % 60 == 1) std.log.debug("cursor   {d:.0},{d:.0} moved {d:.1},{d:.1}", .{ cur.x, cur.y, cur.dx, cur.dy });
        },
        .scroll => |s| std.log.info("scroll   {d:.2},{d:.2}", .{ s.x, s.y }),
        .cursor_enter => |e| std.log.info("pointer  {s}", .{if (e.value) "in" else "out"}),

        .resize => |r| std.log.info("size     {d}x{d} CSS px", .{ r.width, r.height }),
        .framebuffer_resize => |r| std.log.info("pixels   {d}x{d}", .{ r.width, r.height }),
        .scale => |s| std.log.info("scale    {d:.2}", .{s.x}),
        .focus => |f| std.log.info("focus    {}", .{f.value}),
        .maximize => |m| std.log.info("filling the page: {}", .{m.value}),

        // A hidden tab. Animation frames stop, so this is the last frame for
        // a while - the one to pause the music in.
        .suspended => std.log.info("hidden: the page gets no frames until it is shown", .{}),
        .resumed => std.log.info("shown again", .{}),

        // A lost WebGL context, which is the Android pair of events for the
        // same reason: everything made with it is gone.
        .surface_lost => {
            drawing = false;
            std.log.warn("the WebGL context was lost; nothing to draw with until it is back", .{});
        },
        .surface_created => |s| {
            drawing = true;
            std.log.info("the WebGL context is back, {d}x{d}", .{ s.width, s.height });
        },

        .drop => |d| for (d.paths, 0..) |name, index| {
            // A name and some bytes - a page never sees a path.
            if (platform.web.droppedFile(&ctx, index, gpa)) |bytes| {
                defer gpa.free(bytes);
                std.log.info("dropped  {s}, {d} bytes, starting {x}", .{ name, bytes.len, bytes[0..@min(bytes.len, 8)] });
            } else |err| {
                std.log.info("dropped  {s}, unreadable: {t}", .{ name, err });
            }
        },

        .gamepad_connected => |index| {
            const pad = ctx.gamepad(index) orelse return;
            std.log.info("gamepad  {d} connected: {f}", .{ index, pad.* });
        },
        .gamepad_disconnected => |index| std.log.info("gamepad  {d} gone", .{index}),

        .close => win.setShouldClose(true),
        else => {},
    }
}

/// What the keys at the top of this file do.
fn command(key: platform.Key) void {
    // While typing, a key is a letter and not a command - except the one that
    // stops the typing.
    if (win.textInput()) {
        if (key == .escape) {
            win.setTextInput(false) catch {};
            std.log.info("text input off", .{});
        }
        return;
    }

    switch (key) {
        .f => {
            const wanted: platform.Fullscreen = if (win.fullscreen() == .windowed) .{ .borderless = 0 } else .windowed;
            win.setFullscreen(wanted) catch |err| return std.log.warn("fullscreen: {t}", .{err});
            // The browser may want a click first; it gets one on the next.
            std.log.info("fullscreen asked for: {t}", .{wanted});
        },
        .l => {
            const wanted: platform.CursorMode = if (win.cursorMode() == .disabled) .normal else .disabled;
            win.setCursorMode(wanted) catch |err| return std.log.warn("cursor: {t}", .{err});
            std.log.info("cursor mode {t}{s}", .{ wanted, if (wanted == .disabled) " - a click takes the pointer if the key did not" else "" });
        },
        .r => {
            const granted = win.setRawMouseMotion(!win.rawMouseMotion());
            std.log.info("raw motion {s}", .{if (granted) "on" else "off, or not to be had"});
        },
        .t => {
            win.setTextInput(true) catch |err| return std.log.warn("text input: {t}", .{err});
            // Where the caret would be, so an input method opens beside it.
            win.setTextInputArea(.{ .x = 24, .y = 24, .width = 2, .height = 20 }) catch {};
            std.log.info("text input on: type, or use an input method; escape stops", .{});
        },
        .m => {
            if (win.isMaximized()) win.restore() catch {} else win.maximize() catch {};
        },
        .c => {
            const shapes = std.enums.values(platform.CursorShape);
            shape = (shape + 1) % shapes.len;
            win.setCursorShape(shapes[shape]) catch {};
            std.log.info("cursor shape {t}", .{shapes[shape]});
        },
        .h => {
            const wanted: platform.CursorMode = if (win.cursorMode() == .hidden) .normal else .hidden;
            win.setCursorMode(wanted) catch {};
            std.log.info("cursor mode {t}", .{wanted});
        },
        else => {},
    }
}

/// The first controller, printed when it changes rather than every frame.
fn watchPad() void {
    const pad = ctx.firstGamepad() orelse return;
    if (std.meta.eql(pad.state, last_pad)) return;
    last_pad = pad.state;
    std.log.info("pad      a={} b={} lx={d:.2} ly={d:.2} lt={d:.2} rt={d:.2}", .{
        pad.state.button(.a),
        pad.state.button(.b),
        pad.state.axis(.left_x),
        pad.state.axis(.left_y),
        pad.state.axis(.left_trigger),
        pad.state.axis(.right_trigger),
    });
}

/// A background that follows the square, and the square: no shaders, only
/// clears through a scissor, because this example is about the window.
fn draw() void {
    if (!drawing) return;

    const size = win.size();
    const fb = win.framebufferSize();
    if (size[0] == 0 or size[1] == 0) return;
    const scale: f64 = win.contentScale()[0];

    gl.viewport(0, 0, @intCast(fb[0]), @intCast(fb[1]));
    gl.disable(c.scissor_test);

    const fx: f32 = @floatCast(marker[0] / @as(f64, @floatFromInt(size[0])));
    const fy: f32 = @floatCast(marker[1] / @as(f64, @floatFromInt(size[1])));
    // Dimmed without the keyboard, which is what `.focus` is for.
    const light: f32 = if (win.isFocused()) 1 else 0.55;
    gl.clearColor(light * (0.08 + 0.25 * fx), light * 0.1, light * (0.12 + 0.25 * fy), 1);
    gl.clear(c.color_buffer_bit | c.depth_buffer_bit);

    // A controller's left stick pushes the square, so it can be seen working.
    if (ctx.firstGamepad()) |pad| {
        marker[0] = std.math.clamp(marker[0] + pad.state.axisDeadzone(.left_x, 0.15) * 8, 0, @as(f64, @floatFromInt(size[0])));
        marker[1] = std.math.clamp(marker[1] + pad.state.axisDeadzone(.left_y, 0.15) * 8, 0, @as(f64, @floatFromInt(size[1])));
    }

    // CSS pixels to device pixels, and top-down to GL's bottom-up.
    const half: f64 = 10 * scale;
    const x = marker[0] * scale;
    const y = @as(f64, @floatFromInt(fb[1])) - marker[1] * scale;
    gl.enable(c.scissor_test);
    gl.scissor(@intFromFloat(x - half), @intFromFloat(y - half), @intFromFloat(2 * half), @intFromFloat(2 * half));
    const pressed = ctx.mouseButton(.left) or ctx.mouseButton(.right);
    if (pressed) gl.clearColor(1, 0.85, 0.3, 1) else gl.clearColor(0.9, 0.92, 0.96, 1);
    gl.clear(c.color_buffer_bit);
    gl.disable(c.scissor_test);
}
