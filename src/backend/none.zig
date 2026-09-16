// SPDX-License-Identifier: BSL-1.0

//! The backend for a target with no windowing system.
//!
//! Not a stub that pretends: every call that would need a window says
//! `error.Unavailable`, and `pump` produces nothing forever. It exists so that
//! a cross-compiled build links, a test suite runs on a machine with no
//! display, and a program that only wanted `keys.Key` compiles on a target this
//! library has never heard of.
//!
//! `Context.init` never chooses this one - `platform.supported` leaves it out,
//! so `auto` fails with `error.Unsupported` rather than quietly opening
//! something that cannot draw. It is reachable only by asking for it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const backend = @import("../backend.zig");
const cursor_mod = @import("../cursor.zig");
const icon_mod = @import("../icon.zig");
const event = @import("../event.zig");
const input = @import("../input.zig");
const monitor = @import("../monitor.zig");
const gamepad = @import("../gamepad.zig");
const gl = @import("../gl.zig");
const vulkan = @import("../vulkan.zig");
const text = @import("../text.zig");
const platform = @import("../platform.zig");

const Error = platform.Error;

/// There is no state, and one instance is enough for every context.
var singleton: u8 = 0;

pub const vtable: backend.Vtable = .{
    .backend = .none,
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
    .scrollLines = scrollLines,
    .doubleClickTime = doubleClickTime,
    .caretBlinkTime = caretBlinkTime,
    .windowMonitor = windowMonitor,
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
    .setClipboardText = setClipboardText,
    .clipboardText = clipboardText,
    .hasClipboardText = hasClipboardText,
    .showFileDialog = showFileDialog,
    .chosenFile = chosenFile,
    .setFullscreen = setFullscreen,
    .setCursorMode = setCursorMode,
    .setRawMouseMotion = setRawMouseMotion,
    .setCursorPos = setCursorPos,
    .setCursorShape = setCursorShape,
    .setCursorImage = setCursorImage,
    .setIcon = setIcon,
    .position = position,
    .setPosition = setPosition,
    .setSize = setSize,
    .setState = setState,
    .getState = getState,
    .setSizeLimits = setSizeLimits,
    .setOpacity = setOpacity,
};

/// Open it. Cannot fail: there is nothing to connect to.
pub fn open(gpa: Allocator) Error!backend.Impl {
    _ = gpa;
    return &singleton;
}

fn deinit(impl: backend.Impl, gpa: Allocator) void {
    _ = impl;
    _ = gpa;
}

fn createWindow(
    impl: backend.Impl,
    gpa: Allocator,
    id: event.WindowId,
    desc: backend.WindowDesc,
) Error!backend.NativeWindow {
    _ = .{ impl, gpa, id, desc };
    return error.Unavailable;
}

fn destroyWindow(impl: backend.Impl, gpa: Allocator, native: backend.NativeWindow) void {
    _ = .{ impl, gpa, native };
}

fn pump(impl: backend.Impl, queue: *backend.Queue) Error!void {
    _ = .{ impl, queue };
}

fn wait(impl: backend.Impl, timeout_ms: ?u32) Error!void {
    _ = .{ impl, timeout_ms };
    // Returns at once, including for a null timeout. Nothing will ever arrive,
    // so sleeping out the wait would only delay a program that cannot make a
    // window anyway - and waiting forever would hang it outright.
}

fn post(impl: backend.Impl) void {
    _ = impl;
}

fn setTitle(impl: backend.Impl, native: backend.NativeWindow, title: []const u8) Error!void {
    _ = .{ impl, native, title };
    return error.Unavailable;
}

fn setVisible(impl: backend.Impl, native: backend.NativeWindow, visible: bool) void {
    _ = .{ impl, native, visible };
}

fn size(impl: backend.Impl, native: backend.NativeWindow) [2]u32 {
    _ = .{ impl, native };
    return .{ 0, 0 };
}

fn framebufferSize(impl: backend.Impl, native: backend.NativeWindow) [2]u32 {
    _ = .{ impl, native };
    return .{ 0, 0 };
}

fn contentScale(impl: backend.Impl, native: backend.NativeWindow) [2]f32 {
    _ = .{ impl, native };
    return .{ 1, 1 };
}

fn nativeHandle(impl: backend.Impl, native: backend.NativeWindow) usize {
    _ = .{ impl, native };
    return 0;
}

/// No displays, which is the truth rather than a failure: a caller gets an
/// empty list and can say so.
fn enumerateMonitors(
    impl: backend.Impl,
    list: *std.ArrayListUnmanaged(monitor.Monitor),
    modes: *std.ArrayListUnmanaged(monitor.VideoMode),
    gpa: Allocator,
) Error!void {
    _ = .{ impl, list, modes, gpa };
}

fn windowMonitor(impl: backend.Impl, native: backend.NativeWindow, list: []const monitor.Monitor) ?usize {
    _ = .{ impl, native, list };
    return null;
}

fn scrollLines(impl: backend.Impl) input.ScrollLines {
    _ = impl;
    return .{};
}

fn doubleClickTime(impl: backend.Impl) u32 {
    _ = impl;
    return 400;
}

fn caretBlinkTime(impl: backend.Impl) ?u32 {
    _ = impl;
    return 530;
}

/// No keyboard, so no text and no input method to compose it with.
fn setTextInput(impl: backend.Impl, native: backend.NativeWindow, on: bool) Error!void {
    _ = .{ impl, native, on };
    return error.Unavailable;
}

fn setTextInputArea(impl: backend.Impl, native: backend.NativeWindow, area: text.Area) Error!void {
    _ = .{ impl, native, area };
    return error.Unavailable;
}

fn preedit(impl: backend.Impl) ?*const text.Preedit {
    _ = impl;
    return null;
}

/// No session, so no clipboard to share with anything.
fn setClipboardText(impl: backend.Impl, utf8: []const u8) Error!void {
    _ = .{ impl, utf8 };
    return error.Unavailable;
}

fn clipboardText(impl: backend.Impl, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    _ = .{ impl, out, gpa };
    return error.Unavailable;
}

fn hasClipboardText(impl: backend.Impl) bool {
    _ = impl;
    return false;
}

fn showFileDialog(impl: backend.Impl, gpa: Allocator, request: backend.DialogRequest) Error!void {
    _ = .{ impl, gpa, request };
    return error.Unavailable;
}

fn chosenFile(impl: backend.Impl, index: usize, path: []const u8, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    _ = .{ impl, index, path, out, gpa };
    return error.Unavailable;
}

/// Nothing to draw into, so nothing to draw with. Every one of these refuses
/// by name, which is what a program cross-compiled to a target with no
/// windowing system should find out at run time rather than not at all.
fn makeContextCurrent(impl: backend.Impl, native: backend.NativeWindow) Error!void {
    _ = .{ impl, native };
    return error.Unavailable;
}

fn clearContext(impl: backend.Impl) void {
    _ = impl;
}

fn swapBuffers(impl: backend.Impl, native: backend.NativeWindow) Error!void {
    _ = .{ impl, native };
    return error.Unavailable;
}

fn setSwapInterval(impl: backend.Impl, native: backend.NativeWindow, interval: i32) Error!void {
    _ = .{ impl, native, interval };
    return error.Unavailable;
}

fn getProcAddress(impl: backend.Impl, native: backend.NativeWindow, name: [*:0]const u8) ?gl.Proc {
    _ = .{ impl, native, name };
    return null;
}

fn contextConfig(impl: backend.Impl, native: backend.NativeWindow) ?gl.Config {
    _ = .{ impl, native };
    return null;
}

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

/// No controllers, for the same reason there are no windows: this backend is
/// what a target with nothing gets, and pretending otherwise would be worse
/// than saying so.
fn pollGamepads(impl: backend.Impl, devices: *[gamepad.max_devices]gamepad.Device) void {
    _ = impl;
    for (devices) |*device| device.* = .{};
}

fn setFullscreen(
    impl: backend.Impl,
    native: backend.NativeWindow,
    wanted: monitor.Fullscreen,
    target: ?*const monitor.Monitor,
) Error!void {
    _ = .{ impl, native, wanted, target };
    return error.Unavailable;
}

fn setCursorMode(impl: backend.Impl, native: backend.NativeWindow, mode: cursor_mod.Mode) Error!void {
    _ = .{ impl, native, mode };
    return error.Unavailable;
}

fn setRawMouseMotion(impl: backend.Impl, native: backend.NativeWindow, on: bool) bool {
    _ = .{ impl, native, on };
    return false;
}

fn setCursorPos(impl: backend.Impl, native: backend.NativeWindow, x: f64, y: f64) Error!void {
    _ = .{ impl, native, x, y };
    return error.Unavailable;
}

fn setCursorShape(impl: backend.Impl, native: backend.NativeWindow, shape: cursor_mod.Shape) Error!void {
    _ = .{ impl, native, shape };
    return error.Unavailable;
}

fn setCursorImage(impl: backend.Impl, native: backend.NativeWindow, image: ?cursor_mod.Image) Error!void {
    _ = .{ impl, native, image };
    return error.Unavailable;
}

fn setIcon(impl: backend.Impl, native: backend.NativeWindow, images: []const icon_mod.Image) Error!void {
    _ = .{ impl, native, images };
    return error.Unavailable;
}

fn position(impl: backend.Impl, native: backend.NativeWindow) [2]i32 {
    _ = .{ impl, native };
    return .{ 0, 0 };
}

fn setPosition(impl: backend.Impl, native: backend.NativeWindow, x: i32, y: i32) Error!void {
    _ = .{ impl, native, x, y };
    return error.Unavailable;
}

fn setSize(impl: backend.Impl, native: backend.NativeWindow, width: u32, height: u32) Error!void {
    _ = .{ impl, native, width, height };
    return error.Unavailable;
}

fn setState(impl: backend.Impl, native: backend.NativeWindow, wanted: backend.WindowState) Error!void {
    _ = .{ impl, native, wanted };
    return error.Unavailable;
}

fn getState(impl: backend.Impl, native: backend.NativeWindow, which: backend.WindowState) bool {
    _ = .{ impl, native, which };
    return false;
}

fn setSizeLimits(impl: backend.Impl, native: backend.NativeWindow, limits: backend.SizeLimits) Error!void {
    _ = .{ impl, native, limits };
    return error.Unavailable;
}

fn setOpacity(impl: backend.Impl, native: backend.NativeWindow, opacity: f32) Error!void {
    _ = .{ impl, native, opacity };
    return error.Unavailable;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "it opens, and then refuses to make a window" {
    const impl = try open(testing.allocator);
    defer vtable.deinit(impl, testing.allocator);

    try testing.expectEqual(platform.Backend.none, vtable.backend);
    try testing.expectError(error.Unavailable, vtable.createWindow(
        impl,
        testing.allocator,
        @enumFromInt(1),
        .{
            .title = "nothing",
            .width = 640,
            .height = 480,
            .resizable = true,
            .decorated = true,
            .visible = true,
            .maximized = false,
            .gl = null,
        },
    ));
}

test "pumping produces nothing, forever" {
    const impl = try open(testing.allocator);
    defer vtable.deinit(impl, testing.allocator);

    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();

    try vtable.pump(impl, &queue);
    try vtable.pump(impl, &queue);
    try testing.expect(!queue.pending());
}

test "there is no clipboard, and every call says so" {
    const impl = try open(testing.allocator);
    defer vtable.deinit(impl, testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.Unavailable, vtable.setClipboardText(impl, "text"));
    try testing.expectError(error.Unavailable, vtable.clipboardText(impl, &out, testing.allocator));
    try testing.expect(!vtable.hasClipboardText(impl));
}

test "waiting with no timeout returns rather than hanging" {
    const impl = try open(testing.allocator);
    defer vtable.deinit(impl, testing.allocator);

    // The one that would hang if this backend pretended to have events.
    try vtable.wait(impl, null);
    vtable.post(impl);
}
