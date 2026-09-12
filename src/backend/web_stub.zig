// SPDX-License-Identifier: BSL-1.0

//! A page that is not there, so the web backend builds and its tests run on a
//! machine with no browser.
//!
//! Every declaration in `web_imports.zig` appears again here, with the same
//! parameters and the same result, implemented in Zig against a fake page: a
//! handful of canvases that remember what they were told, a queue of records a
//! test fills by hand, a screen and a gamepad or two. `web.js` is the real
//! thing; this is the part of it that can be checked without one.
//!
//! What that buys is the whole path from a record to an event. A test queues
//! what the glue would have queued for a key press, pumps, and reads back the
//! event the backend made of it - through the real translation, the real
//! drain loop, and the real `Context`. The only thing left untested is
//! `web.js` itself, which the example in `examples/web.zig` is for.
//!
//! `web.verify` compares the two files at compile time on a wasm build, so the
//! declarations cannot drift apart without the build saying so.

const std = @import("std");

const wire = @import("web_wire.zig");

/// As many canvases as a test will ever ask for.
pub const max_canvases = 8;

/// One canvas, and everything the backend has asked of it.
pub const Canvas = struct {
    used: bool = false,
    id: u32 = 0,
    /// CSS pixels.
    width: f64 = 0,
    height: f64 = 0,
    scale: f64 = 1,
    visible: bool = true,
    maximized: bool = false,
    focused: bool = false,
    fullscreen: bool = false,
    opacity: f32 = 1,
    cursor_mode: u32 = 0,
    cursor_shape: u32 = 0,
    raw_motion: bool = false,
    text_input: bool = false,
    area: [4]i32 = @splat(0),
    limits: [4]u32 = @splat(0),
    gl_version: u32 = 0,
};

/// Everything the fake page is, and everything it was told.
pub const Page = struct {
    /// False is a worker: no `document`, so nothing to open.
    available: bool = true,
    opened: bool = false,

    canvases: [max_canvases]Canvas = @splat(.{}),
    /// The device pixel ratio a new canvas gets.
    scale: f64 = 1,
    /// The best WebGL this browser has. Zero is a browser with it turned off.
    webgl: u32 = 2,
    /// Whether `unadjustedMovement` is accepted.
    raw_supported: bool = true,
    /// Whether the Fullscreen API exists. An iPhone's Safari has none for
    /// anything but video.
    fullscreen_api: bool = true,
    /// Refuse to make a canvas at all.
    fail_create: bool = false,

    title: [128]u8 = @splat(0),
    title_len: usize = 0,

    /// What the page has heard and the backend has not drained yet.
    pending: [256]wire.Record = undefined,
    pending_count: usize = 0,
    text: [8192]u8 = undefined,
    text_len: usize = 0,

    pads: [4]wire.GamepadRecord = @splat(.{}),
    pad_count: usize = 0,

    screen: ?wire.MonitorInfo = .{
        .width = 1920,
        .height = 1080,
        .avail_width = 1920,
        .avail_height = 1040,
        .scale = 1,
        .color_depth = 24,
        .refresh_hz = 60,
    },

    syncs: u32 = 0,
    waits: u32 = 0,
    last_wait: f64 = 0,
    posts: u32 = 0,

    last_log_level: u32 = 0,
    last_log: [256]u8 = undefined,
    last_log_len: usize = 0,

    /// The files of the last drop, as the glue would have read them.
    dropped: []const []const u8 = &.{},

    /// The clipboard as the page knows it, null until it knows anything.
    clipboard: [4096]u8 = undefined,
    clipboard_len: ?usize = null,
    /// Whether the page has any way at all to write the clipboard.
    clipboard_api: bool = true,
};

pub var page: Page = .{};

/// Start again with a page nobody has touched.
pub fn reset() void {
    page = .{};
}

/// Hear something, the way a listener in `web.js` would: the record, and the
/// text it carries, waiting for the next `drain`.
pub fn queue(record: wire.Record, text: []const u8) void {
    std.debug.assert(page.pending_count < page.pending.len);
    std.debug.assert(page.text_len + text.len <= page.text.len);

    var copy = record;
    copy.text_offset = @intCast(page.text_len);
    copy.text_len = @intCast(text.len);
    @memcpy(page.text[page.text_len..][0..text.len], text);
    page.text_len += text.len;

    page.pending[page.pending_count] = copy;
    page.pending_count += 1;
}

/// Somebody pasted, which is when a page learns what the clipboard holds.
pub fn paste(text: []const u8) void {
    std.debug.assert(text.len <= page.clipboard.len);
    @memcpy(page.clipboard[0..text.len], text);
    page.clipboard_len = text.len;
}

/// The canvas behind a handle, which is its slot plus one so that zero can
/// mean none.
pub fn canvas(handle: u32) ?*Canvas {
    if (handle == 0 or handle > max_canvases) return null;
    const slot = &page.canvases[handle - 1];
    return if (slot.used) slot else null;
}

/// The canvas a window was given, found by the window's id.
pub fn canvasFor(id: u32) ?*Canvas {
    for (&page.canvases) |*slot| {
        if (slot.used and slot.id == id) return slot;
    }
    return null;
}

// -------------------------------------------------------------------------
// The imports, in `web_imports.zig`'s order
// -------------------------------------------------------------------------

pub fn open() u32 {
    if (!page.available) return 0;
    page.opened = true;
    return 1;
}

pub fn close() void {
    page.opened = false;
}

pub fn createWindow(
    id: u32,
    title_ptr: [*]const u8,
    title_len: u32,
    width: u32,
    height: u32,
    flags: u32,
    gl_version: u32,
    gl_flags: u32,
    info: *wire.WindowInfo,
) u32 {
    if (page.fail_create) return 0;

    const slot = for (&page.canvases, 0..) |*slot, index| {
        if (!slot.used) break .{ slot, index };
    } else return 0;

    slot[0].* = .{
        .used = true,
        .id = id,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .scale = page.scale,
        .visible = flags & 4 != 0,
        .maximized = flags & 8 != 0,
    };
    if (title_len > 0) setTitle(0, title_ptr, title_len);

    // The best the fake browser has, if that is at least what was asked for.
    if (gl_version != 0 and page.webgl >= gl_version) slot[0].gl_version = page.webgl;

    const handle: u32 = @intCast(slot[1] + 1);
    fillInfo(slot[0], info);
    if (slot[0].gl_version != 0) {
        info.red_bits = 8;
        info.green_bits = 8;
        info.blue_bits = 8;
        // A canvas is made opaque, so the drawing buffer has no alpha.
        info.alpha_bits = 0;
        info.depth_bits = if (gl_flags & 1 != 0) 24 else 0;
        info.stencil_bits = if (gl_flags & 2 != 0) 8 else 0;
        info.samples = if (gl_flags & 4 != 0) 4 else 0;
    }
    return handle;
}

fn fillInfo(slot: *const Canvas, info: *wire.WindowInfo) void {
    info.width = slot.width;
    info.height = slot.height;
    info.fb_width = @intFromFloat(@round(slot.width * slot.scale));
    info.fb_height = @intFromFloat(@round(slot.height * slot.scale));
    info.scale = slot.scale;
    info.focused = @intFromBool(slot.focused);
    info.gl_version = slot.gl_version;
}

pub fn destroyWindow(handle: u32) void {
    const slot = canvas(handle) orelse return;
    slot.* = .{};
}

pub fn windowInfo(handle: u32, info: *wire.WindowInfo) void {
    const slot = canvas(handle) orelse return;
    fillInfo(slot, info);
}

pub fn setTitle(handle: u32, ptr: [*]const u8, len: u32) void {
    _ = handle;
    const kept = @min(len, page.title.len);
    @memcpy(page.title[0..kept], ptr[0..kept]);
    page.title_len = kept;
}

pub fn setVisible(handle: u32, visible: u32) void {
    const slot = canvas(handle) orelse return;
    slot.visible = visible != 0;
}

pub fn setSize(handle: u32, width: u32, height: u32) void {
    const slot = canvas(handle) orelse return;
    slot.width = @floatFromInt(width);
    slot.height = @floatFromInt(height);
    slot.maximized = false;
}

pub fn setSizeLimits(handle: u32, min_width: u32, min_height: u32, max_width: u32, max_height: u32) void {
    const slot = canvas(handle) orelse return;
    slot.limits = .{ min_width, min_height, max_width, max_height };
}

pub fn setOpacity(handle: u32, opacity: f32) void {
    const slot = canvas(handle) orelse return;
    slot.opacity = opacity;
}

/// The same answers `web.js` gives: a page can fill itself and give the
/// space back, and take the keyboard, and has no idea of the other two.
pub fn setState(handle: u32, state: u32) u32 {
    const slot = canvas(handle) orelse return 0;
    switch (state) {
        1 => slot.maximized = true,
        2 => slot.maximized = false,
        3 => slot.focused = true,
        else => return 0,
    }
    return 1;
}

pub fn getState(handle: u32, state: u32) u32 {
    const slot = canvas(handle) orelse return 0;
    return switch (state) {
        1 => @intFromBool(slot.maximized),
        2 => @intFromBool(!slot.maximized),
        3 => @intFromBool(slot.focused),
        else => 0,
    };
}

/// Everything but `captured`, which no browser can do.
pub fn setCursorMode(handle: u32, mode: u32) u32 {
    const slot = canvas(handle) orelse return 0;
    if (mode == 2) return 0;
    slot.cursor_mode = mode;
    return 1;
}

pub fn setRawMouseMotion(handle: u32, on: u32) u32 {
    const slot = canvas(handle) orelse return 0;
    slot.raw_motion = on != 0 and page.raw_supported;
    return @intFromBool(page.raw_supported);
}

pub fn setCursorShape(handle: u32, shape: u32) u32 {
    const slot = canvas(handle) orelse return 0;
    slot.cursor_shape = shape;
    return 1;
}

pub fn setFullscreen(handle: u32, on: u32) u32 {
    const slot = canvas(handle) orelse return 0;
    if (!page.fullscreen_api) return 0;
    slot.fullscreen = on != 0;
    return 1;
}

pub fn setTextInput(handle: u32, on: u32) u32 {
    const slot = canvas(handle) orelse return 0;
    slot.text_input = on != 0;
    return 1;
}

pub fn setTextInputArea(handle: u32, x: i32, y: i32, width: u32, height: u32) void {
    const slot = canvas(handle) orelse return;
    slot.area = .{ x, y, @intCast(width), @intCast(height) };
}

pub fn monitor(info: *wire.MonitorInfo) u32 {
    info.* = page.screen orelse return 0;
    return 1;
}

pub fn gamepads(out: [*]wire.GamepadRecord, capacity: u32) u32 {
    const count = @min(page.pad_count, capacity);
    for (page.pads[0..count], 0..) |pad, index| out[index] = pad;
    return @intCast(count);
}

/// Hand over what is pending, as much as fits, and keep the rest for the next
/// call - which is what the real glue does when a pump has more to say than
/// one buffer holds.
pub fn drain(records: [*]wire.Record, capacity: u32, heap: [*]u8, heap_capacity: u32) u32 {
    var written: usize = 0;
    var used: usize = 0;
    while (written < capacity and written < page.pending_count) {
        const record = page.pending[written];
        var len: usize = record.text_len;
        if (used + len > heap_capacity) {
            // Waiting only helps if a later drain would have room. A text
            // longer than the whole heap never will, so it is cut instead -
            // otherwise it would sit at the front and stop everything behind
            // it, and a zero answer would read as "nothing left".
            if (written > 0) break;
            len = heap_capacity;
        }

        var copy = record;
        @memcpy(heap[used..][0..len], page.text[record.text_offset..][0..len]);
        copy.text_offset = @intCast(used);
        copy.text_len = @intCast(len);
        used += len;

        records[written] = copy;
        written += 1;
    }

    // What was handed over is gone; what was not moves to the front.
    const left = page.pending_count - written;
    @memmove(page.pending[0..left], page.pending[written..page.pending_count]);
    page.pending_count = left;
    if (left == 0) page.text_len = 0;

    return @intCast(written);
}

pub fn sync() void {
    page.syncs += 1;
}

pub fn wait(timeout_ms: f64) void {
    page.waits += 1;
    page.last_wait = timeout_ms;
}

pub fn post() void {
    page.posts += 1;
}

pub fn log(level: u32, ptr: [*]const u8, len: u32) void {
    const kept = @min(len, page.last_log.len);
    @memcpy(page.last_log[0..kept], ptr[0..kept]);
    page.last_log_len = kept;
    page.last_log_level = level;
}

pub fn droppedSize(index: u32) i32 {
    if (index >= page.dropped.len) return -1;
    return @intCast(page.dropped[index].len);
}

pub fn droppedRead(index: u32, ptr: [*]u8, len: u32) u32 {
    if (index >= page.dropped.len) return 0;
    const file = page.dropped[index];
    const kept = @min(len, file.len);
    @memcpy(ptr[0..kept], file[0..kept]);
    return @intCast(kept);
}

pub fn setClipboard(ptr: [*]const u8, len: u32) u32 {
    if (!page.clipboard_api) return 0;
    paste(ptr[0..len]);
    return 1;
}

pub fn clipboardSize() i32 {
    const len = page.clipboard_len orelse return -1;
    return @intCast(len);
}

pub fn clipboardRead(ptr: [*]u8, len: u32) u32 {
    const known = page.clipboard_len orelse return 0;
    const kept = @min(len, known);
    @memcpy(ptr[0..kept], page.clipboard[0..kept]);
    return @intCast(kept);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a drain hands over what fits and keeps the rest" {
    reset();
    defer reset();

    queue(.{ .kind = .key, .window = 1 }, "KeyA");
    queue(.{ .kind = .key, .window = 1 }, "KeyB");
    queue(.{ .kind = .focus, .window = 1, .a = 1 }, "");

    var records: [2]wire.Record = undefined;
    var heap: [16]u8 = undefined;

    try testing.expectEqual(@as(u32, 2), drain(&records, records.len, &heap, heap.len));
    try testing.expectEqualStrings("KeyA", heap[records[0].text_offset..][0..records[0].text_len]);
    try testing.expectEqualStrings("KeyB", heap[records[1].text_offset..][0..records[1].text_len]);

    try testing.expectEqual(@as(u32, 1), drain(&records, records.len, &heap, heap.len));
    try testing.expectEqual(wire.Kind.focus, records[0].kind);
    try testing.expectEqual(@as(u32, 0), drain(&records, records.len, &heap, heap.len));
}

test "a record whose text does not fit waits for the next drain" {
    reset();
    defer reset();

    queue(.{ .kind = .key }, "KeyA");
    queue(.{ .kind = .key }, "ControlLeft");
    var records: [4]wire.Record = undefined;
    var heap: [8]u8 = undefined;

    // The first fits and the second does not, so the second waits.
    try testing.expectEqual(@as(u32, 1), drain(&records, records.len, &heap, heap.len));
    // And on its own, in an empty heap that is still too small, it is cut
    // rather than left to block the queue for ever.
    try testing.expectEqual(@as(u32, 1), drain(&records, records.len, &heap, heap.len));
    try testing.expectEqualStrings("ControlL", heap[0..records[0].text_len]);
    try testing.expectEqual(@as(u32, 0), drain(&records, records.len, &heap, heap.len));
}
