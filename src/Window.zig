// SPDX-License-Identifier: BSL-1.0

//! One window: a handle, and what can be asked of it.
//!
//! A `Window` is an id and the context it belongs to, not the window itself.
//! Copying one is free and copies nothing; the window lives in the context and
//! dies with `destroy`. That is what lets an event name a window without
//! handing out a pointer that may already be stale - `Context.window` turns an
//! id back into a handle, or into null if it has gone.
//!
//! **`shouldClose` is a flag, not a state.** The system never closes a window
//! on its own: a `.close` event says the user asked, and it is the program that
//! decides. `setShouldClose(true)` is how a loop is told to end, and a program
//! that wants to ask "save first?" simply does not set it.

const std = @import("std");
const testing = std.testing;

const backend = @import("backend.zig");
const cursor = @import("cursor.zig");
const monitor_mod = @import("monitor.zig");
const gl = @import("gl.zig");
const vulkan = @import("vulkan.zig");
const text = @import("text.zig");
const event = @import("event.zig");
const platform = @import("platform.zig");
const Context = @import("Context.zig");

const Window = @This();

pub const Error = platform.Error;

/// What the context keeps for each window. Not public: a program holds a
/// `Window`, and the context holds these.
pub const Entry = struct {
    native: backend.NativeWindow,
    should_close: bool,
    /// Remembered here rather than asked of the system every time: not every
    /// backend can be asked, and the answer is the program's own request.
    cursor_mode: cursor.Mode = .normal,
    raw_motion: bool = false,
    fullscreen: monitor_mod.Fullscreen = .windowed,
    text_input: bool = false,
};

/// What a window is being asked for.
///
/// Every field has a default that is right for a game: a resizable, decorated,
/// visible window of a size that fits on any monitor made this century.
pub const Desc = struct {
    title: []const u8 = "fluxion",
    width: u32 = 1280,
    height: u32 = 720,
    /// Can the user resize it? A fixed-size window still changes size when the
    /// DPI does, so a program cannot treat this as "the size never changes".
    resizable: bool = true,
    /// Title bar and border. False for a splash screen or a game that draws its
    /// own frame.
    decorated: bool = true,
    /// Shown as soon as it is made. False to set a position or an icon first
    /// and avoid the window appearing in the wrong place for a frame.
    visible: bool = true,
    maximized: bool = false,

    /// Ask for an OpenGL context along with the window, or leave it null for
    /// one that draws some other way - Vulkan, or the system's own painting.
    ///
    /// It has to be decided here. See `gl` for why no platform lets a window
    /// change its mind afterwards.
    gl: ?gl.Config = null,
};

ctx: *Context,
id: event.WindowId,

/// Close it. Every handle to this window is stale afterwards, and the id it
/// used is never handed out again.
pub fn destroy(self: Window) void {
    self.ctx.destroyWindow(self.id);
}

/// Is this handle still a window? False after `destroy`, and after the backend
/// took the window away.
pub fn alive(self: Window) bool {
    return self.ctx.entry(self.id) != null;
}

/// Has anything asked for this window to close?
pub fn shouldClose(self: Window) bool {
    const e = self.ctx.entry(self.id) orelse return true;
    return e.should_close;
}

/// Set or clear the flag. The usual answer to a `.close` event, and the usual
/// way to end a loop from somewhere else.
pub fn setShouldClose(self: Window, value: bool) void {
    const e = self.ctx.entry(self.id) orelse return;
    e.should_close = value;
}

pub fn setTitle(self: Window, title: []const u8) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    return self.ctx.vtable.setTitle(self.ctx.impl, e.native, title);
}

pub fn show(self: Window) void {
    const e = self.ctx.entry(self.id) orelse return;
    self.ctx.vtable.setVisible(self.ctx.impl, e.native, true);
}

pub fn hide(self: Window) void {
    const e = self.ctx.entry(self.id) orelse return;
    self.ctx.vtable.setVisible(self.ctx.impl, e.native, false);
}

/// The content area in logical units - what a layout is written in.
pub fn size(self: Window) [2]u32 {
    const e = self.ctx.entry(self.id) orelse return .{ 0, 0 };
    return self.ctx.vtable.size(self.ctx.impl, e.native);
}

/// The drawable in pixels - what a swapchain, a viewport and a scissor want.
///
/// Not the same as `size` on a HiDPI display, and the difference is the bug
/// that renders a quarter of the window on a laptop screen.
pub fn framebufferSize(self: Window) [2]u32 {
    const e = self.ctx.entry(self.id) orelse return .{ 0, 0 };
    return self.ctx.vtable.framebufferSize(self.ctx.impl, e.native);
}

/// Pixels per logical unit, per axis. 1.0 on an ordinary display, 2.0 on a
/// HiDPI one, and it changes when the window moves between monitors.
pub fn contentScale(self: Window) [2]f32 {
    const e = self.ctx.entry(self.id) orelse return .{ 1, 1 };
    return self.ctx.vtable.contentScale(self.ctx.impl, e.native);
}

/// Where the window is, in screen coordinates, measured to the top left of the
/// content area.
///
/// Zero on Wayland, which deliberately does not tell a program where its own
/// window is - the compositor places windows, and a client that knew could
/// fight it.
pub fn position(self: Window) [2]i32 {
    const e = self.ctx.entry(self.id) orelse return .{ 0, 0 };
    return self.ctx.vtable.position(self.ctx.impl, e.native);
}

pub fn setPosition(self: Window, x: i32, y: i32) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    return self.ctx.vtable.setPosition(self.ctx.impl, e.native, x, y);
}

/// Resize the content area, in logical units.
pub fn setSize(self: Window, width: u32, height: u32) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    return self.ctx.vtable.setSize(self.ctx.impl, e.native, width, height);
}

/// Minimise it.
pub fn iconify(self: Window) Error!void {
    return self.setState(.iconified);
}

/// Fill the work area.
pub fn maximize(self: Window) Error!void {
    return self.setState(.maximized);
}

/// Undo either of those, in one step: neither minimised nor maximised after it.
pub fn restore(self: Window) Error!void {
    return self.setState(.restored);
}

/// Raise it and take the keyboard. Most systems refuse this from a program
/// that does not already have focus, and `requestAttention` is the polite
/// version.
pub fn focus(self: Window) Error!void {
    return self.setState(.focused);
}

/// Ask to be noticed - a flashing taskbar entry, a bouncing icon. What the
/// system does with it is the system's business.
pub fn requestAttention(self: Window) Error!void {
    return self.setState(.attention);
}

fn setState(self: Window, wanted: backend.WindowState) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    return self.ctx.vtable.setState(self.ctx.impl, e.native, wanted);
}

pub fn isIconified(self: Window) bool {
    return self.getState(.iconified);
}

pub fn isMaximized(self: Window) bool {
    return self.getState(.maximized);
}

pub fn isFocused(self: Window) bool {
    return self.getState(.focused);
}

fn getState(self: Window, which: backend.WindowState) bool {
    const e = self.ctx.entry(self.id) orelse return false;
    return self.ctx.vtable.getState(self.ctx.impl, e.native, which);
}

/// The bounds the user may resize within, in logical units. Zero on an edge
/// means no limit there.
pub fn setSizeLimits(self: Window, limits: backend.SizeLimits) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    return self.ctx.vtable.setSizeLimits(self.ctx.impl, e.native, limits);
}

/// How see-through the whole window is, from 0 for invisible to 1 for solid.
pub fn setOpacity(self: Window, opacity: f32) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    return self.ctx.vtable.setOpacity(self.ctx.impl, e.native, opacity);
}

// -------------------------------------------------------------------------
// Text input
// -------------------------------------------------------------------------

/// Say whether a text field has focus.
///
/// Off by default, and worth leaving off: this is what raises the soft keyboard
/// on a phone and what lets an input method open its candidate window over the
/// top of whatever is being drawn. A game turns it on when a chat box opens and
/// off again when it closes.
///
/// `.char` events arrive either way on a desktop - a keyboard is a keyboard.
/// What changes is whether an input method gets to sit between the two.
pub fn setTextInput(self: Window, on: bool) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    try self.ctx.vtable.setTextInput(self.ctx.impl, e.native, on);
    e.text_input = on;
}

/// Is it on?
pub fn textInput(self: Window) bool {
    const e = self.ctx.entry(self.id) orelse return false;
    return e.text_input;
}

/// Where the caret is, so an input method's candidate list appears next to the
/// text rather than across it.
///
/// In content-area coordinates, the framebuffer's pixels: the caret's position
/// and how tall the line is. Worth setting whenever the caret moves, and
/// refused by a backend that has nowhere to put it.
pub fn setTextInputArea(self: Window, area: text.Area) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    try self.ctx.vtable.setTextInputArea(self.ctx.impl, e.native, area);
}

// -------------------------------------------------------------------------
// OpenGL
// -------------------------------------------------------------------------

/// Bind this window's context to the calling thread.
///
/// Every GL call goes to whichever context is current on the thread making it,
/// so this comes before the first one and after any thread switch.
/// `error.Unavailable` if the window was made without a context.
pub fn makeContextCurrent(self: Window) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    try self.ctx.vtable.makeContextCurrent(self.ctx.impl, e.native);
}

/// Show what was drawn.
///
/// The end of a frame. With a swap interval of one this is also where the
/// program waits for the display, which is why a frame's timing is measured
/// around it rather than inside it.
pub fn swapBuffers(self: Window) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    try self.ctx.vtable.swapBuffers(self.ctx.impl, e.native);
}

/// How many display refreshes to wait before showing a frame.
///
/// `.vsync` for a program that wants no tearing, `.immediate` for one that is
/// measuring how fast it can draw. `.adaptive` tears on a late frame rather
/// than dropping to half the refresh rate, and is refused where the driver has
/// no such extension.
///
/// Applies to the context current on this thread, so `makeContextCurrent`
/// comes first.
pub fn setSwapInterval(self: Window, interval: gl.SwapInterval) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    try self.ctx.vtable.setSwapInterval(self.ctx.impl, e.native, interval.toInt());
}

/// The address of one GL entry point, or null where this driver has none.
///
/// What a loader is fed. Null is an ordinary answer, so a loader should check
/// rather than assume.
///
/// **A non-null answer is not proof the function exists.** WGL and GLX return
/// null for a name the driver has never heard of, but EGL is allowed to return
/// a dispatch stub for anything beginning with `gl` - and Mesa does, so on
/// Wayland and on Android a misspelled name comes back as a perfectly valid
/// pointer to something that will not work. The version and the extension
/// string are the authority on what a context actually has; this call only says
/// where to find it.
pub fn getProcAddress(self: Window, name: [*:0]const u8) ?gl.Proc {
    const e = self.ctx.entry(self.id) orelse return null;
    return self.ctx.vtable.getProcAddress(self.ctx.impl, e.native, name);
}

/// `getProcAddress` under the name `fluxion-dyn` looks for.
///
/// A `dyn` resolver is a `getProcAddress` function or a value with a public
/// `get` method, and every table loader built on it - `fluxion-gl` first among
/// them - takes one of those. So a window with a context is itself the thing
/// to hand `load`, with nothing in between:
///
/// ```zig
/// var api: opengl.Gl = undefined;
/// try api.load(win);
/// ```
///
/// The window already looks in both places a command can be - the context's
/// extension mechanism and the GL library's own exports - so no `Chain` is
/// needed around it.
pub fn get(self: Window, name: [*:0]const u8) ?gl.Proc {
    return self.getProcAddress(name);
}

/// What the context actually is, which is not always what was asked for: a
/// driver may hand back a newer version, or fewer samples than requested.
///
/// Null where the window has no context.
pub fn contextConfig(self: Window) ?gl.Config {
    const e = self.ctx.entry(self.id) orelse return null;
    return self.ctx.vtable.contextConfig(self.ctx.impl, e.native);
}

// -------------------------------------------------------------------------
// Vulkan
// -------------------------------------------------------------------------

/// Make a `VkSurfaceKHR` for this window.
///
/// `instance` is a `VkInstance` as an integer and the return is a
/// `VkSurfaceKHR` as one, because neither is a type this library can declare
/// without dragging in half of `vulkan.h`. `get_proc` is the caller's own
/// `vkGetInstanceProcAddr`.
///
/// The instance must already have the extensions
/// `vulkan.requiredInstanceExtensions` named, or the entry point this needs
/// does not exist and the call fails with `error.Unavailable`.
///
/// **The surface is the caller's to destroy**, with `vkDestroySurfaceKHR`,
/// before the window and before the instance.
pub fn createVulkanSurface(
    self: Window,
    instance: usize,
    get_proc: vulkan.GetInstanceProcAddr,
    allocator: ?*const anyopaque,
) Error!u64 {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    return self.ctx.vtable.createVulkanSurface(
        self.ctx.impl,
        e.native,
        instance,
        get_proc,
        allocator,
    );
}

/// Fill a monitor, or go back to being a window.
///
/// `.borderless` is what a modern game should use: the monitor keeps the mode
/// it is already in, so alt-tab is instant and nothing else on the desktop is
/// resized. `.exclusive` switches the display, which is slower to leave and
/// rearranges every other window on the machine - worth it only when a
/// different resolution genuinely is the point.
///
/// The index is into `Context.monitors`.
pub fn setFullscreen(self: Window, wanted: monitor_mod.Fullscreen) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;

    const target: ?*const monitor_mod.Monitor = if (wanted.monitorIndex()) |index| blk: {
        const list = self.ctx.monitors();
        if (index >= list.len) return error.Unavailable;
        break :blk &list[index];
    } else null;

    try self.ctx.vtable.setFullscreen(self.ctx.impl, e.native, wanted, target);
    e.fullscreen = wanted;
}

/// What it is now.
pub fn fullscreen(self: Window) monitor_mod.Fullscreen {
    const e = self.ctx.entry(self.id) orelse return .windowed;
    return e.fullscreen;
}

/// The index into `Context.monitors` of the monitor the window is on; the
/// primary one where the system cannot tell, and null only with no monitors.
pub fn monitor(self: Window) ?usize {
    const e = self.ctx.entry(self.id) orelse return null;
    const list = self.ctx.monitors();
    if (list.len == 0) return null;
    if (self.ctx.vtable.windowMonitor(self.ctx.impl, e.native, list)) |index| return index;
    for (list, 0..) |mon, index| {
        if (mon.primary) return index;
    }
    return 0;
}

/// Hide the pointer, confine it, or take it out of the picture entirely.
///
/// `.disabled` is the one a first-person camera needs: from then on the
/// `.cursor` events carry `dx` and `dy` that keep going in whichever direction
/// the mouse moved, and `x` and `y` stop meaning anything. `.confined_hidden`
/// is the other half of that pair - held and unseen, but still somewhere - for
/// a program that draws its own pointer. See `cursor.Mode`.
pub fn setCursorMode(self: Window, mode: cursor.Mode) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    try self.ctx.vtable.setCursorMode(self.ctx.impl, e.native, mode);
    e.cursor_mode = mode;
}

/// Which mode it is in now.
pub fn cursorMode(self: Window) cursor.Mode {
    const e = self.ctx.entry(self.id) orelse return .normal;
    return e.cursor_mode;
}

/// Ask for motion that has not been through pointer acceleration.
///
/// Returns whether it was actually turned on: not every system can, and the
/// answer is worth knowing rather than assuming. Only has an effect in
/// `.disabled` mode, because there is no cursor left to accelerate.
pub fn setRawMouseMotion(self: Window, on: bool) bool {
    const e = self.ctx.entry(self.id) orelse return false;
    const granted = self.ctx.vtable.setRawMouseMotion(self.ctx.impl, e.native, on);
    e.raw_motion = granted and on;
    return e.raw_motion;
}

/// Is unaccelerated motion on?
pub fn rawMouseMotion(self: Window) bool {
    const e = self.ctx.entry(self.id) orelse return false;
    return e.raw_motion;
}

/// Put the pointer somewhere in the content area, in the framebuffer's pixels.
///
/// Rarely what a program wants: warping the cursor under the user's hand is
/// jarring, and in `.disabled` mode it does nothing useful because there is no
/// cursor to move. It exists for the cases that genuinely need it - recentring
/// after a menu, restoring a position across a mode change.
pub fn setCursorPos(self: Window, x: f64, y: f64) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    return self.ctx.vtable.setCursorPos(self.ctx.impl, e.native, x, y);
}

/// Use one of the system's own cursor shapes over this window.
///
/// `error.Unavailable` for a shape this system has not got - `Shape.optional()`
/// names those, and `arrow`, which is everywhere, is what to use instead.
pub fn setCursorShape(self: Window, shape: cursor.Shape) Error!void {
    const e = self.ctx.entry(self.id) orelse return error.Unavailable;
    return self.ctx.vtable.setCursorShape(self.ctx.impl, e.native, shape);
}

/// The windowing system's own handle, as a number: an `HWND`, an X11 `Window`,
/// a `wl_surface`, an `ANativeWindow`. Zero if this handle is stale, or if the
/// backend has none to give.
///
/// The escape hatch, for the call this library does not wrap. What it names
/// depends on `Context.backend`, and reading it wrong is a crash rather than an
/// error, so check the backend first:
///
/// ```zig
/// if (ctx.backend() == .win32) {
///     const hwnd: ?*anyopaque = @ptrFromInt(win.native());
/// }
/// ```
///
/// A number rather than a pointer because not every platform's handle is one -
/// an X11 `Window` is an id, not an address.
pub fn native(self: Window) usize {
    const e = self.ctx.entry(self.id) orelse return 0;
    return self.ctx.vtable.nativeHandle(self.ctx.impl, e.native);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a stale handle answers rather than crashing" {
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    // An id that names nothing, which is what a handle to a destroyed window
    // is. Every accessor has to have an answer for it.
    const stale: Window = .{ .ctx = &ctx, .id = @enumFromInt(999) };

    try testing.expect(!stale.alive());
    // True, because a loop written as `while (!win.shouldClose())` must end
    // when the window has gone rather than spin forever.
    try testing.expect(stale.shouldClose());
    try testing.expectEqual(@as(usize, 0), stale.native());
    try testing.expectEqual([2]u32{ 0, 0 }, stale.size());
    try testing.expectEqual([2]u32{ 0, 0 }, stale.framebufferSize());
    try testing.expectEqual([2]f32{ 1, 1 }, stale.contentScale());
    try testing.expectEqual(@as(?usize, null), stale.monitor());
    try testing.expectError(error.Unavailable, stale.setTitle("nothing"));

    // And the ones that return nothing simply do nothing.
    stale.setShouldClose(false);
    stale.show();
    stale.hide();
    stale.destroy();
}

test "the defaults are a window a game would want" {
    const desc: Desc = .{};
    try testing.expectEqual(@as(u32, 1280), desc.width);
    try testing.expectEqual(@as(u32, 720), desc.height);
    try testing.expect(desc.resizable);
    try testing.expect(desc.decorated);
    try testing.expect(desc.visible);
    try testing.expect(!desc.maximized);
}

test "a handle is small enough to copy without thinking about it" {
    // The property the whole design rests on: a `Window` in an event handler,
    // in a struct, in an array, is the same window and costs nothing to carry.
    // Two pointers rather than the exact sum, because the id is padded out to
    // the pointer's alignment.
    try testing.expect(@sizeOf(Window) <= 2 * @sizeOf(*Context));
    try testing.expect(@sizeOf(Window) >= @sizeOf(*Context) + @sizeOf(event.WindowId));
}

test "a window is a resolver fluxion-dyn accepts" {
    // The contract is duck-typed - a public `get(name) ?Proc` - and this is
    // where it is checked, so that a loader built on `fluxion-dyn` can take
    // the window itself rather than a wrapper somebody had to write.
    const dyn = @import("fluxion_dyn");
    try testing.expect(dyn.resolver.isResolver(Window));
    try testing.expect(dyn.resolver.isResolver(*const Window));

    // And on a backend with no display, asking answers null rather than
    // crashing - the same answer as for a name the driver has never heard of.
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();
    const stale: Window = .{ .ctx = &ctx, .id = @enumFromInt(7) };
    try testing.expectEqual(@as(?gl.Proc, null), stale.get("glClear"));
}
