// SPDX-License-Identifier: BSL-1.0

//! OpenGL contexts through EGL, for Wayland and for Android.
//!
//! **One file for two backends, because EGL is the same everywhere.** What
//! differs is only what a "native window" is: a `wl_egl_window` wrapping a
//! `wl_surface` on Wayland, an `ANativeWindow` on Android. Everything from
//! choosing a config to swapping a buffer is identical, so it is written once.
//!
//! **Wayland has no other option.** There is no GLX equivalent and no plan for
//! one: the compositor owns the display, a client renders into a buffer and
//! hands it over, and EGL is the interface that does that. Android is the same
//! story for a different reason - the driver is EGL and ES, and always has been.
//!
//! **`eglGetProcAddress` answers for core functions too**, unlike WGL. The
//! specification has said so since EGL 1.5, and the two drivers this runs
//! against - Mesa and whatever Android ships - both honoured it well before
//! that. The library's own exports are still tried second, for the one that
//! does not.

const std = @import("std");

const dyn = @import("fluxion_dyn");
const gl = @import("../gl.zig");
const platform = @import("../platform.zig");

const Error = platform.Error;

pub const Display = *opaque {};
pub const Surface = *opaque {};
pub const Config = *opaque {};
pub const ContextHandle = *opaque {};
/// Whatever the platform calls a window. A `wl_egl_window*` or an
/// `ANativeWindow*`, and EGL does not care which.
pub const NativeWindow = *anyopaque;

const egl_false: c_uint = 0;
const egl_true: c_uint = 1;
const egl_no_display: ?Display = null;
const egl_no_context: ?ContextHandle = null;
const egl_no_surface: ?Surface = null;

// Attribute names, from `egl.h`.
const egl_alpha_size: i32 = 0x3021;
const egl_blue_size: i32 = 0x3022;
const egl_green_size: i32 = 0x3023;
const egl_red_size: i32 = 0x3024;
const egl_depth_size: i32 = 0x3025;
const egl_stencil_size: i32 = 0x3026;
const egl_samples: i32 = 0x3031;
const egl_sample_buffers: i32 = 0x3032;
const egl_surface_type: i32 = 0x3033;
const egl_none: i32 = 0x3038;
const egl_renderable_type: i32 = 0x3040;
const egl_native_visual_id: i32 = 0x302E;
const egl_window_bit: i32 = 0x0004;
const egl_opengl_es2_bit: i32 = 0x0004;
const egl_opengl_es3_bit: i32 = 0x00000040;
const egl_opengl_bit: i32 = 0x0008;

const egl_opengl_es_api: c_uint = 0x30A0;
const egl_opengl_api: c_uint = 0x30A2;

const egl_context_major_version: i32 = 0x3098;
const egl_context_minor_version: i32 = 0x30FB;
const egl_context_opengl_profile_mask: i32 = 0x30FD;
const egl_context_opengl_core_profile_bit: i32 = 0x00000001;
const egl_context_opengl_compatibility_profile_bit: i32 = 0x00000002;
const egl_context_opengl_debug: i32 = 0x31B0;
const egl_context_opengl_forward_compatible: i32 = 0x31B1;
/// `EGL_GL_COLORSPACE` and `EGL_GL_COLORSPACE_SRGB`, from EGL 1.5 or
/// `EGL_KHR_gl_colorspace`.
const egl_gl_colorspace: i32 = 0x309D;
const egl_gl_colorspace_srgb: i32 = 0x3089;

const Egl = struct {
    eglGetDisplay: *const fn (?*anyopaque) callconv(.c) ?Display,
    eglInitialize: *const fn (Display, *i32, *i32) callconv(.c) c_uint,
    eglTerminate: *const fn (Display) callconv(.c) c_uint,
    eglBindAPI: *const fn (c_uint) callconv(.c) c_uint,
    eglChooseConfig: *const fn (Display, [*]const i32, ?[*]Config, i32, *i32) callconv(.c) c_uint,
    eglGetConfigAttrib: *const fn (Display, Config, i32, *i32) callconv(.c) c_uint,
    eglCreateContext: *const fn (Display, Config, ?ContextHandle, [*]const i32) callconv(.c) ?ContextHandle,
    eglDestroyContext: *const fn (Display, ContextHandle) callconv(.c) c_uint,
    eglCreateWindowSurface: *const fn (Display, Config, NativeWindow, ?[*]const i32) callconv(.c) ?Surface,
    eglDestroySurface: *const fn (Display, Surface) callconv(.c) c_uint,
    eglMakeCurrent: *const fn (Display, ?Surface, ?Surface, ?ContextHandle) callconv(.c) c_uint,
    eglSwapBuffers: *const fn (Display, Surface) callconv(.c) c_uint,
    eglSwapInterval: *const fn (Display, i32) callconv(.c) c_uint,
    eglGetProcAddress: *const fn ([*:0]const u8) callconv(.c) ?gl.Proc,
    eglQueryString: *const fn (?Display, i32) callconv(.c) ?[*:0]const u8,
};

/// `EGL_EXTENSIONS`.
const egl_extensions: i32 = 0x3055;

const candidates: []const [:0]const u8 = &.{ "libEGL.so.1", "libEGL.so" };

/// What one window carries.
pub const Context = struct {
    surface: Surface,
    handle: ContextHandle,
    config: gl.Config,
    /// The `wl_egl_window` this surface was made from, on the backend that has
    /// one. Null on Android, where the native window belongs to the activity.
    native: ?NativeWindow = null,
};

pub const Backend = struct {
    lib: ?dyn.Library = null,
    e: ?Egl = null,
    display: ?Display = null,
    has_srgb: bool = false,

    pub fn open() Backend {
        var self: Backend = .{};
        var lib = dyn.Library.openAny(candidates) catch return self;
        const e = lib.bind(Egl) catch {
            lib.close();
            return self;
        };
        self.lib = lib;
        self.e = e;
        return self;
    }

    pub fn close(self: *Backend) void {
        if (self.e) |e| {
            if (self.display) |display| {
                _ = e.eglMakeCurrent(display, null, null, null);
                _ = e.eglTerminate(display);
            }
        }
        if (self.lib) |*lib| lib.close();
        self.* = .{};
    }

    pub fn available(self: *const Backend) bool {
        return self.e != null;
    }
};

/// Connect EGL to whatever the platform's display is.
///
/// `native_display` is a `wl_display*` on Wayland and null on Android, where
/// there is only one display and EGL knows it. Done once, and lazily: a program
/// that never asks for a context never talks to the driver.
pub fn connect(self: *Backend, native_display: ?*anyopaque) Error!Display {
    if (self.display) |display| return display;
    const e = self.e orelse return error.Unavailable;

    const display = e.eglGetDisplay(native_display) orelse return error.Unavailable;

    var major: i32 = 0;
    var minor: i32 = 0;
    if (e.eglInitialize(display, &major, &minor) == egl_false) return error.Unavailable;

    if (e.eglQueryString(display, egl_extensions)) |raw| {
        const list = std.mem.span(raw);
        self.has_srgb = hasExtension(list, "EGL_KHR_gl_colorspace");
    }
    // EGL 1.5 has it in core, whatever the extension string says.
    if (major > 1 or (major == 1 and minor >= 5)) self.has_srgb = true;

    self.display = display;
    return display;
}

fn hasExtension(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    return false;
}

/// Pick a config, without making anything yet.
///
/// Separate from `createContext` because Android needs the config's native
/// visual id before the surface exists: `ANativeWindow_setBuffersGeometry` has
/// to be told the format, and telling it afterwards is too late.
pub fn chooseConfig(self: *Backend, display: Display, config: gl.Config) Error!Config {
    const e = self.e orelse return error.Unavailable;

    const renderable: i32 = switch (config.api) {
        .opengl => egl_opengl_bit,
        // Version three where three was asked for: a driver that has both
        // reports them separately and a 2-bit config cannot make a 3 context.
        .opengl_es => if (config.major >= 3) egl_opengl_es3_bit else egl_opengl_es2_bit,
    };

    var attribs: [32]i32 = undefined;
    var n: usize = 0;
    const pairs = [_][2]i32{
        .{ egl_surface_type, egl_window_bit },
        .{ egl_renderable_type, renderable },
        .{ egl_red_size, config.red_bits },
        .{ egl_green_size, config.green_bits },
        .{ egl_blue_size, config.blue_bits },
        .{ egl_alpha_size, config.alpha_bits },
        .{ egl_depth_size, config.depth_bits },
        .{ egl_stencil_size, config.stencil_bits },
    };
    for (pairs) |pair| {
        attribs[n] = pair[0];
        attribs[n + 1] = pair[1];
        n += 2;
    }
    if (config.samples > 0) {
        attribs[n] = egl_sample_buffers;
        attribs[n + 1] = 1;
        attribs[n + 2] = egl_samples;
        attribs[n + 3] = config.samples;
        n += 4;
    }
    attribs[n] = egl_none;
    n += 1;

    var chosen: [1]Config = undefined;
    var count: i32 = 0;
    if (e.eglChooseConfig(display, &attribs, &chosen, 1, &count) == egl_false) {
        return error.Unavailable;
    }
    if (count <= 0) return error.Unavailable;
    return chosen[0];
}

/// The pixel format id a config wants, which Android needs before the surface
/// is made. Zero where the driver will not say.
pub fn nativeVisualId(self: *Backend, display: Display, config: Config) i32 {
    const e = self.e orelse return 0;
    var value: i32 = 0;
    if (e.eglGetConfigAttrib(display, config, egl_native_visual_id, &value) == egl_false) return 0;
    return value;
}

/// Make the surface and the context, now that there is a native window.
pub fn createContext(
    self: *Backend,
    display: Display,
    egl_config: Config,
    native: NativeWindow,
    config: gl.Config,
) Error!Context {
    const e = self.e orelse return error.Unavailable;

    // Which API the *next* call means. EGL is a state machine here, and
    // forgetting this is how a program asking for desktop GL gets an ES
    // context and a pile of missing functions.
    const api: c_uint = if (config.api == .opengl) egl_opengl_api else egl_opengl_es_api;
    if (e.eglBindAPI(api) == egl_false) return error.Unavailable;

    var surface_attribs: [4]i32 = undefined;
    var sn: usize = 0;
    if (config.srgb and self.has_srgb) {
        surface_attribs[sn] = egl_gl_colorspace;
        surface_attribs[sn + 1] = egl_gl_colorspace_srgb;
        sn += 2;
    }
    surface_attribs[sn] = egl_none;
    sn += 1;

    const surface = e.eglCreateWindowSurface(display, egl_config, native, &surface_attribs) orelse
        return error.Unavailable;
    errdefer _ = e.eglDestroySurface(display, surface);

    var attribs: [12]i32 = undefined;
    var n: usize = 0;
    attribs[n] = egl_context_major_version;
    attribs[n + 1] = config.major;
    n += 2;
    // The minor version needs EGL 1.5 or `EGL_KHR_create_context`. Sending it
    // to a driver without either is an error rather than a hint, so it goes
    // only where a minor version was actually asked for.
    if (config.minor != 0) {
        attribs[n] = egl_context_minor_version;
        attribs[n + 1] = config.minor;
        n += 2;
    }
    if (config.wantsProfile()) {
        attribs[n] = egl_context_opengl_profile_mask;
        attribs[n + 1] = if (config.profile == .core)
            egl_context_opengl_core_profile_bit
        else
            egl_context_opengl_compatibility_profile_bit;
        n += 2;
    }
    if (config.debug) {
        attribs[n] = egl_context_opengl_debug;
        attribs[n + 1] = egl_true;
        n += 2;
    }
    if (config.wantsForwardCompatible()) {
        attribs[n] = egl_context_opengl_forward_compatible;
        attribs[n + 1] = egl_true;
        n += 2;
    }
    attribs[n] = egl_none;
    n += 1;

    const handle = e.eglCreateContext(display, egl_config, null, &attribs) orelse
        return error.Unavailable;

    return .{ .surface = surface, .handle = handle, .config = config, .native = null };
}

pub fn destroyContext(self: *Backend, display: Display, context: Context) void {
    const e = self.e orelse return;
    _ = e.eglMakeCurrent(display, null, null, null);
    _ = e.eglDestroyContext(display, context.handle);
    _ = e.eglDestroySurface(display, context.surface);
}

pub fn makeCurrent(self: *Backend, display: Display, context: Context) Error!void {
    const e = self.e orelse return error.Unavailable;
    // The same surface for reading and for drawing, which is what a window is.
    if (e.eglMakeCurrent(display, context.surface, context.surface, context.handle) == egl_false) {
        return error.Unavailable;
    }
}

pub fn clearCurrent(self: *Backend, display: Display) void {
    const e = self.e orelse return;
    _ = e.eglMakeCurrent(display, null, null, null);
}

pub fn swap(self: *Backend, display: Display, context: Context) Error!void {
    const e = self.e orelse return error.Unavailable;
    if (e.eglSwapBuffers(display, context.surface) == egl_false) return error.Unavailable;
}

pub fn setSwapInterval(self: *Backend, display: Display, interval: i32) Error!void {
    const e = self.e orelse return error.Unavailable;
    // EGL has no adaptive interval and no extension for one. A negative number
    // is refused rather than clamped to zero, which would turn vsync off when
    // the caller asked for a milder form of it.
    if (interval < 0) return error.Unavailable;
    if (e.eglSwapInterval(display, interval) == egl_false) return error.Unavailable;
}

pub fn getProcAddress(self: *Backend, name: [*:0]const u8) ?gl.Proc {
    const e = self.e orelse return null;
    if (e.eglGetProcAddress(name)) |proc| return proc;
    var lib = self.lib orelse return null;
    return lib.lookup(gl.Proc, std.mem.span(name));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "an extension is found by whole word" {
    const list = "EGL_KHR_create_context EGL_EXT_buffer_age EGL_KHR_gl_colorspace";
    try testing.expect(hasExtension(list, "EGL_KHR_gl_colorspace"));
    try testing.expect(hasExtension(list, "EGL_EXT_buffer_age"));
    try testing.expect(!hasExtension(list, "EGL_KHR_gl"));
    try testing.expect(!hasExtension(list, "EGL_KHR_create_context_no_error"));
}

test "a backend with nothing open refuses by name" {
    var backend: Backend = .{};
    try testing.expect(!backend.available());

    const display: Display = @ptrFromInt(0x1000);
    const context: Context = .{
        .surface = @ptrFromInt(0x2000),
        .handle = @ptrFromInt(0x3000),
        .config = .{},
    };

    try testing.expectError(error.Unavailable, connect(&backend, null));
    try testing.expectError(error.Unavailable, chooseConfig(&backend, display, .{}));
    try testing.expectError(error.Unavailable, makeCurrent(&backend, display, context));
    try testing.expectError(error.Unavailable, swap(&backend, display, context));
    try testing.expectError(error.Unavailable, setSwapInterval(&backend, display, 1));
    try testing.expectEqual(@as(?gl.Proc, null), getProcAddress(&backend, "glClear"));
    try testing.expectEqual(@as(i32, 0), nativeVisualId(&backend, display, @ptrFromInt(0x4000)));

    clearCurrent(&backend, display);
    destroyContext(&backend, display, context);
}

test "adaptive vsync is refused, because EGL has no such thing" {
    var backend: Backend = .{};
    const display: Display = @ptrFromInt(0x1000);

    // Refused before the driver is even asked, so a caller hears no rather
    // than having a negative number reinterpreted as "off".
    try testing.expectError(error.Unavailable, setSwapInterval(&backend, display, -1));
}
