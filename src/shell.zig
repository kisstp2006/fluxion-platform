// SPDX-License-Identifier: BSL-1.0

//! Handing a file, a folder or an address to the system: opened in whatever
//! the user opens that kind of thing with, or shown in the file manager.
//!
//! ```zig
//! try platform.shell.openUrl(gpa, io, "https://ziglang.org/");
//! if (platform.shell.support.show_in_folder) try platform.shell.showInFolder(gpa, io, "C:/game/level.json");
//! ```
//!
//! Each says what went wrong rather than starting a program and hoping:
//! Explorer's exit code means nothing, where the shell's own calls and
//! `xdg-open`'s exit code do.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const dyn = @import("fluxion_dyn");

const platform = @import("platform.zig");
const unix = @import("backend/unix_shell.zig");
const portal = @import("backend/portal.zig");
const android = @import("backend/android.zig");
const web = @import("backend/web.zig");

pub const Support = struct {
    open_path: bool,
    show_in_folder: bool,
    open_url: bool,
};

/// What this build can hand over at all. A phone and a page have no paths to
/// hand over; a `content://` URI from Android's file dialog is `openUrl`'s.
pub const support: Support = if (platform.is_web or builtin.abi.isAndroid())
    .{ .open_path = false, .show_in_folder = false, .open_url = true }
else switch (builtin.os.tag) {
    .windows, .macos, .linux, .freebsd, .openbsd, .netbsd, .dragonfly => .{ .open_path = true, .show_in_folder = true, .open_url = true },
    else => .{ .open_path = false, .show_in_folder = false, .open_url = false },
};

pub const Error = error{
    /// See `support`.
    Unsupported,
    FileNotFound,
    /// Nothing on this system opens this kind of file or address.
    NoHandler,
    /// The system would not: a browser blocking the new window, no
    /// permission, or a reason it did not give.
    Refused,
} || Allocator.Error;

/// Open a file or a folder as a double click in the file manager would.
pub fn openPath(gpa: Allocator, io: std.Io, path: []const u8) Error!void {
    if (comptime !support.open_path) return error.Unsupported;
    try exists(io, path);
    if (comptime builtin.os.tag == .windows) return windows.open(gpa, path);
    const whole = try absolute(gpa, io, path);
    defer gpa.free(whole);
    return ended(try unix.run(if (builtin.os.tag == .macos) "open" else "xdg-open", &.{whole}));
}

/// Open the folder `path` is in, with it selected where the file manager can.
pub fn showInFolder(gpa: Allocator, io: std.Io, path: []const u8) Error!void {
    if (comptime !support.show_in_folder) return error.Unsupported;
    try exists(io, path);
    if (comptime builtin.os.tag == .windows) return windows.show(gpa, path);
    const whole = try absolute(gpa, io, path);
    defer gpa.free(whole);
    if (comptime builtin.os.tag == .macos) return ended(try unix.run("open", &.{ "-R", whole }));
    const uri = try portal.fileUri(gpa, whole);
    defer gpa.free(uri);
    if (unix.fileManagerShow(uri)) return;
    return ended(try unix.run("xdg-open", &.{std.fs.path.dirnamePosix(whole) orelse whole}));
}

/// A web address - or any URI something on the system opens - in the user's
/// browser, or in that something.
pub fn openUrl(gpa: Allocator, io: std.Io, url: []const u8) Error!void {
    _ = io;
    if (comptime !support.open_url) return error.Unsupported;
    if (comptime platform.is_web) {
        if (web.js.openUrl(url.ptr, @intCast(url.len)) == 0) return error.Refused;
        return;
    }
    if (comptime builtin.abi.isAndroid()) return switch (try android.viewUri(gpa, url)) {
        .done => {},
        .no_handler => error.NoHandler,
        .unavailable => error.Refused,
    };
    if (comptime builtin.os.tag == .windows) return windows.open(gpa, url);
    if (comptime builtin.os.tag == .macos) return ended(try unix.run("open", &.{url}));
    if (unix.portalOpen(url)) return;
    return ended(try unix.run("xdg-open", &.{url}));
}

fn exists(io: std.Io, path: []const u8) Error!void {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        else => error.Refused,
    };
}

fn absolute(gpa: Allocator, io: std.Io, path: []const u8) Error![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(gpa, &.{path});
    const here = std.process.currentPathAlloc(io, gpa) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Refused,
    };
    defer gpa.free(here);
    return std.fs.path.resolve(gpa, &.{ here, path });
}

fn ended(outcome: unix.Outcome) Error!void {
    return switch (outcome) {
        .done => {},
        .not_found => error.FileNotFound,
        .no_handler => error.NoHandler,
        .refused => error.Refused,
    };
}

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------

const windows = struct {
    const Shell32 = struct {
        ShellExecuteW: *const fn (?*anyopaque, ?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, i32) callconv(.winapi) usize,
        SHParseDisplayName: *const fn ([*:0]const u16, ?*anyopaque, *?*anyopaque, u32, ?*u32) callconv(.winapi) i32,
        SHOpenFolderAndSelectItems: *const fn (*anyopaque, u32, ?[*]const ?*anyopaque, u32) callconv(.winapi) i32,
    };
    const Ole32 = struct {
        CoInitializeEx: *const fn (?*anyopaque, u32) callconv(.winapi) i32,
        CoUninitialize: *const fn () callconv(.winapi) void,
        CoTaskMemFree: *const fn (?*anyopaque) callconv(.winapi) void,
    };
    const Kernel32 = struct {
        GetFullPathNameW: *const fn ([*:0]const u16, u32, ?[*]u16, ?*?[*:0]u16) callconv(.winapi) u32,
    };

    const coinit_apartmentthreaded: u32 = 0x2;
    const coinit_disable_ole1dde: u32 = 0x4;
    const sw_shownormal: i32 = 1;
    const file_not_found: i32 = @bitCast(@as(u32, 0x80070002));
    const path_not_found: i32 = @bitCast(@as(u32, 0x80070003));

    /// The shell wants COM in a single-threaded apartment. A thread already in
    /// another kind keeps it, and is not the one to end it.
    const Com = struct {
        shell32: dyn.Library,
        ole32: dyn.Library,
        shell: Shell32,
        ole: Ole32,
        entered: bool,

        fn enter() Error!Com {
            var shell32 = dyn.openSystem("shell32.dll") catch return error.Unsupported;
            errdefer shell32.close();
            var ole32 = dyn.openSystem("ole32.dll") catch return error.Unsupported;
            errdefer ole32.close();
            const shell = shell32.bind(Shell32) catch return error.Unsupported;
            const ole = ole32.bind(Ole32) catch return error.Unsupported;
            const result = ole.CoInitializeEx(null, coinit_apartmentthreaded | coinit_disable_ole1dde);
            return .{ .shell32 = shell32, .ole32 = ole32, .shell = shell, .ole = ole, .entered = result >= 0 };
        }

        fn leave(self: *Com) void {
            if (self.entered) self.ole.CoUninitialize();
            self.ole32.close();
            self.shell32.close();
        }
    };

    fn open(gpa: Allocator, target: []const u8) Error!void {
        var com = try Com.enter();
        defer com.leave();
        const wide = try wideZ(gpa, target);
        defer gpa.free(wide);
        const code = com.shell.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), wide, null, null, sw_shownormal);
        if (code > 32) return;
        return switch (code) {
            2, 3 => error.FileNotFound,
            27, 31 => error.NoHandler,
            0, 8 => error.OutOfMemory,
            else => error.Refused,
        };
    }

    fn show(gpa: Allocator, path: []const u8) Error!void {
        var com = try Com.enter();
        defer com.leave();
        const whole = try fullPath(gpa, path);
        defer gpa.free(whole);
        var item: ?*anyopaque = null;
        const parsed = com.shell.SHParseDisplayName(whole, null, &item, 0, null);
        if (parsed < 0 or item == null) {
            return if (parsed == file_not_found or parsed == path_not_found) error.FileNotFound else error.Refused;
        }
        defer com.ole.CoTaskMemFree(item);
        if (com.shell.SHOpenFolderAndSelectItems(item.?, 0, null, 0) < 0) return error.Refused;
    }

    fn wideZ(gpa: Allocator, text: []const u8) Error![:0]u16 {
        return std.unicode.wtf8ToWtf16LeAllocZ(gpa, text) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidWtf8 => error.Refused,
        };
    }

    /// The shell parses only whole paths with backslashes.
    fn fullPath(gpa: Allocator, path: []const u8) Error![:0]u16 {
        var kernel32 = dyn.openSystem("kernel32.dll") catch return error.Unsupported;
        defer kernel32.close();
        const kernel = kernel32.bind(Kernel32) catch return error.Unsupported;
        const wide = try wideZ(gpa, path);
        defer gpa.free(wide);
        std.mem.replaceScalar(u16, wide, '/', '\\');
        const needed = kernel.GetFullPathNameW(wide.ptr, 0, null, null);
        if (needed < 2) return error.FileNotFound;
        const whole = try gpa.allocSentinel(u16, needed - 1, 0);
        errdefer gpa.free(whole);
        if (kernel.GetFullPathNameW(wide.ptr, needed, whole.ptr, null) != needed - 1) return error.FileNotFound;
        return whole;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "what is not there is said to be not there, and nothing is started for it" {
    if (!support.open_path) return error.SkipZigTest;
    const missing = "fluxion-platform-no-such-file.txt";
    try testing.expectError(error.FileNotFound, openPath(testing.allocator, testing.io, missing));
    try testing.expectError(error.FileNotFound, showInFolder(testing.allocator, testing.io, missing));
}

test "a hand-over's ending is one of the errors a caller can act on" {
    try ended(.done);
    try testing.expectError(error.FileNotFound, ended(.not_found));
    try testing.expectError(error.NoHandler, ended(.no_handler));
    try testing.expectError(error.Refused, ended(.refused));
}
