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
//!   as it is typed, and the committed text arrives as characters afterwards;
//! - ctrl+C, then paste into another program, and the other way round: the
//!   clipboard is the system's, and what comes back from it is UTF-8 with
//!   `\n` between lines whatever wrote it. Ctrl+X empties the line as well.

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

    var typed: Typed = .{};

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
                // Not with alt: Windows sends AltGr as control and alt, and
                // AltGr and V is `@` on a Hungarian keyboard.
                if (k.mods.control and !k.mods.alt) try shortcut(&ctx, k.virtual, &typed, out);
            },

            .char => |ch| {
                // And the letter, after everything. This is what a text field
                // reads.
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(ch.codepoint, &utf8) catch 0;
                try out.print("char  U+{X:0>4} '{s}'\n", .{ ch.codepoint, utf8[0..len] });

                typed.append(utf8[0..len]);
                try out.print("      so far: {s}\n", .{typed.text()});
            },

            // The composition changed. Only that it changed - the text itself
            // is a polled value, because it is on screen until it is committed
            // and may still change.
            .preedit => try out.print("preedit {f}\n", .{ctx.preedit()}),

            else => {},
        };

        try out.flush();
    }

    try out.print("\ntyped: {s}\n", .{typed.text()});
    try out.flush();
}

/// What has been typed, as a text field would hold it.
const Typed = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn text(self: *const Typed) []const u8 {
        return self.buf[0..self.len];
    }

    /// As much as fits, cut where a character begins.
    fn append(self: *Typed, more: []const u8) void {
        const kept = platform.text.truncateUtf8(more, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..kept.len], kept);
        self.len += kept.len;
    }
};

/// Ctrl+C and ctrl+X put what was typed on the clipboard and ctrl+V types what
/// is there: the program's own shortcuts, through the system's clipboard.
fn shortcut(ctx: *platform.Context, key: platform.Key, typed: *Typed, out: *Io.Writer) !void {
    switch (key) {
        .c, .x => {
            ctx.setClipboardText(typed.text()) catch |err| return out.print("copy refused: {t}\n", .{err});
            try out.print("copied \"{s}\"\n", .{typed.text()});
            if (key == .x) typed.len = 0;
        },
        .v => {
            const pasted = ctx.clipboardText() catch |err| return out.print("paste refused: {t}\n", .{err});
            typed.append(pasted);
            try out.print("pasted \"{s}\"\n      so far: {s}\n", .{ pasted, typed.text() });
        },
        else => {},
    }
}
