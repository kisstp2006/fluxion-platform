// SPDX-License-Identifier: BSL-1.0

//! Asking a window for an OpenGL context, and driving the one it gives back.
//!
//! **The context is part of the window, not a thing beside it.** Every platform
//! here decides the pixel format when the window is made and cannot change it
//! afterwards: Win32 allows one `SetPixelFormat` per window, X11 needs the
//! window created with the visual the framebuffer config named, and EGL wants a
//! surface built against a config. So the config goes in `Window.Desc` and a
//! window either has a context from the moment it exists or never gets one.
//!
//! ```zig
//! var win = try ctx.createWindow(.{ .gl = .{ .major = 3, .minor = 3 } });
//! try win.makeContextCurrent();
//! try win.setSwapInterval(1);
//! while (!win.shouldClose()) {
//!     try ctx.pump();
//!     draw();
//!     try win.swapBuffers();
//! }
//! ```
//!
//! **Nothing here loads a single GL function.** `getProcAddress` is the one
//! call that matters, and what it returns is for a loader to sort into a table -
//! `fluxion-gl` does exactly that. A windowing library that also shipped a GL
//! header would be two libraries in a coat.
//!
//! **A context belongs to one thread at a time.** `makeContextCurrent` binds it
//! to the calling thread and unbinds it from whichever thread had it.
//!
//! **Two windows can share what they draw with.** A window made with
//! `Window.Desc.share_gl_with` naming another has a context of its own whose
//! textures, buffers, shaders and programs are the other's: one renderer draws
//! into both, making each current in turn. What holds other objects - a
//! vertex array, a framebuffer - is each context's own, as GL has it. Web
//! pages and Android have no such thing, and say so.

const std = @import("std");
const testing = std.testing;

/// Which OpenGL. The desktop one, or the embedded one a phone has.
pub const Api = enum {
    /// Desktop OpenGL. Not available on Android, where the driver is ES only.
    opengl,
    /// OpenGL ES. Available everywhere, including on the desktop through
    /// Mesa or a vendor driver.
    opengl_es,
};

/// Which half of OpenGL, for version 3.2 and later.
pub const Profile = enum {
    /// Everything removed in 3.0 is gone. What a new program should ask for.
    core,
    /// The fixed-function pipeline is still there. For old code.
    compatibility,
    /// No preference, which is what a driver wants below 3.2 - asking for a
    /// profile there is an error rather than a hint.
    any,
};

/// What kind of context a window should come with.
///
/// The defaults are a modern core context with a depth and stencil buffer,
/// which is what a program that has not thought about it wants.
pub const Config = struct {
    api: Api = .opengl,
    /// The version to ask for. A driver may hand back a newer one - that is
    /// what "at least" means in every one of these APIs - but never an older.
    major: u8 = 3,
    minor: u8 = 3,
    profile: Profile = .core,

    red_bits: u8 = 8,
    green_bits: u8 = 8,
    blue_bits: u8 = 8,
    alpha_bits: u8 = 8,
    depth_bits: u8 = 24,
    stencil_bits: u8 = 8,

    /// Samples per pixel for multisampling. Zero is off, which is what a
    /// program that does its own antialiasing wants.
    samples: u8 = 0,

    /// Ask the driver to convert on write, so blending happens in linear space.
    /// Not granted everywhere, and a program that needs it should check.
    srgb: bool = false,

    /// Two buffers and a swap, rather than drawing straight to the screen.
    /// Almost always what is wanted; false is for a program that has its own
    /// reason.
    double_buffer: bool = true,

    /// Turn on the driver's own error reporting, which is worth the cost while
    /// writing a renderer and not afterwards.
    debug: bool = false,

    /// Refuse to provide anything the version removed, so that using it is an
    /// error here rather than a surprise on another driver.
    forward_compatible: bool = false,

    /// True where a profile is a thing to ask for at all.
    ///
    /// Below 3.2 there is no such idea, and a driver handed
    /// `GLX_CONTEXT_PROFILE_MASK` for a 2.1 context is entitled to refuse the
    /// whole request.
    pub fn wantsProfile(self: Config) bool {
        if (self.api != .opengl) return false;
        if (self.profile == .any) return false;
        return self.major > 3 or (self.major == 3 and self.minor >= 2);
    }

    /// True where `forward_compatible` means anything, which is 3.0 and later.
    pub fn wantsForwardCompatible(self: Config) bool {
        if (!self.forward_compatible) return false;
        if (self.api != .opengl) return false;
        return self.major >= 3;
    }

    pub fn format(self: Config, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {d}.{d}", .{
            if (self.api == .opengl) "OpenGL" else "OpenGL ES",
            self.major,
            self.minor,
        });
        if (self.wantsProfile()) try w.print(" {t}", .{self.profile});
        try w.print(" r{d}g{d}b{d}a{d} d{d} s{d}", .{
            self.red_bits,  self.green_bits, self.blue_bits,
            self.alpha_bits, self.depth_bits, self.stencil_bits,
        });
        if (self.samples > 0) try w.print(" x{d}", .{self.samples});
        if (self.srgb) try w.writeAll(" srgb");
    }
};

/// How a window is told to wait for the display before swapping.
pub const SwapInterval = enum(i32) {
    /// Swap as fast as the program can draw. Tears, and is what a benchmark
    /// wants.
    immediate = 0,
    /// One swap per refresh, which is what a program should use.
    vsync = 1,
    /// Swap on the next refresh, but do not block if the frame was late.
    /// Tears on a missed frame instead of dropping to half rate, which is the
    /// better of the two. Not granted everywhere.
    adaptive = -1,

    pub fn toInt(self: SwapInterval) i32 {
        return @intFromEnum(self);
    }
};

/// The address of one GL entry point, or null if the driver has no such thing.
///
/// A function pointer with no signature, because the signature belongs to
/// whichever loader is being fed - `fluxion-gl` has the whole table, and this
/// library has no business knowing what `glDrawElements` looks like.
///
/// Null means no. Non-null does *not* reliably mean yes: see
/// `Window.getProcAddress`.
pub const Proc = *const fn () callconv(.c) void;

/// What the platform layer keeps for a window that has a context.
///
/// Opaque on purpose: it is a `HGLRC` on Windows, a `GLXContext` on X11 and an
/// `EGLContext` elsewhere, and a program has no reason to tell them apart.
pub const Handle = ?*anyopaque;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a profile is only asked for where one exists" {
    // 3.2 is where profiles arrived. Below that, asking is an error rather
    // than a preference the driver can ignore.
    try testing.expect(!(Config{ .major = 2, .minor = 1 }).wantsProfile());
    try testing.expect(!(Config{ .major = 3, .minor = 1 }).wantsProfile());
    try testing.expect((Config{ .major = 3, .minor = 2 }).wantsProfile());
    try testing.expect((Config{ .major = 4, .minor = 6 }).wantsProfile());

    // `any` means "do not mention it", which is not the same as `core`.
    try testing.expect(!(Config{ .major = 4, .minor = 6, .profile = .any }).wantsProfile());

    // ES has no profiles at all.
    try testing.expect(!(Config{ .api = .opengl_es, .major = 3, .minor = 2 }).wantsProfile());
}

test "forward compatibility is only asked for where it means something" {
    try testing.expect(!(Config{ .forward_compatible = false, .major = 4 }).wantsForwardCompatible());
    try testing.expect(!(Config{ .forward_compatible = true, .major = 2 }).wantsForwardCompatible());
    try testing.expect((Config{ .forward_compatible = true, .major = 3 }).wantsForwardCompatible());
    try testing.expect(!(Config{
        .forward_compatible = true,
        .api = .opengl_es,
        .major = 3,
    }).wantsForwardCompatible());
}

test "the defaults are a context a modern program can use" {
    const config: Config = .{};
    try testing.expectEqual(Api.opengl, config.api);
    try testing.expect(config.major >= 3);
    try testing.expect(config.double_buffer);
    // A depth buffer by default: a program that draws anything in three
    // dimensions and forgot to ask would otherwise get a flat mess.
    try testing.expect(config.depth_bits > 0);
}

test "a swap interval is the number every platform wants" {
    try testing.expectEqual(@as(i32, 0), SwapInterval.immediate.toInt());
    try testing.expectEqual(@as(i32, 1), SwapInterval.vsync.toInt());
    // Negative, which is how both WGL and GLX spell adaptive.
    try testing.expectEqual(@as(i32, -1), SwapInterval.adaptive.toInt());
}

test "a config prints as a person would describe one" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "OpenGL 3.3 core r8g8b8a8 d24 s8",
        try std.fmt.bufPrint(&buf, "{f}", .{Config{}}),
    );
    try testing.expectEqualStrings(
        "OpenGL ES 3.0 r8g8b8a8 d24 s8 x4 srgb",
        try std.fmt.bufPrint(&buf, "{f}", .{Config{
            .api = .opengl_es,
            .major = 3,
            .minor = 0,
            .samples = 4,
            .srgb = true,
        }}),
    );
}
