// SPDX-License-Identifier: BSL-1.0

//! Everything that can happen, as one tagged union.
//!
//! Events are pulled rather than pushed: `Context.poll` hands back the next one
//! or null, so the whole input phase of a frame is one `while` and one `switch`,
//! and there is no callback running in the middle of somebody else's code.
//!
//! ```zig
//! while (ctx.poll()) |ev| switch (ev) {
//!     .close => win.setShouldClose(true),
//!     .key => |k| if (k.action.down()) keyboard.onKeyDown(k.key),
//!     .char => |c| text.append(c.codepoint),
//!     else => {},
//! };
//! ```
//!
//! **`.key` and `.char` are not the same event.** A key event is a physical key
//! going down or up, in the position it occupies whatever the layout says, and
//! the virtual key the layout names it beside it. A char event is a codepoint
//! the user meant to type, already through the layout, the dead keys and any
//! input method - one keypress can produce no chars, one char, or several. Bind
//! controls to `key`, compare shortcuts against `virtual`, and put text in a box
//! with `.char`.
//!
//! **`.surface_lost` and `.surface_created` are the Android ones**, and the
//! reason this library does not pretend a window is a thing you own for as long
//! as you hold it. There, the system takes the drawing surface away when the
//! app goes to the background or the screen rotates, and gives back a new one
//! later, while the process keeps running. A program that releases its
//! swapchain on the first and builds a new one on the second is correct on
//! Android and unaffected everywhere else, because no desktop backend ever
//! sends them.

const std = @import("std");
const testing = std.testing;

const keys = @import("keys.zig");

/// Which window an event is about.
///
/// An id rather than a pointer, so an event that outlives the window it came
/// from is a lookup that fails rather than a pointer that does not.
pub const WindowId = enum(u32) {
    /// Not about any window: a monitor was plugged in, a gamepad connected.
    none = 0,
    _,
};

/// A key going down, coming up, or repeating.
///
/// **Two names for one key: the physical and the virtual.** `key` is where
/// it is, whatever the layout says - what WASD is bound to, so that it does
/// not move under somebody on AZERTY. `virtual` is what the layout calls it -
/// what a shortcut is written against, because ctrl+Z means the Z the user
/// can see, and on a German or Hungarian keyboard that is the key `key` calls
/// `.y`.
pub const KeyEvent = struct {
    window: WindowId,
    /// The physical key, at its position on a US layout.
    key: keys.Key,
    /// The virtual key: the key as the layout in use names it.
    ///
    /// Only letters move. A key that types a Latin letter is that letter,
    /// wherever the layout put it. A letter from another alphabet is the
    /// Latin letter of its place, the way every system does it for shortcuts,
    /// so ctrl+C still copies on a Cyrillic or a Greek keyboard. A letter's
    /// place that holds something else - AZERTY's comma, where US has M - is
    /// `.unknown`, so that no two keys claim one letter. Digits, punctuation
    /// and the keys that type nothing are the same as `key`.
    ///
    /// Every backend fills this in. An event made by hand - a test's, a
    /// replay's - that leaves it out gets `.unknown`.
    virtual: keys.Key = .unknown,
    /// The platform's own number for the same key. Use it to tell two keys
    /// apart that both arrive as `unknown`.
    scancode: keys.Scancode,
    action: keys.Action,
    mods: keys.Mods,
};

/// A codepoint the user meant to type.
pub const CharEvent = struct {
    window: WindowId,
    codepoint: u21,
    mods: keys.Mods,
};

/// A mouse button going down or up. Never `repeat`.
pub const MouseButtonEvent = struct {
    window: WindowId,
    button: keys.MouseButton,
    action: keys.Action,
    mods: keys.Mods,
    /// Where the cursor was, in content-area coordinates.
    x: f64,
    y: f64,
};

/// The cursor moved, in content-area coordinates with the origin top left.
///
/// **Content-area coordinates are the framebuffer's pixels, on every
/// backend**: the pixels a program draws, so a position lands on what was
/// drawn there. A layout written in `Window.size` units divides by the ratio
/// of `framebufferSize` to `size`. A browser's CSS pixels and a Wayland
/// surface's are turned into these by the backend.
///
/// `dx` and `dy` are the movement since the last such event. In `.disabled`
/// cursor mode they are the raw motion the device reported and `x`/`y` stop
/// meaning anything, which is what a camera wants.
pub const CursorEvent = struct {
    window: WindowId,
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
};

/// A wheel or a trackpad. `y` is the usual vertical wheel; `x` is the
/// horizontal one, which most mice have not got.
///
/// Measured in notches - one click of a wheel is one, and a trackpad's glide
/// is a fraction of one - and signed the same way on every backend: `y` is
/// positive for up, the wheel rolled away from the user, and `x` is positive
/// for right. The systems underneath do not agree - Wayland and the DOM count
/// down as positive, Win32 and X11 count up - and each backend turns its own
/// numbers round, so that a program has one convention to know rather than
/// one per platform.
///
/// A text view scrolls notches times `Context.scrollLines`: the user's own setting.
pub const ScrollEvent = struct {
    window: WindowId,
    x: f64,
    y: f64,
    mods: keys.Mods,
};

/// A size, in whichever unit the event says.
pub const SizeEvent = struct {
    window: WindowId,
    width: u32,
    height: u32,
};

/// A position, in screen coordinates.
pub const PositionEvent = struct {
    window: WindowId,
    x: i32,
    y: i32,
};

/// A window gained or lost something - focus, iconification, the pointer.
pub const StateEvent = struct {
    window: WindowId,
    /// True for gained, entered, iconified; false for the opposite.
    value: bool,
};

/// How many pixels there are per logical unit, per axis.
///
/// 1.0 is an ordinary display; 2.0 is what a HiDPI screen reports. It changes
/// while the program runs, because a window can be dragged from one monitor to
/// another.
pub const ScaleEvent = struct {
    window: WindowId,
    x: f32,
    y: f32,
};

/// Files were dropped on the window. The paths belong to the library and are
/// valid until the next `pump`, as a dialog's answer is; copy anything you
/// keep.
pub const DropEvent = struct {
    window: WindowId,
    paths: []const []const u8,
    /// Where they were let go, in content-area coordinates like a
    /// `CursorEvent`'s - where the program puts what was dropped: into the
    /// folder under it, onto the thing under it. A drop the system says no
    /// place for is at the origin.
    x: f64 = 0,
    y: f64 = 0,
};

/// Which file dialog an answer belongs to: the id `Context.openFileDialog`
/// or `Context.openFolderDialog` returned.
pub const DialogId = enum(u32) {
    none = 0,
    _,
};

/// The answer to a file or folder dialog. The paths belong to the library and
/// are valid until the next `pump`; copy anything you keep.
pub const FileDialogEvent = struct {
    /// The window the dialog was opened over, or `.none`.
    window: WindowId,
    id: DialogId,
    /// Absolute paths - names, on the web - and none when nothing was chosen.
    paths: []const []const u8,
};

/// A new drawing surface exists. Android only.
pub const SurfaceEvent = struct {
    window: WindowId,
    width: u32,
    height: u32,
};

/// Everything that can happen.
pub const Event = union(enum) {
    /// The user asked for the window to close - the button, alt+F4, the window
    /// menu. Nothing has closed yet: it is a request, and ignoring it keeps the
    /// window open.
    close: WindowId,
    /// The window needs redrawing, because something covered it or the system
    /// resized it mid-drag. A program that draws every frame anyway can ignore
    /// this.
    refresh: WindowId,

    resize: SizeEvent,
    /// The drawable size in pixels, which is not the window size on a HiDPI
    /// display. This is the one a swapchain and a viewport want.
    framebuffer_resize: SizeEvent,
    move: PositionEvent,
    scale: ScaleEvent,

    focus: StateEvent,
    iconify: StateEvent,
    maximize: StateEvent,
    /// The pointer entered or left the content area.
    cursor_enter: StateEvent,

    key: KeyEvent,
    char: CharEvent,
    mouse_button: MouseButtonEvent,
    cursor: CursorEvent,
    scroll: ScrollEvent,
    drop: DropEvent,
    file_dialog: FileDialogEvent,

    /// Android: the drawing surface has gone. Release everything that points at
    /// it - swapchain, framebuffers, the EGL surface - before returning from
    /// the frame that handled this.
    surface_lost: WindowId,
    /// Android: there is a surface again, and it may be a different size from
    /// the one before.
    surface_created: SurfaceEvent,

    /// The application is going to the background. On Android this arrives
    /// before `surface_lost`; on the desktop it never arrives at all.
    suspended,
    /// And coming back.
    resumed,
    /// The system is short of memory and would like some back.
    low_memory,

    /// What an input method is composing has changed.
    ///
    /// Only that it changed: the text itself is `Context.preedit`, because a
    /// composition is a state rather than a thing that happened - it is on
    /// screen until it is committed or abandoned. See `text`.
    ///
    /// A program that draws its own text field has to draw the preedit,
    /// underlined, at the caret. One that does not can ignore this and still
    /// get correct text, because a composition is committed through `.char`
    /// like anything else.
    preedit: WindowId,

    /// A controller was plugged in, or turned on, or came back into range.
    /// Carries the slot, which is what `Context.gamepad` takes.
    ///
    /// The one thing about a gamepad that is an event. Everything else - which
    /// way the stick is pushed, which buttons are down - is a position rather
    /// than a thing that happened, and is read with `Context.gamepad`.
    gamepad_connected: usize,
    /// And gone again: unplugged, switched off, or out of batteries.
    gamepad_disconnected: usize,

    /// Which window this is about, or `.none` for the ones that are about the
    /// process rather than a window.
    pub fn window(self: Event) WindowId {
        return switch (self) {
            .close, .refresh, .surface_lost, .preedit => |id| id,
            .suspended, .resumed, .low_memory => .none,
            // A controller belongs to the machine, not to a window.
            .gamepad_connected, .gamepad_disconnected => .none,
            inline else => |payload| payload.window,
        };
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "every event says which window it is about" {
    const id: WindowId = @enumFromInt(7);

    try testing.expectEqual(id, (Event{ .close = id }).window());
    try testing.expectEqual(id, (Event{ .refresh = id }).window());
    try testing.expectEqual(id, (Event{ .surface_lost = id }).window());
    try testing.expectEqual(id, (Event{ .resize = .{ .window = id, .width = 1, .height = 2 } }).window());
    try testing.expectEqual(id, (Event{ .key = .{
        .window = id,
        .key = .a,
        .scancode = @enumFromInt(30),
        .action = .press,
        .mods = .none,
    } }).window());
    try testing.expectEqual(id, (Event{ .scale = .{ .window = id, .x = 2, .y = 2 } }).window());
    try testing.expectEqual(id, (Event{ .file_dialog = .{ .window = id, .id = @enumFromInt(1), .paths = &.{} } }).window());
}

test "the process-wide events belong to no window" {
    try testing.expectEqual(WindowId.none, (Event{ .suspended = {} }).window());
    try testing.expectEqual(WindowId.none, (Event{ .resumed = {} }).window());
    try testing.expectEqual(WindowId.none, (Event{ .low_memory = {} }).window());
}

test "a switch over events compiles for every case" {
    // Not an assertion about behaviour: it is a check that the union stays
    // switchable without an `else`, so adding a case is a compile error at
    // every site that has to care.
    const ev: Event = .{ .close = @enumFromInt(1) };
    const kind: []const u8 = switch (ev) {
        .close => "close",
        .refresh => "refresh",
        .resize, .framebuffer_resize => "resize",
        .move => "move",
        .scale => "scale",
        .focus, .iconify, .maximize, .cursor_enter => "state",
        .key => "key",
        .char => "char",
        .mouse_button => "button",
        .cursor => "cursor",
        .scroll => "scroll",
        .drop => "drop",
        .file_dialog => "file dialog",
        .surface_lost, .surface_created => "surface",
        .preedit => "preedit",
        .suspended, .resumed, .low_memory => "lifecycle",
        .gamepad_connected, .gamepad_disconnected => "gamepad",
    };
    try testing.expectEqualStrings("close", kind);
}

test "window zero is never a real window" {
    // `WindowId.none` is the zero value, so a zeroed struct names no window
    // rather than naming the first one.
    const zeroed: WindowId = @enumFromInt(0);
    try testing.expectEqual(WindowId.none, zeroed);
}
