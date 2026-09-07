// SPDX-License-Identifier: BSL-1.0

//! A window, a `VkInstance`, and a `VkSurfaceKHR` made from the two.
//!
//! The whole of what this library does for Vulkan: say which instance
//! extensions this session needs, and turn a window into a surface. Everything
//! after that - the physical device, the swapchain, the render pass - belongs
//! to the program, and `fluxion-vulkan` is the binding to write it against.
//!
//! **The Vulkan loaded here is the example's, not the library's.** Just enough
//! of it to make an instance and prove the surface is real: a handful of
//! structs and four entry points, through `fluxion-dyn`. A real program already
//! has all of this from its own binding, which is exactly why
//! `createVulkanSurface` takes a `vkGetInstanceProcAddr` rather than looking
//! for one itself.

const std = @import("std");
const Io = std.Io;

const dyn = @import("fluxion_dyn");
const platform = @import("fluxion_platform");

/// `VK_STRUCTURE_TYPE_APPLICATION_INFO` and `..._INSTANCE_CREATE_INFO`.
const st_application_info: u32 = 0;
const st_instance_create_info: u32 = 1;
/// `VK_API_VERSION_1_0`.
const api_version_1_0: u32 = 1 << 22;

const ApplicationInfo = extern struct {
    s_type: u32 = st_application_info,
    next: ?*const anyopaque = null,
    application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32 = api_version_1_0,
};

const InstanceCreateInfo = extern struct {
    s_type: u32 = st_instance_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    application_info: ?*const ApplicationInfo = null,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
};

const Proc = *const fn () callconv(.c) void;
const GetInstanceProcAddr = *const fn (usize, [*:0]const u8) callconv(.c) ?Proc;

/// The loader, by the name each platform gives it.
const loaders: []const [:0]const u8 = &.{
    "vulkan-1.dll",
    "libvulkan.so.1",
    "libvulkan.so",
    "libvulkan.1.dylib",
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    var ctx = platform.Context.init(init.arena.allocator(), .{}) catch |err| {
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

    var lib = dyn.Library.openAny(loaders) catch {
        try out.writeAll("\nno Vulkan loader on this machine, which is an answer\n");
        try out.flush();
        return;
    };
    defer lib.close();

    const get_proc = lib.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse {
        try out.writeAll("\nthat library is not a Vulkan loader\n");
        try out.flush();
        return;
    };

    // A null instance is how the three calls that exist before one is made are
    // looked up. It is not an error - it is the documented way in.
    const create_instance: *const fn (
        *const InstanceCreateInfo,
        ?*const anyopaque,
        *usize,
    ) callconv(.c) i32 = @ptrCast(get_proc(0, "vkCreateInstance") orelse {
        try out.writeAll("\nno vkCreateInstance\n");
        try out.flush();
        return;
    });

    const app: ApplicationInfo = .{
        .application_name = "fluxion-platform",
        .engine_name = "fluxion",
    };
    const info: InstanceCreateInfo = .{
        .application_info = &app,
        .enabled_extension_count = @intCast(extensions.len),
        .enabled_extension_names = extensions.ptr,
    };

    var instance: usize = 0;
    const result = create_instance(&info, null, &instance);
    if (result != 0) {
        // The usual cause is a driver without the platform surface extension -
        // a headless container, or a loader with no ICD installed.
        try out.print("\nvkCreateInstance failed: {d}\n", .{result});
        try out.flush();
        return;
    }

    const destroy_instance: *const fn (usize, ?*const anyopaque) callconv(.c) void =
        @ptrCast(get_proc(instance, "vkDestroyInstance").?);
    defer destroy_instance(instance, null);

    try out.writeAll("\ninstance created\n");

    const win = try ctx.createWindow(.{
        .title = "fluxion-platform: Vulkan",
        .width = 640,
        .height = 480,
    });
    defer win.destroy();

    // The one call this library exists for here.
    const surface = win.createVulkanSurface(instance, get_proc, null) catch |err| {
        try out.print("no surface: {t}\n", .{err});
        try out.flush();
        return;
    };
    try out.print("surface 0x{x}\n", .{surface});

    // Destroyed before the window and before the instance, which is the order
    // the specification requires and the order this library will not do for
    // you - it never had the instance.
    const destroy_surface: *const fn (usize, u64, ?*const anyopaque) callconv(.c) void =
        @ptrCast(get_proc(instance, "vkDestroySurfaceKHR").?);
    defer destroy_surface(instance, surface, null);

    // Proof that it is a real surface rather than a number: ask the driver
    // whether a queue on the first device could present to it.
    try reportPresentation(out, get_proc, instance, surface);

    try out.flush();
}

/// Ask the first physical device whether any of its queues can present here.
///
/// Not part of what this library does - it is here because "the call returned
/// a non-zero handle" is weak evidence, and "the driver agrees it can present
/// to this window" is not.
fn reportPresentation(
    out: *Io.Writer,
    get_proc: GetInstanceProcAddr,
    instance: usize,
    surface: u64,
) !void {
    const enumerate: *const fn (usize, *u32, ?[*]usize) callconv(.c) i32 =
        @ptrCast(get_proc(instance, "vkEnumeratePhysicalDevices") orelse return);
    const queue_props: *const fn (usize, *u32, ?*anyopaque) callconv(.c) void =
        @ptrCast(get_proc(instance, "vkGetPhysicalDeviceQueueFamilyProperties") orelse return);
    const supports: *const fn (usize, u32, u64, *u32) callconv(.c) i32 =
        @ptrCast(get_proc(instance, "vkGetPhysicalDeviceSurfaceSupportKHR") orelse return);

    var device_count: u32 = 0;
    if (enumerate(instance, &device_count, null) != 0 or device_count == 0) {
        try out.writeAll("no physical device to ask\n");
        return;
    }

    var devices: [8]usize = undefined;
    device_count = @min(device_count, devices.len);
    if (enumerate(instance, &device_count, &devices) != 0) return;

    var families: u32 = 0;
    queue_props(devices[0], &families, null);

    var family: u32 = 0;
    while (family < families) : (family += 1) {
        var ok: u32 = 0;
        if (supports(devices[0], family, surface, &ok) != 0) continue;
        if (ok != 0) {
            try out.print("queue family {d} can present to it\n", .{family});
            return;
        }
    }
    try out.writeAll("no queue family can present to it\n");
}
