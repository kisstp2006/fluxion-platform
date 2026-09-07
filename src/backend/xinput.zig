// SPDX-License-Identifier: BSL-1.0

//! Controllers on Windows, through XInput.
//!
//! **Four slots, not sixteen.** XInput is the Xbox controller API and it holds
//! exactly four pads, because that is how many an Xbox takes. Anything else -
//! a flight stick, an arcade board, a wheel with a hundred buttons - is a
//! DirectInput device and is not here. That is the trade GLFW makes too, and it
//! is the right one: XInput is present on every Windows machine since Vista,
//! needs no COM, and reports the layout every game actually wants.
//!
//! **Nothing has to be mapped.** An XInput pad *is* the Xbox layout - the API
//! has fields called `A` and `LeftThumbX` - so this backend fills in the mapped
//! state directly and a program never needs a mapping file for one.
//!
//! **A missing controller is slow to ask about.** `XInputGetState` on an empty
//! slot used to take a millisecond, which is why this only asks about the empty
//! ones a few times a second rather than every frame. A controller plugged in
//! now is noticed within that, which is faster than a person can look up.

const std = @import("std");

const dyn = @import("fluxion_dyn");
const gamepad = @import("../gamepad.zig");

/// XInput holds four. Anything past that is always disconnected.
pub const max_pads = 4;

/// `ERROR_SUCCESS` and `ERROR_DEVICE_NOT_CONNECTED`, which are the only two
/// answers that matter.
const error_success: u32 = 0;
const error_device_not_connected: u32 = 1167;

/// `XINPUT_GAMEPAD_*`, in wire order.
const button_dpad_up: u16 = 0x0001;
const button_dpad_down: u16 = 0x0002;
const button_dpad_left: u16 = 0x0004;
const button_dpad_right: u16 = 0x0008;
const button_start: u16 = 0x0010;
const button_back: u16 = 0x0020;
const button_left_thumb: u16 = 0x0040;
const button_right_thumb: u16 = 0x0080;
const button_left_shoulder: u16 = 0x0100;
const button_right_shoulder: u16 = 0x0200;
const button_a: u16 = 0x1000;
const button_b: u16 = 0x2000;
const button_x: u16 = 0x4000;
const button_y: u16 = 0x8000;

const XInputGamepad = extern struct {
    buttons: u16 = 0,
    left_trigger: u8 = 0,
    right_trigger: u8 = 0,
    thumb_lx: i16 = 0,
    thumb_ly: i16 = 0,
    thumb_rx: i16 = 0,
    thumb_ry: i16 = 0,
};

const XInputState = extern struct {
    /// Bumped whenever anything moved. Not used here - the whole state is read
    /// every time regardless - but the struct is passed by size.
    packet: u32 = 0,
    pad: XInputGamepad = .{},
};

const XInputCapabilities = extern struct {
    kind: u8 = 0,
    sub_type: u8 = 0,
    flags: u16 = 0,
    pad: XInputGamepad = .{},
    vibration: extern struct { left: u16 = 0, right: u16 = 0 } = .{},
};

const XInput = struct {
    XInputGetState: *const fn (u32, *XInputState) callconv(.winapi) u32,
    /// For the controller's kind - a wheel and a pad both answer XInput, and
    /// the name shown to a person should say which.
    XInputGetCapabilities: ?*const fn (u32, u32, *XInputCapabilities) callconv(.winapi) u32 = null,
};

/// Newest first. 1.4 ships with Windows 8 and later, 1.3 with the DirectX
/// runtime, and 9.1.0 with every Windows since Vista - so the last one is
/// always there and the first one is the best.
const candidates: []const [:0]const u8 = &.{
    "xinput1_4.dll",
    "xinput1_3.dll",
    "xinput9_1_0.dll",
};

/// `XINPUT_DEVSUBTYPE_*`, for a name a person would recognise. XInput has no
/// call that returns the device's actual name, so this is the best there is.
fn subTypeName(sub_type: u8) []const u8 {
    return switch (sub_type) {
        1 => "Xbox Controller",
        2 => "Xbox Wheel",
        3 => "Xbox Arcade Stick",
        4 => "Xbox Flight Stick",
        5 => "Xbox Dance Pad",
        6 => "Xbox Guitar",
        7 => "Xbox Guitar (alternate)",
        8 => "Xbox Drum Kit",
        11 => "Xbox Guitar Bass",
        19 => "Xbox Arcade Pad",
        else => "Xbox Controller",
    };
}

/// How many polls to skip before asking about an empty slot again.
///
/// Asking about a slot with nothing in it is the slow case, and asking about
/// four of them every frame is a measurable part of a frame. Every thirty is a
/// fifth of a second at sixty frames, which is well under how long it takes a
/// person to notice.
const empty_slot_interval: u8 = 30;

pub const Backend = struct {
    lib: ?dyn.Library = null,
    x: ?XInput = null,
    countdown: [max_pads]u8 = @splat(0),

    pub fn open() Backend {
        var self: Backend = .{};
        // Optional: a machine with no XInput has no controllers as far as this
        // library is concerned, which is not a reason to fail to open a window.
        var lib = dyn.Library.openAny(candidates) catch return self;
        const x = lib.bind(XInput) catch {
            lib.close();
            return self;
        };
        self.lib = lib;
        self.x = x;
        return self;
    }

    pub fn close(self: *Backend) void {
        if (self.lib) |*lib| lib.close();
        self.lib = null;
        self.x = null;
    }

    pub fn poll(self: *Backend, devices: *[gamepad.max_devices]gamepad.Device) void {
        const x = self.x orelse {
            for (devices) |*device| device.* = .{};
            return;
        };

        for (devices, 0..) |*device, index| {
            if (index >= max_pads) {
                device.* = .{};
                continue;
            }

            // An empty slot is expensive to ask about, so it is asked about
            // rarely. A connected one is cheap and is read every time.
            if (!device.connected) {
                if (self.countdown[index] > 0) {
                    self.countdown[index] -= 1;
                    continue;
                }
                self.countdown[index] = empty_slot_interval;
            }

            var state: XInputState = .{};
            if (x.XInputGetState(@intCast(index), &state) != error_success) {
                device.* = .{};
                continue;
            }

            if (!device.connected) fillIdentity(x, device, @intCast(index));
            device.connected = true;
            fillState(device, state.pad);
        }
    }

    /// The name and GUID, which only change when a different controller is
    /// plugged into the slot.
    fn fillIdentity(x: XInput, device: *gamepad.Device, index: u32) void {
        var name: []const u8 = "Xbox Controller";
        if (x.XInputGetCapabilities) |caps_of| {
            var caps: XInputCapabilities = .{};
            // Flag 1 is `XINPUT_FLAG_GAMEPAD`; zero means "any device".
            if (caps_of(index, 0, &caps) == error_success) {
                name = subTypeName(caps.sub_type);
            }
        }
        device.setName(name);

        // The GUID SDL gives an XInput pad. Not built from a real vendor and
        // product id, because XInput does not report one - but stable, and the
        // one the community's database uses for "an XInput controller".
        device.guid = "78696e70757400000000000000000000".*;
    }
};

/// XInput's state, in both the raw form a joystick has and the mapped one.
///
/// Both, because a program written against the raw axes should still work
/// against an Xbox pad - it is a joystick like any other, and the order here is
/// the one SDL and GLFW report XInput in.
fn fillState(device: *gamepad.Device, pad: XInputGamepad) void {
    var raw: gamepad.Raw = .{ .axis_count = 6, .button_count = 10, .hat_count = 1 };

    raw.axes[0] = stick(pad.thumb_lx);
    // Windows has up as positive on a stick and everything else has it as
    // negative, so the two vertical axes are flipped here rather than in six
    // different places later.
    raw.axes[1] = -stick(pad.thumb_ly);
    raw.axes[2] = stick(pad.thumb_rx);
    raw.axes[3] = -stick(pad.thumb_ry);
    raw.axes[4] = trigger(pad.left_trigger);
    raw.axes[5] = trigger(pad.right_trigger);

    const order = [_]u16{
        button_a,             button_b,
        button_x,             button_y,
        button_left_shoulder, button_right_shoulder,
        button_back,          button_start,
        button_left_thumb,    button_right_thumb,
    };
    for (order, 0..) |mask, index| raw.buttons[index] = (pad.buttons & mask) != 0;

    raw.hats[0] = .{
        .up = (pad.buttons & button_dpad_up) != 0,
        .right = (pad.buttons & button_dpad_right) != 0,
        .down = (pad.buttons & button_dpad_down) != 0,
        .left = (pad.buttons & button_dpad_left) != 0,
    };
    device.raw = raw;

    // And the mapped form, straight across: XInput already is the Xbox layout,
    // so there is nothing to look up and no mapping file to need.
    var state: gamepad.State = .{};
    state.axes[@intFromEnum(gamepad.Axis.left_x)] = raw.axes[0];
    state.axes[@intFromEnum(gamepad.Axis.left_y)] = raw.axes[1];
    state.axes[@intFromEnum(gamepad.Axis.right_x)] = raw.axes[2];
    state.axes[@intFromEnum(gamepad.Axis.right_y)] = raw.axes[3];
    // A trigger reads zero to one, and `trigger` already returned that.
    state.axes[@intFromEnum(gamepad.Axis.left_trigger)] = triggerUnit(pad.left_trigger);
    state.axes[@intFromEnum(gamepad.Axis.right_trigger)] = triggerUnit(pad.right_trigger);

    const buttons = [_]struct { gamepad.Button, u16 }{
        .{ .a, button_a },
        .{ .b, button_b },
        .{ .x, button_x },
        .{ .y, button_y },
        .{ .left_bumper, button_left_shoulder },
        .{ .right_bumper, button_right_shoulder },
        .{ .back, button_back },
        .{ .start, button_start },
        .{ .left_thumb, button_left_thumb },
        .{ .right_thumb, button_right_thumb },
        .{ .dpad_up, button_dpad_up },
        .{ .dpad_right, button_dpad_right },
        .{ .dpad_down, button_dpad_down },
        .{ .dpad_left, button_dpad_left },
    };
    for (buttons) |entry| {
        state.buttons[@intFromEnum(entry[0])] = (pad.buttons & entry[1]) != 0;
    }
    // XInput will not report the guide button. It belongs to the system, and
    // the undocumented call that reads it is not one to rely on.

    device.state = state;
    device.mapped = true;
}

/// A thumbstick's -32768..32767 as -1 to 1.
fn stick(value: i16) f32 {
    // Divided by 32767 rather than 32768, so that the far end is exactly one
    // and a stick pushed fully is not 0.99997.
    return std.math.clamp(@as(f32, @floatFromInt(value)) / 32767.0, -1, 1);
}

/// A trigger's 0..255 as the -1 to 1 a raw axis uses.
fn trigger(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 127.5 - 1;
}

/// The same trigger as the 0 to 1 a mapped one uses.
fn triggerUnit(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255.0;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a stick at rest is zero and at the ends is one" {
    try testing.expectEqual(@as(f32, 0), stick(0));
    try testing.expectApproxEqAbs(@as(f32, 1), stick(32767), 0.0001);
    // The extra step at the negative end is clamped rather than reported as
    // -1.00003, which would put a normalised vector outside the unit circle.
    try testing.expectApproxEqAbs(@as(f32, -1), stick(-32768), 0.0001);
}

test "a trigger reads both ways it is asked for" {
    try testing.expectApproxEqAbs(@as(f32, -1), trigger(0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), trigger(255), 0.01);

    try testing.expectEqual(@as(f32, 0), triggerUnit(0));
    try testing.expectEqual(@as(f32, 1), triggerUnit(255));
}

test "every button lands where the Xbox layout says it does" {
    var device: gamepad.Device = .{ .connected = true };
    fillState(&device, .{ .buttons = button_a | button_dpad_left | button_start });

    try testing.expect(device.mapped);
    try testing.expect(device.state.button(.a));
    try testing.expect(device.state.button(.dpad_left));
    try testing.expect(device.state.button(.start));

    try testing.expect(!device.state.button(.b));
    try testing.expect(!device.state.button(.dpad_right));
    // XInput does not report it, so it is never pressed rather than sometimes
    // wrong.
    try testing.expect(!device.state.button(.guide));

    // The same press in the raw form, at the index SDL uses for it.
    try testing.expect(device.raw.buttons[0]);
    try testing.expect(device.raw.hats[0].left);
    try testing.expect(!device.raw.hats[0].right);
}

test "up on a stick is negative, as it is everywhere but Windows" {
    var device: gamepad.Device = .{ .connected = true };
    fillState(&device, .{ .thumb_ly = 32767, .thumb_ry = -32768 });

    // Windows says a stick pushed up is positive; every other platform and
    // every mapping file says it is negative, so this backend flips it.
    try testing.expect(device.state.axis(.left_y) < -0.9);
    try testing.expect(device.state.axis(.right_y) > 0.9);
}

test "a trigger's mapped value rests at zero, not at minus one" {
    var device: gamepad.Device = .{ .connected = true };
    fillState(&device, .{});
    try testing.expectEqual(@as(f32, 0), device.state.axis(.left_trigger));

    fillState(&device, .{ .right_trigger = 255 });
    try testing.expectEqual(@as(f32, 1), device.state.axis(.right_trigger));
    // And the raw one still spans the whole range, because that is what a raw
    // axis is.
    try testing.expectApproxEqAbs(@as(f32, 1), device.raw.axes[5], 0.01);
}

test "the slots past XInput's four are always empty" {
    var backend: Backend = .{};
    var devices: [gamepad.max_devices]gamepad.Device = @splat(.{});
    devices[7] = .{ .connected = true };

    // No library open, so every slot is cleared rather than left as it was.
    backend.poll(&devices);
    for (&devices) |*device| try testing.expect(!device.connected);
}
