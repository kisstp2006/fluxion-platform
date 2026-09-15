// SPDX-License-Identifier: BSL-1.0

//! `shell` on a desktop that is not Windows: the freedesktop.org calls where a
//! session bus answers them, and `xdg-open` - or macOS's `open` - otherwise.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const dbus = @import("dbus.zig");
const portal = @import("portal.zig");
const linux_dialog = @import("linux_dialog.zig");

const heap = std.heap.c_allocator;

pub const Outcome = enum { done, not_found, no_handler, refused };

/// Long enough for the bus to start a portal or a file manager that was not running.
const bus_timeout_ms: c_int = 5000;
/// `xdg-open` returns once the program is started; one still running after this is left to it.
const run_timeout_ms: u32 = 5000;

const c = struct {
    extern "c" fn fork() c_int;
    extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _exit(status: c_int) noreturn;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn usleep(microseconds: c_uint) c_int;
    extern "c" var environ: [*:null]const ?[*:0]const u8;
};

const wnohang: c_int = 1;

/// A web address through the desktop portal, which a sandboxed program has to
/// use and every other program may. False where no portal took it.
pub fn portalOpen(uri: []const u8) bool {
    var bus = linux_dialog.Bus.open() orelse return false;
    defer bus.close();
    var w: dbus.Writer = .{ .gpa = heap };
    defer w.deinit();
    portal.writeOpenUri(&w, bus.nextSerial(), uri) catch return false;
    const reply = bus.call(&w, -1, bus_timeout_ms) catch return false;
    return reply.kind == .method_return;
}

/// The file manager's own "show in folder", with the file selected. False
/// where no file manager on the bus answers it.
pub fn fileManagerShow(uri: []const u8) bool {
    var bus = linux_dialog.Bus.open() orelse return false;
    defer bus.close();
    var w: dbus.Writer = .{ .gpa = heap };
    defer w.deinit();
    portal.writeShowItems(&w, bus.nextSerial(), uri) catch return false;
    const reply = bus.call(&w, -1, bus_timeout_ms) catch return false;
    return reply.kind == .method_return;
}

/// Run a program found on `PATH` and say how it ended, in `xdg-open`'s terms:
/// 2 is a file that is not there, 3 a tool it could not find.
pub fn run(program: []const u8, args: []const []const u8) std.mem.Allocator.Error!Outcome {
    var found: [512]u8 = undefined;
    const path = linux_dialog.onPath(&found, program) orelse return .no_handler;

    var arena_state: std.heap.ArenaAllocator = .init(heap);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try arena.allocSentinel(?[*:0]const u8, args.len + 1, null);
    argv[0] = path.ptr;
    for (args, argv[1..]) |arg, *slot| slot.* = (try arena.dupeZ(u8, arg)).ptr;

    const pid = c.fork();
    if (pid < 0) return .refused;
    if (pid == 0) {
        _ = c.execve(path, argv, c.environ);
        c._exit(127);
    }

    var status: c_int = 0;
    var waited: u32 = 0;
    while (waited < run_timeout_ms) : (waited += 10) {
        const ended = c.waitpid(pid, &status, wnohang);
        if (ended == pid) return outcome(status);
        if (ended < 0) return .refused;
        _ = c.usleep(10_000);
    }
    const reaper = std.Thread.spawn(.{}, reap, .{pid}) catch return .done;
    reaper.detach();
    return .done;
}

fn reap(pid: c_int) void {
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
}

fn outcome(status: c_int) Outcome {
    const bits: u32 = @bitCast(status);
    if (bits & 0x7F != 0) return .refused;
    return switch ((bits >> 8) & 0xFF) {
        0 => .done,
        2 => .not_found,
        3, 127 => .no_handler,
        else => .refused,
    };
}

test "an exit status says how a hand-over ended" {
    try std.testing.expectEqual(Outcome.done, outcome(0));
    try std.testing.expectEqual(Outcome.not_found, outcome(2 << 8));
    try std.testing.expectEqual(Outcome.no_handler, outcome(3 << 8));
    try std.testing.expectEqual(Outcome.no_handler, outcome(127 << 8));
    try std.testing.expectEqual(Outcome.refused, outcome(4 << 8));
    try std.testing.expectEqual(Outcome.refused, outcome(9));
}
