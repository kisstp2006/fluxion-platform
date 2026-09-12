// SPDX-License-Identifier: BSL-1.0

//! What a file or folder dialog is asked for. `Context.openFileDialog` and
//! `Context.openFolderDialog` open one, and the answer is a `.file_dialog`
//! event.

const std = @import("std");
const testing = std.testing;

const Window = @import("Window.zig");

/// One entry in a file dialog's list of types.
pub const Filter = struct {
    /// What the dialog shows for it: "Images".
    name: []const u8,
    /// `"png"` or `".png"`, and `"*"` for any file.
    extensions: []const []const u8,
};

pub const FileOptions = struct {
    /// The window the dialog belongs to and stays in front of.
    window: ?Window = null,
    /// The system's own when null: "Open".
    title: ?[]const u8 = null,
    multiple: bool = false,
    /// None shows every file.
    filters: []const Filter = &.{},
    /// Where the dialog starts, rather than wherever the system remembers.
    initial_folder: ?[]const u8 = null,
};

pub const FolderOptions = struct {
    window: ?Window = null,
    title: ?[]const u8 = null,
    initial_folder: ?[]const u8 = null,
};

/// An extension without its leading dot, the way every system writes it.
pub fn bare(extension: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, extension, ".")) extension[1..] else extension;
}

/// Whether a filter can be written in every system's syntax - patterns joined
/// by `;` on Windows and by `,` on a page - and mean the same in each.
pub fn validFilter(filter: Filter) bool {
    if (!std.unicode.utf8ValidateSlice(filter.name) or filter.extensions.len == 0) return false;
    for (filter.extensions) |extension| {
        if (!validExtension(bare(extension))) return false;
    }
    return true;
}

fn validExtension(extension: []const u8) bool {
    if (std.mem.eql(u8, extension, "*")) return true;
    if (extension.len == 0 or !std.unicode.utf8ValidateSlice(extension)) return false;
    if (extension[0] == '.' or extension[extension.len - 1] == '.') return false;
    for (extension) |byte| switch (byte) {
        0...' ', '*', '?', ';', ',', '/', '\\', '"', '<', '>', '|', ':', '[', ']', '(', ')', 0x7F => return false,
        else => {},
    };
    return true;
}

test "an extension loses its dot and nothing else" {
    try testing.expectEqualStrings("png", bare(".png"));
    try testing.expectEqualStrings("png", bare("png"));
    try testing.expectEqualStrings("tar.gz", bare(".tar.gz"));
    try testing.expectEqualStrings("*", bare("*"));
}

test "a filter is refused when a system would read it differently" {
    try testing.expect(validFilter(.{ .name = "Images", .extensions = &.{ "png", ".jpg", "tar.gz" } }));
    try testing.expect(validFilter(.{ .name = "Everything", .extensions = &.{"*"} }));
    try testing.expect(validFilter(.{ .name = "Képek", .extensions = &.{"kép"} }));

    try testing.expect(!validFilter(.{ .name = "Nothing", .extensions = &.{} }));
    try testing.expect(!validFilter(.{ .name = "Empty", .extensions = &.{""} }));
    try testing.expect(!validFilter(.{ .name = "Dot", .extensions = &.{"."} }));
    try testing.expect(!validFilter(.{ .name = "Two", .extensions = &.{"png;jpg"} }));
    try testing.expect(!validFilter(.{ .name = "Glob", .extensions = &.{"*.png"} }));
    try testing.expect(!validFilter(.{ .name = "Space", .extensions = &.{"p ng"} }));
    try testing.expect(!validFilter(.{ .name = "Trailing", .extensions = &.{"png."} }));
    try testing.expect(!validFilter(.{ .name = "Class", .extensions = &.{"[pP]ng"} }));
    try testing.expect(!validFilter(.{ .name = "\xFF", .extensions = &.{"png"} }));
}
