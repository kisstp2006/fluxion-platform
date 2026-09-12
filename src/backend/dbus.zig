// SPDX-License-Identifier: BSL-1.0

//! Just enough of the D-Bus wire protocol to ask the desktop portal for a
//! file: the address, the login, and messages written and read. Pure bytes -
//! the socket is `linux_dialog`'s - so all of it is checked on any host.
//!
//! A message is a fixed header, an array of header fields and a body, and
//! every value in it is aligned to its own size measured from the start of the
//! message. Getting one alignment wrong is not an error the bus reports: the
//! daemon drops the connection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Type = enum(u8) {
    method_call = 1,
    method_return = 2,
    @"error" = 3,
    signal = 4,
    _,
};

const Field = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
    _,
};

pub const Error = error{Malformed};

/// The first `unix:` address in a bus address list that this can connect to,
/// with its `%xx` escapes decoded into `buffer`.
pub const Address = union(enum) {
    path: []const u8,
    abstract: []const u8,
};

pub fn parseAddress(list: []const u8, buffer: []u8) ?Address {
    var addresses = std.mem.splitScalar(u8, list, ';');
    while (addresses.next()) |address| {
        const rest = if (std.mem.startsWith(u8, address, "unix:")) address["unix:".len..] else continue;
        var pairs = std.mem.splitScalar(u8, rest, ',');
        while (pairs.next()) |pair| {
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..equals];
            const value = unescape(pair[equals + 1 ..], buffer) orelse continue;
            if (std.mem.eql(u8, key, "path")) return .{ .path = value };
            if (std.mem.eql(u8, key, "abstract")) return .{ .abstract = value };
        }
    }
    return null;
}

fn unescape(value: []const u8, buffer: []u8) ?[]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (len += 1) {
        if (len >= buffer.len) return null;
        if (value[i] == '%') {
            if (i + 3 > value.len) return null;
            buffer[len] = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            buffer[len] = value[i];
            i += 1;
        }
    }
    return buffer[0..len];
}

/// `AUTH EXTERNAL`, which proves who is connecting by the socket's own
/// credentials. The argument is the uid as a decimal string, hex-encoded.
pub fn authLine(buffer: []u8, uid: u32) []const u8 {
    var decimal: [10]u8 = undefined;
    const digits = std.fmt.bufPrint(&decimal, "{d}", .{uid}) catch unreachable;
    var w: std.Io.Writer = .fixed(buffer);
    w.writeAll("AUTH EXTERNAL ") catch return "";
    for (digits) |digit| w.print("{x:0>2}", .{digit}) catch return "";
    w.writeAll("\r\n") catch return "";
    return w.buffered();
}

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// A method call, written little-endian from the fixed header to the end of
/// the body. `finish` fills in the body's length, which is not known until the
/// body has been written.
pub const Writer = struct {
    gpa: Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    body_start: usize = 0,

    pub const Call = struct {
        destination: ?[]const u8 = null,
        path: []const u8,
        interface: ?[]const u8 = null,
        member: []const u8,
        /// The body's signature, empty for none.
        signature: []const u8 = "",
        /// Tell the other end no answer is wanted.
        no_reply: bool = false,
    };

    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.gpa);
    }

    pub fn call(self: *Writer, serial: u32, what: Call) Allocator.Error!void {
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(self.gpa, &.{ 'l', @intFromEnum(Type.method_call), @intFromBool(what.no_reply), 1 });
        try self.uint32(0);
        try self.uint32(serial);

        const fields = try self.beginArray(8);
        try self.field(.path, "o", what.path);
        if (what.interface) |interface| try self.field(.interface, "s", interface);
        try self.field(.member, "s", what.member);
        if (what.destination) |destination| try self.field(.destination, "s", destination);
        if (what.signature.len > 0) {
            try self.pad(8);
            try self.byte(@intFromEnum(Field.signature));
            try self.signature("g");
            try self.signature(what.signature);
        }
        self.endArray(fields);
        try self.pad(8);
        self.body_start = self.bytes.items.len;
    }

    fn field(self: *Writer, code: Field, kind: []const u8, value: []const u8) Allocator.Error!void {
        try self.pad(8);
        try self.byte(@intFromEnum(code));
        try self.signature(kind);
        try self.string(value);
    }

    /// The whole message, its body's length filled in.
    pub fn finish(self: *Writer) []const u8 {
        const body: u32 = @intCast(self.bytes.items.len - self.body_start);
        std.mem.writeInt(u32, self.bytes.items[4..8], body, .little);
        return self.bytes.items;
    }

    fn pad(self: *Writer, alignment: usize) Allocator.Error!void {
        while (self.bytes.items.len % alignment != 0) try self.bytes.append(self.gpa, 0);
    }

    pub fn byte(self: *Writer, value: u8) Allocator.Error!void {
        try self.bytes.append(self.gpa, value);
    }

    pub fn boolean(self: *Writer, value: bool) Allocator.Error!void {
        try self.uint32(@intFromBool(value));
    }

    pub fn uint32(self: *Writer, value: u32) Allocator.Error!void {
        try self.pad(4);
        var raw: [4]u8 = undefined;
        std.mem.writeInt(u32, &raw, value, .little);
        try self.bytes.appendSlice(self.gpa, &raw);
    }

    /// A string or an object path, which are written the same way.
    pub fn string(self: *Writer, value: []const u8) Allocator.Error!void {
        try self.uint32(@intCast(value.len));
        try self.bytes.appendSlice(self.gpa, value);
        try self.bytes.append(self.gpa, 0);
    }

    pub fn signature(self: *Writer, value: []const u8) Allocator.Error!void {
        try self.byte(@intCast(value.len));
        try self.bytes.appendSlice(self.gpa, value);
        try self.bytes.append(self.gpa, 0);
    }

    /// `ay` from bytes, with the terminating zero the portal wants on a path.
    pub fn bytesWithZero(self: *Writer, value: []const u8) Allocator.Error!void {
        const array = try self.beginArray(1);
        try self.bytes.appendSlice(self.gpa, value);
        try self.bytes.append(self.gpa, 0);
        self.endArray(array);
    }

    pub const Array = struct { length_at: usize, start: usize };

    /// The length goes first and the padding after it is there even when the
    /// array is empty, which is the rule an empty filter list breaks easiest.
    pub fn beginArray(self: *Writer, element_alignment: usize) Allocator.Error!Array {
        try self.uint32(0);
        const length_at = self.bytes.items.len - 4;
        try self.pad(element_alignment);
        return .{ .length_at = length_at, .start = self.bytes.items.len };
    }

    pub fn endArray(self: *Writer, array: Array) void {
        const length: u32 = @intCast(self.bytes.items.len - array.start);
        std.mem.writeInt(u32, self.bytes.items[array.length_at..][0..4], length, .little);
    }

    pub fn beginStruct(self: *Writer) Allocator.Error!void {
        try self.pad(8);
    }
};

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

/// How long the message at the start of `bytes` is in total, or null while
/// its first sixteen bytes - which say so - have not all arrived.
pub fn messageLength(bytes: []const u8) Error!?usize {
    if (bytes.len < 16) return null;
    const endian = try endianOf(bytes[0]);
    const body = std.mem.readInt(u32, bytes[4..8], endian);
    const fields = std.mem.readInt(u32, bytes[12..16], endian);
    if (body > max_message or fields > max_message) return error.Malformed;
    return std.mem.alignForward(usize, 16 + fields, 8) + body;
}

/// The protocol's own ceiling on a message.
const max_message = 128 * 1024 * 1024;

fn endianOf(marker: u8) Error!std.builtin.Endian {
    return switch (marker) {
        'l' => .little,
        'B' => .big,
        else => error.Malformed,
    };
}

pub const Header = struct {
    kind: Type,
    serial: u32,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    reply_serial: u32 = 0,
    sender: []const u8 = "",
    signature: []const u8 = "",
    /// Where the body is read from.
    body: Reader,
};

/// A whole message's header, and a reader left at the start of its body.
pub fn parse(message: []const u8) Error!Header {
    var r: Reader = .{ .bytes = message, .endian = try endianOf(message[0]) };
    r.pos = 1;
    const kind: Type = @enumFromInt(try r.byte());
    _ = try r.byte();
    if (try r.byte() != 1) return error.Malformed;
    const body_len = try r.uint32();
    var header: Header = .{ .kind = kind, .serial = try r.uint32(), .body = undefined };

    const fields_len = try r.uint32();
    const fields_end = r.pos + fields_len;
    if (fields_end > message.len) return error.Malformed;
    while (r.pos < fields_end) {
        try r.alignTo(8);
        const code: Field = @enumFromInt(try r.byte());
        const kind_of = try r.signature();
        switch (code) {
            .path, .interface, .member, .error_name, .sender, .destination => {
                if (kind_of.len != 1 or (kind_of[0] != 's' and kind_of[0] != 'o')) return error.Malformed;
                const value = try r.string();
                switch (code) {
                    .path => header.path = value,
                    .interface => header.interface = value,
                    .member => header.member = value,
                    .error_name => header.error_name = value,
                    .sender => header.sender = value,
                    else => {},
                }
            },
            .reply_serial => header.reply_serial = try r.uint32(),
            .signature => header.signature = try r.signature(),
            else => try r.skip(kind_of),
        }
    }
    try r.alignTo(8);
    if (r.pos + body_len > message.len) return error.Malformed;
    header.body = .{ .bytes = message[0 .. r.pos + body_len], .pos = r.pos, .endian = r.endian };
    return header;
}

/// Values out of a message, each checked against what is left of it. Alignment
/// is from the start of the message, so a reader always holds the whole of it.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    endian: std.builtin.Endian = .little,

    pub fn done(self: *const Reader) bool {
        return self.pos >= self.bytes.len;
    }

    pub fn alignTo(self: *Reader, alignment: usize) Error!void {
        const aligned = std.mem.alignForward(usize, self.pos, alignment);
        if (aligned > self.bytes.len) return error.Malformed;
        self.pos = aligned;
    }

    fn take(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.bytes.len - self.pos) return error.Malformed;
        defer self.pos += count;
        return self.bytes[self.pos..][0..count];
    }

    pub fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    pub fn uint32(self: *Reader) Error!u32 {
        try self.alignTo(4);
        return std.mem.readInt(u32, (try self.take(4))[0..4], self.endian);
    }

    pub fn boolean(self: *Reader) Error!bool {
        return try self.uint32() != 0;
    }

    /// A string or an object path, without its terminating zero.
    pub fn string(self: *Reader) Error![]const u8 {
        const len = try self.uint32();
        const value = try self.take(@as(usize, len) + 1);
        if (value[len] != 0) return error.Malformed;
        return value[0..len];
    }

    pub fn signature(self: *Reader) Error![]const u8 {
        const len = try self.byte();
        const value = try self.take(@as(usize, len) + 1);
        if (value[len] != 0) return error.Malformed;
        return value[0..len];
    }

    /// The end of an array whose length has just been read, and the reader
    /// moved to its first element.
    pub fn beginArray(self: *Reader, element: []const u8) Error!usize {
        const len = try self.uint32();
        try self.alignTo(try alignmentOf(element));
        if (len > self.bytes.len - self.pos) return error.Malformed;
        return self.pos + len;
    }

    /// Step over one value of the complete type at the start of `kind`.
    pub fn skip(self: *Reader, kind: []const u8) Error!void {
        if (kind.len == 0) return error.Malformed;
        switch (kind[0]) {
            'y' => _ = try self.take(1),
            'n', 'q' => {
                try self.alignTo(2);
                _ = try self.take(2);
            },
            'b', 'i', 'u', 'h' => _ = try self.uint32(),
            'x', 't', 'd' => {
                try self.alignTo(8);
                _ = try self.take(8);
            },
            's', 'o' => _ = try self.string(),
            'g' => _ = try self.signature(),
            'v' => try self.skip(try self.signature()),
            'a' => {
                const end = try self.beginArray(kind[1..]);
                self.pos = end;
            },
            '(', '{' => {
                try self.alignTo(8);
                var inner = kind[1 .. try completeLength(kind) - 1];
                while (inner.len > 0) {
                    const len = try completeLength(inner);
                    try self.skip(inner[0..len]);
                    inner = inner[len..];
                }
            },
            else => return error.Malformed,
        }
    }
};

/// How long the complete type at the start of `kind` is: one letter, an array
/// and what it holds, or a bracketed struct or dictionary entry.
pub fn completeLength(kind: []const u8) Error!usize {
    if (kind.len == 0) return error.Malformed;
    switch (kind[0]) {
        'a' => return 1 + try completeLength(kind[1..]),
        '(', '{' => {
            const close: u8 = if (kind[0] == '(') ')' else '}';
            var at: usize = 1;
            while (at < kind.len and kind[at] != close) at += try completeLength(kind[at..]);
            if (at >= kind.len) return error.Malformed;
            return at + 1;
        },
        else => return 1,
    }
}

fn alignmentOf(kind: []const u8) Error!usize {
    if (kind.len == 0) return error.Malformed;
    return switch (kind[0]) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => error.Malformed,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the address is the first unix socket in the list, unescaped" {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("/run/user/1000/bus", parseAddress("unix:path=/run/user/1000/bus", &buffer).?.path);
    try testing.expectEqualStrings("/tmp/dbus-x y", parseAddress("tcp:host=a,port=1;unix:abstract=/tmp/dbus-x%20y,guid=00ff", &buffer).?.abstract);
    try testing.expectEqual(@as(?Address, null), parseAddress("tcp:host=localhost,port=4", &buffer));
    try testing.expectEqual(@as(?Address, null), parseAddress("unix:path=%zz", &buffer));
}

test "the login names the uid as hex digits of its decimal form" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("AUTH EXTERNAL 31303030\r\n", authLine(&buffer, 1000));
    try testing.expectEqualStrings("AUTH EXTERNAL 30\r\n", authLine(&buffer, 0));
}

test "a method call is laid out byte for byte as the specification writes it" {
    var w: Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    try w.call(1, .{
        .destination = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "Hello",
    });
    const message = w.finish();

    try testing.expectEqualSlices(u8, &.{ 'l', 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0 }, message[0..12]);
    try testing.expectEqual(@as(usize, 0), message.len % 8);
    try testing.expectEqual(@as(?usize, message.len), try messageLength(message));

    const header = try parse(message);
    try testing.expectEqual(Type.method_call, header.kind);
    try testing.expectEqual(@as(u32, 1), header.serial);
    try testing.expectEqualStrings("/org/freedesktop/DBus", header.path);
    try testing.expectEqualStrings("org.freedesktop.DBus", header.interface);
    try testing.expectEqualStrings("Hello", header.member);
    try testing.expectEqualStrings("", header.signature);
    try testing.expect(header.body.done());
}

test "a body round-trips through the writer and the reader, alignment and all" {
    var w: Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    try w.call(7, .{ .path = "/p", .member = "M", .signature = "sa{sv}ay" });
    try w.string("parent");
    const dict = try w.beginArray(8);
    try w.beginStruct();
    try w.string("multiple");
    try w.signature("b");
    try w.boolean(true);
    try w.beginStruct();
    try w.string("filters");
    try w.signature("a(sa(us))");
    const filters = try w.beginArray(8);
    try w.beginStruct();
    try w.string("Images");
    const patterns = try w.beginArray(8);
    try w.beginStruct();
    try w.uint32(0);
    try w.string("*.png");
    w.endArray(patterns);
    w.endArray(filters);
    w.endArray(dict);
    try w.bytesWithZero("/home");
    const message = w.finish();

    const header = try parse(message);
    try testing.expectEqualStrings("sa{sv}ay", header.signature);
    var r = header.body;
    try testing.expectEqualStrings("parent", try r.string());
    const end = try r.beginArray("{sv}");
    try r.alignTo(8);
    try testing.expectEqualStrings("multiple", try r.string());
    try testing.expectEqualStrings("b", try r.signature());
    try testing.expect(try r.boolean());
    try r.alignTo(8);
    try testing.expectEqualStrings("filters", try r.string());
    try r.skip(try r.signature());
    try testing.expectEqual(end, r.pos);
    const bytes_end = try r.beginArray("y");
    try testing.expectEqualStrings("/home\x00", r.bytes[r.pos..bytes_end]);
    r.pos = bytes_end;
    try testing.expect(r.done());
}

test "an empty array still pads to its element's alignment" {
    var w: Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    try w.call(2, .{ .path = "/p", .member = "M", .signature = "a(us)y" });
    const start = w.bytes.items.len;
    const array = try w.beginArray(8);
    w.endArray(array);
    try w.byte(1);
    try testing.expectEqual(@as(usize, 9), w.bytes.items.len - start);
    var header = try parse(w.finish());
    try header.body.skip("a(us)");
    try testing.expectEqual(@as(u8, 1), try header.body.byte());
    try testing.expect(header.body.done());
}

test "a type's complete length follows arrays, structs and dictionaries" {
    try testing.expectEqual(@as(usize, 1), try completeLength("s"));
    try testing.expectEqual(@as(usize, 5), try completeLength("a{sv}x"));
    try testing.expectEqual(@as(usize, 9), try completeLength("a(sa(us))"));
    try testing.expectError(error.Malformed, completeLength("a(s"));
}

test "a truncated or foreign message is refused, not read past" {
    var w: Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    try w.call(3, .{ .path = "/p", .member = "M", .signature = "s" });
    try w.string("hello");
    const message = w.finish();

    try testing.expectEqual(@as(?usize, null), try messageLength(message[0..10]));
    try testing.expectError(error.Malformed, parse(message[0 .. message.len - 3]));
    const copy = try testing.allocator.dupe(u8, message);
    defer testing.allocator.free(copy);
    copy[0] = 'x';
    try testing.expectError(error.Malformed, messageLength(copy));
}
