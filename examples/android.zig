// SPDX-License-Identifier: BSL-1.0

//! The same loop as `window.zig`, on Android.
//!
//! Android has no `main` and no stdout, so this differs from the desktop
//! example in exactly two ways: the entry point is `fluxionMain`, which the
//! backend's `ANativeActivity_onCreate` starts a thread for, and every line
//! goes to logcat instead of a terminal.
//!
//! Everything between those is the same code: pump, drain the queue, act. The
//! two events a desktop never sends - `.surface_lost` and `.surface_created` -
//! are the ones worth watching here, and on Android they are also when a GL
//! context appears and disappears: the surface is destroyed every time the app
//! goes to the background, and the context goes with it.

const std = @import("std");

const platform = @import("fluxion_platform");

const log_info: c_int = 4;
const tag = "fluxion";

extern "log" fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;

// Three GL functions, declared here rather than loaded from a library: this
// library's job ends at `getProcAddress`, and a real program would hand what it
// returns to a loader. Three is enough to prove the context works.
//
// Something has to be drawn, and not only to have something to look at: a
// window with nothing in it is not a visible surface, and the system routes
// touch by hit-testing visible surfaces. The clear below is what makes the
// touch events further down real.
const Gl = struct {
    clearColor: *const fn (f32, f32, f32, f32) callconv(.c) void,
    clear: *const fn (u32) callconv(.c) void,
    getString: *const fn (u32) callconv(.c) ?[*:0]const u8,

    const color_buffer_bit: u32 = 0x00004000;
    const version: u32 = 0x1F02;
    const renderer: u32 = 0x1F01;

    fn load(win: platform.Window) ?Gl {
        return .{
            .clearColor = @ptrCast(win.getProcAddress("glClearColor") orelse return null),
            .clear = @ptrCast(win.getProcAddress("glClear") orelse return null),
            .getString = @ptrCast(win.getProcAddress("glGetString") orelse return null),
        };
    }
};

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    _ = __android_log_write(log_info, tag, line.ptr);
}

/// What the backend's thread calls. Not `main`: Android never calls one.
export fn fluxionMain() void {
    run() catch |err| log("failed: {t}", .{err});
}

fn run() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    log("fluxionMain started", .{});

    var ctx = platform.Context.init(gpa, .{}) catch |err| {
        log("no context: {t}", .{err});
        return;
    };
    defer ctx.deinit();

    log("backend {t}", .{ctx.backend()});

    // OpenGL ES, which is the only kind an Android driver has. Asked for with
    // the window because a window's config is decided when it is made - and
    // granted later, at `.surface_created`, because there is no surface yet.
    var win = try ctx.createWindow(.{
        .title = "fluxion",
        .gl = .{ .api = .opengl_es, .major = 3, .minor = 0 },
    });
    defer win.destroy();

    // A second window is the one thing Android has not got, and saying so is
    // better than handing back the same one twice.
    if (ctx.createWindow(.{})) |_| {
        log("BUG: a second window was allowed", .{});
    } else |err| {
        log("second window refused: {t}", .{err});
    }

    var last_pad: platform.gamepad.State = .{};
    // Null while there is no surface, which on Android is most of the time an
    // app spends in the background.
    var gl: ?Gl = null;
    var frames: u32 = 0;
    var surfaces: u32 = 0;
    while (frames < 600) : (frames += 1) {
        // One pump per frame, and no other. `pump` drops whatever the last one
        // left unread, so pumping twice around a single `poll` loop throws
        // half the events away - which is a mistake worth making only once.
        try ctx.pumpWait(16);

        while (ctx.poll()) |ev| switch (ev) {
            .surface_created => |s| {
                surfaces += 1;
                log("surface created {d}x{d}", .{ s.width, s.height });

                // The context is new: the old one went with the old surface,
                // so it is made current again and every GL pointer is looked up
                // again. A program that cached them across a background trip
                // would be calling into a driver that has moved on.
                win.makeContextCurrent() catch |err| log("no context: {t}", .{err});
                win.setSwapInterval(.vsync) catch {};
                gl = Gl.load(win);
                if (gl) |g| {
                    if (g.getString(Gl.version)) |text| {
                        log("gl {s}", .{std.mem.span(text)});
                    }
                    if (g.getString(Gl.renderer)) |text| {
                        log("on {s}", .{std.mem.span(text)});
                    }
                }

                // The screen is only knowable once there is a surface: before
                // it, `monitors` is empty and that is the honest answer.
                for (ctx.monitors()) |*mon| {
                    log("monitor {f} scale {d:.2}", .{ mon.*, mon.scale_x });
                }
                // And a window here is already the whole screen, so this is
                // the one platform where going fullscreen is nothing to do.
                win.setFullscreen(.{ .borderless = 0 }) catch |err| {
                    log("fullscreen: {t}", .{err});
                };

                // Without this a phone shows no keyboard and types nothing at
                // all - there is no hardware one to fall back on.
                win.setTextInput(true) catch |err| log("text input: {t}", .{err});
            },
            .surface_lost => {
                // The pointers belong to a context that is about to be
                // destroyed, so they go now rather than being called once more.
                gl = null;
                log("surface lost", .{});
            },
            .resize => |r| log("resize {d}x{d}", .{ r.width, r.height }),
            .focus => |f| log("focus {}", .{f.value}),
            .resumed => log("resumed", .{}),
            .suspended => log("suspended", .{}),
            .close => log("close requested", .{}),
            .key => |k| log("key {f} {t}", .{ k.key, k.action }),
            .char => |ch| {
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(ch.codepoint, &utf8) catch 0;
                log("char U+{X:0>4} '{s}'", .{ ch.codepoint, utf8[0..len] });
            },
            .preedit => log("preedit {f}", .{ctx.preedit()}),
            .gamepad_connected => |index| {
                const pad = ctx.gamepad(index) orelse continue;
                log("gamepad {d} connected: {f}", .{ index, pad.* });
            },
            .gamepad_disconnected => |index| log("gamepad {d} gone", .{index}),
            .mouse_button => |b| log("touch {t} at {d:.0},{d:.0}", .{ b.action, b.x, b.y }),
            .cursor => {},
            else => {},
        };

        // What the first controller is doing, printed only when it changes -
        // a line per frame would bury everything else in the log.
        //
        // After the queue rather than before it. `pump` fills the state and
        // queues the connection notice together, so reading the state first
        // would print what a controller is doing one line above the event
        // saying it arrived.
        if (ctx.firstGamepad()) |pad| {
            if (!std.meta.eql(pad.state, last_pad)) {
                last_pad = pad.state;
                log("pad a={} b={} dpad={}{}{}{} lx={d:.2} ly={d:.2} lt={d:.2} rt={d:.2}", .{
                    pad.state.button(.a),
                    pad.state.button(.b),
                    pad.state.button(.dpad_up),
                    pad.state.button(.dpad_right),
                    pad.state.button(.dpad_down),
                    pad.state.button(.dpad_left),
                    pad.state.axis(.left_x),
                    pad.state.axis(.left_y),
                    pad.state.axis(.left_trigger),
                    pad.state.axis(.right_trigger),
                });
            }
        }

        // The frame. Nothing while the app is in the background, which is not
        // an idle loop being lazy - there is no surface to draw into and
        // swapping without one is an error.
        if (gl) |g| {
            const t = @as(f32, @floatFromInt(frames % 240)) / 240.0;
            g.clearColor(0.1, t, 1.0 - t, 1.0);
            g.clear(Gl.color_buffer_bit);
            win.swapBuffers() catch |err| log("swap failed: {t}", .{err});
        }
    }

    const fb = win.framebufferSize();
    log("done: {d} frames, {d} surface(s), {d}x{d}", .{ frames, surfaces, fb[0], fb[1] });
}
