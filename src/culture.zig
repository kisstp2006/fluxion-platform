// SPDX-License-Identifier: BSL-1.0

//! What the system knows of the person at it: the language and region they
//! read in, how dates, times and spans of time are written there, and the
//! time zone they live in.
//!
//! ```zig
//! var tag: [platform.culture.max_tag]u8 = undefined;
//! const mine = platform.culture.userLocale(&tag);        // "hu-HU"
//! const offset = platform.culture.utcOffset(unix_ms);    // 7200, in summer
//!
//! const hu = try platform.culture.Culture.open(gpa, "hu-HU");
//! defer hu.close();
//! hu.monthName(8, .wide, .format)                        // "szeptember"
//! hu.datePattern(.long)                                  // "y. MMMM d."
//! hu.relative(&buf, -1, .day, .wide, false)              // "tegnap"
//! ```
//!
//! **Asked of the system's own ICU** - the library every system keeps its
//! languages' data in: `icu.dll` on Windows 10 and 11, `libicu.so` on Android
//! 12 and later, `libicuuc` and `libicui18n` on a Linux that has them. What a
//! culture says is what the rest of the machine says: its names, its
//! patterns, and the choices the person made in the system's settings - a
//! week that starts on Sunday, a clock of twelve hours.
//!
//! **Patterns are CLDR's**, the letters ICU and every locale's data use:
//! `y. MMMM d.`, `EEEE, MMMM d, y`, `H:mm`. A program formats with them
//! itself, from the names here, so a date is written the same way whatever
//! its time zone and however fine its seconds.
//!
//! **Where there is no ICU** - a browser, an older Android, a Linux without
//! it - a culture is English as the United States writes it, and says so in
//! `source`. The time zone is still the system's: `localtime_r` where there
//! is a libc, and Windows' own rules where there is not.
//!
//! Not safe to call from two threads at once: the library is loaded the
//! first time it is wanted.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const dyn = @import("fluxion_dyn");

/// The longest tag `userLocale` gives.
pub const max_tag = 64;

/// How much of a name: `szeptember`, `szept.`, `Sz`.
pub const Width = enum { wide, abbreviated, narrow };

/// A name inside a date, or on its own: Polish writes `25 września` and,
/// over a calendar, `wrzesień`.
pub const Context = enum { format, standalone };

/// How much of a date or a time a style writes.
pub const Style = enum { full, long, medium, short };

/// What a span of time is counted in.
pub const Unit = enum { second, minute, hour, day, week, month, quarter, year };

/// Which form a number takes its noun in: English has `one` and `other`,
/// Polish `one`, `few`, `many` and `other`.
pub const Plural = enum { zero, one, two, few, many, other };

/// Where a culture's data came from.
pub const Source = enum {
    /// The system's ICU.
    system,
    /// Nothing to ask: English, as the United States writes it.
    fallback,
};

/// Whether this build can ask a system at all. A culture opens everywhere;
/// where this is false it is always the fallback.
pub const available = switch (builtin.os.tag) {
    .windows, .linux => true,
    else => false,
};

/// The locale the person chose, as a BCP 47 tag: `hu-HU`, `en-US`, `pt-BR`.
/// `en-US` when the system does not say.
pub fn userLocale(buf: *[max_tag]u8) []const u8 {
    if (icu()) |lib| {
        if (lib.uloc_getDefault()) |id| {
            var base: [max_tag]u8 = undefined;
            var status: Status = 0;
            const len = lib.uloc_getBaseName(id, &base, max_tag - 1, &status);
            if (status <= 0 and len > 0) {
                base[@intCast(len)] = 0;
                return tagOf(lib, base[0..@intCast(len) :0], buf) orelse copy(buf, fallback_tag);
            }
        }
    }
    return nativeLocale(buf);
}

/// Seconds east of UTC in the system's time zone at `unix_ms` - summer time
/// included, for that moment rather than for now.
pub fn utcOffset(unix_ms: i64) i32 {
    if (icu()) |lib| if (zoneCalendar(lib)) |cal| {
        var status: Status = 0;
        lib.ucal_setMillis(cal, @floatFromInt(unix_ms), &status);
        const zone = lib.ucal_get(cal, ucal_zone_offset, &status);
        const dst = lib.ucal_get(cal, ucal_dst_offset, &status);
        if (status <= 0) return @divTrunc(zone + dst, 1000);
    };
    return nativeOffset(unix_ms);
}

/// The system's time zone: an IANA name, `Europe/Budapest`, where the system
/// has one, and empty where it does not say.
pub fn timeZoneName(buf: []u8) []const u8 {
    const lib = icu() orelse return "";
    var wide: [128]UChar = undefined;
    var status: Status = 0;
    const len = lib.ucal_getDefaultTimeZone(&wide, wide.len, &status);
    if (status > 0 or len <= 0) return "";
    return utf8Of(wide[0..@intCast(@min(len, wide.len))], buf);
}

// -------------------------------------------------------------------------
// A culture
// -------------------------------------------------------------------------

/// One locale's names and patterns, read once, and its way of counting and
/// saying how long ago, asked each time.
pub const Culture = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    /// The tag the system took it for: `hu-HU`.
    tag: []const u8,
    source: Source,
    /// `[context][width][month]`, January first.
    months: [2][3][12][]const u8,
    /// `[context][width][day]`, Monday first.
    weekdays: [2][3][7][]const u8,
    /// Before and after noon: `de.`, `du.`; `AM`, `PM`.
    day_periods: [2][]const u8,
    /// `[width][era]`, before and after the common era: `i. e.`, `i. sz.`.
    eras: [2][2][]const u8,
    /// `[width][quarter]`: `I. negyedév`, `I. n.év`.
    quarters: [2][4][]const u8,
    /// `[date style][time style]`, then one without the other.
    date_times: [4][4][]const u8,
    dates: [4][]const u8,
    times: [4][]const u8,
    /// The day a week starts on, 1 for Monday to 7 for Sunday, and how many
    /// of its days the first week of a year must have.
    first_weekday: u3,
    minimal_days: u3,
    /// Whether its clock has twelve hours rather than twenty-four.
    twelve_hours: bool,

    /// The system's handles for what is asked each time. Null for the
    /// fallback.
    icu_id: [:0]const u8 = "",
    relative_formatters: [3]?*anyopaque = @splat(null),
    plurals: ?*anyopaque = null,
    generator: ?*anyopaque = null,
    units: [8][3]?*anyopaque = @splat(@splat(null)),
    list_formatter: [3]?*anyopaque = @splat(null),

    /// The culture for `tag`, or the person's own for an empty one - with
    /// the choices they made in the system's settings. A tag the system does
    /// not know is the closest one it does; with no system to ask, English.
    pub fn open(gpa: Allocator, tag: []const u8) Allocator.Error!*Culture {
        const self = try gpa.create(Culture);
        errdefer gpa.destroy(self);
        self.* = english(gpa);
        errdefer self.arena.deinit();
        const lib = icu() orelse return self;
        self.fromSystem(lib, tag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Refused => {
                self.arena.deinit();
                self.* = english(gpa);
            },
        };
        return self;
    }

    /// English as the United States writes it, whatever the system has:
    /// the same everywhere, for a test or a game that wants it.
    pub fn openEnglish(gpa: Allocator) Allocator.Error!*Culture {
        const self = try gpa.create(Culture);
        self.* = english(gpa);
        return self;
    }

    pub fn close(self: *Culture) void {
        if (icu()) |lib| {
            for (self.relative_formatters) |held| if (held) |h| lib.ureldatefmt_close(h);
            if (self.plurals) |h| lib.uplrules_close(h);
            if (self.generator) |h| lib.udatpg_close(h);
            for (self.units) |row| for (row) |held| if (held) |h| if (lib.unumf_close) |free| free(h);
            for (self.list_formatter) |held| if (held) |h| if (lib.ulistfmt_close) |free| free(h);
        }
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn monthName(self: *const Culture, month: u4, width: Width, context: Context) []const u8 {
        return self.months[@intFromEnum(context)][@intFromEnum(width)][month - 1];
    }

    /// A day's name, 1 for Monday to 7 for Sunday.
    pub fn weekdayName(self: *const Culture, day: u3, width: Width, context: Context) []const u8 {
        return self.weekdays[@intFromEnum(context)][@intFromEnum(width)][day - 1];
    }

    pub fn datePattern(self: *const Culture, style: Style) []const u8 {
        return self.dates[@intFromEnum(style)];
    }

    pub fn timePattern(self: *const Culture, style: Style) []const u8 {
        return self.times[@intFromEnum(style)];
    }

    /// A date and a time together, as the culture joins them.
    pub fn dateTimePattern(self: *const Culture, date: Style, time: Style) []const u8 {
        return self.date_times[@intFromEnum(date)][@intFromEnum(time)];
    }

    /// The best pattern for what a program wants shown, named by a
    /// skeleton - the letters of a pattern in any order, without the
    /// punctuation: `MMMMd` is `MMMM d.` in Hungarian and `MMMM d` in
    /// English, `yMMM` is `y. MMM` and `MMM y`. The fallback gives the
    /// skeleton back.
    pub fn bestPattern(self: *Culture, buf: []u8, skeleton: []const u8) []const u8 {
        const lib = icu() orelse return copy(buf, skeleton);
        if (self.icu_id.len == 0) return copy(buf, skeleton);
        if (self.generator == null) {
            var status: Status = 0;
            self.generator = lib.udatpg_open(self.icu_id.ptr, &status);
            if (status > 0) self.generator = null;
        }
        const generator = self.generator orelse return copy(buf, skeleton);
        var wide_skeleton: [64]UChar = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide_skeleton, skeleton) catch return copy(buf, skeleton);
        var wide: [128]UChar = undefined;
        var status: Status = 0;
        const len = lib.udatpg_getBestPattern(generator, &wide_skeleton, @intCast(n), &wide, wide.len, &status);
        if (status > 0 or len <= 0) return copy(buf, skeleton);
        return utf8Of(wide[0..@intCast(@min(len, wide.len))], buf);
    }

    /// How long ago or from now `value` of `unit` is: `-1` days is
    /// `tegnap`, `yesterday`, and with `numeric` `1 nappal ezelőtt`,
    /// `1 day ago`; nought seconds is `most`, `now`.
    pub fn relative(self: *Culture, buf: []u8, value: f64, unit: Unit, width: Width, numeric: bool) []const u8 {
        if (self.relativeFormatter(width)) |formatter| {
            const lib = icu().?;
            var wide: [128]UChar = undefined;
            var status: Status = 0;
            const call = if (numeric) lib.ureldatefmt_formatNumeric else lib.ureldatefmt_format;
            const len = call(formatter, value, relativeUnit(unit), &wide, wide.len, &status);
            if (status <= 0 and len > 0) return utf8Of(wide[0..@intCast(@min(len, wide.len))], buf);
        }
        return englishRelative(buf, value, unit, numeric);
    }

    /// The form a noun takes after `n`: `one` for 1 in English, `few` for
    /// 22 in Polish.
    pub fn plural(self: *Culture, n: f64) Plural {
        if (icu()) |lib| if (self.icu_id.len > 0) {
            if (self.plurals == null) {
                var status: Status = 0;
                self.plurals = lib.uplrules_open(self.icu_id.ptr, &status);
                if (status > 0) self.plurals = null;
            }
            if (self.plurals) |rules| {
                var wide: [16]UChar = undefined;
                var status: Status = 0;
                const len = lib.uplrules_select(rules, n, &wide, wide.len, &status);
                if (status <= 0 and len > 0) {
                    var word: [16]u8 = undefined;
                    return std.meta.stringToEnum(Plural, utf8Of(wide[0..@intCast(@min(len, wide.len))], &word)) orelse .other;
                }
            }
        };
        return if (n == 1) .one else .other;
    }

    /// `value` of `unit` with the unit's name: `5 óra`, `5 ó`; `5 hours`,
    /// `5 hr`.
    pub fn amount(self: *Culture, buf: []u8, value: f64, unit: Unit, width: Width) []const u8 {
        if (self.unitFormatter(unit, width)) |formatter| {
            const lib = icu().?;
            var status: Status = 0;
            if (lib.unumf_openResult.?(&status)) |result| {
                defer lib.unumf_closeResult.?(result);
                lib.unumf_formatDouble.?(formatter, value, result, &status);
                var wide: [64]UChar = undefined;
                const len = lib.unumf_resultToString.?(result, &wide, wide.len, &status);
                if (status <= 0 and len > 0) return utf8Of(wide[0..@intCast(@min(len, wide.len))], buf);
            }
        }
        return englishAmount(buf, value, unit, width);
    }

    /// Amounts of units, one after another as the culture lists them:
    /// `1 hour, 5 minutes`, `1 óra, 5 perc`.
    pub fn list(self: *Culture, buf: []u8, items: []const []const u8, width: Width) []const u8 {
        if (self.listFormatter(width)) |formatter| if (items.len <= 8) {
            const lib = icu().?;
            var wide_items: [8][64]UChar = undefined;
            var starts: [8][*]const UChar = undefined;
            var lengths: [8]i32 = undefined;
            for (items, 0..) |item, i| {
                const n = std.unicode.utf8ToUtf16Le(&wide_items[i], item[0..@min(item.len, 60)]) catch 0;
                starts[i] = &wide_items[i];
                lengths[i] = @intCast(n);
            }
            var wide: [256]UChar = undefined;
            var status: Status = 0;
            const len = lib.ulistfmt_format.?(formatter, &starts, &lengths, @intCast(items.len), &wide, wide.len, &status);
            if (status <= 0 and len > 0) return utf8Of(wide[0..@intCast(@min(len, wide.len))], buf);
        };
        return joined(buf, items, ", ");
    }

    /// The system time zone's name at `unix_ms`: `közép-európai nyári idő`,
    /// `Central European Summer Time`, or with `long` false `CEST`, `GMT+2`.
    /// Empty for the fallback.
    pub fn zoneName(self: *const Culture, buf: []u8, unix_ms: i64, long: bool) []const u8 {
        const lib = icu() orelse return "";
        if (self.icu_id.len == 0) return "";
        const pattern = std.unicode.utf8ToUtf16LeStringLiteral("zzzz");
        var status: Status = 0;
        const formatter = lib.udat_open(udat_pattern, udat_pattern, self.icu_id.ptr, null, 0, pattern, if (long) 4 else 1, &status) orelse return "";
        defer lib.udat_close(formatter);
        if (status > 0) return "";
        var wide: [96]UChar = undefined;
        const len = lib.udat_format(formatter, @floatFromInt(unix_ms), &wide, wide.len, null, &status);
        if (status > 0 or len <= 0) return "";
        return utf8Of(wide[0..@intCast(@min(len, wide.len))], buf);
    }

    // ---------------------------------------------------------------------

    fn fromSystem(self: *Culture, lib: *const Icu, tag: []const u8) error{ OutOfMemory, Refused }!void {
        const arena = self.arena.allocator();
        var id_buffer: [128]u8 = undefined;
        const id: [:0]const u8 = if (tag.len == 0) blk: {
            const system = lib.uloc_getDefault() orelse return error.Refused;
            break :blk std.mem.span(system);
        } else blk: {
            var tag_z: [max_tag + 1]u8 = undefined;
            if (tag.len > max_tag) return error.Refused;
            @memcpy(tag_z[0..tag.len], tag);
            tag_z[tag.len] = 0;
            var status: Status = 0;
            const len = lib.uloc_forLanguageTag(tag_z[0..tag.len :0].ptr, &id_buffer, id_buffer.len - 1, null, &status);
            if (status > 0 or len <= 0) return error.Refused;
            id_buffer[@intCast(len)] = 0;
            break :blk id_buffer[0..@intCast(len) :0];
        };
        self.icu_id = try arena.dupeZ(u8, id);
        self.source = .system;

        var base: [max_tag]u8 = undefined;
        var status: Status = 0;
        const base_len = lib.uloc_getBaseName(self.icu_id.ptr, &base, max_tag - 1, &status);
        var tag_buffer: [max_tag]u8 = undefined;
        if (status <= 0 and base_len > 0) {
            base[@intCast(base_len)] = 0;
            if (tagOf(lib, base[0..@intCast(base_len) :0], &tag_buffer)) |named| self.tag = try arena.dupe(u8, named);
        }

        // The patterns, one formatter a style.
        for (0..4) |d| {
            self.dates[d] = try self.patternOf(lib, @intCast(d), udat_none);
            self.times[d] = try self.patternOf(lib, udat_none, @intCast(d));
            for (0..4) |t| self.date_times[d][t] = try self.patternOf(lib, @intCast(d), @intCast(t));
        }
        self.twelve_hours = hasTwelveHours(self.times[@intFromEnum(Style.short)]);

        // The names.
        status = 0;
        const formatter = lib.udat_open(udat_short, udat_short, self.icu_id.ptr, null, 0, null, 0, &status) orelse return error.Refused;
        defer lib.udat_close(formatter);
        if (status > 0) return error.Refused;
        const month_kinds = [2][3]c_int{ .{ 1, 2, 8 }, .{ 10, 11, 12 } };
        const day_kinds = [2][3]c_int{ .{ 3, 4, 9 }, .{ 13, 14, 15 } };
        for (0..2) |c| for (0..3) |w| {
            for (0..12) |m| self.months[c][w][m] = try self.symbol(lib, formatter, month_kinds[c][w], @intCast(m));
            // The system counts from Sunday at 1; these start on Monday.
            for (0..7) |d| self.weekdays[c][w][d] = try self.symbol(lib, formatter, day_kinds[c][w], @intCast((d + 1) % 7 + 1));
        };
        for (0..2) |p| self.day_periods[p] = try self.symbol(lib, formatter, 5, @intCast(p));
        for (0..2) |e| {
            self.eras[0][e] = try self.symbol(lib, formatter, 7, @intCast(e));
            self.eras[1][e] = try self.symbol(lib, formatter, 0, @intCast(e));
        }
        for (0..4) |q| {
            self.quarters[0][q] = try self.symbol(lib, formatter, 16, @intCast(q));
            self.quarters[1][q] = try self.symbol(lib, formatter, 17, @intCast(q));
        }

        // The week.
        status = 0;
        const cal = lib.ucal_open(null, -1, self.icu_id.ptr, ucal_gregorian, &status) orelse return error.Refused;
        defer lib.ucal_close(cal);
        const first = lib.ucal_getAttribute(cal, ucal_first_day_of_week);
        self.first_weekday = if (first == 1) 7 else @intCast(std.math.clamp(first - 1, 1, 7));
        self.minimal_days = @intCast(std.math.clamp(lib.ucal_getAttribute(cal, ucal_minimal_days), 1, 7));
    }

    fn patternOf(self: *Culture, lib: *const Icu, date: c_int, time: c_int) error{ OutOfMemory, Refused }![]const u8 {
        var status: Status = 0;
        const formatter = lib.udat_open(time, date, self.icu_id.ptr, null, 0, null, 0, &status) orelse return error.Refused;
        defer lib.udat_close(formatter);
        if (status > 0) return error.Refused;
        var wide: [128]UChar = undefined;
        const len = lib.udat_toPattern(formatter, 0, &wide, wide.len, &status);
        if (status > 0 or len <= 0) return error.Refused;
        return self.keep(wide[0..@intCast(@min(len, wide.len))]);
    }

    fn symbol(self: *Culture, lib: *const Icu, formatter: *anyopaque, kind: c_int, index: i32) Allocator.Error![]const u8 {
        var wide: [64]UChar = undefined;
        var status: Status = 0;
        const len = lib.udat_getSymbols(formatter, kind, index, &wide, wide.len, &status);
        if (status > 0 or len <= 0) return "";
        return self.keep(wide[0..@intCast(@min(len, wide.len))]);
    }

    fn keep(self: *Culture, wide: []const UChar) Allocator.Error![]const u8 {
        return std.unicode.wtf16LeToWtf8Alloc(self.arena.allocator(), wide);
    }

    fn relativeFormatter(self: *Culture, width: Width) ?*anyopaque {
        const lib = icu() orelse return null;
        if (self.icu_id.len == 0) return null;
        const slot = &self.relative_formatters[@intFromEnum(width)];
        if (slot.* == null) {
            var status: Status = 0;
            slot.* = lib.ureldatefmt_open(self.icu_id.ptr, null, @intFromEnum(width), capitalization_none, &status);
            if (status > 0) slot.* = null;
        }
        return slot.*;
    }

    fn unitFormatter(self: *Culture, unit: Unit, width: Width) ?*anyopaque {
        const lib = icu() orelse return null;
        const open_one = lib.unumf_openForSkeletonAndLocale orelse return null;
        if (self.icu_id.len == 0 or lib.unumf_openResult == null or unit == .quarter) return null;
        const slot = &self.units[@intFromEnum(unit)][@intFromEnum(width)];
        if (slot.* == null) {
            var text: [96]u8 = undefined;
            const widths = [_][]const u8{ "full-name", "short", "narrow" };
            const skeleton = std.fmt.bufPrint(&text, "measure-unit/duration-{t} unit-width-{s}", .{ unit, widths[@intFromEnum(width)] }) catch return null;
            var wide: [96]UChar = undefined;
            const n = std.unicode.utf8ToUtf16Le(&wide, skeleton) catch return null;
            var status: Status = 0;
            slot.* = open_one(&wide, @intCast(n), self.icu_id.ptr, &status);
            if (status > 0) slot.* = null;
        }
        return slot.*;
    }

    fn listFormatter(self: *Culture, width: Width) ?*anyopaque {
        const lib = icu() orelse return null;
        const open_one = lib.ulistfmt_openForType orelse return null;
        if (self.icu_id.len == 0 or lib.ulistfmt_format == null) return null;
        const slot = &self.list_formatter[@intFromEnum(width)];
        if (slot.* == null) {
            var status: Status = 0;
            slot.* = open_one(self.icu_id.ptr, ulistfmt_units, @intFromEnum(width), &status);
            if (status > 0) slot.* = null;
        }
        return slot.*;
    }
};

fn relativeUnit(unit: Unit) c_int {
    return switch (unit) {
        .year => 0,
        .quarter => 1,
        .month => 2,
        .week => 3,
        .day => 4,
        .hour => 5,
        .minute => 6,
        .second => 7,
    };
}

/// Whether a time pattern counts the hours to twelve: `h` or `K` outside
/// its quoted words.
fn hasTwelveHours(pattern: []const u8) bool {
    var quoted = false;
    for (pattern) |c| {
        if (c == '\'') quoted = !quoted else if (!quoted and (c == 'h' or c == 'K')) return true;
    }
    return false;
}

fn copy(buf: []u8, text: []const u8) []const u8 {
    const n = @min(buf.len, text.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

fn utf8Of(wide: []const UChar, buf: []u8) []const u8 {
    // Room for the worst case, three bytes a unit; a longer name is cut.
    var at: usize = 0;
    var it = std.unicode.Wtf16LeIterator.init(wide);
    while (it.nextCodepoint()) |c| {
        var one: [4]u8 = undefined;
        const n = std.unicode.wtf8Encode(c, &one) catch break;
        if (at + n > buf.len) break;
        @memcpy(buf[at..][0..n], one[0..n]);
        at += n;
    }
    return buf[0..at];
}

fn joined(buf: []u8, items: []const []const u8, between: []const u8) []const u8 {
    var at: usize = 0;
    for (items, 0..) |item, i| {
        if (i > 0) at += copy(buf[at..], between).len;
        at += copy(buf[at..], item).len;
    }
    return buf[0..at];
}

// -------------------------------------------------------------------------
// English, where there is nothing to ask
// -------------------------------------------------------------------------

const fallback_tag = "en-US";

const english_months = [3][12][]const u8{
    .{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" },
    .{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" },
    .{ "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" },
};

const english_weekdays = [3][7][]const u8{
    .{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" },
    .{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" },
    .{ "M", "T", "W", "T", "F", "S", "S" },
};

/// English as the United States writes it: what CLDR's `en-US` says.
fn english(gpa: Allocator) Culture {
    return .{
        .gpa = gpa,
        .arena = .init(gpa),
        .tag = fallback_tag,
        .source = .fallback,
        .months = .{ english_months, english_months },
        .weekdays = .{ english_weekdays, english_weekdays },
        .day_periods = .{ "AM", "PM" },
        .eras = .{ .{ "Before Christ", "Anno Domini" }, .{ "BC", "AD" } },
        .quarters = .{ .{ "1st quarter", "2nd quarter", "3rd quarter", "4th quarter" }, .{ "Q1", "Q2", "Q3", "Q4" } },
        .date_times = english_date_times,
        .dates = english_dates,
        .times = english_times,
        .first_weekday = 7,
        .minimal_days = 1,
        .twelve_hours = true,
    };
}

/// A date and a time, as `en-US` joins them: with "at" for the two longer
/// date styles, and a comma for the two shorter.
const english_date_times = blk: {
    var out: [4][4][]const u8 = undefined;
    for (0..4) |d| for (0..4) |t| {
        out[d][t] = english_dates[d] ++ (if (d < 2) " 'at' " else ", ") ++ english_times[t];
    };
    break :blk out;
};

const english_dates = [4][]const u8{ "EEEE, MMMM d, y", "MMMM d, y", "MMM d, y", "M/d/yy" };
const english_times = [4][]const u8{ "h:mm:ss a zzzz", "h:mm:ss a z", "h:mm:ss a", "h:mm a" };

fn englishRelative(buf: []u8, value: f64, unit: Unit, numeric: bool) []const u8 {
    if (!numeric) {
        if (value == 0 and unit == .second) return copy(buf, "now");
        if (unit == .day and value == -1) return copy(buf, "yesterday");
        if (unit == .day and value == 0) return copy(buf, "today");
        if (unit == .day and value == 1) return copy(buf, "tomorrow");
        if (value == -1 and unit != .second and unit != .minute and unit != .hour) return std.fmt.bufPrint(buf, "last {t}", .{unit}) catch "";
        if (value == 0 and unit != .second and unit != .minute and unit != .hour) return std.fmt.bufPrint(buf, "this {t}", .{unit}) catch "";
        if (value == 1 and unit != .second and unit != .minute and unit != .hour) return std.fmt.bufPrint(buf, "next {t}", .{unit}) catch "";
    }
    const n = @abs(value);
    var said: [48]u8 = undefined;
    const counted = englishAmount(&said, n, unit, .wide);
    return (if (value < 0)
        std.fmt.bufPrint(buf, "{s} ago", .{counted})
    else
        std.fmt.bufPrint(buf, "in {s}", .{counted})) catch "";
}

fn englishAmount(buf: []u8, value: f64, unit: Unit, width: Width) []const u8 {
    const short = [_][]const u8{ "sec", "min", "hr", "day", "wk", "mth", "qtr", "yr" };
    const narrow = [_][]const u8{ "s", "m", "h", "d", "w", "m", "q", "y" };
    const one = value == 1;
    return switch (width) {
        .wide => std.fmt.bufPrint(buf, "{d} {t}{s}", .{ value, unit, if (one) "" else "s" }),
        .abbreviated => std.fmt.bufPrint(buf, "{d} {s}", .{ value, short[@intFromEnum(unit)] }),
        .narrow => std.fmt.bufPrint(buf, "{d}{s}", .{ value, narrow[@intFromEnum(unit)] }),
    } catch "";
}

// -------------------------------------------------------------------------
// The system, without ICU
// -------------------------------------------------------------------------

fn nativeLocale(buf: *[max_tag]u8) []const u8 {
    if (comptime builtin.os.tag == .windows) {
        var kernel32 = dyn.openSystem("kernel32.dll") catch return copy(buf, fallback_tag);
        defer kernel32.close();
        const get = kernel32.lookup(*const fn ([*]u16, i32) callconv(.winapi) i32, "GetUserDefaultLocaleName") orelse return copy(buf, fallback_tag);
        var wide: [85]u16 = undefined;
        const len = get(&wide, wide.len);
        if (len <= 1) return copy(buf, fallback_tag);
        return utf8Of(wide[0..@intCast(len - 1)], buf);
    }
    if (comptime builtin.link_libc) {
        for ([_][*:0]const u8{ "LC_ALL", "LC_TIME", "LANG" }) |name| {
            const value = std.mem.span(std.c.getenv(name) orelse continue);
            if (value.len == 0) continue;
            return posixTag(value, buf);
        }
    }
    return copy(buf, fallback_tag);
}

/// `hu_HU.UTF-8` or `hu_HU@euro` as `hu-HU`; `C` and `POSIX` as English.
fn posixTag(value: []const u8, buf: *[max_tag]u8) []const u8 {
    const end = std.mem.indexOfAny(u8, value, ".@") orelse value.len;
    const name = value[0..end];
    if (name.len == 0 or std.mem.eql(u8, name, "C") or std.mem.eql(u8, name, "POSIX")) return copy(buf, fallback_tag);
    const out = copy(buf, name);
    for (buf[0..out.len]) |*c| {
        if (c.* == '_') c.* = '-';
    }
    return out;
}

fn nativeOffset(unix_ms: i64) i32 {
    if (comptime builtin.os.tag == .windows) return windowsOffset();
    if (comptime builtin.link_libc and @hasDecl(std.c, "time_t")) {
        var seconds: std.c.time_t = @intCast(@divFloor(unix_ms, 1000));
        var parts: Tm = undefined;
        if (localtime_r(&seconds, &parts) != null) return @intCast(parts.gmtoff);
    }
    return 0;
}

/// POSIX's broken-down time, as glibc, musl and bionic lay it out.
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

extern "c" fn localtime_r(timer: *const std.c.time_t, result: *Tm) ?*Tm;

/// Windows' offset now - the rule for this moment, where ICU would give the
/// one for any.
fn windowsOffset() i32 {
    const TimeZoneInformation = extern struct {
        bias: i32,
        standard_name: [32]u16,
        standard_date: [8]u16,
        standard_bias: i32,
        daylight_name: [32]u16,
        daylight_date: [8]u16,
        daylight_bias: i32,
    };
    var kernel32 = dyn.openSystem("kernel32.dll") catch return 0;
    defer kernel32.close();
    const get = kernel32.lookup(*const fn (*TimeZoneInformation) callconv(.winapi) u32, "GetTimeZoneInformation") orelse return 0;
    var info: TimeZoneInformation = undefined;
    const which = get(&info);
    const bias = info.bias + if (which == 2) info.daylight_bias else info.standard_bias;
    return -bias * 60;
}

// -------------------------------------------------------------------------
// ICU
// -------------------------------------------------------------------------

const UChar = u16;
/// ICU's `UErrorCode`: above nought a failure, below it a warning.
const Status = c_int;

const udat_none: c_int = -1;
const udat_short: c_int = 3;
const udat_pattern: c_int = -2;
const ucal_gregorian: c_int = 1;
const ucal_first_day_of_week: c_int = 1;
const ucal_minimal_days: c_int = 2;
const ucal_zone_offset: c_int = 15;
const ucal_dst_offset: c_int = 16;
const capitalization_none: c_int = 1 << 8;
const ulistfmt_units: c_int = 2;

/// The C calls this needs, as ICU names them. The number and list calls came
/// later than the rest, and a system without them still formats dates.
const Icu = struct {
    udat_open: *const fn (c_int, c_int, ?[*:0]const u8, ?[*]const UChar, i32, ?[*]const UChar, i32, *Status) callconv(.c) ?*anyopaque,
    udat_close: *const fn (*anyopaque) callconv(.c) void,
    udat_toPattern: *const fn (*anyopaque, i8, [*]UChar, i32, *Status) callconv(.c) i32,
    udat_getSymbols: *const fn (*anyopaque, c_int, i32, [*]UChar, i32, *Status) callconv(.c) i32,
    udat_format: *const fn (*anyopaque, f64, [*]UChar, i32, ?*anyopaque, *Status) callconv(.c) i32,
    udatpg_open: *const fn ([*:0]const u8, *Status) callconv(.c) ?*anyopaque,
    udatpg_close: *const fn (*anyopaque) callconv(.c) void,
    udatpg_getBestPattern: *const fn (*anyopaque, [*]const UChar, i32, [*]UChar, i32, *Status) callconv(.c) i32,
    ureldatefmt_open: *const fn ([*:0]const u8, ?*anyopaque, c_int, c_int, *Status) callconv(.c) ?*anyopaque,
    ureldatefmt_close: *const fn (*anyopaque) callconv(.c) void,
    ureldatefmt_format: *const fn (*anyopaque, f64, c_int, [*]UChar, i32, *Status) callconv(.c) i32,
    ureldatefmt_formatNumeric: *const fn (*anyopaque, f64, c_int, [*]UChar, i32, *Status) callconv(.c) i32,
    uplrules_open: *const fn ([*:0]const u8, *Status) callconv(.c) ?*anyopaque,
    uplrules_close: *const fn (*anyopaque) callconv(.c) void,
    uplrules_select: *const fn (*anyopaque, f64, [*]UChar, i32, *Status) callconv(.c) i32,
    ucal_open: *const fn (?[*]const UChar, i32, [*:0]const u8, c_int, *Status) callconv(.c) ?*anyopaque,
    ucal_close: *const fn (*anyopaque) callconv(.c) void,
    ucal_getAttribute: *const fn (*anyopaque, c_int) callconv(.c) i32,
    ucal_setMillis: *const fn (*anyopaque, f64, *Status) callconv(.c) void,
    ucal_get: *const fn (*anyopaque, c_int, *Status) callconv(.c) i32,
    ucal_getDefaultTimeZone: *const fn ([*]UChar, i32, *Status) callconv(.c) i32,
    uloc_getDefault: *const fn () callconv(.c) ?[*:0]const u8,
    uloc_forLanguageTag: *const fn ([*:0]const u8, [*]u8, i32, ?*i32, *Status) callconv(.c) i32,
    uloc_toLanguageTag: *const fn ([*:0]const u8, [*]u8, i32, i8, *Status) callconv(.c) i32,
    uloc_getBaseName: *const fn ([*:0]const u8, [*]u8, i32, *Status) callconv(.c) i32,
    unumf_openForSkeletonAndLocale: ?*const fn ([*]const UChar, i32, [*:0]const u8, *Status) callconv(.c) ?*anyopaque = null,
    unumf_close: ?*const fn (*anyopaque) callconv(.c) void = null,
    unumf_openResult: ?*const fn (*Status) callconv(.c) ?*anyopaque = null,
    unumf_closeResult: ?*const fn (*anyopaque) callconv(.c) void = null,
    unumf_formatDouble: ?*const fn (*anyopaque, f64, *anyopaque, *Status) callconv(.c) void = null,
    unumf_resultToString: ?*const fn (*anyopaque, [*]UChar, i32, *Status) callconv(.c) i32 = null,
    ulistfmt_openForType: ?*const fn ([*:0]const u8, c_int, c_int, *Status) callconv(.c) ?*anyopaque = null,
    ulistfmt_close: ?*const fn (*anyopaque) callconv(.c) void = null,
    ulistfmt_format: ?*const fn (*anyopaque, [*]const [*]const UChar, ?[*]const i32, i32, [*]UChar, i32, *Status) callconv(.c) i32 = null,
};

var loaded: ?Icu = null;
var tried = false;
var libraries: [2]?dyn.Library = .{ null, null };
var zone_calendar: ?*anyopaque = null;

/// The system's ICU, loaded the first time it is asked for.
fn icu() ?*const Icu {
    if (!tried) {
        tried = true;
        loaded = load();
    }
    return if (loaded) |*lib| lib else null;
}

fn load() ?Icu {
    if (comptime builtin.os.tag == .windows) {
        // Windows 10 1903 and later keep it beside the rest of the system,
        // with the C names unversioned.
        var lib = dyn.openSystem("icu.dll") catch return null;
        const table = lib.bind(Icu) catch {
            lib.close();
            return null;
        };
        libraries[0] = lib;
        return table;
    }
    if (comptime builtin.os.tag == .linux) {
        if (comptime builtin.abi.isAndroid()) {
            // Android 12 and later give apps the system's ICU by this name,
            // its C names unversioned.
            var lib = dyn.Library.open("libicu.so") catch return null;
            const table = lib.bind(Icu) catch {
                lib.close();
                return null;
            };
            libraries[0] = lib;
            return table;
        }
        return loadVersioned();
    }
    return null;
}

/// A Linux ICU: two libraries named with their major version, and every C
/// name with it too - `udat_open_74` - unless it was built without.
fn loadVersioned() ?Icu {
    var version: u32 = 90;
    while (version >= 50) : (version -= 1) {
        var names: [2][40]u8 = undefined;
        const common = std.fmt.bufPrintZ(&names[0], "libicuuc.so.{d}", .{version}) catch return null;
        const dates = std.fmt.bufPrintZ(&names[1], "libicui18n.so.{d}", .{version}) catch return null;
        var uc = dyn.Library.open(common) catch continue;
        var i18n = dyn.Library.open(dates) catch {
            uc.close();
            continue;
        };
        var suffix_buffer: [8]u8 = undefined;
        const suffixed: Suffixed = .{ .libraries = .{ &uc, &i18n }, .suffix = std.fmt.bufPrint(&suffix_buffer, "_{d}", .{version}) catch "" };
        const plain: Suffixed = .{ .libraries = .{ &uc, &i18n }, .suffix = "" };
        const table = dyn.table.bind(Icu, suffixed) catch dyn.table.bind(Icu, plain) catch {
            uc.close();
            i18n.close();
            return null;
        };
        libraries = .{ uc, i18n };
        return table;
    }
    return null;
}

/// Looks a name up with a version on its end, in either library.
const Suffixed = struct {
    libraries: [2]*dyn.Library,
    suffix: []const u8,

    pub fn get(self: Suffixed, name: [*:0]const u8) ?dyn.Proc {
        var buffer: [96]u8 = undefined;
        const spelled = std.fmt.bufPrintZ(&buffer, "{s}{s}", .{ std.mem.span(name), self.suffix }) catch return null;
        for (self.libraries) |lib| if (lib.get(spelled.ptr)) |found| return found;
        return null;
    }
};

/// One calendar in the system's time zone, for its offsets.
fn zoneCalendar(lib: *const Icu) ?*anyopaque {
    if (zone_calendar == null) {
        var status: Status = 0;
        zone_calendar = lib.ucal_open(null, 0, "en", ucal_gregorian, &status);
        if (status > 0) zone_calendar = null;
    }
    return zone_calendar;
}

fn tagOf(lib: *const Icu, id: [:0]const u8, buf: *[max_tag]u8) ?[]const u8 {
    var status: Status = 0;
    const len = lib.uloc_toLanguageTag(id.ptr, buf, max_tag, 0, &status);
    if (status > 0 or len <= 0) return null;
    return buf[0..@intCast(@min(len, max_tag))];
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "English is there with nothing to ask, and says so" {
    const held = try Culture.openEnglish(testing.allocator);
    defer held.close();
    try testing.expectEqual(Source.fallback, held.source);
    try testing.expectEqualStrings("September", held.monthName(9, .wide, .format));
    try testing.expectEqualStrings("Sun", held.weekdayName(7, .abbreviated, .standalone));
    try testing.expectEqualStrings("MMMM d, y 'at' h:mm a", held.dateTimePattern(.long, .short));
    try testing.expectEqualStrings("M/d/yy, h:mm a", held.dateTimePattern(.short, .short));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("yesterday", englishRelative(&buf, -1, .day, false));
    try testing.expectEqualStrings("in 3 hours", englishRelative(&buf, 3, .hour, false));
    try testing.expectEqualStrings("5 minutes ago", englishRelative(&buf, -5, .minute, true));
    try testing.expectEqualStrings("1 hour", englishAmount(&buf, 1, .hour, .wide));
}

test "a POSIX locale is a tag, and C is English" {
    var buf: [max_tag]u8 = undefined;
    try testing.expectEqualStrings("hu-HU", posixTag("hu_HU.UTF-8", &buf));
    try testing.expectEqualStrings("de-DE", posixTag("de_DE@euro", &buf));
    try testing.expectEqualStrings("en-US", posixTag("C", &buf));
}

test "a twelve-hour clock is told by its h, not by a quoted one" {
    try testing.expect(hasTwelveHours("h:mm a"));
    try testing.expect(!hasTwelveHours("H:mm"));
    try testing.expect(!hasTwelveHours("HH 'h' mm"));
}

test "the person's locale and time zone come from the system" {
    var tag: [max_tag]u8 = undefined;
    const mine = userLocale(&tag);
    try testing.expect(mine.len >= 2);
    // Somewhere on Earth, at any moment.
    const offset = utcOffset(1790358125000);
    try testing.expect(offset >= -14 * 3600 and offset <= 14 * 3600);
}

test "a culture from the system: names, patterns, the week, how long ago, and plurals" {
    if (icu() == null) return error.SkipZigTest;
    const hu = try Culture.open(testing.allocator, "hu-HU");
    defer hu.close();
    try testing.expectEqual(Source.system, hu.source);
    try testing.expectEqualStrings("hu-HU", hu.tag);
    try testing.expectEqualStrings("szeptember", hu.monthName(9, .wide, .format));
    try testing.expectEqualStrings("hétfő", hu.weekdayName(1, .wide, .format));
    try testing.expectEqualStrings("y. MMMM d.", hu.datePattern(.long));
    try testing.expectEqualStrings("H:mm", hu.timePattern(.short));
    try testing.expectEqual(@as(u3, 1), hu.first_weekday);
    try testing.expect(!hu.twelve_hours);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("tegnap", hu.relative(&buf, -1, .day, .wide, false));
    try testing.expectEqualStrings("most", hu.relative(&buf, 0, .second, .wide, false));
    try testing.expectEqualStrings("5 perccel ezelőtt", hu.relative(&buf, -5, .minute, .wide, true));
    try testing.expectEqualStrings("5 óra", hu.amount(&buf, 5, .hour, .wide));
    try testing.expectEqualStrings("MMMM d.", hu.bestPattern(&buf, "MMMMd"));

    const pl = try Culture.open(testing.allocator, "pl-PL");
    defer pl.close();
    try testing.expectEqualStrings("września", pl.monthName(9, .wide, .format));
    try testing.expectEqualStrings("wrzesień", pl.monthName(9, .wide, .standalone));
    try testing.expectEqual(Plural.few, pl.plural(22));
    try testing.expectEqual(Plural.many, pl.plural(25));
    try testing.expectEqual(Plural.one, pl.plural(1));

    const us = try Culture.open(testing.allocator, "en-US");
    defer us.close();
    try testing.expect(us.twelve_hours);
    try testing.expectEqual(@as(u3, 7), us.first_weekday);
    const items = [_][]const u8{ "1 hour", "5 minutes" };
    try testing.expectEqualStrings("1 hour, 5 minutes", us.list(&buf, &items, .wide));
}

test "a tag the system does not know is the nearest it does" {
    if (icu() == null) return error.SkipZigTest;
    const odd = try Culture.open(testing.allocator, "hu-XX");
    defer odd.close();
    try testing.expectEqualStrings("szeptember", odd.monthName(9, .wide, .format));
}
