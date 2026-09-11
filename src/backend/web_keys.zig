// SPDX-License-Identifier: BSL-1.0

//! Where a key is, as a browser names it.
//!
//! **`KeyboardEvent.code` is exactly what `Key` means.** The DOM has two ways
//! to say which key moved: `key`, which is what it types on this layout, and
//! `code`, which is where it is - `"KeyA"` is the key left of `S` whether it
//! types `a`, `q` or `ф`. That is the promise `Key` makes on every other
//! backend, so this is a table from one to the other and nothing more: no
//! layout is consulted, and none needs to be.
//!
//! **The scancode is the key's USB usage.** A browser has no scancode of its
//! own to report - `keyCode` is deprecated and follows the layout, which is
//! the opposite of a scancode - but every `code` value is defined as the name
//! of one USB HID usage, and that number is what this backend hands out:
//! `KeyA` is `0x070004`, page 7 usage 4. It is stable across browsers and
//! machines, which is more than a Win32 scancode is, and a key this table has
//! no name for still has one, so two such keys stay apart.
//!
//! A `code` that is not in the table at all - a key some future keyboard has -
//! gets a hash of its name instead, with the top bit set. A USB usage fits in
//! 24 bits, so the two can never collide.
//!
//! Anything not named here is `Key.unknown`, which is a key on somebody's
//! keyboard rather than a mistake.

const std = @import("std");
const testing = std.testing;

const keys = @import("../keys.zig");

/// What a `code` turned into.
pub const Found = struct {
    key: keys.Key,
    scancode: keys.Scancode,
};

/// One row: the DOM's name, this library's key, and the USB usage as page and
/// id together - `0x07_0004` is page 7, usage 4.
const Row = struct { []const u8, keys.Key, u32 };

/// Every `code` a browser sends, from the W3C's "UI Events KeyboardEvent code
/// Values" and the USB HID usage tables that define them.
const rows = [_]Row{
    // The writing block, where a US keyboard puts it.
    .{ "KeyA", .a, 0x070004 },
    .{ "KeyB", .b, 0x070005 },
    .{ "KeyC", .c, 0x070006 },
    .{ "KeyD", .d, 0x070007 },
    .{ "KeyE", .e, 0x070008 },
    .{ "KeyF", .f, 0x070009 },
    .{ "KeyG", .g, 0x07000A },
    .{ "KeyH", .h, 0x07000B },
    .{ "KeyI", .i, 0x07000C },
    .{ "KeyJ", .j, 0x07000D },
    .{ "KeyK", .k, 0x07000E },
    .{ "KeyL", .l, 0x07000F },
    .{ "KeyM", .m, 0x070010 },
    .{ "KeyN", .n, 0x070011 },
    .{ "KeyO", .o, 0x070012 },
    .{ "KeyP", .p, 0x070013 },
    .{ "KeyQ", .q, 0x070014 },
    .{ "KeyR", .r, 0x070015 },
    .{ "KeyS", .s, 0x070016 },
    .{ "KeyT", .t, 0x070017 },
    .{ "KeyU", .u, 0x070018 },
    .{ "KeyV", .v, 0x070019 },
    .{ "KeyW", .w, 0x07001A },
    .{ "KeyX", .x, 0x07001B },
    .{ "KeyY", .y, 0x07001C },
    .{ "KeyZ", .z, 0x07001D },

    .{ "Digit1", .@"1", 0x07001E },
    .{ "Digit2", .@"2", 0x07001F },
    .{ "Digit3", .@"3", 0x070020 },
    .{ "Digit4", .@"4", 0x070021 },
    .{ "Digit5", .@"5", 0x070022 },
    .{ "Digit6", .@"6", 0x070023 },
    .{ "Digit7", .@"7", 0x070024 },
    .{ "Digit8", .@"8", 0x070025 },
    .{ "Digit9", .@"9", 0x070026 },
    .{ "Digit0", .@"0", 0x070027 },

    .{ "Enter", .enter, 0x070028 },
    .{ "Escape", .escape, 0x070029 },
    .{ "Backspace", .backspace, 0x07002A },
    .{ "Tab", .tab, 0x07002B },
    .{ "Space", .space, 0x07002C },
    .{ "Minus", .minus, 0x07002D },
    .{ "Equal", .equal, 0x07002E },
    .{ "BracketLeft", .left_bracket, 0x07002F },
    .{ "BracketRight", .right_bracket, 0x070030 },
    // Also the `#~` key beside Enter on an ISO keyboard: the DOM gives both
    // the one name, because both are the key a US layout puts `\` on.
    .{ "Backslash", .backslash, 0x070031 },
    .{ "Semicolon", .semicolon, 0x070033 },
    .{ "Quote", .apostrophe, 0x070034 },
    .{ "Backquote", .grave_accent, 0x070035 },
    .{ "Comma", .comma, 0x070036 },
    .{ "Period", .period, 0x070037 },
    .{ "Slash", .slash, 0x070038 },
    .{ "CapsLock", .caps_lock, 0x070039 },
    // The extra key an ISO keyboard has between left shift and `Z`, which
    // the evdev and Win32 tables call `world_2` as well.
    .{ "IntlBackslash", .world_2, 0x070064 },

    .{ "F1", .f1, 0x07003A },
    .{ "F2", .f2, 0x07003B },
    .{ "F3", .f3, 0x07003C },
    .{ "F4", .f4, 0x07003D },
    .{ "F5", .f5, 0x07003E },
    .{ "F6", .f6, 0x07003F },
    .{ "F7", .f7, 0x070040 },
    .{ "F8", .f8, 0x070041 },
    .{ "F9", .f9, 0x070042 },
    .{ "F10", .f10, 0x070043 },
    .{ "F11", .f11, 0x070044 },
    .{ "F12", .f12, 0x070045 },
    .{ "F13", .f13, 0x070068 },
    .{ "F14", .f14, 0x070069 },
    .{ "F15", .f15, 0x07006A },
    .{ "F16", .f16, 0x07006B },
    .{ "F17", .f17, 0x07006C },
    .{ "F18", .f18, 0x07006D },
    .{ "F19", .f19, 0x07006E },
    .{ "F20", .f20, 0x07006F },
    .{ "F21", .f21, 0x070070 },
    .{ "F22", .f22, 0x070071 },
    .{ "F23", .f23, 0x070072 },
    .{ "F24", .f24, 0x070073 },

    .{ "PrintScreen", .print_screen, 0x070046 },
    .{ "ScrollLock", .scroll_lock, 0x070047 },
    .{ "Pause", .pause, 0x070048 },
    .{ "Insert", .insert, 0x070049 },
    .{ "Home", .home, 0x07004A },
    .{ "PageUp", .page_up, 0x07004B },
    .{ "Delete", .delete, 0x07004C },
    .{ "End", .end, 0x07004D },
    .{ "PageDown", .page_down, 0x07004E },
    .{ "ArrowRight", .right, 0x07004F },
    .{ "ArrowLeft", .left, 0x070050 },
    .{ "ArrowDown", .down, 0x070051 },
    .{ "ArrowUp", .up, 0x070052 },

    .{ "NumLock", .num_lock, 0x070053 },
    .{ "NumpadDivide", .kp_divide, 0x070054 },
    .{ "NumpadMultiply", .kp_multiply, 0x070055 },
    .{ "NumpadSubtract", .kp_subtract, 0x070056 },
    .{ "NumpadAdd", .kp_add, 0x070057 },
    .{ "NumpadEnter", .kp_enter, 0x070058 },
    .{ "Numpad1", .kp_1, 0x070059 },
    .{ "Numpad2", .kp_2, 0x07005A },
    .{ "Numpad3", .kp_3, 0x07005B },
    .{ "Numpad4", .kp_4, 0x07005C },
    .{ "Numpad5", .kp_5, 0x07005D },
    .{ "Numpad6", .kp_6, 0x07005E },
    .{ "Numpad7", .kp_7, 0x07005F },
    .{ "Numpad8", .kp_8, 0x070060 },
    .{ "Numpad9", .kp_9, 0x070061 },
    .{ "Numpad0", .kp_0, 0x070062 },
    .{ "NumpadDecimal", .kp_decimal, 0x070063 },
    .{ "NumpadEqual", .kp_equal, 0x070067 },

    .{ "ContextMenu", .menu, 0x070065 },

    .{ "ControlLeft", .left_control, 0x0700E0 },
    .{ "ShiftLeft", .left_shift, 0x0700E1 },
    .{ "AltLeft", .left_alt, 0x0700E2 },
    .{ "MetaLeft", .left_super, 0x0700E3 },
    .{ "ControlRight", .right_control, 0x0700E4 },
    .{ "ShiftRight", .right_shift, 0x0700E5 },
    .{ "AltRight", .right_alt, 0x0700E6 },
    .{ "MetaRight", .right_super, 0x0700E7 },
    // Firefox before 118 named the two logo keys after the operating system.
    // The same keys, so the same usages.
    .{ "OSLeft", .left_super, 0x0700E3 },
    .{ "OSRight", .right_super, 0x0700E7 },

    // Keys the DOM names and `Key` does not. `unknown`, as on every other
    // backend, but each keeps its own usage - so a binding to the volume
    // rocker is still a binding to the volume rocker.
    .{ "Power", .unknown, 0x070066 },
    .{ "Open", .unknown, 0x070074 },
    .{ "Help", .unknown, 0x070075 },
    .{ "Select", .unknown, 0x070077 },
    .{ "Again", .unknown, 0x070079 },
    .{ "Undo", .unknown, 0x07007A },
    .{ "Cut", .unknown, 0x07007B },
    .{ "Copy", .unknown, 0x07007C },
    .{ "Paste", .unknown, 0x07007D },
    .{ "Find", .unknown, 0x07007E },
    .{ "AudioVolumeMute", .unknown, 0x07007F },
    .{ "AudioVolumeUp", .unknown, 0x070080 },
    .{ "AudioVolumeDown", .unknown, 0x070081 },
    .{ "NumpadComma", .unknown, 0x070085 },
    .{ "IntlRo", .unknown, 0x070087 },
    .{ "KanaMode", .unknown, 0x070088 },
    .{ "IntlYen", .unknown, 0x070089 },
    .{ "Convert", .unknown, 0x07008A },
    .{ "NonConvert", .unknown, 0x07008B },
    .{ "Lang1", .unknown, 0x070090 },
    .{ "Lang2", .unknown, 0x070091 },
    .{ "Lang3", .unknown, 0x070092 },
    .{ "Lang4", .unknown, 0x070093 },
    .{ "Lang5", .unknown, 0x070094 },
    .{ "NumpadParenLeft", .unknown, 0x0700B6 },
    .{ "NumpadParenRight", .unknown, 0x0700B7 },

    // The generic desktop page.
    .{ "Sleep", .unknown, 0x010082 },
    .{ "WakeUp", .unknown, 0x010083 },

    // The consumer page: media and browser keys.
    .{ "MediaTrackNext", .unknown, 0x0C00B5 },
    .{ "MediaTrackPrevious", .unknown, 0x0C00B6 },
    .{ "MediaStop", .unknown, 0x0C00B7 },
    .{ "Eject", .unknown, 0x0C00B8 },
    .{ "MediaPlayPause", .unknown, 0x0C00CD },
    .{ "MediaSelect", .unknown, 0x0C0183 },
    .{ "LaunchMediaPlayer", .unknown, 0x0C0183 },
    .{ "LaunchMail", .unknown, 0x0C018A },
    .{ "LaunchApp2", .unknown, 0x0C0192 },
    .{ "LaunchApp1", .unknown, 0x0C0194 },
    .{ "BrowserSearch", .unknown, 0x0C0221 },
    .{ "BrowserHome", .unknown, 0x0C0223 },
    .{ "BrowserBack", .unknown, 0x0C0224 },
    .{ "BrowserForward", .unknown, 0x0C0225 },
    .{ "BrowserStop", .unknown, 0x0C0226 },
    .{ "BrowserRefresh", .unknown, 0x0C0227 },
    .{ "BrowserFavorites", .unknown, 0x0C022A },
};

const map = map: {
    var list: [rows.len]struct { []const u8, Found } = undefined;
    for (rows, &list) |row, *entry| {
        entry.* = .{ row[0], .{ .key = row[1], .scancode = @enumFromInt(row[2]) } };
    }
    break :map std.StaticStringMap(Found).initComptime(list);
};

/// The key a `code` names, and its scancode.
///
/// An empty `code` - which is what a soft keyboard sends, having no positions
/// to report - is `unknown` with a scancode of zero. The glue sends the key's
/// *name* instead where it has one worth sending (`"Enter"`, `"Backspace"`,
/// the arrows), and those names are the same strings as the codes, so they
/// come through this table unchanged.
pub fn fromCode(code: []const u8) Found {
    if (code.len == 0) return .{ .key = .unknown, .scancode = @enumFromInt(0) };
    if (map.get(code)) |found| return found;
    return .{ .key = .unknown, .scancode = @enumFromInt(hashed(code)) };
}

/// A number for a `code` the table has never heard of: FNV-1a over the name,
/// with the top bit set so it can never be mistaken for a USB usage.
fn hashed(code: []const u8) u32 {
    var hash: u32 = 0x811C9DC5;
    for (code) |byte| {
        hash ^= byte;
        hash *%= 0x01000193;
    }
    return hash | 0x8000_0000;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a code is a position, not a letter" {
    // WASD, where a US keyboard has them - and where an AZERTY one has ZQSD,
    // which is the point: the browser reports `KeyW` for the key a French
    // keyboard prints Z on, and so does this.
    try testing.expectEqual(keys.Key.w, fromCode("KeyW").key);
    try testing.expectEqual(keys.Key.a, fromCode("KeyA").key);
    try testing.expectEqual(keys.Key.s, fromCode("KeyS").key);
    try testing.expectEqual(keys.Key.d, fromCode("KeyD").key);

    try testing.expectEqual(keys.Key.@"1", fromCode("Digit1").key);
    try testing.expectEqual(keys.Key.@"0", fromCode("Digit0").key);
    try testing.expectEqual(keys.Key.space, fromCode("Space").key);
    try testing.expectEqual(keys.Key.apostrophe, fromCode("Quote").key);
    try testing.expectEqual(keys.Key.grave_accent, fromCode("Backquote").key);
}

test "the scancode is the USB usage" {
    try testing.expectEqual(@as(u32, 0x070004), @intFromEnum(fromCode("KeyA").scancode));
    try testing.expectEqual(@as(u32, 0x070029), @intFromEnum(fromCode("Escape").scancode));
    try testing.expectEqual(@as(u32, 0x0700E0), @intFromEnum(fromCode("ControlLeft").scancode));
    try testing.expectEqual(@as(u32, 0x0C00CD), @intFromEnum(fromCode("MediaPlayPause").scancode));
}

test "the duplicated keys are separate keys" {
    try testing.expectEqual(keys.Key.enter, fromCode("Enter").key);
    try testing.expectEqual(keys.Key.kp_enter, fromCode("NumpadEnter").key);
    try testing.expectEqual(keys.Key.left_shift, fromCode("ShiftLeft").key);
    try testing.expectEqual(keys.Key.right_shift, fromCode("ShiftRight").key);
    try testing.expectEqual(keys.Key.left_control, fromCode("ControlLeft").key);
    try testing.expectEqual(keys.Key.right_control, fromCode("ControlRight").key);
}

test "the old Firefox names are the same keys as the new ones" {
    try testing.expectEqual(fromCode("MetaLeft"), fromCode("OSLeft"));
    try testing.expectEqual(fromCode("MetaRight"), fromCode("OSRight"));
}

test "a named key with no Key keeps a scancode of its own" {
    const mute = fromCode("AudioVolumeMute");
    const back = fromCode("BrowserBack");
    try testing.expectEqual(keys.Key.unknown, mute.key);
    try testing.expectEqual(keys.Key.unknown, back.key);
    // Both unknown, and still two different keys.
    try testing.expect(mute.scancode != back.scancode);
}

test "a code nobody has heard of is unknown, and still distinct" {
    const one = fromCode("LaunchApplication9");
    const two = fromCode("SomeFutureKey");
    try testing.expectEqual(keys.Key.unknown, one.key);
    try testing.expect(one.scancode != two.scancode);
    // Never a USB usage, which fits in 24 bits.
    try testing.expect(@intFromEnum(one.scancode) & 0x8000_0000 != 0);
    // And the same name twice is the same number twice, or a binding the
    // user made would not survive the next key press.
    try testing.expectEqual(one.scancode, fromCode("LaunchApplication9").scancode);
}

test "no code at all is unknown with no scancode" {
    const nothing = fromCode("");
    try testing.expectEqual(keys.Key.unknown, nothing.key);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(nothing.scancode));
}

test "the key names a soft keyboard sends come through the same table" {
    // With no `code`, the glue sends `key` for these - and for exactly these
    // the two are spelled the same.
    for ([_][]const u8{ "Enter", "Backspace", "Tab", "Escape", "Delete", "ArrowLeft", "Home", "F5" }) |name| {
        try testing.expect(fromCode(name).key != .unknown);
    }
}

test "no two codes name the same key, apart from the two renamed ones" {
    var seen: [keys.Key.max + 1]bool = @splat(false);
    for (rows) |row| {
        if (row[1] == .unknown) continue;
        if (std.mem.startsWith(u8, row[0], "OS")) continue;
        const index = row[1].index() orelse continue;
        try testing.expect(!seen[index]);
        seen[index] = true;
    }
}

test "every key the library names is reachable from some code" {
    // Two are not, and neither is an omission: no DOM code is `world_1` on any
    // layout, and the DOM stops at F24.
    inline for (@typeInfo(keys.Key).@"enum".fields) |field| {
        const key: keys.Key = @enumFromInt(field.value);
        if (key == .unknown or key == .world_1 or key == .f25) continue;

        var found = false;
        for (rows) |row| {
            if (row[1] == key) found = true;
        }
        if (!found) std.debug.print("no code reaches Key.{s}\n", .{field.name});
        try testing.expect(found);
    }
}
