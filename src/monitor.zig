// SPDX-License-Identifier: BSL-1.0

//! The displays attached to this machine, and what each of them can do.
//!
//! A monitor is a value, not a handle: everything worth knowing about one is
//! small and is gathered when the list is built, so reading it is a field
//! access rather than a round trip to the display server. The list belongs to
//! the `Context` and is rebuilt when asked for, which is the only time a
//! monitor being unplugged can change anything under a program's feet.
//!
//! **The work area is not the whole monitor.** A taskbar, a dock or a panel
//! takes a strip out of it, and a window placed by the full bounds appears
//! underneath one. `work_area` is where a window belongs; `bounds` is where the
//! pixels are.
//!
//! **Physical size is what the display reports, and displays lie.** A monitor
//! with no EDID says zero, a projector says whatever it feels like, and a 4K
//! television on the desk here claims to be 1.6 metres across. It is not what
//! DPI scaling should be computed from - `scale_x` is, because that is the
//! number the user actually set - and it is here only because a program that
//! wants real-world units has nowhere else to get them.
//!
//! **Not every backend can answer every question.** Wayland has no work area to
//! ask for and no mode to switch to, an X server without RandR sees a
//! two-monitor desktop as one wide screen, and Android has one display that a
//! program cannot choose. Each of those is reported as what it is - the whole
//! monitor as the work area, an empty list, a refused mode change - rather than
//! guessed at.

const std = @import("std");
const testing = std.testing;

/// A resolution, a colour depth and a refresh rate: one thing a display can be
/// switched to.
pub const VideoMode = struct {
    /// Zero for a display that has not said - a headless session, or a mode a
    /// backend could not read.
    width: u32 = 0,
    height: u32 = 0,
    /// Bits per pixel across all channels. 24 or 32 on anything modern, and
    /// zero where the backend does not report it.
    bits: u32 = 0,
    /// In hertz, rounded. Zero where it is not known - Wayland reports
    /// millihertz and a virtual display may report nothing.
    refresh_hz: u32 = 0,

    /// Same pixels? Ignores refresh rate and depth, which is the comparison a
    /// program picking a resolution from a menu wants.
    pub fn sameSize(self: VideoMode, other: VideoMode) bool {
        return self.width == other.width and self.height == other.height;
    }

    /// Sorts smallest first, then by refresh rate. For putting a list in front
    /// of a person.
    pub fn lessThan(_: void, a: VideoMode, b: VideoMode) bool {
        if (a.width != b.width) return a.width < b.width;
        if (a.height != b.height) return a.height < b.height;
        return a.refresh_hz < b.refresh_hz;
    }

    pub fn format(self: VideoMode, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}x{d}", .{ self.width, self.height });
        if (self.refresh_hz != 0) try w.print(" @{d}Hz", .{self.refresh_hz});
    }
};

/// A rectangle in the virtual desktop.
///
/// Same coordinates as `Window.position`, so a window can be matched to the
/// monitor it is on. Not the same units as `Window.size`, which is logical:
/// these are the screen's own, which is what a position is measured in.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and
            px < self.x + @as(i32, @intCast(self.width)) and
            py < self.y + @as(i32, @intCast(self.height));
    }

    /// How many pixels two rectangles share.
    pub fn overlap(self: Rect, other: Rect) u64 {
        const left = @max(self.x, other.x);
        const top = @max(self.y, other.y);
        const right = @min(@as(i64, self.x) + self.width, @as(i64, other.x) + other.width);
        const bottom = @min(@as(i64, self.y) + self.height, @as(i64, other.y) + other.height);
        if (right <= left or bottom <= top) return 0;
        return @intCast((right - left) * (bottom - top));
    }
};

/// The longest monitor name this library keeps. Held inline rather than
/// allocated, so a `Monitor` is a value with nothing to free.
pub const max_name_len = 63;

/// One display.
pub const Monitor = struct {
    /// What the system calls it - `\\.\DISPLAY1`, `HDMI-A-1`, the model name a
    /// Wayland compositor reports. Not stable between reboots on every
    /// platform, so it is for showing a person rather than for storing.
    name_buf: [max_name_len + 1]u8 = @splat(0),
    name_len: u8 = 0,

    /// Where this monitor sits in the virtual desktop, and how big it is.
    bounds: Rect = .{},
    /// The part of it a window should be placed in - the whole thing less any
    /// taskbar or panel. Equal to `bounds` where the backend cannot say.
    work_area: Rect = .{},

    /// Millimetres, as the display reports them. Zero when it does not.
    physical_width_mm: u32 = 0,
    physical_height_mm: u32 = 0,

    /// Pixels per logical unit. What the user set, and what a program should
    /// scale by.
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    /// What it is set to now.
    current: VideoMode = .{},

    /// Every mode it can be switched to. Owned by the `Context`, and valid
    /// until the monitor list is rebuilt.
    modes: []const VideoMode = &.{},

    /// Where this monitor's modes sit in the context's one mode array. Written
    /// by a backend, read by the context, and of no interest to anyone else -
    /// `modes` is the answer once the array has stopped growing.
    mode_start: usize = 0,
    mode_count: usize = 0,

    /// True for the one a desktop treats as the main display: the one with the
    /// taskbar, and where a window with no other instruction should open.
    primary: bool = false,

    pub fn name(self: *const Monitor) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Set the name, truncating anything longer than this library keeps.
    pub fn setName(self: *Monitor, text: []const u8) void {
        const len = @min(text.len, max_name_len);
        @memcpy(self.name_buf[0..len], text[0..len]);
        self.name_buf[len] = 0;
        self.name_len = @intCast(len);
    }

    /// The largest mode this monitor has, which is what a fullscreen window
    /// with no preference should use.
    pub fn largestMode(self: *const Monitor) VideoMode {
        var best = self.current;
        for (self.modes) |mode| {
            if (mode.width * mode.height > best.width * best.height) best = mode;
        }
        return best;
    }

    pub fn format(self: Monitor, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {f}", .{ self.name(), self.current });
        if (self.primary) try w.writeAll(" (primary)");
    }
};

/// How a window fills a monitor.
pub const Fullscreen = union(enum) {
    /// A window again, at the size and place it had before.
    windowed,
    /// The whole monitor, at whatever it is already set to. What a modern game
    /// should use: no mode change, so alt-tab is instant and nothing else on
    /// the desktop is resized.
    borderless: usize,
    /// The whole monitor, after switching it to `mode`. For the cases that
    /// genuinely need a different resolution.
    exclusive: struct { monitor: usize, mode: VideoMode },

    /// Which monitor this is about, or null for windowed.
    pub fn monitorIndex(self: Fullscreen) ?usize {
        return switch (self) {
            .windowed => null,
            .borderless => |index| index,
            .exclusive => |it| it.monitor,
        };
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a name longer than the buffer is truncated rather than overflowing" {
    var mon: Monitor = .{};
    mon.setName("HDMI-A-1");
    try testing.expectEqualStrings("HDMI-A-1", mon.name());

    const long = "x" ** 200;
    mon.setName(long);
    try testing.expectEqual(@as(usize, max_name_len), mon.name().len);
    // And still terminated, so it can be handed to a C call.
    try testing.expectEqual(@as(u8, 0), mon.name_buf[max_name_len]);
}

test "an empty monitor has an empty name rather than rubbish" {
    const mon: Monitor = .{};
    try testing.expectEqualStrings("", mon.name());
}

test "modes compare by pixels, then by refresh" {
    const small: VideoMode = .{ .width = 1280, .height = 720, .refresh_hz = 60 };
    const big: VideoMode = .{ .width = 1920, .height = 1080, .refresh_hz = 60 };
    const fast: VideoMode = .{ .width = 1920, .height = 1080, .refresh_hz = 144 };

    try testing.expect(VideoMode.lessThan({}, small, big));
    try testing.expect(VideoMode.lessThan({}, big, fast));
    try testing.expect(!VideoMode.lessThan({}, fast, big));

    // The same pixels at a different rate are the same size.
    try testing.expect(big.sameSize(fast));
    try testing.expect(!big.sameSize(small));
}

test "the largest mode is the one with the most pixels" {
    const modes = [_]VideoMode{
        .{ .width = 1280, .height = 720 },
        .{ .width = 2560, .height = 1080 },
        .{ .width = 1920, .height = 1080 },
    };
    var mon: Monitor = .{ .modes = &modes, .current = .{ .width = 800, .height = 600 } };

    const largest = mon.largestMode();
    try testing.expectEqual(@as(u32, 2560), largest.width);

    // With no list, the current mode is the only answer there is.
    mon.modes = &.{};
    try testing.expectEqual(@as(u32, 800), mon.largestMode().width);
}

test "a rectangle knows what is inside it" {
    const area: Rect = .{ .x = 100, .y = 50, .width = 200, .height = 100 };

    try testing.expect(area.contains(100, 50));
    try testing.expect(area.contains(299, 149));
    // The far edge is outside, which is what makes two adjacent monitors not
    // both claim the same pixel.
    try testing.expect(!area.contains(300, 150));
    try testing.expect(!area.contains(99, 50));
}

test "two rectangles share the pixels both cover, and neighbours share none" {
    const left: Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const right: Rect = .{ .x = 1920, .y = 0, .width = 1280, .height = 1024 };
    const window: Rect = .{ .x = 1820, .y = 100, .width = 400, .height = 300 };

    try testing.expectEqual(@as(u64, 0), left.overlap(right));
    try testing.expectEqual(@as(u64, 100 * 300), left.overlap(window));
    try testing.expectEqual(@as(u64, 300 * 300), right.overlap(window));
    try testing.expectEqual(@as(u64, 400 * 300), window.overlap(window));
}

test "fullscreen says which monitor it means" {
    try testing.expectEqual(@as(?usize, null), (Fullscreen{ .windowed = {} }).monitorIndex());
    try testing.expectEqual(@as(?usize, 1), (Fullscreen{ .borderless = 1 }).monitorIndex());
    try testing.expectEqual(
        @as(?usize, 2),
        (Fullscreen{ .exclusive = .{ .monitor = 2, .mode = .{ .width = 1, .height = 1 } } }).monitorIndex(),
    );
}

test "a mode prints as a person would write it" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(
        "1920x1080 @144Hz",
        try std.fmt.bufPrint(&buf, "{f}", .{VideoMode{ .width = 1920, .height = 1080, .refresh_hz = 144 }}),
    );
    // An unknown refresh rate is left out rather than printed as zero.
    try testing.expectEqualStrings(
        "800x600",
        try std.fmt.bufPrint(&buf, "{f}", .{VideoMode{ .width = 800, .height = 600 }}),
    );
}
