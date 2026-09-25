// SPDX-License-Identifier: BSL-1.0

//! Asking a real backend for an OpenGL context.
//!
//! `gl.zig` checks the config arithmetic and each backend checks its own
//! translation; this checks the seam - that a window either comes back with a
//! working context or refuses by name, that the context can be made current and
//! swapped, and that a window made without one says so rather than crashing.
//!
//! **A machine with no OpenGL passes all of this.** A build server, a container,
//! an SSH session with no GLX: `createWindow` says `error.Unavailable` and the
//! test skips. What must never happen is a window that claims to have a context
//! and then cannot be drawn into.

const std = @import("std");
const testing = std.testing;

const Context = @import("Context.zig");
const Window = @import("Window.zig");
const gl = @import("gl.zig");
const vulkan = @import("vulkan.zig");

/// A context, and a window with a GL context if this machine can make one.
///
/// In place rather than by value, for the reason the other test files give: a
/// `Window` points back at its context, and moving one breaks the other.
const Fixture = struct {
    ctx: Context = undefined,
    win: Window = undefined,
    has_gl: bool = false,

    fn open(self: *Fixture, config: ?gl.Config) bool {
        self.ctx = Context.init(testing.allocator, .{}) catch return false;
        self.win = self.ctx.createWindow(.{
            .title = "fluxion-platform gl",
            .width = 320,
            .height = 240,
            .visible = false,
            .gl = config,
        }) catch {
            self.ctx.deinit();
            return false;
        };
        self.has_gl = config != null;
        return true;
    }

    fn close(self: *Fixture) void {
        self.win.destroy();
        self.ctx.deinit();
    }
};

test "a window made without a context refuses every GL call by name" {
    var fixture: Fixture = .{};
    if (!fixture.open(null)) return error.SkipZigTest;
    defer fixture.close();
    const win = fixture.win;

    // Not a crash and not a silent no-op: a program that forgot to ask for a
    // context should find out at the first call rather than at the first blank
    // frame.
    try testing.expectError(error.Unavailable, win.makeContextCurrent());
    try testing.expectError(error.Unavailable, win.swapBuffers());
    try testing.expectError(error.Unavailable, win.setSwapInterval(.vsync));
    try testing.expectEqual(@as(?gl.Config, null), win.contextConfig());
}

test "a context that was granted can be made current and swapped" {
    var fixture: Fixture = .{};
    if (!fixture.open(.{ .major = 3, .minor = 3 })) return error.SkipZigTest;
    defer fixture.close();
    const win = fixture.win;

    // The window exists, so the context does: this backend does not hand back
    // a window with a broken one.
    try win.makeContextCurrent();

    const config = win.contextConfig() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(gl.Api.opengl, config.api);
    try testing.expectEqual(@as(u8, 3), config.major);

    // The one call every loader makes first. A context that cannot produce
    // `glClear` is not a context.
    try testing.expect(win.getProcAddress("glClear") != null);

    // And nothing is asserted about a name that does not exist, because the
    // answer differs by platform and both answers are correct. WGL and GLX
    // return null; EGL is entitled to return a dispatch stub for any `gl`
    // name, and Mesa does. A loader that treats a non-null pointer as proof
    // that a function exists is wrong on EGL - the extension string is the
    // authority, which is what `Window.getProcAddress` says.

    // Swapping a hidden window is still a swap. It may present nothing, which
    // is fine; what it must not do is fail.
    try win.swapBuffers();

    fixture.ctx.clearContext();
    // And current again afterwards, because clearing must not break the
    // context - only unbind it.
    try win.makeContextCurrent();
}

test "a window made to share another's context draws with the other's textures" {
    var fixture: Fixture = .{};
    if (!fixture.open(.{})) return error.SkipZigTest;
    defer fixture.close();
    const second = fixture.ctx.createWindow(.{
        .title = "fluxion-platform gl, shared",
        .width = 64,
        .height = 64,
        .visible = false,
        .gl = .{},
        .share_gl_with = fixture.win,
    }) catch |err| switch (err) {
        error.Unavailable => return error.SkipZigTest,
        else => return err,
    };
    defer second.destroy();

    const apientry: std.builtin.CallingConvention = if (@import("builtin").os.tag == .windows) .winapi else .c;
    const GenTextures = *const fn (i32, *u32) callconv(apientry) void;
    const IsTexture = *const fn (u32) callconv(apientry) u8;
    const BindTexture = *const fn (u32, u32) callconv(apientry) void;
    const texture_2d: u32 = 0x0DE1;

    // Made and bound in the first - a name is a texture once it is bound.
    try fixture.win.makeContextCurrent();
    const gen: GenTextures = @ptrCast(fixture.win.getProcAddress("glGenTextures") orelse return error.SkipZigTest);
    const bind: BindTexture = @ptrCast(fixture.win.getProcAddress("glBindTexture") orelse return error.SkipZigTest);
    var name: u32 = 0;
    gen(1, &name);
    bind(texture_2d, name);

    // A texture in the second too.
    try second.makeContextCurrent();
    const is: IsTexture = @ptrCast(second.getProcAddress("glIsTexture") orelse return error.SkipZigTest);
    try testing.expect(is(name) != 0);
    try second.swapBuffers();
    fixture.ctx.clearContext();
}

test "the swap interval is set or refused by name, never silently ignored" {
    var fixture: Fixture = .{};
    if (!fixture.open(.{})) return error.SkipZigTest;
    defer fixture.close();
    const win = fixture.win;

    try win.makeContextCurrent();

    // Vsync on and off are the two every platform can do, though a driver
    // configured to force one is entitled to refuse.
    for ([_]gl.SwapInterval{ .vsync, .immediate, .adaptive }) |interval| {
        win.setSwapInterval(interval) catch |err| switch (err) {
            error.Unavailable => continue,
            else => return err,
        };
    }
}

test "a stale window refuses every GL call rather than reaching through it" {
    var ctx = Context.init(testing.allocator, .{}) catch return error.SkipZigTest;
    defer ctx.deinit();

    const win = ctx.createWindow(.{ .visible = false }) catch return error.SkipZigTest;
    win.destroy();

    // The handle is a copy and outlives the window, which is the whole point
    // of it being one. Every call has to notice.
    try testing.expectError(error.Unavailable, win.makeContextCurrent());
    try testing.expectError(error.Unavailable, win.swapBuffers());
    try testing.expectError(error.Unavailable, win.setSwapInterval(.vsync));
    try testing.expectEqual(@as(?gl.Config, null), win.contextConfig());
    try testing.expectEqual(@as(?gl.Proc, null), win.getProcAddress("glClear"));
}

test "the Vulkan extensions match the backend that actually opened" {
    var ctx = Context.init(testing.allocator, .{}) catch return error.SkipZigTest;
    defer ctx.deinit();

    const names = ctx.requiredVulkanExtensions();
    try testing.expectEqualSlices(
        [*:0]const u8,
        vulkan.requiredInstanceExtensions(ctx.backend()),
        names,
    );

    // Not the empty list: a context that opened a real backend can present.
    try testing.expect(names.len == 2);
}

test "a Vulkan surface is refused when the loader has no entry point for it" {
    var ctx = Context.init(testing.allocator, .{}) catch return error.SkipZigTest;
    defer ctx.deinit();

    const win = ctx.createWindow(.{ .visible = false }) catch return error.SkipZigTest;
    defer win.destroy();

    // A loader that answers null for everything is what an instance created
    // without the surface extensions looks like. The refusal has to be by
    // name, because the alternative is calling through a null pointer.
    const nothing = struct {
        fn get(instance: usize, name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
            _ = .{ instance, name };
            return null;
        }
    }.get;

    try testing.expectError(error.Unavailable, win.createVulkanSurface(0, nothing, null));
}
