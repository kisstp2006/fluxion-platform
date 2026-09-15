// SPDX-License-Identifier: BSL-1.0

//! What a windowing system has to answer to, as one table of function pointers.
//!
//! A vtable rather than a comptime switch, because on Linux the choice is not
//! made until the program runs: the same binary opens Wayland in one session
//! and X11 in the next, and `Context` holds whichever answered. Everywhere else
//! there is exactly one candidate and the indirection costs a call.
//!
//! Backends do not return events. They push them into the `Queue` the context
//! owns, because one platform message can mean several events - a Win32
//! `WM_SIZE` is a resize and a framebuffer resize, and a single keypress can
//! produce a key event and any number of chars.

const std = @import("std");
const Allocator = std.mem.Allocator;

const cursor = @import("cursor.zig");
const dialog = @import("dialog.zig");
const event = @import("event.zig");
const input = @import("input.zig");
const monitor = @import("monitor.zig");
const gamepad = @import("gamepad.zig");
const gl_mod = @import("gl.zig");
const vulkan = @import("vulkan.zig");
const text = @import("text.zig");
const platform = @import("platform.zig");

const Error = platform.Error;

/// A backend's own state, whatever it is. Only the backend that made one ever
/// looks inside.
pub const Impl = *anyopaque;

/// A backend's own per-window state.
pub const NativeWindow = *anyopaque;

/// What a window is being asked for. See `Window.Desc` for the documented form;
/// this is the same thing, flattened to what a backend needs.
pub const WindowDesc = struct {
    title: []const u8,
    width: u32,
    height: u32,
    resizable: bool,
    decorated: bool,
    visible: bool,
    maximized: bool,
    /// Ask for an OpenGL context, or null for a window with none.
    ///
    /// Here rather than on a later call because every platform decides the
    /// pixel format when the window is made: Win32 allows one `SetPixelFormat`
    /// per window, X11 needs the window built on the visual the framebuffer
    /// config named, and EGL wants a surface made against a config. A window
    /// has a context from the moment it exists or never.
    gl: ?gl_mod.Config,
};

/// What a window can be asked to become, beyond being shown or hidden.
pub const WindowState = enum {
    /// Minimised to the taskbar or the dock.
    iconified,
    /// Filling the work area, but still a window.
    maximized,
    /// Neither of those - the size it had before. Reached in one go, even from
    /// minimised-from-maximised.
    restored,
    /// Raised and given the keyboard. Rude, and refused by most systems unless
    /// the program already had focus.
    focused,
    /// The gentler version: ask to be noticed, and let the system decide how.
    attention,
};

/// A file or folder dialog, as a backend is asked for one. See `dialog` for
/// the documented form; the context has checked every string in it.
pub const DialogRequest = struct {
    id: event.DialogId = .none,
    /// The window it belongs to, and that window's id for the answer.
    owner: ?NativeWindow = null,
    window: event.WindowId = .none,
    folder: bool,
    multiple: bool,
    title: ?[]const u8,
    filters: []const dialog.Filter,
    initial_folder: ?[]const u8,
};

/// The limits a window may not be resized past. Zero means no limit on that
/// edge, which is what a window has by default.
pub const SizeLimits = struct {
    min_width: u32 = 0,
    min_height: u32 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,

    /// A minimum above the maximum loses to it.
    pub fn clamp(self: SizeLimits, wanted: [2]u32) [2]u32 {
        return .{
            within(wanted[0], self.min_width, self.max_width),
            within(wanted[1], self.min_height, self.max_height),
        };
    }

    fn within(value: u32, min: u32, max: u32) u32 {
        var held = value;
        if (min != 0) held = @max(held, min);
        if (max != 0) held = @min(held, max);
        return held;
    }
};

/// Every call a windowing system has to answer.
///
/// Anything a backend cannot do returns `error.Unavailable` rather than being
/// left out: a caller that asks for a window's position on Wayland should get
/// an answer it can act on, not a compile error that moves the problem to build
/// time.
pub const Vtable = struct {
    /// Which one this is. `Context.backend` reads it back out.
    backend: platform.Backend,

    /// Let go of the connection. Every window is destroyed first, by the
    /// context.
    deinit: *const fn (impl: Impl, gpa: Allocator) void,

    /// Make a window. The id is the context's, and the backend stores it so
    /// that the events it pushes can name it.
    createWindow: *const fn (
        impl: Impl,
        gpa: Allocator,
        id: event.WindowId,
        desc: WindowDesc,
    ) Error!NativeWindow,

    /// Puts back what the window changed for the whole machine: a display mode, a held pointer.
    destroyWindow: *const fn (impl: Impl, gpa: Allocator, native: NativeWindow) void,

    /// Drain whatever the system has and push it into `queue`.
    ///
    /// Must not block. `wait` is the one that may, and only until something
    /// arrives or the timeout runs out.
    ///
    /// The web backend bends this in one case, because a page does: when the
    /// program's `main` is a loop, a pump is where the module is suspended
    /// until the next animation frame. Nothing else would ever let the browser
    /// draw or deliver an event. See `backend/web.zig`.
    pump: *const fn (impl: Impl, queue: *Queue) Error!void,

    /// Block until there is something to pump, or `timeout_ms` passes. A null
    /// timeout waits forever.
    wait: *const fn (impl: Impl, timeout_ms: ?u32) Error!void,

    /// Wake a `wait` from another thread, so a program that sleeps between
    /// frames can be told to stop.
    post: *const fn (impl: Impl) void,

    setTitle: *const fn (impl: Impl, native: NativeWindow, title: []const u8) Error!void,
    setVisible: *const fn (impl: Impl, native: NativeWindow, visible: bool) void,

    /// The content area, in logical units.
    size: *const fn (impl: Impl, native: NativeWindow) [2]u32,
    /// The drawable, in pixels. The same on an ordinary display and larger on a
    /// HiDPI one, which is why a swapchain must ask for this and not `size`.
    /// Both keep the last real size while minimised; no resize to 0x0 is pushed.
    framebufferSize: *const fn (impl: Impl, native: NativeWindow) [2]u32,
    /// Pixels per logical unit, per axis.
    contentScale: *const fn (impl: Impl, native: NativeWindow) [2]f32,

    /// Where the window is, in screen coordinates. Meaningless where the
    /// system does not tell a program where its window is - Wayland - and zero
    /// there rather than a guess.
    position: *const fn (impl: Impl, native: NativeWindow) [2]i32,
    setPosition: *const fn (impl: Impl, native: NativeWindow, x: i32, y: i32) Error!void,

    /// Resize the content area.
    setSize: *const fn (impl: Impl, native: NativeWindow, width: u32, height: u32) Error!void,

    /// Iconify, maximize, restore, focus, or ask for attention.
    setState: *const fn (impl: Impl, native: NativeWindow, wanted: WindowState) Error!void,

    /// Is it in that state now?
    getState: *const fn (impl: Impl, native: NativeWindow, which: WindowState) bool,

    /// The bounds the user may resize within, applied at once unless the
    /// window is maximised, minimised or fullscreen.
    setSizeLimits: *const fn (impl: Impl, native: NativeWindow, limits: SizeLimits) Error!void,

    /// How see-through the whole window is, from 0 to 1. `error.Unavailable`
    /// where the system has no such idea.
    setOpacity: *const fn (impl: Impl, native: NativeWindow, opacity: f32) Error!void,

    /// Hide, confine or free the pointer. See `cursor.Mode`. A confining mode
    /// holds the pointer only while the window has focus.
    setCursorMode: *const fn (impl: Impl, native: NativeWindow, mode: cursor.Mode) Error!void,

    /// Ask for unaccelerated motion, and say whether it was granted. Only
    /// meaningful in `disabled` mode.
    setRawMouseMotion: *const fn (impl: Impl, native: NativeWindow, on: bool) bool,

    /// Put the pointer somewhere, in content-area coordinates.
    setCursorPos: *const fn (impl: Impl, native: NativeWindow, x: f64, y: f64) Error!void,

    /// Use one of the system's own cursor shapes.
    setCursorShape: *const fn (impl: Impl, native: NativeWindow, shape: cursor.Shape) Error!void,

    /// The user's scroll setting, asked for each time so a change is heard at once.
    scrollLines: *const fn (impl: Impl) input.ScrollLines,

    /// Fill `list` with what is attached now, and `modes` with every video mode
    /// any of them has.
    ///
    /// Two lists rather than one, because a monitor's `modes` is a slice into
    /// the second: growing one array while holding slices into it would leave
    /// every earlier monitor pointing at freed memory, so the backend appends
    /// all the modes first and the context fixes up the slices after.
    enumerateMonitors: *const fn (
        impl: Impl,
        list: *std.ArrayListUnmanaged(monitor.Monitor),
        modes: *std.ArrayListUnmanaged(monitor.VideoMode),
        gpa: Allocator,
    ) Error!void,

    /// The index into `list` of the monitor the window is on, or null if unknown.
    windowMonitor: *const fn (
        impl: Impl,
        native: NativeWindow,
        list: []const monitor.Monitor,
    ) ?usize,

    /// Fill a monitor, or go back to being a window.
    setFullscreen: *const fn (
        impl: Impl,
        native: NativeWindow,
        wanted: monitor.Fullscreen,
        target: ?*const monitor.Monitor,
    ) Error!void,

    /// Read every controller into `devices`, which the context owns.
    ///
    /// Called from `pump`, so a program that pumps has a fresh state and one
    /// that does not has the last one. A backend writes `raw` and, where the
    /// system already knows the layout - XInput, the kernel's gamepad spec,
    /// Android's button codes - `state` and `mapped` as well; the context fills
    /// in the rest from whatever mappings were loaded.
    ///
    /// No error: a controller that has just been unplugged mid-read is not a
    /// failure, it is a controller that is no longer connected.
    pollGamepads: *const fn (
        impl: Impl,
        devices: *[gamepad.max_devices]gamepad.Device,
    ) void,

    /// Bind this window's context to the calling thread.
    ///
    /// `error.Unavailable` where the window was made without one.
    makeContextCurrent: *const fn (impl: Impl, native: NativeWindow) Error!void,

    /// Unbind whatever this thread had, so another thread may take it.
    clearContext: *const fn (impl: Impl) void,

    /// Show what was drawn.
    swapBuffers: *const fn (impl: Impl, native: NativeWindow) Error!void,

    /// How many refreshes to wait before a swap. Applies to the context that is
    /// current on this thread, which is how every one of these APIs works.
    setSwapInterval: *const fn (impl: Impl, native: NativeWindow, interval: i32) Error!void,

    /// One GL entry point by name, or null where the driver has no such thing.
    ///
    /// Needs a current context on some drivers, which is why it takes the
    /// window rather than standing alone.
    getProcAddress: *const fn (
        impl: Impl,
        native: NativeWindow,
        name: [*:0]const u8,
    ) ?gl_mod.Proc,

    /// The config the window actually got, or null where it has no context.
    /// Not always what was asked for - a driver may hand back a newer version
    /// or fewer samples.
    contextConfig: *const fn (impl: Impl, native: NativeWindow) ?gl_mod.Config,

    /// Make a `VkSurfaceKHR` for this window.
    ///
    /// The instance and the surface are integers rather than types, and the
    /// entry point is looked up through the caller's own loader - see
    /// `vulkan.zig` for why a windowing library declares neither.
    createVulkanSurface: *const fn (
        impl: Impl,
        native: NativeWindow,
        instance: usize,
        get_proc: vulkan.GetInstanceProcAddr,
        allocator: ?*const anyopaque,
    ) Error!u64,

    /// Turn text input on or off for this window.
    ///
    /// On is what tells the system a text field has focus: it raises the soft
    /// keyboard on a phone and lets an input method open its candidate window.
    /// Off is the default, so a game never gets one by accident.
    setTextInput: *const fn (impl: Impl, native: NativeWindow, on: bool) Error!void,

    /// Where the caret is, so an input method can put its candidates near it
    /// and not on top of it. In the window's own coordinates.
    setTextInputArea: *const fn (impl: Impl, native: NativeWindow, area: text.Area) Error!void,

    /// What is being composed right now, or null where nothing is.
    ///
    /// Owned by the backend and valid until the next `pump`.
    preedit: *const fn (impl: Impl) ?*const text.Preedit,

    /// Put text on the system clipboard. Checked by the context first: it is
    /// UTF-8, and a backend converts only what its system keeps differently.
    setClipboardText: *const fn (impl: Impl, text: []const u8) Error!void,

    /// Append the clipboard's text to `out`, as UTF-8 in whatever shape the
    /// system keeps it, or nothing when it holds no text. Line endings and
    /// broken bytes are the context's to tidy, once for every backend.
    clipboardText: *const fn (
        impl: Impl,
        out: *std.ArrayListUnmanaged(u8),
        gpa: Allocator,
    ) Error!void,

    /// Whether the clipboard holds text, asked without reading it.
    hasClipboardText: *const fn (impl: Impl) bool,

    /// Open the system's file or folder dialog, and return without waiting
    /// for it. A later `pump` pushes the answer as `.file_dialog` - always,
    /// with no paths when nothing was chosen - and until then another is
    /// refused with `error.Unavailable`.
    showFileDialog: *const fn (impl: Impl, gpa: Allocator, request: DialogRequest) Error!void,

    /// Append the bytes of the `index`th file of the last answer, whose path
    /// in that answer was `path`. A backend whose answers are paths reads the
    /// path; one whose answers are names reads what it kept of the choice.
    chosenFile: *const fn (
        impl: Impl,
        index: usize,
        path: []const u8,
        out: *std.ArrayListUnmanaged(u8),
        gpa: Allocator,
    ) Error!void,

    /// The windowing system's own handle, as a number.
    ///
    /// A number rather than a pointer because not every platform's handle is
    /// one: an X11 `Window` is a 32-bit id, and casting it to a pointer to hand
    /// it back would be a lie the caller then has to undo. Zero means there is
    /// no handle to give.
    nativeHandle: *const fn (impl: Impl, native: NativeWindow) usize,
};

/// The events one pump produced, in the order the system reported them.
///
/// A growable buffer with a read cursor rather than a ring: a pump appends,
/// `next` walks, and draining resets both. Nothing wraps, so an event's slice
/// payload - a drop's paths - stays valid until the next pump, which is exactly
/// what `DropEvent` promises.
pub const Queue = struct {
    gpa: Allocator,
    items: std.ArrayListUnmanaged(event.Event) = .empty,
    read: usize = 0,

    pub fn init(gpa: Allocator) Queue {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Queue) void {
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    /// Add one event. Called by a backend, from inside `pump`.
    pub fn push(self: *Queue, ev: event.Event) Allocator.Error!void {
        try self.items.append(self.gpa, ev);
    }

    /// The next event, or null when this pump's events have all been read.
    pub fn next(self: *Queue) ?event.Event {
        if (self.read >= self.items.items.len) return null;
        defer self.read += 1;
        return self.items.items[self.read];
    }

    /// Are there unread events?
    pub fn pending(self: *const Queue) bool {
        return self.read < self.items.items.len;
    }

    /// Forget everything, keeping the memory for the next pump.
    pub fn clear(self: *Queue) void {
        self.items.clearRetainingCapacity();
        self.read = 0;
    }
};

/// Events a backend made outside a pump, kept for the next one: Windows answers
/// a program's own `maximize` at once, and a Wayland roundtrip runs listeners.
/// Not a drop or a dialog's answer, whose paths would not live that long.
pub const Later = struct {
    items: std.ArrayListUnmanaged(event.Event) = .empty,

    pub const max = 256;

    pub fn keep(self: *Later, gpa: Allocator, ev: event.Event) void {
        switch (ev) {
            .drop, .file_dialog => return,
            else => {},
        }
        if (self.items.items.len >= max) return;
        self.items.append(gpa, ev) catch {};
    }

    pub fn hand(self: *Later, queue: *Queue) Allocator.Error!void {
        defer self.items.clearRetainingCapacity();
        for (self.items.items) |ev| try queue.push(ev);
    }

    pub fn deinit(self: *Later, gpa: Allocator) void {
        self.items.deinit(gpa);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "what happened between pumps waits for the next one, paths aside" {
    var later: Later = .{};
    defer later.deinit(testing.allocator);
    var queue: Queue = .init(testing.allocator);
    defer queue.deinit();
    const id: event.WindowId = @enumFromInt(1);

    later.keep(testing.allocator, .{ .maximize = .{ .window = id, .value = true } });
    later.keep(testing.allocator, .{ .drop = .{ .window = id, .paths = &.{"gone.png"} } });
    later.keep(testing.allocator, .{ .iconify = .{ .window = id, .value = true } });
    try later.hand(&queue);

    try testing.expect(queue.next().? == .maximize);
    try testing.expect(queue.next().? == .iconify);
    try testing.expectEqual(@as(?event.Event, null), queue.next());
    try testing.expectEqual(@as(usize, 0), later.items.items.len);

    for (0..Later.max + 10) |_| later.keep(testing.allocator, .{ .close = id });
    try testing.expectEqual(@as(usize, Later.max), later.items.items.len);
}

test "a queue hands events back in the order they arrived" {
    var queue: Queue = .init(testing.allocator);
    defer queue.deinit();

    try testing.expect(!queue.pending());
    try testing.expectEqual(@as(?event.Event, null), queue.next());

    const first: event.WindowId = @enumFromInt(1);
    const second: event.WindowId = @enumFromInt(2);
    try queue.push(.{ .close = first });
    try queue.push(.{ .refresh = second });

    try testing.expect(queue.pending());
    try testing.expectEqual(first, queue.next().?.window());
    try testing.expectEqual(second, queue.next().?.window());
    try testing.expectEqual(@as(?event.Event, null), queue.next());
    try testing.expect(!queue.pending());
}

test "clearing keeps the memory and forgets the events" {
    var queue: Queue = .init(testing.allocator);
    defer queue.deinit();

    try queue.push(.{ .suspended = {} });
    _ = queue.next();
    const capacity = queue.items.capacity;

    queue.clear();
    try testing.expect(!queue.pending());
    try testing.expectEqual(@as(usize, 0), queue.read);
    // The point of `clear` over `deinit`: the next pump does not allocate again.
    try testing.expectEqual(capacity, queue.items.capacity);
}

test "a size is brought inside its limits, and zero is no limit" {
    const limits: SizeLimits = .{ .min_width = 200, .min_height = 150, .max_width = 800 };
    try testing.expectEqual([2]u32{ 200, 150 }, limits.clamp(.{ 100, 100 }));
    try testing.expectEqual([2]u32{ 800, 5000 }, limits.clamp(.{ 1000, 5000 }));
    try testing.expectEqual([2]u32{ 640, 480 }, limits.clamp(.{ 640, 480 }));
    try testing.expectEqual([2]u32{ 1, 1 }, (SizeLimits{}).clamp(.{ 1, 1 }));

    const contradicting: SizeLimits = .{ .min_width = 900, .max_width = 600 };
    try testing.expectEqual(@as(u32, 600), contradicting.clamp(.{ 100, 100 })[0]);
}

test "a half-read queue keeps the rest" {
    var queue: Queue = .init(testing.allocator);
    defer queue.deinit();

    for (0..4) |i| try queue.push(.{ .close = @enumFromInt(@as(u32, @intCast(i + 1))) });

    try testing.expectEqual(@as(u32, 1), @intFromEnum(queue.next().?.window()));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(queue.next().?.window()));
    try testing.expect(queue.pending());
    try testing.expectEqual(@as(u32, 3), @intFromEnum(queue.next().?.window()));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(queue.next().?.window()));
    try testing.expect(!queue.pending());
}
