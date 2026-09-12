// SPDX-License-Identifier: BSL-1.0

//! A window, and every event it produces.
//!
//! Opens one, prints what happens to it, and closes on escape or on the window
//! button. `--frames N` closes after N pumps instead, so that
//! `zig build examples` finishes on its own rather than waiting for a person.
//! O and D open the system's file and folder dialogs.
//!
//! This is the shape of a frame loop: pump once, drain the queue, draw. There
//! is no callback anywhere, and the `switch` is exhaustive over what this
//! program cares about.

const std = @import("std");
const Io = std.Io;

const platform = @import("fluxion_platform");

/// f11 fills the monitor the window is on; f10 does it by switching that
/// monitor to its largest mode instead; f9 puts everything back.
///
/// Which monitor is worked out from where the window is, because a window
/// dragged to the second screen should fill the second screen.
fn fullscreenKey(
    ctx: *platform.Context,
    win: platform.Window,
    key: platform.Key,
    out: *Io.Writer,
) !void {
    switch (key) {
        .f9 => {
            try win.setFullscreen(.windowed);
            try out.writeAll("       windowed\n");
        },
        .f10, .f11 => {
            const at = win.position();
            const screens = ctx.monitors();
            var index: usize = 0;
            for (screens, 0..) |*mon, i| {
                if (mon.bounds.contains(at[0], at[1])) index = i;
            }
            if (screens.len == 0) return error.Unavailable;

            if (key == .f11) {
                try win.setFullscreen(.{ .borderless = index });
                try out.print("       borderless on {f}\n", .{screens[index]});
            } else {
                const mode = screens[index].largestMode();
                try win.setFullscreen(.{ .exclusive = .{ .monitor = index, .mode = mode } });
                try out.print("       exclusive {f}\n", .{mode});
            }
        },
        else => {},
    }
}

/// o asks for files and d for a folder, in the system's own dialog. The
/// answer is an event some frames later; the loop does not stop for it.
fn dialogKey(ctx: *platform.Context, win: platform.Window, key: platform.Key, out: *Io.Writer) !void {
    const id = switch (key) {
        .o => try ctx.openFileDialog(.{
            .window = win,
            .multiple = true,
            .filters = &.{
                .{ .name = "Images", .extensions = &.{ "png", "jpg" } },
                .{ .name = "Everything", .extensions = &.{"*"} },
            },
        }),
        .d => try ctx.openFolderDialog(.{ .window = win }),
        else => return,
    };
    try out.print("       dialog {d} open\n", .{@intFromEnum(id)});
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    const gpa = init.arena.allocator();

    const limit = try frameLimit(init, gpa);

    var ctx = platform.Context.init(gpa, .{}) catch |err| {
        try out.print("no windowing system here: {t}\n", .{err});
        try out.flush();
        return;
    };
    defer ctx.deinit();

    var win = try ctx.createWindow(.{
        .title = "fluxion-platform",
        .width = 960,
        .height = 540,
    });
    defer win.destroy();

    const fb = win.framebufferSize();
    const scale = win.contentScale();
    try out.print("{t}: {d}x{d} px, scale {d:.2}\n", .{ ctx.backend(), fb[0], fb[1], scale[0] });
    try out.writeAll("escape or the window button closes it\n");
    try out.writeAll("f11 fills the monitor, f10 switches its mode, f9 gives it back\n");
    try out.writeAll("o opens files, d a folder\n\n");
    try out.flush();

    var frames: u32 = 0;
    while (!win.shouldClose()) {
        try ctx.pump();

        while (ctx.poll()) |ev| switch (ev) {
            .close => {
                try out.writeAll("close requested\n");
                win.setShouldClose(true);
            },

            .key => |k| {
                try out.print("key    {f} {t} [{f}] virtual {f} scancode {f}\n", .{
                    k.key, k.action, k.mods, k.virtual, k.scancode,
                });
                if (k.key == .escape and k.action == .press) win.setShouldClose(true);
                if (k.action == .press) fullscreenKey(&ctx, win, k.key, out) catch |err| {
                    try out.print("       fullscreen: {t}\n", .{err});
                };
                if (k.action == .press) dialogKey(&ctx, win, k.virtual, out) catch |err| {
                    try out.print("       dialog: {t}\n", .{err});
                };
            },

            .file_dialog => |d| {
                try out.print("dialog {d}: {d} chosen\n", .{ @intFromEnum(d.id), d.paths.len });
                for (d.paths, 0..) |path, index| {
                    // The one way to read a choice that works on every platform;
                    // a folder has no bytes of its own to read.
                    if (ctx.chosenFile(index, gpa)) |bytes| {
                        try out.print("       {s} ({d} bytes)\n", .{ path, bytes.len });
                    } else |_| try out.print("       {s}\n", .{path});
                }
            },

            .char => |c| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c.codepoint, &buf) catch 0;
                try out.print("char   U+{X:0>4} '{s}'\n", .{ c.codepoint, buf[0..len] });
            },

            .mouse_button => |b| try out.print("button {t} {t} at {d:.0},{d:.0}\n", .{
                b.button, b.action, b.x, b.y,
            }),

            .scroll => |s| try out.print("scroll {d:.1},{d:.1}\n", .{ s.x, s.y }),

            .framebuffer_resize => |r| try out.print("pixels {d}x{d}\n", .{ r.width, r.height }),
            .resize => |r| try out.print("size   {d}x{d}\n", .{ r.width, r.height }),
            .scale => |s| try out.print("scale  {d:.2}\n", .{s.x}),
            .focus => |f| try out.print("focus  {}\n", .{f.value}),

            // The Android pair. Never sent by a desktop backend, and handled
            // here so that this example is a correct program on a phone too.
            .surface_lost => try out.writeAll("surface lost - release the swapchain\n"),
            .surface_created => |s| try out.print("surface {d}x{d}\n", .{ s.width, s.height }),

            // The cursor moves constantly and would drown everything else.
            .cursor => {},
            else => {},
        };

        try out.flush();

        frames += 1;
        if (limit) |max| if (frames >= max) break;
    }

    try out.print("\n{d} frames\n", .{frames});
    try out.flush();
}

/// `--frames N`, for a run that has to end on its own.
fn frameLimit(init: std.process.Init, arena: std.mem.Allocator) !?u32 {
    const arguments = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < arguments.len) : (i += 1) {
        if (!std.mem.eql(u8, arguments[i], "--frames")) continue;
        if (i + 1 >= arguments.len) return error.MissingValue;
        return try std.fmt.parseInt(u32, arguments[i + 1], 10);
    }
    return null;
}

test "a window opens, reports its size, and closes" {
    const testing = std.testing;

    var ctx = platform.Context.init(testing.allocator, .{}) catch return error.SkipZigTest;
    defer ctx.deinit();

    var win = ctx.createWindow(.{
        .title = "fluxion-platform test",
        .width = 400,
        .height = 300,
        // A test that flashes a window on screen is a nuisance, and everything
        // checked here works on a hidden one.
        .visible = false,
    }) catch return error.SkipZigTest;
    defer win.destroy();

    try testing.expect(win.alive());
    try testing.expect(!win.shouldClose());

    const fb = win.framebufferSize();
    try testing.expectEqual(@as(u32, 400), fb[0]);
    try testing.expectEqual(@as(u32, 300), fb[1]);

    // Pumping is safe with a window that nobody has touched.
    try ctx.pump();

    // The flag is the program's, so setting it is what ends a loop.
    win.setShouldClose(true);
    try testing.expect(win.shouldClose());

    // And a destroyed window says so rather than answering as if it were there.
    win.destroy();
    try testing.expect(!win.alive());
    try testing.expect(win.shouldClose());
}
