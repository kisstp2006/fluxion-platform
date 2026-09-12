// SPDX-License-Identifier: BSL-1.0

//! The connection to the windowing system, the windows on it, and the events
//! they produce.
//!
//! One per process, and every call on it belongs to the thread that made it.
//! That is not this library being careful: Win32 delivers messages to the
//! thread that created the window, and Android's looper belongs to the thread
//! that attached it. A context used from two threads is a bug on every backend,
//! so it is a rule here rather than a lock.
//!
//! **A context does not move once a window exists.** A `Window` is an id and a
//! pointer back to the context that owns it, so copying the context - returning
//! it from a function, putting it in a struct that is then moved, growing an
//! array it lives in - leaves every window handle pointing at where it used to
//! be. Keep it where it was made: a local in `main`, or a field of something
//! that itself stays put.
//!
//! ```zig
//! var ctx = try Context.init(gpa, .{});
//! defer ctx.deinit();
//!
//! var win = try ctx.createWindow(.{ .title = "hello" });
//! defer win.destroy();
//!
//! while (!win.shouldClose()) {
//!     try ctx.pump();
//!     while (ctx.poll()) |ev| switch (ev) {
//!         .close => win.setShouldClose(true),
//!         else => {},
//!     };
//! }
//! ```
//!
//! `pump` talks to the system and fills the queue; `poll` walks the queue. They
//! are separate because a frame reads its events once and a program that draws
//! nothing new should be able to wait instead - `pumpWait` blocks until there
//! is something to read.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const backend_mod = @import("backend.zig");
const dialog = @import("dialog.zig");
const event = @import("event.zig");
const platform = @import("platform.zig");
const keys = @import("keys.zig");
const Window = @import("Window.zig");
const input = @import("input.zig");
const monitor = @import("monitor.zig");
const gamepad_mod = @import("gamepad.zig");
const vulkan = @import("vulkan.zig");
const text_mod = @import("text.zig");
const clipboard_mod = @import("backend/clipboard.zig");

/// A backend is imported only where it could run. `fluxion-dyn` has no library
/// handle on a target with no run-time loading - `wasm32`, and anything else
/// `std.DynLib` does not cover - so a backend built on one cannot even be
/// sized there, and importing it anyway would fail the build for a program
/// that only wanted `Key`. The web backend is the other way round: its calls
/// are imports only a page can satisfy, so it is imported only for one.
const posix_desktop = switch (builtin.os.tag) {
    .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => !builtin.abi.isAndroid(),
    else => false,
};

const none = @import("backend/none.zig");
const win32 = if (builtin.os.tag == .windows) @import("backend/win32.zig") else void;
const x11 = if (posix_desktop) @import("backend/x11.zig") else void;
const wayland = if (posix_desktop) @import("backend/wayland.zig") else void;
const android = if (builtin.abi.isAndroid()) @import("backend/android.zig") else void;
// The one backend that needs no loader at all: its calls are WebAssembly
// imports, resolved by the page before the module runs.
const web = if (platform.is_web) @import("backend/web.zig") else void;

const Context = @This();

pub const Error = platform.Error;

/// What to open, and how.
pub const Options = struct {
    /// Which windowing system. `.auto` keeps the first of `platform.supported`
    /// that opens.
    select: platform.Selection = .auto,
};

gpa: Allocator,
vtable: *const backend_mod.Vtable,
impl: backend_mod.Impl,
queue: backend_mod.Queue,

/// Every live window, by id. Sparse: destroying one leaves a hole rather than
/// renumbering, so an id already handed out never comes to mean another window.
windows: std.AutoArrayHashMapUnmanaged(event.WindowId, Window.Entry) = .empty,
next_id: u32 = 1,

/// What is held down right now, kept up to date by `pump`. See `input`.
///
/// One keyboard and one pointer, not one per window: that is what the hardware
/// is, and a program that wants to know which window has focus reads the
/// `.focus` events.
state: input.State = .{},

/// What was attached the last time anyone asked. Rebuilt by `refreshMonitors`,
/// and by `monitors` the first time it is called - so a program that never asks
/// never pays for the round trip.
monitor_list: std.ArrayListUnmanaged(monitor.Monitor) = .empty,
/// Every mode of every monitor, in one array that each monitor's `modes` slices
/// into. See the vtable's `enumerateMonitors` for why it is separate.
monitor_modes: std.ArrayListUnmanaged(monitor.VideoMode) = .empty,
monitors_known: bool = false,

/// Every controller slot, refreshed by `pump`. Sixteen values held inline,
/// because a device is small and a program that reads one every frame should
/// not be chasing a pointer to do it.
pads: [gamepad_mod.max_devices]gamepad_mod.Device = @splat(.{}),
/// The layouts a program has loaded, for controllers the system does not
/// already know. Empty on a machine where every pad is an Xbox one.
mappings: gamepad_mod.Store = .{},

/// What `clipboardText` last read, kept so its answer needs no freeing.
clipboard: std.ArrayListUnmanaged(u8) = .empty,

next_dialog: u32 = 1,
/// The paths of the last `.file_dialog` answer, kept past the pump it came in
/// for `chosenFile`.
chosen: std.ArrayListUnmanaged([]u8) = .empty,

/// Open the windowing system.
///
/// `error.Unsupported` means this build has no backend for the target;
/// `error.NoDisplay` means it has one and the machine has not got it, which on
/// Linux is what a session with neither `DISPLAY` nor `WAYLAND_DISPLAY` looks
/// like. Both are things to report and carry on from, not things to crash on.
pub fn init(gpa: Allocator, options: Options) Error!Context {
    const wanted = try platform.candidates(options.select);

    var last: Error = error.NoDisplay;
    for (wanted) |candidate| {
        const opened = openOne(gpa, candidate) catch |err| {
            last = err;
            continue;
        };
        return .{
            .gpa = gpa,
            .vtable = opened.vtable,
            .impl = opened.impl,
            .queue = .init(gpa),
        };
    }
    return last;
}

const Opened = struct {
    vtable: *const backend_mod.Vtable,
    impl: backend_mod.Impl,
};

fn openOne(gpa: Allocator, which: platform.Backend) Error!Opened {
    switch (which) {
        .win32 => {
            if (builtin.os.tag != .windows) return error.Unsupported;
            return .{ .vtable = &win32.vtable, .impl = try win32.open(gpa) };
        },
        .wayland => {
            if (!posix_desktop) return error.Unsupported;
            return .{ .vtable = &wayland.vtable, .impl = try wayland.open(gpa) };
        },
        .x11 => {
            if (!posix_desktop) return error.Unsupported;
            return .{ .vtable = &x11.vtable, .impl = try x11.open(gpa) };
        },
        .android => {
            if (!builtin.abi.isAndroid()) return error.Unsupported;
            return .{ .vtable = &android.vtable, .impl = try android.open(gpa) };
        },
        .web => {
            if (!platform.is_web) return error.Unsupported;
            return .{ .vtable = &web.vtable, .impl = try web.open(gpa) };
        },
        .none => return .{ .vtable = &none.vtable, .impl = try none.open(gpa) },
    }
}

/// Close every window and let go of the connection.
pub fn deinit(self: *Context) void {
    var it = self.windows.iterator();
    while (it.next()) |open_window| {
        self.vtable.destroyWindow(self.impl, self.gpa, open_window.value_ptr.native);
    }
    self.windows.deinit(self.gpa);
    self.monitor_list.deinit(self.gpa);
    self.monitor_modes.deinit(self.gpa);
    self.mappings.deinit(self.gpa);
    self.clipboard.deinit(self.gpa);
    self.forgetChosen();
    self.chosen.deinit(self.gpa);
    self.queue.deinit();
    self.vtable.deinit(self.impl, self.gpa);
    self.* = undefined;
}

/// Which backend this run actually got.
pub fn backend(self: *const Context) platform.Backend {
    return self.vtable.backend;
}

/// Make a window.
pub fn createWindow(self: *Context, desc: Window.Desc) Error!Window {
    const id: event.WindowId = @enumFromInt(self.next_id);

    const native = try self.vtable.createWindow(self.impl, self.gpa, id, .{
        .title = desc.title,
        .width = desc.width,
        .height = desc.height,
        .resizable = desc.resizable,
        .decorated = desc.decorated,
        .visible = desc.visible,
        .maximized = desc.maximized,
        .gl = desc.gl,
    });
    errdefer self.vtable.destroyWindow(self.impl, self.gpa, native);

    try self.windows.put(self.gpa, id, .{ .native = native, .should_close = false });
    self.next_id += 1;

    return .{ .ctx = self, .id = id };
}

/// Talk to the system and fill the queue with whatever it had.
///
/// Does not block. Everything unread from the last pump is dropped, because an
/// event nobody looked at by the next frame is stale by definition.
///
/// **In a browser, a program whose `main` is a loop is the exception**: this
/// is where it gives the page its turn, and it returns at the next animation
/// frame. Nothing is drawn and nothing is heard until a module lets go, so a
/// loop that pumps once a frame is paced by the display - which is what a
/// desktop loop gets from its swap. A program that exports `frame` instead
/// returns to the page by returning, and this never waits there. See
/// `backend/web.zig`.
pub fn pump(self: *Context) Error!void {
    self.queue.clear();
    try self.vtable.pump(self.impl, &self.queue);

    // After the window system and before the queue is handed out, so a frame
    // sees the controller and the connection notice at the same time.
    self.refreshGamepads();

    // Walked before anything is handed out, so the state a frame reads always
    // agrees with the events that frame is about to see.
    for (self.queue.items.items) |ev| {
        self.state.apply(ev);
        if (ev == .file_dialog) try self.keepChosen(ev.file_dialog.paths);
    }
}

/// The same, but sleep first until there is something to pump or `timeout_ms`
/// passes. A null timeout sleeps until something arrives.
///
/// For a program that redraws only when something changed. One that animates
/// should use `pump` and let the presentation rate set the pace.
///
/// A page that calls `frame` cannot be slept, so there this is `pump`.
pub fn pumpWait(self: *Context, timeout_ms: ?u32) Error!void {
    try self.vtable.wait(self.impl, timeout_ms);
    try self.pump();
}

/// Wake a `pumpWait` from another thread. The one call on a context that may be
/// made from anywhere.
pub fn post(self: *Context) void {
    self.vtable.post(self.impl);
}

/// The next event from the last pump, or null when they have all been read.
pub fn poll(self: *Context) ?event.Event {
    return self.queue.next();
}

/// The window an event names, or null if it has been destroyed since.
pub fn window(self: *Context, id: event.WindowId) ?Window {
    if (!self.windows.contains(id)) return null;
    return .{ .ctx = self, .id = id };
}

/// How many windows are open.
pub fn windowCount(self: *const Context) usize {
    return self.windows.count();
}

// -------------------------------------------------------------------------
// Monitors
// -------------------------------------------------------------------------

/// The displays attached to this machine.
///
/// Built the first time it is asked for and kept until `refreshMonitors`. The
/// slice - and every `modes` slice inside it - belongs to the context and is
/// invalidated by a refresh, so anything kept across one should be a copy.
///
/// Empty where the backend cannot enumerate, which is not an error: a program
/// that wanted a monitor to go fullscreen on can say so, and one that only
/// wanted to list them has its answer.
pub fn monitors(self: *Context) []const monitor.Monitor {
    if (!self.monitors_known) {
        self.refreshMonitors() catch return &.{};
    }
    return self.monitor_list.items;
}

/// Ask the system again. For a program that has seen a monitor plugged in, or
/// one that wants to be sure before going fullscreen.
pub fn refreshMonitors(self: *Context) Error!void {
    self.monitor_list.clearRetainingCapacity();
    self.monitor_modes.clearRetainingCapacity();
    self.monitors_known = true;

    try self.vtable.enumerateMonitors(
        self.impl,
        &self.monitor_list,
        &self.monitor_modes,
        self.gpa,
    );

    // The backend appended modes as ranges; the slices are made here, once the
    // array has stopped moving.
    for (self.monitor_list.items) |*mon| {
        const start = mon.mode_start;
        const count = mon.mode_count;
        if (start + count > self.monitor_modes.items.len) {
            mon.modes = &.{};
            continue;
        }
        mon.modes = self.monitor_modes.items[start .. start + count];
    }
}

/// The one a desktop treats as the main display, or null when there are none.
pub fn primaryMonitor(self: *Context) ?*const monitor.Monitor {
    const list = self.monitors();
    for (list) |*mon| {
        if (mon.primary) return mon;
    }
    // No monitor claimed it, so the first is as good an answer as there is.
    return if (list.len > 0) &list[0] else null;
}

/// The monitor a point falls on, for working out which display a window is on.
pub fn monitorAt(self: *Context, x: i32, y: i32) ?*const monitor.Monitor {
    for (self.monitors()) |*mon| {
        if (mon.bounds.contains(x, y)) return mon;
    }
    return null;
}

/// What an input method is composing right now.
///
/// Empty whenever nothing is being composed, which is almost always. The
/// contents are valid until the next `pump`, and `.preedit` is the event that
/// says they changed - see `text` for why this is a polled value rather than an
/// event payload.
pub fn preedit(self: *const Context) text_mod.Preedit {
    return (self.vtable.preedit(self.impl) orelse &empty_preedit).*;
}

/// What `preedit` answers on a backend that has no input method at all, so that
/// a caller never has to check for null.
const empty_preedit: text_mod.Preedit = .{};

/// Unbind whatever OpenGL context this thread had.
///
/// For a thread that is handing its context to another one, and for a program
/// that wants to be sure nothing is current before it tears things down.
pub fn clearContext(self: *Context) void {
    self.vtable.clearContext(self.impl);
}

/// The Vulkan instance extensions this session needs, for the backend that
/// actually opened. See `vulkan`.
pub fn requiredVulkanExtensions(self: *const Context) []const [*:0]const u8 {
    return vulkan.requiredInstanceExtensions(self.vtable.backend);
}

// -------------------------------------------------------------------------
// The clipboard
//
// Text, and the same text on every platform: UTF-8 with `\n` between lines,
// converted on the way out to whatever the system keeps and back on the way
// in. It belongs to the session rather than to a window, so it lives here.
// -------------------------------------------------------------------------

/// Put `text` on the system clipboard, for this program and every other.
///
/// Copied, so `text` may go as soon as this returns. Text that is not UTF-8 is
/// refused with `error.Unavailable`, and so is a system that will not take it:
/// Wayland takes the clipboard only from a program with the keyboard, and a
/// page may not have a clipboard at all. See the README for each platform.
pub fn setClipboardText(self: *Context, text: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.Unavailable;
    return self.vtable.setClipboardText(self.impl, text);
}

/// The text on the clipboard, or nothing when it holds none.
///
/// UTF-8 with `\n` between lines whatever put it there, with U+FFFD for bytes
/// that were not text. The context's, and valid until the next call.
///
/// On X11 and Wayland this asks the program that owns the clipboard and waits
/// for it, giving up after a second in which it sends nothing. In a browser it
/// is the last paste the page heard or what the program put there since,
/// because a page may read the clipboard only when somebody pastes - which is
/// also when a program wants it.
pub fn clipboardText(self: *Context) Error![]const u8 {
    self.clipboard.clearRetainingCapacity();
    try self.vtable.clipboardText(self.impl, &self.clipboard, self.gpa);
    try clipboard_mod.normalize(self.gpa, &self.clipboard);
    return self.clipboard.items;
}

/// Whether the clipboard holds text, asked without reading it.
///
/// For a Paste entry that greys out. Not free on X11, which asks the owner, but
/// quiet on Android, which shows a notice every time a program reads.
pub fn hasClipboardText(self: *Context) bool {
    return self.vtable.hasClipboardText(self.impl);
}

// -------------------------------------------------------------------------
// File dialogs
// -------------------------------------------------------------------------

/// Ask for a file - or several, with `multiple` - in the system's own dialog.
///
/// Returns at once, and the answer is a `.file_dialog` event with this id: no
/// paths when nothing was chosen. One dialog at a time; asking while one is
/// open is `error.Unavailable`, and so is a backend that has no dialog.
pub fn openFileDialog(self: *Context, options: dialog.FileOptions) Error!event.DialogId {
    for (options.filters) |filter| {
        if (!dialog.validFilter(filter)) return error.Unavailable;
    }
    return self.showDialog(options.window, .{
        .folder = false,
        .multiple = options.multiple,
        .title = options.title,
        .filters = options.filters,
        .initial_folder = options.initial_folder,
    });
}

/// Ask for a folder, the same way. On the web the answer names every file in
/// it instead, since a page is given files and never a folder - see `web`.
pub fn openFolderDialog(self: *Context, options: dialog.FolderOptions) Error!event.DialogId {
    return self.showDialog(options.window, .{
        .folder = true,
        .multiple = false,
        .title = options.title,
        .filters = &.{},
        .initial_folder = options.initial_folder,
    });
}

fn showDialog(self: *Context, parent: ?Window, wanted: backend_mod.DialogRequest) Error!event.DialogId {
    var request = wanted;
    if (request.title) |title| {
        if (!std.unicode.utf8ValidateSlice(title)) return error.Unavailable;
    }
    if (request.initial_folder) |folder| {
        if (!std.unicode.wtf8ValidateSlice(folder)) return error.Unavailable;
    }
    if (parent) |win| {
        request.owner = (self.entry(win.id) orelse return error.Unavailable).native;
        request.window = win.id;
    }
    request.id = @enumFromInt(self.next_dialog);

    try self.vtable.showFileDialog(self.impl, self.gpa, request);
    self.next_dialog = @max(1, self.next_dialog +% 1);
    return request.id;
}

/// The bytes of the `index`th file of the last `.file_dialog` answer, read
/// into memory from `gpa`. The caller frees them.
///
/// The one way to read an answer that works everywhere: on the desktop the
/// paths are paths and this reads them, while on the web and on Android they
/// are names, and the bytes come from the page or the system - see `web` and
/// the README. `error.Unavailable` for an index past the end, for a folder,
/// and for a file that cannot be read.
pub fn chosenFile(self: *Context, index: usize, gpa: Allocator) Error![]u8 {
    if (index >= self.chosen.items.len) return error.Unavailable;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try self.vtable.chosenFile(self.impl, index, self.chosen.items[index], &out, gpa);
    return out.toOwnedSlice(gpa);
}

fn keepChosen(self: *Context, paths: []const []const u8) Allocator.Error!void {
    self.forgetChosen();
    try self.chosen.ensureTotalCapacity(self.gpa, paths.len);
    for (paths) |path| self.chosen.appendAssumeCapacity(try self.gpa.dupe(u8, path));
}

fn forgetChosen(self: *Context) void {
    for (self.chosen.items) |path| self.gpa.free(path);
    self.chosen.clearRetainingCapacity();
}

// -------------------------------------------------------------------------
// Gamepads
// -------------------------------------------------------------------------

/// Every controller slot, connected or not.
///
/// Sixteen of them always, so a program can index by the number an event gave
/// it without checking a length first. `connected` says which are real.
pub fn gamepads(self: *const Context) []const gamepad_mod.Device {
    return &self.pads;
}

/// One slot, or null if the number is out of range or nothing is in it.
pub fn gamepad(self: *const Context, index: usize) ?*const gamepad_mod.Device {
    if (index >= self.pads.len) return null;
    if (!self.pads[index].connected) return null;
    return &self.pads[index];
}

/// The first controller that is plugged in, for a program that wants one and
/// does not care which.
pub fn firstGamepad(self: *const Context) ?*const gamepad_mod.Device {
    for (&self.pads) |*pad| {
        if (pad.connected) return pad;
    }
    return null;
}

/// Load controller layouts in SDL's `gamecontrollerdb.txt` format, and apply
/// them to anything already plugged in.
///
/// For the pad no system recognises. Most never need this - see `gamepad` for
/// which ones and why - so it is a call a program makes rather than a file this
/// library carries around.
///
/// Returns how many lines were taken.
pub fn updateGamepadMappings(self: *Context, text: []const u8) Error!usize {
    const taken = self.mappings.load(self.gpa, text) catch return error.OutOfMemory;
    for (&self.pads) |*pad| {
        if (pad.connected) self.applyMapping(pad);
    }
    return taken;
}

/// Give one device its mapped state, if there is a mapping for it and the
/// backend did not already know the layout.
fn applyMapping(self: *const Context, pad: *gamepad_mod.Device) void {
    if (self.mappings.find(pad.guid)) |mapping| {
        pad.state = mapping.apply(pad.raw);
        pad.mapped = true;
    }
}

/// Read every controller and report what changed.
///
/// Called from `pump`, which is why a program that pumps has a current state
/// without asking for one.
fn refreshGamepads(self: *Context) void {
    var before: [gamepad_mod.max_devices]bool = undefined;
    for (&self.pads, 0..) |*pad, index| before[index] = pad.connected;

    self.vtable.pollGamepads(self.impl, &self.pads);

    for (&self.pads, 0..) |*pad, index| {
        // A backend that already knew the layout said so; anything else gets
        // whatever mapping was loaded for it.
        if (pad.connected and !pad.mapped) self.applyMapping(pad);

        if (pad.connected == before[index]) continue;
        // A queue that is full drops the notice rather than failing the pump:
        // the device is still in `pads`, and a program that polls will see it.
        self.queue.push(if (pad.connected)
            .{ .gamepad_connected = index }
        else
            .{ .gamepad_disconnected = index }) catch {};
    }
}

// -------------------------------------------------------------------------
// Polled input
//
// The queue says what happened; these say what is. Both are fed by the same
// pump, so they never disagree.
// -------------------------------------------------------------------------

/// Is this key down? See `input.State.key` for what `sticky` changes.
pub fn key(self: *Context, which: keys.Key) bool {
    return self.state.key(which);
}

/// Is this mouse button down?
pub fn mouseButton(self: *Context, which: keys.MouseButton) bool {
    return self.state.button(which);
}

/// Where the cursor is, in content-area coordinates.
pub fn cursorPos(self: *const Context) [2]f64 {
    return self.state.cursor();
}

/// What was held down when the last input event arrived.
pub fn mods(self: *const Context) keys.Mods {
    return self.state.mods;
}

/// Keep a press readable until it has been polled once, so a tap that begins
/// and ends inside one frame is not lost. See `input.State`.
pub fn setStickyKeys(self: *Context, on: bool) void {
    self.state.sticky = on;
}

// -------------------------------------------------------------------------
// Used by Window, which is the public face of these
// -------------------------------------------------------------------------

pub fn entry(self: *Context, id: event.WindowId) ?*Window.Entry {
    return self.windows.getPtr(id);
}

pub fn destroyWindow(self: *Context, id: event.WindowId) void {
    if (self.windows.fetchSwapRemove(id)) |removed| {
        self.vtable.destroyWindow(self.impl, self.gpa, removed.value.native);
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a context can be opened on a target with nothing to open" {
    // `.none` is never chosen by `auto`; asking for it by name is how a test
    // gets a context on a machine with no display.
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    try testing.expectEqual(platform.Backend.none, ctx.backend());
    try testing.expectEqual(@as(usize, 0), ctx.windowCount());
}

test "pumping an empty backend yields nothing" {
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    try ctx.pump();
    try testing.expectEqual(@as(?event.Event, null), ctx.poll());
}

test "a backend this build has not got is refused by name" {
    const absent: platform.Backend = if (builtin.os.tag == .windows) .wayland else .win32;
    try testing.expectError(
        error.Unsupported,
        Context.init(testing.allocator, .{ .select = .{ .only = absent } }),
    );
}

test "a backend with no dialog refuses one, and so does a window that is not there" {
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    try testing.expectError(error.Unavailable, ctx.openFileDialog(.{ .multiple = true }));
    try testing.expectError(error.Unavailable, ctx.openFolderDialog(.{ .title = "Project" }));
    try testing.expectError(error.Unavailable, ctx.openFileDialog(.{ .window = .{ .ctx = &ctx, .id = @enumFromInt(9) } }));
    try testing.expectError(error.Unavailable, ctx.openFileDialog(.{ .title = "\xFF" }));
    try testing.expectError(error.Unavailable, ctx.chosenFile(0, testing.allocator));
}

test "an answer's paths outlive its pump, for reading afterwards" {
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    try ctx.queue.push(.{ .file_dialog = .{ .window = .none, .id = @enumFromInt(1), .paths = &.{ "a.png", "b.png" } } });
    for (ctx.queue.items.items) |ev| {
        if (ev == .file_dialog) try ctx.keepChosen(ev.file_dialog.paths);
    }
    ctx.queue.clear();
    try testing.expectEqual(@as(usize, 2), ctx.chosen.items.len);
    try testing.expectEqualStrings("b.png", ctx.chosen.items[1]);
    try testing.expectError(error.Unavailable, ctx.chosenFile(1, testing.allocator));
    try testing.expectError(error.Unavailable, ctx.chosenFile(2, testing.allocator));

    try ctx.keepChosen(&.{"c.png"});
    try testing.expectEqual(@as(usize, 1), ctx.chosen.items.len);
}

test "an id names one window forever, even after it is destroyed" {
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();

    // This backend makes no windows, so the table stays empty and an id that
    // was never handed out resolves to nothing.
    try testing.expectEqual(@as(?Window, null), ctx.window(@enumFromInt(1)));
    try testing.expectEqual(@as(?Window, null), ctx.window(.none));
}
