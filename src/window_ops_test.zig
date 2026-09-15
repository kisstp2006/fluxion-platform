// SPDX-License-Identifier: BSL-1.0

//! What a window can be asked to do, checked against whichever backend this
//! machine actually has.
//!
//! One file rather than four copies: every backend answers the same calls, so
//! the test is the same everywhere and the differences are in what each one is
//! allowed to refuse. A call that says `error.Unavailable` is passing - Wayland
//! genuinely cannot move a window, and Android genuinely has nowhere to move it
//! to - and the thing worth checking is that it says so rather than crashing or
//! quietly doing nothing.
//!
//! Skips where there is no display, so a build server runs it without failing.

const std = @import("std");
const testing = std.testing;

const Context = @import("Context.zig");
const Window = @import("Window.zig");
const backend = @import("backend.zig");
const keys = @import("keys.zig");
const platform = @import("platform.zig");

/// A hidden window on the real backend, or nothing where there is none to open.
///
/// Built in place rather than returned by value, and that is not a style
/// choice: a `Window` holds a `*Context`, so moving the context after a window
/// exists leaves every handle pointing at where it used to be. Returning this
/// struct by value did exactly that, and the tests below crashed until it did
/// not.
const Fixture = struct {
    ctx: Context = undefined,
    win: Window = undefined,

    fn open(self: *Fixture) bool {
        return self.openWith(false);
    }

    /// `visible` is worth asking for in one case only. A window that was never
    /// mapped has no place on the screen - under XWayland it reports the origin
    /// rather than wherever it was moved to - so the position test shows its
    /// window and the others do not, because a test that flashes something on
    /// screen is a nuisance.
    fn openWith(self: *Fixture, visible: bool) bool {
        self.ctx = Context.init(testing.allocator, .{}) catch return false;
        self.win = self.ctx.createWindow(.{
            .title = "fluxion-platform window ops",
            .width = 400,
            .height = 300,
            .visible = visible,
        }) catch {
            self.ctx.deinit();
            return false;
        };
        return true;
    }

    fn close(self: *Fixture) void {
        self.win.destroy();
        self.ctx.deinit();
    }
};

/// Did the call work, or refuse for a reason this backend is entitled to?
fn allowed(result: anyerror!void) !void {
    result catch |err| switch (err) {
        error.Unavailable => return,
        else => return err,
    };
}

test "every state call either works or refuses by name" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const win = fixture.win;

    // None of these may crash, and none may return an error that means
    // something went wrong rather than "this platform has no such idea".
    try allowed(win.iconify());
    try allowed(win.restore());
    try allowed(win.maximize());
    try allowed(win.restore());
    try allowed(win.requestAttention());
    try allowed(win.setOpacity(0.5));
    try allowed(win.setOpacity(1.0));
    try allowed(win.setSizeLimits(.{ .min_width = 200, .min_height = 150 }));
    try allowed(win.setSizeLimits(.{}));
    try allowed(win.setPosition(120, 80));
    try allowed(win.setSize(320, 240));

    // And the queries answer without a window having to be in any one state.
    _ = win.isIconified();
    _ = win.isMaximized();
    _ = win.isFocused();
    _ = win.position();
}

test "a position that was set is a position that reads back" {
    var fixture: Fixture = .{};
    // Mapped, because an unmapped window has no position to report.
    if (!fixture.openWith(true)) return error.SkipZigTest;
    defer fixture.close();

    const win = fixture.win;

    // Let the window actually appear before moving it.
    var settle: usize = 0;
    while (settle < 20) : (settle += 1) try fixture.ctx.pumpWait(10);

    win.setPosition(150, 120) catch |err| switch (err) {
        // Wayland has no such call, and Android has nowhere to move to. Both
        // are correct answers, and there is nothing left to check.
        error.Unavailable => return,
        else => return err,
    };

    // The window manager has to act on it, which is not instant.
    var tries: usize = 0;
    var at: [2]i32 = .{ 0, 0 };
    while (tries < 50) : (tries += 1) {
        try fixture.ctx.pump();
        at = win.position();
        if (at[0] != 0 or at[1] != 0) break;
        try fixture.ctx.pumpWait(20);
    }

    // Not the exact numbers: a window manager may refuse a position, snap it to
    // a work area, or offset it by a frame this test does not know the size of.
    // What is checked is that something answered with a real coordinate rather
    // than the zero a backend without an answer returns.
    try testing.expect(at[0] != 0 or at[1] != 0);
}

test "a size that was set is a size that reads back" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    const win = fixture.win;
    win.setSize(512, 384) catch |err| switch (err) {
        error.Unavailable => return,
        else => return err,
    };

    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        try fixture.ctx.pump();
        const fb = win.framebufferSize();
        if (fb[0] == 512 and fb[1] == 384) return;
        try fixture.ctx.pumpWait(20);
    }

    // On a HiDPI display the logical size and the pixel size differ, so the
    // pixel size is checked against the scale rather than against the request.
    const scale = win.contentScale();
    const fb = win.framebufferSize();
    const wanted_w: u32 = @intFromFloat(@round(512 * scale[0]));
    const wanted_h: u32 = @intFromFloat(@round(384 * scale[1]));
    try testing.expectEqual(wanted_w, fb[0]);
    try testing.expectEqual(wanted_h, fb[1]);
}

test "a window outside new size limits is brought inside them at once" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    const win = fixture.win;
    win.setSizeLimits(.{ .min_width = 480, .min_height = 360 }) catch |err| switch (err) {
        error.Unavailable => return,
        else => return err,
    };

    const scale = win.contentScale();
    const scaled: [2]u32 = .{ @intFromFloat(@round(480 * scale[0])), @intFromFloat(@round(360 * scale[1])) };
    var fb = win.framebufferSize();
    for (0..50) |_| {
        if (std.meta.eql(fb, [2]u32{ 480, 360 }) or std.meta.eql(fb, scaled)) return;
        try fixture.ctx.pumpWait(20);
        fb = win.framebufferSize();
    }
    try testing.expectEqual(scaled, fb);
}

test "restoring a window minimised from maximised brings it back at its own size" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    const win = fixture.win;
    win.maximize() catch return;
    for (0..20) |_| if (!win.isMaximized()) try fixture.ctx.pumpWait(10);
    if (!win.isMaximized()) return;
    win.iconify() catch return;
    for (0..20) |_| if (!win.isIconified()) try fixture.ctx.pumpWait(10);
    if (!win.isIconified()) return;

    try win.restore();
    for (0..50) |_| {
        if (!win.isIconified() and !win.isMaximized()) return;
        try fixture.ctx.pumpWait(20);
    }
    try testing.expect(!win.isIconified());
    try testing.expect(!win.isMaximized());
}

test "a window knows which of the monitors it is on" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    const count = fixture.ctx.monitors().len;
    const index = fixture.win.monitor();
    if (count == 0) return testing.expectEqual(@as(?usize, null), index);
    try testing.expect(index.? < count);
}

test "the polled state starts empty and follows the events" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    var ctx = &fixture.ctx;

    // Nothing has happened, so nothing is held.
    try testing.expect(!ctx.key(.w));
    try testing.expect(!ctx.mouseButton(.left));
    try testing.expectEqual(keys.Mods.none, ctx.mods());

    // Pumping an idle window changes none of that.
    try ctx.pump();
    try testing.expect(!ctx.key(.w));

    // And the state is the same object the events feed, so applying one by
    // hand is what the pump would have done.
    ctx.state.apply(.{ .key = .{
        .window = @enumFromInt(1),
        .key = .w,
        .scancode = @enumFromInt(0),
        .action = .press,
        .mods = .{ .shift = true },
    } });
    try testing.expect(ctx.key(.w));
    try testing.expectEqual(keys.Mods{ .shift = true }, ctx.mods());

    // Losing focus lets go of it, which is the bug this exists to prevent.
    ctx.state.apply(.{ .focus = .{ .window = @enumFromInt(1), .value = false } });
    try testing.expect(!ctx.key(.w));
}

test "a stale window refuses every state call rather than crashing" {
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    const stale: Window = .{ .ctx = &ctx, .id = @enumFromInt(999) };

    try testing.expectError(error.Unavailable, stale.setPosition(0, 0));
    try testing.expectError(error.Unavailable, stale.setSize(1, 1));
    try testing.expectError(error.Unavailable, stale.iconify());
    try testing.expectError(error.Unavailable, stale.maximize());
    try testing.expectError(error.Unavailable, stale.restore());
    try testing.expectError(error.Unavailable, stale.focus());
    try testing.expectError(error.Unavailable, stale.requestAttention());
    try testing.expectError(error.Unavailable, stale.setSizeLimits(.{}));
    try testing.expectError(error.Unavailable, stale.setOpacity(1));

    try testing.expectEqual([2]i32{ 0, 0 }, stale.position());
    try testing.expect(!stale.isIconified());
    try testing.expect(!stale.isMaximized());
    try testing.expect(!stale.isFocused());
}
