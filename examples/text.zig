// SPDX-License-Identifier: BSL-1.0

//! A window that takes typing, and prints what it got.
//!
//! The difference between a key and a letter, made visible. Every keystroke
//! prints twice: once as the key that moved - at its position on the keyboard,
//! and as the key the layout names it - and once as the text it produced after
//! the layout, the dead keys and the input method have all had their say.
//!
//! Worth trying, in order:
//!
//! - a letter, which prints the same both ways on a US layout and differently
//!   on any other - on a German or Hungarian keyboard, Z is the key at `y`,
//!   and its virtual key is `z`;
//! - shift and a number, which prints one key and a symbol that depends on the
//!   layout;
//! - a dead key - `'` then `e` on a US-international layout, or compose then
//!   `'` then `e` - which prints two keys and one letter;
//! - an input method, if one is installed: on Windows the composition appears
//!   as it is typed, and the committed text arrives as characters afterwards.

const std = @import("std");
const Io = std.Io;

const platform = @import("fluxion_platform");

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

    const win = try ctx.createWindow(.{
        .title = "fluxion-platform: text",
        .width = 640,
        .height = 240,
    });
    defer win.destroy();

    // Without this a phone shows no keyboard at all, and an input method has
    // not been told there is anywhere to type. On a desktop it is what lets a
    // candidate window open.
    if (win.setTextInput(true)) {
        try out.writeAll("text input on\n");
    } else |err| {
        try out.print("text input refused: {t}\n", .{err});
    }

    // Where the caret is, so that a candidate list appears beside the text
    // rather than across it. A real program moves this as the caret moves.
    win.setTextInputArea(.{ .x = 16, .y = 32, .width = 2, .height = 20 }) catch |err| {
        try out.print("caret position refused: {t}\n", .{err});
    };

    try out.writeAll("type something; escape closes it\n\n");
    try out.flush();

    var typed: [256]u8 = undefined;
    var typed_len: usize = 0;

    while (!win.shouldClose()) {
        try ctx.pumpWait(null);

        while (ctx.poll()) |ev| switch (ev) {
            .close => win.setShouldClose(true),

            .key => |k| {
                if (k.action != .press) continue;
                if (k.key == .escape) win.setShouldClose(true);
                // The position on the keyboard. `.a` is where `A` is on a US
                // layout and where `Q` is on a French one - which is exactly
                // why a text field must not read this. And the virtual key,
                // the name the layout gives it, which is what a shortcut
                // compares against.
                try out.print("key   {f}, virtual {f}\n", .{ k.key, k.virtual });
            },

            .char => |ch| {
                // And the letter, after everything. This is what a text field
                // reads.
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(ch.codepoint, &utf8) catch 0;
                try out.print("char  U+{X:0>4} '{s}'\n", .{ ch.codepoint, utf8[0..len] });

                if (typed_len + len <= typed.len) {
                    @memcpy(typed[typed_len..][0..len], utf8[0..len]);
                    typed_len += len;
                    try out.print("      so far: {s}\n", .{typed[0..typed_len]});
                }
            },

            // The composition changed. Only that it changed - the text itself
            // is a polled value, because it is on screen until it is committed
            // and may still change.
            .preedit => try out.print("preedit {f}\n", .{ctx.preedit()}),

            else => {},
        };

        try out.flush();
    }

    try out.print("\ntyped: {s}\n", .{typed[0..typed_len]});
    try out.flush();
}
