// SPDX-License-Identifier: BSL-1.0

//! What the pointer does, checked against whichever backend this machine has.
//!
//! The same shape as the window-state tests: a call that answers
//! `error.Unavailable` is passing, because a phone has no pointer to hide and
//! Wayland genuinely will not let a client put one anywhere. What is checked is
//! that each says so, that the mode the library reports is the mode it was
//! asked for, and that nothing is left holding the pointer afterwards.
//!
//! **The last of those is the one worth having.** An X11 grab outlives the
//! program that took it: leave one behind and every other window on the machine
//! stops responding to the mouse until the display is reset. So the tests put
//! the pointer back whatever happens.

const std = @import("std");
const testing = std.testing;

const Context = @import("Context.zig");
const Window = @import("Window.zig");
const cursor = @import("cursor.zig");
const platform = @import("platform.zig");

const Fixture = struct {
    ctx: Context = undefined,
    win: Window = undefined,

    fn open(self: *Fixture) bool {
        self.ctx = Context.init(testing.allocator, .{}) catch return false;
        self.win = self.ctx.createWindow(.{
            .title = "fluxion-platform cursor",
            .width = 400,
            .height = 300,
            .visible = false,
        }) catch {
            self.ctx.deinit();
            return false;
        };
        return true;
    }

    fn close(self: *Fixture) void {
        // Back to normal before anything else: a mode left set is a grab left
        // held, and on X11 that is every other program's problem too.
        self.win.setCursorMode(.normal) catch {};
        self.win.destroy();
        self.ctx.deinit();
    }
};

fn allowed(result: anyerror!void) !void {
    result catch |err| switch (err) {
        error.Unavailable => return,
        else => return err,
    };
}

test "a mode that was set is the mode that reads back" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    const win = fixture.win;

    // What every window starts as.
    try testing.expectEqual(cursor.Mode.normal, win.cursorMode());

    const wanted = [_]cursor.Mode{ .hidden, .captured, .disabled, .normal };
    for (wanted) |mode| {
        win.setCursorMode(mode) catch |err| switch (err) {
            // A compositor without pointer constraints, or a phone. Both are
            // answers, and the mode is then left as it was.
            error.Unavailable => continue,
            else => return err,
        };
        try testing.expectEqual(mode, win.cursorMode());
    }
}

test "setting the mode it is already in is not an error" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    try allowed(fixture.win.setCursorMode(.normal));
    try allowed(fixture.win.setCursorMode(.normal));
    try testing.expectEqual(cursor.Mode.normal, fixture.win.cursorMode());
}

test "raw motion answers whether it was actually turned on" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    const win = fixture.win;

    // The answer is what matters, not which way it goes: X11 without XInput2
    // says no, Win32 says yes, and a program that is told no can turn down its
    // own sensitivity instead of pretending.
    const granted = win.setRawMouseMotion(true);
    try testing.expectEqual(granted, win.rawMouseMotion());

    // Turning it off always works, whether or not it was ever on.
    _ = win.setRawMouseMotion(false);
    try testing.expect(!win.rawMouseMotion());
}

test "every shape is either set or refused by name" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    const shapes = std.enums.values(cursor.Shape);
    for (shapes) |shape| {
        fixture.win.setCursorShape(shape) catch |err| switch (err) {
            error.Unavailable => {
                // Only the ones a system is allowed not to have. An I-beam
                // missing would be a bug, not a platform difference.
                try testing.expect(shape.optional() or platform.supported.len == 0);
            },
            else => return err,
        };
    }
}

test "the pointer can be put somewhere, or the backend says it cannot" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();

    // Wayland refuses on purpose: a client that could move the pointer could
    // move it out from under the user's hand.
    try allowed(fixture.win.setCursorPos(50, 40));
}

test "a stale window refuses every cursor call rather than crashing" {
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    const stale: Window = .{ .ctx = &ctx, .id = @enumFromInt(999) };

    try testing.expectError(error.Unavailable, stale.setCursorMode(.disabled));
    try testing.expectError(error.Unavailable, stale.setCursorPos(0, 0));
    try testing.expectError(error.Unavailable, stale.setCursorShape(.ibeam));
    try testing.expect(!stale.setRawMouseMotion(true));

    // And the readers answer with what a window that is not there would be.
    try testing.expectEqual(cursor.Mode.normal, stale.cursorMode());
    try testing.expect(!stale.rawMouseMotion());
}

test "a failed mode change leaves the mode alone" {
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    // This backend refuses everything, so it is the one place a failure is
    // certain - and the thing to check is that the library did not record a
    // mode the system never entered.
    const stale: Window = .{ .ctx = &ctx, .id = @enumFromInt(1) };
    try testing.expectError(error.Unavailable, stale.setCursorMode(.disabled));
    try testing.expectEqual(cursor.Mode.normal, stale.cursorMode());
}
