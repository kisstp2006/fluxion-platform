// SPDX-License-Identifier: BSL-1.0

//! What every backend's clipboard shares: the text a program holds is UTF-8
//! with `\n` between lines, and these turn it into what each system keeps and
//! back again - UTF-16 for Windows and Java, Latin-1 for an old X11 program.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// How long a read waits for the program that owns the clipboard, per step of
/// the transfer. On X11 and Wayland that program is asked, and one that has
/// hung must not hang this one with it.
pub const timeout_ms = 1000;

pub const LineEnding = enum { lf, crlf };

/// How many UTF-16 units `text` becomes, with `\n` written as `ending` says.
pub fn utf16Len(text: []const u8, ending: LineEnding) usize {
    var units: usize = 0;
    var previous: u21 = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |c| {
        if (ending == .crlf and c == '\n' and previous != '\r') units += 1;
        units += if (c >= 0x10000) 2 else 1;
        previous = c;
    }
    return units;
}

/// `text`, which has to be UTF-8, as UTF-16 in `out`, which has to be
/// `utf16Len` units long. A `\n` that already has its `\r` does not get two.
pub fn toUtf16(text: []const u8, ending: LineEnding, out: []u16) void {
    var at: usize = 0;
    var previous: u21 = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |c| {
        if (ending == .crlf and c == '\n' and previous != '\r') {
            out[at] = '\r';
            at += 1;
        }
        if (c >= 0x10000) {
            const above = c - 0x10000;
            out[at] = @intCast(0xD800 + (above >> 10));
            out[at + 1] = @intCast(0xDC00 + (above & 0x3FF));
            at += 2;
        } else {
            out[at] = @intCast(c);
            at += 1;
        }
        previous = c;
    }
    std.debug.assert(at == out.len);
}

/// UTF-16 appended to `out` as UTF-8. A surrogate without its partner, which
/// UTF-16 from Windows or Java may hold and UTF-8 cannot, becomes U+FFFD.
pub fn appendUtf16(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), units: []const u16) Allocator.Error!void {
    try out.ensureUnusedCapacity(gpa, units.len);
    var it = std.unicode.Wtf16LeIterator.init(units);
    while (it.nextCodepoint()) |c| {
        const whole = if (std.unicode.isSurrogateCodepoint(c)) std.unicode.replacement_character else c;
        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(whole, &utf8) catch unreachable;
        try out.appendSlice(gpa, utf8[0..len]);
    }
}

/// ISO 8859-1 appended to `out` as UTF-8: X11's `STRING`, which is all an old
/// program offers.
pub fn appendLatin1(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), bytes: []const u8) Allocator.Error!void {
    try out.ensureUnusedCapacity(gpa, bytes.len * 2);
    for (bytes) |byte| {
        if (byte < 0x80) {
            out.appendAssumeCapacity(byte);
        } else {
            out.appendAssumeCapacity(0xC0 | (byte >> 6));
            out.appendAssumeCapacity(0x80 | (byte & 0x3F));
        }
    }
}

/// Turn what a backend read into the text every backend reports: without the
/// terminator a C program left on the end, with `\n` for every `\r\n`, and
/// with U+FFFD wherever the bytes were not UTF-8.
pub fn normalize(gpa: Allocator, text: *std.ArrayListUnmanaged(u8)) Allocator.Error!void {
    const bytes = text.items;
    var end = bytes.len;
    while (end > 0 and bytes[end - 1] == 0) end -= 1;

    var kept: usize = 0;
    for (bytes[0..end], 0..) |byte, i| {
        if (byte == '\r' and i + 1 < end and bytes[i + 1] == '\n') continue;
        bytes[kept] = byte;
        kept += 1;
    }
    text.shrinkRetainingCapacity(kept);

    if (std.unicode.utf8ValidateSlice(text.items)) return;
    var repaired: std.Io.Writer.Allocating = .init(gpa);
    defer repaired.deinit();
    repaired.writer.print("{f}", .{std.unicode.fmtUtf8(text.items)}) catch return error.OutOfMemory;
    text.deinit(gpa);
    text.* = repaired.toArrayList();
}

/// When a wait that starts now has to end, for the backends that wait on a
/// file descriptor. Monotonic, so a clock set back cannot stretch it.
pub const Deadline = struct {
    end_ms: i64,

    pub fn in(ms: u32) Deadline {
        return .{ .end_ms = (now() orelse 0) + ms };
    }

    /// What is left, in the form `poll` takes: zero once it has passed.
    pub fn left(self: Deadline) c_int {
        const current = now() orelse return 0;
        return @intCast(std.math.clamp(self.end_ms - current, 0, std.math.maxInt(c_int)));
    }

    fn now() ?i64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return null;
        return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn normalized(input: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, input);
    try normalize(testing.allocator, &list);
    return list.toOwnedSlice(testing.allocator);
}

fn expectNormalized(expected: []const u8, input: []const u8) !void {
    const got = try normalized(input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "a line ends in \\n, however the clipboard had it" {
    try expectNormalized("one\ntwo\n", "one\r\ntwo\r\n");
    try expectNormalized("one\ntwo", "one\ntwo");
    try expectNormalized("a\rb", "a\rb");
    try expectNormalized("a\r\n", "a\r\r\n");
    try expectNormalized("\n", "\r\n");
    try expectNormalized("", "");
}

test "the terminator a C program left on the end is not text" {
    try expectNormalized("abc", "abc\x00");
    try expectNormalized("abc", "abc\x00\x00\x00");
    try expectNormalized("a\x00b", "a\x00b");
    try expectNormalized("", "\x00");
}

test "bytes that are not UTF-8 become U+FFFD, and text that is stays as it was" {
    try expectNormalized("a\u{FFFD}b", "a\xFFb");
    try expectNormalized("caf\u{FFFD}", "caf\xE9");
    try expectNormalized("\u{FFFD}", "\xE2\x82");
    try expectNormalized("\u{FFFD}\u{FFFD}\u{FFFD}", "\xED\xA0\x80");
    try expectNormalized("árvíztűrő tükörfúrógép 😀", "árvíztűrő tükörfúrógép 😀");
    try expectNormalized("x\u{FFFD}\ny", "x\xC3\r\ny");
}

test "UTF-16 becomes UTF-8, and a surrogate on its own becomes U+FFFD" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);

    try appendUtf16(testing.allocator, &out, &.{ 'H', 0xE9, 0xD83D, 0xDE00, 0xD800, 'A', 0xDC00 });
    try testing.expectEqualStrings("Hé😀\u{FFFD}A\u{FFFD}", out.items);

    out.clearRetainingCapacity();
    try appendUtf16(testing.allocator, &out, &.{});
    try testing.expectEqualStrings("", out.items);
}

test "UTF-8 becomes UTF-16, with \\r\\n where the system wants it" {
    const cases = [_]struct { text: []const u8, ending: LineEnding, units: []const u16 }{
        .{ .text = "a\nb", .ending = .crlf, .units = &.{ 'a', '\r', '\n', 'b' } },
        .{ .text = "a\r\nb", .ending = .crlf, .units = &.{ 'a', '\r', '\n', 'b' } },
        .{ .text = "\n\n", .ending = .crlf, .units = &.{ '\r', '\n', '\r', '\n' } },
        .{ .text = "a\nb", .ending = .lf, .units = &.{ 'a', '\n', 'b' } },
        .{ .text = "é😀", .ending = .lf, .units = &.{ 0xE9, 0xD83D, 0xDE00 } },
        .{ .text = "", .ending = .crlf, .units = &.{} },
    };
    for (cases) |case| {
        const len = utf16Len(case.text, case.ending);
        try testing.expectEqual(case.units.len, len);
        const units = try testing.allocator.alloc(u16, len);
        defer testing.allocator.free(units);
        toUtf16(case.text, case.ending, units);
        try testing.expectEqualSlices(u16, case.units, units);
    }
}

test "text that goes out as UTF-16 comes back as the same text" {
    const text = "Hungarian: őű, Greek: αβγ, emoji: 🦎\nand a second line\n";
    const units = try testing.allocator.alloc(u16, utf16Len(text, .crlf));
    defer testing.allocator.free(units);
    toUtf16(text, .crlf, units);

    var back: std.ArrayListUnmanaged(u8) = .empty;
    defer back.deinit(testing.allocator);
    try appendUtf16(testing.allocator, &back, units);
    try normalize(testing.allocator, &back);
    try testing.expectEqualStrings(text, back.items);
}

test "Latin-1 is the first 256 codepoints" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendLatin1(testing.allocator, &out, "caf\xE9 \xA9 \xFF.");
    try testing.expectEqualStrings("café © ÿ.", out.items);
}

test "a deadline counts down, and has nothing left once it has passed" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    const later = Deadline.in(60_000);
    try testing.expect(later.left() > 50_000);
    const passed: Deadline = .{ .end_ms = 0 };
    try testing.expectEqual(@as(c_int, 0), passed.left());
}
