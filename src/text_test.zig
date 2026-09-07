// SPDX-License-Identifier: BSL-1.0

//! Text input against a real backend.
//!
//! `text.zig` checks the composition buffer on its own and each backend checks
//! its own translation; this checks the seam - that turning text input on and
//! off either works or refuses by name, that a composition is readable at any
//! time, and that a window which has gone does not take a caller with it.
//!
//! Nothing here types anything. Synthesising a keystroke means injecting into
//! the window system, which is a different kind of test and a different kind of
//! machine; what this can check is that the calls around it behave.

const std = @import("std");
const testing = std.testing;

const Context = @import("Context.zig");
const Window = @import("Window.zig");
const text = @import("text.zig");

const Fixture = struct {
    ctx: Context = undefined,
    win: Window = undefined,

    fn open(self: *Fixture) bool {
        self.ctx = Context.init(testing.allocator, .{}) catch return false;
        self.win = self.ctx.createWindow(.{
            .title = "fluxion-platform text",
            .width = 320,
            .height = 240,
            .visible = false,
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

test "text input starts off and can be turned on and off" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const win = fixture.win;

    // Off by default, which is what keeps a soft keyboard off a game's screen
    // and a candidate window out of the way.
    try testing.expect(!win.textInput());

    if (win.setTextInput(true)) {
        try testing.expect(win.textInput());
        try win.setTextInput(false);
        try testing.expect(!win.textInput());
    } else |err| switch (err) {
        // A machine with no input method to talk to. The flag stays off,
        // because the call did not do anything.
        error.Unavailable => try testing.expect(!win.textInput()),
        else => return err,
    }
}

test "the caret can be reported, or the backend says it has nowhere to put it" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const win = fixture.win;

    // Refused is a correct answer on Wayland and on Android, where a soft
    // keyboard sits at the bottom of the screen whatever anyone says.
    try allowed(win.setTextInputArea(.{ .x = 100, .y = 50, .width = 2, .height = 18 }));

    // A zero-sized area is not special, and neither is one off the window: an
    // input method clamps it, and nothing here may reject it on the way past.
    try allowed(win.setTextInputArea(.{}));
    try allowed(win.setTextInputArea(.{ .x = -5000, .y = -5000, .width = 1, .height = 1 }));
}

test "the composition is readable at any time and is empty until something composes" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const ctx = &fixture.ctx;

    // Before a pump, after a pump, and with no input method at all. Never a
    // crash and never stale bytes from an earlier composition.
    try testing.expect(ctx.preedit().isEmpty());
    try ctx.pump();
    try testing.expect(ctx.preedit().isEmpty());

    const composing = ctx.preedit();
    try testing.expectEqualStrings("", composing.text());
    try testing.expect(std.unicode.utf8ValidateSlice(composing.text()));
    // No caret to draw while there is nothing to draw it in.
    try testing.expectEqual(@as(i32, -1), composing.cursor_begin);
}

test "a stale window refuses text input rather than reaching through it" {
    var ctx = Context.init(testing.allocator, .{}) catch return error.SkipZigTest;
    defer ctx.deinit();

    const win = ctx.createWindow(.{ .visible = false }) catch return error.SkipZigTest;
    win.destroy();

    try testing.expectError(error.Unavailable, win.setTextInput(true));
    try testing.expectError(error.Unavailable, win.setTextInputArea(.{}));
    try testing.expect(!win.textInput());
}

test "turning text input on twice is not an error" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const win = fixture.win;

    // A program that calls this every frame while a text field has focus - the
    // simplest way to write it - must not be punished for it.
    win.setTextInput(true) catch return error.SkipZigTest;
    try win.setTextInput(true);
    try win.setTextInput(false);
    try win.setTextInput(false);
}
