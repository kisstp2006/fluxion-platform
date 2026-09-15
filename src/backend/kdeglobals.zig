// SPDX-License-Identifier: BSL-1.0

//! The settings a Linux desktop keeps for how its pointer and text behave:
//! KDE's, in the `[KDE]` group of `kdeglobals`, the only desktop that writes
//! them where a program can read them. Without the file the answer is the
//! toolkits' own default - what GNOME uses unless it is changed.

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
    const lines: f32 = @floatFromInt(read("WheelScrollLines") orelse return .{});
    return .{ .x = lines, .y = lines };
}

pub fn doubleClickTime() u32 {
    return read("DoubleClickInterval") orelse 400;
}

/// KDE keeps the whole blink, as Qt does; GTK's own default is 1200 ms of it.
pub fn caretBlinkTime() ?u32 {
    const cycle = read("CursorBlinkRate") orelse return 600;
    return if (cycle == 0) null else cycle / 2;
}

fn read(key: []const u8) ?u32 {
    var where: [std.fs.max_path_bytes]u8 = undefined;
    const path = filePath(&where) orelse return null;
    var contents: std.ArrayListUnmanaged(u8) = .empty;
    defer contents.deinit(std.heap.c_allocator);
    linux_dialog.readFile(path, &contents, std.heap.c_allocator) catch return null;
    return number(contents.items, key);
}

fn filePath(buffer: []u8) ?[]const u8 {
    if (c.getenv("XDG_CONFIG_HOME")) |raw| {
        const config = std.mem.span(raw);
        if (std.fs.path.isAbsolutePosix(config)) return std.fmt.bufPrint(buffer, "{s}/kdeglobals", .{config}) catch null;
    }
    const home = std.mem.span(c.getenv("HOME") orelse return null);
    return std.fmt.bufPrint(buffer, "{s}/.config/kdeglobals", .{home}) catch null;
}

/// A number in the `[KDE]` group, which KConfig may mark `[KDE][$i]`.
fn number(contents: []const u8, wanted: []const u8) ?u32 {
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
        if (!std.mem.eql(u8, key, wanted)) continue;
        return std.fmt.parseInt(u32, std.mem.trim(u8, line[equals + 1 ..], " \t"), 10) catch null;
    }
    return null;
}

test "a setting is read from the KDE group and nowhere else" {
    const file =
        \\[General]
        \\WheelScrollLines=9
        \\
        \\[KDE]
        \\LookAndFeelPackage=org.kde.breeze.desktop
        \\WheelScrollLines=5
        \\DoubleClickInterval=250
        \\
        \\[KDE][Other]
        \\WheelScrollLines=7
        \\
    ;
    try testing.expectEqual(@as(?u32, 5), number(file, "WheelScrollLines"));
    try testing.expectEqual(@as(?u32, 250), number(file, "DoubleClickInterval"));
    try testing.expectEqual(@as(?u32, null), number(file, "CursorBlinkRate"));
    try testing.expectEqual(@as(?u32, 4), number("[KDE][$i]\r\nWheelScrollLines[$e] = 4\r\n", "WheelScrollLines"));
    try testing.expectEqual(@as(?u32, null), number("[KDE][Other]\nWheelScrollLines=7\n", "WheelScrollLines"));
    try testing.expectEqual(@as(?u32, null), number("[KDE]\nWheelScrollLines=many\n", "WheelScrollLines"));
}
