// SPDX-License-Identifier: BSL-1.0

//! What the display list looks like on whichever backend this machine has.
//!
//! `monitor.zig` checks the types on their own; this checks what a real
//! display server puts in them, which is where the surprises are - a compositor
//! that reports no work area, a virtual display with no mode list, a headless
//! session with nothing attached at all.
//!
//! An empty list is a pass. It is what a machine with no monitors should say,
//! and the tests below check that everything which *is* reported makes sense
//! rather than that anything is reported at all.

const std = @import("std");
const testing = std.testing;

const Context = @import("Context.zig");
const Window = @import("Window.zig");
const monitor = @import("monitor.zig");

/// A context on the real backend, or nothing where there is none to open.
///
/// In place rather than by value, for the reason `window_ops_test.zig` gives:
/// a `Window` points back at its context, and moving one breaks the other.
const Fixture = struct {
    ctx: Context = undefined,

    fn open(self: *Fixture) bool {
        self.ctx = Context.init(testing.allocator, .{}) catch return false;
        return true;
    }

    fn close(self: *Fixture) void {
        self.ctx.deinit();
    }
};

test "whatever is reported is a monitor that could exist" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    for (fixture.ctx.monitors()) |*mon| {
        // A monitor with no pixels is not one; a backend that cannot measure
        // one should leave it out rather than report an empty rectangle.
        try testing.expect(mon.bounds.width > 0);
        try testing.expect(mon.bounds.height > 0);

        // The work area is a part of the monitor, not a separate thing that
        // happens to be nearby.
        try testing.expect(mon.work_area.width <= mon.bounds.width);
        try testing.expect(mon.work_area.height <= mon.bounds.height);
        try testing.expect(mon.work_area.x >= mon.bounds.x);
        try testing.expect(mon.work_area.y >= mon.bounds.y);

        // Scale is a multiplier. Zero would divide by nothing, and a negative
        // one means the field was never filled in.
        try testing.expect(mon.scale_x > 0);
        try testing.expect(mon.scale_y > 0);

        // The name is inside its buffer and terminated, so it can be handed
        // straight to a C call.
        try testing.expect(mon.name().len <= monitor.max_name_len);
        try testing.expectEqual(@as(u8, 0), mon.name_buf[mon.name_len]);

        for (mon.modes) |mode| {
            try testing.expect(mode.width > 0);
            try testing.expect(mode.height > 0);
        }
    }
}

test "the monitor list can be rebuilt without invalidating what it says" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const ctx = &fixture.ctx;

    const before = ctx.monitors().len;

    // Nothing was plugged in between the two calls, so the answer must not
    // change - and, more to the point, the second call must not read through
    // the mode slices the first one made.
    try ctx.refreshMonitors();
    try testing.expectEqual(before, ctx.monitors().len);

    for (ctx.monitors()) |*mon| {
        // The slices were rebuilt against the new array rather than left
        // pointing into the old one.
        try testing.expectEqual(mon.mode_count, mon.modes.len);
    }
}

test "the primary monitor is one of the monitors" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const ctx = &fixture.ctx;

    const list = ctx.monitors();
    const primary = ctx.primaryMonitor();

    if (list.len == 0) {
        try testing.expectEqual(@as(?*const monitor.Monitor, null), primary);
        return;
    }

    // Not just any monitor: the one at that address, so a caller can compare
    // it against the list rather than against a copy.
    const found = primary orelse return error.TestUnexpectedResult;
    var inside = false;
    for (list) |*mon| {
        if (mon == found) inside = true;
    }
    try testing.expect(inside);

    // Its own top left corner belongs to it, which is what makes `monitorAt`
    // usable for working out which display a window is on.
    const at = ctx.monitorAt(found.bounds.x, found.bounds.y);
    try testing.expect(at != null);
}

test "no two monitors claim the same pixel" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    const list = fixture.ctx.monitors();
    for (list, 0..) |*a, i| {
        for (list[i + 1 ..]) |*b| {
            const apart_x = a.bounds.x + @as(i32, @intCast(a.bounds.width)) <= b.bounds.x or
                b.bounds.x + @as(i32, @intCast(b.bounds.width)) <= a.bounds.x;
            const apart_y = a.bounds.y + @as(i32, @intCast(a.bounds.height)) <= b.bounds.y or
                b.bounds.y + @as(i32, @intCast(b.bounds.height)) <= a.bounds.y;
            try testing.expect(apart_x or apart_y);
        }
    }
}

test "going fullscreen and back either works or refuses by name" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const ctx = &fixture.ctx;

    // Shown, because a window the server has never mapped cannot be given a
    // monitor to fill - and on X11 the request would be answered by nothing at
    // all rather than by an error.
    const win = ctx.createWindow(.{
        .title = "fluxion-platform fullscreen",
        .width = 320,
        .height = 240,
    }) catch return error.SkipZigTest;
    defer win.destroy();

    for (0..20) |_| ctx.pumpWait(5) catch {};

    if (ctx.monitors().len == 0) {
        // Nothing to fill. Asking must still fail by name rather than crash.
        try testing.expectError(error.Unavailable, win.setFullscreen(.{ .borderless = 0 }));
        return;
    }

    // A monitor that is not there is a caller's mistake and is refused, not a
    // reason to reach past the end of the list.
    try testing.expectError(
        error.Unavailable,
        win.setFullscreen(.{ .borderless = ctx.monitors().len + 5 }),
    );

    win.setFullscreen(.{ .borderless = 0 }) catch |err| switch (err) {
        error.Unavailable => return,
        else => return err,
    };
    try testing.expectEqual(@as(usize, 0), win.fullscreen().monitorIndex().?);

    for (0..20) |_| ctx.pumpWait(5) catch {};

    // And back, which is the half that a program leaving fullscreen needs to
    // work: a window that cannot return is a window the user cannot get out of.
    try win.setFullscreen(.windowed);
    try testing.expectEqual(@as(?usize, null), win.fullscreen().monitorIndex());
}
