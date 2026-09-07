// SPDX-License-Identifier: BSL-1.0

//! Typing: the text a keyboard actually produces, and the input method that
//! stands between the two.
//!
//! **A key is not a letter.** `.key` events say which key moved, at a position
//! on the keyboard; `.char` events say what was typed, after the layout, the
//! dead keys, the compose sequence and whatever input method is running have
//! all had their say. A game reads the first. A text field reads the second,
//! and reading the first would spell the user's name wrong on every layout but
//! one.
//!
//! **Composition is a state, not an event.** While an input method is being
//! used - typing Japanese, or a compose sequence, or a dead key - there is text
//! on screen that has not been committed and may still change. The `.preedit`
//! event says it changed; `Context.preedit` says what it is now. That is the
//! same split the rest of this library uses: the queue says what happened, a
//! polled value says what is.
//!
//! A program that draws its own text field has to draw the preedit too,
//! underlined, at the caret - the input method will not draw it. One that does
//! not can ignore all of this and still get correct text from `.char`, because
//! an input method commits through the same path in the end.
//!
//! **Text input is off until it is asked for.** `Window.setTextInput(true)` is
//! what tells the system a text field has focus: it is what raises the soft
//! keyboard on a phone, and what lets an input method open its candidate
//! window. A game that never calls it never gets one in the middle of a
//! firefight.

const std = @import("std");
const testing = std.testing;

/// The longest composition this library keeps, in bytes of UTF-8.
///
/// Held inline rather than allocated, so reading the preedit is a field access
/// and there is nothing to free. Two hundred and fifty-five bytes is far more
/// than any input method composes at once - Japanese and Chinese commit every
/// few characters, and a compose sequence is two or three.
pub const max_preedit_bytes = 255;

/// Text being composed but not yet committed.
///
/// Valid until the next `pump`, and empty whenever nothing is being composed -
/// which is almost always, including on every platform that has no input
/// method running.
pub const Preedit = struct {
    buf: [max_preedit_bytes]u8 = @splat(0),
    len: u8 = 0,

    /// Where the caret sits inside the text, as a byte offset. `-1` means the
    /// input method does not want a caret drawn.
    cursor_begin: i32 = -1,
    /// The end of the selected range, as a byte offset. Equal to
    /// `cursor_begin` for a caret rather than a selection.
    cursor_end: i32 = -1,

    pub fn text(self: *const Preedit) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const Preedit) bool {
        return self.len == 0;
    }

    /// Replace the composition, truncating anything longer than this library
    /// keeps - and truncating on a codepoint boundary, because half a
    /// character is not text.
    pub fn set(self: *Preedit, value: []const u8, begin: i32, end: i32) void {
        const kept = truncateUtf8(value, max_preedit_bytes);
        @memcpy(self.buf[0..kept.len], kept);
        self.len = @intCast(kept.len);

        const limit: i32 = @intCast(kept.len);
        self.cursor_begin = if (begin < 0) -1 else @min(begin, limit);
        self.cursor_end = if (end < 0) -1 else @min(end, limit);
    }

    pub fn clear(self: *Preedit) void {
        self.len = 0;
        self.cursor_begin = -1;
        self.cursor_end = -1;
    }

    pub fn format(self: Preedit, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.len == 0) return w.writeAll("(nothing)");
        try w.print("\"{s}\"", .{self.buf[0..self.len]});
        if (self.cursor_begin >= 0) try w.print(" caret {d}", .{self.cursor_begin});
    }
};

/// The longest prefix of `value` that fits in `limit` bytes without cutting a
/// codepoint in half.
///
/// A UTF-8 continuation byte has its top two bits set to `10`, and a sequence
/// never starts with one - so walking back to the first byte that is not a
/// continuation finds where the last whole character began.
pub fn truncateUtf8(value: []const u8, limit: usize) []const u8 {
    if (value.len <= limit) return value;

    var end = limit;
    while (end > 0 and value[end] & 0xC0 == 0x80) end -= 1;
    return value[0..end];
}

/// Where an input method should put its candidate window, in the window's own
/// coordinates.
///
/// The caret, and how tall the line is. An input method puts its list of
/// candidates just below this and takes care not to cover it - which it can
/// only do if it is told where the text is.
pub const Area = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a composition longer than the buffer is cut on a character boundary" {
    var preedit: Preedit = .{};

    // Three-byte characters, so a naive truncation at 255 would leave two
    // thirds of one behind and produce text no renderer can draw.
    const long = "あ" ** 200;
    preedit.set(long, 0, 0);

    try testing.expect(preedit.text().len <= max_preedit_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(preedit.text()));
    // 255 / 3 = 85 whole characters.
    try testing.expectEqual(@as(usize, 255), preedit.text().len);
}

test "truncation leaves whole characters and nothing else" {
    // Two bytes each, so a limit of three has to drop back to two.
    try testing.expectEqualStrings("é", truncateUtf8("éé", 3));
    try testing.expectEqualStrings("éé", truncateUtf8("éé", 4));
    // Room to spare is not a reason to cut anything.
    try testing.expectEqualStrings("éé", truncateUtf8("éé", 100));
    try testing.expectEqualStrings("", truncateUtf8("é", 1));
    try testing.expectEqualStrings("abc", truncateUtf8("abcd", 3));
    try testing.expectEqualStrings("", truncateUtf8("", 0));
}

test "an empty composition says so rather than holding stale text" {
    var preedit: Preedit = .{};
    try testing.expect(preedit.isEmpty());
    try testing.expectEqualStrings("", preedit.text());

    preedit.set("にほん", 3, 3);
    try testing.expect(!preedit.isEmpty());
    try testing.expectEqualStrings("にほん", preedit.text());
    try testing.expectEqual(@as(i32, 3), preedit.cursor_begin);

    preedit.clear();
    try testing.expect(preedit.isEmpty());
    try testing.expectEqual(@as(i32, -1), preedit.cursor_begin);
    try testing.expectEqual(@as(i32, -1), preedit.cursor_end);
}

test "a caret past the end of the text is pulled back to it" {
    var preedit: Preedit = .{};

    // An input method that reports a caret in characters where this expects
    // bytes, or one that reports where the caret will be after the next key.
    // Either way it must not point outside the text.
    preedit.set("ab", 99, 99);
    try testing.expectEqual(@as(i32, 2), preedit.cursor_begin);
    try testing.expectEqual(@as(i32, 2), preedit.cursor_end);

    // And a negative one stays negative, because that is how "draw no caret"
    // is spelled.
    preedit.set("ab", -1, -1);
    try testing.expectEqual(@as(i32, -1), preedit.cursor_begin);
}

test "a composition prints as a person would read it" {
    var buf: [64]u8 = undefined;
    var preedit: Preedit = .{};
    try testing.expectEqualStrings("(nothing)", try std.fmt.bufPrint(&buf, "{f}", .{preedit}));

    preedit.set("nihon", 2, 2);
    try testing.expectEqualStrings(
        "\"nihon\" caret 2",
        try std.fmt.bufPrint(&buf, "{f}", .{preedit}),
    );

    // No caret asked for, so none printed.
    preedit.set("nihon", -1, -1);
    try testing.expectEqualStrings("\"nihon\"", try std.fmt.bufPrint(&buf, "{f}", .{preedit}));
}
