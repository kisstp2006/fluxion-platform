// SPDX-License-Identifier: BSL-1.0

//! The one Linux desktop setting for how far a wheel notch scrolls: KDE's
//! `WheelScrollLines`, in `kdeglobals`. GNOME has none, and without the file
//! the answer is the three lines every desktop defaults to.

const std = @import("std");
const testing = std.testing;

const input = @import("../input.zig");
const linux_dialog = @import("linux_dialog.zig");

const c = struct {
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
};

/// Read each time, so a change in System Settings is heard at once. Qt scrolls
/// sideways by the same number.
pub fn scrollLines() input.ScrollLines {
    var where: [std.fs.max_path_bytes]u8 = undefined;
    const path = filePath(&where) orelse return .{};
    var contents: std.ArrayListUnmanaged(u8) = .empty;
    defer contents.deinit(std.heap.c_allocator);
    linux_dialog.readFile(path, &contents, std.heap.c_allocator) catch return .{};
    const lines: f32 = @floatFromInt(wheelLines(contents.items) orelse return .{});
    return .{ .x = lines, .y = lines };
}

fn filePath(buffer: []u8) ?[]const u8 {
    if (c.getenv("XDG_CONFIG_HOME")) |raw| {
        const config = std.mem.span(raw);
        if (std.fs.path.isAbsolutePosix(config)) return std.fmt.bufPrint(buffer, "{s}/kdeglobals", .{config}) catch null;
    }
    const home = std.mem.span(c.getenv("HOME") orelse return null);
    return std.fmt.bufPrint(buffer, "{s}/.config/kdeglobals", .{home}) catch null;
}

/// `WheelScrollLines` in the `[KDE]` group, which KConfig may mark `[KDE][$i]`.
fn wheelLines(contents: []const u8) ?u32 {
    var in_kde = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_kde = std.mem.eql(u8, line, "[KDE]") or std.mem.startsWith(u8, line, "[KDE][$");
            continue;
        }
        if (!in_kde) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        var key = std.mem.trim(u8, line[0..equals], " \t");
        if (std.mem.indexOfScalar(u8, key, '[')) |flags| key = key[0..flags];
        if (!std.mem.eql(u8, key, "WheelScrollLines")) continue;
        return std.fmt.parseInt(u32, std.mem.trim(u8, line[equals + 1 ..], " \t"), 10) catch null;
    }
    return null;
}

test "the wheel setting is read from the KDE group and nowhere else" {
    const file =
        \\[General]
        \\WheelScrollLines=9
        \\
        \\[KDE]
        \\LookAndFeelPackage=org.kde.breeze.desktop
        \\WheelScrollLines=5
        \\
        \\[KDE][Other]
        \\WheelScrollLines=7
        \\
    ;
    try testing.expectEqual(@as(?u32, 5), wheelLines(file));
    try testing.expectEqual(@as(?u32, 4), wheelLines("[KDE][$i]\r\nWheelScrollLines[$e] = 4\r\n"));
    try testing.expectEqual(@as(?u32, null), wheelLines("[KDE]\nSingleClick=false\n"));
    try testing.expectEqual(@as(?u32, null), wheelLines("[KDE][Other]\nWheelScrollLines=7\n"));
    try testing.expectEqual(@as(?u32, null), wheelLines("[KDE]\nWheelScrollLines=many\n"));
}
