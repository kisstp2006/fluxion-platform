// SPDX-License-Identifier: BSL-1.0

//! Controllers on Linux, through evdev.
//!
//! **Not a windowing-system question.** A gamepad on Linux is a character
//! device the kernel exposes at `/dev/input/eventN`, and it is the same device
//! whether the session is X11, Wayland, or a terminal with no display at all.
//! So this file is shared: both desktop backends point their `pollGamepads` at
//! it and neither has a copy.
//!
//! **The kernel has already done the mapping.** `Documentation/input/gamepad.rst`
//! says which code is which button - `BTN_SOUTH` is the one under the thumb,
//! `ABS_RZ` is the right trigger - and every driver in the tree follows it. So
//! a pad here arrives mapped without a database, and the database is only
//! needed for the device that ignores the spec.
//!
//! Note that the four face buttons are named by *position*: `BTN_NORTH` is the
//! top one. Its historical alias is `BTN_X`, which is the wrong letter for an
//! Xbox pad, and following the alias rather than the position is how a library
//! ends up swapping X and Y for everybody.
//!
//! **Reading a device needs permission.** On a desktop `udev` and `logind` hand
//! the seat's input devices to whoever is logged in, so this works. Over SSH,
//! in a container, or on a system without them, `open` says no and there are no
//! controllers - which is the truth, not a failure.

const std = @import("std");

const gamepad = @import("../gamepad.zig");

/// How many `/dev/input/eventN` to look at. The kernel numbers them from zero
/// and a desktop rarely passes ten; thirty-two is room for a machine with a lot
/// plugged in, and thirty-two `open` calls once a second is nothing.
const max_nodes = 32;

/// How many polls between rescans.
///
/// A controller plugged in now should be noticed, and `inotify` on
/// `/dev/input` is the tidy way to do it - but it is another descriptor to own
/// and another failure mode, and trying to open thirty-two paths is cheap
/// enough that a second's delay is not worth the machinery.
const rescan_interval: u8 = 60;

// evdev's own numbers, from `linux/input-event-codes.h`.
const ev_syn: u16 = 0x00;
const ev_key: u16 = 0x01;
const ev_abs: u16 = 0x03;

const key_max: usize = 0x2ff;
const key_count: usize = key_max + 1;
const abs_max: usize = 0x3f;
const abs_count: usize = abs_max + 1;

const abs_x: u16 = 0x00;
const abs_y: u16 = 0x01;
const abs_z: u16 = 0x02;
const abs_rx: u16 = 0x03;
const abs_ry: u16 = 0x04;
const abs_rz: u16 = 0x05;
const abs_hat0x: u16 = 0x10;
const abs_hat3y: u16 = 0x17;

const btn_joystick: u16 = 0x120;
const btn_gamepad: u16 = 0x130;
const btn_south: u16 = 0x130;
const btn_east: u16 = 0x131;
const btn_north: u16 = 0x133;
const btn_west: u16 = 0x134;
const btn_tl: u16 = 0x136;
const btn_tr: u16 = 0x137;
const btn_tl2: u16 = 0x138;
const btn_tr2: u16 = 0x139;
const btn_select: u16 = 0x13a;
const btn_start: u16 = 0x13b;
const btn_mode: u16 = 0x13c;
const btn_thumbl: u16 = 0x13d;
const btn_thumbr: u16 = 0x13e;
const btn_dpad_up: u16 = 0x220;
const btn_dpad_down: u16 = 0x221;
const btn_dpad_left: u16 = 0x222;
const btn_dpad_right: u16 = 0x223;

const o_rdonly: c_int = 0;
const o_nonblock: c_int = 0o4000;
const o_cloexec: c_int = 0o2000000;

const InputEvent = extern struct {
    /// A `timeval`, which nothing here reads. Present because the struct is
    /// read from the kernel by size and a short one would misalign every field
    /// after it.
    sec: c_long,
    usec: c_long,
    type: u16,
    code: u16,
    value: i32,
};

/// `struct input_id`, which is where the GUID comes from.
const InputId = extern struct {
    bustype: u16 = 0,
    vendor: u16 = 0,
    product: u16 = 0,
    version: u16 = 0,
};

/// `struct input_absinfo`: an axis's range, and how much of it is noise.
const AbsInfo = extern struct {
    value: i32 = 0,
    minimum: i32 = 0,
    maximum: i32 = 0,
    fuzz: i32 = 0,
    /// The kernel's own deadzone, in the axis's units. A driver that knows its
    /// hardware drifts says so here.
    flat: i32 = 0,
    resolution: i32 = 0,
};

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
/// `errno` is a macro over a per-thread location, so the location is what a
/// library asks for. glibc and musl both export this name.
extern "c" fn __errno_location() *c_int;

/// `EAGAIN`, which on Linux is also `EWOULDBLOCK`. The one failure from a
/// non-blocking read that is not a failure at all.
const eagain: c_int = 11;
const eintr: c_int = 4;

/// `_IOC(_IOC_READ, type, nr, size)`, which is how every `EVIOCG*` is built.
fn ior(letter: u8, number: u8, size: usize) c_ulong {
    const read_dir: c_ulong = 2;
    return (read_dir << 30) | (@as(c_ulong, size) << 16) |
        (@as(c_ulong, letter) << 8) | @as(c_ulong, number);
}

fn eviocgid() c_ulong {
    return ior('E', 0x02, @sizeOf(InputId));
}

fn eviocgname(len: usize) c_ulong {
    return ior('E', 0x06, len);
}

fn eviocgbit(ev: u8, len: usize) c_ulong {
    return ior('E', 0x20 + ev, len);
}

fn eviocgabs(axis: u8) c_ulong {
    return ior('E', 0x40 + axis, @sizeOf(AbsInfo));
}

fn bitSet(bits: []const u8, index: usize) bool {
    const byte = index / 8;
    if (byte >= bits.len) return false;
    return (bits[byte] >> @intCast(index % 8)) & 1 != 0;
}

/// One open controller.
const Node = struct {
    fd: c_int = -1,
    /// Which `/dev/input/eventN` it is, so a rescan does not open the same
    /// device twice into a second slot.
    node: u8 = 0,

    /// Which evdev code each raw axis and button came from, so an event can be
    /// turned back into an index without a search.
    axis_codes: [gamepad.max_axes]u16 = @splat(0),
    axis_min: [gamepad.max_axes]i32 = @splat(0),
    axis_max: [gamepad.max_axes]i32 = @splat(0),
    button_codes: [gamepad.max_buttons]u16 = @splat(0),
    /// The first `ABS_HAT*X` code of each hat.
    hat_codes: [gamepad.max_hats]u16 = @splat(0),

    /// Where the kernel's own named controls ended up in the raw arrays, or
    /// 255 for one this device does not have. Built once, so applying the
    /// kernel's layout each poll is a handful of array reads.
    mapped_axis: [gamepad.Axis.count]u8 = @splat(255),
    mapped_button: [gamepad.Button.count]u8 = @splat(255),
    /// The hat that drives the d-pad, or 255 where the d-pad is four buttons.
    dpad_hat: u8 = 255,
    /// True once the device has been recognised as following the kernel's
    /// gamepad layout.
    follows_spec: bool = false,
};

pub const Backend = struct {
    nodes: [gamepad.max_devices]Node = @splat(.{}),
    countdown: u8 = 0,

    pub fn close_(self: *Backend) void {
        for (&self.nodes) |*node| {
            if (node.fd >= 0) _ = close(node.fd);
            node.fd = -1;
        }
    }

    pub fn poll(self: *Backend, devices: *[gamepad.max_devices]gamepad.Device) void {
        if (self.countdown == 0) {
            self.scan(devices);
            self.countdown = rescan_interval;
        } else {
            self.countdown -= 1;
        }

        for (&self.nodes, devices) |*node, *device| {
            if (node.fd < 0) continue;
            if (!drain(node, device)) {
                // Read failed for a reason that is not "nothing to read": the
                // device was unplugged mid-frame.
                _ = close(node.fd);
                node.* = .{};
                device.* = .{};
                continue;
            }
            if (node.follows_spec) applyKernelLayout(node, device);
        }
    }

    /// Look for controllers that are not open yet.
    fn scan(self: *Backend, devices: *[gamepad.max_devices]gamepad.Device) void {
        var path: [32]u8 = undefined;

        for (0..max_nodes) |number| {
            if (self.isOpen(@intCast(number))) continue;

            const written = std.fmt.bufPrint(&path, "/dev/input/event{d}\x00", .{number}) catch continue;
            const name: [*:0]const u8 = @ptrCast(written.ptr);

            // Non-blocking, because `poll` reads whatever has arrived and
            // returns rather than waiting for a stick to move.
            const fd = open(name, o_rdonly | o_nonblock | o_cloexec);
            if (fd < 0) continue;

            const slot = self.freeSlot() orelse {
                _ = close(fd);
                return;
            };

            if (!describe(fd, @intCast(number), &self.nodes[slot], &devices[slot])) {
                _ = close(fd);
                self.nodes[slot] = .{};
                devices[slot] = .{};
            }
        }
    }

    fn isOpen(self: *const Backend, number: u8) bool {
        for (&self.nodes) |*node| {
            if (node.fd >= 0 and node.node == number) return true;
        }
        return false;
    }

    fn freeSlot(self: *const Backend) ?usize {
        for (&self.nodes, 0..) |*node, index| {
            if (node.fd < 0) return index;
        }
        return null;
    }
};

/// Ask a freshly opened device what it is. False if it is not a controller -
/// most of `/dev/input` is keyboards, mice, lid switches and power buttons.
fn describe(fd: c_int, number: u8, node: *Node, device: *gamepad.Device) bool {
    var key_bits: [key_count / 8]u8 = @splat(0);
    var abs_bits: [abs_count / 8]u8 = @splat(0);

    if (ioctl(fd, eviocgbit(@intCast(ev_key), key_bits.len), &key_bits) < 0) return false;
    if (ioctl(fd, eviocgbit(@intCast(ev_abs), abs_bits.len), &abs_bits) < 0) return false;

    // A controller is a thing with two sticks' worth of axes and at least one
    // button in the gamepad or joystick range. A mouse has axes but no such
    // button; a keyboard has buttons but no axes.
    if (!bitSet(&abs_bits, abs_x) or !bitSet(&abs_bits, abs_y)) return false;
    var has_pad_button = false;
    for (btn_joystick..btn_dpad_right + 1) |code| {
        if (bitSet(&key_bits, code)) {
            has_pad_button = true;
            break;
        }
    }
    if (!has_pad_button) return false;

    node.* = .{ .fd = fd, .node = number };
    device.* = .{ .connected = true };

    var name_buf: [gamepad.max_name_len + 1]u8 = @splat(0);
    if (ioctl(fd, eviocgname(name_buf.len), &name_buf) >= 0) {
        const len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse name_buf.len;
        device.setName(name_buf[0..len]);
    } else device.setName("Joystick");

    var id: InputId = .{};
    if (ioctl(fd, eviocgid(), &id) >= 0) {
        device.guid = gamepad.guidFromUsb(id.bustype, id.vendor, id.product, id.version);
    }

    // Axes, hats and buttons in ascending code order, which is the order SDL
    // and every mapping file were written against.
    var raw: gamepad.Raw = .{};
    for (0..abs_count) |code| {
        if (!bitSet(&abs_bits, code)) continue;

        if (code >= abs_hat0x and code <= abs_hat3y) {
            // Hats come in pairs, and the X of each pair names it.
            if ((code - abs_hat0x) % 2 != 0) continue;
            if (raw.hat_count >= gamepad.max_hats) continue;
            node.hat_codes[raw.hat_count] = @intCast(code);
            raw.hat_count += 1;
            continue;
        }

        if (raw.axis_count >= gamepad.max_axes) continue;
        var info: AbsInfo = .{};
        if (ioctl(fd, eviocgabs(@intCast(code)), &info) < 0) continue;
        // An axis with no range cannot be normalised and is not an axis.
        if (info.maximum <= info.minimum) continue;

        node.axis_codes[raw.axis_count] = @intCast(code);
        node.axis_min[raw.axis_count] = info.minimum;
        node.axis_max[raw.axis_count] = info.maximum;
        raw.axes[raw.axis_count] = gamepad.normalize(info.value, info.minimum, info.maximum);
        raw.axis_count += 1;
    }

    for (btn_joystick..key_count) |code| {
        if (!bitSet(&key_bits, code)) continue;
        if (raw.button_count >= gamepad.max_buttons) break;
        node.button_codes[raw.button_count] = @intCast(code);
        raw.button_count += 1;
    }

    device.raw = raw;
    buildKernelLayout(node, device);
    return true;
}

/// Work out where each of the kernel's named controls ended up.
///
/// Only for a device that follows `Documentation/input/gamepad.rst`, which is
/// every driver in the tree. One that does not is left unmapped and waits for a
/// mapping file, which is the honest outcome: guessing at a flight stick's
/// layout produces a gamepad that is wrong rather than absent.
fn buildKernelLayout(node: *Node, device: *gamepad.Device) void {
    const raw = device.raw;

    const axes = [_]struct { gamepad.Axis, u16 }{
        .{ .left_x, abs_x },
        .{ .left_y, abs_y },
        .{ .right_x, abs_rx },
        .{ .right_y, abs_ry },
        .{ .left_trigger, abs_z },
        .{ .right_trigger, abs_rz },
    };
    for (axes) |entry| {
        for (node.axis_codes[0..raw.axis_count], 0..) |code, index| {
            if (code == entry[1]) {
                node.mapped_axis[@intFromEnum(entry[0])] = @intCast(index);
                break;
            }
        }
    }

    const buttons = [_]struct { gamepad.Button, u16 }{
        // By position, not by the historical alias: `BTN_NORTH` is the top
        // button, which is `Y` on an Xbox pad however it is spelled in the
        // header.
        .{ .a, btn_south },
        .{ .b, btn_east },
        .{ .x, btn_west },
        .{ .y, btn_north },
        .{ .left_bumper, btn_tl },
        .{ .right_bumper, btn_tr },
        .{ .back, btn_select },
        .{ .start, btn_start },
        .{ .guide, btn_mode },
        .{ .left_thumb, btn_thumbl },
        .{ .right_thumb, btn_thumbr },
        .{ .dpad_up, btn_dpad_up },
        .{ .dpad_right, btn_dpad_right },
        .{ .dpad_down, btn_dpad_down },
        .{ .dpad_left, btn_dpad_left },
    };
    for (buttons) |entry| {
        for (node.button_codes[0..raw.button_count], 0..) |code, index| {
            if (code == entry[1]) {
                node.mapped_button[@intFromEnum(entry[0])] = @intCast(index);
                break;
            }
        }
    }

    // Most pads report the d-pad as a hat rather than as four buttons.
    if (raw.hat_count > 0 and node.hat_codes[0] == abs_hat0x) node.dpad_hat = 0;

    // The bottom face button is the one test that matters: a device with it
    // follows the spec, and one without it is a joystick of some other shape.
    node.follows_spec = node.mapped_button[@intFromEnum(gamepad.Button.a)] != 255;
    if (node.follows_spec) applyKernelLayout(node, device);
}

fn applyKernelLayout(node: *const Node, device: *gamepad.Device) void {
    var state: gamepad.State = .{};

    for (node.mapped_axis, 0..) |index, which| {
        if (index == 255) continue;
        const axis: gamepad.Axis = @enumFromInt(which);
        const value = device.raw.axes[index];
        // A trigger rests at the bottom of its range rather than the middle, so
        // its -1 to 1 becomes 0 to 1.
        state.axes[which] = if (axis.isTrigger()) (value + 1) / 2 else value;
    }

    for (node.mapped_button, 0..) |index, which| {
        if (index == 255) continue;
        state.buttons[which] = device.raw.buttons[index];
    }

    if (node.dpad_hat != 255) {
        const hat = device.raw.hats[node.dpad_hat];
        state.buttons[@intFromEnum(gamepad.Button.dpad_up)] = hat.up;
        state.buttons[@intFromEnum(gamepad.Button.dpad_right)] = hat.right;
        state.buttons[@intFromEnum(gamepad.Button.dpad_down)] = hat.down;
        state.buttons[@intFromEnum(gamepad.Button.dpad_left)] = hat.left;
    }

    // Some pads report a trigger only as a button, and a program reading
    // `.left_trigger` should still see it go down.
    const digital = [_]struct { gamepad.Axis, u16 }{
        .{ .left_trigger, btn_tl2 },
        .{ .right_trigger, btn_tr2 },
    };
    for (digital) |entry| {
        if (node.mapped_axis[@intFromEnum(entry[0])] != 255) continue;
        for (node.button_codes[0..device.raw.button_count], 0..) |code, index| {
            if (code != entry[1]) continue;
            if (device.raw.buttons[index]) state.axes[@intFromEnum(entry[0])] = 1;
            break;
        }
    }

    device.state = state;
    device.mapped = true;
}

/// Read everything the kernel has queued for one device.
///
/// False means the device is gone. An empty queue is not that: a non-blocking
/// read with nothing in it fails with `EAGAIN`, which is the ordinary way this
/// returns and is told apart from a real failure by `errno` - without that
/// check an unplugged controller would sit in the list for the rest of the
/// program, reporting whatever it was doing when it left.
fn drain(node: *Node, device: *gamepad.Device) bool {
    var buffer: [16]InputEvent = undefined;

    while (true) {
        const bytes = read(node.fd, @ptrCast(&buffer), @sizeOf(@TypeOf(buffer)));
        if (bytes < 0) {
            const err = __errno_location().*;
            // An empty queue is where every poll ends, and a signal that
            // arrived mid-read is worth one more try. Anything else - `ENODEV`
            // above all - means the device was unplugged, and reporting that as
            // "nothing happened" would leave a controller in the list forever.
            if (err == eagain) return true;
            if (err == eintr) continue;
            return false;
        }
        if (bytes == 0) return false;

        const count: usize = @intCast(@divTrunc(bytes, @sizeOf(InputEvent)));
        for (buffer[0..count]) |ev| apply(node, device, ev);

        // A short read means the queue is empty; a full one means there may be
        // more waiting.
        if (count < buffer.len) return true;
    }
}

fn apply(node: *const Node, device: *gamepad.Device, ev: InputEvent) void {
    switch (ev.type) {
        ev_key => {
            for (node.button_codes[0..device.raw.button_count], 0..) |code, index| {
                if (code != ev.code) continue;
                // Two is a key repeat, which a button does not have: anything
                // non-zero is held.
                device.raw.buttons[index] = ev.value != 0;
                return;
            }
        },
        ev_abs => {
            for (node.hat_codes[0..device.raw.hat_count], 0..) |code, index| {
                if (ev.code == code) {
                    device.raw.hats[index].left = ev.value < 0;
                    device.raw.hats[index].right = ev.value > 0;
                    return;
                }
                if (ev.code == code + 1) {
                    device.raw.hats[index].up = ev.value < 0;
                    device.raw.hats[index].down = ev.value > 0;
                    return;
                }
            }
            for (node.axis_codes[0..device.raw.axis_count], 0..) |code, index| {
                if (code != ev.code) continue;
                device.raw.axes[index] = gamepad.normalize(
                    ev.value,
                    node.axis_min[index],
                    node.axis_max[index],
                );
                return;
            }
        },
        // `EV_SYN` ends a group of changes. Nothing here batches, so there is
        // nothing to do at the end of one.
        ev_syn => {},
        else => {},
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "the ioctl numbers are the ones evdev publishes" {
    // Checked against `linux/input.h` rather than derived from it, because a
    // wrong number here fails silently: the ioctl returns -1 and every
    // controller looks like it is not a controller.
    try testing.expectEqual(@as(c_ulong, 0x80084502), eviocgid());
    try testing.expectEqual(@as(c_ulong, 0x81004506), eviocgname(0x100));
    // `EVIOCGBIT(EV_KEY, 96)`.
    try testing.expectEqual(@as(c_ulong, 0x80604521), eviocgbit(1, 96));
    // `EVIOCGABS(ABS_X)`.
    try testing.expectEqual(@as(c_ulong, 0x80184540), eviocgabs(0));
}

test "an event struct is the size the kernel writes" {
    // 64-bit: two longs of timeval, two shorts, one int.
    if (@sizeOf(c_long) == 8) {
        try testing.expectEqual(@as(usize, 24), @sizeOf(InputEvent));
    }
    try testing.expectEqual(@as(usize, 8), @sizeOf(InputId));
    try testing.expectEqual(@as(usize, 24), @sizeOf(AbsInfo));
}

test "a bit is found in the mask the kernel fills in" {
    var bits: [16]u8 = @splat(0);
    bits[0] = 0b0000_0101;
    bits[3] = 0b1000_0000;

    try testing.expect(bitSet(&bits, 0));
    try testing.expect(!bitSet(&bits, 1));
    try testing.expect(bitSet(&bits, 2));
    try testing.expect(bitSet(&bits, 31));

    // Past the end is not set rather than a read out of bounds - the mask a
    // driver fills in can be shorter than the one asked for.
    try testing.expect(!bitSet(&bits, 1000));
}

test "the kernel's layout puts each control where a program expects it" {
    var node: Node = .{ .fd = 1 };
    var device: gamepad.Device = .{ .connected = true };

    // A pad shaped like every in-tree driver: six axes, the gamepad buttons,
    // and one hat for the d-pad.
    const codes = [_]u16{ abs_x, abs_y, abs_z, abs_rx, abs_ry, abs_rz };
    for (codes, 0..) |code, index| {
        node.axis_codes[index] = code;
        node.axis_min[index] = -32768;
        node.axis_max[index] = 32767;
    }
    const buttons = [_]u16{
        btn_south, btn_east, btn_north,  btn_west,
        btn_tl,    btn_tr,   btn_select, btn_start,
        btn_mode,  btn_thumbl, btn_thumbr,
    };
    for (buttons, 0..) |code, index| node.button_codes[index] = code;
    node.hat_codes[0] = abs_hat0x;

    device.raw = .{ .axis_count = codes.len, .button_count = buttons.len, .hat_count = 1 };
    buildKernelLayout(&node, &device);

    try testing.expect(node.follows_spec);
    try testing.expect(device.mapped);

    // The top button is `y` and the left one is `x`, whatever the header's
    // aliases say.
    device.raw.buttons[2] = true; // BTN_NORTH
    device.raw.buttons[3] = true; // BTN_WEST
    device.raw.axes[2] = 1; // ABS_Z, the left trigger, fully pulled
    // And the other one resting, which for a trigger is the bottom of its
    // range rather than the middle - a raw zero would be half pulled.
    device.raw.axes[5] = -1;
    device.raw.hats[0] = .{ .left = true };
    applyKernelLayout(&node, &device);

    try testing.expect(device.state.button(.y));
    try testing.expect(device.state.button(.x));
    try testing.expect(!device.state.button(.a));
    try testing.expectEqual(@as(f32, 1), device.state.axis(.left_trigger));
    try testing.expectEqual(@as(f32, 0), device.state.axis(.right_trigger));
    try testing.expect(device.state.button(.dpad_left));
    try testing.expect(!device.state.button(.dpad_right));
}

test "a device that does not follow the spec is left unmapped rather than guessed at" {
    var node: Node = .{ .fd = 1 };
    var device: gamepad.Device = .{ .connected = true };

    // A flight stick: axes, and buttons in the joystick range rather than the
    // gamepad one.
    node.axis_codes[0] = abs_x;
    node.axis_codes[1] = abs_y;
    node.button_codes[0] = btn_joystick;
    node.button_codes[1] = btn_joystick + 1;
    device.raw = .{ .axis_count = 2, .button_count = 2 };

    buildKernelLayout(&node, &device);
    try testing.expect(!node.follows_spec);
    try testing.expect(!device.mapped);
    // The raw values are still there, which is what a program written for a
    // flight stick reads anyway.
    try testing.expectEqual(@as(u8, 2), device.raw.axis_count);
}

test "an axis event moves the axis it names and nothing else" {
    var node: Node = .{ .fd = 1 };
    node.axis_codes[0] = abs_x;
    node.axis_codes[1] = abs_y;
    node.axis_min = @splat(0);
    node.axis_max = @splat(255);
    node.hat_codes[0] = abs_hat0x;

    var device: gamepad.Device = .{ .connected = true };
    device.raw = .{ .axis_count = 2, .hat_count = 1 };

    apply(&node, &device, .{ .sec = 0, .usec = 0, .type = ev_abs, .code = abs_y, .value = 255 });
    try testing.expectApproxEqAbs(@as(f32, 1), device.raw.axes[1], 0.01);
    try testing.expectEqual(@as(f32, 0), device.raw.axes[0]);

    // A hat's two codes are one axis each, and negative is up and left.
    apply(&node, &device, .{ .sec = 0, .usec = 0, .type = ev_abs, .code = abs_hat0x + 1, .value = -1 });
    try testing.expect(device.raw.hats[0].up);
    try testing.expect(!device.raw.hats[0].down);

    apply(&node, &device, .{ .sec = 0, .usec = 0, .type = ev_abs, .code = abs_hat0x, .value = 0 });
    try testing.expect(!device.raw.hats[0].left);
    try testing.expect(!device.raw.hats[0].right);
    // And the vertical half is untouched by the horizontal event.
    try testing.expect(device.raw.hats[0].up);
}

test "a key repeat is not a second press" {
    var node: Node = .{ .fd = 1 };
    node.button_codes[0] = btn_south;
    var device: gamepad.Device = .{ .connected = true };
    device.raw = .{ .button_count = 1 };

    apply(&node, &device, .{ .sec = 0, .usec = 0, .type = ev_key, .code = btn_south, .value = 1 });
    try testing.expect(device.raw.buttons[0]);

    // Two means "still held", which is held rather than released.
    apply(&node, &device, .{ .sec = 0, .usec = 0, .type = ev_key, .code = btn_south, .value = 2 });
    try testing.expect(device.raw.buttons[0]);

    apply(&node, &device, .{ .sec = 0, .usec = 0, .type = ev_key, .code = btn_south, .value = 0 });
    try testing.expect(!device.raw.buttons[0]);
}
