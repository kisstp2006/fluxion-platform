// SPDX-License-Identifier: BSL-1.0

//! The web backend: a `<canvas>`, and the page around it.
//!
//! A WebAssembly module in a browser has no windowing system to open, only a
//! page that instantiated it and chose what to hand over. So this backend is
//! half a file: the other half is `web.js`, which lives beside it, listens to
//! the page, and implements every import `web_imports.zig` declares. The two
//! meet at `drain`, which moves what the page heard into a buffer this side
//! turns into events - the same queue, filled the same way, as every other
//! backend fills it.
//!
//! **A window is a canvas.** The first windows take the canvases the page
//! handed the glue, in order, and any after that are made and appended to the
//! page. A title is `document.title`, maximised is filling the page, focus is
//! the keyboard's focus, and a size is CSS pixels - which is this backend's
//! logical unit, as a point is on a Mac. The drawing buffer is in device
//! pixels, kept equal to the canvas's own size on screen so that nothing is
//! drawn blurry.
//!
//! **A browser owns the loop, and there are two ways to live with that.** A
//! page cannot be blocked: nothing is drawn and no event is delivered until the
//! module returns to the browser. So either:
//!
//!   * the module exports `frame` - and `init` and `deinit` if it likes - and
//!     `web.js` calls it once per animation frame. Everything in the loop body
//!     is unchanged, `pump` included; only the `while` moves into the browser.
//!     This runs everywhere, and it is the shape `fluxion-webgl` already has.
//!   * or it has an ordinary `main` with an ordinary loop, and `pump` is where
//!     it gives the browser its turn. That needs the module to be *suspended*
//!     mid-call, which is what JavaScript Promise Integration is for: Chrome
//!     and Edge since 137 and Firefox since 153 have it, Safari does not yet,
//!     and the glue says so by name rather than hanging the tab.
//!
//! **What a page cannot do is refused by name.** There is no screen position
//! to read or set, no iconified state, no confined-but-visible cursor, no
//! warping the pointer, no display mode to switch, and no Vulkan. Each of
//! those is `error.Unavailable` rather than a quiet no-op, the same as on
//! every other backend that lacks one.
//!
//! **A few things need a person to have just done something.** Browsers grant
//! pointer lock, fullscreen and the soft keyboard only in answer to a click or
//! a key. The call is accepted either way; if the browser turns it down, the
//! glue asks again inside the next click or key press on the canvas. That is
//! what "click to capture the mouse" means on every web game.
//!
//! **OpenGL is WebGL, and it is not reached through addresses.** A window made
//! with `.gl` gets a WebGL context on its canvas, and `contextConfig` says what
//! the browser actually gave. But `getProcAddress` answers null for every
//! name: WebGL is JavaScript, a wasm module calls it through imports rather
//! than pointers, and `fluxion-webgl` is the binding that declares them. A lost
//! context - a GPU reset, a phone reclaiming memory - arrives as
//! `.surface_lost`, and a restored one as `.surface_created`: the Android pair,
//! which a program that handles it is already correct for.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const backend = @import("../backend.zig");
const cursor_mod = @import("../cursor.zig");
const event = @import("../event.zig");
const gamepad = @import("../gamepad.zig");
const gl = @import("../gl.zig");
const keys = @import("../keys.zig");
const monitor = @import("../monitor.zig");
const platform = @import("../platform.zig");
const text_mod = @import("../text.zig");
const vulkan = @import("../vulkan.zig");
const web_gamepad = @import("web_gamepad.zig");
const web_keys = @import("web_keys.zig");
pub const wire = @import("web_wire.zig");

/// The page that is not there, for building and testing anywhere else. Always
/// safe to name: it is ordinary Zig.
pub const stub = @import("web_stub.zig");

/// The page, whichever kind this build has.
///
/// On a web build every call leaves the module as a WebAssembly import. On any
/// other it is `stub`, and every call is a function in this process. There is
/// no run-time branch: this is a type, chosen by the target.
///
/// `web_imports.zig` is reached only through this `if`, and that is load-
/// bearing. To every linker but wasm's, `extern "fluxion_platform"` names a
/// library to link against, and merely analysing the declarations would put
/// one on the link line - so a host build must never look inside the file.
pub const js = if (platform.is_web) @import("web_imports.zig") else stub;

const Error = platform.Error;

/// Records per drain. A pump that heard more than this drains again.
const record_capacity = 64;
/// Bytes of text per drain: `code` names, typed text, dropped file names.
const heap_capacity = 4096;

/// `createWindow`'s `flags`, bit by bit.
pub const window_flags = struct {
    pub const resizable: u32 = 1 << 0;
    pub const decorated: u32 = 1 << 1;
    pub const visible: u32 = 1 << 2;
    pub const maximized: u32 = 1 << 3;
};

/// `createWindow`'s `gl_flags`, bit by bit.
pub const context_flags = struct {
    pub const depth: u32 = 1 << 0;
    pub const stencil: u32 = 1 << 1;
    pub const antialias: u32 = 1 << 2;
};

const Impl = struct {
    gpa: Allocator,
    natives: std.ArrayListUnmanaged(*Native) = .empty,

    queue: ?*backend.Queue = null,
    push_failed: bool = false,

    /// What the input method is composing, as the last `.preedit` said.
    preedit: text_mod.Preedit = .{},

    /// Where one drain lands. Held here rather than on the stack: four
    /// kilobytes of records and four of text is more than a wasm stack should
    /// be asked for in the middle of somebody's frame.
    records: [record_capacity]wire.Record = undefined,
    heap: [heap_capacity]u8 = undefined,
    pads: [gamepad.max_devices]wire.GamepadRecord = undefined,

    /// The names of the last drop, kept until the next pump - which is how
    /// long `DropEvent` promises they last. Reset at the start of each pump.
    drops: std.heap.ArenaAllocator,
    drop_names: std.ArrayListUnmanaged([]const u8) = .empty,
    drop_window: event.WindowId = .none,
    drop_expected: usize = 0,
};

const Native = struct {
    id: event.WindowId,
    /// The glue's number for the canvas.
    handle: u32,
    /// CSS pixels.
    width: u32,
    height: u32,
    /// Device pixels.
    fb_width: u32,
    fb_height: u32,
    scale: f32,
    /// What the context actually is, or null for a window with none.
    gl_config: ?gl.Config = null,
    /// Between `.surface_lost` and `.surface_created`: the context is gone,
    /// and so is everything that was made with it.
    context_lost: bool = false,
};

pub const vtable: backend.Vtable = .{
    .backend = .web,
    .deinit = deinit,
    .createWindow = createWindow,
    .destroyWindow = destroyWindow,
    .pump = pump,
    .wait = wait,
    .post = post,
    .setTitle = setTitle,
    .setVisible = setVisible,
    .size = size,
    .framebufferSize = framebufferSize,
    .contentScale = contentScale,
    .nativeHandle = nativeHandle,
    .enumerateMonitors = enumerateMonitors,
    .pollGamepads = pollGamepads,
    .makeContextCurrent = makeContextCurrent,
    .clearContext = clearContext,
    .swapBuffers = swapBuffers,
    .setSwapInterval = setSwapInterval,
    .getProcAddress = getProcAddress,
    .contextConfig = contextConfig,
    .createVulkanSurface = createVulkanSurface,
    .setTextInput = setTextInput,
    .setTextInputArea = setTextInputArea,
    .preedit = preedit,
    .setFullscreen = setFullscreen,
    .setCursorMode = setCursorMode,
    .setRawMouseMotion = setRawMouseMotion,
    .setCursorPos = setCursorPos,
    .setCursorShape = setCursorShape,
    .position = position,
    .setPosition = setPosition,
    .setSize = setSize,
    .setState = setState,
    .getState = getState,
    .setSizeLimits = setSizeLimits,
    .setOpacity = setOpacity,
};

/// Start listening to the page.
///
/// `error.NoDisplay` where there is no page to listen to - a module running in
/// a worker has no `document` - which is the same answer a Linux machine with
/// no session gives, and for the same reason.
pub fn open(gpa: Allocator) Error!backend.Impl {
    const self = gpa.create(Impl) catch return error.OutOfMemory;
    errdefer gpa.destroy(self);

    if (js.open() == 0) return error.NoDisplay;
    self.* = .{ .gpa = gpa, .drops = .init(gpa) };
    return self;
}

fn deinit(impl: backend.Impl, gpa: Allocator) void {
    const self = cast(impl);
    js.close();
    self.natives.deinit(gpa);
    self.drops.deinit();
    gpa.destroy(self);
}

fn cast(impl: backend.Impl) *Impl {
    return @ptrCast(@alignCast(impl));
}

fn castWindow(native: backend.NativeWindow) *Native {
    return @ptrCast(@alignCast(native));
}

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------

/// What to ask the canvas for, worked out from a `gl.Config`.
pub const ContextRequest = struct {
    /// 0 for no context, 1 for WebGL 1 or better, 2 for WebGL 2 only.
    version: u32 = 0,
    flags: u32 = 0,
};

/// Which WebGL answers a config, or `error.Unavailable` where none can.
///
/// A browser has OpenGL ES and nothing else: WebGL 1 is ES 2.0 and WebGL 2 is
/// ES 3.0. So a request for desktop OpenGL is refused rather than quietly
/// handed ES - its shaders are a different language, and a program that asked
/// for 3.3 core would find that out from a compile error a long way from here.
/// ES 2.0 is satisfied by either, since "at least" is what a version means,
/// and ES 3.1 and later by neither.
///
/// Alpha is not asked for, whatever the config says. On the desktop an alpha
/// channel is storage; on a page it is transparency, and a canvas with one is
/// composited over whatever is behind it. `contextConfig` reports the zero
/// that results, which is the truth.
pub fn contextRequest(wanted: ?gl.Config) error{Unavailable}!ContextRequest {
    const config = wanted orelse return .{};
    if (config.api != .opengl_es) return error.Unavailable;

    const version: u32 = switch (config.major) {
        2 => 1,
        3 => if (config.minor == 0) 2 else return error.Unavailable,
        else => return error.Unavailable,
    };

    var flags: u32 = 0;
    if (config.depth_bits > 0) flags |= context_flags.depth;
    if (config.stencil_bits > 0) flags |= context_flags.stencil;
    if (config.samples > 0) flags |= context_flags.antialias;
    return .{ .version = version, .flags = flags };
}

/// The config a canvas's context actually has, from what the glue read back
/// out of it.
pub fn grantedConfig(info: wire.WindowInfo) gl.Config {
    return .{
        .api = .opengl_es,
        .major = if (info.gl_version >= 2) 3 else 2,
        .minor = 0,
        .profile = .any,
        .red_bits = clampBits(info.red_bits),
        .green_bits = clampBits(info.green_bits),
        .blue_bits = clampBits(info.blue_bits),
        .alpha_bits = clampBits(info.alpha_bits),
        .depth_bits = clampBits(info.depth_bits),
        .stencil_bits = clampBits(info.stencil_bits),
        .samples = clampBits(info.samples),
        // The drawing buffer is never sRGB-encoded on write: a canvas has a
        // colour space, which is a different thing, and no way to ask for
        // this one.
        .srgb = false,
        // A page always draws into a buffer the browser presents afterwards.
        .double_buffer = true,
        .debug = false,
        .forward_compatible = false,
    };
}

fn clampBits(value: u32) u8 {
    return @intCast(@min(value, 255));
}

fn createWindow(
    impl: backend.Impl,
    gpa: Allocator,
    id: event.WindowId,
    desc: backend.WindowDesc,
) Error!backend.NativeWindow {
    const self = cast(impl);
    const request = try contextRequest(desc.gl);

    const native = gpa.create(Native) catch return error.OutOfMemory;
    errdefer gpa.destroy(native);
    self.natives.ensureUnusedCapacity(gpa, 1) catch return error.OutOfMemory;

    var flags: u32 = 0;
    if (desc.resizable) flags |= window_flags.resizable;
    if (desc.decorated) flags |= window_flags.decorated;
    if (desc.visible) flags |= window_flags.visible;
    if (desc.maximized) flags |= window_flags.maximized;

    var info: wire.WindowInfo = .{};
    const handle = js.createWindow(
        @intFromEnum(id),
        desc.title.ptr,
        @intCast(desc.title.len),
        desc.width,
        desc.height,
        flags,
        request.version,
        request.flags,
        &info,
    );
    if (handle == 0) return error.WindowCreationFailed;

    // A canvas that could not have the context it was asked for is not the
    // window that was asked for. See `gl`: a window has its context from the
    // moment it exists or never.
    if (request.version != 0 and info.gl_version == 0) {
        js.destroyWindow(handle);
        return error.Unavailable;
    }

    native.* = .{
        .id = id,
        .handle = handle,
        .width = cssPixels(info.width),
        .height = cssPixels(info.height),
        .fb_width = info.fb_width,
        .fb_height = info.fb_height,
        .scale = if (info.scale > 0) @floatCast(info.scale) else 1,
        .gl_config = if (request.version != 0) grantedConfig(info) else null,
    };
    self.natives.appendAssumeCapacity(native);
    return native;
}

fn cssPixels(value: f64) u32 {
    if (!(value > 0)) return 0;
    return @intFromFloat(@round(@min(value, std.math.maxInt(u32))));
}

fn destroyWindow(impl: backend.Impl, gpa: Allocator, native: backend.NativeWindow) void {
    const self = cast(impl);
    const win = castWindow(native);
    js.destroyWindow(win.handle);
    for (self.natives.items, 0..) |candidate, index| {
        if (candidate == win) {
            _ = self.natives.swapRemove(index);
            break;
        }
    }
    gpa.destroy(win);
}

fn find(self: *Impl, id: event.WindowId) ?*Native {
    for (self.natives.items) |native| {
        if (native.id == id) return native;
    }
    return null;
}

/// `document.title`, which is the one title a page has. With two windows the
/// last one to set it wins, which is what a tab can show.
fn setTitle(impl: backend.Impl, native: backend.NativeWindow, title: []const u8) Error!void {
    _ = impl;
    js.setTitle(castWindow(native).handle, title.ptr, @intCast(title.len));
}

/// `visibility`, not `display`: a hidden canvas keeps its place and its size,
/// so a window made hidden and shown later is the size it was asked to be.
fn setVisible(impl: backend.Impl, native: backend.NativeWindow, visible: bool) void {
    _ = impl;
    js.setVisible(castWindow(native).handle, @intFromBool(visible));
}

/// CSS pixels, as the last pump reported them.
fn size(impl: backend.Impl, native: backend.NativeWindow) [2]u32 {
    _ = impl;
    const win = castWindow(native);
    return .{ win.width, win.height };
}

fn framebufferSize(impl: backend.Impl, native: backend.NativeWindow) [2]u32 {
    _ = impl;
    const win = castWindow(native);
    return .{ win.fb_width, win.fb_height };
}

/// `devicePixelRatio`, which is the display's scale times the page's zoom -
/// so it changes when the user presses ctrl and plus, and a `.scale` event
/// says so.
fn contentScale(impl: backend.Impl, native: backend.NativeWindow) [2]f32 {
    _ = impl;
    const scale = castWindow(native).scale;
    return .{ scale, scale };
}

/// The glue's number for the canvas. `Platform.canvas(handle)` on the
/// JavaScript side turns it back into the element, which is what a WebGPU
/// binding wants a surface made from.
fn nativeHandle(impl: backend.Impl, native: backend.NativeWindow) usize {
    _ = impl;
    return castWindow(native).handle;
}

/// Zero, always.
///
/// A page can read where its window is on the screen, but not where the
/// canvas is inside it - the browser's own toolbars are in between and no API
/// says how tall they are. So the honest answer is the one Wayland gives.
fn position(impl: backend.Impl, native: backend.NativeWindow) [2]i32 {
    _ = .{ impl, native };
    return .{ 0, 0 };
}

/// A page cannot move the browser's window, and moving the canvas around the
/// page is layout, which belongs to the page.
fn setPosition(impl: backend.Impl, native: backend.NativeWindow, x: i32, y: i32) Error!void {
    _ = .{ impl, native, x, y };
    return error.Unavailable;
}

/// The canvas's CSS size. Takes it out of filling the page, the way resizing a
/// maximised window restores it first.
fn setSize(impl: backend.Impl, native: backend.NativeWindow, width: u32, height: u32) Error!void {
    _ = impl;
    js.setSize(castWindow(native).handle, width, height);
}

/// Maximised is filling the page, restored is giving the space back, and
/// focused is taking the keyboard - which a page may do on its own. Iconified
/// and attention have no meaning inside a tab.
fn setState(impl: backend.Impl, native: backend.NativeWindow, wanted: backend.WindowState) Error!void {
    _ = impl;
    if (js.setState(castWindow(native).handle, @intFromEnum(wanted)) == 0) return error.Unavailable;
}

fn getState(impl: backend.Impl, native: backend.NativeWindow, which: backend.WindowState) bool {
    _ = impl;
    return js.getState(castWindow(native).handle, @intFromEnum(which)) != 0;
}

/// CSS `min-width` and the rest - which only mean anything while the page is
/// what decides the size, which is while the canvas fills it.
fn setSizeLimits(impl: backend.Impl, native: backend.NativeWindow, limits: backend.SizeLimits) Error!void {
    _ = impl;
    js.setSizeLimits(
        castWindow(native).handle,
        limits.min_width,
        limits.min_height,
        limits.max_width,
        limits.max_height,
    );
}

/// CSS `opacity`, which a canvas has like any element.
fn setOpacity(impl: backend.Impl, native: backend.NativeWindow, opacity: f32) Error!void {
    _ = impl;
    js.setOpacity(castWindow(native).handle, std.math.clamp(opacity, 0, 1));
}

// -------------------------------------------------------------------------
// The pointer
// -------------------------------------------------------------------------

/// `normal` and `hidden` are CSS; `disabled` is pointer lock, which the browser
/// grants on a click if it turned down the first request. `captured` is the
/// one no browser can do - a visible pointer held inside an element - and it
/// is refused rather than approximated.
fn setCursorMode(impl: backend.Impl, native: backend.NativeWindow, mode: cursor_mod.Mode) Error!void {
    _ = impl;
    if (js.setCursorMode(castWindow(native).handle, @intFromEnum(mode)) == 0) return error.Unavailable;
}

/// `unadjustedMovement`, which Chromium accepts on Windows, macOS and ChromeOS
/// and nothing else does yet. The answer is a guess until the first lock and
/// the truth after it: the glue learns it from whether the browser accepted.
fn setRawMouseMotion(impl: backend.Impl, native: backend.NativeWindow, on: bool) bool {
    _ = impl;
    return js.setRawMouseMotion(castWindow(native).handle, @intFromBool(on)) != 0;
}

/// A page cannot move the pointer, and should not be able to.
fn setCursorPos(impl: backend.Impl, native: backend.NativeWindow, x: f64, y: f64) Error!void {
    _ = .{ impl, native, x, y };
    return error.Unavailable;
}

/// CSS cursors, which have every shape `cursor.Shape` names.
fn setCursorShape(impl: backend.Impl, native: backend.NativeWindow, shape: cursor_mod.Shape) Error!void {
    _ = impl;
    if (js.setCursorShape(castWindow(native).handle, @intFromEnum(shape)) == 0) return error.Unavailable;
}

// -------------------------------------------------------------------------
// Monitors and fullscreen
// -------------------------------------------------------------------------

/// One screen: the one the page is on, which is the only one a page can see
/// without asking for a permission.
///
/// No mode list, because nothing on a page can switch one. The refresh rate is
/// measured rather than read - no browser reports it - and is zero until a
/// few frames have gone past to measure.
fn enumerateMonitors(
    impl: backend.Impl,
    list: *std.ArrayListUnmanaged(monitor.Monitor),
    modes: *std.ArrayListUnmanaged(monitor.VideoMode),
    gpa: Allocator,
) Error!void {
    _ = .{ impl, modes };
    var info: wire.MonitorInfo = .{};
    if (js.monitor(&info) == 0) return;
    try list.append(gpa, monitorFrom(info));
}

/// A `MonitorInfo` as a `Monitor`.
pub fn monitorFrom(info: wire.MonitorInfo) monitor.Monitor {
    const scale: f32 = if (info.scale > 0) @floatCast(info.scale) else 1;
    var mon: monitor.Monitor = .{
        // The screen's own units, which on a page are CSS pixels: the same
        // ones `screen.left` would be measured in.
        .bounds = .{
            .x = cssOffset(info.left),
            .y = cssOffset(info.top),
            .width = cssPixels(info.width),
            .height = cssPixels(info.height),
        },
        .work_area = .{
            .x = cssOffset(info.avail_left),
            .y = cssOffset(info.avail_top),
            .width = cssPixels(info.avail_width),
            .height = cssPixels(info.avail_height),
        },
        .scale_x = scale,
        .scale_y = scale,
        // And the mode in the panel's own pixels, which is what a mode is.
        .current = .{
            .width = cssPixels(info.width * info.scale),
            .height = cssPixels(info.height * info.scale),
            .bits = info.color_depth,
            .refresh_hz = info.refresh_hz,
        },
        .primary = true,
    };
    mon.setName("screen");
    return mon;
}

fn cssOffset(value: f64) i32 {
    if (std.math.isNan(value)) return 0;
    return @intFromFloat(@round(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32))));
}

/// The Fullscreen API on the canvas. `.borderless` is the only kind a page
/// has: nothing switches the display's mode, so `.exclusive` is refused.
///
/// The browser also takes fullscreen away on its own - escape always leaves
/// it - which arrives as the resize it is, while `Window.fullscreen` goes on
/// saying what the program last asked for.
fn setFullscreen(
    impl: backend.Impl,
    native: backend.NativeWindow,
    wanted: monitor.Fullscreen,
    target: ?*const monitor.Monitor,
) Error!void {
    _ = .{ impl, target };
    const handle = castWindow(native).handle;
    switch (wanted) {
        .exclusive => return error.Unavailable,
        .windowed => _ = js.setFullscreen(handle, 0),
        .borderless => if (js.setFullscreen(handle, 1) == 0) return error.Unavailable,
    }
}

// -------------------------------------------------------------------------
// Controllers
// -------------------------------------------------------------------------

/// `navigator.getGamepads()`, every pump. The browser's slot is the slot here,
/// so a pad keeps its number for as long as it is plugged in.
fn pollGamepads(impl: backend.Impl, devices: *[gamepad.max_devices]gamepad.Device) void {
    const self = cast(impl);
    const count = @min(js.gamepads(&self.pads, gamepad.max_devices), gamepad.max_devices);

    for (devices) |*device| device.* = .{};
    for (self.pads[0..count]) |*record| {
        if (record.index >= gamepad.max_devices) continue;
        web_gamepad.fill(&devices[record.index], record);
    }
}

// -------------------------------------------------------------------------
// WebGL
// -------------------------------------------------------------------------

/// Nothing to bind: a WebGL context is not current on a thread, it belongs to
/// the canvas it was made on. Refused for a window that has none, and while
/// the one it had is lost.
fn makeContextCurrent(impl: backend.Impl, native: backend.NativeWindow) Error!void {
    _ = impl;
    try usableContext(castWindow(native));
}

fn usableContext(win: *const Native) Error!void {
    if (win.gl_config == null or win.context_lost) return error.Unavailable;
}

fn clearContext(impl: backend.Impl) void {
    _ = impl;
}

/// Nothing to swap. The browser presents what was drawn when the module next
/// gives it control - the end of `frame`, or the next `pump` in a loop - and
/// this is accepted so that a loop written for the desktop needs no change.
fn swapBuffers(impl: backend.Impl, native: backend.NativeWindow) Error!void {
    _ = impl;
    try usableContext(castWindow(native));
}

/// One, and nothing else. A page is shown once per refresh of the display it
/// is on, and no call changes that - so `.vsync` is the truth and the other
/// two would be a promise this backend cannot keep.
fn setSwapInterval(impl: backend.Impl, native: backend.NativeWindow, interval: i32) Error!void {
    _ = impl;
    try usableContext(castWindow(native));
    if (interval != 1) return error.Unavailable;
}

/// Null, for every name. See the top of this file: WebGL is reached through
/// imports, and `fluxion-webgl` is the binding that has them.
fn getProcAddress(impl: backend.Impl, native: backend.NativeWindow, name: [*:0]const u8) ?gl.Proc {
    _ = .{ impl, native, name };
    return null;
}

fn contextConfig(impl: backend.Impl, native: backend.NativeWindow) ?gl.Config {
    _ = impl;
    const win = castWindow(native);
    if (win.context_lost) return null;
    return win.gl_config;
}

/// A browser has no Vulkan. Its modern API is WebGPU, which a binding makes
/// from the canvas `nativeHandle` names - not from a `VkInstance`.
fn createVulkanSurface(
    impl: backend.Impl,
    native: backend.NativeWindow,
    instance: usize,
    get_proc: vulkan.GetInstanceProcAddr,
    allocator: ?*const anyopaque,
) Error!u64 {
    _ = .{ impl, native, instance, get_proc, allocator };
    return error.Unavailable;
}

// -------------------------------------------------------------------------
// Text input
// -------------------------------------------------------------------------

/// Focus a hidden text field in front of the canvas, or put it away.
///
/// That field is how a page gets an input method and a soft keyboard at all:
/// both only ever attach to something editable. With it focused, typing goes
/// through the input method and arrives as `.char` and `.preedit`; without it,
/// `.char` comes straight from the keyboard, as on a desktop.
fn setTextInput(impl: backend.Impl, native: backend.NativeWindow, on: bool) Error!void {
    const self = cast(impl);
    if (js.setTextInput(castWindow(native).handle, @intFromBool(on)) == 0) return error.Unavailable;
    if (!on) self.preedit.clear();
}

/// Move the hidden field to the caret, which is where an input method opens
/// its candidates - it has no other way of knowing where the text is.
fn setTextInputArea(impl: backend.Impl, native: backend.NativeWindow, area: text_mod.Area) Error!void {
    _ = impl;
    js.setTextInputArea(castWindow(native).handle, area.x, area.y, area.width, area.height);
}

fn preedit(impl: backend.Impl) ?*const text_mod.Preedit {
    return &cast(impl).preedit;
}

// -------------------------------------------------------------------------
// The event loop
// -------------------------------------------------------------------------

/// Hand control to the browser if the program has a loop, then drain.
///
/// In the frame model `sync` returns at once, because returning from `frame`
/// is what gives the browser its turn. In the loop model it is that turn: the
/// module is suspended here until the next animation frame, which is when the
/// page is painted and the listeners that fill the queue get to run. A loop
/// that pumps once a frame is therefore paced by the display, the way a
/// desktop loop is paced by a swap.
fn pump(impl: backend.Impl, queue: *backend.Queue) Error!void {
    const self = cast(impl);

    self.queue = queue;
    self.push_failed = false;
    defer self.queue = null;

    js.sync();

    // The last drop's names were promised until now, and the queue that held
    // them has just been cleared.
    _ = self.drops.reset(.retain_capacity);
    self.drop_names = .empty;
    self.drop_expected = 0;

    while (true) {
        const count = @min(js.drain(&self.records, record_capacity, &self.heap, heap_capacity), record_capacity);
        if (count == 0) break;
        for (self.records[0..count]) |*record| translate(self, record);
    }

    if (self.push_failed) return error.OutOfMemory;
}

/// Sleep until the page hears something or `timeout_ms` passes - in the loop
/// model. A page in the frame model cannot be slept at all, and this returns
/// at once there.
fn wait(impl: backend.Impl, timeout_ms: ?u32) Error!void {
    _ = impl;
    js.wait(if (timeout_ms) |ms| @floatFromInt(ms) else -1);
}

/// Wake a `wait`. There is no other thread on a page to call this from, but a
/// program that calls it from its own code gets the answer it would get
/// anywhere else.
fn post(impl: backend.Impl) void {
    _ = impl;
    js.post();
}

/// One record, as whatever events it means.
fn translate(self: *Impl, record: *const wire.Record) void {
    const id: event.WindowId = @enumFromInt(record.window);
    const text = textOf(self, record);

    switch (record.kind) {
        .key => {
            const action = actionFrom(record.a) orelse return;
            const found = web_keys.fromCode(text);
            push(self, .{ .key = .{
                .window = id,
                .key = found.key,
                .scancode = found.scancode,
                .action = action,
                .mods = modsFrom(record.b),
            } });
        },

        .char => {
            const codepoint = charFrom(record.a) orelse return;
            push(self, .{ .char = .{ .window = id, .codepoint = codepoint, .mods = modsFrom(record.b) } });
        },

        .button => {
            const action = actionFrom(record.b) orelse return;
            // A button does not repeat; a stray one is a press.
            push(self, .{ .mouse_button = .{
                .window = id,
                .button = buttonFrom(record.a),
                .action = if (action == .repeat) .press else action,
                .mods = modsFrom(record.c),
                .x = record.x,
                .y = record.y,
            } });
        },

        .cursor => push(self, .{ .cursor = .{
            .window = id,
            .x = record.x,
            .y = record.y,
            .dx = record.dx,
            .dy = record.dy,
        } }),

        .scroll => {
            const amount = wheelSteps(record.a, record.x, record.y);
            if (amount[0] == 0 and amount[1] == 0) return;
            push(self, .{ .scroll = .{ .window = id, .x = amount[0], .y = amount[1], .mods = modsFrom(record.b) } });
        },

        .enter => push(self, .{ .cursor_enter = .{ .window = id, .value = record.a != 0 } }),
        .focus => push(self, .{ .focus = .{ .window = id, .value = record.a != 0 } }),
        .maximize => push(self, .{ .maximize = .{ .window = id, .value = record.a != 0 } }),

        .resize => resized(self, id, record),

        // A hidden tab is an app in the background: animation frames stop,
        // and a program should pause what it would pause on a phone.
        .visibility => push(self, if (record.a != 0) .suspended else .resumed),

        .preedit => {
            if (text.len == 0) self.preedit.clear() else self.preedit.set(text, record.a, record.b);
            push(self, .{ .preedit = id });
        },

        .drop_begin => {
            self.drop_names = .empty;
            self.drop_window = id;
            self.drop_expected = @intCast(@max(0, record.a));
        },

        .drop_file => {
            if (self.drop_expected == 0) return;
            const arena = self.drops.allocator();
            const name = arena.dupe(u8, text) catch return pushFailed(self);
            self.drop_names.append(arena, name) catch return pushFailed(self);
            if (self.drop_names.items.len < self.drop_expected) return;

            self.drop_expected = 0;
            push(self, .{ .drop = .{ .window = self.drop_window, .paths = self.drop_names.items } });
        },

        .surface_lost => {
            if (find(self, id)) |native| native.context_lost = true;
            push(self, .{ .surface_lost = id });
        },

        .surface_created => {
            const width: u32 = @intCast(@max(0, record.a));
            const height: u32 = @intCast(@max(0, record.b));
            if (find(self, id)) |native| {
                native.context_lost = false;
                native.fb_width = width;
                native.fb_height = height;
            }
            push(self, .{ .surface_created = .{ .window = id, .width = width, .height = height } });
        },

        .none, _ => {},
    }
}

/// A canvas changed size, or the page's scale did.
///
/// Every change is its own event, in the order a program wants to meet them:
/// the scale first, so that a layout redone on `.resize` is redone at the new
/// one; then the logical size and the pixels; then a refresh, because setting
/// a canvas's size clears it.
fn resized(self: *Impl, id: event.WindowId, record: *const wire.Record) void {
    const native = find(self, id) orelse return;

    const width: u32 = @intCast(@max(0, record.a));
    const height: u32 = @intCast(@max(0, record.b));
    const fb_width: u32 = @intCast(@max(0, record.c));
    const fb_height: u32 = @intCast(@max(0, record.d));
    const scale: f32 = if (record.x > 0) @floatCast(record.x) else native.scale;

    var changed = false;
    if (scale != native.scale) {
        native.scale = scale;
        push(self, .{ .scale = .{ .window = id, .x = scale, .y = scale } });
        changed = true;
    }
    if (width != native.width or height != native.height) {
        native.width = width;
        native.height = height;
        push(self, .{ .resize = .{ .window = id, .width = width, .height = height } });
        changed = true;
    }
    if (fb_width != native.fb_width or fb_height != native.fb_height) {
        native.fb_width = fb_width;
        native.fb_height = fb_height;
        push(self, .{ .framebuffer_resize = .{ .window = id, .width = fb_width, .height = fb_height } });
        changed = true;
    }
    if (changed) push(self, .{ .refresh = id });
}

/// The text a record carries, or nothing if its offsets point outside what
/// was drained - which would be a glue bug, and is not worth a crash.
fn textOf(self: *const Impl, record: *const wire.Record) []const u8 {
    const start: usize = record.text_offset;
    const len: usize = record.text_len;
    if (start > self.heap.len or len > self.heap.len - start) return "";
    return self.heap[start..][0..len];
}

fn push(self: *Impl, ev: event.Event) void {
    const queue = self.queue orelse return;
    queue.push(ev) catch {
        self.push_failed = true;
    };
}

fn pushFailed(self: *Impl) void {
    self.push_failed = true;
}

// -------------------------------------------------------------------------
// The translations, one number at a time
// -------------------------------------------------------------------------

/// The glue's modifier bits, which are `keys.Mods` bit for bit: shift,
/// control, alt, meta, caps lock, num lock. Anything above is dropped rather
/// than landing in the padding.
pub fn modsFrom(bits: i32) keys.Mods {
    const byte: u8 = @truncate(@as(u32, @bitCast(bits)));
    return @bitCast(byte & 0b0011_1111);
}

/// 0 release, 1 press, 2 repeat - the order of `keys.Action`, and the glue
/// sends nothing else.
pub fn actionFrom(value: i32) ?keys.Action {
    return switch (value) {
        0 => .release,
        1 => .press,
        2 => .repeat,
        else => null,
    };
}

/// `MouseEvent.button`, which counts left, middle, right - where this library
/// counts left, right, middle, as GLFW does.
pub fn buttonFrom(dom: i32) keys.MouseButton {
    return switch (dom) {
        0 => .left,
        1 => .middle,
        2 => .right,
        3 => .button_4,
        4 => .button_5,
        else => @enumFromInt(@as(u8, @intCast(std.math.clamp(dom, 0, 255)))),
    };
}

/// A codepoint the page typed, or null where it is not text.
///
/// The same rule the Win32 backend applies to `WM_CHAR`: control codes are
/// `.key` events and never characters, and neither is the C1 block or half a
/// surrogate pair - the glue splits strings by codepoint, so a surrogate here
/// would be a broken string rather than half of a whole one.
pub fn charFrom(value: i32) ?u21 {
    if (value < 0 or value > 0x10FFFF) return null;
    const codepoint: u21 = @intCast(value);
    if (codepoint < 0x20 or codepoint == 0x7F) return null;
    if (codepoint >= 0x80 and codepoint < 0xA0) return null;
    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return null;
    return codepoint;
}

/// `WheelEvent.deltaMode`: what the deltas are measured in.
pub const delta_pixel = 0;
pub const delta_line = 1;
pub const delta_page = 2;

/// A wheel's deltas as notches, which is what `.scroll` counts on every other
/// backend.
///
/// The DOM measures in pixels, lines or pages, and counts down as positive -
/// the opposite of what `.scroll` means. A notch is a hundred pixels in every
/// browser that reports pixels for a wheel, three lines in Firefox, which
/// reports lines, and a page is eighty, which is the figure SDL and GLFW both
/// settled on. A trackpad reports small pixel deltas and gets fractions of a
/// notch, which is what it is.
///
/// Horizontal is right-positive, as it is on every backend, and so is not
/// negated.
pub fn wheelSteps(mode: i32, dx: f64, dy: f64) [2]f64 {
    const per_notch: f64 = switch (mode) {
        delta_line => 3,
        delta_page => 1.0 / 80.0,
        else => 100,
    };
    // Adding zero turns a negative zero - what negating a still wheel gives -
    // into a positive one, so that an axis that did not move prints as 0 and
    // not as -0.
    return .{ dx / per_notch + 0.0, -dy / per_notch + 0.0 };
}

// -------------------------------------------------------------------------
// Keeping the imports and the stub in step
// -------------------------------------------------------------------------

/// Check that `stub` answers every call `web_imports.zig` declares, with the
/// same parameters and the same result.
///
/// The two files are written by hand, and a wasm build never compiles one
/// while a host build never compiles the other - so a signature changed on
/// one side alone would be found by a browser, as an argument quietly of the
/// wrong type. This compares them at compile time and costs nothing when they
/// agree.
///
/// It can only run where the imports may be looked at, which is a web build;
/// `zig build test` compiles the library for `wasm32-freestanding` as one of
/// its steps so that it does. Calling convention is left out of the
/// comparison on purpose: the imports are `callconv(.c)`, the stub is Zig,
/// and it is the shape that has to match.
pub fn verify() void {
    if (!platform.is_web) return;

    comptime {
        const imports = @import("web_imports.zig");
        for (@typeInfo(imports).@"struct".decls) |decl| {
            if (!@hasDecl(stub, decl.name)) {
                @compileError("web_stub is missing '" ++ decl.name ++ "', which web_imports declares");
            }
            const wanted = @typeInfo(@TypeOf(@field(imports, decl.name))).@"fn";
            const given = @typeInfo(@TypeOf(@field(stub, decl.name))).@"fn";
            if (wanted.params.len != given.params.len) {
                @compileError("web_stub." ++ decl.name ++ " takes the wrong number of arguments");
            }
            if (wanted.return_type != given.return_type) {
                @compileError("web_stub." ++ decl.name ++ " returns the wrong type");
            }
            for (wanted.params, given.params, 0..) |want, got, i| {
                if (want.type != got.type) {
                    @compileError(std.fmt.comptimePrint("web_stub.{s} argument {d} is the wrong type", .{ decl.name, i }));
                }
            }
        }
    }
}

comptime {
    verify();
}

// -------------------------------------------------------------------------
// Tests
//
// All of these run on the host, against `stub`: the backend is driven through
// its vtable, the fake page is told what a listener would have heard, and the
// events that come out are checked. The glue itself is the one part that
// needs a browser, and `examples/web.zig` is where it gets one.
// -------------------------------------------------------------------------

fn plainWindow() backend.WindowDesc {
    return .{
        .title = "fluxion",
        .width = 640,
        .height = 480,
        .resizable = true,
        .decorated = true,
        .visible = true,
        .maximized = false,
        .gl = null,
    };
}

/// Open the backend with one window, run `body`, and close everything again.
fn withWindow(desc: backend.WindowDesc, body: *const fn (impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) anyerror!void) !void {
    stub.reset();
    defer stub.reset();

    const impl = try open(testing.allocator);
    defer vtable.deinit(impl, testing.allocator);

    const native = try vtable.createWindow(impl, testing.allocator, @enumFromInt(1), desc);
    defer vtable.destroyWindow(impl, testing.allocator, native);

    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();

    try body(impl, native, &queue);
}

test "a window is a canvas, the size it was asked for" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = queue;
            try testing.expectEqual([2]u32{ 640, 480 }, vtable.size(impl, native));
            try testing.expectEqual([2]u32{ 640, 480 }, vtable.framebufferSize(impl, native));
            try testing.expectEqual([2]f32{ 1, 1 }, vtable.contentScale(impl, native));

            const canvas = stub.canvasFor(1) orelse return error.TestUnexpectedResult;
            try testing.expect(canvas.visible);
            try testing.expectEqualStrings("fluxion", stub.page.title[0..stub.page.title_len]);
            // The handle is the glue's number for the canvas, and never zero.
            try testing.expect(vtable.nativeHandle(impl, native) != 0);
        }
    }.run);
}

test "on a HiDPI page the pixels are the CSS size times the scale" {
    stub.reset();
    defer stub.reset();
    stub.page.scale = 2;

    const impl = try open(testing.allocator);
    defer vtable.deinit(impl, testing.allocator);
    const native = try vtable.createWindow(impl, testing.allocator, @enumFromInt(1), plainWindow());
    defer vtable.destroyWindow(impl, testing.allocator, native);

    try testing.expectEqual([2]u32{ 640, 480 }, vtable.size(impl, native));
    try testing.expectEqual([2]u32{ 1280, 960 }, vtable.framebufferSize(impl, native));
    try testing.expectEqual([2]f32{ 2, 2 }, vtable.contentScale(impl, native));
}

test "a page with no document is no display, not a crash" {
    stub.reset();
    defer stub.reset();
    stub.page.available = false;
    try testing.expectError(error.NoDisplay, open(testing.allocator));
}

test "a key arrives at its position, with its usage as the scancode" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = native;
            stub.queue(.{ .kind = .key, .window = 1, .a = 1, .b = 0b000011 }, "KeyW");
            stub.queue(.{ .kind = .key, .window = 1, .a = 2 }, "KeyW");
            stub.queue(.{ .kind = .key, .window = 1, .a = 0 }, "KeyW");
            try vtable.pump(impl, queue);

            const press = queue.next().?.key;
            try testing.expectEqual(keys.Key.w, press.key);
            try testing.expectEqual(keys.Action.press, press.action);
            try testing.expectEqual(@as(u32, 0x07001A), @intFromEnum(press.scancode));
            try testing.expectEqual(keys.Mods{ .shift = true, .control = true }, press.mods);
            try testing.expectEqual(@as(event.WindowId, @enumFromInt(1)), press.window);

            try testing.expectEqual(keys.Action.repeat, queue.next().?.key.action);
            try testing.expectEqual(keys.Action.release, queue.next().?.key.action);
            try testing.expectEqual(@as(?event.Event, null), queue.next());
        }
    }.run);
}

test "text is codepoints, and control codes are not text" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = native;
            stub.queue(.{ .kind = .char, .window = 1, .a = 'e' }, "");
            stub.queue(.{ .kind = .char, .window = 1, .a = 0xE9 }, ""); // é
            stub.queue(.{ .kind = .char, .window = 1, .a = 0x1F600 }, ""); // an emoji, whole
            stub.queue(.{ .kind = .char, .window = 1, .a = '\r' }, "");
            stub.queue(.{ .kind = .char, .window = 1, .a = 0x7F }, "");
            stub.queue(.{ .kind = .char, .window = 1, .a = 0xD83D }, ""); // half an emoji
            try vtable.pump(impl, queue);

            try testing.expectEqual(@as(u21, 'e'), queue.next().?.char.codepoint);
            try testing.expectEqual(@as(u21, 0xE9), queue.next().?.char.codepoint);
            try testing.expectEqual(@as(u21, 0x1F600), queue.next().?.char.codepoint);
            try testing.expectEqual(@as(?event.Event, null), queue.next());
        }
    }.run);
}

test "a button, the pointer and the wheel come through in the library's terms" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = native;
            // The DOM's right button is 2, this library's is 1.
            stub.queue(.{ .kind = .button, .window = 1, .a = 2, .b = 1, .x = 10, .y = 20 }, "");
            stub.queue(.{ .kind = .cursor, .window = 1, .x = 11, .y = 22, .dx = 1, .dy = 2 }, "");
            // One notch down in Chrome, and one down in Firefox.
            stub.queue(.{ .kind = .scroll, .window = 1, .a = delta_pixel, .y = 100 }, "");
            stub.queue(.{ .kind = .scroll, .window = 1, .a = delta_line, .y = 3 }, "");
            try vtable.pump(impl, queue);

            const button = queue.next().?.mouse_button;
            try testing.expectEqual(keys.MouseButton.right, button.button);
            try testing.expectEqual(keys.Action.press, button.action);
            try testing.expectEqual(@as(f64, 20), button.y);

            const moved = queue.next().?.cursor;
            try testing.expectEqual(@as(f64, 11), moved.x);
            try testing.expectEqual(@as(f64, 2), moved.dy);

            // Down is negative here, as on every other backend.
            try testing.expectApproxEqAbs(@as(f64, -1), queue.next().?.scroll.y, 1e-9);
            try testing.expectApproxEqAbs(@as(f64, -1), queue.next().?.scroll.y, 1e-9);
        }
    }.run);
}

test "a resize is the scale, the size, the pixels and a refresh, in that order" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            // The page was zoomed to 150%, and the canvas kept its CSS size.
            stub.queue(.{ .kind = .resize, .window = 1, .a = 640, .b = 480, .c = 960, .d = 720, .x = 1.5 }, "");
            try vtable.pump(impl, queue);

            try testing.expectApproxEqAbs(@as(f32, 1.5), queue.next().?.scale.x, 1e-6);
            const pixels = queue.next().?.framebuffer_resize;
            try testing.expectEqual(@as(u32, 960), pixels.width);
            try testing.expect(queue.next().? == .refresh);
            try testing.expectEqual(@as(?event.Event, null), queue.next());

            try testing.expectEqual([2]u32{ 640, 480 }, vtable.size(impl, native));
            try testing.expectEqual([2]u32{ 960, 720 }, vtable.framebufferSize(impl, native));

            // And the same numbers again are no event at all.
            queue.clear();
            stub.queue(.{ .kind = .resize, .window = 1, .a = 640, .b = 480, .c = 960, .d = 720, .x = 1.5 }, "");
            try vtable.pump(impl, queue);
            try testing.expectEqual(@as(?event.Event, null), queue.next());
        }
    }.run);
}

test "a hidden tab is the app going to the background" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = native;
            stub.queue(.{ .kind = .visibility, .a = 1 }, "");
            stub.queue(.{ .kind = .visibility, .a = 0 }, "");
            try vtable.pump(impl, queue);
            try testing.expect(queue.next().? == .suspended);
            try testing.expect(queue.next().? == .resumed);
        }
    }.run);
}

test "a composition is a state, and ending it empties it" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = native;
            stub.queue(.{ .kind = .preedit, .window = 1, .a = 6, .b = 6 }, "にほ");
            try vtable.pump(impl, queue);
            try testing.expect(queue.next().? == .preedit);
            try testing.expectEqualStrings("にほ", vtable.preedit(impl).?.text());
            try testing.expectEqual(@as(i32, 6), vtable.preedit(impl).?.cursor_begin);

            queue.clear();
            stub.queue(.{ .kind = .preedit, .window = 1 }, "");
            try vtable.pump(impl, queue);
            try testing.expect(queue.next().? == .preedit);
            try testing.expect(vtable.preedit(impl).?.isEmpty());
        }
    }.run);
}

test "a drop is one event with every name in it, valid until the next pump" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = native;
            stub.queue(.{ .kind = .drop_begin, .window = 1, .a = 2 }, "");
            stub.queue(.{ .kind = .drop_file, .window = 1, .a = 0 }, "level.json");
            stub.queue(.{ .kind = .drop_file, .window = 1, .a = 1 }, "atlas.png");
            try vtable.pump(impl, queue);

            const dropped = queue.next().?.drop;
            try testing.expectEqual(@as(usize, 2), dropped.paths.len);
            try testing.expectEqualStrings("level.json", dropped.paths[0]);
            try testing.expectEqualStrings("atlas.png", dropped.paths[1]);
            try testing.expectEqual(@as(?event.Event, null), queue.next());
        }
    }.run);
}

test "a lost context is the surface going, and a restored one is it coming back" {
    var desc = plainWindow();
    desc.gl = .{ .api = .opengl_es, .major = 3, .minor = 0 };
    try withWindow(desc, struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            try vtable.makeContextCurrent(impl, native);

            stub.queue(.{ .kind = .surface_lost, .window = 1 }, "");
            try vtable.pump(impl, queue);
            try testing.expect(queue.next().? == .surface_lost);
            // Nothing to draw with until it comes back, and every call says so.
            try testing.expectError(error.Unavailable, vtable.makeContextCurrent(impl, native));
            try testing.expectError(error.Unavailable, vtable.swapBuffers(impl, native));
            try testing.expectEqual(@as(?gl.Config, null), vtable.contextConfig(impl, native));

            queue.clear();
            stub.queue(.{ .kind = .surface_created, .window = 1, .a = 640, .b = 480 }, "");
            try vtable.pump(impl, queue);
            const created = queue.next().?.surface_created;
            try testing.expectEqual(@as(u32, 640), created.width);
            try vtable.makeContextCurrent(impl, native);
            try testing.expect(vtable.contextConfig(impl, native) != null);
        }
    }.run);
}

test "every pump gives the browser its turn first" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = native;
            try vtable.pump(impl, queue);
            try vtable.pump(impl, queue);
            try testing.expectEqual(@as(u32, 2), stub.page.syncs);

            try vtable.wait(impl, 16);
            try testing.expectEqual(@as(f64, 16), stub.page.last_wait);
            // No timeout is for ever, which the glue spells as negative.
            try vtable.wait(impl, null);
            try testing.expect(stub.page.last_wait < 0);
        }
    }.run);
}

test "more records than one drain holds all arrive, in order" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = native;
            const total = record_capacity * 2 + 5;
            for (0..total) |i| {
                stub.queue(.{ .kind = .cursor, .window = 1, .x = @floatFromInt(i) }, "");
            }
            try vtable.pump(impl, queue);
            for (0..total) |i| {
                try testing.expectEqual(@as(f64, @floatFromInt(i)), queue.next().?.cursor.x);
            }
            try testing.expectEqual(@as(?event.Event, null), queue.next());
        }
    }.run);
}

test "WebGL is ES, asked for by version" {
    // Desktop OpenGL is not something a browser has, whatever version.
    try testing.expectError(error.Unavailable, contextRequest(gl.Config{}));
    try testing.expectError(error.Unavailable, contextRequest(.{ .api = .opengl_es, .major = 3, .minor = 1 }));
    try testing.expectError(error.Unavailable, contextRequest(.{ .api = .opengl_es, .major = 1, .minor = 1 }));

    const es3 = try contextRequest(.{ .api = .opengl_es, .major = 3, .minor = 0 });
    try testing.expectEqual(@as(u32, 2), es3.version);
    // Depth and stencil, as the defaults ask; no antialiasing unless asked.
    try testing.expectEqual(context_flags.depth | context_flags.stencil, es3.flags);

    const es2 = try contextRequest(.{ .api = .opengl_es, .major = 2, .minor = 0, .samples = 4, .stencil_bits = 0 });
    try testing.expectEqual(@as(u32, 1), es2.version);
    try testing.expectEqual(context_flags.depth | context_flags.antialias, es2.flags);

    // And no context at all is no request at all.
    try testing.expectEqual(ContextRequest{}, try contextRequest(null));
}

test "the config reported is the one the browser gave, not the one asked for" {
    const config = grantedConfig(.{ .gl_version = 2, .red_bits = 8, .green_bits = 8, .blue_bits = 8, .depth_bits = 24, .stencil_bits = 8, .samples = 4 });
    try testing.expectEqual(gl.Api.opengl_es, config.api);
    try testing.expectEqual(@as(u8, 3), config.major);
    try testing.expectEqual(@as(u8, 0), config.minor);
    try testing.expectEqual(@as(u8, 0), config.alpha_bits);
    try testing.expectEqual(@as(u8, 4), config.samples);

    try testing.expectEqual(@as(u8, 2), grantedConfig(.{ .gl_version = 1 }).major);
}

test "a window asking for a context the browser has not got is not made" {
    stub.reset();
    defer stub.reset();
    stub.page.webgl = 1;

    const impl = try open(testing.allocator);
    defer vtable.deinit(impl, testing.allocator);

    var desc = plainWindow();
    desc.gl = .{ .api = .opengl_es, .major = 3, .minor = 0 };
    try testing.expectError(error.Unavailable, vtable.createWindow(impl, testing.allocator, @enumFromInt(1), desc));
    // And the canvas that was made for it is given back.
    try testing.expectEqual(@as(?*stub.Canvas, null), stub.canvasFor(1));

    // ES 2.0 is what a WebGL 1 browser can do.
    desc.gl = .{ .api = .opengl_es, .major = 2, .minor = 0 };
    const native = try vtable.createWindow(impl, testing.allocator, @enumFromInt(1), desc);
    defer vtable.destroyWindow(impl, testing.allocator, native);
    try testing.expectEqual(@as(u8, 2), vtable.contextConfig(impl, native).?.major);
}

test "only vsync is a swap interval a page can keep" {
    var desc = plainWindow();
    desc.gl = .{ .api = .opengl_es, .major = 3, .minor = 0 };
    try withWindow(desc, struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = queue;
            try vtable.setSwapInterval(impl, native, 1);
            try testing.expectError(error.Unavailable, vtable.setSwapInterval(impl, native, 0));
            try testing.expectError(error.Unavailable, vtable.setSwapInterval(impl, native, -1));
            try vtable.swapBuffers(impl, native);
            // Never an address: see the top of the file.
            try testing.expectEqual(@as(?gl.Proc, null), vtable.getProcAddress(impl, native, "glClear"));
        }
    }.run);
}

test "a window without a context refuses every GL call by name" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = queue;
            try testing.expectError(error.Unavailable, vtable.makeContextCurrent(impl, native));
            try testing.expectError(error.Unavailable, vtable.swapBuffers(impl, native));
            try testing.expectEqual(@as(?gl.Config, null), vtable.contextConfig(impl, native));
        }
    }.run);
}

test "what a page cannot do is refused, and what it can is done" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = queue;
            try testing.expectError(error.Unavailable, vtable.setPosition(impl, native, 1, 2));
            try testing.expectError(error.Unavailable, vtable.setCursorPos(impl, native, 1, 2));
            try testing.expectError(error.Unavailable, vtable.setCursorMode(impl, native, .captured));
            try testing.expectError(error.Unavailable, vtable.setState(impl, native, .iconified));
            try testing.expectError(error.Unavailable, vtable.setState(impl, native, .attention));
            try testing.expectError(error.Unavailable, vtable.setFullscreen(impl, native, .{
                .exclusive = .{ .monitor = 0, .mode = .{ .width = 800, .height = 600 } },
            }, null));
            try testing.expectError(error.Unavailable, vtable.createVulkanSurface(impl, native, 0, undefined, null));
            try testing.expectEqual([2]i32{ 0, 0 }, vtable.position(impl, native));

            const canvas = stub.canvasFor(1).?;
            try vtable.setCursorMode(impl, native, .disabled);
            try testing.expectEqual(@intFromEnum(cursor_mod.Mode.disabled), canvas.cursor_mode);
            try vtable.setState(impl, native, .maximized);
            try testing.expect(vtable.getState(impl, native, .maximized));
            try vtable.setState(impl, native, .restored);
            try testing.expect(!vtable.getState(impl, native, .maximized));
            try vtable.setFullscreen(impl, native, .{ .borderless = 0 }, null);
            try testing.expect(canvas.fullscreen);
            try vtable.setFullscreen(impl, native, .windowed, null);
            try testing.expect(!canvas.fullscreen);
            try vtable.setCursorShape(impl, native, .pointing_hand);
            try testing.expectEqual(@intFromEnum(cursor_mod.Shape.pointing_hand), canvas.cursor_shape);
            try vtable.setOpacity(impl, native, 3);
            try testing.expectEqual(@as(f32, 1), canvas.opacity);
            try testing.expect(vtable.setRawMouseMotion(impl, native, true));
        }
    }.run);
}

test "a page with no Fullscreen API says so" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            _ = queue;
            stub.page.fullscreen_api = false;
            try testing.expectError(error.Unavailable, vtable.setFullscreen(impl, native, .{ .borderless = 0 }, null));
        }
    }.run);
}

test "text input is a field the page focuses, and turning it off ends a composition" {
    try withWindow(plainWindow(), struct {
        fn run(impl: backend.Impl, native: backend.NativeWindow, queue: *backend.Queue) !void {
            try vtable.setTextInput(impl, native, true);
            try vtable.setTextInputArea(impl, native, .{ .x = 16, .y = 32, .width = 2, .height = 20 });
            const canvas = stub.canvasFor(1).?;
            try testing.expect(canvas.text_input);
            try testing.expectEqual([4]i32{ 16, 32, 2, 20 }, canvas.area);

            stub.queue(.{ .kind = .preedit, .window = 1, .a = 1, .b = 1 }, "k");
            try vtable.pump(impl, queue);
            try vtable.setTextInput(impl, native, false);
            try testing.expect(vtable.preedit(impl).?.isEmpty());
        }
    }.run);
}

test "the screen is one monitor, measured in the page's own pixels" {
    const mon = monitorFrom(.{
        .width = 1440,
        .height = 900,
        .avail_width = 1440,
        .avail_height = 875,
        .scale = 2,
        .color_depth = 30,
        .refresh_hz = 120,
    });
    try testing.expectEqualStrings("screen", mon.name());
    try testing.expect(mon.primary);
    try testing.expectEqual(@as(u32, 1440), mon.bounds.width);
    try testing.expectEqual(@as(u32, 875), mon.work_area.height);
    // The mode is the panel's own pixels: a Retina MacBook Air's.
    try testing.expectEqual(@as(u32, 2880), mon.current.width);
    try testing.expectEqual(@as(u32, 1800), mon.current.height);
    try testing.expectEqual(@as(u32, 120), mon.current.refresh_hz);
    try testing.expectEqual(@as(f32, 2), mon.scale_x);
}

test "the gamepads are the browser's, in the browser's slots" {
    stub.reset();
    defer stub.reset();

    var pad: wire.GamepadRecord = .{ .index = 2, .standard = 1, .axis_count = 4, .button_count = 17, .pressed = 1 };
    const id = "Xbox 360 Controller (XInput STANDARD GAMEPAD)";
    @memcpy(pad.id[0..id.len], id);
    pad.id_len = id.len;
    stub.page.pads[0] = pad;
    stub.page.pad_count = 1;

    const impl = try open(testing.allocator);
    defer vtable.deinit(impl, testing.allocator);

    var devices: [gamepad.max_devices]gamepad.Device = @splat(.{});
    devices[0].connected = true; // a pad that has since been unplugged
    vtable.pollGamepads(impl, &devices);

    try testing.expect(!devices[0].connected);
    try testing.expect(devices[2].connected);
    try testing.expect(devices[2].mapped);
    try testing.expect(devices[2].state.button(.a));
    try testing.expectEqualStrings("Xbox 360 Controller", devices[2].name());
}

test "the numbers the glue reads are the enums' own" {
    // `web.js` switches on these by number. Reorder an enum and this fails,
    // rather than a cursor mode quietly meaning another one.
    try testing.expectEqual(0, @intFromEnum(cursor_mod.Mode.normal));
    try testing.expectEqual(1, @intFromEnum(cursor_mod.Mode.hidden));
    try testing.expectEqual(2, @intFromEnum(cursor_mod.Mode.captured));
    try testing.expectEqual(3, @intFromEnum(cursor_mod.Mode.disabled));

    try testing.expectEqual(0, @intFromEnum(cursor_mod.Shape.arrow));
    try testing.expectEqual(1, @intFromEnum(cursor_mod.Shape.ibeam));
    try testing.expectEqual(2, @intFromEnum(cursor_mod.Shape.crosshair));
    try testing.expectEqual(3, @intFromEnum(cursor_mod.Shape.pointing_hand));
    try testing.expectEqual(4, @intFromEnum(cursor_mod.Shape.resize_ew));
    try testing.expectEqual(5, @intFromEnum(cursor_mod.Shape.resize_ns));
    try testing.expectEqual(6, @intFromEnum(cursor_mod.Shape.resize_nwse));
    try testing.expectEqual(7, @intFromEnum(cursor_mod.Shape.resize_nesw));
    try testing.expectEqual(8, @intFromEnum(cursor_mod.Shape.resize_all));
    try testing.expectEqual(9, @intFromEnum(cursor_mod.Shape.not_allowed));

    try testing.expectEqual(0, @intFromEnum(backend.WindowState.iconified));
    try testing.expectEqual(1, @intFromEnum(backend.WindowState.maximized));
    try testing.expectEqual(2, @intFromEnum(backend.WindowState.restored));
    try testing.expectEqual(3, @intFromEnum(backend.WindowState.focused));
    try testing.expectEqual(4, @intFromEnum(backend.WindowState.attention));

    // And the modifier bits are `Mods` bit for bit.
    try testing.expectEqual(keys.Mods{ .shift = true }, modsFrom(1));
    try testing.expectEqual(keys.Mods{ .control = true }, modsFrom(2));
    try testing.expectEqual(keys.Mods{ .alt = true }, modsFrom(4));
    try testing.expectEqual(keys.Mods{ .super = true }, modsFrom(8));
    try testing.expectEqual(keys.Mods{ .caps_lock = true }, modsFrom(16));
    try testing.expectEqual(keys.Mods{ .num_lock = true }, modsFrom(32));
    try testing.expectEqual(keys.Mods.none, modsFrom(64 | 128));
}

test "the DOM counts its buttons in a different order" {
    try testing.expectEqual(keys.MouseButton.left, buttonFrom(0));
    try testing.expectEqual(keys.MouseButton.middle, buttonFrom(1));
    try testing.expectEqual(keys.MouseButton.right, buttonFrom(2));
    try testing.expectEqual(keys.MouseButton.button_4, buttonFrom(3));
    try testing.expectEqual(keys.MouseButton.button_5, buttonFrom(4));
    try testing.expectEqual(@as(u8, 9), @intFromEnum(buttonFrom(9)));
}

test "a wheel's pixels, lines and pages are all notches" {
    try testing.expectEqual([2]f64{ 0, -1 }, wheelSteps(delta_pixel, 0, 100));
    try testing.expectEqual([2]f64{ 0, 1 }, wheelSteps(delta_line, 0, -3));
    try testing.expectEqual([2]f64{ 0, -80 }, wheelSteps(delta_page, 0, 1));
    // Right is right, as on every backend.
    try testing.expectEqual([2]f64{ 1, 0 }, wheelSteps(delta_pixel, 100, 0));
    // A trackpad's few pixels are a fraction of a notch, not a whole one.
    try testing.expectApproxEqAbs(@as(f64, -0.04), wheelSteps(delta_pixel, 0, 4)[1], 1e-9);
    // And an axis that did not move is zero, not negative zero.
    try testing.expect(!std.math.signbit(wheelSteps(delta_pixel, 0, 0)[1]));
    try testing.expect(!std.math.signbit(wheelSteps(delta_pixel, -0.0, 0)[0]));
}
