// SPDX-License-Identifier: BSL-1.0

//! Controllers in a browser: `navigator.getGamepads()`, and what it means.
//!
//! **Most pads arrive mapped.** A browser that recognises a controller says
//! `mapping: "standard"` and puts every control where the W3C layout says:
//! button 0 is the bottom face button, 12 to 15 are the d-pad, axis 1 is the
//! left stick's vertical with up negative. That is this library's layout
//! already - it is GLFW's, which is SDL's, which is the Xbox pad's - so a
//! standard pad is mapped on arrival and nothing is looked up.
//!
//! A pad the browser does not recognise arrives with an empty mapping and its
//! controls in whatever order the driver reported them. Those are handed over
//! raw, with an SDL GUID built from the vendor and product the `id` string
//! carries, and `Context.updateGamepadMappings` can map them the way it maps
//! anything else.
//!
//! **A pad is not listed until it is touched.** Browsers keep controllers out
//! of `getGamepads()` until a button is pressed while the page is visible, so
//! that a page cannot fingerprint what is plugged into the machine. So "press
//! any button" is the right prompt here, as it is on Android - and for a
//! related reason.
//!
//! **Triggers are buttons with a value.** The standard layout has no trigger
//! axes: `buttons[6]` and `buttons[7]` carry `value` from 0 to 1, which is
//! exactly the range `gamepad.Axis.left_trigger` promises, so they are copied
//! straight across.

const std = @import("std");
const testing = std.testing;

const gamepad = @import("../gamepad.zig");
const wire = @import("web_wire.zig");

/// The W3C "standard gamepad" button numbers.
pub const standard = struct {
    pub const a: u5 = 0;
    pub const b: u5 = 1;
    pub const x: u5 = 2;
    pub const y: u5 = 3;
    pub const left_bumper: u5 = 4;
    pub const right_bumper: u5 = 5;
    pub const left_trigger: u5 = 6;
    pub const right_trigger: u5 = 7;
    pub const back: u5 = 8;
    pub const start: u5 = 9;
    pub const left_thumb: u5 = 10;
    pub const right_thumb: u5 = 11;
    pub const dpad_up: u5 = 12;
    pub const dpad_down: u5 = 13;
    pub const dpad_left: u5 = 14;
    pub const dpad_right: u5 = 15;
    pub const guide: u5 = 16;
};

/// Where each of this library's buttons is in the standard layout.
///
/// Indexed by `gamepad.Button`, so the order is that enum's: the d-pad here is
/// up, right, down, left, while the W3C numbers it up, down, left, right.
const button_sources = [gamepad.Button.count]u5{
    standard.a,
    standard.b,
    standard.x,
    standard.y,
    standard.left_bumper,
    standard.right_bumper,
    standard.back,
    standard.start,
    standard.guide,
    standard.left_thumb,
    standard.right_thumb,
    standard.dpad_up,
    standard.dpad_right,
    standard.dpad_down,
    standard.dpad_left,
};

/// What an `id` string says about the device it names.
pub const Identity = struct {
    name: []const u8,
    vendor: ?u16 = null,
    product: ?u16 = null,
};

/// Take the vendor, the product and a readable name out of a `Gamepad.id`.
///
/// Every browser formats it differently, and none of the formats is
/// specified:
///
///   Chrome   `Wireless Controller (STANDARD GAMEPAD Vendor: 054c Product: 09cc)`
///   Chrome   `Xbox 360 Controller (XInput STANDARD GAMEPAD)`
///   Firefox  `054c-09cc-Wireless Controller`
///   Safari   `Wireless Controller`
///
/// So this reads what it recognises and keeps the rest as the name. A string
/// it cannot take apart is a name with no vendor, which is still a pad that
/// works - it just cannot be looked up in a mapping file.
pub fn identify(id: []const u8) Identity {
    var result: Identity = .{ .name = std.mem.trim(u8, id, " ") };

    // Chrome: the ids are inside a parenthesis at the end, and the name is
    // everything before it.
    if (std.mem.indexOf(u8, id, "Vendor: ")) |at| {
        result.vendor = hex16(id[at + "Vendor: ".len ..]);
        if (std.mem.indexOf(u8, id, "Product: ")) |p| {
            result.product = hex16(id[p + "Product: ".len ..]);
        }
    }
    if (std.mem.lastIndexOfScalar(u8, id, '(')) |open| {
        const inside = id[open..];
        if (std.mem.indexOf(u8, inside, "Vendor") != null or
            std.mem.indexOf(u8, inside, "GAMEPAD") != null)
        {
            result.name = std.mem.trim(u8, id[0..open], " ");
        }
    }
    if (result.vendor != null) return result;

    // Firefox: two hex numbers and a dash in front of the name.
    var parts = std.mem.splitScalar(u8, id, '-');
    const first = parts.next() orelse return result;
    const second = parts.next() orelse return result;
    if (first.len == 0 or first.len > 4 or second.len == 0 or second.len > 4) return result;
    const vendor = std.fmt.parseInt(u16, first, 16) catch return result;
    const product = std.fmt.parseInt(u16, second, 16) catch return result;
    result.vendor = vendor;
    result.product = product;
    result.name = std.mem.trim(u8, parts.rest(), " ");
    return result;
}

/// Four hex digits at the start of `text`, or null.
fn hex16(text: []const u8) ?u16 {
    if (text.len < 4) return null;
    return std.fmt.parseInt(u16, text[0..4], 16) catch null;
}

/// USB, as SDL numbers buses. A browser does not say how a pad is attached,
/// and USB is what the mapping database files almost every entry under.
const bus_usb: u16 = 0x03;

/// Turn one record into a device.
pub fn fill(device: *gamepad.Device, record: *const wire.GamepadRecord) void {
    device.* = .{ .connected = true };

    const id = record.id[0..@min(record.id_len, record.id.len)];
    const identity = identify(id);
    device.setName(identity.name);
    if (identity.vendor) |vendor| {
        // The version is not in the string, and zero is what SDL writes when
        // it does not know one either.
        device.guid = gamepad.guidFromUsb(bus_usb, vendor, identity.product orelse 0, 0);
    }

    const axis_count = @min(record.axis_count, gamepad.max_axes);
    const button_count = @min(record.button_count, gamepad.max_buttons);
    device.raw.axis_count = @intCast(axis_count);
    device.raw.button_count = @intCast(button_count);
    for (0..axis_count) |i| {
        device.raw.axes[i] = std.math.clamp(record.axes[i], -1, 1);
    }
    for (0..button_count) |i| {
        device.raw.buttons[i] = pressed(record, @intCast(i));
    }

    if (record.standard == 0) return;

    // Where every button already is, so nothing to look up.
    for (button_sources, 0..) |source, index| {
        device.state.buttons[index] = source < button_count and pressed(record, source);
    }
    const axes = [_]gamepad.Axis{ .left_x, .left_y, .right_x, .right_y };
    for (axes, 0..) |which, source| {
        if (source >= axis_count) continue;
        device.state.axes[@intFromEnum(which)] = std.math.clamp(record.axes[source], -1, 1);
    }
    device.state.axes[@intFromEnum(gamepad.Axis.left_trigger)] =
        triggerValue(record, standard.left_trigger, button_count);
    device.state.axes[@intFromEnum(gamepad.Axis.right_trigger)] =
        triggerValue(record, standard.right_trigger, button_count);
    device.mapped = true;
}

fn pressed(record: *const wire.GamepadRecord, index: u5) bool {
    return (record.pressed >> index) & 1 != 0;
}

/// How far a trigger is pulled. A pad whose triggers are digital reports a
/// value of exactly 0 or 1, which is the same answer from the same field.
fn triggerValue(record: *const wire.GamepadRecord, index: u5, button_count: usize) f32 {
    if (index >= button_count) return 0;
    return std.math.clamp(record.values[index], 0, 1);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn padNamed(id: []const u8) wire.GamepadRecord {
    var result: wire.GamepadRecord = .{};
    @memcpy(result.id[0..id.len], id);
    result.id_len = @intCast(id.len);
    return result;
}

test "Chrome's id: the name, then the ids in brackets" {
    const found = identify("Wireless Controller (STANDARD GAMEPAD Vendor: 054c Product: 09cc)");
    try testing.expectEqualStrings("Wireless Controller", found.name);
    try testing.expectEqual(@as(?u16, 0x054c), found.vendor);
    try testing.expectEqual(@as(?u16, 0x09cc), found.product);
}

test "Chrome's XInput id has a name and nothing else" {
    const found = identify("Xbox 360 Controller (XInput STANDARD GAMEPAD)");
    try testing.expectEqualStrings("Xbox 360 Controller", found.name);
    try testing.expectEqual(@as(?u16, null), found.vendor);
}

test "Firefox's id: the ids first, dashed" {
    const found = identify("045e-028e-Microsoft X-Box 360 pad");
    try testing.expectEqualStrings("Microsoft X-Box 360 pad", found.name);
    try testing.expectEqual(@as(?u16, 0x045e), found.vendor);
    try testing.expectEqual(@as(?u16, 0x028e), found.product);
}

test "an id that is only a name stays a name" {
    const found = identify("Xbox Wireless Controller");
    try testing.expectEqualStrings("Xbox Wireless Controller", found.name);
    try testing.expectEqual(@as(?u16, null), found.vendor);

    // Dashes that are not hex are part of the name, not a Firefox prefix.
    const dashed = identify("Pro-Controller-X");
    try testing.expectEqualStrings("Pro-Controller-X", dashed.name);
    try testing.expectEqual(@as(?u16, null), dashed.vendor);
}

test "a standard pad arrives mapped, with every control where it belongs" {
    var input = padNamed("Wireless Controller (STANDARD GAMEPAD Vendor: 054c Product: 09cc)");
    input.standard = 1;
    input.axis_count = 4;
    input.button_count = 17;
    input.axes = .{ 0.5, -1, 0, 0.25, 0, 0, 0, 0 };
    input.pressed = (1 << standard.a) | (1 << standard.dpad_right) | (1 << standard.guide);
    input.values[standard.left_trigger] = 0.75;

    var device: gamepad.Device = .{};
    fill(&device, &input);

    try testing.expect(device.connected);
    try testing.expect(device.mapped);
    try testing.expectEqualStrings("Wireless Controller", device.name());

    try testing.expect(device.state.button(.a));
    try testing.expect(device.state.button(.dpad_right));
    try testing.expect(device.state.button(.guide));
    try testing.expect(!device.state.button(.b));
    // The W3C numbers the d-pad up, down, left, right, and this library up,
    // right, down, left. Getting that wrong is a pad whose d-pad is rotated.
    try testing.expect(!device.state.button(.dpad_down));

    // Up is negative, here as everywhere but XInput, which this matches.
    try testing.expectApproxEqAbs(@as(f32, -1), device.state.axis(.left_y), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), device.state.axis(.left_x), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), device.state.axis(.right_y), 0.001);
    // A trigger is a button with a value, and the value is the axis.
    try testing.expectApproxEqAbs(@as(f32, 0.75), device.state.axis(.left_trigger), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), device.state.axis(.right_trigger), 0.001);
}

test "the guid is built the way SDL builds one, so the database can find it" {
    const input = padNamed("054c-09cc-Wireless Controller");
    var device: gamepad.Device = .{};
    fill(&device, &input);
    try testing.expectEqualStrings("030000004c050000cc09000000000000", &device.guid);
}

test "a pad the browser does not know is raw and unmapped" {
    var input = padNamed("Odd Stick");
    input.axis_count = 3;
    input.button_count = 5;
    input.axes = .{ 0.1, 0.2, 0.3, 0, 0, 0, 0, 0 };
    input.pressed = 0b10010;

    var device: gamepad.Device = .{};
    fill(&device, &input);

    try testing.expect(device.connected);
    try testing.expect(!device.mapped);
    try testing.expectEqual(@as(u8, 3), device.raw.axis_count);
    try testing.expectEqual(@as(u8, 5), device.raw.button_count);
    try testing.expect(device.raw.buttons[1]);
    try testing.expect(device.raw.buttons[4]);
    try testing.expect(!device.raw.buttons[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.3), device.raw.axes[2], 0.001);
    // No ids in the string, so nothing a mapping could be found by.
    try testing.expectEqualStrings("0" ** 32, &device.guid);
}

test "a device reporting more than the library keeps is cut, not overrun" {
    var input = padNamed("Flight Stick (Vendor: 044f Product: b10a)");
    input.axis_count = 40;
    input.button_count = 90;
    var device: gamepad.Device = .{};
    fill(&device, &input);
    try testing.expectEqual(@as(u8, gamepad.max_axes), device.raw.axis_count);
    try testing.expectEqual(@as(u8, gamepad.max_buttons), device.raw.button_count);
}

test "a standard pad with fewer buttons than the layout reads the rest as up" {
    var input = padNamed("Minimal");
    input.standard = 1;
    input.button_count = 4;
    input.pressed = 0xFFFF_FFFF;
    input.values[standard.left_trigger] = 1;

    var device: gamepad.Device = .{};
    fill(&device, &input);
    try testing.expect(device.state.button(.a));
    try testing.expect(!device.state.button(.guide));
    try testing.expectEqual(@as(f32, 0), device.state.axis(.left_trigger));
}
