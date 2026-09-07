// SPDX-License-Identifier: BSL-1.0

//! OpenGL contexts on Windows, through WGL.
//!
//! **Everything worth having needs a context to ask for it.** `wglCreateContext`
//! makes a 1.1 context and nothing else; the call that makes a modern one,
//! `wglCreateContextAttribsARB`, is an *extension*, and an extension can only be
//! looked up through `wglGetProcAddress`, which needs a context to be current
//! first. So the sequence is: make a throwaway window, give it a pixel format,
//! make a 1.1 context on it, ask that context where the real entry points are,
//! throw all of it away, and only then make the window the program asked for.
//!
//! That is not this file being clever - it is the documented way, and every
//! toolkit on Windows does it. Doing it once at `open` rather than once per
//! window is the only choice made here.
//!
//! **A window's pixel format is set once and never again.** `SetPixelFormat`
//! fails on a window that already has one, so the format is chosen while the
//! window is being created and a window without a context can never gain one.
//!
//! **`wglGetProcAddress` will not return OpenGL 1.1.** The functions that
//! shipped in `opengl32.dll` - `glClear`, `glDrawArrays` and the rest of the
//! original set - are exported by the DLL and return null from
//! `wglGetProcAddress` on most drivers. So `getProcAddress` asks the extension
//! mechanism first and falls back to the library's own exports, which is what a
//! loader needs and what every other toolkit does.

const std = @import("std");

const dyn = @import("fluxion_dyn");
const gl = @import("../gl.zig");
const platform = @import("../platform.zig");

const Error = platform.Error;

const HWND = *opaque {};
const HDC = *opaque {};
const HGLRC = *opaque {};
const HINSTANCE = *opaque {};

/// `PIXELFORMATDESCRIPTOR`, which is the old way of asking and the only way
/// that works before there is a context to ask the new way with.
const PixelFormatDescriptor = extern struct {
    size: u16 = @sizeOf(PixelFormatDescriptor),
    version: u16 = 1,
    flags: u32 = 0,
    pixel_type: u8 = 0,
    color_bits: u8 = 0,
    red_bits: u8 = 0,
    red_shift: u8 = 0,
    green_bits: u8 = 0,
    green_shift: u8 = 0,
    blue_bits: u8 = 0,
    blue_shift: u8 = 0,
    alpha_bits: u8 = 0,
    alpha_shift: u8 = 0,
    accum_bits: u8 = 0,
    accum_red_bits: u8 = 0,
    accum_green_bits: u8 = 0,
    accum_blue_bits: u8 = 0,
    accum_alpha_bits: u8 = 0,
    depth_bits: u8 = 0,
    stencil_bits: u8 = 0,
    aux_buffers: u8 = 0,
    layer_type: u8 = 0,
    reserved: u8 = 0,
    layer_mask: u32 = 0,
    visible_mask: u32 = 0,
    damage_mask: u32 = 0,
};

const pfd_draw_to_window: u32 = 0x00000004;
const pfd_support_opengl: u32 = 0x00000020;
const pfd_double_buffer: u32 = 0x00000001;
const pfd_type_rgba: u8 = 0;
const pfd_main_plane: u8 = 0;

/// `WGL_*` attribute names, from `WGL_ARB_pixel_format`.
const wgl_draw_to_window_arb: i32 = 0x2001;
const wgl_support_opengl_arb: i32 = 0x2010;
const wgl_double_buffer_arb: i32 = 0x2011;
const wgl_pixel_type_arb: i32 = 0x2013;
const wgl_color_bits_arb: i32 = 0x2014;
const wgl_red_bits_arb: i32 = 0x2015;
const wgl_green_bits_arb: i32 = 0x2017;
const wgl_blue_bits_arb: i32 = 0x2019;
const wgl_alpha_bits_arb: i32 = 0x201B;
const wgl_depth_bits_arb: i32 = 0x2022;
const wgl_stencil_bits_arb: i32 = 0x2023;
const wgl_type_rgba_arb: i32 = 0x202B;
const wgl_sample_buffers_arb: i32 = 0x2041;
const wgl_samples_arb: i32 = 0x2042;
const wgl_framebuffer_srgb_capable_arb: i32 = 0x20A9;

/// From `WGL_ARB_create_context` and `WGL_ARB_create_context_profile`.
const wgl_context_major_version_arb: i32 = 0x2091;
const wgl_context_minor_version_arb: i32 = 0x2092;
const wgl_context_flags_arb: i32 = 0x2094;
const wgl_context_profile_mask_arb: i32 = 0x9126;
const wgl_context_debug_bit_arb: i32 = 0x0001;
const wgl_context_forward_compatible_bit_arb: i32 = 0x0002;
const wgl_context_core_profile_bit_arb: i32 = 0x00000001;
const wgl_context_compatibility_profile_bit_arb: i32 = 0x00000002;
/// `WGL_EXT_create_context_es2_profile`, which is how a desktop driver is asked
/// for an ES context.
const wgl_context_es2_profile_bit_ext: i32 = 0x00000004;

const Opengl32 = struct {
    wglCreateContext: *const fn (HDC) callconv(.winapi) ?HGLRC,
    wglDeleteContext: *const fn (HGLRC) callconv(.winapi) i32,
    wglMakeCurrent: *const fn (?HDC, ?HGLRC) callconv(.winapi) i32,
    wglGetProcAddress: *const fn ([*:0]const u8) callconv(.winapi) ?gl.Proc,
    wglGetCurrentContext: *const fn () callconv(.winapi) ?HGLRC,
    wglGetCurrentDC: *const fn () callconv(.winapi) ?HDC,
};

const Gdi32 = struct {
    ChoosePixelFormat: *const fn (HDC, *const PixelFormatDescriptor) callconv(.winapi) i32,
    SetPixelFormat: *const fn (HDC, i32, *const PixelFormatDescriptor) callconv(.winapi) i32,
    DescribePixelFormat: *const fn (HDC, i32, u32, ?*PixelFormatDescriptor) callconv(.winapi) i32,
    SwapBuffers: *const fn (HDC) callconv(.winapi) i32,
};

/// The extension entry points, found through a throwaway context. Each is
/// optional because a driver may have none of them, and then this backend can
/// still make an old-style context rather than nothing at all.
const Extensions = struct {
    createContextAttribs: ?*const fn (HDC, ?HGLRC, [*]const i32) callconv(.winapi) ?HGLRC = null,
    choosePixelFormat: ?*const fn (
        HDC,
        ?[*]const i32,
        ?[*]const f32,
        u32,
        [*]i32,
        *u32,
    ) callconv(.winapi) i32 = null,
    swapInterval: ?*const fn (i32) callconv(.winapi) i32 = null,
    /// `WGL_EXT_swap_control_tear`, without which a negative interval is
    /// refused rather than quietly treated as one.
    has_adaptive: bool = false,
    has_srgb: bool = false,
    has_es2_profile: bool = false,
};

/// What one window carries. Lives on the win32 backend's `Native`.
pub const Context = struct {
    hdc: HDC,
    hglrc: HGLRC,
    /// What the driver was asked for. Reported back by `contextConfig`, which
    /// is as close to the truth as this layer can get without a GL call - the
    /// version string belongs to a loader.
    config: gl.Config,
};

pub const Backend = struct {
    lib: ?dyn.Library = null,
    gdi: ?dyn.Library = null,
    wgl: ?Opengl32 = null,
    g: ?Gdi32 = null,
    ext: Extensions = .{},
    /// Whether the throwaway context has already been made and thrown away.
    probed: bool = false,

    pub fn open() Backend {
        var self: Backend = .{};

        // Optional: a machine with no OpenGL is one where a window still opens
        // and `.gl` is refused, which is better than failing to start.
        var lib = dyn.openSystem("opengl32.dll") catch return self;
        const wgl = lib.bind(Opengl32) catch {
            lib.close();
            return self;
        };
        var gdi = dyn.openSystem("gdi32.dll") catch {
            lib.close();
            return self;
        };
        const g = gdi.bind(Gdi32) catch {
            gdi.close();
            lib.close();
            return self;
        };

        self.lib = lib;
        self.gdi = gdi;
        self.wgl = wgl;
        self.g = g;
        return self;
    }

    pub fn close(self: *Backend) void {
        if (self.lib) |*lib| lib.close();
        if (self.gdi) |*lib| lib.close();
        self.* = .{};
    }

    pub fn available(self: *const Backend) bool {
        return self.wgl != null;
    }
};

/// Find the modern entry points, using a context made the old way.
///
/// `helper` is a window this backend may set a pixel format on and then never
/// use again. The caller makes and destroys it, because making a window is the
/// win32 backend's business and not this file's.
pub fn probe(self: *Backend, helper_dc: HDC) void {
    if (self.probed) return;
    self.probed = true;

    const wgl = self.wgl orelse return;
    const g = self.g orelse return;

    // Any format at all: this context exists only to be asked questions.
    var pfd: PixelFormatDescriptor = .{
        .flags = pfd_draw_to_window | pfd_support_opengl | pfd_double_buffer,
        .pixel_type = pfd_type_rgba,
        .color_bits = 32,
        .depth_bits = 24,
        .stencil_bits = 8,
        .layer_type = pfd_main_plane,
    };
    const format = g.ChoosePixelFormat(helper_dc, &pfd);
    if (format == 0) return;
    if (g.SetPixelFormat(helper_dc, format, &pfd) == 0) return;

    const temp = wgl.wglCreateContext(helper_dc) orelse return;
    defer _ = wgl.wglDeleteContext(temp);

    // Whatever was current before is put back afterwards. A program that had a
    // context on this thread and then opened a second window must not find its
    // own context quietly unbound.
    const had_context = wgl.wglGetCurrentContext();
    const had_dc = wgl.wglGetCurrentDC();
    defer _ = wgl.wglMakeCurrent(had_dc, had_context);

    if (wgl.wglMakeCurrent(helper_dc, temp) == 0) return;

    self.ext.createContextAttribs = @ptrCast(wgl.wglGetProcAddress("wglCreateContextAttribsARB"));
    self.ext.choosePixelFormat = @ptrCast(wgl.wglGetProcAddress("wglChoosePixelFormatARB"));
    self.ext.swapInterval = @ptrCast(wgl.wglGetProcAddress("wglSwapIntervalEXT"));

    // The extension list is itself an extension, so a driver without it is
    // treated as having none of the optional bits.
    const get_string: ?*const fn (HDC) callconv(.winapi) ?[*:0]const u8 =
        @ptrCast(wgl.wglGetProcAddress("wglGetExtensionsStringARB") orelse
            wgl.wglGetProcAddress("wglGetExtensionsStringEXT"));
    if (get_string) |get| {
        if (get(helper_dc)) |raw| {
            const list = std.mem.span(raw);
            self.ext.has_adaptive = hasExtension(list, "WGL_EXT_swap_control_tear");
            self.ext.has_srgb = hasExtension(list, "WGL_ARB_framebuffer_sRGB") or
                hasExtension(list, "WGL_EXT_framebuffer_sRGB");
            self.ext.has_es2_profile = hasExtension(list, "WGL_EXT_create_context_es2_profile");
        }
    }
}

/// Whole-word search. `WGL_ARB_framebuffer_sRGB` must not be found inside
/// `WGL_ARB_framebuffer_sRGB_something`, which a substring search would do.
fn hasExtension(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    return false;
}

/// Give a window a pixel format and a context.
///
/// Called while the window is being created, because that is the only time a
/// pixel format can be chosen.
pub fn createContext(self: *Backend, hdc: HDC, config: gl.Config) Error!Context {
    const wgl = self.wgl orelse return error.Unavailable;
    const g = self.g orelse return error.Unavailable;

    try choosePixelFormat(self, g, hdc, config);

    const hglrc = blk: {
        if (self.ext.createContextAttribs) |create| {
            var attribs: [16]i32 = undefined;
            var n: usize = 0;

            attribs[n] = wgl_context_major_version_arb;
            attribs[n + 1] = config.major;
            n += 2;
            attribs[n] = wgl_context_minor_version_arb;
            attribs[n + 1] = config.minor;
            n += 2;

            var flags: i32 = 0;
            if (config.debug) flags |= wgl_context_debug_bit_arb;
            if (config.wantsForwardCompatible()) flags |= wgl_context_forward_compatible_bit_arb;
            if (flags != 0) {
                attribs[n] = wgl_context_flags_arb;
                attribs[n + 1] = flags;
                n += 2;
            }

            if (config.api == .opengl_es) {
                // Only where the driver says it can: asking for an ES profile
                // it has never heard of fails the whole call.
                if (self.ext.has_es2_profile) {
                    attribs[n] = wgl_context_profile_mask_arb;
                    attribs[n + 1] = wgl_context_es2_profile_bit_ext;
                    n += 2;
                } else return error.Unavailable;
            } else if (config.wantsProfile()) {
                attribs[n] = wgl_context_profile_mask_arb;
                attribs[n + 1] = if (config.profile == .core)
                    wgl_context_core_profile_bit_arb
                else
                    wgl_context_compatibility_profile_bit_arb;
                n += 2;
            }

            attribs[n] = 0;
            n += 1;

            if (create(hdc, null, &attribs)) |made| break :blk made;
            // A driver that cannot give the version asked for says so by
            // returning null. Falling back to a 1.1 context would be worse
            // than saying no: the program would run and every modern call
            // would be missing.
            return error.Unavailable;
        }

        // No extension at all, which is a very old driver or a software
        // rasteriser. Only the original context is possible, and a program that
        // wanted a modern one should hear about it.
        if (config.major > 1 or config.api != .opengl) return error.Unavailable;
        break :blk wgl.wglCreateContext(hdc) orelse return error.Unavailable;
    };

    return .{ .hdc = hdc, .hglrc = hglrc, .config = config };
}

fn choosePixelFormat(self: *Backend, g: Gdi32, hdc: HDC, config: gl.Config) Error!void {
    // The modern way first: it is the only one that can ask for multisampling
    // or sRGB at all.
    if (self.ext.choosePixelFormat) |choose| {
        var attribs: [32]i32 = undefined;
        var n: usize = 0;

        const pairs = [_][2]i32{
            .{ wgl_draw_to_window_arb, 1 },
            .{ wgl_support_opengl_arb, 1 },
            .{ wgl_double_buffer_arb, if (config.double_buffer) 1 else 0 },
            .{ wgl_pixel_type_arb, wgl_type_rgba_arb },
            .{ wgl_red_bits_arb, config.red_bits },
            .{ wgl_green_bits_arb, config.green_bits },
            .{ wgl_blue_bits_arb, config.blue_bits },
            .{ wgl_alpha_bits_arb, config.alpha_bits },
            .{ wgl_depth_bits_arb, config.depth_bits },
            .{ wgl_stencil_bits_arb, config.stencil_bits },
        };
        for (pairs) |pair| {
            attribs[n] = pair[0];
            attribs[n + 1] = pair[1];
            n += 2;
        }

        if (config.samples > 0) {
            attribs[n] = wgl_sample_buffers_arb;
            attribs[n + 1] = 1;
            attribs[n + 2] = wgl_samples_arb;
            attribs[n + 3] = config.samples;
            n += 4;
        }
        if (config.srgb and self.ext.has_srgb) {
            attribs[n] = wgl_framebuffer_srgb_capable_arb;
            attribs[n + 1] = 1;
            n += 2;
        }
        attribs[n] = 0;
        n += 1;

        var format: i32 = 0;
        var count: u32 = 0;
        if (choose(hdc, &attribs, null, 1, @ptrCast(&format), &count) != 0 and count > 0) {
            // `SetPixelFormat` still wants a descriptor, and the honest one to
            // give it is the driver's own description of the format chosen.
            var described: PixelFormatDescriptor = .{};
            _ = g.DescribePixelFormat(hdc, format, @sizeOf(PixelFormatDescriptor), &described);
            if (g.SetPixelFormat(hdc, format, &described) != 0) return;
            return error.Unavailable;
        }
        // Fall through: a driver that cannot match the exact request may still
        // manage something close through the old call.
    }

    var pfd: PixelFormatDescriptor = .{
        .flags = pfd_draw_to_window | pfd_support_opengl |
            (if (config.double_buffer) pfd_double_buffer else 0),
        .pixel_type = pfd_type_rgba,
        .color_bits = config.red_bits + config.green_bits + config.blue_bits,
        .red_bits = config.red_bits,
        .green_bits = config.green_bits,
        .blue_bits = config.blue_bits,
        .alpha_bits = config.alpha_bits,
        .depth_bits = config.depth_bits,
        .stencil_bits = config.stencil_bits,
        .layer_type = pfd_main_plane,
    };
    const format = g.ChoosePixelFormat(hdc, &pfd);
    if (format == 0) return error.Unavailable;
    if (g.SetPixelFormat(hdc, format, &pfd) == 0) return error.Unavailable;
}

pub fn destroyContext(self: *Backend, context: Context) void {
    const wgl = self.wgl orelse return;
    // Unbound first, if it is this thread's: deleting a current context is
    // undefined, and on some drivers it takes the next `wglMakeCurrent` with it.
    if (wgl.wglGetCurrentContext() == context.hglrc) {
        _ = wgl.wglMakeCurrent(null, null);
    }
    _ = wgl.wglDeleteContext(context.hglrc);
}

pub fn makeCurrent(self: *Backend, context: Context) Error!void {
    const wgl = self.wgl orelse return error.Unavailable;
    if (wgl.wglMakeCurrent(context.hdc, context.hglrc) == 0) return error.Unavailable;
}

pub fn clearCurrent(self: *Backend) void {
    const wgl = self.wgl orelse return;
    _ = wgl.wglMakeCurrent(null, null);
}

pub fn swap(self: *Backend, context: Context) Error!void {
    const g = self.g orelse return error.Unavailable;
    if (g.SwapBuffers(context.hdc) == 0) return error.Unavailable;
}

pub fn setSwapInterval(self: *Backend, interval: i32) Error!void {
    const set = self.ext.swapInterval orelse return error.Unavailable;
    // A negative interval without the tear extension is not "the same as one":
    // some drivers take it and behave oddly, so it is refused here.
    if (interval < 0 and !self.ext.has_adaptive) return error.Unavailable;
    if (set(interval) == 0) return error.Unavailable;
}

/// One entry point by name.
///
/// Two places to look, and both are needed. `wglGetProcAddress` knows every
/// extension and everything above OpenGL 1.1; the original 1.1 functions are
/// plain exports of `opengl32.dll` and most drivers return null for them.
pub fn getProcAddress(self: *Backend, name: [*:0]const u8) ?gl.Proc {
    const wgl = self.wgl orelse return null;
    if (wgl.wglGetProcAddress(name)) |proc| {
        // Some drivers return 1, 2, 3 or -1 for "no" instead of null. Those
        // are addresses a program would happily call.
        const address = @intFromPtr(proc);
        if (address > 3 and address != std.math.maxInt(usize)) return proc;
    }
    var lib = self.lib orelse return null;
    return lib.lookup(gl.Proc, std.mem.span(name));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "the descriptor is the size Windows expects" {
    // `nSize` is how the call knows which version of the struct it was handed,
    // and it is filled in from `@sizeOf` - so the struct being one field short
    // would be a lie the driver believes.
    try testing.expectEqual(@as(usize, 40), @sizeOf(PixelFormatDescriptor));
    const pfd: PixelFormatDescriptor = .{};
    try testing.expectEqual(@as(u16, 40), pfd.size);
    try testing.expectEqual(@as(u16, 1), pfd.version);
}

test "an extension is found by whole word, not by substring" {
    const list = "WGL_ARB_extensions_string WGL_EXT_swap_control WGL_ARB_pixel_format";

    try testing.expect(hasExtension(list, "WGL_EXT_swap_control"));
    try testing.expect(hasExtension(list, "WGL_ARB_pixel_format"));
    try testing.expect(!hasExtension(list, "WGL_EXT_swap_control_tear"));
    // And the other way round: a prefix of a listed name is not listed.
    try testing.expect(!hasExtension(list, "WGL_ARB_pixel"));
    try testing.expect(!hasExtension(list, ""));
    try testing.expect(!hasExtension("", "WGL_EXT_swap_control"));
}

test "a backend with nothing open refuses every call by name" {
    var backend: Backend = .{};
    try testing.expect(!backend.available());

    const fake: Context = .{
        .hdc = @ptrFromInt(0x1000),
        .hglrc = @ptrFromInt(0x2000),
        .config = .{},
    };
    try testing.expectError(error.Unavailable, makeCurrent(&backend, fake));
    try testing.expectError(error.Unavailable, swap(&backend, fake));
    try testing.expectError(error.Unavailable, setSwapInterval(&backend, 1));
    try testing.expectEqual(@as(?gl.Proc, null), getProcAddress(&backend, "glClear"));

    // And the ones that cannot fail simply do nothing.
    clearCurrent(&backend);
    destroyContext(&backend, fake);
}

test "adaptive vsync is refused rather than rounded to one" {
    var backend: Backend = .{};
    // A driver with the swap-control extension but not the tear one.
    backend.ext.swapInterval = struct {
        fn set(interval: i32) callconv(.winapi) i32 {
            _ = interval;
            return 1;
        }
    }.set;

    try setSwapInterval(&backend, 1);
    try setSwapInterval(&backend, 0);
    // Negative means "tear rather than wait", and a driver that cannot do it
    // should hear no rather than be handed a number it will interpret its own
    // way.
    try testing.expectError(error.Unavailable, setSwapInterval(&backend, -1));

    backend.ext.has_adaptive = true;
    try setSwapInterval(&backend, -1);
}
