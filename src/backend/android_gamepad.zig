// SPDX-License-Identifier: BSL-1.0

//! Controllers on Android.
//!
//! **A gamepad arrives as input, not as a device list.** The NDK has no C call
//! that enumerates input devices - `InputManager.getInputDeviceIds` is Java,
//! and reaching it means JNI, a class lookup and a method id, all from a
//! background thread that has to attach itself to the VM first. So a controller
//! here appears in the list the first time it sends anything: press a button or
//! move a stick and the slot fills in.
//!
//! That is worth saying plainly rather than hiding: **a pad that has been
//! plugged in but never touched is not in the list yet**, and a program that
//! wants to say "press A to start" should say exactly that rather than waiting
//! for a device to appear.
//!
//! The same limit applies at the other end. Nothing tells a native activity
//! that a controller was unplugged, so a slot stays filled once it has been
//! used. A disconnected pad simply stops changing.
//!
//! **Nothing has to be mapped.** Android's compatibility rules say what a
//! gamepad reports - `AKEYCODE_BUTTON_A` is the bottom face button, `AXIS_Z`
//! and `AXIS_RZ` are the right stick - so a pad here is mapped on arrival and
//! no database is needed.

const std = @import("std");

const gamepad = @import("../gamepad.zig");

/// `AINPUT_SOURCE_*`. Each is a device bit *plus* a class bit, and several
/// sources share a class - a keyboard, a d-pad and a gamepad are all
/// `CLASS_BUTTON`. So a source is tested by masked equality and never by a
/// plain `and`: `SOURCE_KEYBOARD & SOURCE_GAMEPAD` is the class bit they have
/// in common, which is not zero and does not mean a keyboard is a gamepad.
pub const source_dpad: i32 = 0x00000201;
pub const source_gamepad: i32 = 0x00000401;
pub const source_joystick: i32 = 0x01000010;

/// True for an event that came from a controller rather than a touchscreen, a
/// keyboard or a mouse.
///
/// A d-pad on its own is not one. That is a television remote or a set-top
/// box's ring, and its arrow keys should reach a program as arrow keys - a
/// menu is driven with those, and swallowing them into a gamepad nobody asked
/// about would leave the menu dead.
pub fn isController(source: i32) bool {
    return (source & source_gamepad) == source_gamepad or
        (source & source_joystick) == source_joystick;
}

/// `AKEYCODE_BUTTON_*` and the d-pad, which is numbered with the navigation
/// keys rather than with the buttons.
const key_dpad_up: i32 = 19;
const key_dpad_down: i32 = 20;
const key_dpad_left: i32 = 21;
const key_dpad_right: i32 = 22;
const key_button_a: i32 = 96;
const key_button_b: i32 = 97;
const key_button_c: i32 = 98;
const key_button_x: i32 = 99;
const key_button_y: i32 = 100;
const key_button_z: i32 = 101;
const key_button_l1: i32 = 102;
const key_button_r1: i32 = 103;
const key_button_l2: i32 = 104;
const key_button_r2: i32 = 105;
const key_button_thumbl: i32 = 106;
const key_button_thumbr: i32 = 107;
const key_button_start: i32 = 108;
const key_button_select: i32 = 109;
const key_button_mode: i32 = 110;

/// `AMOTION_EVENT_AXIS_*`.
pub const axis_x: i32 = 0;
pub const axis_y: i32 = 1;
pub const axis_z: i32 = 11;
pub const axis_rz: i32 = 14;
pub const axis_hat_x: i32 = 15;
pub const axis_hat_y: i32 = 16;
pub const axis_ltrigger: i32 = 17;
pub const axis_rtrigger: i32 = 18;
/// What a pad reports when it has analogue triggers but calls them pedals.
/// Several do, and a program that only read `LTRIGGER` would find them dead.
pub const axis_brake: i32 = 23;
pub const axis_gas: i32 = 22;

/// The raw order this backend reports, chosen to match what SDL reports for an
/// Android controller so that a mapping written against one works here.
const raw_axis_order = [_]i32{
    axis_x,        axis_y,  axis_z,
    axis_rz,       axis_hat_x, axis_hat_y,
    axis_ltrigger, axis_rtrigger,
};

const raw_button_order = [_]i32{
    key_button_a,      key_button_b,      key_button_x,     key_button_y,
    key_button_l1,     key_button_r1,     key_button_select, key_button_start,
    key_button_mode,   key_button_thumbl, key_button_thumbr, key_button_l2,
    key_button_r2,     key_button_c,      key_button_z,
};

/// Which device is in which slot. Android device ids are arbitrary integers
/// that are not reused within a boot, so a slot belongs to one controller for
/// as long as the program runs.
pub const Backend = struct {
    device_ids: [gamepad.max_devices]i32 = @splat(0),

    /// The slot for a device, opening one if this is the first thing it has
    /// sent. Null when every slot is taken.
    fn slotFor(self: *Backend, devices: *[gamepad.max_devices]gamepad.Device, device_id: i32) ?usize {
        for (self.device_ids, 0..) |id, index| {
            if (id == device_id and devices[index].connected) return index;
        }
        for (self.device_ids, 0..) |_, index| {
            if (devices[index].connected) continue;

            self.device_ids[index] = device_id;
            devices[index] = .{ .connected = true, .mapped = true };
            devices[index].raw = .{
                .axis_count = raw_axis_order.len,
                .button_count = raw_button_order.len,
                .hat_count = 1,
            };
            // Triggers rest at the bottom of a raw axis's range, not in the
            // middle, and nothing will say so until they are pulled.
            devices[index].raw.axes[6] = -1;
            devices[index].raw.axes[7] = -1;

            var name_buf: [24]u8 = undefined;
            // The NDK will not say what it is called, so the id is the name.
            const name = std.fmt.bufPrint(&name_buf, "Controller {d}", .{device_id}) catch "Controller";
            devices[index].setName(name);
            // SDL's identifier for a controller it knows only through Android.
            devices[index].guid = "616e64726f696400000000000000000".* ++ "0".*;
            return index;
        }
        return null;
    }

    /// A button went down or up. True if this was a controller's.
    pub fn key(
        self: *Backend,
        devices: *[gamepad.max_devices]gamepad.Device,
        device_id: i32,
        source: i32,
        code: i32,
        pressed: bool,
    ) bool {
        if (!isController(source)) return false;
        if (findButton(code) == null and findDpad(code) == null) return false;

        const slot = self.slotFor(devices, device_id) orelse return false;
        const device = &devices[slot];

        if (findButton(code)) |index| device.raw.buttons[index] = pressed;
        if (findDpad(code)) |direction| {
            switch (direction) {
                .up => device.raw.hats[0].up = pressed,
                .right => device.raw.hats[0].right = pressed,
                .down => device.raw.hats[0].down = pressed,
                .left => device.raw.hats[0].left = pressed,
            }
        }
        remap(device);
        return true;
    }

    /// A stick or a trigger moved. `values` is one reading per axis in
    /// `raw_axis_order`, which is what the caller gets from
    /// `AMotionEvent_getAxisValue`.
    pub fn motion(
        self: *Backend,
        devices: *[gamepad.max_devices]gamepad.Device,
        device_id: i32,
        source: i32,
        values: [raw_axis_order.len]f32,
    ) bool {
        if (!isController(source)) return false;

        const slot = self.slotFor(devices, device_id) orelse return false;
        const device = &devices[slot];

        for (values, 0..) |value, index| {
            device.raw.axes[index] = std.math.clamp(value, -1, 1);
        }

        // The d-pad arrives as a hat axis on a controller and as key events on
        // a remote; both end up in the same hat.
        const hat_x = values[4];
        const hat_y = values[5];
        device.raw.hats[0] = .{
            .left = hat_x < -0.5,
            .right = hat_x > 0.5,
            .up = hat_y < -0.5,
            .down = hat_y > 0.5,
        };

        remap(device);
        return true;
    }

    /// How many axes a caller has to read for `motion`.
    pub const axis_count = raw_axis_order.len;

    /// Which `AMOTION_EVENT_AXIS_*` each of those is.
    pub const axis_codes = raw_axis_order;
};

const Direction = enum { up, right, down, left };

fn findDpad(code: i32) ?Direction {
    return switch (code) {
        key_dpad_up => .up,
        key_dpad_right => .right,
        key_dpad_down => .down,
        key_dpad_left => .left,
        else => null,
    };
}

fn findButton(code: i32) ?usize {
    for (raw_button_order, 0..) |wanted, index| {
        if (wanted == code) return index;
    }
    return null;
}

/// Android's layout straight across into the mapped state. Nothing to look up:
/// the compatibility rules already say which button is which.
fn remap(device: *gamepad.Device) void {
    var state: gamepad.State = .{};
    const raw = device.raw;

    state.axes[@intFromEnum(gamepad.Axis.left_x)] = raw.axes[0];
    state.axes[@intFromEnum(gamepad.Axis.left_y)] = raw.axes[1];
    state.axes[@intFromEnum(gamepad.Axis.right_x)] = raw.axes[2];
    state.axes[@intFromEnum(gamepad.Axis.right_y)] = raw.axes[3];
    // A trigger axis on Android already reads zero to one, unlike a stick, so
    // the raw form is the one that had to be shifted rather than this one.
    state.axes[@intFromEnum(gamepad.Axis.left_trigger)] = (raw.axes[6] + 1) / 2;
    state.axes[@intFromEnum(gamepad.Axis.right_trigger)] = (raw.axes[7] + 1) / 2;

    const buttons = [_]gamepad.Button{
        .a,     .b,          .x,           .y,
        .left_bumper, .right_bumper, .back, .start,
        .guide, .left_thumb, .right_thumb,
    };
    for (buttons, 0..) |which, index| {
        state.buttons[@intFromEnum(which)] = raw.buttons[index];
    }

    // A pad with digital triggers reports them as L2 and R2 rather than as an
    // axis, and a program reading the axis should still see them.
    if (raw.buttons[11]) state.axes[@intFromEnum(gamepad.Axis.left_trigger)] = 1;
    if (raw.buttons[12]) state.axes[@intFromEnum(gamepad.Axis.right_trigger)] = 1;

    state.buttons[@intFromEnum(gamepad.Button.dpad_up)] = raw.hats[0].up;
    state.buttons[@intFromEnum(gamepad.Button.dpad_right)] = raw.hats[0].right;
    state.buttons[@intFromEnum(gamepad.Button.dpad_down)] = raw.hats[0].down;
    state.buttons[@intFromEnum(gamepad.Button.dpad_left)] = raw.hats[0].left;

    device.state = state;
    device.mapped = true;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a touchscreen event is not a controller's" {
    // `AINPUT_SOURCE_TOUCHSCREEN` and `AINPUT_SOURCE_KEYBOARD`.
    try testing.expect(!isController(0x00001002));
    try testing.expect(!isController(0x00000101));

    try testing.expect(isController(source_gamepad));
    try testing.expect(isController(source_joystick));
    // A real pad claims several classes at once, which is still one pad.
    try testing.expect(isController(source_gamepad | source_joystick | source_dpad));

    // A keyboard and a gamepad share `CLASS_BUTTON`, so the bit they have in
    // common is not zero - which is why this is a masked equality and not an
    // `and`. A remote control's d-pad is not a gamepad either.
    try testing.expect(!isController(source_dpad));
    try testing.expect(!isController(source_dpad | 0x00000101));
}

test "a controller appears the first time it sends anything" {
    var backend: Backend = .{};
    var devices: [gamepad.max_devices]gamepad.Device = @splat(.{});

    try testing.expect(devices[0].connected == false);

    try testing.expect(backend.key(&devices, 42, source_gamepad, key_button_a, true));
    try testing.expect(devices[0].connected);
    try testing.expect(devices[0].state.button(.a));

    // The same device again goes to the same slot rather than filling a new
    // one, which is what makes the index a program remembers stay valid.
    try testing.expect(backend.key(&devices, 42, source_gamepad, key_button_b, true));
    try testing.expect(devices[0].state.button(.b));
    try testing.expect(!devices[1].connected);

    // A second controller gets the next slot.
    try testing.expect(backend.key(&devices, 43, source_gamepad, key_button_a, true));
    try testing.expect(devices[1].connected);
}

test "a key the pad does not have opens no slot" {
    var backend: Backend = .{};
    var devices: [gamepad.max_devices]gamepad.Device = @splat(.{});

    // `AKEYCODE_VOLUME_UP` claiming to come from a gamepad is not a reason to
    // invent a controller.
    try testing.expect(!backend.key(&devices, 1, source_gamepad, 24, true));
    try testing.expect(!devices[0].connected);
}

test "the d-pad works whether it arrives as keys or as an axis" {
    var backend: Backend = .{};
    var devices: [gamepad.max_devices]gamepad.Device = @splat(.{});

    // A real pad's d-pad claims both classes at once.
    const pad_dpad = source_gamepad | source_dpad;
    _ = backend.key(&devices, 1, pad_dpad, key_dpad_left, true);
    try testing.expect(devices[0].state.button(.dpad_left));
    try testing.expect(!devices[0].state.button(.dpad_right));

    _ = backend.key(&devices, 1, pad_dpad, key_dpad_left, false);
    try testing.expect(!devices[0].state.button(.dpad_left));

    // And the same thing as a hat axis, which is how a real pad sends it.
    var values: [Backend.axis_count]f32 = @splat(0);
    values[4] = 1; // hat X, pushed right
    _ = backend.motion(&devices, 1, source_joystick, values);
    try testing.expect(devices[0].state.button(.dpad_right));
    try testing.expect(!devices[0].state.button(.dpad_left));
}

test "a trigger rests at zero and reads one when pulled" {
    var backend: Backend = .{};
    var devices: [gamepad.max_devices]gamepad.Device = @splat(.{});

    // Opened by a button press, so the resting trigger values are the ones the
    // slot was created with rather than anything a motion event said.
    _ = backend.key(&devices, 1, source_gamepad, key_button_a, true);
    try testing.expectEqual(@as(f32, 0), devices[0].state.axis(.left_trigger));

    var values: [Backend.axis_count]f32 = @splat(0);
    values[6] = 1;
    values[7] = -1;
    _ = backend.motion(&devices, 1, source_joystick, values);
    try testing.expectEqual(@as(f32, 1), devices[0].state.axis(.left_trigger));
    try testing.expectEqual(@as(f32, 0), devices[0].state.axis(.right_trigger));

    // A pad with digital triggers reports L2 instead, and it still reads as
    // fully pulled.
    _ = backend.key(&devices, 1, source_gamepad, key_button_l2, true);
    try testing.expectEqual(@as(f32, 1), devices[0].state.axis(.left_trigger));
}

test "the sticks land on the axes Android says they do" {
    var backend: Backend = .{};
    var devices: [gamepad.max_devices]gamepad.Device = @splat(.{});

    var values: [Backend.axis_count]f32 = @splat(0);
    values[0] = -1; // AXIS_X
    values[1] = 0.5; // AXIS_Y
    values[2] = 0.25; // AXIS_Z, which is the right stick's horizontal
    values[3] = -0.75; // AXIS_RZ, its vertical
    _ = backend.motion(&devices, 7, source_joystick, values);

    const state = devices[0].state;
    try testing.expectApproxEqAbs(@as(f32, -1), state.axis(.left_x), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), state.axis(.left_y), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), state.axis(.right_x), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.75), state.axis(.right_y), 0.001);
}

test "every slot can be filled, and the next device is dropped rather than overwriting one" {
    var backend: Backend = .{};
    var devices: [gamepad.max_devices]gamepad.Device = @splat(.{});

    for (0..gamepad.max_devices) |index| {
        try testing.expect(backend.key(&devices, @intCast(index + 1), source_gamepad, key_button_a, true));
    }
    try testing.expect(devices[gamepad.max_devices - 1].connected);

    // One more than there is room for is refused, and nothing already in the
    // list is disturbed.
    try testing.expect(!backend.key(&devices, 999, source_gamepad, key_button_a, true));
    try testing.expectEqual(@as(i32, 1), backend.device_ids[0]);
}
