// SPDX-License-Identifier: BSL-1.0

//! What the pointer looks like, and where it is allowed to go.
//!
//! Four modes, and the difference between them is the difference between a
//! program that has a cursor and a game that has a camera:
//!
//!   `normal`    the ordinary arrow, free to leave the window
//!   `hidden`    invisible over the window, and still free to leave
//!   `captured`  visible, but confined to the content area
//!   `disabled`  invisible, confined, and reporting motion with no edges
//!
//! **`disabled` is the one a first-person camera needs**, and it is not just
//! `hidden` plus `captured`. A confined cursor still stops at the edge of the
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

    /// Is the pointer confined to the window in this mode?
    pub fn confines(self: Mode) bool {
        return self == .captured or self == .disabled;
    }

    /// Is it invisible in this mode?
    pub fn hides(self: Mode) bool {
        return self == .hidden or self == .disabled;
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

    /// The two diagonals and the two axes are the ones a system may not have.
    /// `arrow` is the fallback, and every platform has that.
    pub fn optional(self: Shape) bool {
        return switch (self) {
            .resize_nwse, .resize_nesw, .not_allowed => true,
            else => false,
        };
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
    try testing.expect(!Mode.normal.confines());
    try testing.expect(!Mode.hidden.confines());

    try testing.expect(Mode.hidden.hides());
    try testing.expect(Mode.disabled.hides());
    try testing.expect(!Mode.normal.hides());
    try testing.expect(!Mode.captured.hides());
}

test "disabled is the only mode that both hides and confines" {
    var both: usize = 0;
    inline for (@typeInfo(Mode).@"enum".fields) |field| {
        const mode: Mode = @enumFromInt(field.value);
        if (mode.hides() and mode.confines()) both += 1;
    }
    try testing.expectEqual(@as(usize, 1), both);
}

test "the shapes a system may not have are named" {
    // Everything else has to work everywhere, because there is no sensible
    // substitute for an I-beam in a text box.
    try testing.expect(!Shape.arrow.optional());
    try testing.expect(!Shape.ibeam.optional());
    try testing.expect(!Shape.pointing_hand.optional());
    try testing.expect(!Shape.resize_ew.optional());
    try testing.expect(Shape.resize_nwse.optional());
    try testing.expect(Shape.not_allowed.optional());
}

test "the defaults are what a window starts as" {
    const options: Options = .{};
    try testing.expectEqual(Mode.normal, options.mode);
    try testing.expectEqual(Shape.arrow, options.shape);
    try testing.expect(!options.raw_motion);
}
