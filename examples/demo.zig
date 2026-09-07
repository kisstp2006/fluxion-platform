// SPDX-License-Identifier: BSL-1.0

//! What this machine's windowing is, without opening anything.
//!
//! Opens the connection, says which backend answered, asks what the pointer can
//! be told to do, and closes everything again. Where there is no display at all
//! it says that, which is the answer rather than a failure.
//!
//! A small window appears for a moment near the end. It has to: X11 will not
//! grab a pointer for a window it has never shown, so a hidden one would report
//! that this session cannot lock the cursor when it can.

const std = @import("std");
const Io = std.Io;

const platform = @import("fluxion_platform");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    const gpa = init.arena.allocator();

    try out.writeAll("fluxion-platform\n\n");

    // --- what this build could open ---------------------------------------
    try out.writeAll("this build supports\n");
    if (platform.supported.len == 0) {
        try out.writeAll("   nothing - this target has no windowing system to reach\n");
    } else {
        for (platform.supported) |candidate| {
            try out.print("   {t}\n", .{candidate});
        }
    }

    // --- what this machine actually has -----------------------------------
    try out.writeAll("\nthis machine\n");
    var ctx = platform.Context.init(gpa, .{}) catch |err| {
        try out.print("   no connection: {t}\n", .{err});
        try out.writeAll(
            \\
            \\That is an answer, not a crash. A machine with no graphical
            \\session reports it and a program decides what to do about it.
            \\
        );
        try out.flush();
        return;
    };
    defer ctx.deinit();

    try out.print("   opened {t}\n", .{ctx.backend()});
    try out.print("   {d} window(s)\n", .{ctx.windowCount()});

    // Pumping with nothing open is valid, and produces nothing.
    try ctx.pump();
    var count: usize = 0;
    while (ctx.poll()) |_| count += 1;
    try out.print("   {d} event(s) waiting\n", .{count});

    // --- what is plugged in -------------------------------------------------
    // Modes are counted rather than listed: a desktop monitor has dozens, and
    // the interesting number is how many resolutions a program could offer.
    try out.writeAll("\nmonitors\n");
    const screens = ctx.monitors();
    if (screens.len == 0) {
        try out.writeAll("   none reported\n");
    } else {
        for (screens) |*mon| {
            try out.print("   {f}\n", .{mon.*});
            try out.print(
                "      at {d},{d}  work {d}x{d}  scale {d:.2}\n",
                .{ mon.bounds.x, mon.bounds.y, mon.work_area.width, mon.work_area.height, mon.scale_x },
            );
            if (mon.physical_width_mm != 0) {
                try out.print(
                    "      {d}x{d} mm\n",
                    .{ mon.physical_width_mm, mon.physical_height_mm },
                );
            }
            try out.print("      {d} mode(s), largest {f}\n", .{ mon.modes.len, mon.largestMode() });
        }
    }

    // --- what a window could be drawn into ----------------------------------
    // A context is decided when the window is made, so asking means making one.
    // It is never shown, which is enough for the driver to answer.
    try out.writeAll("\ndrawing\n");
    if (ctx.createWindow(.{ .visible = false, .gl = .{} })) |probe| {
        defer probe.destroy();
        if (probe.contextConfig()) |config| {
            try out.print("   opengl   {f}\n", .{config});
        }
    } else |err| {
        try out.print("   opengl   no ({t})\n", .{err});
    }

    // Vulkan needs no window to answer: what a session needs is a property of
    // the backend rather than of anything that was opened.
    for (ctx.requiredVulkanExtensions()) |name| {
        try out.print("   vulkan   {s}\n", .{std.mem.span(name)});
    }

    // --- what is plugged into the machine ------------------------------------
    // One pump, because that is what fills the list: a controller is polled
    // rather than announced, and nothing has looked yet.
    try out.writeAll("\ncontrollers\n");
    try ctx.pump();
    var pads: usize = 0;
    for (ctx.gamepads(), 0..) |*pad, index| {
        if (!pad.connected) continue;
        pads += 1;
        try out.print("   {d}: {f}\n", .{ index, pad.* });
    }
    if (pads == 0) {
        try out.writeAll("   none\n");
    }

    // --- what the pointer can be told to do ---------------------------------
    // A window is needed to ask, and a *shown* one: X11 refuses to grab the
    // pointer for a window that was never mapped, so asking with a hidden one
    // would report "no" on a session that can do it perfectly well. It appears
    // for as long as this takes and no longer.
    //
    // The answers differ by compositor rather than by platform: a Wayland
    // session without `zwp_pointer_constraints_v1` cannot lock a pointer, and a
    // game that needs one should find that out here rather than mid-camera.
    try out.writeAll("\ncursor\n");
    if (ctx.createWindow(.{ .title = "fluxion-platform", .width = 240, .height = 180 })) |win| {
        defer win.destroy();

        // Let it actually map before asking; a grab on a window the server has
        // not shown yet fails for that reason rather than any other.
        for (0..30) |_| try ctx.pumpWait(10);

        const modes = [_]platform.CursorMode{ .hidden, .captured, .disabled };
        for (modes) |mode| {
            if (win.setCursorMode(mode)) {
                try out.print("   {t:<9} yes\n", .{mode});
            } else |err| {
                try out.print("   {t:<9} no ({t})\n", .{ mode, err });
            }
        }
        win.setCursorMode(.normal) catch {};

        const raw = win.setRawMouseMotion(true);
        _ = win.setRawMouseMotion(false);
        try out.print("   raw motion {s}\n", .{if (raw) "yes" else "no"});
    } else |err| {
        try out.print("   no window to ask with: {t}\n", .{err});
    }

    try out.writeAll("\nSee `zig build example-window` for one that opens something.\n");
    try out.flush();
}

test "the demo names a backend, or says there is none" {
    // Not a test of this file's output: a check that asking the question is
    // always safe, including where the answer is "nothing".
    const testing = std.testing;

    var ctx = platform.Context.init(testing.allocator, .{}) catch |err| {
        try testing.expect(err == error.Unsupported or err == error.NoDisplay or
            err == error.ConnectionFailed);
        return;
    };
    defer ctx.deinit();

    try testing.expect(ctx.backend() != .none);
}
