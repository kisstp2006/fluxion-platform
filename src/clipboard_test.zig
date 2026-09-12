// SPDX-License-Identifier: BSL-1.0

//! The clipboard against a real backend.
//!
//! Nothing here writes to it: a test run that replaced whatever the person
//! running it had copied would be a nuisance, and on a desktop with clipboard
//! history it would leave a trail there too. So this checks what can be
//! checked without that - that a read answers in this library's terms, and
//! that text which is not UTF-8 never reaches the system. The writing is
//! checked against the web backend's fake page, and by `example-text`.

const std = @import("std");
const testing = std.testing;

const Context = @import("Context.zig");

test "a read is UTF-8 with \\n between lines, or refused by name" {
    var ctx = Context.init(testing.allocator, .{}) catch return error.SkipZigTest;
    defer ctx.deinit();

    const text = ctx.clipboardText() catch |err| switch (err) {
        error.Unavailable => return,
        else => return err,
    };
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, text, "\r\n"));
    _ = ctx.hasClipboardText();
}

test "text that is not UTF-8 is refused before it reaches the system" {
    var ctx = Context.init(testing.allocator, .{}) catch return error.SkipZigTest;
    defer ctx.deinit();

    try testing.expectError(error.Unavailable, ctx.setClipboardText("caf\xE9"));
    try testing.expectError(error.Unavailable, ctx.setClipboardText("\xFF"));
}

test "a context with no windowing system has no clipboard" {
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    try testing.expectError(error.Unavailable, ctx.setClipboardText("text"));
    try testing.expectError(error.Unavailable, ctx.clipboardText());
    try testing.expect(!ctx.hasClipboardText());
}
