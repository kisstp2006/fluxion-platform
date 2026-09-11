// SPDX-License-Identifier: BSL-1.0

//! Which windowing system this build can reach, and which one it got.
//!
//! Two questions, and they have different answers. `supported` is what this
//! *build* can talk to, fixed when the program is compiled: a Windows binary
//! can only ever be Win32. `Context.backend` is what this *run* actually found,
//! decided at startup: a Linux binary supports both X11 and Wayland, and which
//! one it opens depends on the session it was started in.
//!
//! That split is why every backend is loaded through `fluxion-dyn` rather than
//! linked. A binary that imports `XOpenDisplay` the ordinary way does not start
//! on a Wayland-only machine with no X libraries installed - the loader fails
//! before `main`, and a fallback that lives inside the program never gets to
//! run.
//!
//! Where there is nothing to reach at all - a cross-compiled target, a build
//! with no windowing system - `Backend.none` is the answer and every call says
//! so through `error.Unsupported`. The library still compiles, because a
//! program that only wanted the key tokens should not have to arrange its
//! imports around a platform it is not on.
//!
//! **A browser is a platform too**, and `wasm32-freestanding` is how a build
//! says it is for one: there the windowing system is the page, reached through
//! the imports `backend/web.js` supplies. WASI is not the same thing - a WASI
//! runtime is a command line with no page behind it, and a module that asked
//! it for a canvas would not even instantiate - so a `wasm32-wasi` build stays
//! `.none`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// A windowing system.
pub const Backend = enum {
    /// `user32.dll` and friends. The only one on Windows.
    win32,
    /// `libX11.so.6`, and the extensions worth having: Xrandr, Xinerama, Xcursor.
    x11,
    /// `libwayland-client.so.0`, plus the protocols a window needs.
    wayland,
    /// `libandroid.so` and one `ANativeWindow` the system owns.
    android,
    /// A `<canvas>` and the page around it, through the JavaScript that ships
    /// beside this library as `fluxion-platform.js`.
    web,
    /// Nothing. Not a gap: the target has no windowing system this library can
    /// reach, so there is nothing to find.
    none,

    /// Is this one of the POSIX desktop backends? Both go through the same
    /// input plumbing and the same EGL, and differ in how a surface is made.
    pub fn isPosixDesktop(self: Backend) bool {
        return self == .x11 or self == .wayland;
    }
};

/// Whether this build runs in a browser: a 32-bit wasm module with nothing
/// underneath it but the page that instantiated it.
///
/// 32-bit only. A `wasm64` module passes every pointer to JavaScript as a
/// `BigInt`, and the glue is written for the numbers every browser's wasm
/// actually uses.
pub const is_web = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;

/// Every backend this build could open, in the order they are tried.
///
/// A list rather than one value, because Linux has two and which is right is
/// not known until the program runs. Empty where there is nothing to try.
pub const supported: []const Backend = switch (builtin.os.tag) {
    .windows => &.{.win32},
    .linux => if (builtin.abi.isAndroid())
        &.{.android}
    else
        // Wayland first: on a session running both, it is the one without a
        // compatibility layer in the middle.
        &.{ .wayland, .x11 },
    .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => &.{ .wayland, .x11 },
    .freestanding => if (is_web) &.{.web} else &.{},
    else => &.{},
};

/// Which backend to open. `.auto` walks `supported` and keeps the first that
/// works, which is what a program that does not care should ask for.
pub const Selection = union(enum) {
    auto,
    only: Backend,
};

pub const Error = error{
    /// This build has no backend for the target, or the one asked for by name
    /// is not among `supported`.
    Unsupported,
    /// Every backend this build supports was tried and none opened. On Linux
    /// that usually means neither `DISPLAY` nor `WAYLAND_DISPLAY` is set, which
    /// is what a machine with no graphical session looks like. In a browser it
    /// means a module running in a worker, which has no page to draw on.
    NoDisplay,
    /// The windowing system is there but refused - out of a resource, a
    /// protocol version mismatch, a compositor that denied the connection.
    ConnectionFailed,
    /// A window could not be created, though the connection is fine.
    WindowCreationFailed,
    /// Asked for something this backend has not got: a cursor shape, a
    /// clipboard, a second window on Android.
    Unavailable,
    /// Ran out of memory.
    OutOfMemory,
};

/// Is `wanted` something this build could open? A `true` is not a promise that
/// it will: the machine still has to have it.
pub fn isSupported(wanted: Backend) bool {
    for (supported) |candidate| {
        if (candidate == wanted) return true;
    }
    return false;
}

/// The backends to try for a selection, or an error when the selection names
/// one this build has not got.
pub fn candidates(selection: Selection) Error![]const Backend {
    switch (selection) {
        .auto => {
            if (supported.len == 0) return error.Unsupported;
            return supported;
        },
        .only => |wanted| {
            // `none` is never in `supported`, so `auto` cannot land on it - but
            // asking for it by name is the way to get a context on a machine
            // with no display, which is what a test suite on a build server
            // needs.
            if (wanted == .none) return &[_]Backend{.none};
            if (!isSupported(wanted)) return error.Unsupported;
            // A slice of the static list, so no allocation and no lifetime.
            for (supported, 0..) |candidate, i| {
                if (candidate == wanted) return supported[i .. i + 1];
            }
            unreachable;
        },
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a platform either has backends to try or has none to try" {
    switch (builtin.os.tag) {
        .windows => {
            try testing.expectEqual(@as(usize, 1), supported.len);
            try testing.expectEqual(Backend.win32, supported[0]);
        },
        .linux => try testing.expect(supported.len > 0),
        else => {},
    }

    // The page is a backend only where the build says it is running in one.
    try testing.expectEqual(is_web, isSupported(.web));

    // `none` is the absence of a backend, so it is never in the list of ones to
    // try - otherwise `auto` would "succeed" by finding nothing.
    for (supported) |candidate| try testing.expect(candidate != .none);
}

test "asking for a backend this build has not got is refused by name" {
    // Nothing supports every backend, so at least one of these is absent on
    // any machine this test runs on.
    const absent: Backend = if (builtin.os.tag == .windows) .wayland else .win32;
    try testing.expect(!isSupported(absent));
    try testing.expectError(error.Unsupported, candidates(.{ .only = absent }));
}

test "`none` is askable by name and unreachable by `auto`" {
    // Not in `supported`, so nothing that does not name it can land on it.
    try testing.expect(!isSupported(.none));
    for (try candidates(.auto)) |candidate| try testing.expect(candidate != .none);

    // And named, it is the one candidate - which is how a headless test gets a
    // context on a machine with no display.
    const only = try candidates(.{ .only = .none });
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqual(Backend.none, only[0]);
}

test "auto offers every backend, only offers one" {
    if (supported.len == 0) {
        try testing.expectError(error.Unsupported, candidates(.auto));
        return;
    }

    const all = try candidates(.auto);
    try testing.expectEqual(supported.len, all.len);

    const one = try candidates(.{ .only = supported[0] });
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(supported[0], one[0]);
}

test "the POSIX desktop pair is the two that share their plumbing" {
    try testing.expect(Backend.x11.isPosixDesktop());
    try testing.expect(Backend.wayland.isPosixDesktop());
    try testing.expect(!Backend.win32.isPosixDesktop());
    try testing.expect(!Backend.android.isPosixDesktop());
    try testing.expect(!Backend.web.isPosixDesktop());
    try testing.expect(!Backend.none.isPosixDesktop());
}
