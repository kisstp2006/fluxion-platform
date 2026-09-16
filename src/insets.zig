// SPDX-License-Identifier: BSL-1.0

//! The edges of a window the system draws over, and a program should not.
//!
//! A phone's screen is not all usable: a notch or a camera hole eats into the
//! top, the gesture bar sits along the bottom, and a rounded corner cuts the
//! ends off both. The window is still the whole screen and drawing still fills
//! it - a background should reach the corners - but anything the user has to
//! read or press belongs inside these four edges.
//!
//! **In the framebuffer's pixels**, like every other position this library
//! reports, so a layout written against `framebufferSize` can subtract them
//! without converting anything.
//!
//! **They change while the program runs**: a rotation moves the notch to the
//! side, and a phone hides the gesture bar in fullscreen. A `.safe_area` event
//! says so, and `Window.safeArea` is the same numbers whenever they are asked
//! for. Every desktop answers zero on all four, which is the truth: a window
//! there is drawn over by nothing.

const std = @import("std");
const testing = std.testing;

/// How far in from each edge the usable part of a window starts.
pub const Insets = struct {
    left: u32 = 0,
    top: u32 = 0,
    right: u32 = 0,
    bottom: u32 = 0,

    /// Is the whole window usable? True on every desktop.
    pub fn isEmpty(self: Insets) bool {
        return self.left == 0 and self.top == 0 and self.right == 0 and self.bottom == 0;
    }

    /// The four edges in one word, sixteen bits each, in the order they are
    /// written here.
    ///
    /// For a backend whose numbers arrive on another thread - Android's, from
    /// the layout - so that what the program reads is one set of edges rather
    /// than halves of two. Sixteen bits is a screen wider than any there is.
    pub fn pack(self: Insets) u64 {
        return @as(u64, cut(self.left)) |
            @as(u64, cut(self.top)) << 16 |
            @as(u64, cut(self.right)) << 32 |
            @as(u64, cut(self.bottom)) << 48;
    }

    pub fn unpack(word: u64) Insets {
        return .{
            .left = @as(u16, @truncate(word)),
            .top = @as(u16, @truncate(word >> 16)),
            .right = @as(u16, @truncate(word >> 32)),
            .bottom = @as(u16, @truncate(word >> 48)),
        };
    }

    fn cut(edge: u32) u16 {
        return @truncate(@min(edge, std.math.maxInt(u16)));
    }

    /// What is left of a framebuffer of `size` once the edges are taken off:
    /// x, y, width and height, in the same pixels. Nothing smaller than
    /// nothing, for a window narrower than its own insets.
    pub fn within(self: Insets, size: [2]u32) [4]u32 {
        const width = size[0] -| self.left -| self.right;
        const height = size[1] -| self.top -| self.bottom;
        return .{ @min(self.left, size[0]), @min(self.top, size[1]), width, height };
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a window with nothing over it is empty, and one with a notch is not" {
    try testing.expect((Insets{}).isEmpty());
    try testing.expect(!(Insets{ .top = 96 }).isEmpty());
}

test "four edges make one word, and come back out of it" {
    const phone: Insets = .{ .left = 0, .top = 136, .right = 0, .bottom = 63 };
    try testing.expectEqual(phone, Insets.unpack(phone.pack()));

    const turned: Insets = .{ .left = 136, .top = 0, .right = 0, .bottom = 63 };
    try testing.expectEqual(turned, Insets.unpack(turned.pack()));

    // Each edge is its own sixteen bits, and none of them reads another's.
    try testing.expectEqual(@as(u64, 136 << 16), phone.pack() & 0xFFFF_0000);
    try testing.expectEqual(Insets{}, Insets.unpack(0));
}

test "the usable part is the framebuffer less the edges, and never negative" {
    const phone: Insets = .{ .top = 96, .bottom = 48 };
    try testing.expectEqual([4]u32{ 0, 96, 1080, 2400 - 144 }, phone.within(.{ 1080, 2400 }));

    const sideways: Insets = .{ .left = 96, .right = 48 };
    try testing.expectEqual([4]u32{ 96, 0, 2400 - 144, 1080 }, sideways.within(.{ 2400, 1080 }));

    // A window smaller than its own insets leaves nothing, rather than wrapping.
    const huge: Insets = .{ .left = 500, .right = 500, .top = 500, .bottom = 500 };
    try testing.expectEqual([4]u32{ 100, 100, 0, 0 }, huge.within(.{ 100, 100 }));
}
