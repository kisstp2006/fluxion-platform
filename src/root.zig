// SPDX-License-Identifier: BSL-1.0

//! Fluxion Platform - windows, input and the event loop, on whatever this
//! machine has.
//!
//! Six pieces:
//!
//!   `platform`  which windowing system this build can reach, and which it got
//!   `Context`   the connection, the windows on it, and the event queue
//!   `Window`    one window, as a handle you can copy
//!   `event`     everything that can happen, as one tagged union
//!   `keys`      what a key is, what a button is, what was held down
//!   `backend`   what a windowing system has to answer to
//!
//! The shape is GLFW's - window hints, key tokens at GLFW's own numbers,
//! `shouldClose` as a flag the program owns - with one deliberate difference:
//! events are pulled rather than pushed.
//!
//! ```zig
//! var ctx = try platform.Context.init(gpa, .{});
//! defer ctx.deinit();
//!
//! var win = try ctx.createWindow(.{ .title = "hello" });
//! defer win.destroy();
//!
//! while (!win.shouldClose()) {
//!     try ctx.pump();
//!     while (ctx.poll()) |ev| switch (ev) {
//!         .close => win.setShouldClose(true),
//!         .key => |k| if (k.key == .escape and k.action == .press) win.setShouldClose(true),
//!         .framebuffer_resize => |r| resize(r.width, r.height),
//!         else => {},
//!     };
//!     draw();
//! }
//! ```
//!
//! **A queue rather than callbacks**, because a frame reads its input at one
//! point and a callback fires in the middle of somebody else's pump. One
//! `while` and one `switch` is also the shape an engine's own event dispatch
//! already has, so nothing has to be threaded through a user pointer to get
//! there.
//!
//! **Every backend is loaded at run time** through `fluxion-dyn`, so one binary
//! opens Wayland in one session and X11 in the next, and a Windows build still
//! starts on a version that predates the DPI calls it would like to use.
//!
//! **Android is not a desktop with a smaller screen.** The system takes the
//! drawing surface away when the app goes to the background and gives back a
//! different one later, while the process keeps running. That arrives as
//! `.surface_lost` and `.surface_created`, which no desktop backend ever sends
//! - so a program written to handle them is correct on a phone and unchanged
//! everywhere else.
//!
//! **A browser is a backend like the others.** Built for `wasm32-freestanding`
//! a window is a `<canvas>`, the events come from the page through
//! `fluxion-platform.js`, and a lost WebGL context is the same pair of events
//! a phone sends. What differs is who owns the loop: see `web` and
//! `backend/web.zig` for the two ways a program can live with a page that
//! cannot be blocked.
//!
//! Nothing here allocates except through the allocator handed to
//! `Context.init`.

const std = @import("std");

pub const platform = @import("platform.zig");
pub const event = @import("event.zig");
pub const keys = @import("keys.zig");
pub const backend = @import("backend.zig");
pub const input = @import("input.zig");
pub const cursor = @import("cursor.zig");
pub const monitor = @import("monitor.zig");
pub const gamepad = @import("gamepad.zig");
pub const gl = @import("gl.zig");
pub const vulkan = @import("vulkan.zig");
pub const text = @import("text.zig");
/// The console and the panic handler a browser build needs. See `web`.
pub const web = @import("web.zig");

/// The connection to the windowing system. See `Context`.
pub const Context = @import("Context.zig");

/// One window. See `Window`.
pub const Window = @import("Window.zig");

/// Which windowing system. See `platform`.
pub const Backend = platform.Backend;

/// Everything opening one can fail with. See `platform`.
pub const Error = platform.Error;

/// Everything that can happen. See `event`.
pub const Event = event.Event;

/// Which window an event is about. See `event`.
pub const WindowId = event.WindowId;

/// A physical key, at its position on a US layout. See `keys`.
pub const Key = keys.Key;

/// The platform's own number for the same key. See `keys`.
pub const Scancode = keys.Scancode;

/// A mouse button. See `keys`.
pub const MouseButton = keys.MouseButton;

/// What happened to a key or a button. See `keys`.
pub const Action = keys.Action;

/// What was held down at the time. See `keys`.
pub const Mods = keys.Mods;

/// Where the pointer may go, and whether it can be seen. See `cursor`.
pub const CursorMode = cursor.Mode;

/// One of the system's own cursor shapes. See `cursor`.
pub const CursorShape = cursor.Shape;

/// One display. See `monitor`.
pub const Monitor = monitor.Monitor;

/// A resolution and a refresh rate. See `monitor`.
pub const VideoMode = monitor.VideoMode;

/// How a window fills a monitor. See `monitor`.
pub const Fullscreen = monitor.Fullscreen;

/// One controller. See `gamepad`.
pub const Gamepad = gamepad.Device;

/// A button on a mapped gamepad. See `gamepad`.
pub const GamepadButton = gamepad.Button;

/// An axis on a mapped gamepad. See `gamepad`.
pub const GamepadAxis = gamepad.Axis;

/// What kind of OpenGL context a window should come with. See `gl`.
pub const GlConfig = gl.Config;

/// How long to wait for the display before showing a frame. See `gl`.
pub const SwapInterval = gl.SwapInterval;

/// Text an input method is composing. See `text`.
pub const Preedit = text.Preedit;

/// Where an input method should put its candidates. See `text`.
pub const TextInputArea = text.Area;

/// What this build could open, in the order `auto` tries them. See `platform`.
pub const supported = platform.supported;

test {
    // Pull each module in so `zig build test` runs its tests too.
    _ = platform;
    _ = event;
    _ = keys;
    _ = backend;
    _ = input;
    _ = cursor;
    _ = monitor;
    _ = gamepad;
    _ = gl;
    _ = vulkan;
    _ = text;
    _ = web;
    _ = @import("window_ops_test.zig");
    _ = @import("cursor_test.zig");
    _ = @import("monitor_test.zig");
    _ = @import("gamepad_test.zig");
    _ = @import("gl_test.zig");
    _ = @import("text_test.zig");
    _ = Context;
    _ = Window;
    _ = @import("backend/none.zig");
    // The key table has no platform in it, so it is checked on every host.
    _ = @import("backend/evdev.zig");
    // Nor has the rule every backend works the virtual key out with.
    _ = @import("backend/virtual_key.zig");

    const os = @import("builtin").os.tag;
    if (os == .windows) {
        _ = @import("backend/win32.zig");
        _ = @import("backend/xinput.zig");
        _ = @import("backend/wgl.zig");
    }
    if (@import("builtin").abi.isAndroid()) _ = @import("backend/android.zig");
    // Not only on Android: this one is arithmetic over Android's key codes and
    // axis numbers, with nothing from the NDK in it, so it can be checked on
    // whichever machine the tests are actually run on.
    _ = @import("backend/android_gamepad.zig");
    // Same again: JNI table offsets are arithmetic, checkable anywhere.
    _ = @import("backend/android_text.zig");
    // And the web backend in full: off a browser it talks to `web_stub.zig`,
    // a fake page, so the whole path from a record to an event is checked on
    // whatever machine runs the tests.
    _ = @import("backend/web.zig");
    _ = @import("backend/web_wire.zig");
    _ = @import("backend/web_keys.zig");
    _ = @import("backend/web_gamepad.zig");
    _ = @import("backend/web_stub.zig");
    // The protocol ABI tests inside these run wherever the backends do, which
    // is every target that has a windowing system to reach.
    if (os == .linux or os == .freebsd or os == .netbsd or os == .openbsd) {
        if (!@import("builtin").abi.isAndroid()) {
            _ = @import("backend/x11.zig");
            _ = @import("backend/wayland.zig");
            _ = @import("backend/linux_gamepad.zig");
            _ = @import("backend/glx.zig");
            _ = @import("backend/egl.zig");
            _ = @import("backend/xkb.zig");
        }
    }
}

test "the pieces compose" {
    const testing = std.testing;

    // The whole library in one go, on a backend that needs no display: open,
    // ask what it is, pump, and find nothing - which is the correct answer
    // from a machine with nothing to report.
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    try testing.expectEqual(Backend.none, ctx.backend());
    try ctx.pump();
    try testing.expectEqual(@as(?Event, null), ctx.poll());

    // And the one thing this backend refuses, refused by name rather than by
    // crashing.
    try testing.expectError(error.Unavailable, ctx.createWindow(.{}));
}
