// SPDX-License-Identifier: BSL-1.0

//! A desktop loop, unchanged, in a browser.
//!
//! `gl.zig` again, near enough line for line: a `main`, a window with a
//! context, and a `while` that pumps, reads the queue and clears to a colour
//! that moves. Nothing here knows it is on a page.
//!
//! **What makes it possible is `pump`.** A page cannot be blocked - nothing is
//! drawn and nothing is heard until the module returns - so on the web a pump
//! is where the module is *suspended*, handing the browser its turn, and
//! resumed at the next animation frame with whatever the page heard in the
//! meantime. That takes JavaScript Promise Integration: Chrome and Edge since
//! 137 and Firefox since 153 have it, and the glue refuses by name in a
//! browser that does not, rather than hanging the tab.
//!
//! `web.zig` is the other shape - `init` and `frame` exports the page calls -
//! and it runs everywhere, Safari included.

const std = @import("std");

const platform = @import("fluxion_platform");
const webgl = @import("fluxion_webgl");
const c = webgl.enums;

pub const std_options: std.Options = .{ .logFn = platform.web.logFn };
pub const panic = platform.web.panic;

pub fn main() !void {
    var ctx = try platform.Context.init(std.heap.wasm_allocator, .{});
    defer ctx.deinit();

    const win = try ctx.createWindow(.{
        .title = "fluxion-platform: a main loop",
        .width = 640,
        .height = 480,
        .gl = .{ .api = .opengl_es, .major = 3, .minor = 0 },
    });
    defer win.destroy();

    try win.makeContextCurrent();
    try win.setSwapInterval(.vsync);
    const gl: webgl.Context = .init();

    if (win.contextConfig()) |config| std.log.info("asked for {f}", .{config});
    std.log.info("got       {f}", .{gl.version});
    std.log.info("a desktop loop, suspended at every pump; escape ends it", .{});

    var frame: u32 = 0;
    while (!win.shouldClose()) {
        // The browser's turn. Back at the next animation frame, with the
        // queue filled.
        try ctx.pump();
        while (ctx.poll()) |ev| switch (ev) {
            .close => win.setShouldClose(true),
            .key => |k| {
                if (k.action == .press) std.log.info("key   {f}", .{k.key});
                if (k.key == .escape and k.action == .press) win.setShouldClose(true);
            },
            .mouse_button => |b| if (b.action == .press) {
                std.log.info("click {t} at {d:.0},{d:.0}", .{ b.button, b.x, b.y });
            },
            .framebuffer_resize => |r| std.log.info("pixels {d}x{d}", .{ r.width, r.height }),
            .suspended => std.log.info("hidden - the loop sleeps in its pump until the page is shown", .{}),
            .resumed => std.log.info("shown again, after {d} frames", .{frame}),
            else => {},
        };

        // The framebuffer, not the window: on a scaled display the two are
        // different numbers and this is the one in pixels.
        const fb = win.framebufferSize();
        gl.viewport(0, 0, @intCast(fb[0]), @intCast(fb[1]));
        const t = @as(f32, @floatFromInt(frame % 240)) / 240.0;
        gl.clearColor(0.1, t, 1.0 - t, 1.0);
        gl.clear(c.color_buffer_bit);

        try win.swapBuffers();
        frame += 1;
    }

    std.log.info("{d} frames, and main returned", .{frame});
}
