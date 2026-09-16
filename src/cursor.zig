// SPDX-License-Identifier: BSL-1.0

//! What the pointer looks like, and where it is allowed to go.
//!
//! Five modes, and the difference between them is the difference between a
//! program that has a cursor and a game that has a camera:
//!
//!   `normal`           the ordinary arrow, free to leave the window
//!   `hidden`           invisible over the window, and still free to leave
//!   `captured`         visible, but confined to the content area
//!   `confined_hidden`  confined and invisible, and still has a position
//!   `disabled`         invisible, confined, and reporting motion with no edges
//!
//! **`disabled` is the one a first-person camera needs**, and it is not just
//! `hidden` plus `captured` - that pair is `confined_hidden`, the one to draw
//! a pointer of your own with. A confined cursor stops at the edge of the
//! window, so a fast turn runs out of screen and the camera stops with it. In
//! `disabled` the pointer is taken out of the picture entirely: `.cursor`
//! events carry `dx` and `dy` that keep going in whichever direction the mouse
//! moved, however far, and `x` and `y` stop meaning anything at all.
//!
//! **Raw motion is the other half of that.** The numbers a system reports for
//! an ordinary cursor have been through pointer acceleration - a curve meant to
//! make a cursor land on a button - which is exactly wrong for aiming. With
//! `raw_motion` on, the deltas are what the device reported and nothing else.
//! It only means anything in `disabled` mode, because there is no cursor left
//! to accelerate.

const std = @import("std");
const testing = std.testing;

/// Where the pointer may go, and whether it can be seen.
pub const Mode = enum {
    /// Visible, and free to leave the window. What a window starts as.
    normal,
    /// Invisible over the content area, and otherwise unchanged - it still
    /// leaves the window, and it still has a position. For a program that
    /// draws its own cursor.
    hidden,
    /// Visible, and held inside the content area. For a strategy game that
    /// scrolls at the screen edge, where the cursor should stay put but still
    /// be seen.
    captured,
    /// Invisible, held, and reporting motion without limit. The one a
    /// first-person camera needs, and the only mode where `raw_motion` does
    /// anything.
    disabled,
    /// Invisible and held, with positions that still mean something: a
    /// `.cursor` event's `x` and `y` are where the pointer is, and it stops at
    /// the edges rather than turning forever. For a strategy game that draws
    /// its own pointer and scrolls at the screen edge.
    confined_hidden,

    /// Is the pointer confined to the window in this mode?
    pub fn confines(self: Mode) bool {
        return switch (self) {
            .captured, .disabled, .confined_hidden => true,
            .normal, .hidden => false,
        };
    }

    /// Is it invisible in this mode?
    pub fn hides(self: Mode) bool {
        return switch (self) {
            .hidden, .disabled, .confined_hidden => true,
            .normal, .captured => false,
        };
    }
};

/// One of the shapes every desktop already has.
///
/// A named shape rather than an image, because the system's own is the one that
/// matches the theme, the size and the display's scale - and a program that
/// ships its own arrow gets all three wrong on somebody's machine.
pub const Shape = enum {
    /// The ordinary pointer. What a window starts with.
    arrow,
    /// The text caret, for anything editable.
    ibeam,
    /// Precise selection.
    crosshair,
    /// The hand, for a link or a button.
    pointing_hand,
    /// Horizontal resize, as on a left or right edge.
    resize_ew,
    /// Vertical resize.
    resize_ns,
    /// The diagonal from top left to bottom right.
    resize_nwse,
    /// The other diagonal.
    resize_nesw,
    /// Move, or resize in every direction at once.
    resize_all,
    /// The circle-and-bar: this is not somewhere the thing can be dropped.
    not_allowed,
    /// The hourglass: the program is busy and will not answer.
    wait,
    /// The arrow with an hourglass beside it: working, but still usable.
    busy,
    /// The question mark, for a control that explains itself when clicked.
    help,
    /// Something is being dragged: the closed hand.
    drag,
    /// And here it can be dropped.
    can_drop,
    /// The handle between two rows, dragged up and down.
    vsplit,
    /// The handle between two columns, dragged left and right.
    hsplit,

    /// Shapes a system may not have, where `arrow` is what to draw instead.
    /// Every platform has the rest.
    pub fn optional(self: Shape) bool {
        return switch (self) {
            .resize_nwse, .resize_nesw, .not_allowed, .can_drop => true,
            else => false,
        };
    }
};

/// An image to draw as the pointer, and the point in it that does the pointing.
///
/// A named `Shape` is still the better answer where one fits: the system's own
/// cursor is the one that matches the theme, the size and the display's scale.
/// This is for the pointer a program has to draw itself - a paint tool's brush,
/// an editor's drag - and it is Godot's `set_custom_mouse_cursor` in one call
/// rather than one per shape: an image replaces this window's pointer until
/// null puts the shape back.
pub const Image = struct {
    /// Straight RGBA, one byte a channel, row by row from the top left: what a
    /// PNG decodes to. Not premultiplied - the backends that want it that way
    /// multiply it themselves.
    pixels: []const u8,
    width: u32,
    height: u32,
    /// Which pixel of the image the pointer actually points with: the tip of an
    /// arrow, the middle of a crosshair.
    hot_x: u32 = 0,
    hot_y: u32 = 0,

    /// The longest side a system will take, which is Godot's limit too. A
    /// cursor larger than this is one the user would lose.
    pub const max_side: u32 = 256;

    /// Is this an image a system could take: a size within the limit, the
    /// pixels to fill it, and a hotspot inside it?
    pub fn valid(self: Image) bool {
        if (self.width == 0 or self.height == 0) return false;
        if (self.width > max_side or self.height > max_side) return false;
        if (self.hot_x >= self.width or self.hot_y >= self.height) return false;
        return self.pixels.len == @as(usize, self.width) * self.height * 4;
    }
};

/// How the pointer is set up for one window.
pub const Options = struct {
    mode: Mode = .normal,
    /// Unaccelerated motion. Only has an effect in `disabled` mode, and only
    /// where the system can provide it - `Window.rawMouseMotion` says whether
    /// it was actually turned on.
    raw_motion: bool = false,
    shape: Shape = .arrow,
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the modes say what they do" {
    // The pair that matters: `captured` keeps the cursor in and `disabled`
    // takes it away, and only the second is any use for a camera.
    try testing.expect(Mode.captured.confines());
    try testing.expect(Mode.disabled.confines());
    try testing.expect(Mode.confined_hidden.confines());
    try testing.expect(!Mode.normal.confines());
    try testing.expect(!Mode.hidden.confines());

    try testing.expect(Mode.hidden.hides());
    try testing.expect(Mode.disabled.hides());
    try testing.expect(Mode.confined_hidden.hides());
    try testing.expect(!Mode.normal.hides());
    try testing.expect(!Mode.captured.hides());
}

test "two modes hide and confine, and the one for a camera is the one with no position" {
    var both: usize = 0;
    inline for (@typeInfo(Mode).@"enum".fields) |field| {
        const mode: Mode = @enumFromInt(field.value);
        if (mode.hides() and mode.confines()) both += 1;
    }
    try testing.expectEqual(@as(usize, 2), both);
}

test "the shapes a system may not have are named" {
    // Everything else has to work everywhere, because there is no sensible
    // substitute for an I-beam in a text box.
    try testing.expect(!Shape.arrow.optional());
    try testing.expect(!Shape.ibeam.optional());
    try testing.expect(!Shape.pointing_hand.optional());
    try testing.expect(!Shape.resize_ew.optional());
    try testing.expect(!Shape.wait.optional());
    try testing.expect(!Shape.vsplit.optional());
    try testing.expect(Shape.resize_nwse.optional());
    try testing.expect(Shape.not_allowed.optional());
    try testing.expect(Shape.can_drop.optional());
}

test "an image is checked before a system is handed it" {
    var pixels: [4 * 4 * 4]u8 = @splat(0);
    const good: Image = .{ .pixels = &pixels, .width = 4, .height = 4, .hot_x = 3, .hot_y = 0 };
    try testing.expect(good.valid());

    // Nothing to draw, too few pixels for the size, a hotspot outside the
    // image, and a side no system takes.
    try testing.expect(!(Image{ .pixels = &pixels, .width = 0, .height = 4 }).valid());
    try testing.expect(!(Image{ .pixels = pixels[0..60], .width = 4, .height = 4 }).valid());
    try testing.expect(!(Image{ .pixels = &pixels, .width = 4, .height = 4, .hot_x = 4 }).valid());
    try testing.expect(!(Image{ .pixels = &pixels, .width = Image.max_side + 1, .height = 4 }).valid());
}

test "the defaults are what a window starts as" {
    const options: Options = .{};
    try testing.expectEqual(Mode.normal, options.mode);
    try testing.expectEqual(Shape.arrow, options.shape);
    try testing.expect(!options.raw_motion);
}
