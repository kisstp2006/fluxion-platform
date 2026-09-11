// SPDX-License-Identifier: BSL-1.0

//! What a key is, what a button is, and what was held down at the time.
//!
//! A `Key` names a physical key by where it sits on a US layout, not by what it
//! types. `Key.a` is the key left of `s` whatever the keyboard is set to, which
//! is what WASD wants; the letter the user actually typed arrives separately, as
//! a `.char` event, already through the layout and any dead keys.
//!
//! The same names serve the virtual key a key event carries beside the
//! physical one: `KeyEvent.virtual` is `.z` for the key the layout in use has
//! put Z on, wherever that is, which is what a shortcut wants.
//!
//! The numbers match GLFW's, so a port is a change of spelling. `Key` is
//! non-exhaustive: a key this library has no name for keeps its value rather
//! than being flattened to one `unknown`, and `Key.named` says which it was.
//!
//! A `Scancode` is the platform's own number for the same key. It is not
//! portable and not stable between machines, and the one thing it is good for
//! is remembering a binding the user set: two keys that produce `Key.unknown`
//! still have different scancodes.

const std = @import("std");
const testing = std.testing;

/// A physical key, at its position on a US layout.
///
/// Values below 256 are the ASCII character that key types unshifted, which is
/// why `Key.a` is 65 and not 0.
pub const Key = enum(i32) {
    unknown = -1,

    space = 32,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,

    @"0" = 48,
    @"1" = 49,
    @"2" = 50,
    @"3" = 51,
    @"4" = 52,
    @"5" = 53,
    @"6" = 54,
    @"7" = 55,
    @"8" = 56,
    @"9" = 57,

    semicolon = 59,
    equal = 61,

    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,

    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave_accent = 96,

    /// The two extra keys a non-US layout can have where a US one has none.
    world_1 = 161,
    world_2 = 162,

    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    page_up = 266,
    page_down = 267,
    home = 268,
    end = 269,

    caps_lock = 280,
    scroll_lock = 281,
    num_lock = 282,
    print_screen = 283,
    pause = 284,

    f1 = 290,
    f2 = 291,
    f3 = 292,
    f4 = 293,
    f5 = 294,
    f6 = 295,
    f7 = 296,
    f8 = 297,
    f9 = 298,
    f10 = 299,
    f11 = 300,
    f12 = 301,
    f13 = 302,
    f14 = 303,
    f15 = 304,
    f16 = 305,
    f17 = 306,
    f18 = 307,
    f19 = 308,
    f20 = 309,
    f21 = 310,
    f22 = 311,
    f23 = 312,
    f24 = 313,
    f25 = 314,

    kp_0 = 320,
    kp_1 = 321,
    kp_2 = 322,
    kp_3 = 323,
    kp_4 = 324,
    kp_5 = 325,
    kp_6 = 326,
    kp_7 = 327,
    kp_8 = 328,
    kp_9 = 329,
    kp_decimal = 330,
    kp_divide = 331,
    kp_multiply = 332,
    kp_subtract = 333,
    kp_add = 334,
    kp_enter = 335,
    kp_equal = 336,

    left_shift = 340,
    left_control = 341,
    left_alt = 342,
    left_super = 343,
    right_shift = 344,
    right_control = 345,
    right_alt = 346,
    right_super = 347,
    menu = 348,

    _,

    /// The highest value this library ever hands out, for sizing a key-state
    /// array. `unknown` is negative and belongs in no such array.
    pub const max: usize = 348;

    /// Does this library have a name for the key? A `false` here is not an
    /// error - it is a key on somebody's keyboard that no layout this library
    /// knows puts a name to, and its `Scancode` still identifies it.
    pub fn named(self: Key) bool {
        return switch (self) {
            _ => false,
            else => true,
        };
    }

    /// Where this key sits in a `[Key.max + 1]bool`, or null for `unknown` and
    /// anything outside the range.
    pub fn index(self: Key) ?usize {
        const value = @intFromEnum(self);
        if (value < 0 or value > max) return null;
        return @intCast(value);
    }

    pub fn format(self: Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            _ => try w.print("Key({d})", .{@intFromEnum(self)}),
            else => try w.writeAll(@tagName(self)),
        }
    }
};

/// The platform's own number for a physical key.
///
/// Opaque on purpose: it means nothing across machines and nothing across
/// platforms. Store it to remember a binding, compare it to another scancode,
/// and do not write it into a save file that another machine will read.
pub const Scancode = enum(u32) {
    _,

    pub fn format(self: Scancode, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("scancode({d})", .{@intFromEnum(self)});
    }
};

/// A mouse button. The first three have names because every mouse has them.
pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
    button_4 = 3,
    button_5 = 4,
    button_6 = 5,
    button_7 = 6,
    button_8 = 7,
    _,

    pub const max: usize = 7;

    pub fn index(self: MouseButton) ?usize {
        const value = @intFromEnum(self);
        if (value > max) return null;
        return value;
    }
};

/// What happened to a key or a button.
///
/// `repeat` is the system's auto-repeat, which fires while a key is held. A
/// program that counts presses wants `press` alone; one that moves a text
/// cursor wants both.
pub const Action = enum {
    release,
    press,
    repeat,

    /// Is the key down after this? True for both `press` and `repeat`.
    pub fn down(self: Action) bool {
        return self != .release;
    }
};

/// What was held down when the event happened.
///
/// The lock bits are the state of the lock, not of its key: `caps_lock` is set
/// while capitals are on, whether or not the key is being pressed.
pub const Mods = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    /// Windows key, Command, Meta - the platform's own modifier.
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u2 = 0,

    pub const none: Mods = .{};

    /// Are any of `wanted` missing from these? For "is this exactly ctrl+S",
    /// compare the whole struct instead.
    pub fn has(self: Mods, wanted: Mods) bool {
        const bits: u8 = @bitCast(self);
        const mask: u8 = @bitCast(wanted);
        return bits & mask == mask;
    }

    pub fn format(self: Mods, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        inline for (@typeInfo(Mods).@"struct".fields) |field| {
            if (field.type != bool) continue;
            if (@field(self, field.name)) {
                if (!first) try w.writeAll("+");
                try w.writeAll(field.name);
                first = false;
            }
        }
        if (first) try w.writeAll("none");
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the numbers are GLFW's, so a port is a change of spelling" {
    try testing.expectEqual(@as(i32, 32), @intFromEnum(Key.space));
    try testing.expectEqual(@as(i32, 65), @intFromEnum(Key.a));
    try testing.expectEqual(@as(i32, 256), @intFromEnum(Key.escape));
    try testing.expectEqual(@as(i32, 290), @intFromEnum(Key.f1));
    try testing.expectEqual(@as(i32, 340), @intFromEnum(Key.left_shift));
    try testing.expectEqual(@as(i32, -1), @intFromEnum(Key.unknown));
}

test "a key with no name keeps its value" {
    const odd: Key = @enumFromInt(200);
    try testing.expect(!odd.named());
    try testing.expect(Key.a.named());
    // And it is still a distinct key, not flattened into `unknown`.
    try testing.expect(odd != Key.unknown);
    try testing.expectEqual(@as(?usize, 200), odd.index());
}

test "indices stay inside an array sized by max" {
    var pressed: [Key.max + 1]bool = @splat(false);
    pressed[Key.menu.index().?] = true;
    try testing.expect(pressed[348]);

    // `unknown` belongs in no array, and neither does anything past the end.
    try testing.expectEqual(@as(?usize, null), Key.unknown.index());
    const far: Key = @enumFromInt(9000);
    try testing.expectEqual(@as(?usize, null), far.index());
}

test "an action says whether the key is down" {
    try testing.expect(Action.press.down());
    try testing.expect(Action.repeat.down());
    try testing.expect(!Action.release.down());
}

test "modifiers are one byte, and `has` asks about a subset" {
    const ctrl_shift: Mods = .{ .control = true, .shift = true };
    try testing.expect(ctrl_shift.has(.{ .control = true }));
    try testing.expect(ctrl_shift.has(.{ .control = true, .shift = true }));
    try testing.expect(!ctrl_shift.has(.{ .alt = true }));
    // Nothing wanted is always satisfied.
    try testing.expect(ctrl_shift.has(.none));

    try testing.expectEqual(@as(usize, 1), @sizeOf(Mods));
}

test "modifiers print as a chord" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "shift+control",
        try std.fmt.bufPrint(&buf, "{f}", .{Mods{ .shift = true, .control = true }}),
    );
    try testing.expectEqualStrings(
        "none",
        try std.fmt.bufPrint(&buf, "{f}", .{Mods.none}),
    );
}

test "a key prints as its name, or as its number when it has none" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("escape", try std.fmt.bufPrint(&buf, "{f}", .{Key.escape}));
    try testing.expectEqualStrings(
        "Key(200)",
        try std.fmt.bufPrint(&buf, "{f}", .{@as(Key, @enumFromInt(200))}),
    );
}

test "mouse buttons index an array too" {
    var down: [MouseButton.max + 1]bool = @splat(false);
    down[MouseButton.middle.index().?] = true;
    try testing.expect(down[2]);
    const far: MouseButton = @enumFromInt(200);
    try testing.expectEqual(@as(?usize, null), far.index());
}
