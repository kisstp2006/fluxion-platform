// SPDX-License-Identifier: BSL-1.0

//! Gamepads and joysticks: what is plugged in, what it is doing, and how to
//! read a device nobody has heard of.
//!
//! Two layers, because a joystick and a gamepad are not the same thing. A
//! joystick is whatever the driver says it is - some number of axes, some
//! number of buttons, some hats - and a program that reads one has to know
//! which axis is which. A gamepad is a joystick that has been *mapped*: axis 3
//! is the right stick's X, button 0 is the bottom face button, and a program
//! can be written once for every controller rather than once per controller.
//!
//! **The mapping is the whole problem.** Every controller reports its buttons
//! in whatever order its firmware felt like, so the same physical button is
//! number 0 on one pad and number 2 on the next. SDL solved this by collecting
//! a database of them; `Mapping.parse` reads that format, so the community's
//! file works here.
//!
//! Most controllers never need one. Windows reports an XInput pad in the Xbox
//! layout because that is what XInput is, the Linux kernel normalises anything
//! that follows its gamepad spec, and Android hands over `AKEYCODE_BUTTON_A`
//! and friends. A mapping is for the device that does none of that.
//!
//! **Nothing here is an event.** A gamepad is polled: a program reads the whole
//! state each frame and compares it to the last one, because that is what a
//! stick is - a position, not a thing that happened. Connection and
//! disconnection do arrive as events, because those genuinely are.

const std = @import("std");
const testing = std.testing;

/// How many devices this library will track at once. GLFW's number, and more
/// than any machine has.
pub const max_devices = 16;

/// Inline limits, so a device is a value with nothing to free. A controller
/// with more axes than this reports the first `max_axes` of them.
pub const max_axes = 8;
pub const max_buttons = 32;
pub const max_hats = 4;
pub const max_name_len = 63;

/// One of the fifteen buttons a mapped gamepad has, at GLFW's numbers.
///
/// Named by position, not by letter. `.a` is the bottom face button wherever it
/// is and whatever is printed on it: it is `A` on an Xbox pad, cross on a
/// PlayStation one, and `B` on a Nintendo one, because Nintendo swapped them.
/// A program that means "the button under the thumb" should say `.a`; one that
/// wants to print a letter should ask the device what it is called.
pub const Button = enum(u8) {
    a = 0,
    b = 1,
    x = 2,
    y = 3,
    left_bumper = 4,
    right_bumper = 5,
    back = 6,
    start = 7,
    /// The one in the middle with the logo on it. Not every pad has it, and on
    /// some platforms the system keeps it for itself.
    guide = 8,
    /// Pressing the stick in.
    left_thumb = 9,
    right_thumb = 10,
    dpad_up = 11,
    dpad_right = 12,
    dpad_down = 13,
    dpad_left = 14,

    pub const count = 15;

    /// The name SDL's mapping database uses for it, which is what
    /// `Mapping.parse` reads.
    pub fn sdlName(self: Button) []const u8 {
        return switch (self) {
            .a => "a",
            .b => "b",
            .x => "x",
            .y => "y",
            .left_bumper => "leftshoulder",
            .right_bumper => "rightshoulder",
            .back => "back",
            .start => "start",
            .guide => "guide",
            .left_thumb => "leftstick",
            .right_thumb => "rightstick",
            .dpad_up => "dpup",
            .dpad_right => "dpright",
            .dpad_down => "dpdown",
            .dpad_left => "dpleft",
        };
    }
};

/// One of the six axes a mapped gamepad has, at GLFW's numbers.
pub const Axis = enum(u8) {
    left_x = 0,
    left_y = 1,
    right_x = 2,
    right_y = 3,
    left_trigger = 4,
    right_trigger = 5,

    pub const count = 6;

    pub fn sdlName(self: Axis) []const u8 {
        return switch (self) {
            .left_x => "leftx",
            .left_y => "lefty",
            .right_x => "rightx",
            .right_y => "righty",
            .left_trigger => "lefttrigger",
            .right_trigger => "righttrigger",
        };
    }

    /// True for the two that rest at zero rather than in the middle.
    ///
    /// A stick reads -1 to 1 and sits at 0; a trigger reads 0 to 1 and sits at
    /// 0 as well, but a *raw* trigger axis usually rests at -1, so the two are
    /// converted differently. Everything that has to know asks here.
    pub fn isTrigger(self: Axis) bool {
        return self == .left_trigger or self == .right_trigger;
    }
};

/// Which way a hat switch is pushed. The four bits combine: up and right at
/// once is the diagonal.
pub const Hat = packed struct(u8) {
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,
    _padding: u4 = 0,

    pub const centered: Hat = .{};

    pub fn isCentered(self: Hat) bool {
        return !self.up and !self.right and !self.down and !self.left;
    }

    /// The four bits as SDL and GLFW number them, which is what a hat mapping
    /// like `h0.4` means.
    pub fn bits(self: Hat) u4 {
        var value: u4 = 0;
        if (self.up) value |= 1;
        if (self.right) value |= 2;
        if (self.down) value |= 4;
        if (self.left) value |= 8;
        return value;
    }

    pub fn fromBits(value: u4) Hat {
        return .{
            .up = (value & 1) != 0,
            .right = (value & 2) != 0,
            .down = (value & 4) != 0,
            .left = (value & 8) != 0,
        };
    }
};

/// What a mapped gamepad is doing right now.
pub const State = struct {
    axes: [Axis.count]f32 = @splat(0),
    buttons: [Button.count]bool = @splat(false),

    pub fn button(self: State, which: Button) bool {
        return self.buttons[@intFromEnum(which)];
    }

    pub fn axis(self: State, which: Axis) f32 {
        return self.axes[@intFromEnum(which)];
    }

    /// The axis with anything smaller than `dead` treated as nothing.
    ///
    /// A stick that has been used for a year does not come back to exactly
    /// zero, and a camera driven by the raw value drifts. This is the fix, and
    /// it belongs to the caller rather than the driver because how much drift
    /// is acceptable depends on what the stick is steering.
    pub fn axisDeadzone(self: State, which: Axis, dead: f32) f32 {
        const value = self.axis(which);
        if (@abs(value) <= dead) return 0;
        // Rescaled rather than clipped, so the first movement past the deadzone
        // is a small one and not a jump.
        const sign: f32 = if (value < 0) -1 else 1;
        return sign * (@abs(value) - dead) / (1 - dead);
    }
};

/// What a device reports before anything has been mapped.
pub const Raw = struct {
    axis_count: u8 = 0,
    button_count: u8 = 0,
    hat_count: u8 = 0,

    /// Each in -1 to 1, whatever the driver's own range was.
    axes: [max_axes]f32 = @splat(0),
    buttons: [max_buttons]bool = @splat(false),
    hats: [max_hats]Hat = @splat(.{}),
};

/// One joystick or gamepad.
pub const Device = struct {
    /// False for a slot nothing is plugged into. Every other field is
    /// meaningless then.
    connected: bool = false,

    name_buf: [max_name_len + 1]u8 = @splat(0),
    name_len: u8 = 0,

    /// SDL's device identifier: 32 hex characters built from the USB vendor and
    /// product ids and the driver's own signature. What a mapping is looked up
    /// by, and all zeroes where the backend cannot build one.
    guid: [32]u8 = @splat('0'),

    raw: Raw = .{},

    /// The mapped state, and whether there was anything to map it with. False
    /// means this is a joystick that nothing knows the layout of - the raw
    /// values are still there and still true.
    state: State = .{},
    mapped: bool = false,

    pub fn name(self: *const Device) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *Device, text: []const u8) void {
        const len = @min(text.len, max_name_len);
        @memcpy(self.name_buf[0..len], text[0..len]);
        self.name_buf[len] = 0;
        self.name_len = @intCast(len);
    }

    pub fn format(self: Device, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!self.connected) return w.writeAll("(nothing)");
        try w.print("{s} ({d} axes, {d} buttons, {d} hats)", .{
            self.name(),
            self.raw.axis_count,
            self.raw.button_count,
            self.raw.hat_count,
        });
        if (!self.mapped) try w.writeAll(" unmapped");
    }
};

// -------------------------------------------------------------------------
// Mappings
// -------------------------------------------------------------------------

/// Where one gamepad control gets its value from.
pub const Source = struct {
    kind: enum { none, button, axis, hat } = .none,
    index: u8 = 0,
    /// For an axis: which half of it counts. `+a2` and `-a2` let one axis drive
    /// two different controls, which is how a pad with a single trigger axis is
    /// described.
    half: enum { whole, positive, negative } = .whole,
    /// For an axis: the value is negated. Written `~` in the mapping.
    inverted: bool = false,
    /// For a hat: which of the four bits.
    hat_mask: u4 = 0,
};

/// One controller's layout, in SDL's `gamecontrollerdb.txt` format.
///
/// A line looks like:
///
/// ```text
/// 030000005e040000e002000000007801,Xbox One Wireless,a:b0,b:b1,leftx:a0,dpup:h0.1,platform:Linux,
/// ```
///
/// The first field is the device's GUID, the second is a name for a person, and
/// the rest say where each control comes from: `bN` a button, `aN` an axis
/// (with an optional `+`/`-` in front for half of one and `~` after it for an
/// inverted one), `hN.M` one bit of a hat.
pub const Mapping = struct {
    guid: [32]u8 = @splat('0'),
    name_buf: [max_name_len + 1]u8 = @splat(0),
    name_len: u8 = 0,

    buttons: [Button.count]Source = @splat(.{}),
    axes: [Axis.count]Source = @splat(.{}),

    pub fn name(self: *const Mapping) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub const ParseError = error{
        /// Not enough fields to be a mapping line at all.
        Malformed,
        /// The GUID is not 32 characters.
        BadGuid,
    };

    /// Read one line. Blank lines and `#` comments are not this function's
    /// business - `Store.load` skips those.
    pub fn parse(line: []const u8) ParseError!Mapping {
        var self: Mapping = .{};
        var fields = std.mem.splitScalar(u8, line, ',');

        const guid = std.mem.trim(u8, fields.next() orelse return error.Malformed, " \t\r");
        if (guid.len != 32) return error.BadGuid;
        @memcpy(&self.guid, guid);

        const label = fields.next() orelse return error.Malformed;
        const len = @min(label.len, max_name_len);
        @memcpy(self.name_buf[0..len], label[0..len]);
        self.name_len = @intCast(len);

        while (fields.next()) |field| {
            const trimmed = std.mem.trim(u8, field, " \t\r");
            if (trimmed.len == 0) continue;

            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const key = trimmed[0..colon];
            const value = trimmed[colon + 1 ..];

            // `platform:`, `crc:`, `hint:` and the rest are for SDL. A mapping
            // for the wrong platform is filtered by whoever loaded the file;
            // an unknown key is skipped rather than refused, because the format
            // grows and an old parser should keep working.
            if (findButton(key)) |which| {
                self.buttons[@intFromEnum(which)] = parseSource(value) orelse continue;
            } else if (findAxis(key)) |which| {
                self.axes[@intFromEnum(which)] = parseSource(value) orelse continue;
            }
        }

        return self;
    }

    fn findButton(key: []const u8) ?Button {
        inline for (comptime std.enums.values(Button)) |which| {
            if (std.mem.eql(u8, key, comptime which.sdlName())) return which;
        }
        return null;
    }

    fn findAxis(key: []const u8) ?Axis {
        inline for (comptime std.enums.values(Axis)) |which| {
            if (std.mem.eql(u8, key, comptime which.sdlName())) return which;
        }
        return null;
    }

    fn parseSource(text: []const u8) ?Source {
        if (text.len < 2) return null;
        var rest = text;
        var source: Source = .{};

        switch (rest[0]) {
            '+' => {
                source.half = .positive;
                rest = rest[1..];
            },
            '-' => {
                source.half = .negative;
                rest = rest[1..];
            },
            else => {},
        }
        if (rest.len == 0) return null;

        if (std.mem.endsWith(u8, rest, "~")) {
            source.inverted = true;
            rest = rest[0 .. rest.len - 1];
        }
        if (rest.len < 2) return null;

        switch (rest[0]) {
            'b' => {
                source.kind = .button;
                source.index = std.fmt.parseInt(u8, rest[1..], 10) catch return null;
            },
            'a' => {
                source.kind = .axis;
                source.index = std.fmt.parseInt(u8, rest[1..], 10) catch return null;
            },
            'h' => {
                // `h0.4`: hat zero, the bit meaning down.
                const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
                source.kind = .hat;
                source.index = std.fmt.parseInt(u8, rest[1..dot], 10) catch return null;
                const mask = std.fmt.parseInt(u8, rest[dot + 1 ..], 10) catch return null;
                source.hat_mask = @truncate(mask);
            },
            else => return null,
        }
        return source;
    }

    /// Turn what a device reported into what a gamepad is doing.
    pub fn apply(self: *const Mapping, raw: Raw) State {
        var state: State = .{};

        for (self.buttons, 0..) |source, index| {
            state.buttons[index] = readButton(source, raw);
        }
        for (self.axes, 0..) |source, index| {
            const which: Axis = @enumFromInt(index);
            state.axes[index] = readAxis(source, raw, which);
        }
        return state;
    }

    fn readButton(source: Source, raw: Raw) bool {
        return switch (source.kind) {
            .none => false,
            .button => source.index < raw.button_count and raw.buttons[source.index],
            // A button driven by an axis is pressed past the middle. Half a
            // trigger pull is not a press.
            .axis => blk: {
                if (source.index >= raw.axis_count) break :blk false;
                const value = raw.axes[source.index];
                break :blk switch (source.half) {
                    .whole => value > 0,
                    .positive => value > 0,
                    .negative => value < 0,
                };
            },
            .hat => source.index < raw.hat_count and
                (raw.hats[source.index].bits() & source.hat_mask) != 0,
        };
    }

    fn readAxis(source: Source, raw: Raw, which: Axis) f32 {
        const value: f32 = switch (source.kind) {
            .none => return 0,
            .axis => blk: {
                if (source.index >= raw.axis_count) return 0;
                const raw_value = raw.axes[source.index];
                break :blk switch (source.half) {
                    .whole => raw_value,
                    // Half an axis, rescaled to the whole of one: `+a2` means
                    // "zero when a2 is at or below the middle, one at the top".
                    .positive => @max(0, raw_value) * 2 - 1,
                    .negative => @max(0, -raw_value) * 2 - 1,
                };
            },
            // A button standing in for an axis is all or nothing, which is what
            // a pad with digital triggers gives.
            .button => if (source.index < raw.button_count and raw.buttons[source.index]) 1 else -1,
            .hat => if (source.index < raw.hat_count and
                (raw.hats[source.index].bits() & source.hat_mask) != 0) 1 else -1,
        };

        const signed = if (source.inverted) -value else value;
        // A trigger reads zero to one, and everything above reads minus one to
        // one, so the last step is where the two ranges meet.
        if (which.isTrigger()) return (signed + 1) / 2;
        return std.math.clamp(signed, -1, 1);
    }
};

/// Every mapping a program has loaded, looked up by GUID.
///
/// Empty to begin with, and that is not a problem for most controllers: the
/// backends here report an XInput pad, a kernel-normalised evdev pad and an
/// Android gamepad already mapped, because those systems have done the work.
/// This is for the device none of them recognise, and for a program that wants
/// to ship SDL's database.
pub const Store = struct {
    list: std.ArrayListUnmanaged(Mapping) = .empty,

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
    }

    /// Read a whole `gamecontrollerdb.txt`. Blank lines, comments and lines for
    /// another platform are skipped; a line that will not parse is skipped too,
    /// because one bad entry in a community file should not stop the rest.
    ///
    /// Returns how many were taken.
    pub fn load(self: *Store, gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!usize {
        var taken: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (!isForThisPlatform(trimmed)) continue;

            const mapping = Mapping.parse(trimmed) catch continue;
            try self.add(gpa, mapping);
            taken += 1;
        }
        return taken;
    }

    /// Add one, replacing any earlier mapping for the same device.
    pub fn add(self: *Store, gpa: std.mem.Allocator, mapping: Mapping) std.mem.Allocator.Error!void {
        for (self.list.items) |*existing| {
            if (std.mem.eql(u8, &existing.guid, &mapping.guid)) {
                existing.* = mapping;
                return;
            }
        }
        try self.list.append(gpa, mapping);
    }

    pub fn find(self: *const Store, guid: [32]u8) ?*const Mapping {
        for (self.list.items) |*mapping| {
            if (std.mem.eql(u8, &mapping.guid, &guid)) return mapping;
        }
        return null;
    }

    /// SDL's file carries every platform's mappings in one list, so the ones
    /// for other systems are left where they are.
    fn isForThisPlatform(line: []const u8) bool {
        const marker = "platform:";
        const at = std.mem.indexOf(u8, line, marker) orelse return true;
        const rest = line[at + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        const named = std.mem.trim(u8, rest[0..end], " \t\r");

        const ours = switch (@import("builtin").os.tag) {
            .windows => "Windows",
            .linux => "Linux",
            .macos => "Mac OS X",
            else => return true,
        };
        return std.mem.eql(u8, named, ours);
    }
};

/// Build SDL's 32-character GUID from what a USB device says about itself.
///
/// The layout is SDL's: a bus type, then vendor, product and version, each as
/// a little-endian 16-bit value written out in hex, with a zero between each.
/// Getting it wrong means the community's database never matches, so it is
/// worth doing exactly.
pub fn guidFromUsb(bus: u16, vendor: u16, product: u16, version: u16) [32]u8 {
    var out: [32]u8 = @splat('0');
    writeLe16(out[0..4], bus);
    writeLe16(out[8..12], vendor);
    writeLe16(out[16..20], product);
    writeLe16(out[24..28], version);
    return out;
}

fn writeLe16(out: *[4]u8, value: u16) void {
    const hex = "0123456789abcdef";
    const low: u8 = @truncate(value);
    const high: u8 = @truncate(value >> 8);
    out[0] = hex[low >> 4];
    out[1] = hex[low & 0xf];
    out[2] = hex[high >> 4];
    out[3] = hex[high & 0xf];
}

/// Turn a driver's own integer range into the -1 to 1 everything here uses.
pub fn normalize(value: i32, minimum: i32, maximum: i32) f32 {
    if (maximum <= minimum) return 0;
    const span: f32 = @floatFromInt(maximum - minimum);
    const offset: f32 = @floatFromInt(value - minimum);
    return std.math.clamp(offset / span * 2 - 1, -1, 1);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a mapping line is read field by field" {
    const line = "030000005e040000e002000000007801,Xbox Wireless Controller," ++
        "a:b0,b:b1,x:b2,y:b3,leftshoulder:b4,rightshoulder:b5,back:b6,start:b7," ++
        "leftstick:b8,rightstick:b9,leftx:a0,lefty:a1,rightx:a2,righty:a3," ++
        "lefttrigger:a4,righttrigger:a5,dpup:h0.1,dpright:h0.2,dpdown:h0.4,dpleft:h0.8,platform:Linux,";

    const mapping = try Mapping.parse(line);
    try testing.expectEqualStrings("Xbox Wireless Controller", mapping.name());
    try testing.expectEqualStrings("030000005e040000e002000000007801", &mapping.guid);

    const a = mapping.buttons[@intFromEnum(Button.a)];
    try testing.expectEqual(.button, a.kind);
    try testing.expectEqual(@as(u8, 0), a.index);

    const up = mapping.buttons[@intFromEnum(Button.dpad_up)];
    try testing.expectEqual(@as(u8, 0), up.index);
    try testing.expectEqual(@as(u4, 1), up.hat_mask);

    const left_x = mapping.axes[@intFromEnum(Axis.left_x)];
    try testing.expectEqual(@as(u8, 0), left_x.index);
}

test "an axis source can be half of one, or inverted, or both" {
    const line = "00000000000000000000000000000000,Odd," ++
        "lefttrigger:+a2,righttrigger:-a2,lefty:a1~,";
    const mapping = try Mapping.parse(line);

    const left = mapping.axes[@intFromEnum(Axis.left_trigger)];
    try testing.expectEqual(@as(u8, 2), left.index);
    try testing.expect(!left.inverted);

    const right = mapping.axes[@intFromEnum(Axis.right_trigger)];
    try testing.expectEqual(@as(u8, 2), right.index);

    const y = mapping.axes[@intFromEnum(Axis.left_y)];
    try testing.expect(y.inverted);
}

test "a line with no guid is refused rather than half read" {
    try testing.expectError(error.BadGuid, Mapping.parse("short,Name,a:b0,"));
    try testing.expectError(error.Malformed, Mapping.parse("00000000000000000000000000000000"));
}

test "applying a mapping puts each control where the program expects it" {
    const line = "00000000000000000000000000000000,Test," ++
        "a:b2,b:b0,leftx:a1,lefty:a0~,lefttrigger:a3,dpup:h0.1,dpdown:h0.4,";
    const mapping = try Mapping.parse(line);

    var raw: Raw = .{ .axis_count = 4, .button_count = 4, .hat_count = 1 };
    raw.buttons[2] = true;
    raw.axes[0] = 0.5;
    raw.axes[1] = -0.25;
    raw.axes[3] = 1;
    raw.hats[0] = .{ .up = true };

    const state = mapping.apply(raw);

    // The pad's button 2 is the gamepad's `a`, and its button 0 is not pressed.
    try testing.expect(state.button(.a));
    try testing.expect(!state.button(.b));

    try testing.expectApproxEqAbs(@as(f32, -0.25), state.axis(.left_x), 0.001);
    // Inverted, so the stick's 0.5 reads as -0.5.
    try testing.expectApproxEqAbs(@as(f32, -0.5), state.axis(.left_y), 0.001);
    // A trigger's raw -1 to 1 becomes 0 to 1, so a raw 1 is fully pulled.
    try testing.expectApproxEqAbs(@as(f32, 1), state.axis(.left_trigger), 0.001);

    try testing.expect(state.button(.dpad_up));
    try testing.expect(!state.button(.dpad_down));
}

test "a control that reads past the end of the device is zero, not rubbish" {
    const line = "00000000000000000000000000000000,Test,a:b9,leftx:a7,dpup:h3.1,";
    const mapping = try Mapping.parse(line);

    // A device with two buttons and one axis, mapped by a line that expects
    // ten. Nothing here may read past what the device reported.
    const raw: Raw = .{ .axis_count = 1, .button_count = 2, .hat_count = 0 };
    const state = mapping.apply(raw);

    try testing.expect(!state.button(.a));
    try testing.expectEqual(@as(f32, 0), state.axis(.left_x));
    try testing.expect(!state.button(.dpad_up));
}

test "the store keeps one mapping per device and finds it by guid" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const first = try Mapping.parse("0000000000000000000000000000000a,First,a:b0,");
    const second = try Mapping.parse("0000000000000000000000000000000b,Second,a:b1,");
    try store.add(testing.allocator, first);
    try store.add(testing.allocator, second);
    try testing.expectEqual(@as(usize, 2), store.list.items.len);

    // The same device again replaces rather than piles up, so a program can
    // load its own file over the shipped one.
    const replacement = try Mapping.parse("0000000000000000000000000000000a,Better,a:b3,");
    try store.add(testing.allocator, replacement);
    try testing.expectEqual(@as(usize, 2), store.list.items.len);

    const found = store.find(first.guid) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Better", found.name());

    try testing.expectEqual(
        @as(?*const Mapping, null),
        store.find(@splat('f')),
    );
}

test "loading a database skips comments, blanks and other platforms" {
    const text =
        \\# a comment
        \\
        \\0000000000000000000000000000000a,Ours,a:b0,platform:Windows,
        \\0000000000000000000000000000000b,Theirs,a:b0,platform:Mac OS X,
        \\0000000000000000000000000000000c,Linux one,a:b0,platform:Linux,
        \\not a mapping at all
        \\0000000000000000000000000000000d,No platform named,a:b0,
    ;

    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const taken = try store.load(testing.allocator, text);

    // One for this platform plus the one that names none, whichever platform
    // this is compiled for.
    try testing.expectEqual(@as(usize, 2), taken);
    try testing.expect(store.find(@splat('0')) == null);
}

test "hat bits and the four directions agree in both directions" {
    try testing.expect(Hat.centered.isCentered());
    try testing.expectEqual(@as(u4, 0), Hat.centered.bits());

    const up_right: Hat = .{ .up = true, .right = true };
    try testing.expectEqual(@as(u4, 3), up_right.bits());
    try testing.expect(!up_right.isCentered());

    for (0..16) |value| {
        const bits: u4 = @intCast(value);
        try testing.expectEqual(bits, Hat.fromBits(bits).bits());
    }
}

test "a deadzone removes drift without making the first movement a jump" {
    var state: State = .{};

    state.axes[@intFromEnum(Axis.left_x)] = 0.05;
    try testing.expectEqual(@as(f32, 0), state.axisDeadzone(.left_x, 0.1));

    // Just past the edge is a small number, not a sudden 0.15.
    state.axes[@intFromEnum(Axis.left_x)] = 0.15;
    try testing.expect(state.axisDeadzone(.left_x, 0.1) < 0.1);

    // And the far end is still the far end.
    state.axes[@intFromEnum(Axis.left_x)] = -1;
    try testing.expectApproxEqAbs(@as(f32, -1), state.axisDeadzone(.left_x, 0.1), 0.001);
}

test "a guid is built the way SDL builds one" {
    // Little-endian halves, each written out in hex, with a zero between them.
    const guid = guidFromUsb(3, 0x045e, 0x02e0, 0x0178);
    try testing.expectEqualStrings("030000005e040000e002000078010000", &guid);
}

test "a driver's range becomes minus one to one" {
    try testing.expectApproxEqAbs(@as(f32, -1), normalize(0, 0, 255), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), normalize(255, 0, 255), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), normalize(128, 0, 256), 0.01);

    // A driver that reports a broken range gets zero rather than a division by
    // nothing.
    try testing.expectEqual(@as(f32, 0), normalize(5, 10, 10));
}

test "the button and axis names are the ones the database uses" {
    try testing.expectEqualStrings("a", Button.a.sdlName());
    try testing.expectEqualStrings("leftshoulder", Button.left_bumper.sdlName());
    try testing.expectEqualStrings("dpup", Button.dpad_up.sdlName());
    try testing.expectEqualStrings("righttrigger", Axis.right_trigger.sdlName());

    // No two share one, or a mapping line would set the same control twice.
    const buttons = comptime std.enums.values(Button);
    inline for (buttons, 0..) |a, i| {
        inline for (buttons, 0..) |b, j| {
            if (i != j) try testing.expect(!std.mem.eql(u8, a.sdlName(), b.sdlName()));
        }
    }
}

test "an unconnected device says so rather than printing rubbish" {
    var buf: [128]u8 = undefined;
    const empty: Device = .{};
    try testing.expectEqualStrings("(nothing)", try std.fmt.bufPrint(&buf, "{f}", .{empty}));

    var pad: Device = .{ .connected = true, .mapped = true };
    pad.setName("Wireless Controller");
    pad.raw = .{ .axis_count = 6, .button_count = 15, .hat_count = 1 };
    try testing.expectEqualStrings(
        "Wireless Controller (6 axes, 15 buttons, 1 hats)",
        try std.fmt.bufPrint(&buf, "{f}", .{pad}),
    );

    pad.mapped = false;
    try testing.expect(std.mem.endsWith(
        u8,
        try std.fmt.bufPrint(&buf, "{f}", .{pad}),
        "unmapped",
    ));
}
