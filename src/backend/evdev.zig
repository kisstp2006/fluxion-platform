// SPDX-License-Identifier: BSL-1.0

//! Where a key is, as the Linux kernel numbers it.
//!
//! Shared by both POSIX backends, and the reason they agree about what `Key.w`
//! means. X11 hands out the same numbers plus eight, because it reserves
//! everything below eight; Wayland hands them out as they are. Neither depends
//! on the layout, which is what `Key` promises and what reading a keysym would
//! throw away.
//!
//! From `input-event-codes.h`. Anything not named here keeps its scancode and
//! arrives as `Key.unknown`, which is a key on somebody's keyboard rather than
//! a mistake.

const std = @import("std");
const testing = std.testing;

const keys = @import("../keys.zig");

/// The key at `code`, or `unknown` for one this table has no name for.
pub fn keyFromEvdev(code: u32) keys.Key {
    return switch (code) {
        1 => .escape,
        2 => .@"1",
        3 => .@"2",
        4 => .@"3",
        5 => .@"4",
        6 => .@"5",
        7 => .@"6",
        8 => .@"7",
        9 => .@"8",
        10 => .@"9",
        11 => .@"0",
        12 => .minus,
        13 => .equal,
        14 => .backspace,
        15 => .tab,
        16 => .q,
        17 => .w,
        18 => .e,
        19 => .r,
        20 => .t,
        21 => .y,
        22 => .u,
        23 => .i,
        24 => .o,
        25 => .p,
        26 => .left_bracket,
        27 => .right_bracket,
        28 => .enter,
        29 => .left_control,
        30 => .a,
        31 => .s,
        32 => .d,
        33 => .f,
        34 => .g,
        35 => .h,
        36 => .j,
        37 => .k,
        38 => .l,
        39 => .semicolon,
        40 => .apostrophe,
        41 => .grave_accent,
        42 => .left_shift,
        43 => .backslash,
        44 => .z,
        45 => .x,
        46 => .c,
        47 => .v,
        48 => .b,
        49 => .n,
        50 => .m,
        51 => .comma,
        52 => .period,
        53 => .slash,
        54 => .right_shift,
        55 => .kp_multiply,
        56 => .left_alt,
        57 => .space,
        58 => .caps_lock,
        59 => .f1,
        60 => .f2,
        61 => .f3,
        62 => .f4,
        63 => .f5,
        64 => .f6,
        65 => .f7,
        66 => .f8,
        67 => .f9,
        68 => .f10,
        69 => .num_lock,
        70 => .scroll_lock,
        71 => .kp_7,
        72 => .kp_8,
        73 => .kp_9,
        74 => .kp_subtract,
        75 => .kp_4,
        76 => .kp_5,
        77 => .kp_6,
        78 => .kp_add,
        79 => .kp_1,
        80 => .kp_2,
        81 => .kp_3,
        82 => .kp_0,
        83 => .kp_decimal,
        // The extra key an ISO keyboard has and an ANSI one does not.
        86 => .world_2,
        87 => .f11,
        88 => .f12,
        96 => .kp_enter,
        97 => .right_control,
        98 => .kp_divide,
        99 => .print_screen,
        100 => .right_alt,
        102 => .home,
        103 => .up,
        104 => .page_up,
        105 => .left,
        106 => .right,
        107 => .end,
        108 => .down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        119 => .pause,
        125 => .left_super,
        126 => .right_super,
        127 => .menu,
        183 => .f13,
        184 => .f14,
        185 => .f15,
        186 => .f16,
        187 => .f17,
        188 => .f18,
        189 => .f19,
        190 => .f20,
        191 => .f21,
        192 => .f22,
        193 => .f23,
        194 => .f24,
        else => .unknown,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the main block is where a US keyboard puts it" {
    try testing.expectEqual(keys.Key.escape, keyFromEvdev(1));
    try testing.expectEqual(keys.Key.w, keyFromEvdev(17));
    try testing.expectEqual(keys.Key.a, keyFromEvdev(30));
    try testing.expectEqual(keys.Key.s, keyFromEvdev(31));
    try testing.expectEqual(keys.Key.d, keyFromEvdev(32));
    try testing.expectEqual(keys.Key.space, keyFromEvdev(57));
}

test "the duplicated keys are separate keys" {
    try testing.expectEqual(keys.Key.enter, keyFromEvdev(28));
    try testing.expectEqual(keys.Key.kp_enter, keyFromEvdev(96));
    try testing.expectEqual(keys.Key.left_control, keyFromEvdev(29));
    try testing.expectEqual(keys.Key.right_control, keyFromEvdev(97));
    try testing.expectEqual(keys.Key.left_shift, keyFromEvdev(42));
    try testing.expectEqual(keys.Key.right_shift, keyFromEvdev(54));
}

test "a code with no name is unknown rather than a wrong key" {
    try testing.expectEqual(keys.Key.unknown, keyFromEvdev(0));
    try testing.expectEqual(keys.Key.unknown, keyFromEvdev(240));
    try testing.expectEqual(keys.Key.unknown, keyFromEvdev(1000));
}

test "no two codes name the same key" {
    // The table is a mapping of positions, so a duplicate would be two physical
    // keys reporting as one - which is exactly the bug a hand-written table
    // invites.
    var seen: [keys.Key.max + 1]bool = @splat(false);
    for (0..256) |code| {
        const key = keyFromEvdev(@intCast(code));
        if (key == .unknown) continue;
        const index = key.index() orelse continue;
        try testing.expect(!seen[index]);
        seen[index] = true;
    }
}
