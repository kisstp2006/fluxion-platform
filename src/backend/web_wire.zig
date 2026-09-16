// SPDX-License-Identifier: BSL-1.0

//! What crosses between `web.zig` and `web.js`, byte for byte.
//!
//! WebAssembly hands four types across its boundary - 32- and 64-bit integers
//! and floats - and nothing else. Anything bigger than one of those, an event
//! or a gamepad or a monitor, is written into the module's memory by one side
//! and read out by the other, at offsets both have to agree on. These are
//! those layouts.
//!
//! `extern struct` so the compiler keeps the fields in the order written, and
//! the tests at the bottom pin every offset `web.js` hard-codes. A field moved
//! here without being moved there is a key read out of the middle of a
//! timestamp, and nothing reports it: the numbers are just wrong.
//!
//! **Little-endian, always.** WebAssembly memory is little-endian on every
//! machine that runs it, which is why the JavaScript side passes `true` to
//! every `DataView` accessor rather than trusting the host.

const std = @import("std");
const testing = std.testing;

/// What one record says happened. The numbers are the wire format.
pub const Kind = enum(u32) {
    none = 0,
    /// A key went down, came up or repeated. `a` is the action - 0 release,
    /// 1 press, 2 repeat - `b` the modifier bits, and the text is the DOM
    /// `code`: where the key is, not what it types. `c` is what it types on
    /// its own on the layout in use, as a codepoint, or 0 where the glue could
    /// not tell - the virtual key is worked out from it.
    key = 1,
    /// A codepoint was typed. `a` is the codepoint, `b` the modifier bits.
    char = 2,
    /// A mouse button changed. `a` is the DOM button number, `b` the action,
    /// `c` the modifier bits, `d` the event's time in whole milliseconds,
    /// wrapped to 32 bits, `x` and `y` where the pointer was, and `dx` 1 where
    /// a finger rather than a mouse or a pen did it.
    button = 3,
    /// The pointer moved. `x` and `y` in the drawing buffer's pixels, `dx` and
    /// `dy` the motion.
    cursor = 4,
    /// A wheel turned. `a` is the DOM delta mode, `b` the modifier bits, `x`
    /// and `y` the deltas exactly as the browser reported them.
    scroll = 5,
    /// The pointer entered (`a` 1) or left (`a` 0) the canvas.
    enter = 6,
    /// The canvas gained (`a` 1) or lost (`a` 0) the keyboard.
    focus = 7,
    /// The canvas changed size. `a` and `b` are CSS pixels, `c` and `d` device
    /// pixels, `x` the device pixel ratio.
    resize = 8,
    /// The page was hidden (`a` 1) or shown again (`a` 0). Not about a window.
    visibility = 9,
    /// The canvas started (`a` 1) or stopped (`a` 0) filling the page.
    maximize = 10,
    /// What the input method is composing changed. The text is the
    /// composition, `a` and `b` the caret as byte offsets into it.
    preedit = 11,
    /// Files were dropped on the canvas: `a` of them, whose names follow as
    /// that many `drop_file` records.
    drop_begin = 12,
    /// One dropped file. `a` is its index, the text its name.
    drop_file = 13,
    /// The WebGL context was lost, and everything made with it has gone.
    surface_lost = 14,
    /// A WebGL context is back. `a` and `b` are the drawing buffer in device
    /// pixels.
    surface_created = 15,
    /// A file dialog was answered: `a` files, whose names follow as that many
    /// `dialog_file` records. `b` is the dialog's id.
    dialog_begin = 16,
    /// One chosen file. `a` is its index, the text its name.
    dialog_file = 17,
    /// The page's safe-area insets changed. `a`, `b`, `c` and `d` are left,
    /// top, right and bottom, in the drawing buffer's pixels.
    safe_area = 18,
    _,
};

/// One thing that happened, as `drain` writes it.
///
/// Sixty-four bytes, every one of them named. The generic fields rather than
/// one struct per kind, because the JavaScript writes them with a `DataView`
/// at fixed offsets and a union would be the same bytes with more ways to get
/// the offsets wrong. `Kind` says which fields mean what.
pub const Record = extern struct {
    kind: Kind = .none,
    /// The `WindowId` the context gave the window, or zero for an event about
    /// the page rather than a canvas.
    window: u32 = 0,
    a: i32 = 0,
    b: i32 = 0,
    c: i32 = 0,
    d: i32 = 0,
    x: f64 = 0,
    y: f64 = 0,
    dx: f64 = 0,
    dy: f64 = 0,
    /// Where this record's text starts in the heap `drain` was handed, and how
    /// many bytes of UTF-8 it is. Zero length for a record with no text.
    text_offset: u32 = 0,
    text_len: u32 = 0,
};

/// What the page says about a canvas: its sizes, and the context it got.
///
/// Written by `createWindow` and by `windowInfo`.
pub const WindowInfo = extern struct {
    /// CSS pixels, which is this backend's logical unit.
    width: f64 = 0,
    height: f64 = 0,
    /// The drawing buffer, in device pixels.
    fb_width: u32 = 0,
    fb_height: u32 = 0,
    /// `devicePixelRatio`.
    scale: f64 = 1,
    focused: u32 = 0,
    /// 0 for no context, 1 for WebGL 1, 2 for WebGL 2.
    gl_version: u32 = 0,
    /// What the context actually has, read back from it rather than assumed
    /// from what was asked for.
    red_bits: u32 = 0,
    green_bits: u32 = 0,
    blue_bits: u32 = 0,
    alpha_bits: u32 = 0,
    depth_bits: u32 = 0,
    stencil_bits: u32 = 0,
    samples: u32 = 0,
    reserved: u32 = 0,
};

/// The screen the page is on.
pub const MonitorInfo = extern struct {
    /// `screen.left` and `screen.top`, which only a browser with the Window
    /// Management API has. Zero elsewhere.
    left: f64 = 0,
    top: f64 = 0,
    /// `screen.width` and `screen.height`, in CSS pixels.
    width: f64 = 0,
    height: f64 = 0,
    /// The part of it a window may use: the screen less the taskbar.
    avail_left: f64 = 0,
    avail_top: f64 = 0,
    avail_width: f64 = 0,
    avail_height: f64 = 0,
    /// `devicePixelRatio`.
    scale: f64 = 1,
    /// `screen.colorDepth`.
    color_depth: u32 = 0,
    /// Measured from the gaps between animation frames, because no browser
    /// says. Zero until enough frames have gone past to say.
    refresh_hz: u32 = 0,
};

/// The longest gamepad `id` kept, in bytes. Chrome's run past sixty-four -
/// "Wireless Controller (STANDARD GAMEPAD Vendor: 054c Product: 09cc)" is
/// sixty-six - and the vendor and product are at the end, so a shorter buffer
/// would cut off the part that identifies the device.
pub const max_gamepad_id = 128;

/// One controller, as `navigator.getGamepads()` describes it.
pub const GamepadRecord = extern struct {
    /// `Gamepad.index`: the browser's slot for it, stable while it is plugged
    /// in.
    index: u32 = 0,
    /// Whether `Gamepad.mapping` is `"standard"` - which means the browser has
    /// already put every control where the W3C layout says, and nothing here
    /// has to map it.
    standard: u32 = 0,
    axis_count: u32 = 0,
    button_count: u32 = 0,
    /// Bit `n` is `buttons[n].pressed`.
    pressed: u32 = 0,
    id_len: u32 = 0,
    axes: [8]f32 = @splat(0),
    /// `buttons[n].value`, which is how far a trigger is pulled.
    values: [32]f32 = @splat(0),
    id: [max_gamepad_id]u8 = @splat(0),
};

// -------------------------------------------------------------------------
// Tests
//
// Every number below is also written in `web.js`. Change one side and this
// is the file that fails, which is the point: the other failure mode is an
// event read at the wrong offset, in somebody's browser.
// -------------------------------------------------------------------------

test "a record is sixty-four bytes, at the offsets the glue writes" {
    try testing.expectEqual(64, @sizeOf(Record));
    try testing.expectEqual(0, @offsetOf(Record, "kind"));
    try testing.expectEqual(4, @offsetOf(Record, "window"));
    try testing.expectEqual(8, @offsetOf(Record, "a"));
    try testing.expectEqual(12, @offsetOf(Record, "b"));
    try testing.expectEqual(16, @offsetOf(Record, "c"));
    try testing.expectEqual(20, @offsetOf(Record, "d"));
    try testing.expectEqual(24, @offsetOf(Record, "x"));
    try testing.expectEqual(32, @offsetOf(Record, "y"));
    try testing.expectEqual(40, @offsetOf(Record, "dx"));
    try testing.expectEqual(48, @offsetOf(Record, "dy"));
    try testing.expectEqual(56, @offsetOf(Record, "text_offset"));
    try testing.expectEqual(60, @offsetOf(Record, "text_len"));
}

test "the floats are aligned, so the glue can write them in one access" {
    // `DataView` does not care, but a record array is also read by Zig as
    // `[]Record`, and an `f64` at an odd offset would be a misaligned load.
    try testing.expectEqual(0, @offsetOf(Record, "x") % 8);
    try testing.expectEqual(8, @alignOf(Record));
}

test "the event kinds are the numbers the glue sends" {
    try testing.expectEqual(1, @intFromEnum(Kind.key));
    try testing.expectEqual(2, @intFromEnum(Kind.char));
    try testing.expectEqual(3, @intFromEnum(Kind.button));
    try testing.expectEqual(4, @intFromEnum(Kind.cursor));
    try testing.expectEqual(5, @intFromEnum(Kind.scroll));
    try testing.expectEqual(6, @intFromEnum(Kind.enter));
    try testing.expectEqual(7, @intFromEnum(Kind.focus));
    try testing.expectEqual(8, @intFromEnum(Kind.resize));
    try testing.expectEqual(9, @intFromEnum(Kind.visibility));
    try testing.expectEqual(10, @intFromEnum(Kind.maximize));
    try testing.expectEqual(11, @intFromEnum(Kind.preedit));
    try testing.expectEqual(12, @intFromEnum(Kind.drop_begin));
    try testing.expectEqual(13, @intFromEnum(Kind.drop_file));
    try testing.expectEqual(14, @intFromEnum(Kind.surface_lost));
    try testing.expectEqual(15, @intFromEnum(Kind.surface_created));
    try testing.expectEqual(16, @intFromEnum(Kind.dialog_begin));
    try testing.expectEqual(17, @intFromEnum(Kind.dialog_file));
    try testing.expectEqual(18, @intFromEnum(Kind.safe_area));
}

test "the window info is laid out the way the glue fills it" {
    try testing.expectEqual(72, @sizeOf(WindowInfo));
    try testing.expectEqual(0, @offsetOf(WindowInfo, "width"));
    try testing.expectEqual(8, @offsetOf(WindowInfo, "height"));
    try testing.expectEqual(16, @offsetOf(WindowInfo, "fb_width"));
    try testing.expectEqual(20, @offsetOf(WindowInfo, "fb_height"));
    try testing.expectEqual(24, @offsetOf(WindowInfo, "scale"));
    try testing.expectEqual(32, @offsetOf(WindowInfo, "focused"));
    try testing.expectEqual(36, @offsetOf(WindowInfo, "gl_version"));
    try testing.expectEqual(40, @offsetOf(WindowInfo, "red_bits"));
    try testing.expectEqual(44, @offsetOf(WindowInfo, "green_bits"));
    try testing.expectEqual(48, @offsetOf(WindowInfo, "blue_bits"));
    try testing.expectEqual(52, @offsetOf(WindowInfo, "alpha_bits"));
    try testing.expectEqual(56, @offsetOf(WindowInfo, "depth_bits"));
    try testing.expectEqual(60, @offsetOf(WindowInfo, "stencil_bits"));
    try testing.expectEqual(64, @offsetOf(WindowInfo, "samples"));
}

test "the monitor info is laid out the way the glue fills it" {
    try testing.expectEqual(80, @sizeOf(MonitorInfo));
    try testing.expectEqual(0, @offsetOf(MonitorInfo, "left"));
    try testing.expectEqual(16, @offsetOf(MonitorInfo, "width"));
    try testing.expectEqual(32, @offsetOf(MonitorInfo, "avail_left"));
    try testing.expectEqual(48, @offsetOf(MonitorInfo, "avail_width"));
    try testing.expectEqual(64, @offsetOf(MonitorInfo, "scale"));
    try testing.expectEqual(72, @offsetOf(MonitorInfo, "color_depth"));
    try testing.expectEqual(76, @offsetOf(MonitorInfo, "refresh_hz"));
}

test "a gamepad record is laid out the way the glue fills it" {
    try testing.expectEqual(312, @sizeOf(GamepadRecord));
    try testing.expectEqual(0, @offsetOf(GamepadRecord, "index"));
    try testing.expectEqual(4, @offsetOf(GamepadRecord, "standard"));
    try testing.expectEqual(8, @offsetOf(GamepadRecord, "axis_count"));
    try testing.expectEqual(12, @offsetOf(GamepadRecord, "button_count"));
    try testing.expectEqual(16, @offsetOf(GamepadRecord, "pressed"));
    try testing.expectEqual(20, @offsetOf(GamepadRecord, "id_len"));
    try testing.expectEqual(24, @offsetOf(GamepadRecord, "axes"));
    try testing.expectEqual(56, @offsetOf(GamepadRecord, "values"));
    try testing.expectEqual(184, @offsetOf(GamepadRecord, "id"));
}
