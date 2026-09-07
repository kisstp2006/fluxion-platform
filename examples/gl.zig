// SPDX-License-Identifier: BSL-1.0

//! A window with an OpenGL context, clearing to a colour that moves.
//!
//! The smallest program that proves the whole path works: a context was made,
//! it is current, `getProcAddress` found something to call, and a swap put it
//! on screen.
//!
//! **Four GL functions, declared here rather than loaded from a library.** This
//! library's job ends at `getProcAddress`; sorting what it returns into a table
//! is a loader's job, and `fluxion-gl` is the one to use for a real program.
//! Four hand-written pointers are enough to show that the context works and are
//! not a suggestion about how to write a renderer.

const std = @import("std");
const Io = std.Io;

const platform = @import("fluxion_platform");

/// The handful of entry points this example calls. `glClear` and `glClearColor`
/// are OpenGL 1.1, which on Windows means they come from the DLL's own exports
/// rather than from `wglGetProcAddress` - the backend looks in both places, so
/// a caller does not have to know that.
const Gl = struct {
    clearColor: *const fn (f32, f32, f32, f32) callconv(.c) void,
    clear: *const fn (u32) callconv(.c) void,
    viewport: *const fn (i32, i32, i32, i32) callconv(.c) void,
    getString: *const fn (u32) callconv(.c) ?[*:0]const u8,

    const color_buffer_bit: u32 = 0x00004000;
    const depth_buffer_bit: u32 = 0x00000100;
    const version: u32 = 0x1F02;
    const renderer: u32 = 0x1F01;

    fn load(win: platform.Window) ?Gl {
        return .{
            .clearColor = @ptrCast(win.getProcAddress("glClearColor") orelse return null),
            .clear = @ptrCast(win.getProcAddress("glClear") orelse return null),
            .viewport = @ptrCast(win.getProcAddress("glViewport") orelse return null),
            .getString = @ptrCast(win.getProcAddress("glGetString") orelse return null),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    var ctx = platform.Context.init(init.arena.allocator(), .{}) catch |err| {
        try out.print("no display: {t}\n", .{err});
        try out.flush();
        return;
    };
    defer ctx.deinit();

    const win = ctx.createWindow(.{
        .title = "fluxion-platform: OpenGL",
        .width = 640,
        .height = 480,
        .gl = .{ .major = 3, .minor = 3, .profile = .core },
    }) catch |err| {
        // Worth telling apart from any other failure: the window system is
        // fine and it is OpenGL that is missing.
        try out.print("no context: {t}\n", .{err});
        try out.flush();
        return;
    };
    defer win.destroy();

    try win.makeContextCurrent();

    // Asked for rather than assumed: a driver may hand back a newer version
    // than the one requested, and `.adaptive` is refused where the extension
    // for it is missing.
    win.setSwapInterval(.vsync) catch |err| {
        try out.print("swap interval refused: {t}\n", .{err});
    };

    const gl = Gl.load(win) orelse {
        try out.writeAll("the context is there but glClear is not, which should not happen\n");
        try out.flush();
        return;
    };

    if (win.contextConfig()) |config| try out.print("asked for {f}\n", .{config});
    if (gl.getString(Gl.version)) |text| try out.print("got       {s}\n", .{std.mem.span(text)});
    if (gl.getString(Gl.renderer)) |text| try out.print("on        {s}\n", .{std.mem.span(text)});
    try out.writeAll("escape closes it\n");
    try out.flush();

    var frame: u32 = 0;
    while (!win.shouldClose()) {
        try ctx.pump();
        while (ctx.poll()) |ev| switch (ev) {
            .close => win.setShouldClose(true),
            .key => |k| if (k.key == .escape and k.action == .press) win.setShouldClose(true),
            // The framebuffer, not the window: on a scaled display the two are
            // different numbers and this is the one in pixels.
            .framebuffer_resize => |r| gl.viewport(0, 0, @intCast(r.width), @intCast(r.height)),
            else => {},
        };

        const t = @as(f32, @floatFromInt(frame % 240)) / 240.0;
        gl.clearColor(0.1, t, 1.0 - t, 1.0);
        gl.clear(Gl.color_buffer_bit | Gl.depth_buffer_bit);

        try win.swapBuffers();
        frame += 1;

        // Long enough to see it work, short enough not to sit there.
        if (frame > 600) win.setShouldClose(true);
    }

    try out.print("{d} frames\n", .{frame});
    try out.flush();
}
