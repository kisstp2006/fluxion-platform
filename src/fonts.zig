// SPDX-License-Identifier: BSL-1.0

//! The fonts the system draws its own interface and its own code in, as files
//! a font library can open.
//!
//! ```zig
//! const face = try platform.fonts.systemUi(gpa, io);
//! defer face.deinit(gpa);
//! const code = try platform.fonts.systemMono(gpa, io);
//! defer code.deinit(gpa);
//! ```
//!
//! Asked of the system rather than guessed from a list of paths: Segoe UI is
//! not the interface font on a Chinese Windows, and DejaVu is not installed on
//! every Linux.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const dyn = @import("fluxion_dyn");

pub const Face = struct {
    /// Absolute, for the caller to free.
    path: []u8,
    /// Which font in a collection - a `.ttc` - and 0 for a file of one.
    index: u32 = 0,

    pub fn deinit(self: Face, gpa: Allocator) void {
        gpa.free(self.path);
    }
};

pub const available = switch (builtin.os.tag) {
    .windows, .macos, .linux, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

pub const Error = error{
    /// See `available`.
    Unsupported,
    /// The system named a font this could not find a file for, or has none.
    NotFound,
} || Allocator.Error;

pub fn systemUi(gpa: Allocator, io: std.Io) Error!Face {
    if (comptime !available) return error.Unsupported;
    if (comptime builtin.os.tag == .windows) return windows.systemUi(gpa);
    if (comptime builtin.abi.isAndroid()) return firstThere(gpa, io, &android_files);
    if (comptime builtin.os.tag == .macos) return firstThere(gpa, io, &apple_files);
    if (fontconfig.match(gpa, "sans-serif")) |face| return face else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return firstThere(gpa, io, &linux_files),
    }
}

/// The monospaced face the system sets code and terminals in: Cascadia Mono
/// where Windows has it - it is what Windows Terminal draws in - and Consolas
/// where it has not; SF Mono or Menlo on a Mac; what fontconfig makes of
/// `monospace` on Linux; and Android's own `monospace`, Droid Sans Mono.
pub fn systemMono(gpa: Allocator, io: std.Io) Error!Face {
    if (comptime !available) return error.Unsupported;
    if (comptime builtin.os.tag == .windows) return windows.systemMono(gpa);
    if (comptime builtin.abi.isAndroid()) return firstThere(gpa, io, &android_mono_files);
    if (comptime builtin.os.tag == .macos) return firstThere(gpa, io, &apple_mono_files);
    if (fontconfig.match(gpa, "monospace")) |face| return face else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return firstThere(gpa, io, &linux_mono_files),
    }
}

const Known = struct { path: []const u8, index: u32 = 0 };

const android_files = [_]Known{
    .{ .path = "/system/fonts/Roboto-Regular.ttf" },
    .{ .path = "/system/fonts/RobotoStatic-Regular.ttf" },
    .{ .path = "/system/fonts/DroidSans.ttf" },
};

const apple_files = [_]Known{
    .{ .path = "/System/Library/Fonts/SFNS.ttf" },
    .{ .path = "/System/Library/Fonts/SFNSText.ttf" },
    .{ .path = "/System/Library/Fonts/Helvetica.ttc" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial.ttf" },
};

/// Where Debian, Fedora and Arch put the fonts a desktop always has, for a system without fontconfig.
const linux_files = [_]Known{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" },
    .{ .path = "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf" },
    .{ .path = "/usr/share/fonts/TTF/DejaVuSans.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf" },
    .{ .path = "/usr/share/fonts/google-noto/NotoSans-Regular.ttf" },
    .{ .path = "/usr/share/fonts/noto/NotoSans-Regular.ttf" },
    .{ .path = "/usr/share/fonts/liberation/LiberationSans-Regular.ttf" },
};

/// What the system's `monospace` family is on Android: `fonts.xml` names Droid
/// Sans Mono, and Cutive Mono is the serif one beside it.
const android_mono_files = [_]Known{
    .{ .path = "/system/fonts/DroidSansMono.ttf" },
    .{ .path = "/system/fonts/NotoSansMono-Regular.ttf" },
    .{ .path = "/system/fonts/CutiveMono.ttf" },
};

/// Menlo's collection holds regular, bold, italic and bold italic, in that order.
const apple_mono_files = [_]Known{
    .{ .path = "/System/Library/Fonts/SFNSMono.ttf" },
    .{ .path = "/System/Library/Fonts/Menlo.ttc", .index = 0 },
    .{ .path = "/System/Library/Fonts/Monaco.ttf" },
};

const linux_mono_files = [_]Known{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf" },
    .{ .path = "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf" },
    .{ .path = "/usr/share/fonts/TTF/DejaVuSansMono.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf" },
    .{ .path = "/usr/share/fonts/google-noto/NotoSansMono-Regular.ttf" },
    .{ .path = "/usr/share/fonts/noto/NotoSansMono-Regular.ttf" },
    .{ .path = "/usr/share/fonts/liberation/LiberationMono-Regular.ttf" },
};

fn firstThere(gpa: Allocator, io: std.Io, files: []const Known) Error!Face {
    for (files) |file| {
        std.Io.Dir.cwd().access(io, file.path, .{}) catch continue;
        return .{ .path = try gpa.dupe(u8, file.path), .index = file.index };
    }
    return error.NotFound;
}

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------

const windows = struct {
    const LogFont = extern struct {
        height: i32,
        width: i32,
        escapement: i32,
        orientation: i32,
        weight: i32,
        italic: u8,
        underline: u8,
        strike_out: u8,
        char_set: u8,
        out_precision: u8,
        clip_precision: u8,
        quality: u8,
        pitch_and_family: u8,
        face_name: [32]u16,
    };

    const NonClientMetrics = extern struct {
        size: u32 = @sizeOf(NonClientMetrics),
        border_width: i32 = 0,
        scroll_width: i32 = 0,
        scroll_height: i32 = 0,
        caption_width: i32 = 0,
        caption_height: i32 = 0,
        caption_font: LogFont = std.mem.zeroes(LogFont),
        small_caption_width: i32 = 0,
        small_caption_height: i32 = 0,
        small_caption_font: LogFont = std.mem.zeroes(LogFont),
        menu_width: i32 = 0,
        menu_height: i32 = 0,
        menu_font: LogFont = std.mem.zeroes(LogFont),
        status_font: LogFont = std.mem.zeroes(LogFont),
        message_font: LogFont = std.mem.zeroes(LogFont),
        padded_border_width: i32 = 0,
    };

    const spi_getnonclientmetrics: u32 = 0x0029;
    const HKey = *opaque {};
    /// `(HKEY)(LONG)0x80000002` and `...01`, sign-extended to a pointer's width.
    const hkey_local_machine: HKey = @ptrFromInt(@as(usize, @bitCast(@as(isize, -0x7FFFFFFE))));
    const hkey_current_user: HKey = @ptrFromInt(@as(usize, @bitCast(@as(isize, -0x7FFFFFFF))));
    const key_read: u32 = 0x20019;
    const reg_sz: u32 = 1;
    const reg_expand_sz: u32 = 2;
    const fonts_key = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts");

    const User32 = struct {
        SystemParametersInfoW: *const fn (u32, u32, ?*anyopaque, u32) callconv(.winapi) i32,
    };
    const Advapi32 = struct {
        RegOpenKeyExW: *const fn (HKey, [*:0]const u16, u32, u32, *?HKey) callconv(.winapi) i32,
        RegEnumValueW: *const fn (HKey, u32, [*]u16, *u32, ?*u32, ?*u32, ?[*]u8, ?*u32) callconv(.winapi) i32,
        RegCloseKey: *const fn (HKey) callconv(.winapi) i32,
    };
    const Kernel32 = struct {
        GetWindowsDirectoryW: *const fn ([*]u16, u32) callconv(.winapi) u32,
    };

    fn systemUi(gpa: Allocator) Error!Face {
        var user32 = dyn.openSystem("user32.dll") catch return error.Unsupported;
        defer user32.close();
        const user = user32.bind(User32) catch return error.Unsupported;
        var metrics: NonClientMetrics = .{};
        if (user.SystemParametersInfoW(spi_getnonclientmetrics, @sizeOf(NonClientMetrics), &metrics, 0) == 0) return error.NotFound;
        const wide = std.mem.sliceTo(&metrics.message_font.face_name, 0);
        var name_bytes: [128]u8 = undefined;
        const len = std.unicode.wtf16LeToWtf8(&name_bytes, wide);
        if (len > name_bytes.len) return error.NotFound;
        return byName(gpa, name_bytes[0..len]);
    }

    /// Cascadia Mono came with Windows 11 and Windows Terminal; Consolas has
    /// been there since Vista, and Courier New since before either.
    fn systemMono(gpa: Allocator) Error!Face {
        for ([_][]const u8{ "Cascadia Mono", "Consolas", "Courier New" }) |family| {
            if (byName(gpa, family)) |face| return face else |err| switch (err) {
                error.NotFound => continue,
                else => return err,
            }
        }
        return error.NotFound;
    }

    /// Through the registry's list of installed fonts, which is what maps a
    /// family to its file - the machine's first, then the user's own.
    fn byName(gpa: Allocator, family: []const u8) Error!Face {
        var advapi32 = dyn.openSystem("advapi32.dll") catch return error.Unsupported;
        defer advapi32.close();
        const reg = advapi32.bind(Advapi32) catch return error.Unsupported;
        for ([_]HKey{ hkey_local_machine, hkey_current_user }) |root| {
            var key: ?HKey = null;
            if (reg.RegOpenKeyExW(root, fonts_key, 0, key_read, &key) != 0) continue;
            defer _ = reg.RegCloseKey(key.?);
            if (try lookUp(gpa, reg, key.?, family)) |face| return face;
        }
        return error.NotFound;
    }

    fn lookUp(gpa: Allocator, reg: Advapi32, key: HKey, family: []const u8) Error!?Face {
        var name: [16384]u16 = undefined;
        var data: [2048]u8 align(2) = undefined;
        var index: u32 = 0;
        while (true) : (index += 1) {
            var name_len: u32 = name.len;
            var data_len: u32 = data.len;
            var kind: u32 = 0;
            const status = reg.RegEnumValueW(key, index, &name, &name_len, null, &kind, &data, &data_len);
            if (status == 259) return null;
            if (status != 0 or (kind != reg_sz and kind != reg_expand_sz)) continue;

            var listed: [1024]u8 = undefined;
            const listed_len = std.unicode.wtf16LeToWtf8(&listed, name[0..@min(name_len, listed.len / 3)]);
            const which = faceIndex(listed[0..listed_len], family) orelse continue;

            const units: []const u16 = @as([*]const u16, @ptrCast(&data))[0 .. data_len / 2];
            const file = std.mem.sliceTo(units, 0);
            const whole = try fontFile(gpa, file);
            return .{ .path = whole, .index = which };
        }
    }

    /// A file name is in the Windows fonts folder; a user's own font is listed with its whole path.
    fn fontFile(gpa: Allocator, file: []const u16) Error![]u8 {
        const named = try std.unicode.wtf16LeToWtf8Alloc(gpa, file);
        if (std.fs.path.isAbsoluteWindows(named)) return named;
        defer gpa.free(named);
        var kernel32 = dyn.openSystem("kernel32.dll") catch return error.Unsupported;
        defer kernel32.close();
        const kernel = kernel32.bind(Kernel32) catch return error.Unsupported;
        var windows_dir: [260]u16 = undefined;
        const dir_len = kernel.GetWindowsDirectoryW(&windows_dir, windows_dir.len);
        if (dir_len == 0 or dir_len >= windows_dir.len) return error.NotFound;
        const dir = try std.unicode.wtf16LeToWtf8Alloc(gpa, windows_dir[0..dir_len]);
        defer gpa.free(dir);
        return std.fs.path.join(gpa, &.{ dir, "Fonts", named });
    }
};

/// Which face of a registry entry's list a family is: `"Segoe UI (TrueType)"`
/// is one font, `"Microsoft YaHei & Microsoft YaHei UI (TrueType)"` a
/// collection of two, in file order.
fn faceIndex(listed: []const u8, family: []const u8) ?u32 {
    var names = listed;
    if (std.mem.lastIndexOf(u8, names, " (")) |open| {
        if (std.mem.endsWith(u8, names, ")")) names = names[0..open];
    }
    var parts = std.mem.splitSequence(u8, names, " & ");
    var index: u32 = 0;
    while (parts.next()) |part| : (index += 1) {
        if (sameFamily(std.mem.trim(u8, part, " "), family)) return index;
    }
    return null;
}

/// The family itself, or its regular face named as one: a font whose weights
/// are all in one variable file - Cascadia Mono - is listed as
/// `"Cascadia Mono Regular"`, where a family of separate files lists its
/// regular face by the family's name alone.
fn sameFamily(name: []const u8, family: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, family)) return true;
    const regular = " Regular";
    return name.len == family.len + regular.len and
        std.ascii.startsWithIgnoreCase(name, family) and
        std.ascii.endsWithIgnoreCase(name, regular);
}

// -------------------------------------------------------------------------
// fontconfig
// -------------------------------------------------------------------------

const fontconfig = struct {
    const Pattern = opaque {};
    const Config = opaque {};

    const Fc = struct {
        FcNameParse: *const fn ([*:0]const u8) callconv(.c) ?*Pattern,
        FcConfigSubstitute: *const fn (?*Config, *Pattern, c_int) callconv(.c) c_int,
        FcDefaultSubstitute: *const fn (*Pattern) callconv(.c) void,
        FcFontMatch: *const fn (?*Config, *Pattern, *c_int) callconv(.c) ?*Pattern,
        FcPatternGetString: *const fn (*Pattern, [*:0]const u8, c_int, *?[*:0]const u8) callconv(.c) c_int,
        FcPatternGetInteger: *const fn (*Pattern, [*:0]const u8, c_int, *c_int) callconv(.c) c_int,
        FcPatternDestroy: *const fn (*Pattern) callconv(.c) void,
    };

    const match_pattern: c_int = 0;
    const result_match: c_int = 0;

    /// What the desktop's own configuration makes of a family name, as a
    /// toolkit would ask it.
    fn match(gpa: Allocator, family: [*:0]const u8) (error{NotFound} || Allocator.Error)!Face {
        var lib = dyn.Library.openAny(&.{ "libfontconfig.so.1", "libfontconfig.so" }) catch return error.NotFound;
        defer lib.close();
        const fc = lib.bind(Fc) catch return error.NotFound;

        const pattern = fc.FcNameParse(family) orelse return error.NotFound;
        defer fc.FcPatternDestroy(pattern);
        if (fc.FcConfigSubstitute(null, pattern, match_pattern) == 0) return error.NotFound;
        fc.FcDefaultSubstitute(pattern);
        var result: c_int = 0;
        const found = fc.FcFontMatch(null, pattern, &result) orelse return error.NotFound;
        defer fc.FcPatternDestroy(found);

        var file: ?[*:0]const u8 = null;
        if (fc.FcPatternGetString(found, "file", 0, &file) != result_match) return error.NotFound;
        var index: c_int = 0;
        if (fc.FcPatternGetInteger(found, "index", 0, &index) != result_match) index = 0;
        return .{ .path = try gpa.dupe(u8, std.mem.span(file orelse return error.NotFound)), .index = @intCast(@max(0, index)) };
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a registry entry names one font or a collection of them, in file order" {
    try testing.expectEqual(@as(?u32, 0), faceIndex("Segoe UI (TrueType)", "Segoe UI"));
    try testing.expectEqual(@as(?u32, null), faceIndex("Segoe UI Bold (TrueType)", "Segoe UI"));
    try testing.expectEqual(@as(?u32, 1), faceIndex("Microsoft YaHei & Microsoft YaHei UI (TrueType)", "Microsoft YaHei UI"));
    try testing.expectEqual(@as(?u32, 0), faceIndex("Microsoft YaHei & Microsoft YaHei UI (TrueType)", "microsoft yahei"));
    try testing.expectEqual(@as(?u32, 0), faceIndex("Cascadia Code (OpenType)", "Cascadia Code"));
    try testing.expectEqual(@as(?u32, 0), faceIndex("Cascadia Mono Regular (TrueType)", "Cascadia Mono"));
    try testing.expectEqual(@as(?u32, null), faceIndex("Consolas Bold (TrueType)", "Consolas"));
    try testing.expectEqual(@as(?u32, null), faceIndex("Cascadia Mono PL Regular (TrueType)", "Cascadia Mono"));
    try testing.expectEqual(@as(?u32, 0), faceIndex("My Font", "My Font"));
}

test "the Windows metrics are the size Windows says they are" {
    try testing.expectEqual(@as(usize, 92), @sizeOf(windows.LogFont));
    try testing.expectEqual(@as(usize, 504), @sizeOf(windows.NonClientMetrics));
}

test "the code font is a file that is there" {
    if (!available or builtin.abi.isAndroid()) return error.SkipZigTest;
    const face = systemMono(testing.allocator, testing.io) catch |err| switch (err) {
        error.NotFound => return error.SkipZigTest,
        else => return err,
    };
    defer face.deinit(testing.allocator);
    try std.Io.Dir.cwd().access(testing.io, face.path, .{});
}

test "the interface font is a file that is there" {
    if (!available or builtin.abi.isAndroid()) return error.SkipZigTest;
    const face = systemUi(testing.allocator, testing.io) catch |err| switch (err) {
        error.NotFound => return error.SkipZigTest,
        else => return err,
    };
    defer face.deinit(testing.allocator);
    try std.Io.Dir.cwd().access(testing.io, face.path, .{});
}
