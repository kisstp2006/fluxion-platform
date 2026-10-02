// SPDX-License-Identifier: BSL-1.0

//! Files in a browser: a WASI build, whose file code is `std.Io`'s as on a
//! disc, answered by the page's glue - see `Files` in `web.js`.
//!
//! Open `zig-out/web/?example=files` after `zig build example-web`. Each visit
//! is counted in `/user/visits.txt`, which the page keeps in IndexedDB, so a
//! reload counts one more; a file dropped on the canvas is read from
//! `/picked`, where the glue put it, and its first bytes are logged.

const std = @import("std");

const platform = @import("fluxion_platform");

/// Lines to the page, and panics that say what they were.
pub const std_options: std.Options = .{ .logFn = platform.web.logFn };
pub const panic = platform.web.panic;

const gpa = std.heap.wasm_allocator;

var threaded: std.Io.Threaded = .init_single_threaded;
var ctx: platform.Context = undefined;
var win: platform.Window = undefined;

export fn init() bool {
    start() catch |err| {
        std.log.err("init: {t}", .{err});
        return false;
    };
    return true;
}

fn start() !void {
    const io = threaded.io();
    const user = try platform.folders.path(gpa, io, .data);
    defer gpa.free(user);
    const counter = try std.fs.path.join(gpa, &.{ user, "visits.txt" });
    defer gpa.free(counter);

    var buffer: [32]u8 = undefined;
    const before: u32 = if (std.Io.Dir.cwd().readFile(io, counter, &buffer)) |text|
        std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch 0
    else |_|
        0;
    const visits = before + 1;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = counter, .data = try std.fmt.bufPrint(&buffer, "{d}\n", .{visits}) });
    std.log.info("visit {d}, counted in {s} - reload to count another", .{ visits, counter });

    ctx = try .init(gpa, .{});
    win = try ctx.createWindow(.{ .title = "Files", .width = 640, .height = 360 });
    std.log.info("drop a file on the canvas to read it from /picked", .{});
}

export fn frame() bool {
    ctx.pump() catch return false;
    const io = threaded.io();
    while (ctx.poll()) |event| switch (event) {
        .close => return false,
        .drop => |d| for (d.paths) |path| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
                std.log.info("dropped  {s}, unreadable: {t}", .{ path, err });
                continue;
            };
            defer gpa.free(bytes);
            std.log.info("dropped  {s}, {d} bytes, starting {x}", .{ path, bytes.len, bytes[0..@min(bytes.len, 8)] });
        },
        else => {},
    };
    return true;
}

export fn deinit() void {
    win.destroy();
    ctx.deinit();
}
