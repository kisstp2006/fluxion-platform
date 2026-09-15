// SPDX-License-Identifier: BSL-1.0

//! The folders a system keeps for its user - home and documents - and the
//! ones a program keeps its settings, its data and its cache in.
//!
//! ```zig
//! const settings = try platform.folders.path(gpa, io, .config);
//! defer gpa.free(settings);
//! ```
//!
//! The system's own answer rather than an environment variable and a guess:
//! documents redirected to OneDrive, and a Linux desktop's in the user's own
//! language, are where a program finds them. A missing folder is not made.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const dyn = @import("fluxion_dyn");

const android = @import("backend/android.zig");

pub const Folder = enum {
    home,
    documents,
    /// Settings. On Windows the roaming profile, which follows the user.
    config,
    data,
    /// What can be thrown away and made again.
    cache,
};

pub const available = switch (builtin.os.tag) {
    .windows, .macos, .linux, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

pub const Error = error{
    /// See `available`.
    Unsupported,
    /// The system has none: no home set, no shared storage on this phone.
    NotFound,
} || Allocator.Error;

/// The folder, absolute, for the caller to free.
pub fn path(gpa: Allocator, io: std.Io, which: Folder) Error![]u8 {
    if (comptime !available) return error.Unsupported;
    if (comptime builtin.os.tag == .windows) return windows.known(gpa, which);
    if (comptime builtin.abi.isAndroid()) return phone(gpa, which);
    const home = std.mem.span(libc.getenv("HOME") orelse return error.NotFound);
    if (!std.fs.path.isAbsolutePosix(home)) return error.NotFound;
    if (comptime builtin.os.tag == .macos) return apple(gpa, home, which);
    return xdg(gpa, io, .{
        .home = home,
        .config_home = libc.env("XDG_CONFIG_HOME"),
        .data_home = libc.env("XDG_DATA_HOME"),
        .cache_home = libc.env("XDG_CACHE_HOME"),
    }, which);
}

const libc = struct {
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

    fn env(name: [*:0]const u8) ?[]const u8 {
        return std.mem.span(getenv(name) orelse return null);
    }
};

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------

const windows = struct {
    const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

    const profile: Guid = .{ .a = 0x5E6C858F, .b = 0x0E22, .c = 0x4760, .d = .{ 0x9A, 0xFE, 0xEA, 0x33, 0x17, 0xB6, 0x71, 0x73 } };
    const documents: Guid = .{ .a = 0xFDD39AD0, .b = 0x238F, .c = 0x46AF, .d = .{ 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 } };
    const roaming: Guid = .{ .a = 0x3EB685DB, .b = 0x65F9, .c = 0x4CF6, .d = .{ 0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D } };
    const local: Guid = .{ .a = 0xF1B32785, .b = 0x6FBA, .c = 0x4FCF, .d = .{ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 } };

    const Shell32 = struct {
        SHGetKnownFolderPath: *const fn (*const Guid, u32, ?*anyopaque, *?[*:0]u16) callconv(.winapi) i32,
    };
    const Ole32 = struct {
        CoTaskMemFree: *const fn (?*anyopaque) callconv(.winapi) void,
    };

    fn known(gpa: Allocator, which: Folder) Error![]u8 {
        var shell32 = dyn.openSystem("shell32.dll") catch return error.Unsupported;
        defer shell32.close();
        const shell = shell32.bind(Shell32) catch return error.Unsupported;
        var ole32 = dyn.openSystem("ole32.dll") catch return error.Unsupported;
        defer ole32.close();
        const ole = ole32.bind(Ole32) catch return error.Unsupported;

        const id = switch (which) {
            .home => &profile,
            .documents => &documents,
            .config, .data => &roaming,
            .cache => &local,
        };
        var found: ?[*:0]u16 = null;
        const result = shell.SHGetKnownFolderPath(id, 0, null, &found);
        defer ole.CoTaskMemFree(found);
        if (result < 0) return error.NotFound;
        const wide = std.mem.span(found orelse return error.NotFound);
        return std.unicode.wtf16LeToWtf8Alloc(gpa, wide);
    }
};

// -------------------------------------------------------------------------
// Everywhere else
// -------------------------------------------------------------------------

fn apple(gpa: Allocator, home: []const u8, which: Folder) Error![]u8 {
    return switch (which) {
        .home => gpa.dupe(u8, home),
        .documents => under(gpa, home, "Documents"),
        .config, .data => under(gpa, home, "Library/Application Support"),
        .cache => under(gpa, home, "Library/Caches"),
    };
}

/// Private storage for everything but documents, which go where a file manager sees them.
fn phone(gpa: Allocator, which: Folder) Error![]u8 {
    const paths = android.storagePaths() orelse return error.NotFound;
    const internal = std.mem.span(paths.internal orelse return error.NotFound);
    return switch (which) {
        .home, .config, .data => gpa.dupe(u8, internal),
        .cache => under(gpa, std.fs.path.dirnamePosix(internal) orelse return error.NotFound, "cache"),
        .documents => gpa.dupe(u8, std.mem.span(paths.external orelse return error.NotFound)),
    };
}

/// What the XDG base directory spec reads, taken as it stands so a test can make one up.
const Environment = struct {
    home: []const u8,
    config_home: ?[]const u8 = null,
    data_home: ?[]const u8 = null,
    cache_home: ?[]const u8 = null,
};

fn xdg(gpa: Allocator, io: std.Io, env: Environment, which: Folder) Error![]u8 {
    const config = try base(gpa, env.config_home, env.home, ".config");
    if (which == .config) return config;
    defer gpa.free(config);
    return switch (which) {
        .home => gpa.dupe(u8, env.home),
        .data => base(gpa, env.data_home, env.home, ".local/share"),
        .cache => base(gpa, env.cache_home, env.home, ".cache"),
        .documents => documentsFolder(gpa, io, env.home, config),
        .config => unreachable,
    };
}

/// The spec says a relative value is to be ignored.
fn base(gpa: Allocator, set: ?[]const u8, home: []const u8, fallback: []const u8) Error![]u8 {
    if (set) |value| {
        if (std.fs.path.isAbsolutePosix(value)) return gpa.dupe(u8, value);
    }
    return under(gpa, home, fallback);
}

fn under(gpa: Allocator, parent: []const u8, child: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, parent, "/"), child });
}

/// `user-dirs.dirs` names it in the desktop's language; without one, `~/Documents` if it is there.
fn documentsFolder(gpa: Allocator, io: std.Io, home: []const u8, config: []const u8) Error![]u8 {
    var file_path: [std.fs.max_path_bytes]u8 = undefined;
    const dirs_path = std.fmt.bufPrint(&file_path, "{s}/user-dirs.dirs", .{config}) catch return error.NotFound;
    var contents: [8192]u8 = undefined;
    if (std.Io.Dir.cwd().readFile(io, dirs_path, &contents)) |read| {
        if (try userDir(gpa, read, home, "DOCUMENTS")) |found| return found;
    } else |_| {}
    const guess = try under(gpa, home, "Documents");
    if (std.Io.Dir.cwd().access(io, guess, .{})) |_| return guess else |_| {}
    gpa.free(guess);
    return gpa.dupe(u8, home);
}

/// One `XDG_<NAME>_DIR="..."` line: `$HOME/...` or absolute, shell-escaped.
fn userDir(gpa: Allocator, contents: []const u8, home: []const u8, name: []const u8) Allocator.Error!?[]u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "XDG_")) continue;
        const rest = line["XDG_".len..];
        if (!std.mem.startsWith(u8, rest, name) or !std.mem.startsWith(u8, rest[name.len..], "_DIR=\"")) continue;
        const quoted = rest[name.len + "_DIR=\"".len ..];
        const end = std.mem.lastIndexOfScalar(u8, quoted, '"') orelse continue;

        var value: std.ArrayListUnmanaged(u8) = .empty;
        errdefer value.deinit(gpa);
        var escaped = false;
        for (quoted[0..end]) |byte| {
            if (!escaped and byte == '\\') {
                escaped = true;
                continue;
            }
            escaped = false;
            try value.append(gpa, byte);
        }
        if (std.mem.startsWith(u8, value.items, "$HOME")) {
            const tail = std.mem.trimStart(u8, value.items["$HOME".len..], "/");
            defer value.deinit(gpa);
            if (tail.len == 0) return try gpa.dupe(u8, home);
            return try under(gpa, home, tail);
        }
        if (std.fs.path.isAbsolutePosix(value.items)) return try value.toOwnedSlice(gpa);
        value.deinit(gpa);
    }
    return null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const user_dirs =
    \\# This file is written by xdg-user-dirs-update
    \\XDG_DESKTOP_DIR="$HOME/Asztal"
    \\XDG_DOCUMENTS_DIR="$HOME/Dokumentumok"
    \\XDG_MUSIC_DIR="/mnt/zene"
    \\XDG_PICTURES_DIR="$HOME/K\"epek"
    \\XDG_VIDEOS_DIR="$HOME/"
    \\
;

test "a user-dirs.dirs line is read in the desktop's own language" {
    const home = "/home/tamas";
    inline for (.{
        .{ "DOCUMENTS", "/home/tamas/Dokumentumok" },
        .{ "MUSIC", "/mnt/zene" },
        .{ "PICTURES", "/home/tamas/K\"epek" },
        .{ "VIDEOS", "/home/tamas" },
    }) |case| {
        const found = (try userDir(testing.allocator, user_dirs, home, case[0])).?;
        defer testing.allocator.free(found);
        try testing.expectEqualStrings(case[1], found);
    }
    try testing.expectEqual(@as(?[]u8, null), try userDir(testing.allocator, user_dirs, home, "TEMPLATES"));
    try testing.expectEqual(@as(?[]u8, null), try userDir(testing.allocator, user_dirs, home, "DESK"));
}

test "the base directories follow the spec, and a relative one is ignored" {
    const env: Environment = .{ .home = "/home/tamas", .config_home = "/etc/mine", .data_home = "relative/share" };
    inline for (.{
        .{ Folder.home, "/home/tamas" },
        .{ Folder.config, "/etc/mine" },
        .{ Folder.data, "/home/tamas/.local/share" },
        .{ Folder.cache, "/home/tamas/.cache" },
    }) |case| {
        const found = try xdg(testing.allocator, testing.io, env, case[0]);
        defer testing.allocator.free(found);
        try testing.expectEqualStrings(case[1], found);
    }
}

test "documents come from user-dirs.dirs, then from a Documents folder, then home" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var here: [std.fs.max_path_bytes]u8 = undefined;
    const home = here[0..try tmp.dir.realPath(testing.io, &here)];
    const config = try under(testing.allocator, home, ".config");
    defer testing.allocator.free(config);

    const bare = try documentsFolder(testing.allocator, testing.io, home, config);
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings(home, bare);

    try tmp.dir.createDirPath(testing.io, "Documents");
    const guessed = try documentsFolder(testing.allocator, testing.io, home, config);
    defer testing.allocator.free(guessed);
    try testing.expect(std.mem.endsWith(u8, guessed, "Documents"));

    try tmp.dir.createDirPath(testing.io, ".config");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".config/user-dirs.dirs", .data = user_dirs });
    const named = try documentsFolder(testing.allocator, testing.io, home, config);
    defer testing.allocator.free(named);
    try testing.expect(std.mem.endsWith(u8, named, "Dokumentumok"));
}

test "every folder this system keeps is an absolute path" {
    if (!available or builtin.abi.isAndroid()) return error.SkipZigTest;
    for (std.enums.values(Folder)) |which| {
        const found = path(testing.allocator, testing.io, which) catch |err| switch (err) {
            error.NotFound => continue,
            else => return err,
        };
        defer testing.allocator.free(found);
        try testing.expect(std.fs.path.isAbsolute(found));
    }
}
