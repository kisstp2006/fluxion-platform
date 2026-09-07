// SPDX-License-Identifier: BSL-1.0

//! What a controller looks like through a real backend.
//!
//! `gamepad.zig` checks the mapping arithmetic on its own and each backend
//! checks its own translation; this checks the seam between them - that a
//! context polls without a controller attached, that the slots stay put, and
//! that whatever *is* attached comes back looking like a controller.
//!
//! Most of these pass on a machine with nothing plugged in, which is the point:
//! a build server has no gamepad and the library still has to behave.

const std = @import("std");
const testing = std.testing;

const Context = @import("Context.zig");
const gamepad = @import("gamepad.zig");

const Fixture = struct {
    ctx: Context = undefined,

    fn open(self: *Fixture) bool {
        self.ctx = Context.init(testing.allocator, .{}) catch return false;
        return true;
    }

    fn close(self: *Fixture) void {
        self.ctx.deinit();
    }
};

test "a context has sixteen slots whether or not anything is in them" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const ctx = &fixture.ctx;

    // Always the full sixteen, so an index that came out of an event can be
    // used without checking a length first.
    try testing.expectEqual(@as(usize, gamepad.max_devices), ctx.gamepads().len);

    // Out of range is null rather than a crash, and so is an empty slot.
    try testing.expectEqual(@as(?*const gamepad.Device, null), ctx.gamepad(gamepad.max_devices));
    try testing.expectEqual(@as(?*const gamepad.Device, null), ctx.gamepad(9999));
}

test "pumping with no controller attached is not a failure" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const ctx = &fixture.ctx;

    // The expensive half of this is the scan for devices, which runs on the
    // first pump and then rarely. None of it may fail on a machine with an
    // empty `/dev/input` or no XInput.
    for (0..8) |_| try ctx.pump();
}

test "whatever is attached looks like a controller" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const ctx = &fixture.ctx;

    try ctx.pump();

    for (ctx.gamepads(), 0..) |*pad, index| {
        if (!pad.connected) continue;

        // A connected device is one this library can actually read.
        try testing.expect(pad.name().len > 0);
        try testing.expect(pad.name().len <= gamepad.max_name_len);
        try testing.expectEqual(@as(u8, 0), pad.name_buf[pad.name_len]);

        try testing.expect(pad.raw.axis_count <= gamepad.max_axes);
        try testing.expect(pad.raw.button_count <= gamepad.max_buttons);
        try testing.expect(pad.raw.hat_count <= gamepad.max_hats);

        // Every axis is inside the range the whole library agrees on, whatever
        // the driver's own numbers were.
        for (pad.raw.axes[0..pad.raw.axis_count]) |value| {
            try testing.expect(value >= -1 and value <= 1);
        }
        for (pad.state.axes, 0..) |value, which| {
            const axis: gamepad.Axis = @enumFromInt(which);
            // A trigger is zero to one; everything else is minus one to one.
            const floor: f32 = if (axis.isTrigger()) 0 else -1;
            try testing.expect(value >= floor and value <= 1);
        }

        // The GUID is 32 hex characters, because that is what a mapping is
        // looked up by and a short one would never match.
        try testing.expectEqual(@as(usize, 32), pad.guid.len);
        for (pad.guid) |char| {
            try testing.expect(std.ascii.isHex(char));
        }

        // And it is the one `gamepad(index)` hands back, so the two ways of
        // reaching a controller agree.
        try testing.expectEqual(pad, ctx.gamepad(index).?);
    }
}

test "the first controller is the first connected one, or none" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const ctx = &fixture.ctx;

    try ctx.pump();

    var expected: ?*const gamepad.Device = null;
    for (ctx.gamepads()) |*pad| {
        if (pad.connected) {
            expected = pad;
            break;
        }
    }
    try testing.expectEqual(expected, ctx.firstGamepad());
}

test "a mapping file can be loaded over whatever the system already knew" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const ctx = &fixture.ctx;

    const text =
        \\# A comment, and a blank line, and one real entry.
        \\
        \\0000000000000000000000000000ffff,Made up pad,a:b0,b:b1,leftx:a0,
    ;
    const taken = try ctx.updateGamepadMappings(text);
    try testing.expectEqual(@as(usize, 1), taken);

    // Loading the same file twice replaces rather than piles up, so a program
    // that reloads on a hotplug does not grow a list forever.
    _ = try ctx.updateGamepadMappings(text);
    try testing.expectEqual(@as(usize, 1), ctx.mappings.list.items.len);

    // A file with nothing usable in it is zero taken, not an error: a
    // community database with every line for another platform is a real case.
    try testing.expectEqual(@as(usize, 0), try ctx.updateGamepadMappings("# nothing here\n"));
}

test "a connection notice names a slot that can be read" {
    var fixture: Fixture = .{};
    if (!fixture.open()) return error.SkipZigTest;
    defer fixture.close();
    const ctx = &fixture.ctx;

    // The first pump finds whatever was already plugged in, so any controller
    // on this machine is announced here.
    try ctx.pump();

    var announced: usize = 0;
    while (ctx.poll()) |ev| switch (ev) {
        .gamepad_connected => |index| {
            announced += 1;
            // The event is only worth having if the slot it names is readable
            // by the time a program sees it.
            try testing.expect(index < gamepad.max_devices);
            try testing.expect(ctx.gamepad(index) != null);
        },
        .gamepad_disconnected => |index| {
            // Nothing was connected before the first pump, so nothing can have
            // gone away during it.
            _ = index;
            try testing.expect(false);
        },
        else => {},
    };

    // However many were announced, that is how many are connected - the two
    // must not disagree.
    var connected: usize = 0;
    for (ctx.gamepads()) |*pad| {
        if (pad.connected) connected += 1;
    }
    try testing.expectEqual(connected, announced);
}
