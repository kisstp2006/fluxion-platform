// SPDX-License-Identifier: BSL-1.0

//! The picture a system puts beside a window's name: in the title bar, in the
//! task bar, in the alt-tab list, on the dock.
//!
//! **Several sizes at once, because a system picks one per place.** Windows
//! wants a small icon for the title bar and a large one for alt-tab, and it
//! scales whatever it is given if the size it wanted is not there - which
//! looks like a blurred icon rather than a missing one. X11 hands every size
//! to the window manager and lets it choose. So `setIcon` takes a list, and a
//! program that has one drawing at 16, 32 and 48 pixels should pass all three.
//!
//! **An empty list puts the system's own back**, which is the executable's
//! icon on Windows and the desktop file's everywhere else.
//!
//! Where a window's icon is not the window's to set, the call says so:
//! `error.Unavailable` on Android, which has no window decoration to put one
//! in, and on a Wayland compositor with no icon protocol, where the picture
//! comes from the desktop file that matches the application id.

const std = @import("std");
const testing = std.testing;

/// One drawing of an icon, at one size.
pub const Image = struct {
    /// Straight RGBA, one byte a channel, row by row from the top left: what a
    /// PNG decodes to. Not premultiplied.
    pixels: []const u8,
    width: u32,
    height: u32,

    /// The longest side worth sending. Windows stops at 256, and a window's
    /// icon is never drawn larger than a dock's.
    pub const max_side: u32 = 256;

    /// Is this an image a system could take: a size within the limit, and the
    /// pixels to fill it?
    pub fn valid(self: Image) bool {
        if (self.width == 0 or self.height == 0) return false;
        if (self.width > max_side or self.height > max_side) return false;
        return self.pixels.len == @as(usize, self.width) * self.height * 4;
    }
};

/// The image in `images` closest to `wanted` pixels across, preferring one
/// that is larger over one that is smaller: scaling down looks better than
/// scaling up.
pub fn best(images: []const Image, wanted: u32) ?Image {
    var found: ?Image = null;
    var found_score: u64 = 0;
    for (images) |image| {
        const score = fit(image.width, wanted);
        if (found == null or score < found_score) {
            found = image;
            found_score = score;
        }
    }
    return found;
}

/// How badly one width fits: the distance, with anything smaller than what was
/// asked for pushed behind everything larger.
fn fit(width: u32, wanted: u32) u64 {
    const short = width < wanted;
    const distance: u64 = if (short) wanted - width else width - wanted;
    return if (short) distance + 1_000_000 else distance;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "an image is checked before a system is handed it" {
    var pixels: [8 * 8 * 4]u8 = @splat(0);
    try testing.expect((Image{ .pixels = &pixels, .width = 8, .height = 8 }).valid());
    try testing.expect(!(Image{ .pixels = &pixels, .width = 8, .height = 9 }).valid());
    try testing.expect(!(Image{ .pixels = &pixels, .width = 0, .height = 8 }).valid());
    try testing.expect(!(Image{ .pixels = &pixels, .width = Image.max_side + 1, .height = 8 }).valid());
}

test "the size a system asks for is the nearest one, and larger beats smaller" {
    var pixels: [64 * 64 * 4]u8 = @splat(0);
    const small: Image = .{ .pixels = pixels[0 .. 16 * 16 * 4], .width = 16, .height = 16 };
    const middle: Image = .{ .pixels = pixels[0 .. 32 * 32 * 4], .width = 32, .height = 32 };
    const large: Image = .{ .pixels = &pixels, .width = 64, .height = 64 };
    const all = [_]Image{ small, middle, large };

    try testing.expectEqual(@as(u32, 16), best(&all, 16).?.width);
    try testing.expectEqual(@as(u32, 32), best(&all, 32).?.width);
    // Nothing is 48, and 64 scaled down beats 32 scaled up.
    try testing.expectEqual(@as(u32, 64), best(&all, 48).?.width);
    // Larger than anything on offer: the largest there is.
    try testing.expectEqual(@as(u32, 64), best(&all, 256).?.width);
    try testing.expectEqual(@as(?Image, null), best(&.{}, 32));
}
