// SPDX-License-Identifier: BSL-1.0

//! The page, as WebAssembly imports.
//!
//! Every call the web backend makes out of the module, under the import module
//! `fluxion_platform` - which is the key `web.js` hangs its functions off, and
//! which is not `webgl` or `host`, so a page can hand this module the imports
//! of `fluxion-webgl` alongside these and neither set steps on the other.
//!
//! **Only ever analysed on a wasm build.** `extern "fluxion_platform"` names an
//! import module to the wasm linker and a library to link against to every
//! other one - `fluxion_platform.dll`, which does not exist. So nothing reaches
//! this file except through `web.zig`'s `if (platform.is_web)`, and the tests
//! that run on the host talk to `web_stub.zig` instead, which has the same
//! declarations written as Zig. `web.verify` is what keeps the two in step.
//!
//! The wire is the wasm ABI: pointers and `u32`s are `i32` on the JavaScript
//! side and arrive signed, which the glue undoes where it matters; a
//! `*WindowInfo` is an address in this module's memory, and the glue writes
//! the struct there with a `DataView`.

const wire = @import("web_wire.zig");

/// Say whether there is a page to talk to - a `document`, which a worker has
/// not got - and start listening to it. One when there is, zero when not.
pub extern "fluxion_platform" fn open() u32;

/// Stop listening, and let go of every canvas that was made here.
pub extern "fluxion_platform" fn close() void;

/// Find or make a canvas for window `id`, and fill `info` with what it got.
///
/// `flags` is resizable, decorated, visible and maximized, in bits 0 to 3.
/// `gl_version` is 0 for no context, 1 for WebGL 1 or better, 2 for WebGL 2
/// only; `gl_flags` is depth, stencil and antialias, in bits 0 to 2.
///
/// Answers the canvas's handle, or zero when there could be none. A context
/// that was asked for and could not be made is a canvas with `gl_version`
/// zero in `info`, which the backend turns into `error.Unavailable`.
pub extern "fluxion_platform" fn createWindow(
    id: u32,
    title_ptr: [*]const u8,
    title_len: u32,
    width: u32,
    height: u32,
    flags: u32,
    gl_version: u32,
    gl_flags: u32,
    info: *wire.WindowInfo,
) u32;

/// Stop listening to a canvas, and remove it if it was made here rather than
/// found in the page.
pub extern "fluxion_platform" fn destroyWindow(handle: u32) void;

/// The canvas's sizes as they are right now.
pub extern "fluxion_platform" fn windowInfo(handle: u32, info: *wire.WindowInfo) void;

/// `document.title`: the one title a page has.
pub extern "fluxion_platform" fn setTitle(handle: u32, ptr: [*]const u8, len: u32) void;

pub extern "fluxion_platform" fn setVisible(handle: u32, visible: u32) void;

/// The canvas's CSS size.
pub extern "fluxion_platform" fn setSize(handle: u32, width: u32, height: u32) void;

/// CSS `min-width` and the rest. Zero is no limit.
pub extern "fluxion_platform" fn setSizeLimits(
    handle: u32,
    min_width: u32,
    min_height: u32,
    max_width: u32,
    max_height: u32,
) void;

pub extern "fluxion_platform" fn setOpacity(handle: u32, opacity: f32) void;

/// A `backend.WindowState`, by number. One if it was done, zero if the page
/// has no such idea.
pub extern "fluxion_platform" fn setState(handle: u32, state: u32) u32;

/// Is the canvas in that `backend.WindowState` now?
pub extern "fluxion_platform" fn getState(handle: u32, state: u32) u32;

/// A `cursor.Mode`, by number. One if the page can do it, zero if it cannot.
pub extern "fluxion_platform" fn setCursorMode(handle: u32, mode: u32) u32;

/// Ask for pointer lock without acceleration. One where the browser can.
pub extern "fluxion_platform" fn setRawMouseMotion(handle: u32, on: u32) u32;

/// A `cursor.Shape`, by number.
pub extern "fluxion_platform" fn setCursorShape(handle: u32, shape: u32) u32;

/// The edges the page is drawn under - a phone's notch and its home bar, as
/// `env(safe-area-inset-*)` - in the canvas's drawing buffer pixels, written
/// as left, top, right, bottom. Zero on a page that has not asked for
/// `viewport-fit=cover`, which is what makes a browser report them at all.
pub extern "fluxion_platform" fn safeArea(handle: u32, out: *[4]u32) void;

/// The window's icon, which on a page is the tab's: `len` bytes of RGBA at
/// `pixels`. A null pointer puts back whatever the page had before.
pub extern "fluxion_platform" fn setIcon(handle: u32, pixels: ?[*]const u8, len: u32, width: u32, height: u32) u32;

/// An image as the pointer: `len` bytes of RGBA at `pixels`, and where in it
/// the pointer points. A null pointer puts the shape back. Zero where the page
/// could not make a cursor of it.
pub extern "fluxion_platform" fn setCursorImage(
    handle: u32,
    pixels: ?[*]const u8,
    len: u32,
    width: u32,
    height: u32,
    hot_x: u32,
    hot_y: u32,
) u32;

/// Take the canvas fullscreen, or give it back. Zero where the page has no
/// Fullscreen API at all.
pub extern "fluxion_platform" fn setFullscreen(handle: u32, on: u32) u32;

/// Focus the hidden text field that stands between the keyboard and the
/// canvas, or put it away again.
pub extern "fluxion_platform" fn setTextInput(handle: u32, on: u32) u32;

/// Move the hidden text field to the caret, so an input method opens there.
pub extern "fluxion_platform" fn setTextInputArea(handle: u32, x: i32, y: i32, width: u32, height: u32) void;

/// The screen the page is on. Zero where there is no `screen` to ask.
pub extern "fluxion_platform" fn monitor(info: *wire.MonitorInfo) u32;

/// Every connected controller, up to `capacity` of them. Answers how many
/// were written.
pub extern "fluxion_platform" fn gamepads(out: [*]wire.GamepadRecord, capacity: u32) u32;

/// Move what the page has heard since the last call into `records`, with any
/// text they carry in `heap`. Answers how many records were written; zero
/// means there is nothing left.
pub extern "fluxion_platform" fn drain(
    records: [*]wire.Record,
    capacity: u32,
    heap: [*]u8,
    heap_capacity: u32,
) u32;

/// The end of a frame.
///
/// In a program whose `main` is a loop this suspends the module until the
/// next animation frame - the one place control goes back to the browser, so
/// that it can present what was drawn and run the listeners that fill the
/// queue. A `WebAssembly.Suspending` import, and only in that model: a page
/// that calls the module's `frame` export instead gets one that returns at
/// once, because returning from `frame` already is the yield.
pub extern "fluxion_platform" fn sync() void;

/// Sleep until something arrives, or `timeout_ms` passes. Negative waits for
/// ever. Suspends the module like `sync`, and returns at once in the frame
/// model, where a page cannot be slept.
pub extern "fluxion_platform" fn wait(timeout_ms: f64) void;

/// Wake a `wait`.
pub extern "fluxion_platform" fn post() void;

/// One line to the console, at a severity from 0 (debug) to 3 (error).
pub extern "fluxion_platform" fn log(level: u32, ptr: [*]const u8, len: u32) void;

/// How many bytes the `index`th file of the last drop holds, or -1 when there
/// is no such file or it could not be read.
pub extern "fluxion_platform" fn droppedSize(index: u32) i32;

/// Copy the `index`th dropped file into `ptr[0..len]`. Answers how many bytes
/// were copied.
pub extern "fluxion_platform" fn droppedRead(index: u32, ptr: [*]u8, len: u32) u32;

/// Put text on the clipboard - now if the browser agrees, or inside the next
/// key press or click if it wants one. Zero where the page has no way to.
pub extern "fluxion_platform" fn setClipboard(ptr: [*]const u8, len: u32) u32;

/// How many bytes of UTF-8 the clipboard's text is, as far as the page knows
/// it - the last paste it heard, or what was put there since - or -1 when it
/// knows nothing.
pub extern "fluxion_platform" fn clipboardSize() i32;

/// Copy that text into `ptr[0..len]`. Answers how many bytes were copied.
pub extern "fluxion_platform" fn clipboardRead(ptr: [*]u8, len: u32) u32;

/// Open a file dialog for window `window` - an `<input type="file">` the glue
/// clicks, now or inside the next click or key press. `flags` is multiple and
/// folder in bits 0 and 1, `accept` the input's `accept`. Zero when a dialog
/// is already open or there is no page.
pub extern "fluxion_platform" fn openFileDialog(window: u32, id: u32, flags: u32, accept_ptr: [*]const u8, accept_len: u32) u32;

/// How many bytes the `index`th file of the last dialog's answer holds, or -1
/// when there is no such file or it was not read.
pub extern "fluxion_platform" fn chosenSize(index: u32) i32;

/// Copy that file into `ptr[0..len]`. Answers how many bytes were copied.
pub extern "fluxion_platform" fn chosenRead(index: u32, ptr: [*]u8, len: u32) u32;

/// `window.open` in a new tab. Zero when the browser blocked it.
pub extern "fluxion_platform" fn openUrl(ptr: [*]const u8, len: u32) u32;
