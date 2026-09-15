// SPDX-License-Identifier: BSL-1.0

//! A file or a folder moved to the system's trash, where a person can take it
//! back from: the Recycle Bin on Windows, the freedesktop.org trash on a Linux
//! desktop.
//!
//! ```zig
//! if (platform.trash.available) try platform.trash.move(gpa, io, "C:/game/art/old.png");
//! ```
//!
//! Not a windowing matter - there is no window in it and no `Context` - so a
//! tool with neither can use it, and a test.
//!
//! **Windows** asks the shell, with `SHFileOperationW` and "allow undo": the
//! call Explorer's own Delete makes. Something the Recycle Bin cannot take - on
//! a drive with none, or too big for it - is asked about by the shell before
//! it is deleted for good, rather than deleted without a word.
//!
//! **Linux** follows the freedesktop.org Trash specification: the file goes
//! into `files` in `$XDG_DATA_HOME/Trash`, and a `.trashinfo` of the same name
//! goes into `info` beside it, saying where the file was and when it went -
//! which is what a file manager's Restore reads. Its name is claimed by making
//! that info file, which only one program can do, so two moving files of one
//! name at once cannot take the same place. A file on another filesystem than
//! the home folder's trash is refused with `error.OtherDrive`: moving it there
//! would be copying it.
//!
//! Anywhere else - the web, Android, a system with no backend here - it is
//! `error.Unsupported`, and `available` says so before anything is tried.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const dyn = @import("fluxion_dyn");

/// Whether this build has a trash to move things to.
pub const available = switch (builtin.os.tag) {
    .windows => true,
    .linux => !builtin.abi.isAndroid(),
    else => false,
};

pub const Error = error{
    /// This system has no trash this library knows. See `available`.
    Unsupported,
    /// Nothing is at the path.
    FileNotFound,
    /// The file is on another drive than the trash, and moving it there would
    /// be copying it.
    OtherDrive,
    /// The system asked the person, who said no.
    Cancelled,
    /// The system would not move it: no permission, open elsewhere, or a
    /// reason it did not give.
    Refused,
} || Allocator.Error;

/// Move the file or the folder at `path` - absolute, or from the working
/// directory - to the system's trash.
pub fn move(gpa: Allocator, io: std.Io, path: []const u8) Error!void {
    if (comptime !available) return error.Unsupported;
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        else => error.Refused,
    };
    switch (builtin.os.tag) {
        .windows => return windows.move(gpa, path),
        .linux => {
            const whole = try absolute(gpa, io, path);
            defer gpa.free(whole);
            const trash = try linux.homeTrash(gpa);
            defer gpa.free(trash);
            return freedesktop.move(gpa, io, whole, trash, linux.now());
        },
        else => return error.Unsupported,
    }
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

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------

const windows = struct {
    /// `SHFILEOPSTRUCTW`. `shellapi.h` packs it to single bytes on 32-bit
    /// Windows and leaves it naturally aligned on 64-bit.
    const FileOp = if (@sizeOf(usize) == 8) extern struct {
        hwnd: ?*anyopaque = null,
        func: u32,
        from: [*:0]const u16,
        to: ?[*:0]const u16 = null,
        flags: u16,
        aborted: i32 = 0,
        mappings: ?*anyopaque = null,
        title: ?[*:0]const u16 = null,
    } else extern struct {
        hwnd: ?*anyopaque align(1) = null,
        func: u32 align(1),
        from: [*:0]const u16 align(1),
        to: ?[*:0]const u16 align(1) = null,
        flags: u16 align(1),
        aborted: i32 align(1) = 0,
        mappings: ?*anyopaque align(1) = null,
        title: ?[*:0]const u16 align(1) = null,
    };

    const fo_delete: u32 = 3;
    const fof_silent: u16 = 0x0004;
    const fof_noconfirmation: u16 = 0x0010;
    const fof_allowundo: u16 = 0x0040;
    const fof_noerrorui: u16 = 0x0400;
    /// Ask before deleting for good what the Recycle Bin will not take,
    /// which "no confirmation" would otherwise delete without a word.
    const fof_wantnukewarning: u16 = 0x4000;

    const Shell32 = struct {
        SHFileOperationW: *const fn (*FileOp) callconv(.winapi) i32,
    };
    const Kernel32 = struct {
        GetFullPathNameW: *const fn ([*:0]const u16, u32, ?[*]u16, ?*?[*:0]u16) callconv(.winapi) u32,
    };

    fn move(gpa: Allocator, path: []const u8) Error!void {
        var shell32 = dyn.openSystem("shell32.dll") catch return error.Unsupported;
        defer shell32.close();
        const shell = shell32.bind(Shell32) catch return error.Unsupported;
        var kernel32 = dyn.openSystem("kernel32.dll") catch return error.Unsupported;
        defer kernel32.close();
        const kernel = kernel32.bind(Kernel32) catch return error.Unsupported;

        const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidWtf8 => error.FileNotFound,
        };
        defer gpa.free(wide);
        // The shell takes a whole path, made whole the way Windows makes one;
        // and a list of them, each ended, with one more ending after the last.
        const needed = kernel.GetFullPathNameW(wide.ptr, 0, null, null);
        if (needed == 0) return error.FileNotFound;
        const whole = try gpa.alloc(u16, needed + 1);
        defer gpa.free(whole);
        const len = kernel.GetFullPathNameW(wide.ptr, needed, whole.ptr, null);
        if (len == 0 or len >= needed) return error.FileNotFound;
        whole[len] = 0;
        whole[len + 1] = 0;

        var op: FileOp = .{
            .func = fo_delete,
            .from = @ptrCast(whole.ptr),
            .flags = fof_allowundo | fof_noconfirmation | fof_silent | fof_noerrorui | fof_wantnukewarning,
        };
        const result = shell.SHFileOperationW(&op);
        if (op.aborted != 0) return error.Cancelled;
        if (result != 0) return error.Refused;
    }
};

// -------------------------------------------------------------------------
// Linux
// -------------------------------------------------------------------------

/// What only a Linux build reaches: libc's environment and clock. In a
/// struct of its own so a Windows build never analyses it.
const linux = struct {
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn time(out: ?*c_long) c_long;
    extern "c" fn localtime_r(when: *const c_long, out: *Tm) ?*Tm;

    const Tm = extern struct {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        gmtoff: c_long,
        zone: ?[*:0]const u8,
    };

    /// `$XDG_DATA_HOME/Trash`, or `~/.local/share/Trash` where that is not
    /// set - or not absolute, which the base directory spec says to ignore.
    fn homeTrash(gpa: Allocator) Error![]u8 {
        if (getenv("XDG_DATA_HOME")) |raw| {
            const data = std.mem.span(raw);
            if (std.fs.path.isAbsolute(data)) return std.fs.path.join(gpa, &.{ data, "Trash" });
        }
        const home = std.mem.span(getenv("HOME") orelse return error.Unsupported);
        if (home.len == 0) return error.Unsupported;
        return std.fs.path.join(gpa, &.{ home, ".local", "share", "Trash" });
    }

    /// The local time, as the spec wants the deletion date said.
    fn now() Stamp {
        var tm: Tm = undefined;
        const seconds = time(null);
        _ = localtime_r(&seconds, &tm);
        return .{
            .year = @intCast(tm.year + 1900),
            .month = @intCast(tm.mon + 1),
            .day = @intCast(tm.mday),
            .hour = @intCast(tm.hour),
            .minute = @intCast(tm.min),
            .second = @intCast(@min(tm.sec, 59)),
        };
    }
};

/// A date and a time of day, as a `.trashinfo` says when a file went.
pub const Stamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// The freedesktop.org Trash specification, over any directory: the Linux
/// build hands it the home trash, and the tests a folder of their own.
pub const freedesktop = struct {
    /// Past this many files of one name, a trash is refused rather than
    /// searched further.
    const most_of_one_name = 10_000;

    /// Move `path`, absolute, into the trash at `trash`: made if it is not
    /// there, the file under a name no other file in it has, and an info file
    /// beside it saying where it came from and `when`.
    pub fn move(gpa: Allocator, io: std.Io, path: []const u8, trash: []const u8, when: Stamp) Error!void {
        var top = std.Io.Dir.cwd().createDirPathOpen(io, trash, .{}) catch return error.Refused;
        defer top.close(io);
        top.createDirPath(io, "files") catch return error.Refused;
        top.createDirPath(io, "info") catch return error.Refused;

        const info = try infoText(gpa, path, when);
        defer gpa.free(info);
        const name = std.fs.path.basename(path);
        var number: usize = 1;
        while (number <= most_of_one_name) : (number += 1) {
            const kept = if (number == 1) try gpa.dupe(u8, name) else try std.fmt.allocPrint(gpa, "{s}.{d}", .{ name, number });
            defer gpa.free(kept);
            const files = try std.fs.path.join(gpa, &.{ "files", kept });
            defer gpa.free(files);
            if (top.access(io, files, .{})) |_| continue else |_| {}
            const record = try std.fmt.allocPrint(gpa, "info{c}{s}.trashinfo", .{ std.fs.path.sep, kept });
            defer gpa.free(record);
            // The claim: made only if no other program made it first.
            top.writeFile(io, .{ .sub_path = record, .data = info, .flags = .{ .exclusive = true } }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return error.Refused,
            };
            std.Io.Dir.rename(std.Io.Dir.cwd(), path, top, files, io) catch |err| {
                top.deleteFile(io, record) catch {};
                return switch (err) {
                    error.CrossDevice => error.OtherDrive,
                    error.FileNotFound => error.FileNotFound,
                    else => error.Refused,
                };
            };
            return;
        }
        return error.Refused;
    }

    /// What the info file says: where the file was, with every byte a URL
    /// would not carry as it is written as `%XX`, and when it went.
    fn infoText(gpa: Allocator, path: []const u8, when: Stamp) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("[Trash Info]\nPath=") catch return error.OutOfMemory;
        for (path) |byte| {
            if (unreserved(byte)) w.writeByte(byte) catch return error.OutOfMemory else w.print("%{X:0>2}", .{byte}) catch return error.OutOfMemory;
        }
        w.print("\nDeletionDate={d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{ when.year, when.month, when.day, when.hour, when.minute, when.second }) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    /// RFC 2396's unreserved characters, and the slash between a path's parts.
    fn unreserved(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-_.!~*'()/", byte) != null;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const stamp: Stamp = .{ .year = 2026, .month = 9, .day = 15, .hour = 9, .minute = 5, .second = 7 };

fn scratch(tmp: *testing.TmpDir, buffer: []u8, inside: []const u8) ![]const u8 {
    var here: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &here);
    return std.fmt.bufPrint(buffer, "{s}{c}{s}", .{ here[0..len], std.fs.path.sep, inside });
}

test "a file moved to a trash is in its files, with an info file saying where it was and when" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "game/art");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "game/art/old hero.png", .data = "picture" });

    var from: [512]u8 = undefined;
    var trash: [512]u8 = undefined;
    const path = try scratch(&tmp, &from, "game" ++ std.fs.path.sep_str ++ "art" ++ std.fs.path.sep_str ++ "old hero.png");
    try freedesktop.move(testing.allocator, testing.io, path, try scratch(&tmp, &trash, "Trash"), stamp);

    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "game/art/old hero.png", .{}));
    var kept: [16]u8 = undefined;
    try testing.expectEqualStrings("picture", try tmp.dir.readFile(testing.io, "Trash/files/old hero.png", &kept));
    var info: [1024]u8 = undefined;
    const said = try tmp.dir.readFile(testing.io, "Trash/info/old hero.png.trashinfo", &info);
    try testing.expect(std.mem.startsWith(u8, said, "[Trash Info]\nPath="));
    try testing.expect(std.mem.indexOf(u8, said, "old%20hero.png\n") != null);
    try testing.expect(std.mem.endsWith(u8, said, "\nDeletionDate=2026-09-15T09:05:07\n"));
}

test "a second file of the same name takes the next free one, and a folder goes whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var trash: [512]u8 = undefined;
    const bin = try scratch(&tmp, &trash, "Trash");
    for ([_][]const u8{ "one", "two" }) |folder| {
        var note: [64]u8 = undefined;
        try tmp.dir.createDirPath(testing.io, folder);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&note, "{s}/notes.md", .{folder}), .data = folder });
    }
    var from: [512]u8 = undefined;
    try freedesktop.move(testing.allocator, testing.io, try scratch(&tmp, &from, "one" ++ std.fs.path.sep_str ++ "notes.md"), bin, stamp);
    try freedesktop.move(testing.allocator, testing.io, try scratch(&tmp, &from, "two" ++ std.fs.path.sep_str ++ "notes.md"), bin, stamp);
    var kept: [16]u8 = undefined;
    try testing.expectEqualStrings("one", try tmp.dir.readFile(testing.io, "Trash/files/notes.md", &kept));
    try testing.expectEqualStrings("two", try tmp.dir.readFile(testing.io, "Trash/files/notes.md.2", &kept));
    try tmp.dir.access(testing.io, "Trash/info/notes.md.2.trashinfo", .{});

    try tmp.dir.createDirPath(testing.io, "level/parts");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "level/parts/a.json", .data = "{}" });
    try freedesktop.move(testing.allocator, testing.io, try scratch(&tmp, &from, "level"), bin, stamp);
    try tmp.dir.access(testing.io, "Trash/files/level/parts/a.json", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "level", .{}));
}

test "a file that is not there is said so, and leaves no info file claiming a name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var from: [512]u8 = undefined;
    var trash: [512]u8 = undefined;
    try testing.expectError(error.FileNotFound, freedesktop.move(testing.allocator, testing.io, try scratch(&tmp, &from, "gone.png"), try scratch(&tmp, &trash, "Trash"), stamp));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "Trash/info/gone.png.trashinfo", .{}));
    if (available) try testing.expectError(error.FileNotFound, move(testing.allocator, testing.io, try scratch(&tmp, &from, "gone.png")));
}

test "every byte a URL would not carry as it is, is written as %XX" {
    const said = try freedesktop.infoText(testing.allocator, "/home/me/Pictures/hérø [1].png", stamp);
    defer testing.allocator.free(said);
    try testing.expectEqualStrings("[Trash Info]\nPath=/home/me/Pictures/h%C3%A9r%C3%B8%20%5B1%5D.png\nDeletionDate=2026-09-15T09:05:07\n", said);
}
