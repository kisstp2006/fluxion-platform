// SPDX-License-Identifier: BSL-1.0

//! The system's open dialog, `IFileOpenDialog`, on a thread of its own. It is
//! modal, and shown from the program's thread it would hold the loop - the
//! drawing and every event - until it closed.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const dyn = @import("fluxion_dyn");

const backend = @import("../backend.zig");
const dialog = @import("../dialog.zig");
const event = @import("../event.zig");
const platform = @import("../platform.zig");

const Error = platform.Error;

const HRESULT = i32;

const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const clsid_file_open_dialog: Guid = .{ .data1 = 0xDC1C5A9C, .data2 = 0xE88A, .data3 = 0x4DDE, .data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 } };
const iid_file_open_dialog: Guid = .{ .data1 = 0xD57C7288, .data2 = 0xD4AD, .data3 = 0x4768, .data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 } };
const iid_shell_item: Guid = .{ .data1 = 0x43826D1E, .data2 = 0xE718, .data3 = 0x42EE, .data4 = .{ 0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE } };

const clsctx_inproc_server: u32 = 0x1;

const fos_nochangedir: u32 = 0x8;
const fos_pickfolders: u32 = 0x20;
const fos_forcefilesystem: u32 = 0x40;
const fos_allowmultiselect: u32 = 0x200;
const fos_pathmustexist: u32 = 0x800;
const fos_filemustexist: u32 = 0x1000;

const sigdn_filesyspath: u32 = 0x80058000;

/// `HRESULT_FROM_WIN32(ERROR_CANCELLED)`, which is `Show` saying the user
/// closed the dialog without choosing.
const cancelled: HRESULT = @bitCast(@as(u32, 0x800704C7));

/// `COMDLG_FILTERSPEC`.
const FilterSpec = extern struct {
    name: [*:0]const u16,
    spec: [*:0]const u16,
};

// A COM object points at a table of its methods in header order, a derived
// interface's table starting with its parent's. A method never called still
// keeps its slot, or every later one is read from the wrong place.

const Unused = *const anyopaque;

fn Unknown(comptime Self: type) type {
    return extern struct {
        query_interface: Unused,
        add_ref: Unused,
        release: *const fn (*Self) callconv(.winapi) u32,
    };
}

const FileOpenDialog = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(FileOpenDialog),
        // IModalWindow
        show: *const fn (*FileOpenDialog, ?*anyopaque) callconv(.winapi) HRESULT,
        // IFileDialog
        set_file_types: *const fn (*FileOpenDialog, u32, [*]const FilterSpec) callconv(.winapi) HRESULT,
        set_file_type_index: Unused,
        get_file_type_index: Unused,
        advise: Unused,
        unadvise: Unused,
        set_options: *const fn (*FileOpenDialog, u32) callconv(.winapi) HRESULT,
        get_options: *const fn (*FileOpenDialog, *u32) callconv(.winapi) HRESULT,
        set_default_folder: Unused,
        set_folder: *const fn (*FileOpenDialog, *ShellItem) callconv(.winapi) HRESULT,
        get_folder: Unused,
        get_current_selection: Unused,
        set_file_name: Unused,
        get_file_name: Unused,
        set_title: *const fn (*FileOpenDialog, [*:0]const u16) callconv(.winapi) HRESULT,
        set_ok_button_label: Unused,
        set_file_name_label: Unused,
        get_result: *const fn (*FileOpenDialog, *?*ShellItem) callconv(.winapi) HRESULT,
        add_place: Unused,
        set_default_extension: Unused,
        close: Unused,
        set_client_guid: Unused,
        clear_client_data: Unused,
        set_filter: Unused,
        // IFileOpenDialog
        get_results: *const fn (*FileOpenDialog, *?*ShellItemArray) callconv(.winapi) HRESULT,
        get_selected_items: Unused,
    },
};

const ShellItemArray = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(ShellItemArray),
        bind_to_handler: Unused,
        get_property_store: Unused,
        get_property_description_list: Unused,
        get_attributes: Unused,
        get_count: *const fn (*ShellItemArray, *u32) callconv(.winapi) HRESULT,
        get_item_at: *const fn (*ShellItemArray, u32, *?*ShellItem) callconv(.winapi) HRESULT,
        enum_items: Unused,
    },
};

const ShellItem = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(ShellItem),
        bind_to_handler: Unused,
        get_parent: Unused,
        get_display_name: *const fn (*ShellItem, u32, *?[*:0]u16) callconv(.winapi) HRESULT,
        get_attributes: Unused,
        compare: Unused,
    },
};

const Ole32 = struct {
    OleInitialize: *const fn (?*anyopaque) callconv(.winapi) HRESULT,
    OleUninitialize: *const fn () callconv(.winapi) void,
    CoCreateInstance: *const fn (*const Guid, ?*anyopaque, u32, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
    CoTaskMemAlloc: *const fn (usize) callconv(.winapi) ?*anyopaque,
    CoTaskMemFree: *const fn (?*anyopaque) callconv(.winapi) void,
};

const Shell32 = struct {
    SHCreateItemFromParsingName: *const fn ([*:0]const u16, ?*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
};

/// `ole32.dll` and `shell32.dll`, opened for the first dialog rather than by
/// every program that never shows one.
pub const Shell = struct {
    ole32: dyn.Library,
    shell32: dyn.Library,
    calls: Calls,

    pub const Calls = struct {
        ole: Ole32,
        shell: Shell32,
    };

    pub fn open() Error!Shell {
        var ole32 = dyn.openSystem("ole32.dll") catch return error.Unavailable;
        errdefer ole32.close();
        var shell32 = dyn.openSystem("shell32.dll") catch return error.Unavailable;
        errdefer shell32.close();
        const calls: Calls = .{
            .ole = ole32.bind(Ole32) catch return error.Unavailable,
            .shell = shell32.bind(Shell32) catch return error.Unavailable,
        };
        return .{ .ole32 = ole32, .shell32 = shell32, .calls = calls };
    }

    pub fn close(self: *Shell) void {
        self.shell32.close();
        self.ole32.close();
    }
};

/// One dialog: what it was asked for, the thread that shows it, and what came
/// back. Made and destroyed on the program's thread; between `spawn` and the
/// thread's end, the dialog's thread writes `names` and `count` and the
/// program's thread touches nothing but `abandon`.
pub const Dialog = struct {
    gpa: Allocator,
    calls: Shell.Calls,
    /// The request as UTF-16, made before the thread starts.
    strings: std.heap.ArenaAllocator,
    owner: ?*anyopaque,
    window: event.WindowId,
    id: event.DialogId,
    options: u32,
    multiple: bool,
    title: ?[*:0]const u16 = null,
    initial_folder: ?[*:0]const u16 = null,
    filters: []const FilterSpec = &.{},

    thread: std.Thread = undefined,
    abandoned: std.atomic.Value(bool) = .init(false),

    /// The shell's own strings, in COM's task memory: the dialog's thread
    /// allocates nothing itself, since the program's allocator need not be
    /// safe to share.
    names: ?[*][*:0]u16 = null,
    count: u32 = 0,

    pub fn create(gpa: Allocator, calls: Shell.Calls, owner: ?*anyopaque, request: backend.DialogRequest) Error!*Dialog {
        const self = try gpa.create(Dialog);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .calls = calls,
            .strings = .init(gpa),
            .owner = owner,
            .window = request.window,
            .id = request.id,
            .options = optionsFor(request),
            .multiple = request.multiple,
        };
        errdefer self.strings.deinit();

        const arena = self.strings.allocator();
        if (request.title) |title| self.title = try wide(arena, title);
        if (request.initial_folder) |folder| self.initial_folder = try parsingName(arena, folder);
        self.filters = try filterSpecs(arena, request.filters);
        return self;
    }

    /// The shell parses only backslashes, and every other Windows call takes either.
    fn parsingName(arena: Allocator, folder: []const u8) Error![:0]u16 {
        const path = std.unicode.wtf8ToWtf16LeAllocZ(arena, folder) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidWtf8 => error.Unavailable,
        };
        std.mem.replaceScalar(u16, path, '/', '\\');
        return path;
    }

    pub fn spawn(self: *Dialog) Error!void {
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unavailable,
        };
    }

    /// Have the thread give up before it shows the dialog. Once it is shown,
    /// only closing its window will do, and that is the backend's to do.
    pub fn abandon(self: *Dialog) void {
        self.abandoned.store(true, .release);
    }

    /// The paths chosen, as WTF-8 - which is what Zig's file functions take on
    /// Windows - and allocated in `arena`. Only once the thread has ended.
    pub fn paths(self: *const Dialog, arena: Allocator) Allocator.Error![]const []const u8 {
        const names = self.names orelse return &.{};
        const out = try arena.alloc([]const u8, self.count);
        for (names[0..self.count], out) |name, *path| {
            path.* = try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(name));
        }
        return out;
    }

    /// Only once the thread has been joined, or was never spawned.
    pub fn destroy(self: *Dialog) void {
        if (self.names) |names| {
            for (names[0..self.count]) |name| self.calls.ole.CoTaskMemFree(@ptrCast(name));
            self.calls.ole.CoTaskMemFree(@ptrCast(names));
        }
        self.strings.deinit();
        self.gpa.destroy(self);
    }

    fn run(self: *Dialog) void {
        // OLE rather than bare COM: the dialog's own view drags files about
        // and uses the clipboard, and both want it on the thread showing it.
        if (self.calls.ole.OleInitialize(null) < 0) return;
        defer self.calls.ole.OleUninitialize();
        self.ask() catch {};
    }

    fn ask(self: *Dialog) error{Failed}!void {
        var made: ?*anyopaque = null;
        try check(self.calls.ole.CoCreateInstance(&clsid_file_open_dialog, null, clsctx_inproc_server, &iid_file_open_dialog, &made));
        const box: *FileOpenDialog = @ptrCast(@alignCast(made orelse return error.Failed));
        defer _ = box.vtable.unknown.release(box);

        var options: u32 = 0;
        try check(box.vtable.get_options(box, &options));
        try check(box.vtable.set_options(box, options | self.options));
        if (self.filters.len > 0) try check(box.vtable.set_file_types(box, @intCast(self.filters.len), self.filters.ptr));
        if (self.title) |title| try check(box.vtable.set_title(box, title));
        if (self.initial_folder) |folder| self.startIn(box, folder);

        if (self.abandoned.load(.acquire)) return;
        const shown = box.vtable.show(box, self.owner);
        if (shown == cancelled) return;
        try check(shown);

        if (self.multiple) try self.keepAll(box) else try self.keepOne(box);
    }

    fn startIn(self: *Dialog, box: *FileOpenDialog, folder: [*:0]const u16) void {
        var made: ?*anyopaque = null;
        if (self.calls.shell.SHCreateItemFromParsingName(folder, null, &iid_shell_item, &made) < 0) return;
        const item: *ShellItem = @ptrCast(@alignCast(made orelse return));
        defer _ = item.vtable.unknown.release(item);
        _ = box.vtable.set_folder(box, item);
    }

    fn keepOne(self: *Dialog, box: *FileOpenDialog) error{Failed}!void {
        var result: ?*ShellItem = null;
        try check(box.vtable.get_result(box, &result));
        const item = result orelse return error.Failed;
        defer _ = item.vtable.unknown.release(item);
        try self.reserve(1);
        self.keep(item);
    }

    fn keepAll(self: *Dialog, box: *FileOpenDialog) error{Failed}!void {
        var results: ?*ShellItemArray = null;
        try check(box.vtable.get_results(box, &results));
        const items = results orelse return error.Failed;
        defer _ = items.vtable.unknown.release(items);

        var count: u32 = 0;
        try check(items.vtable.get_count(items, &count));
        try self.reserve(count);
        for (0..count) |index| {
            var found: ?*ShellItem = null;
            if (items.vtable.get_item_at(items, @intCast(index), &found) < 0) continue;
            const item = found orelse continue;
            defer _ = item.vtable.unknown.release(item);
            self.keep(item);
        }
    }

    fn reserve(self: *Dialog, capacity: u32) error{Failed}!void {
        if (capacity == 0) return;
        const memory = self.calls.ole.CoTaskMemAlloc(@as(usize, capacity) * @sizeOf([*:0]u16)) orelse return error.Failed;
        self.names = @ptrCast(@alignCast(memory));
    }

    fn keep(self: *Dialog, item: *ShellItem) void {
        var name: ?[*:0]u16 = null;
        if (item.vtable.get_display_name(item, sigdn_filesyspath, &name) < 0) return;
        self.names.?[self.count] = name orelse return;
        self.count += 1;
    }
};

fn check(result: HRESULT) error{Failed}!void {
    if (result < 0) return error.Failed;
}

fn optionsFor(request: backend.DialogRequest) u32 {
    var options = fos_forcefilesystem | fos_nochangedir | fos_pathmustexist;
    options |= if (request.folder) fos_pickfolders else fos_filemustexist;
    if (request.multiple) options |= fos_allowmultiselect;
    return options;
}

fn wide(arena: Allocator, text: []const u8) Error![*:0]const u16 {
    const units = std.unicode.utf8ToUtf16LeAllocZ(arena, text) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.Unavailable,
    };
    return units.ptr;
}

fn filterSpecs(arena: Allocator, filters: []const dialog.Filter) Error![]const FilterSpec {
    const specs = try arena.alloc(FilterSpec, filters.len);
    for (filters, specs) |filter, *spec| spec.* = .{
        .name = try wide(arena, filter.name),
        .spec = try wide(arena, try pattern(arena, filter.extensions)),
    };
    return specs;
}

/// `*.png;*.jpg`, which is how Windows writes a filter.
pub fn pattern(arena: Allocator, extensions: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (extensions, 0..) |extension, index| {
        if (index > 0) try out.append(arena, ';');
        const name = dialog.bare(extension);
        try out.appendSlice(arena, "*.");
        try out.appendSlice(arena, if (std.mem.eql(u8, name, "*")) "*" else name);
    }
    return out.items;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn slot(comptime Interface: type, comptime method: []const u8) usize {
    const Table = @typeInfo(@FieldType(Interface, "vtable")).pointer.child;
    return @offsetOf(Table, method) / @sizeOf(usize);
}

fn slots(comptime Interface: type) usize {
    return @sizeOf(@typeInfo(@FieldType(Interface, "vtable")).pointer.child) / @sizeOf(usize);
}

test "every method is at the slot the header gives it" {
    try testing.expectEqual(29, slots(FileOpenDialog));
    try testing.expectEqual(2, @offsetOf(Unknown(FileOpenDialog), "release") / @sizeOf(usize));
    try testing.expectEqual(3, slot(FileOpenDialog, "show"));
    try testing.expectEqual(4, slot(FileOpenDialog, "set_file_types"));
    try testing.expectEqual(9, slot(FileOpenDialog, "set_options"));
    try testing.expectEqual(10, slot(FileOpenDialog, "get_options"));
    try testing.expectEqual(12, slot(FileOpenDialog, "set_folder"));
    try testing.expectEqual(17, slot(FileOpenDialog, "set_title"));
    try testing.expectEqual(20, slot(FileOpenDialog, "get_result"));
    try testing.expectEqual(27, slot(FileOpenDialog, "get_results"));

    try testing.expectEqual(10, slots(ShellItemArray));
    try testing.expectEqual(7, slot(ShellItemArray, "get_count"));
    try testing.expectEqual(8, slot(ShellItemArray, "get_item_at"));

    try testing.expectEqual(8, slots(ShellItem));
    try testing.expectEqual(5, slot(ShellItem, "get_display_name"));
}

test "a filter is written the way Windows writes one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("*.png;*.jpg;*.tar.gz;*.*", try pattern(arena.allocator(), &.{ "png", ".jpg", "tar.gz", "*" }));
}

test "a folder to start in may be written with either slash" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const path = try Dialog.parsingName(arena.allocator(), "C:/Users/me/Documents\\Projects");
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("C:\\Users\\me\\Documents\\Projects"), path);
    try testing.expectError(error.Unavailable, Dialog.parsingName(arena.allocator(), "\xFF"));
}

test "the options ask for files that exist, or for folders, and never move the working directory" {
    const request: backend.DialogRequest = .{ .folder = false, .multiple = false, .title = null, .filters = &.{}, .initial_folder = null };
    const one = optionsFor(request);
    try testing.expect(one & fos_filemustexist != 0);
    try testing.expect(one & fos_nochangedir != 0);
    try testing.expect(one & (fos_pickfolders | fos_allowmultiselect) == 0);

    var many = request;
    many.multiple = true;
    try testing.expect(optionsFor(many) & fos_allowmultiselect != 0);

    var folder = request;
    folder.folder = true;
    try testing.expect(optionsFor(folder) & fos_pickfolders != 0);
    try testing.expect(optionsFor(folder) & fos_filemustexist == 0);
}

test "a dialog abandoned before it is shown ends with nothing chosen" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var shell = Shell.open() catch return error.SkipZigTest;
    defer shell.close();

    const job = try Dialog.create(testing.allocator, shell.calls, null, .{
        .id = @enumFromInt(4),
        .window = @enumFromInt(2),
        .folder = false,
        .multiple = true,
        .title = "Pick",
        .filters = &.{.{ .name = "Images", .extensions = &.{ "png", "jpg" } }},
        .initial_folder = "C:\\",
    });
    job.abandon();
    try job.spawn();
    job.thread.join();
    defer job.destroy();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try job.paths(arena.allocator())).len);
}
