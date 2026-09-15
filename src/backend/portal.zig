// SPDX-License-Identifier: BSL-1.0

//! What a Linux desktop is asked for a file, and what it answers: the desktop
//! portal's `OpenFile` and `Response`, and the command lines of zenity and
//! kdialog for a desktop that has no portal. Bytes and strings only - the
//! talking is `linux_dialog`'s - so all of it is checked on any host.
//!
//! The portal answers later, as a signal on a request object whose path the
//! caller can work out before it asks: listening first is what keeps a fast
//! answer from arriving before anyone is listening for it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const backend = @import("../backend.zig");
const dbus = @import("dbus.zig");
const dialog = @import("../dialog.zig");

pub const bus_name = "org.freedesktop.DBus";
pub const bus_path = "/org/freedesktop/DBus";
pub const service = "org.freedesktop.portal.Desktop";
pub const path = "/org/freedesktop/portal/desktop";
pub const file_chooser = "org.freedesktop.portal.FileChooser";
pub const request = "org.freedesktop.portal.Request";
pub const properties = "org.freedesktop.DBus.Properties";

/// The version `directory` arrived in. An older portal ignores it, and would
/// hand back a file for a folder.
pub const folder_version: u32 = 3;

/// `/org/freedesktop/portal/desktop/request/SENDER/TOKEN`, with the sender's
/// unique name stripped of its colon and its dots made underscores.
pub fn requestPath(buffer: []u8, sender: []const u8, token: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    w.writeAll(path ++ "/request/") catch return null;
    for (sender) |byte| switch (byte) {
        ':' => {},
        '.' => w.writeByte('_') catch return null,
        else => w.writeByte(byte) catch return null,
    };
    w.print("/{s}", .{token}) catch return null;
    return w.buffered();
}

pub fn matchRule(buffer: []u8, request_path: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "type='signal',sender='" ++ service ++ "',interface='" ++ request ++ "',member='Response',path='{s}'",
        .{request_path},
    ) catch null;
}

/// `OpenFile(parent_window, title, options)`.
pub fn writeOpenFile(w: *dbus.Writer, serial: u32, wanted: backend.DialogRequest, parent: []const u8, token: []const u8) Allocator.Error!void {
    try w.call(serial, .{
        .destination = service,
        .path = path,
        .interface = file_chooser,
        .member = "OpenFile",
        .signature = "ssa{sv}",
    });
    try w.string(parent);
    try w.string(wanted.title orelse if (wanted.folder) "Open Folder" else "Open File");

    const options = try w.beginArray(8);
    try option(w, "handle_token", "s");
    try w.string(token);
    try option(w, "modal", "b");
    try w.boolean(true);
    try option(w, "multiple", "b");
    try w.boolean(wanted.multiple);
    if (wanted.folder) {
        try option(w, "directory", "b");
        try w.boolean(true);
    }
    if (wanted.filters.len > 0) {
        try option(w, "filters", "a(sa(us))");
        const filters = try w.beginArray(8);
        for (wanted.filters) |filter| {
            try w.beginStruct();
            try w.string(filter.name);
            const patterns = try w.beginArray(8);
            for (filter.extensions) |extension| {
                try w.beginStruct();
                try w.uint32(0);
                var glob: [256]u8 = undefined;
                try w.string(caselessGlob(&glob, dialog.bare(extension)));
            }
            w.endArray(patterns);
        }
        w.endArray(filters);
    }
    if (wanted.initial_folder) |folder| {
        try option(w, "current_folder", "ay");
        try w.bytesWithZero(folder);
    }
    w.endArray(options);
}

fn option(w: *dbus.Writer, key: []const u8, kind: []const u8) Allocator.Error!void {
    try w.beginStruct();
    try w.string(key);
    try w.signature(kind);
}

/// `*.[pP][nN][gG]`: a portal's patterns are globs, and a glob is case
/// sensitive where a file dialog's filter never is anywhere else.
pub fn caselessGlob(buffer: []u8, extension: []const u8) []const u8 {
    if (std.mem.eql(u8, extension, "*")) return "*";
    var w: std.Io.Writer = .fixed(buffer);
    w.writeAll("*.") catch return "*";
    for (extension) |byte| {
        if (std.ascii.isAlphabetic(byte)) {
            w.print("[{c}{c}]", .{ std.ascii.toLower(byte), std.ascii.toUpper(byte) }) catch return "*";
        } else w.writeByte(byte) catch return "*";
    }
    return w.buffered();
}

/// `Response(response, results)`: 0 is chosen, 1 cancelled, 2 anything else.
/// The chosen `file://` URIs are appended to `paths` as paths.
pub fn readResponse(body: *dbus.Reader, gpa: Allocator, paths: *std.ArrayListUnmanaged([]u8)) (dbus.Error || Allocator.Error)!u32 {
    const code = try body.uint32();
    const end = try body.beginArray("{sv}");
    while (body.pos < end) {
        try body.alignTo(8);
        const key = try body.string();
        const kind = try body.signature();
        if (!std.mem.eql(u8, key, "uris") or !std.mem.eql(u8, kind, "as")) {
            try body.skip(kind);
            continue;
        }
        const uris_end = try body.beginArray("s");
        while (body.pos < uris_end) {
            const uri = try body.string();
            const local = try pathFromUri(gpa, uri) orelse continue;
            errdefer gpa.free(local);
            try paths.append(gpa, local);
        }
    }
    return code;
}

/// The path a `file://` URI names, `%xx` decoded, or null for any other kind.
pub fn pathFromUri(gpa: Allocator, uri: []const u8) Allocator.Error!?[]u8 {
    const scheme = "file://";
    if (!std.ascii.startsWithIgnoreCase(uri, scheme)) return null;
    var rest = uri[scheme.len..];
    // `file://host/path`: only the local host means this machine.
    if (!std.mem.startsWith(u8, rest, "/")) {
        if (!std.ascii.startsWithIgnoreCase(rest, "localhost/")) return null;
        rest = rest["localhost".len..];
    }

    const out = try gpa.alloc(u8, rest.len);
    errdefer gpa.free(out);
    var len: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (len += 1) {
        if (rest[i] == '%' and i + 3 <= rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |value| {
                out[len] = value;
                i += 3;
                continue;
            } else |_| {}
        }
        out[len] = rest[i];
        i += 1;
    }
    return try gpa.realloc(out, len);
}

/// `file://` and an absolute path, with every byte a URI would not carry as
/// it is written as `%XX` - the reverse of `pathFromUri`.
pub fn fileUri(gpa: Allocator, absolute: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    for (absolute) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-_.~/", byte) != null) {
            try out.append(gpa, byte);
        } else try out.print(gpa, "%{X:0>2}", .{byte});
    }
    return out.toOwnedSlice(gpa);
}

pub const open_uri = "org.freedesktop.portal.OpenURI";
pub const file_manager = "org.freedesktop.FileManager1";
pub const file_manager_path = "/org/freedesktop/FileManager1";

/// `OpenURI(parent_window, uri, options)`: a web address, or anything but a
/// `file://`, which the portal only takes as an open file.
pub fn writeOpenUri(w: *dbus.Writer, serial: u32, uri: []const u8) Allocator.Error!void {
    try w.call(serial, .{ .destination = service, .path = path, .interface = open_uri, .member = "OpenURI", .signature = "ssa{sv}" });
    try w.string("");
    try w.string(uri);
    const options = try w.beginArray(8);
    w.endArray(options);
}

/// `ShowItems(uris, startup_id)`: the file manager opens the folder with them selected.
pub fn writeShowItems(w: *dbus.Writer, serial: u32, uri: []const u8) Allocator.Error!void {
    try w.call(serial, .{ .destination = file_manager, .path = file_manager_path, .interface = file_manager, .member = "ShowItems", .signature = "ass" });
    const uris = try w.beginArray(4);
    try w.string(uri);
    w.endArray(uris);
    try w.string("");
}

// -------------------------------------------------------------------------
// zenity and kdialog, for a desktop with no portal
// -------------------------------------------------------------------------

pub const Tool = enum { zenity, kdialog };

/// Every argument, the program's name first. Allocated in `arena`.
pub fn toolArgs(arena: Allocator, tool: Tool, wanted: backend.DialogRequest) Allocator.Error![]const []const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    switch (tool) {
        .zenity => {
            try args.appendSlice(arena, &.{ "zenity", "--file-selection", "--separator=\n" });
            if (wanted.folder) try args.append(arena, "--directory");
            if (wanted.multiple) try args.append(arena, "--multiple");
            if (wanted.title) |title| try args.append(arena, try std.fmt.allocPrint(arena, "--title={s}", .{title}));
            if (wanted.initial_folder) |folder| {
                const slash = if (std.mem.endsWith(u8, folder, "/")) "" else "/";
                try args.append(arena, try std.fmt.allocPrint(arena, "--filename={s}{s}", .{ folder, slash }));
            }
            for (wanted.filters) |filter| {
                var line: std.ArrayListUnmanaged(u8) = .empty;
                try line.print(arena, "--file-filter={s} |", .{filter.name});
                for (filter.extensions) |extension| {
                    var glob: [256]u8 = undefined;
                    try line.print(arena, " {s}", .{caselessGlob(&glob, dialog.bare(extension))});
                }
                try args.append(arena, line.items);
            }
        },
        .kdialog => {
            try args.append(arena, "kdialog");
            if (wanted.title) |title| try args.appendSlice(arena, &.{ "--title", title });
            const start = wanted.initial_folder orelse ".";
            if (wanted.folder) {
                try args.appendSlice(arena, &.{ "--getexistingdirectory", start });
            } else {
                try args.appendSlice(arena, &.{ "--getopenfilename", start });
                var filter: std.ArrayListUnmanaged(u8) = .empty;
                for (wanted.filters, 0..) |entry, index| {
                    if (index > 0) try filter.append(arena, '\n');
                    for (entry.extensions, 0..) |extension, at| {
                        if (at > 0) try filter.append(arena, ' ');
                        var glob: [256]u8 = undefined;
                        try filter.appendSlice(arena, caselessGlob(&glob, dialog.bare(extension)));
                    }
                    try filter.print(arena, "|{s}", .{entry.name});
                }
                if (filter.items.len > 0) try args.append(arena, filter.items);
                if (wanted.multiple) try args.appendSlice(arena, &.{ "--multiple", "--separate-output" });
            }
        },
    }
    return args.items;
}

/// One path per line, as both print them. Splitting on anything else would
/// cut a name with a space in it.
pub fn toolPaths(output: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, std.mem.trimEnd(u8, output, "\n"), '\n');
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn fileRequest() backend.DialogRequest {
    return .{
        .folder = false,
        .multiple = true,
        .title = "Pick",
        .filters = &.{
            .{ .name = "Images", .extensions = &.{ "png", ".JPG" } },
            .{ .name = "All", .extensions = &.{"*"} },
        },
        .initial_folder = "/home/me",
    };
}

test "the request path is known before the request is made" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_42/fluxion7",
        requestPath(&buffer, ":1.42", "fluxion7").?,
    );
    var small: [8]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), requestPath(&small, ":1.42", "t"));
}

test "a pattern matches an extension in any case" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("*.[pP][nN][gG]", caselessGlob(&buffer, "png"));
    try testing.expectEqualStrings("*.[tT][aA][rR].[gG][zZ]", caselessGlob(&buffer, "tar.gz"));
    try testing.expectEqualStrings("*.7[zZ]", caselessGlob(&buffer, "7z"));
    try testing.expectEqualStrings("*", caselessGlob(&buffer, "*"));
}

test "OpenFile carries the window, the title and every option" {
    var w: dbus.Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    try writeOpenFile(&w, 5, fileRequest(), "x11:1a00003", "fluxion1");
    const header = try dbus.parse(w.finish());
    try testing.expectEqualStrings(path, header.path);
    try testing.expectEqualStrings("OpenFile", header.member);
    try testing.expectEqualStrings(file_chooser, header.interface);
    try testing.expectEqualStrings("ssa{sv}", header.signature);

    var body = header.body;
    try testing.expectEqualStrings("x11:1a00003", try body.string());
    try testing.expectEqualStrings("Pick", try body.string());
    const end = try body.beginArray("{sv}");
    var keys: [8][]const u8 = undefined;
    var count: usize = 0;
    while (body.pos < end) : (count += 1) {
        try body.alignTo(8);
        keys[count] = try body.string();
        const kind = try body.signature();
        if (std.mem.eql(u8, keys[count], "filters")) {
            const filters_end = try body.beginArray("(sa(us))");
            try body.alignTo(8);
            try testing.expectEqualStrings("Images", try body.string());
            const patterns_end = try body.beginArray("(us)");
            try body.alignTo(8);
            try testing.expectEqual(@as(u32, 0), try body.uint32());
            try testing.expectEqualStrings("*.[pP][nN][gG]", try body.string());
            body.pos = patterns_end;
            body.pos = filters_end;
        } else if (std.mem.eql(u8, keys[count], "current_folder")) {
            const folder_end = try body.beginArray("y");
            try testing.expectEqualStrings("/home/me\x00", body.bytes[body.pos..folder_end]);
            body.pos = folder_end;
        } else try body.skip(kind);
    }
    try testing.expectEqual(@as(usize, 5), count);
    try testing.expectEqualStrings("handle_token", keys[0]);
    try testing.expectEqualStrings("multiple", keys[2]);
    try testing.expectEqualStrings("filters", keys[3]);
    try testing.expectEqualStrings("current_folder", keys[4]);
}

test "a folder is asked for as a directory, with the portal's own title when none is given" {
    var w: dbus.Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    try writeOpenFile(&w, 6, .{ .folder = true, .multiple = false, .title = null, .filters = &.{}, .initial_folder = null }, "", "t");
    var body = (try dbus.parse(w.finish())).body;
    try testing.expectEqualStrings("", try body.string());
    try testing.expectEqualStrings("Open Folder", try body.string());
    const end = try body.beginArray("{sv}");
    var saw_directory = false;
    while (body.pos < end) {
        try body.alignTo(8);
        const key = try body.string();
        const kind = try body.signature();
        if (std.mem.eql(u8, key, "directory")) saw_directory = try body.boolean() else try body.skip(kind);
    }
    try testing.expect(saw_directory);
}

test "a response is its code and its file URIs as paths" {
    var w: dbus.Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    try w.call(9, .{ .path = "/r", .member = "Response", .signature = "ua{sv}" });
    try w.uint32(0);
    const results = try w.beginArray(8);
    try option(&w, "choices", "a(ss)");
    const choices = try w.beginArray(8);
    w.endArray(choices);
    try option(&w, "uris", "as");
    const uris = try w.beginArray(4);
    try w.string("file:///home/me/a%20b.png");
    try w.string("https://example.com/c.png");
    try w.string("file://localhost/tmp/d.png");
    w.endArray(uris);
    w.endArray(results);

    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (paths.items) |p| testing.allocator.free(p);
        paths.deinit(testing.allocator);
    }
    var body = (try dbus.parse(w.finish())).body;
    try testing.expectEqual(@as(u32, 0), try readResponse(&body, testing.allocator, &paths));
    try testing.expectEqual(@as(usize, 2), paths.items.len);
    try testing.expectEqualStrings("/home/me/a b.png", paths.items[0]);
    try testing.expectEqualStrings("/tmp/d.png", paths.items[1]);
}

test "a URI that is not a local file names no path" {
    try testing.expectEqual(@as(?[]u8, null), try pathFromUri(testing.allocator, "file://server/share/x"));
    try testing.expectEqual(@as(?[]u8, null), try pathFromUri(testing.allocator, "smb://server/x"));
    const odd = (try pathFromUri(testing.allocator, "FILE:///100%25/%zz")).?;
    defer testing.allocator.free(odd);
    try testing.expectEqualStrings("/100%/%zz", odd);
}

test "a path becomes a file URI and comes back the same" {
    const uri = try fileUri(testing.allocator, "/home/tamás/My Docs/a#b%.png");
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("file:///home/tam%C3%A1s/My%20Docs/a%23b%25.png", uri);
    const back = (try pathFromUri(testing.allocator, uri)).?;
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("/home/tamás/My Docs/a#b%.png", back);
}

test "the file manager is asked to show one item, and the portal to open one address" {
    var w: dbus.Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    try writeShowItems(&w, 3, "file:///home/me/level.json");
    const shown = try dbus.parse(w.finish());
    try testing.expectEqualStrings(file_manager, shown.interface);
    try testing.expectEqualStrings("ShowItems", shown.member);
    try testing.expectEqualStrings("ass", shown.signature);
    var body = shown.body;
    const end = try body.beginArray("s");
    try testing.expectEqualStrings("file:///home/me/level.json", try body.string());
    try testing.expectEqual(end, body.pos);
    try testing.expectEqualStrings("", try body.string());

    try writeOpenUri(&w, 4, "https://ziglang.org/");
    const opened = try dbus.parse(w.finish());
    try testing.expectEqualStrings(open_uri, opened.interface);
    try testing.expectEqualStrings("ssa{sv}", opened.signature);
    body = opened.body;
    try testing.expectEqualStrings("", try body.string());
    try testing.expectEqualStrings("https://ziglang.org/", try body.string());
}

test "zenity and kdialog are told the same thing in their own words" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zenity = try toolArgs(a, .zenity, fileRequest());
    try testing.expectEqualStrings("zenity", zenity[0]);
    try testing.expectEqualStrings("--multiple", zenity[3]);
    try testing.expectEqualStrings("--title=Pick", zenity[4]);
    try testing.expectEqualStrings("--filename=/home/me/", zenity[5]);
    try testing.expectEqualStrings("--file-filter=Images | *.[pP][nN][gG] *.[jJ][pP][gG]", zenity[6]);
    try testing.expectEqualStrings("--file-filter=All | *", zenity[7]);

    const kdialog = try toolArgs(a, .kdialog, fileRequest());
    try testing.expectEqualStrings("kdialog", kdialog[0]);
    try testing.expectEqualStrings("--getopenfilename", kdialog[3]);
    try testing.expectEqualStrings("/home/me", kdialog[4]);
    try testing.expectEqualStrings("*.[pP][nN][gG] *.[jJ][pP][gG]|Images\n*|All", kdialog[5]);
    try testing.expectEqualStrings("--separate-output", kdialog[7]);

    const folder = try toolArgs(a, .kdialog, .{ .folder = true, .multiple = false, .title = null, .filters = &.{}, .initial_folder = null });
    try testing.expectEqualStrings("--getexistingdirectory", folder[1]);
    try testing.expectEqualStrings(".", folder[2]);
}

test "a tool's answer is a path a line" {
    var lines = toolPaths("/a/one file\n/b/two\n");
    try testing.expectEqualStrings("/a/one file", lines.next().?);
    try testing.expectEqualStrings("/b/two", lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
}
