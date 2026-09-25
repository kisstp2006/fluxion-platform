// SPDX-License-Identifier: BSL-1.0

//! OpenGL contexts on X11, through GLX.
//!
//! **The window has to be built on the context's visual.** GLX picks a
//! framebuffer config, that config names an X visual, and a window created on a
//! different visual cannot be drawn into by the context - the server refuses
//! the `glXMakeCurrent` with `BadMatch`. So the config is chosen first and the
//! window is created afterwards, on the visual it named, with a colormap to go
//! with it. That is why `chooseConfig` and `createContext` are two calls: the
//! X11 backend has to make the window in between.
//!
//! **GLX rather than EGL.** Both can produce a context on an X server and Mesa
//! supports each, but GLX is the one every X driver has had for thirty years -
//! including the proprietary ones, where EGL-on-X11 arrived late and is still
//! the less travelled path. The Wayland backend uses EGL because Wayland has no
//! other option; here there is one, and it is the older and duller road.
//!
//! **The modern context call is an extension, but a cheap one.**
//! `glXGetProcAddressARB` needs no current context - unlike WGL, which needs a
//! whole throwaway window first - so there is no dance here, just a lookup.

const std = @import("std");

const dyn = @import("fluxion_dyn");
const gl = @import("../gl.zig");
const platform = @import("../platform.zig");

const Error = platform.Error;

const XID = c_ulong;
const Display = opaque {};
const Window = XID;
const Colormap = XID;
const VisualID = c_ulong;

const GLXFBConfig = *opaque {};
pub const GLXContext = *opaque {};
const GLXDrawable = XID;

/// `XVisualInfo`, which is what `XCreateWindow` needs and what a framebuffer
/// config is turned into.
pub const XVisualInfo = extern struct {
    visual: ?*anyopaque,
    visualid: VisualID,
    screen: c_int,
    depth: c_int,
    class: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    colormap_size: c_int,
    bits_per_rgb: c_int,
};

// `GLX_*` attribute names, from `glx.h`.
const glx_render_type: c_int = 0x8011;
const glx_rgba_bit: c_int = 0x00000001;
const glx_drawable_type: c_int = 0x8010;
const glx_window_bit: c_int = 0x00000001;
const glx_x_renderable: c_int = 0x8012;
const glx_doublebuffer: c_int = 5;
const glx_red_size: c_int = 8;
const glx_green_size: c_int = 9;
const glx_blue_size: c_int = 10;
const glx_alpha_size: c_int = 11;
const glx_depth_size: c_int = 12;
const glx_stencil_size: c_int = 13;
const glx_sample_buffers: c_int = 100000;
const glx_samples: c_int = 100001;
/// `GLX_FRAMEBUFFER_SRGB_CAPABLE_ARB`.
const glx_framebuffer_srgb_capable_arb: c_int = 0x20B2;
const glx_none: c_int = 0x8000;

/// From `GLX_ARB_create_context` and `GLX_ARB_create_context_profile`.
const glx_context_major_version_arb: c_int = 0x2091;
const glx_context_minor_version_arb: c_int = 0x2092;
const glx_context_flags_arb: c_int = 0x2094;
const glx_context_profile_mask_arb: c_int = 0x9126;
const glx_context_debug_bit_arb: c_int = 0x0001;
const glx_context_forward_compatible_bit_arb: c_int = 0x0002;
const glx_context_core_profile_bit_arb: c_int = 0x00000001;
const glx_context_compatibility_profile_bit_arb: c_int = 0x00000002;
/// `GLX_EXT_create_context_es2_profile`.
const glx_context_es_profile_bit_ext: c_int = 0x00000004;

const Glx = struct {
    glXQueryExtension: *const fn (*Display, *c_int, *c_int) callconv(.c) c_int,
    glXQueryVersion: *const fn (*Display, *c_int, *c_int) callconv(.c) c_int,
    glXChooseFBConfig: *const fn (*Display, c_int, [*]const c_int, *c_int) callconv(.c) ?[*]GLXFBConfig,
    glXGetVisualFromFBConfig: *const fn (*Display, GLXFBConfig) callconv(.c) ?*XVisualInfo,
    glXCreateNewContext: *const fn (*Display, GLXFBConfig, c_int, ?GLXContext, c_int) callconv(.c) ?GLXContext,
    glXDestroyContext: *const fn (*Display, GLXContext) callconv(.c) void,
    glXMakeCurrent: *const fn (*Display, GLXDrawable, ?GLXContext) callconv(.c) c_int,
    glXSwapBuffers: *const fn (*Display, GLXDrawable) callconv(.c) void,
    glXQueryExtensionsString: *const fn (*Display, c_int) callconv(.c) ?[*:0]const u8,
    /// The `ARB` spelling, which needs no current context and is the one every
    /// driver has. The unsuffixed `glXGetProcAddress` is newer and no better.
    glXGetProcAddressARB: *const fn ([*:0]const u8) callconv(.c) ?gl.Proc,
};

/// `GLX_RGBA_TYPE`, which is the only render type worth asking for.
const glx_rgba_type: c_int = 0x8014;

const Extensions = struct {
    createContextAttribs: ?*const fn (
        *Display,
        GLXFBConfig,
        ?GLXContext,
        c_int,
        [*]const c_int,
    ) callconv(.c) ?GLXContext = null,
    /// Three spellings of the same idea, in the order of preference. `EXT`
    /// takes a drawable and is the only one that can be set per window; `MESA`
    /// and `SGI` apply to whatever is current.
    swapIntervalEXT: ?*const fn (*Display, GLXDrawable, c_int) callconv(.c) void = null,
    swapIntervalMESA: ?*const fn (c_uint) callconv(.c) c_int = null,
    swapIntervalSGI: ?*const fn (c_int) callconv(.c) c_int = null,
    has_adaptive: bool = false,
    has_srgb: bool = false,
    has_es_profile: bool = false,
};

/// The names to try, in order. The versioned one first, for the same reason
/// libX11 is loaded that way: the unversioned link is a developer package.
const candidates: []const [:0]const u8 = &.{ "libGL.so.1", "libGL.so" };

/// What one window carries.
pub const Context = struct {
    handle: GLXContext,
    drawable: GLXDrawable,
    config: gl.Config,
};

/// A framebuffer config and the visual it names, handed back so that the X11
/// backend can build a window on it.
pub const Chosen = struct {
    fb_config: GLXFBConfig,
    visual: *XVisualInfo,
    config: gl.Config,
};

pub const Backend = struct {
    lib: ?dyn.Library = null,
    g: ?Glx = null,
    ext: Extensions = .{},
    probed: bool = false,
    /// `XFree`, handed over by the X11 backend at startup.
    ///
    /// GLX allocates with it - the framebuffer config array, the visual - and
    /// this file has no Xlib of its own. Taking the caller's rather than
    /// opening a second libX11 is the difference between one connection and
    /// two.
    x_free: ?*const fn (?*anyopaque) callconv(.c) c_int = null,

    pub fn open() Backend {
        var self: Backend = .{};
        var lib = dyn.Library.openAny(candidates) catch return self;
        const g = lib.bind(Glx) catch {
            lib.close();
            return self;
        };
        self.lib = lib;
        self.g = g;
        return self;
    }

    pub fn close(self: *Backend) void {
        if (self.lib) |*lib| lib.close();
        self.* = .{};
    }

    pub fn available(self: *const Backend) bool {
        return self.g != null;
    }
};

/// Look up the extension entry points. No current context needed, unlike WGL.
fn probe(self: *Backend, display: *Display, screen: c_int) void {
    if (self.probed) return;
    self.probed = true;

    const g = self.g orelse return;

    self.ext.createContextAttribs = @ptrCast(g.glXGetProcAddressARB("glXCreateContextAttribsARB"));
    self.ext.swapIntervalEXT = @ptrCast(g.glXGetProcAddressARB("glXSwapIntervalEXT"));
    self.ext.swapIntervalMESA = @ptrCast(g.glXGetProcAddressARB("glXSwapIntervalMESA"));
    self.ext.swapIntervalSGI = @ptrCast(g.glXGetProcAddressARB("glXSwapIntervalSGI"));

    if (g.glXQueryExtensionsString(display, screen)) |raw| {
        const list = std.mem.span(raw);
        self.ext.has_adaptive = hasExtension(list, "GLX_EXT_swap_control_tear");
        self.ext.has_srgb = hasExtension(list, "GLX_ARB_framebuffer_sRGB") or
            hasExtension(list, "GLX_EXT_framebuffer_sRGB");
        self.ext.has_es_profile = hasExtension(list, "GLX_EXT_create_context_es2_profile") or
            hasExtension(list, "GLX_EXT_create_context_es_profile");
    }
}

fn hasExtension(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    return false;
}

/// Pick a framebuffer config, and say which visual a window has to be built on.
///
/// The visual is X's to free, with `XFree`, once the window exists. The caller
/// does that because the caller is the one holding Xlib.
pub fn chooseConfig(
    self: *Backend,
    display: *Display,
    screen: c_int,
    config: gl.Config,
) Error!Chosen {
    const g = self.g orelse return error.Unavailable;

    var event_base: c_int = 0;
    var error_base: c_int = 0;
    // The library being present is not the same as the server having the
    // extension - a remote display over SSH often does not.
    if (g.glXQueryExtension(display, &error_base, &event_base) == 0) return error.Unavailable;

    probe(self, display, screen);

    var attribs: [40]c_int = undefined;
    var n: usize = 0;

    const pairs = [_][2]c_int{
        .{ glx_x_renderable, 1 },
        .{ glx_drawable_type, glx_window_bit },
        .{ glx_render_type, glx_rgba_bit },
        .{ glx_red_size, config.red_bits },
        .{ glx_green_size, config.green_bits },
        .{ glx_blue_size, config.blue_bits },
        .{ glx_alpha_size, config.alpha_bits },
        .{ glx_depth_size, config.depth_bits },
        .{ glx_stencil_size, config.stencil_bits },
        .{ glx_doublebuffer, if (config.double_buffer) 1 else 0 },
    };
    for (pairs) |pair| {
        attribs[n] = pair[0];
        attribs[n + 1] = pair[1];
        n += 2;
    }

    if (config.samples > 0) {
        attribs[n] = glx_sample_buffers;
        attribs[n + 1] = 1;
        attribs[n + 2] = glx_samples;
        attribs[n + 3] = config.samples;
        n += 4;
    }
    if (config.srgb and self.ext.has_srgb) {
        attribs[n] = glx_framebuffer_srgb_capable_arb;
        attribs[n + 1] = 1;
        n += 2;
    }
    attribs[n] = 0;
    n += 1;

    var count: c_int = 0;
    const found = g.glXChooseFBConfig(display, screen, &attribs, &count) orelse
        return error.Unavailable;
    // The array is X's, and is freed whether or not one of the configs is
    // taken - a `GLXFBConfig` stays valid after the list it came in is gone.
    defer if (self.x_free) |free| {
        _ = free(@ptrCast(found));
    };
    if (count <= 0) return error.Unavailable;

    // The first is the server's own best match, which is the one to take: the
    // list is sorted by how well each fits what was asked for.
    const fb_config = found[0];
    const visual = g.glXGetVisualFromFBConfig(display, fb_config) orelse return error.Unavailable;

    return .{ .fb_config = fb_config, .visual = visual, .config = config };
}

/// Free the visual `chooseConfig` handed back. Called once the window exists,
/// because until then the window is being built on it.
pub fn freeVisual(self: *Backend, visual: *XVisualInfo) void {
    if (self.x_free) |free| _ = free(visual);
}

/// Make the context, now that there is a window to point it at. `share`: a
/// context whose objects the new one shares.
pub fn createContext(
    self: *Backend,
    display: *Display,
    chosen: Chosen,
    window: Window,
    share: ?GLXContext,
) Error!Context {
    const g = self.g orelse return error.Unavailable;

    const handle = blk: {
        if (self.ext.createContextAttribs) |create| {
            var attribs: [16]c_int = undefined;
            var n: usize = 0;

            attribs[n] = glx_context_major_version_arb;
            attribs[n + 1] = chosen.config.major;
            n += 2;
            attribs[n] = glx_context_minor_version_arb;
            attribs[n + 1] = chosen.config.minor;
            n += 2;

            var flags: c_int = 0;
            if (chosen.config.debug) flags |= glx_context_debug_bit_arb;
            if (chosen.config.wantsForwardCompatible()) {
                flags |= glx_context_forward_compatible_bit_arb;
            }
            if (flags != 0) {
                attribs[n] = glx_context_flags_arb;
                attribs[n + 1] = flags;
                n += 2;
            }

            if (chosen.config.api == .opengl_es) {
                if (!self.ext.has_es_profile) return error.Unavailable;
                attribs[n] = glx_context_profile_mask_arb;
                attribs[n + 1] = glx_context_es_profile_bit_ext;
                n += 2;
            } else if (chosen.config.wantsProfile()) {
                attribs[n] = glx_context_profile_mask_arb;
                attribs[n + 1] = if (chosen.config.profile == .core)
                    glx_context_core_profile_bit_arb
                else
                    glx_context_compatibility_profile_bit_arb;
                n += 2;
            }

            attribs[n] = 0;
            n += 1;

            if (create(display, chosen.fb_config, share, 1, &attribs)) |made| break :blk made;
            return error.Unavailable;
        }

        // No extension: whatever version the driver feels like, which is the
        // old `glXCreateNewContext` behaviour. Only acceptable for a program
        // that did not ask for anything modern.
        if (chosen.config.major > 1 or chosen.config.api != .opengl) return error.Unavailable;
        break :blk g.glXCreateNewContext(display, chosen.fb_config, glx_rgba_type, share, 1) orelse
            return error.Unavailable;
    };

    return .{ .handle = handle, .drawable = window, .config = chosen.config };
}

pub fn destroyContext(self: *Backend, display: *Display, context: Context) void {
    const g = self.g orelse return;
    // Unbound first if it is ours, for the same reason as on Windows.
    _ = g.glXMakeCurrent(display, 0, null);
    g.glXDestroyContext(display, context.handle);
}

pub fn makeCurrent(self: *Backend, display: *Display, context: Context) Error!void {
    const g = self.g orelse return error.Unavailable;
    if (g.glXMakeCurrent(display, context.drawable, context.handle) == 0) return error.Unavailable;
}

pub fn clearCurrent(self: *Backend, display: *Display) void {
    const g = self.g orelse return;
    _ = g.glXMakeCurrent(display, 0, null);
}

pub fn swap(self: *Backend, display: *Display, context: Context) Error!void {
    const g = self.g orelse return error.Unavailable;
    g.glXSwapBuffers(display, context.drawable);
}

pub fn setSwapInterval(
    self: *Backend,
    display: *Display,
    context: Context,
    interval: c_int,
) Error!void {
    if (interval < 0 and !self.ext.has_adaptive) return error.Unavailable;

    // The per-drawable one is the right answer where it exists: it applies to
    // this window rather than to whatever happens to be current.
    if (self.ext.swapIntervalEXT) |set| {
        set(display, context.drawable, interval);
        return;
    }
    if (self.ext.swapIntervalMESA) |set| {
        if (interval < 0) return error.Unavailable;
        if (set(@intCast(interval)) != 0) return error.Unavailable;
        return;
    }
    if (self.ext.swapIntervalSGI) |set| {
        // SGI's version will not turn vsync *off* - it refuses zero - which is
        // worth failing on rather than pretending it worked.
        if (interval <= 0) return error.Unavailable;
        if (set(interval) != 0) return error.Unavailable;
        return;
    }
    return error.Unavailable;
}

/// One entry point by name.
///
/// `glXGetProcAddressARB` answers for everything, including the OpenGL 1.1
/// functions - unlike WGL, where they have to be fetched from the library's
/// own exports. The fallback is still here for a driver that disagrees.
pub fn getProcAddress(self: *Backend, name: [*:0]const u8) ?gl.Proc {
    const g = self.g orelse return null;
    if (g.glXGetProcAddressARB(name)) |proc| return proc;
    var lib = self.lib orelse return null;
    return lib.lookup(gl.Proc, std.mem.span(name));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "the visual struct is the shape Xlib writes" {
    // Handed straight to `XCreateWindow`, so a field in the wrong place means
    // a window on the wrong visual and a `BadMatch` from `glXMakeCurrent`.
    if (@sizeOf(usize) == 8) {
        try testing.expectEqual(@as(usize, 64), @sizeOf(XVisualInfo));
    }
    try testing.expectEqual(@as(usize, 0), @offsetOf(XVisualInfo, "visual"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(XVisualInfo, "visualid"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(XVisualInfo, "screen"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(XVisualInfo, "depth"));
}

test "an extension is found by whole word" {
    const list = "GLX_EXT_swap_control GLX_ARB_create_context GLX_ARB_framebuffer_sRGB";
    try testing.expect(hasExtension(list, "GLX_EXT_swap_control"));
    try testing.expect(!hasExtension(list, "GLX_EXT_swap_control_tear"));
    try testing.expect(hasExtension(list, "GLX_ARB_framebuffer_sRGB"));
    try testing.expect(!hasExtension(list, "GLX_ARB_create"));
}

test "a backend with nothing open refuses by name rather than crashing" {
    var backend: Backend = .{};
    try testing.expect(!backend.available());

    const display: *Display = @ptrFromInt(0x1000);
    const context: Context = .{
        .handle = @ptrFromInt(0x2000),
        .drawable = 3,
        .config = .{},
    };

    try testing.expectError(error.Unavailable, makeCurrent(&backend, display, context));
    try testing.expectError(error.Unavailable, swap(&backend, display, context));
    try testing.expectError(error.Unavailable, chooseConfig(&backend, display, 0, .{}));
    try testing.expectEqual(@as(?gl.Proc, null), getProcAddress(&backend, "glClear"));

    clearCurrent(&backend, display);
    destroyContext(&backend, display, context);
}

test "the swap interval falls back through three spellings" {
    var backend: Backend = .{};
    const display: *Display = @ptrFromInt(0x1000);
    const context: Context = .{ .handle = @ptrFromInt(0x2000), .drawable = 3, .config = .{} };

    // None of the three: refused rather than silently ignored.
    try testing.expectError(error.Unavailable, setSwapInterval(&backend, display, context, 1));

    // SGI's cannot turn vsync off, so asking it to is a refusal rather than a
    // call that returns success and changes nothing.
    backend.ext.swapIntervalSGI = struct {
        fn set(interval: c_int) callconv(.c) c_int {
            _ = interval;
            return 0;
        }
    }.set;
    try setSwapInterval(&backend, display, context, 1);
    try testing.expectError(error.Unavailable, setSwapInterval(&backend, display, context, 0));

    // MESA's can, but still not adaptive.
    backend.ext.swapIntervalMESA = struct {
        fn set(interval: c_uint) callconv(.c) c_int {
            _ = interval;
            return 0;
        }
    }.set;
    try setSwapInterval(&backend, display, context, 0);
    try testing.expectError(error.Unavailable, setSwapInterval(&backend, display, context, -1));

    // And adaptive needs the tear extension whichever spelling is in use.
    backend.ext.has_adaptive = true;
    try testing.expectError(error.Unavailable, setSwapInterval(&backend, display, context, -1));
}
