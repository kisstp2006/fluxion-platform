// SPDX-License-Identifier: BSL-1.0

//! What a program running in a browser needs from this library and cannot get
//! from the standard library.
//!
//! `wasm32-freestanding` has no console, no stderr and no stack trace, and
//! that is not a gap in Zig's support: it is what the target is. A wasm module
//! is functions and memory, and everything else is something the page chose to
//! hand it. So `std.log` is a compile error until something says where lines
//! go, and a panic traps with its message unread. Two declarations near the
//! top of the program fix both:
//!
//! ```zig
//! pub const std_options: std.Options = .{ .logFn = platform.web.logFn };
//! pub const panic = platform.web.panic;
//! ```
//!
//! Both go through the glue's `log` import, which writes to the console - or
//! to wherever the page told `fluxion-platform.js` to send them.
//!
//! **Off the web these are ordinary Zig.** The console is stderr and the panic
//! is the default one, so a program written against this still builds and runs
//! on the desktop, and so do its tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const platform = @import("platform.zig");
const Context = @import("Context.zig");
const web = @import("backend/web.zig");

/// Whether this build runs in a browser. See `platform.is_web`.
pub const is_web = platform.is_web;

/// How loudly to say something. The numbers are the wire format: the glue
/// turns them into `console.debug` through `console.error`.
pub const Level = enum(u32) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn from(level: std.log.Level) Level {
        return switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err => .err,
        };
    }
};

/// One line to the page's console. Stderr everywhere else.
pub fn write(level: Level, text: []const u8) void {
    if (is_web) {
        web.js.log(@intFromEnum(level), text.ptr, @intCast(text.len));
    } else {
        std.debug.print("{s}\n", .{text});
    }
}

/// The longest line `logFn` formats before cutting it. A fixed buffer, because
/// the alternative is an allocator and a log line is not worth one.
pub const line_limit = 1024;

/// A `std.log` backend that writes to the browser console.
///
/// ```zig
/// pub const std_options: std.Options = .{ .logFn = platform.web.logFn };
/// ```
///
/// The levels and scopes survive: `std.log.scoped(.input).warn` arrives as a
/// `console.warn` with `(input)` in front, and release-mode filtering happens
/// in Zig rather than in the browser.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    var text: [line_limit]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);
    // A line too long for the buffer is still worth sending: the part that
    // fitted is usually the part that says what went wrong.
    w.writeAll(prefix) catch {};
    w.print(format, args) catch {};

    write(.from(level), w.buffered());
}

/// A panic handler that says what happened before it traps.
///
/// ```zig
/// pub const panic = platform.web.panic;
/// ```
///
/// Without it a panic executes `unreachable`, the browser raises
/// `RuntimeError: unreachable`, and the message - the whole reason panics
/// have messages - is never seen. Off the web it is the default handler, so
/// a test run keeps its stack traces.
pub const panic = if (is_web) std.debug.FullPanic(struct {
    fn handler(message: []const u8, first_trace_address: ?usize) noreturn {
        _ = first_trace_address;
        var text: [line_limit]u8 = undefined;
        var w: std.Io.Writer = .fixed(&text);
        w.writeAll("panic: ") catch {};
        w.writeAll(message) catch {};
        write(.err, w.buffered());
        // A trap rather than a loop: the browser reports it with a stack
        // pointing into the module, and a spinning module would take the tab
        // down with it.
        @trap();
    }
}.handler) else std.debug.FullPanic(std.debug.defaultPanic);

/// The contents of the `index`th file of the last `.drop`, copied into memory
/// from `gpa`. The caller frees it.
///
/// A page gets no paths: the names in `.drop` are names, and a file that was
/// dropped is readable only through the event that delivered it. So the glue
/// reads each one as it arrives and keeps the bytes until the next drop, and
/// this is how a program asks for them. `error.Unavailable` off the web, for
/// an index past the end, and for a file the browser would not read.
pub fn droppedFile(ctx: *const Context, index: usize, gpa: Allocator) error{ Unavailable, OutOfMemory }![]u8 {
    if (ctx.backend() != .web) return error.Unavailable;
    if (index > std.math.maxInt(u32)) return error.Unavailable;

    const which: u32 = @intCast(index);
    const len = web.js.droppedSize(which);
    if (len < 0) return error.Unavailable;

    const bytes = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(bytes);
    if (web.js.droppedRead(which, bytes.ptr, @intCast(bytes.len)) != bytes.len) return error.Unavailable;
    return bytes;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the log levels are the numbers the glue expects" {
    try testing.expectEqual(0, @intFromEnum(Level.debug));
    try testing.expectEqual(1, @intFromEnum(Level.info));
    try testing.expectEqual(2, @intFromEnum(Level.warn));
    try testing.expectEqual(3, @intFromEnum(Level.err));
    try testing.expectEqual(Level.warn, Level.from(.warn));
}

test "a dropped file is not something a desktop has" {
    var ctx = try Context.init(testing.allocator, .{ .select = .{ .only = .none } });
    defer ctx.deinit();
    try testing.expectError(error.Unavailable, droppedFile(&ctx, 0, testing.allocator));
}
