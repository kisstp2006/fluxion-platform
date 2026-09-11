// SPDX-License-Identifier: BSL-1.0

//! Getting a `VkSurfaceKHR` out of a window.
//!
//! **Two calls, and neither of them links Vulkan.** A program asks which
//! instance extensions this session needs, enables them when it makes its
//! `VkInstance`, and hands that instance back to get a surface. Everything in
//! between - the loader, the device, the swapchain - belongs to the program
//! and to whatever Vulkan binding it uses. `fluxion-vulkan` is the obvious one.
//!
//! ```zig
//! for (platform.vulkan.requiredInstanceExtensions(ctx.backend())) |name| {
//!     try enabled.append(name);
//! }
//! // ... create the instance ...
//! const surface = try win.createVulkanSurface(instance, get_instance_proc_addr, null);
//! ```
//!
//! **Handles are integers here, not types.** `VkInstance` is a pointer and
//! `VkSurfaceKHR` is a 64-bit handle that is *not* a pointer on a 32-bit
//! machine, and a windowing library that declared either would be declaring
//! half of `vulkan.h` to go with it. So an instance arrives as a `usize` and a
//! surface comes back as a `u64`, which is what both are on the wire, and the
//! caller casts at the seam where the real types are known.
//!
//! **The surface belongs to the caller.** Nothing here destroys one:
//! `vkDestroySurfaceKHR` needs the instance, and the instance outlives the
//! window only if the program says so. Destroy it before the window, and
//! before the instance.

const std = @import("std");
const testing = std.testing;

const platform = @import("platform.zig");

/// `PFN_vkGetInstanceProcAddr`, which is the one Vulkan entry point a program
/// always has: everything else is looked up through it.
///
/// Passed in rather than loaded here, because a program that already has a
/// Vulkan binding already has this, and loading a second copy of the loader
/// would be asking for two of everything.
pub const GetInstanceProcAddr = *const fn (
    instance: usize,
    name: [*:0]const u8,
) callconv(.c) ?*const fn () callconv(.c) void;

/// `VK_KHR_surface`, which every platform needs, plus the one for this
/// windowing system.
///
/// Enable all of them on the `VkInstance`, or `createVulkanSurface` will fail
/// with `error.Unavailable` - the entry point it needs does not exist until the
/// extension is on.
///
/// The strings are static, so the slice can be kept for as long as the program
/// likes.
pub fn requiredInstanceExtensions(backend: platform.Backend) []const [*:0]const u8 {
    return switch (backend) {
        .win32 => &.{ "VK_KHR_surface", "VK_KHR_win32_surface" },
        // Xlib rather than XCB. Both work against an X server and both are
        // near-universally present; Xlib is the one this backend already has a
        // `Display*` for, and handing over a connection we did not open is how
        // a surface ends up on a display nobody is pumping.
        .x11 => &.{ "VK_KHR_surface", "VK_KHR_xlib_surface" },
        .wayland => &.{ "VK_KHR_surface", "VK_KHR_wayland_surface" },
        .android => &.{ "VK_KHR_surface", "VK_KHR_android_surface" },
        // A browser has no Vulkan to enable anything on. Its modern API is
        // WebGPU, which is made from a canvas rather than from an instance.
        .web => &.{},
        // Nothing to present to, so nothing to enable. A program that asks
        // anyway gets an empty list rather than a lie about what is available.
        .none => &.{},
    };
}

/// True where this build could make a surface at all.
pub fn supported(backend: platform.Backend) bool {
    return switch (backend) {
        .none, .web => false,
        .win32, .x11, .wayland, .android => true,
    };
}

/// `VkStructureType` for each platform's surface-creation struct. These are
/// the numbers from `vulkan_core.h` and the platform headers, written out
/// rather than included, because including them would mean depending on the
/// Vulkan SDK to open a window.
pub const StructureType = struct {
    pub const xlib_surface_create_info_khr: u32 = 1000004000;
    pub const wayland_surface_create_info_khr: u32 = 1000006000;
    pub const android_surface_create_info_khr: u32 = 1000008000;
    pub const win32_surface_create_info_khr: u32 = 1000009000;
};

/// `VkXlibSurfaceCreateInfoKHR`.
///
/// No padding field between `flags` and the pointer after it, even though a
/// 64-bit build has four bytes there. An `extern struct` gets exactly the
/// padding C would, on every target - writing it out by hand would be right on
/// one word size and four bytes wrong on the other.
pub const XlibSurfaceCreateInfo = extern struct {
    s_type: u32 = StructureType.xlib_surface_create_info_khr,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    dpy: ?*anyopaque = null,
    /// `Window`, which is an `XID` - `unsigned long`.
    window: c_ulong = 0,
};

/// `VkWaylandSurfaceCreateInfoKHR`.
pub const WaylandSurfaceCreateInfo = extern struct {
    s_type: u32 = StructureType.wayland_surface_create_info_khr,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    display: ?*anyopaque = null,
    surface: ?*anyopaque = null,
};

/// `VkAndroidSurfaceCreateInfoKHR`.
pub const AndroidSurfaceCreateInfo = extern struct {
    s_type: u32 = StructureType.android_surface_create_info_khr,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    window: ?*anyopaque = null,
};

/// `VkWin32SurfaceCreateInfoKHR`.
pub const Win32SurfaceCreateInfo = extern struct {
    s_type: u32 = StructureType.win32_surface_create_info_khr,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    hinstance: ?*anyopaque = null,
    hwnd: ?*anyopaque = null,
};

/// `VK_SUCCESS`. Anything else from a create call is a failure, and which
/// failure is the caller's business rather than something to flatten into one
/// error.
pub const success: i32 = 0;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "every backend that can present asks for the surface extension" {
    for (std.enums.values(platform.Backend)) |backend| {
        const names = requiredInstanceExtensions(backend);
        if (!supported(backend)) {
            try testing.expectEqual(@as(usize, 0), names.len);
            continue;
        }

        // Two: the common one and the platform's. Never one, and never a
        // platform extension without `VK_KHR_surface`, which every other
        // surface extension depends on.
        try testing.expectEqual(@as(usize, 2), names.len);
        try testing.expectEqualStrings("VK_KHR_surface", std.mem.span(names[0]));
        try testing.expect(std.mem.startsWith(u8, std.mem.span(names[1]), "VK_KHR_"));
        try testing.expect(std.mem.endsWith(u8, std.mem.span(names[1]), "_surface"));
    }
}

test "the create-info structs are the size Vulkan expects" {
    // Checked rather than derived: a struct one field short is passed happily
    // and read as rubbish, and the driver reports a validation error a long
    // way from here.
    if (@sizeOf(usize) == 8) {
        // Four bytes of padding after `sType` and four more after `flags`,
        // both of which C has too and neither of which is written out here.
        try testing.expectEqual(@as(usize, 40), @sizeOf(XlibSurfaceCreateInfo));
        try testing.expectEqual(@as(usize, 40), @sizeOf(WaylandSurfaceCreateInfo));
        try testing.expectEqual(@as(usize, 32), @sizeOf(AndroidSurfaceCreateInfo));
        try testing.expectEqual(@as(usize, 40), @sizeOf(Win32SurfaceCreateInfo));

        // And the pointers land where the driver reads them.
        try testing.expectEqual(@as(usize, 8), @offsetOf(XlibSurfaceCreateInfo, "next"));
        try testing.expectEqual(@as(usize, 16), @offsetOf(XlibSurfaceCreateInfo, "flags"));
        try testing.expectEqual(@as(usize, 24), @offsetOf(XlibSurfaceCreateInfo, "dpy"));
        try testing.expectEqual(@as(usize, 32), @offsetOf(XlibSurfaceCreateInfo, "window"));
        try testing.expectEqual(@as(usize, 24), @offsetOf(AndroidSurfaceCreateInfo, "window"));
        try testing.expectEqual(@as(usize, 32), @offsetOf(Win32SurfaceCreateInfo, "hwnd"));
    }

    // And every one of them starts with the type and the chain pointer, in
    // that order, because that is what makes a `VkStructureType` readable by a
    // layer that has never heard of the struct.
    try testing.expectEqual(@as(usize, 0), @offsetOf(XlibSurfaceCreateInfo, "s_type"));
    try testing.expectEqual(@offsetOf(XlibSurfaceCreateInfo, "next"), @offsetOf(Win32SurfaceCreateInfo, "next"));
    try testing.expectEqual(@offsetOf(XlibSurfaceCreateInfo, "flags"), @offsetOf(AndroidSurfaceCreateInfo, "flags"));
}

test "the structure types are the published numbers" {
    // Each is 1000 * the extension's number, plus an index. Getting one wrong
    // means the driver reads a different struct than the one that was sent.
    try testing.expectEqual(@as(u32, 1000004000), StructureType.xlib_surface_create_info_khr);
    try testing.expectEqual(@as(u32, 1000006000), StructureType.wayland_surface_create_info_khr);
    try testing.expectEqual(@as(u32, 1000008000), StructureType.android_surface_create_info_khr);
    try testing.expectEqual(@as(u32, 1000009000), StructureType.win32_surface_create_info_khr);
}

test "the extension names are the ones a driver publishes" {
    try testing.expectEqualStrings(
        "VK_KHR_win32_surface",
        std.mem.span(requiredInstanceExtensions(.win32)[1]),
    );
    try testing.expectEqualStrings(
        "VK_KHR_xlib_surface",
        std.mem.span(requiredInstanceExtensions(.x11)[1]),
    );
    try testing.expectEqualStrings(
        "VK_KHR_wayland_surface",
        std.mem.span(requiredInstanceExtensions(.wayland)[1]),
    );
    try testing.expectEqualStrings(
        "VK_KHR_android_surface",
        std.mem.span(requiredInstanceExtensions(.android)[1]),
    );
}
