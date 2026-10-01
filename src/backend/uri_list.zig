// SPDX-License-Identifier: BSL-1.0

//! What X11's and Wayland's file drops share: the files arrive as
//! `text/uri-list` (RFC 2483) - one URI a line, `#` lines being comments - and
//! a drop is the local paths among them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// The name the list goes by, which both systems offer a drag of files under.
pub const mime = "text/uri-list";

/// The local paths in `text`, in its order, written into `arena`: each
/// `file:` URI on this machine, its `%XX` escapes undone. A URI of another
/// scheme or another host is left out, as is a line that is not one.
pub fn paths(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const path = localPath(line) orelse continue;
        const decoded = try decode(arena, path) orelse continue;
        try out.append(arena, decoded);
    }
    return out.items;
}

/// The path of a `file:` URI naming this machine, still escaped: after
/// `file://` an empty host or `localhost`, or `file:` with the path straight
/// after, as some programs write it. Null for anything else.
fn localPath(uri: []const u8) ?[]const u8 {
    const scheme = "file:";
    if (uri.len < scheme.len or !std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme)) return null;
    const rest = uri[scheme.len..];
    if (!std.mem.startsWith(u8, rest, "//")) return if (std.mem.startsWith(u8, rest, "/")) rest else null;
    const after = rest[2..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
    const host = after[0..slash];
    if (host.len > 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
    return after[slash..];
}

/// `text` with every `%XX` replaced by its byte. Null where an escape is cut
/// short or not hexadecimal, or decodes to a nought, which no path has.
fn decode(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    const out = try arena.alloc(u8, text.len);
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (len += 1) {
        if (text[i] != '%') {
            out[len] = text[i];
            i += 1;
            continue;
        }
        if (i + 3 > text.len) return null;
        const byte = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return null;
        if (byte == 0) return null;
        out[len] = byte;
        i += 3;
    }
    return out[0..len];
}

test "a list of files is the paths it names, escapes undone, comments and blank lines left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = "# dragged from a file manager\r\n" ++
        "file:///home/ada/Pictures/hero%20sheet.png\r\n" ++
        "\r\n" ++
        "file://localhost/tmp/%C3%A1rv%C3%ADzt%C5%B1r%C5%91.txt\r\n" ++
        "file:/srv/one%2Btwo\r\n";
    const got = try paths(arena.allocator(), list);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("/home/ada/Pictures/hero sheet.png", got[0]);
    try testing.expectEqualStrings("/tmp/árvíztűrő.txt", got[1]);
    try testing.expectEqualStrings("/srv/one+two", got[2]);
}

test "what is not a file on this machine is left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = "https://example.com/a.png\n" ++
        "file://another-machine/share/b.png\n" ++
        "file://\n" ++
        "file:relative/c.png\n" ++
        "file:///bad%2\n" ++
        "file:///bad%zz\n" ++
        "file:///nought%00here\n" ++
        "FILE:///kept/when/shouted\n" ++
        "file:///last/without/an/ending";
    const got = try paths(arena.allocator(), list);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("/kept/when/shouted", got[0]);
    try testing.expectEqualStrings("/last/without/an/ending", got[1]);
}

test "an empty list is no paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try paths(arena.allocator(), "")).len);
    try testing.expectEqual(@as(usize, 0), (try paths(arena.allocator(), "# nothing\r\n")).len);
}
