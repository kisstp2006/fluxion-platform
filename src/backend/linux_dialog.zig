// SPDX-License-Identifier: BSL-1.0

//! A file dialog on a Linux desktop, on a thread of its own: the desktop
//! portal's where the session has one, zenity's or kdialog's where it does
//! not. What each is told is `portal`; this is the socket, the child process
//! and the thread, which X11 and Wayland share.
//!
//! The thread allocates from libc's `malloc` and never from the program's
//! allocator, which need not be safe to share.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const backend = @import("../backend.zig");
const dbus = @import("dbus.zig");
const dialog = @import("../dialog.zig");
const event = @import("../event.zig");
const platform = @import("../platform.zig");
const portal = @import("portal.zig");

const Error = platform.Error;
const heap = std.heap.c_allocator;

const c = struct {
    extern "c" fn socket(domain: c_uint, kind: c_uint, protocol: c_uint) c_int;
    extern "c" fn connect(fd: c_int, address: *const anyopaque, len: posix.socklen_t) c_int;
    extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
    extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn poll(fds: [*]Pollfd, nfds: c_ulong, timeout: c_int) c_int;
    extern "c" fn getuid() u32;
    extern "c" fn getpid() c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn fork() c_int;
    extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn dup2(old: c_int, new: c_int) c_int;
    extern "c" fn _exit(status: c_int) noreturn;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn kill(pid: c_int, sig: c_int) c_int;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" var environ: [*:null]const ?[*:0]const u8;
};

/// A chosen path's bytes, appended to `out`: what `Context.chosenFile` is on
/// X11 and Wayland, where the answer's paths are paths. A folder is refused.
pub fn readFile(path: []const u8, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const flags: u32 = @bitCast(posix.O{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    const fd = c.open(path_z, @bitCast(flags));
    if (fd < 0) return error.Unavailable;
    defer _ = c.close(fd);
    while (true) {
        try out.ensureUnusedCapacity(gpa, 64 * 1024);
        const room = out.unusedCapacitySlice();
        const got = c.read(fd, room.ptr, room.len);
        if (got < 0) return error.Unavailable;
        if (got == 0) return;
        out.items.len += @intCast(got);
    }
}

const Pollfd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short = 0,
};

const pollin: c_short = 0x001;
const sigterm: c_int = 15;
const no_sigpipe: c_int = if (@hasDecl(posix.MSG, "NOSIGNAL")) posix.MSG.NOSIGNAL else 0;
const close_on_exec: c_uint = if (@hasDecl(posix.SOCK, "CLOEXEC")) posix.SOCK.CLOEXEC else 0;

/// How long the program's own thread waits on the bus while deciding which
/// dialog there is. A bus that has not answered by then is not one to use.
const probe_timeout_ms: c_int = 1000;

const Failure = error{ Failed, Cancelled, TimedOut, Closed } || dbus.Error || Allocator.Error;

// -------------------------------------------------------------------------
// The session bus
// -------------------------------------------------------------------------

/// One connection to the session bus, logged in and named.
const Bus = struct {
    fd: c_int,
    serial: u32 = 0,
    /// What has arrived and not been read: the message `next` last handed out
    /// is at the front until the following call.
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    handed_out: usize = 0,
    name_bytes: [128]u8 = undefined,
    name_len: usize = 0,

    fn open() ?Bus {
        var bus: Bus = .{ .fd = connectSession() orelse return null };
        if (!bus.login() or !bus.hello()) {
            bus.close();
            return null;
        }
        return bus;
    }

    fn close(self: *Bus) void {
        _ = c.close(self.fd);
        self.buffer.deinit(heap);
        self.fd = -1;
    }

    fn name(self: *const Bus) []const u8 {
        return self.name_bytes[0..self.name_len];
    }

    fn nextSerial(self: *Bus) u32 {
        self.serial +%= 1;
        if (self.serial == 0) self.serial = 1;
        return self.serial;
    }

    /// `MSG_NOSIGNAL`: a bus that has gone away would otherwise end the whole
    /// program with `SIGPIPE`.
    fn sendAll(self: *Bus, bytes: []const u8) bool {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = c.send(self.fd, bytes[sent..].ptr, bytes.len - sent, no_sigpipe);
            if (n <= 0) return false;
            sent += @intCast(n);
        }
        return true;
    }

    fn login(self: *Bus) bool {
        var line: [64]u8 = undefined;
        if (!self.sendAll("\x00") or !self.sendAll(dbus.authLine(&line, c.getuid()))) return false;
        var answer: [256]u8 = undefined;
        var len: usize = 0;
        while (len < answer.len) {
            self.waitReadable(-1, probe_timeout_ms) catch return false;
            if (c.recv(self.fd, answer[len..].ptr, 1, 0) != 1) return false;
            len += 1;
            if (std.mem.endsWith(u8, answer[0..len], "\r\n")) break;
        }
        return std.mem.startsWith(u8, answer[0..len], "OK ") and self.sendAll("BEGIN\r\n");
    }

    fn hello(self: *Bus) bool {
        var w: dbus.Writer = .{ .gpa = heap };
        defer w.deinit();
        w.call(self.nextSerial(), .{ .destination = portal.bus_name, .path = portal.bus_path, .interface = portal.bus_name, .member = "Hello" }) catch return false;
        const reply = self.call(&w, -1, probe_timeout_ms) catch return false;
        var body = reply.body;
        const unique = body.string() catch return false;
        if (reply.kind != .method_return or unique.len > self.name_bytes.len) return false;
        @memcpy(self.name_bytes[0..unique.len], unique);
        self.name_len = unique.len;
        return true;
    }

    /// Whether the portal is running or would be started by asking - asked of
    /// the bus alone, so nothing is started by the question.
    fn hasPortal(self: *Bus) bool {
        var w: dbus.Writer = .{ .gpa = heap };
        defer w.deinit();
        w.call(self.nextSerial(), .{ .destination = portal.bus_name, .path = portal.bus_path, .interface = portal.bus_name, .member = "NameHasOwner", .signature = "s" }) catch return false;
        w.string(portal.service) catch return false;
        const owned = self.call(&w, -1, probe_timeout_ms) catch return false;
        var body = owned.body;
        if (owned.kind == .method_return and (body.boolean() catch false)) return true;

        w.call(self.nextSerial(), .{ .destination = portal.bus_name, .path = portal.bus_path, .interface = portal.bus_name, .member = "ListActivatableNames" }) catch return false;
        const listed = self.call(&w, -1, probe_timeout_ms) catch return false;
        if (listed.kind != .method_return) return false;
        body = listed.body;
        const end = body.beginArray("s") catch return false;
        while (body.pos < end) {
            const each = body.string() catch return false;
            if (std.mem.eql(u8, each, portal.service)) return true;
        }
        return false;
    }

    /// Send a call and wait for its answer, passing over anything else that
    /// arrives meanwhile - the bus's own signals, mostly.
    fn call(self: *Bus, w: *dbus.Writer, cancel: c_int, timeout_ms: c_int) Failure!dbus.Header {
        const message = w.finish();
        const serial = std.mem.readInt(u32, message[8..12], .little);
        if (!self.sendAll(message)) return error.Closed;
        while (true) {
            const reply = try self.next(cancel, timeout_ms);
            if (reply.kind != .method_return and reply.kind != .@"error") continue;
            if (reply.reply_serial == serial) return reply;
        }
    }

    /// The next whole message. Its slices point into the buffer and last until
    /// the next call.
    fn next(self: *Bus, cancel: c_int, timeout_ms: c_int) Failure!dbus.Header {
        if (self.handed_out > 0) {
            const left = self.buffer.items.len - self.handed_out;
            std.mem.copyForwards(u8, self.buffer.items[0..left], self.buffer.items[self.handed_out..]);
            self.buffer.items.len = left;
            self.handed_out = 0;
        }
        while (true) {
            if (try dbus.messageLength(self.buffer.items)) |len| {
                if (self.buffer.items.len >= len) {
                    self.handed_out = len;
                    return dbus.parse(self.buffer.items[0..len]);
                }
            }
            try self.waitReadable(cancel, timeout_ms);
            try self.buffer.ensureUnusedCapacity(heap, 16 * 1024);
            const room = self.buffer.unusedCapacitySlice();
            const got = c.recv(self.fd, room.ptr, room.len, 0);
            if (got <= 0) return error.Closed;
            self.buffer.items.len += @intCast(got);
        }
    }

    fn waitReadable(self: *Bus, cancel: c_int, timeout_ms: c_int) Failure!void {
        var fds = [_]Pollfd{ .{ .fd = self.fd, .events = pollin }, .{ .fd = cancel, .events = pollin } };
        while (true) {
            const ready = c.poll(&fds, if (cancel >= 0) 2 else 1, timeout_ms);
            if (ready == 0) return error.TimedOut;
            if (ready < 0) continue;
            if (cancel >= 0 and fds[1].revents != 0) return error.Cancelled;
            return;
        }
    }
};

/// `DBUS_SESSION_BUS_ADDRESS`, or where systemd puts the bus when nobody
/// said: `$XDG_RUNTIME_DIR/bus`.
fn connectSession() ?c_int {
    var decoded: [256]u8 = undefined;
    if (c.getenv("DBUS_SESSION_BUS_ADDRESS")) |list| {
        return connectUnix(dbus.parseAddress(std.mem.span(list), &decoded) orelse return null);
    }
    const runtime = std.mem.span(c.getenv("XDG_RUNTIME_DIR") orelse return null);
    const socket_path = std.fmt.bufPrint(&decoded, "{s}/bus", .{runtime}) catch return null;
    return connectUnix(.{ .path = socket_path });
}

fn connectUnix(address: dbus.Address) ?c_int {
    var where: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = @splat(0) };
    const name, const offset: usize = switch (address) {
        .path => |p| .{ p, 0 },
        // An abstract name starts with a zero byte, and the length given to
        // `connect` is where it ends - it has no terminator of its own.
        .abstract => |p| .{ p, 1 },
    };
    if (offset + name.len >= where.path.len) return null;
    @memcpy(where.path[offset..][0..name.len], name);
    const len = @offsetOf(posix.sockaddr.un, "path") + offset + name.len + @intFromBool(offset == 0);

    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM | close_on_exec, 0);
    if (fd < 0) return null;
    if (c.connect(fd, &where, @intCast(len)) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

// -------------------------------------------------------------------------
// zenity and kdialog
// -------------------------------------------------------------------------

/// The first of the two on `$PATH`, kdialog first on a KDE desktop.
fn findTool(buffer: *[512]u8) ?struct { portal.Tool, [:0]const u8 } {
    const desktop = std.mem.span(c.getenv("XDG_CURRENT_DESKTOP") orelse "");
    const order: [2]portal.Tool = if (std.mem.indexOf(u8, desktop, "KDE") != null) .{ .kdialog, .zenity } else .{ .zenity, .kdialog };
    for (order) |tool| {
        if (onPath(buffer, @tagName(tool))) |found| return .{ tool, found };
    }
    return null;
}

fn onPath(buffer: *[512]u8, program: []const u8) ?[:0]const u8 {
    var dirs = std.mem.splitScalar(u8, std.mem.span(c.getenv("PATH") orelse "/usr/bin:/bin"), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ dir, program }) catch continue;
        if (c.access(candidate, posix.X_OK) == 0) return candidate;
    }
    return null;
}

// -------------------------------------------------------------------------
// The dialog
// -------------------------------------------------------------------------

/// One dialog and the thread showing it. Made and destroyed on the program's
/// thread; in between that thread only reads `done` and writes to `cancel`,
/// and the dialog's thread writes `chosen` and then `done`.
pub const Dialog = struct {
    gpa: Allocator,
    /// The request, copied: the caller's strings are gone before the thread
    /// has finished with them.
    strings: std.heap.ArenaAllocator,
    request: backend.DialogRequest,
    parent: []const u8,
    bus: ?Bus,
    tool: ?portal.Tool,
    tool_path: [512]u8 = undefined,
    tool_path_len: usize = 0,
    /// A byte written here tells the thread to stop waiting.
    cancel_pipe: [2]c_int,
    /// The backend's own wake pipe, so that a program waiting for events
    /// hears that the answer is in.
    wake: c_int,

    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    chosen: std.ArrayListUnmanaged([]u8) = .empty,
    /// Set once the portal has taken the request: from then on its answer is
    /// the answer, even an empty one, and no tool is asked after it.
    answered: bool = false,

    /// Work out which dialog this desktop has, and start asking it.
    /// `error.Unavailable` where it has none: no portal, no zenity, no kdialog.
    pub fn start(gpa: Allocator, request: backend.DialogRequest, parent: []const u8, wake: c_int) Error!*Dialog {
        const self = try gpa.create(Dialog);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .strings = .init(gpa),
            .request = undefined,
            .parent = undefined,
            .bus = null,
            .tool = null,
            .cancel_pipe = .{ -1, -1 },
            .wake = wake,
        };
        errdefer self.strings.deinit();
        self.request = try copyRequest(self.strings.allocator(), request);
        self.parent = try self.strings.allocator().dupe(u8, parent);

        if (findTool(&self.tool_path)) |found| {
            self.tool = found[0];
            self.tool_path_len = found[1].len;
        }
        if (Bus.open()) |opened| {
            var bus = opened;
            if (bus.hasPortal()) self.bus = bus else bus.close();
        }
        errdefer if (self.bus) |*bus| bus.close();
        if (self.bus == null and self.tool == null) return error.Unavailable;

        if (c.pipe(&self.cancel_pipe) != 0) return error.Unavailable;
        errdefer {
            _ = c.close(self.cancel_pipe[0]);
            _ = c.close(self.cancel_pipe[1]);
        }
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch return error.Unavailable;
        return self;
    }

    pub fn finished(self: *const Dialog) bool {
        return self.done.load(.acquire);
    }

    /// Tell the dialog to go: the portal is asked to close it, and a tool is
    /// ended. Its answer, empty, still arrives.
    pub fn cancel(self: *Dialog) void {
        const byte = [_]u8{0};
        _ = c.write(self.cancel_pipe[1], &byte, 1);
    }

    /// The chosen paths, copied into `arena`. Only once `finished`.
    pub fn paths(self: *const Dialog, arena: Allocator) Allocator.Error![]const []const u8 {
        const out = try arena.alloc([]const u8, self.chosen.items.len);
        for (self.chosen.items, out) |path, *copy| copy.* = try arena.dupe(u8, path);
        return out;
    }

    /// Wait for the thread, and let everything go.
    pub fn destroy(self: *Dialog) void {
        self.thread.join();
        for (self.chosen.items) |path| heap.free(path);
        self.chosen.deinit(heap);
        _ = c.close(self.cancel_pipe[0]);
        _ = c.close(self.cancel_pipe[1]);
        self.strings.deinit();
        self.gpa.destroy(self);
    }

    fn run(self: *Dialog) void {
        defer {
            if (self.bus) |*bus| bus.close();
            self.done.store(true, .release);
            const byte = [_]u8{0};
            _ = c.write(self.wake, &byte, 1);
        }
        if (self.bus != null) {
            self.askPortal() catch |err| switch (err) {
                error.Cancelled => return,
                // A portal with no file chooser, or one too old to pick a
                // folder: a tool may still be there to ask.
                else => {},
            };
            if (self.chosen.items.len > 0 or self.answered) return;
        }
        if (self.tool) |tool| self.askTool(tool) catch {};
    }

    fn askPortal(self: *Dialog) Failure!void {
        const bus = &self.bus.?;
        const cancel_fd = self.cancel_pipe[0];

        var token_bytes: [48]u8 = undefined;
        const token = std.fmt.bufPrint(&token_bytes, "fluxion{d}_{d}", .{ c.getpid(), @intFromEnum(self.request.id) }) catch return error.Failed;
        var expected_bytes: [256]u8 = undefined;
        const expected = portal.requestPath(&expected_bytes, bus.name(), token) orelse return error.Failed;
        try self.listen(expected);

        if (self.request.folder and try self.version() < portal.folder_version) return error.Failed;

        var w: dbus.Writer = .{ .gpa = heap };
        defer w.deinit();
        try portal.writeOpenFile(&w, bus.nextSerial(), self.request, self.parent, token);
        const reply = bus.call(&w, cancel_fd, -1) catch |err| {
            if (err == error.Cancelled) self.close(expected);
            return err;
        };
        if (reply.kind != .method_return) return error.Failed;
        var body = reply.body;
        var handle_bytes: [256]u8 = undefined;
        const answered_on = try body.string();
        if (answered_on.len > handle_bytes.len) return error.Failed;
        @memcpy(handle_bytes[0..answered_on.len], answered_on);
        const handle = handle_bytes[0..answered_on.len];
        // A portal from before tokens made up its own path, and says so here.
        if (!std.mem.eql(u8, handle, expected)) try self.listen(handle);
        self.answered = true;

        while (true) {
            const message = bus.next(cancel_fd, -1) catch |err| {
                if (err == error.Cancelled) self.close(handle);
                return err;
            };
            if (message.kind != .signal or !std.mem.eql(u8, message.member, "Response") or !std.mem.eql(u8, message.path, handle)) continue;
            var response = message.body;
            _ = try portal.readResponse(&response, heap, &self.chosen);
            return;
        }
    }

    fn listen(self: *Dialog, request_path: []const u8) Failure!void {
        const bus = &self.bus.?;
        var rule_bytes: [512]u8 = undefined;
        const rule = portal.matchRule(&rule_bytes, request_path) orelse return error.Failed;
        var w: dbus.Writer = .{ .gpa = heap };
        defer w.deinit();
        try w.call(bus.nextSerial(), .{ .destination = portal.bus_name, .path = portal.bus_path, .interface = portal.bus_name, .member = "AddMatch", .signature = "s" });
        try w.string(rule);
        const reply = try bus.call(&w, self.cancel_pipe[0], -1);
        if (reply.kind != .method_return) return error.Failed;
    }

    /// `FileChooser`'s `version` property. Asking may start the portal, which
    /// is why it is asked here and not on the program's thread.
    fn version(self: *Dialog) Failure!u32 {
        const bus = &self.bus.?;
        var w: dbus.Writer = .{ .gpa = heap };
        defer w.deinit();
        try w.call(bus.nextSerial(), .{ .destination = portal.service, .path = portal.path, .interface = portal.properties, .member = "Get", .signature = "ss" });
        try w.string(portal.file_chooser);
        try w.string("version");
        const reply = try bus.call(&w, self.cancel_pipe[0], -1);
        if (reply.kind != .method_return) return error.Failed;
        var body = reply.body;
        if (!std.mem.eql(u8, try body.signature(), "u")) return error.Failed;
        return body.uint32();
    }

    /// `Request.Close`, which takes a portal's dialog off the screen. Nothing
    /// is waited for: the thread is on its way out.
    fn close(self: *Dialog, request_path: []const u8) void {
        const bus = &self.bus.?;
        var w: dbus.Writer = .{ .gpa = heap };
        defer w.deinit();
        w.call(bus.nextSerial(), .{ .destination = portal.service, .path = request_path, .interface = portal.request, .member = "Close", .no_reply = true }) catch return;
        _ = bus.sendAll(w.finish());
    }

    fn askTool(self: *Dialog, tool: portal.Tool) Failure!void {
        var arena_state: std.heap.ArenaAllocator = .init(heap);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const args = try portal.toolArgs(arena, tool, self.request);
        const argv = try arena.allocSentinel(?[*:0]const u8, args.len, null);
        for (args, argv) |arg, *slot| slot.* = (try arena.dupeZ(u8, arg)).ptr;
        const path_z = try arena.dupeZ(u8, self.tool_path[0..self.tool_path_len]);

        var output_pipe: [2]c_int = .{ -1, -1 };
        if (c.pipe(&output_pipe) != 0) return error.Failed;
        // Everything the child does before `execve` is on the short list of
        // calls that are safe after `fork` in a program with threads.
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(output_pipe[0]);
            _ = c.close(output_pipe[1]);
            return error.Failed;
        }
        if (pid == 0) {
            _ = c.dup2(output_pipe[1], 1);
            _ = c.close(output_pipe[0]);
            _ = c.close(output_pipe[1]);
            _ = c.execve(path_z, argv, c.environ);
            c._exit(127);
        }
        _ = c.close(output_pipe[1]);
        defer _ = c.close(output_pipe[0]);

        var output: std.ArrayListUnmanaged(u8) = .empty;
        var cancelled = false;
        var fds = [_]Pollfd{ .{ .fd = output_pipe[0], .events = pollin }, .{ .fd = self.cancel_pipe[0], .events = pollin } };
        var interrupted: u32 = 0;
        while (interrupted < 1000) {
            if (c.poll(&fds, fds.len, -1) < 0) {
                interrupted += 1;
                continue;
            }
            if (fds[1].revents != 0) {
                _ = c.kill(pid, sigterm);
                cancelled = true;
                break;
            }
            output.ensureUnusedCapacity(arena, 4096) catch {
                _ = c.kill(pid, sigterm);
                cancelled = true;
                break;
            };
            const room = output.unusedCapacitySlice();
            const got = c.read(output_pipe[0], room.ptr, room.len);
            if (got <= 0) break;
            output.items.len += @intCast(got);
        }

        var status: c_int = -1;
        for (0..1000) |_| {
            if (c.waitpid(pid, &status, 0) == pid) break;
        }
        // Zero is "exited, and said yes"; a cancel is 1 from either tool.
        if (cancelled or status != 0) return;
        var lines = portal.toolPaths(output.items);
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const path = try heap.dupe(u8, line);
            errdefer heap.free(path);
            try self.chosen.append(heap, path);
        }
    }
};

fn copyRequest(arena: Allocator, request: backend.DialogRequest) Allocator.Error!backend.DialogRequest {
    var copy = request;
    copy.owner = null;
    if (request.title) |title| copy.title = try arena.dupe(u8, title);
    if (request.initial_folder) |folder| copy.initial_folder = try arena.dupe(u8, folder);
    const filters = try arena.alloc(dialog.Filter, request.filters.len);
    for (request.filters, filters) |filter, *out| {
        const extensions = try arena.alloc([]const u8, filter.extensions.len);
        for (filter.extensions, extensions) |extension, *each| each.* = try arena.dupe(u8, extension);
        out.* = .{ .name = try arena.dupe(u8, filter.name), .extensions = extensions };
    }
    copy.filters = filters;
    return copy;
}
