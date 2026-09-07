// SPDX-License-Identifier: BSL-1.0

//! A window, a `VkInstance`, and a `VkSurfaceKHR` made from the two.
//!
//! The whole of what this library does for Vulkan: say which instance
//! extensions this session needs, and turn a window into a surface. Everything
//! after that - the physical device, the swapchain, the render pass - belongs
//! to the program, and `fluxion-vulkan` is the binding to write it against. So
//! that is what this example writes it against.
//!
//! **Two libraries, one seam.** `fluxion-vulkan` finds the loader and makes the
//! instance; this library makes the surface. They meet at exactly two values:
//! the instance, and the `vkGetInstanceProcAddr` the loader kept. Both cross
//! as integers, because a windowing library that declared `VkInstance` would
//! be declaring half of `vulkan.h` to go with it - so the cast happens here,
//! where both sides' types are known, and nowhere else.
//!
//! `fluxion_vulkan` is a lazy dependency: fetched for this example, never for
//! the library, which links nothing and loads nothing of Vulkan itself.

const std = @import("std");
const Io = std.Io;

const platform = @import("fluxion_platform");
const vk = @import("fluxion_vulkan");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;
    const gpa = init.arena.allocator();

    var ctx = platform.Context.init(gpa, .{}) catch |err| {
        try out.print("no display: {t}\n", .{err});
        try out.flush();
        return;
    };
    defer ctx.deinit();

    // Which extensions this *session* needs, not this build: a program that
    // could open either X11 or Wayland has to ask after it knows which it got.
    const extensions = ctx.requiredVulkanExtensions();
    try out.print("{t} needs:\n", .{ctx.backend()});
    for (extensions) |name| try out.print("   {s}\n", .{std.mem.span(name)});

    // The loader, by whichever name this platform gives it. Not linked: a
    // machine with no driver is a machine this program still starts on.
    var loader = vk.Loader.init() catch |err| {
        try out.print("\nno Vulkan loader on this machine ({t}), which is an answer\n", .{err});
        try out.flush();
        return;
    };
    defer loader.deinit();
    try out.print("\nloader: {s}, Vulkan {f}\n", .{ loader.name() orelse "?", try loader.apiVersion() });

    const app: vk.ApplicationInfo = .{
        .application_name = "fluxion-platform",
        .engine_name = "fluxion",
    };
    var info: vk.InstanceCreateInfo = .{ .application_info = &app };
    info.setExtensions(extensions);

    const instance = loader.createInstance(&info, null) catch |err| {
        // The usual cause is a driver without the platform surface extension -
        // a headless container, or a loader with no ICD installed.
        try out.print("vkCreateInstance failed: {t}\n", .{err});
        try out.flush();
        return;
    };
    const cmds = try loader.instanceCommands(instance);
    defer cmds.destroyInstance(instance, null);
    try out.writeAll("instance created\n");

    const win = try ctx.createWindow(.{
        .title = "fluxion-platform: Vulkan",
        .width = 640,
        .height = 480,
    });
    defer win.destroy();

    // The one call this library exists for here. The instance goes across as
    // an integer and the surface comes back as one; the loader's own
    // `vkGetInstanceProcAddr` goes with it, so nothing is loaded twice.
    const surface = win.createVulkanSurface(
        @intFromPtr(instance),
        @ptrCast(loader.getInstanceProcAddr),
        null,
    ) catch |err| {
        try out.print("no surface: {t}\n", .{err});
        try out.flush();
        return;
    };
    try out.print("surface 0x{x}\n", .{surface});

    // Destroyed before the window and before the instance, which is the order
    // the specification requires and the order this library will not do for
    // you - it never had the instance. `vkDestroySurfaceKHR` is an extension
    // command, so it is not in the binding's tables; the resolver finds it.
    const resolver = loader.instanceResolver(instance);
    const DestroySurface = *const fn (vk.Instance, u64, ?*const vk.AllocationCallbacks) callconv(vk.call) void;
    const destroy_surface: DestroySurface = @ptrCast(resolver.lookup("vkDestroySurfaceKHR").?);
    defer destroy_surface(instance, surface, null);

    // Proof that it is a real surface rather than a number: ask the driver
    // whether a queue on the first device could present to it.
    try reportPresentation(out, gpa, resolver, cmds, instance, surface);

    try out.flush();
}

/// Ask the first physical device whether any of its queues can present here.
///
/// Not part of what this library does - it is here because "the call returned
/// a non-zero handle" is weak evidence, and "the driver agrees it can present
/// to this window" is not.
fn reportPresentation(
    out: *Io.Writer,
    gpa: std.mem.Allocator,
    resolver: vk.Resolver,
    cmds: vk.InstanceCommands,
    instance: vk.Instance,
    surface: u64,
) !void {
    const SurfaceSupport = *const fn (vk.PhysicalDevice, u32, u64, *u32) callconv(vk.call) vk.Result;
    const supports: SurfaceSupport = @ptrCast(resolver.lookup("vkGetPhysicalDeviceSurfaceSupportKHR") orelse return);

    const devices = try vk.enumerate.physicalDevices(gpa, cmds, instance);
    if (devices.len == 0) {
        try out.writeAll("no physical device to ask\n");
        return;
    }

    const families = try vk.enumerate.queueFamilies(gpa, cmds, devices[0]);
    for (families, 0..) |_, index| {
        const family: u32 = @intCast(index);
        var ok: u32 = 0;
        _ = supports(devices[0], family, surface, &ok).check() catch continue;
        if (ok != 0) {
            try out.print("queue family {d} can present to it\n", .{family});
            return;
        }
    }
    try out.writeAll("no queue family can present to it\n");
}
