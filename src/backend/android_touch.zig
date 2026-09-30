// SPDX-License-Identifier: BSL-1.0

//! A touchscreen's fingers on Android, as the library's events.
//!
//! **Every finger is its own `touch` events**, and **the first finger is the
//! mouse as well**: the one that touches when no other is down also moves the
//! cursor and holds the left button, marked `from_touch`, until it is lifted.
//! A second finger is never the mouse, and a first lifted while others stay
//! down leaves no mouse until every one is up - so the button a program made
//! for a mouse sees is one press and one release, whatever the other fingers
//! do. See `event.TouchEvent`.
//!
//! Apart from the NDK, so that it is tested on any machine: `android.zig`
//! reads a motion event's fingers and hands them here.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const event = @import("../event.zig");
const keys = @import("../keys.zig");

/// The most fingers followed at once. More is a screen that says so: they are
/// still told of, but never moved or lifted.
pub const max_fingers = 16;

/// Android's double tap: the second touch within this long of the first lift.
pub const double_tap_ms: u32 = 300;

/// One finger as a motion event has it.
pub const Finger = struct {
    /// `AMotionEvent_getPointerId`: the same number from touch to lift.
    id: u32,
    x: f64,
    y: f64,
    pressure: f32 = 1,
};

/// The fingers down, and which one is the mouse.
pub const Fingers = struct {
    down: [max_fingers]Finger = undefined,
    count: usize = 0,
    /// The finger that is the mouse, and where it was last.
    mouse: ?Finger = null,
    /// The mouse finger's taps, for a double tap.
    clicks: backend.Clicks = .{},

    /// A finger touched. `time_ms` is the event's own clock; `slop` how far
    /// off, in pixels, a second tap may land and still be a double tap.
    pub fn touched(self: *Fingers, sink: anytype, window: event.WindowId, finger: Finger, time_ms: u32, slop: f64) void {
        sink.push(touchOf(window, finger, .down));
        if (self.find(finger.id) == null and self.count < max_fingers) {
            self.down[self.count] = finger;
            self.count += 1;
        }
        if (self.count != 1 or self.mouse != null) {
            // A second finger is no double tap, and ends any that was coming.
            self.clicks = .{};
            return;
        }
        self.mouse = finger;
        sink.push(.{ .cursor = .{ .window = window, .x = finger.x, .y = finger.y, .dx = 0, .dy = 0, .from_touch = true } });
        sink.push(.{ .mouse_button = .{
            .window = window,
            .button = .left,
            .action = .press,
            .mods = .none,
            .x = finger.x,
            .y = finger.y,
            .double_click = self.clicks.press(window, .left, finger.x, finger.y, time_ms, double_tap_ms, slop),
            .from_touch = true,
        } });
    }

    /// A finger is where a move says: told of when it is somewhere new.
    pub fn moved(self: *Fingers, sink: anytype, window: event.WindowId, finger: Finger) void {
        const at = self.find(finger.id) orelse return;
        const was = self.down[at];
        if (was.x == finger.x and was.y == finger.y) return;
        self.down[at] = finger;
        sink.push(touchOf(window, finger, .move));
        const mouse = self.mouse orelse return;
        if (mouse.id != finger.id) return;
        self.mouse = finger;
        sink.push(.{ .cursor = .{
            .window = window,
            .x = finger.x,
            .y = finger.y,
            .dx = finger.x - mouse.x,
            .dy = finger.y - mouse.y,
            .from_touch = true,
        } });
    }

    /// A finger was lifted.
    pub fn lifted(self: *Fingers, sink: anytype, window: event.WindowId, finger: Finger, time_ms: u32) void {
        sink.push(touchOf(window, finger, .up));
        self.forget(finger.id);
        const mouse = self.mouse orelse return;
        if (mouse.id != finger.id) return;
        self.mouse = null;
        self.clicks.release(.left, time_ms);
        sink.push(releaseOf(window, finger));
    }

    /// The system took every finger: its own gesture, or the app went away.
    pub fn canceled(self: *Fingers, sink: anytype, window: event.WindowId) void {
        for (self.down[0..self.count]) |finger| sink.push(touchOf(window, finger, .cancel));
        self.count = 0;
        self.clicks = .{};
        const mouse = self.mouse orelse return;
        self.mouse = null;
        sink.push(releaseOf(window, mouse));
    }

    fn find(self: *const Fingers, id: u32) ?usize {
        for (self.down[0..self.count], 0..) |finger, i| {
            if (finger.id == id) return i;
        }
        return null;
    }

    fn forget(self: *Fingers, id: u32) void {
        const at = self.find(id) orelse return;
        self.down[at] = self.down[self.count - 1];
        self.count -= 1;
    }
};

fn touchOf(window: event.WindowId, finger: Finger, phase: event.TouchPhase) event.Event {
    return .{ .touch = .{
        .window = window,
        .finger = finger.id,
        .phase = phase,
        .x = finger.x,
        .y = finger.y,
        .pressure = std.math.clamp(finger.pressure, 0, 1),
    } };
}

fn releaseOf(window: event.WindowId, finger: Finger) event.Event {
    return .{ .mouse_button = .{
        .window = window,
        .button = .left,
        .action = .release,
        .mods = .none,
        .x = finger.x,
        .y = finger.y,
        .from_touch = true,
    } };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const Sink = struct {
    events: [32]event.Event = undefined,
    len: usize = 0,

    fn push(self: *Sink, ev: event.Event) void {
        self.events[self.len] = ev;
        self.len += 1;
    }

    fn taken(self: *Sink) []const event.Event {
        defer self.len = 0;
        return self.events[0..self.len];
    }
};

const test_window: event.WindowId = @enumFromInt(1);

test "a first finger is a touch and the mouse, and a second only a touch" {
    var fingers: Fingers = .{};
    var sink: Sink = .{};

    fingers.touched(&sink, test_window, .{ .id = 4, .x = 10, .y = 20 }, 1000, 100);
    var got = sink.taken();
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(event.TouchPhase.down, got[0].touch.phase);
    try testing.expectEqual(@as(u32, 4), got[0].touch.finger);
    try testing.expect(got[1].cursor.from_touch);
    try testing.expectEqual(keys.Action.press, got[2].mouse_button.action);
    try testing.expect(got[2].mouse_button.from_touch);

    fingers.touched(&sink, test_window, .{ .id = 7, .x = 300, .y = 40, .pressure = 0.5 }, 1010, 100);
    got = sink.taken();
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u32, 7), got[0].touch.finger);
    try testing.expectEqual(@as(f32, 0.5), got[0].touch.pressure);

    // Both move: the first moves the cursor too, by how far it went.
    fingers.moved(&sink, test_window, .{ .id = 4, .x = 15, .y = 20 });
    fingers.moved(&sink, test_window, .{ .id = 7, .x = 300, .y = 40 });
    fingers.moved(&sink, test_window, .{ .id = 7, .x = 310, .y = 45 });
    got = sink.taken();
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(event.TouchPhase.move, got[0].touch.phase);
    try testing.expectEqual(@as(f64, 5), got[1].cursor.dx);
    try testing.expectEqual(@as(u32, 7), got[2].touch.finger);

    // The first is lifted: the mouse comes up, and the second is no mouse.
    fingers.lifted(&sink, test_window, .{ .id = 4, .x = 15, .y = 20 }, 1100);
    got = sink.taken();
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(event.TouchPhase.up, got[0].touch.phase);
    try testing.expectEqual(keys.Action.release, got[1].mouse_button.action);
    fingers.moved(&sink, test_window, .{ .id = 7, .x = 320, .y = 45 });
    try testing.expectEqual(@as(usize, 1), sink.taken().len);

    // Nor is a finger that touches while it is down.
    fingers.touched(&sink, test_window, .{ .id = 2, .x = 50, .y = 50 }, 1200, 100);
    try testing.expectEqual(@as(usize, 1), sink.taken().len);
    fingers.lifted(&sink, test_window, .{ .id = 7, .x = 320, .y = 45 }, 1300);
    fingers.lifted(&sink, test_window, .{ .id = 2, .x = 50, .y = 50 }, 1300);
    try testing.expectEqual(@as(usize, 2), sink.taken().len);

    // Once every one is up, the next is the mouse again.
    fingers.touched(&sink, test_window, .{ .id = 0, .x = 5, .y = 5 }, 5000, 100);
    try testing.expectEqual(@as(usize, 3), sink.taken().len);
}

test "the mouse finger taps twice for a double tap; a second finger ends one" {
    var fingers: Fingers = .{};
    var sink: Sink = .{};

    fingers.touched(&sink, test_window, .{ .id = 0, .x = 10, .y = 10 }, 1000, 100);
    fingers.lifted(&sink, test_window, .{ .id = 0, .x = 10, .y = 10 }, 1100);
    fingers.touched(&sink, test_window, .{ .id = 0, .x = 40, .y = 30 }, 1300, 100);
    try testing.expect(sink.taken()[7].mouse_button.double_click);
    fingers.lifted(&sink, test_window, .{ .id = 0, .x = 40, .y = 30 }, 1350);

    fingers.touched(&sink, test_window, .{ .id = 0, .x = 10, .y = 10 }, 9000, 100);
    fingers.touched(&sink, test_window, .{ .id = 1, .x = 90, .y = 10 }, 9010, 100);
    fingers.lifted(&sink, test_window, .{ .id = 1, .x = 90, .y = 10 }, 9020);
    fingers.lifted(&sink, test_window, .{ .id = 0, .x = 10, .y = 10 }, 9030);
    _ = sink.taken();
    fingers.touched(&sink, test_window, .{ .id = 0, .x = 10, .y = 10 }, 9100, 100);
    try testing.expect(!sink.taken()[2].mouse_button.double_click);
}

test "a cancel lifts every finger, and the mouse" {
    var fingers: Fingers = .{};
    var sink: Sink = .{};
    fingers.touched(&sink, test_window, .{ .id = 3, .x = 1, .y = 1 }, 0, 100);
    fingers.touched(&sink, test_window, .{ .id = 8, .x = 2, .y = 2 }, 0, 100);
    _ = sink.taken();

    fingers.canceled(&sink, test_window);
    const got = sink.taken();
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(event.TouchPhase.cancel, got[0].touch.phase);
    try testing.expectEqual(event.TouchPhase.cancel, got[1].touch.phase);
    try testing.expectEqual(keys.Action.release, got[2].mouse_button.action);
    try testing.expectEqual(@as(usize, 0), fingers.count);
    try testing.expect(fingers.mouse == null);
}
