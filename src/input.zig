// SPDX-License-Identifier: BSL-1.0

//! What is held down right now, kept up to date as events go past.
//!
//! The queue says what *happened*; this says what *is*. A camera that moves
//! while W is held wants the second, and tracking it from the first is a table
//! every program would otherwise write for itself - with the same two bugs:
//! forgetting to clear it when the window loses focus, and missing a key that
//! went down and up inside one frame.
//!
//! `Context.pump` walks the events it just collected and updates this before
//! `poll` hands any of them out, so the state a frame reads always agrees with
//! the events that frame is about to see.
//!
//! **Sticky keys are how a press that came and went is not lost.** At sixty
//! frames a second a tap can begin and end between two pumps, and a program
//! that only polls would never see it. With `sticky` on, a key that went down
//! stays readable as down until it is polled once - which is what makes
//! polling a fair alternative to reading the queue rather than a lossy one.

const std = @import("std");
const testing = std.testing;

const event = @import("event.zig");
const keys = @import("keys.zig");

/// How far the system scrolls text for one notch of the wheel: what a text
/// view multiplies a `.scroll` event's notches by. See `Context.scrollLines`.
pub const ScrollLines = struct {
    /// Characters for a notch of the horizontal wheel.
    x: f32 = 3,
    /// Lines for a notch of the vertical wheel.
    y: f32 = 3,
    /// The user chose a screen at a time: a vertical notch is a page, and `y` is 1.
    page: bool = false,
};

/// Everything the pointer and the keyboard are doing.
pub const State = struct {
    /// Down now, one entry per key. `Key.index` says where a key sits.
    down: [keys.Key.max + 1]bool = @splat(false),
    /// Went down since the last poll, and not yet read. Only used when
    /// `sticky` is on.
    latched: [keys.Key.max + 1]bool = @splat(false),

    buttons_down: [keys.MouseButton.max + 1]bool = @splat(false),
    buttons_latched: [keys.MouseButton.max + 1]bool = @splat(false),

    /// Where the cursor was when it was last heard from, in content-area
    /// coordinates.
    cursor_x: f64 = 0,
    cursor_y: f64 = 0,
    /// How far the wheel has moved in total. A program that wants "since last
    /// frame" keeps its own copy and subtracts.
    scroll_x: f64 = 0,
    scroll_y: f64 = 0,

    mods: keys.Mods = .none,

    /// Keep a press readable until it has been polled once. Off by default,
    /// because it is only right for a program that polls - one reading the
    /// queue would see the press twice.
    sticky: bool = false,

    /// Take one event into account. Called by `Context.pump`, in order.
    pub fn apply(self: *State, ev: event.Event) void {
        switch (ev) {
            .key => |k| {
                self.mods = k.mods;
                const index = k.key.index() orelse return;
                switch (k.action) {
                    .press => {
                        self.down[index] = true;
                        self.latched[index] = true;
                    },
                    // A repeat is the key still being held, and says nothing
                    // new; treating it as a press would double-count a tap.
                    .repeat => self.down[index] = true,
                    .release => self.down[index] = false,
                }
            },

            .mouse_button => |b| {
                self.mods = b.mods;
                self.cursor_x = b.x;
                self.cursor_y = b.y;
                const index = b.button.index() orelse return;
                switch (b.action) {
                    .press, .repeat => {
                        self.buttons_down[index] = true;
                        self.buttons_latched[index] = true;
                    },
                    .release => self.buttons_down[index] = false,
                }
            },

            .cursor => |c| {
                self.cursor_x = c.x;
                self.cursor_y = c.y;
            },

            .scroll => |s| {
                self.scroll_x += s.x;
                self.scroll_y += s.y;
                self.mods = s.mods;
            },

            // Losing focus means every key the program thinks is held is a key
            // the user may have let go of somewhere else. Anything else leaves
            // a camera drifting after alt-tab, which is the classic version of
            // this bug.
            .focus => |f| if (!f.value) self.clear(),

            else => {},
        }
    }

    /// Is this key down?
    ///
    /// With `sticky` on, a key that went down and up since the last read still
    /// answers true once, and is cleared by the reading.
    pub fn key(self: *State, which: keys.Key) bool {
        const index = which.index() orelse return false;
        if (self.down[index]) return true;
        if (self.sticky and self.latched[index]) {
            self.latched[index] = false;
            return true;
        }
        return false;
    }

    /// The same, without clearing a latched press. For code that asks twice in
    /// one frame and should get the same answer both times.
    pub fn keyDown(self: *const State, which: keys.Key) bool {
        const index = which.index() orelse return false;
        return self.down[index] or (self.sticky and self.latched[index]);
    }

    pub fn button(self: *State, which: keys.MouseButton) bool {
        const index = which.index() orelse return false;
        if (self.buttons_down[index]) return true;
        if (self.sticky and self.buttons_latched[index]) {
            self.buttons_latched[index] = false;
            return true;
        }
        return false;
    }

    pub fn buttonDown(self: *const State, which: keys.MouseButton) bool {
        const index = which.index() orelse return false;
        return self.buttons_down[index] or (self.sticky and self.buttons_latched[index]);
    }

    /// Where the cursor is, in content-area coordinates.
    pub fn cursor(self: *const State) [2]f64 {
        return .{ self.cursor_x, self.cursor_y };
    }

    /// How far the wheel has moved since the context was opened.
    pub fn scroll(self: *const State) [2]f64 {
        return .{ self.scroll_x, self.scroll_y };
    }

    /// Forget everything held. What losing focus does, and what a program
    /// should do itself when it opens a menu that swallows input.
    pub fn clear(self: *State) void {
        self.down = @splat(false);
        self.latched = @splat(false);
        self.buttons_down = @splat(false);
        self.buttons_latched = @splat(false);
        self.mods = .none;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn keyEvent(which: keys.Key, action: keys.Action) event.Event {
    return .{ .key = .{
        .window = @enumFromInt(1),
        .key = which,
        .scancode = @enumFromInt(0),
        .action = action,
        .mods = .none,
    } };
}

test "a press goes down and a release comes up" {
    var state: State = .{};

    try testing.expect(!state.key(.w));
    state.apply(keyEvent(.w, .press));
    try testing.expect(state.key(.w));
    // Asking twice gives the same answer while it is genuinely held.
    try testing.expect(state.key(.w));

    state.apply(keyEvent(.w, .release));
    try testing.expect(!state.key(.w));
}

test "a repeat is not a second press" {
    var state: State = .{};
    state.apply(keyEvent(.a, .press));
    state.apply(keyEvent(.a, .repeat));
    try testing.expect(state.key(.a));
    state.apply(keyEvent(.a, .release));
    try testing.expect(!state.key(.a));
}

test "without sticky, a tap inside one frame is missed" {
    var state: State = .{};

    // Down and up before anything polled - which is what a fast tap looks
    // like at sixty frames a second.
    state.apply(keyEvent(.space, .press));
    state.apply(keyEvent(.space, .release));
    try testing.expect(!state.key(.space));
}

test "with sticky, the same tap is readable exactly once" {
    var state: State = .{ .sticky = true };

    state.apply(keyEvent(.space, .press));
    state.apply(keyEvent(.space, .release));

    // Seen once...
    try testing.expect(state.key(.space));
    // ...and not again, because reading is what clears it.
    try testing.expect(!state.key(.space));
}

test "keyDown does not consume a latched press" {
    var state: State = .{ .sticky = true };
    state.apply(keyEvent(.q, .press));
    state.apply(keyEvent(.q, .release));

    try testing.expect(state.keyDown(.q));
    try testing.expect(state.keyDown(.q));
    // And the consuming read still gets it.
    try testing.expect(state.key(.q));
    try testing.expect(!state.key(.q));
}

test "losing focus lets go of everything" {
    var state: State = .{};
    state.apply(keyEvent(.w, .press));
    state.apply(keyEvent(.left_shift, .press));
    try testing.expect(state.key(.w));

    // The classic bug this prevents: alt-tab away while holding W, and the
    // camera keeps moving forever.
    state.apply(.{ .focus = .{ .window = @enumFromInt(1), .value = false } });
    try testing.expect(!state.key(.w));
    try testing.expect(!state.key(.left_shift));

    // Gaining focus does not restore it - the program has no idea what is
    // still held, and guessing would be worse.
    state.apply(.{ .focus = .{ .window = @enumFromInt(1), .value = true } });
    try testing.expect(!state.key(.w));
}

test "a key with no place in the table is ignored rather than crashing" {
    var state: State = .{};
    state.apply(keyEvent(.unknown, .press));
    try testing.expect(!state.key(.unknown));

    const far: keys.Key = @enumFromInt(9000);
    state.apply(keyEvent(far, .press));
    try testing.expect(!state.key(far));
}

test "buttons and the cursor follow the pointer events" {
    var state: State = .{};

    state.apply(.{ .cursor = .{ .window = @enumFromInt(1), .x = 12, .y = 34, .dx = 0, .dy = 0 } });
    try testing.expectEqual([2]f64{ 12, 34 }, state.cursor());

    state.apply(.{ .mouse_button = .{
        .window = @enumFromInt(1),
        .button = .left,
        .action = .press,
        .mods = .none,
        .x = 40,
        .y = 50,
    } });
    try testing.expect(state.button(.left));
    try testing.expect(!state.button(.right));
    // A button event carries a position too, and it is the newer one.
    try testing.expectEqual([2]f64{ 40, 50 }, state.cursor());
}

test "scroll accumulates rather than reporting a delta" {
    var state: State = .{};
    const one: event.Event = .{ .scroll = .{
        .window = @enumFromInt(1),
        .x = 0,
        .y = 1,
        .mods = .none,
    } };
    state.apply(one);
    state.apply(one);
    try testing.expectEqual([2]f64{ 0, 2 }, state.scroll());
}

test "modifiers come from whichever event was last" {
    var state: State = .{};
    state.apply(.{ .key = .{
        .window = @enumFromInt(1),
        .key = .a,
        .scancode = @enumFromInt(0),
        .action = .press,
        .mods = .{ .control = true },
    } });
    try testing.expectEqual(keys.Mods{ .control = true }, state.mods);

    state.apply(.{ .focus = .{ .window = @enumFromInt(1), .value = false } });
    try testing.expectEqual(keys.Mods.none, state.mods);
}
