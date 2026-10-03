// SPDX-License-Identifier: BSL-1.0

//! The bar a phone types into: `FluxionActivity`'s text field above the soft
//! keyboard, which shows the person what they type while the keyboard covers
//! the program's own field. See `Window.setTextInputField`, and
//! `android/FluxionActivity.java` for the bar itself.
//!
//! A `NativeActivity` has no `InputConnection`, so a soft keyboard has
//! nowhere of its own to put what it types or composes. A real `EditText`
//! has one: the keyboard types into it, and every change crosses back whole -
//! its text, and where its caret is - for the program to put in its field.
//!
//! Text crosses as UTF-16, as the clipboard's does, and so do the caret's
//! places: `NewStringUTF` would misread a character past U+FFFF.

const std = @import("std");

const android_dialog = @import("android_dialog.zig");
const clipboard = @import("clipboard.zig");
const jni = @import("jni.zig");
const platform = @import("../platform.zig");
const text = @import("../text.zig");

const Error = platform.Error;
const JValue = jni.JValue;

/// The allocator for what crosses from the UI thread, which the program's
/// allocator need not be safe to be called from.
const heap = std.heap.c_allocator;

pub const edited_signature = "(Ljava/lang/String;II)V";
pub const done_signature = "(Z)V";
const show_signature = "(Ljava/lang/String;IIZZILjava/lang/String;)V";
const look_signature = "(ZIIIFFFFIIFIIFFFFI[B)V";

/// The activity's methods, looked up once on its class.
pub const Backend = struct {
    show_bar: jni.JMethodId = null,
    hide_bar: jni.JMethodId = null,
    set_look: jni.JMethodId = null,
    /// A print of the look the bar was last given, so it is given again
    /// only when it changes: a face's file is written out each time.
    look_given: ?u64 = null,

    pub fn ready(self: *const Backend) bool {
        return self.show_bar != null and self.hide_bar != null and self.set_look != null;
    }

    /// False for a plain `NativeActivity`, which has no bar.
    pub fn open(self: *Backend, env: jni.JniEnv, activity: jni.JObject) bool {
        if (self.ready()) return true;
        const class_of = env.*.GetObjectClass orelse return false;
        const delete_local = env.*.DeleteLocalRef orelse return false;
        const class = class_of(env, activity) orelse return false;
        defer delete_local(env, class);
        self.show_bar = android_dialog.methodOf(env, class, "showTextBar", show_signature);
        self.hide_bar = android_dialog.methodOf(env, class, "hideTextBar", "()V");
        self.set_look = android_dialog.methodOf(env, class, "setTextBarLook", look_signature);
        if (self.ready()) return true;
        self.* = .{};
        return false;
    }

    /// `showTextBar`: the bar up with `field` in it, or an open one brought
    /// up to it, in the field's look. Returns at once; the bar is made on the
    /// UI thread.
    /// `keep_look` leaves the bar in the look it has, for a field the
    /// program has not described yet.
    pub fn show(self: *Backend, env: jni.JniEnv, activity: jni.JObject, field: text.Field, keep_look: bool) Error!void {
        const frame = android_dialog.Frame.enter(env) orelse return error.Unavailable;
        defer frame.leave();
        const call_void = env.*.CallVoidMethodA orelse return error.Unavailable;

        const key = lookKey(field.look);
        if (!keep_look and self.look_given != key) {
            try self.giveLook(env, activity, field.look);
            self.look_given = key;
        }

        const args = [_]JValue{
            .{ .l = try android_dialog.newString(env, field.text) },
            .{ .i = unitsBefore(field.text, field.selection_start) },
            .{ .i = unitsBefore(field.text, field.selection_end) },
            .{ .z = @intFromBool(field.password) },
            .{ .z = @intFromBool(field.multiline) },
            .{ .i = @intCast(@min(field.max_length, std.math.maxInt(i32))) },
            .{ .l = try android_dialog.newString(env, field.hint) },
        };
        call_void(env, activity, self.show_bar, &args[0]);
        if (jni.threw(env)) return error.Unavailable;
    }

    /// `setTextBarLook`: the program's own look, or - for null - the bar's.
    fn giveLook(self: *const Backend, env: jni.JniEnv, activity: jni.JObject, given: ?text.Look) Error!void {
        const call_void = env.*.CallVoidMethodA orelse return error.Unavailable;
        const look = given orelse text.Look{};
        const font: jni.JObject = if (given != null and look.font.len > 0) blk: {
            const new_bytes = env.*.NewByteArray orelse return error.Unavailable;
            const set_bytes = env.*.SetByteArrayRegion orelse return error.Unavailable;
            const length = std.math.cast(i32, look.font.len) orelse return error.Unavailable;
            const bytes = new_bytes(env, length);
            if (jni.threw(env) or bytes == null) return error.Unavailable;
            set_bytes(env, bytes, 0, length, @ptrCast(look.font.ptr));
            if (jni.threw(env)) return error.Unavailable;
            break :blk bytes;
        } else null;
        const args = [_]JValue{
            .{ .z = @intFromBool(given != null) },
            .{ .i = @bitCast(look.bar) },
            .{ .i = @bitCast(look.field.background) },
            .{ .i = @bitCast(look.field.border) },
            .{ .f = look.field.border_width },
            .{ .f = look.field.corner_radius },
            .{ .f = look.field.padding_x },
            .{ .f = look.field.padding_y },
            .{ .i = @bitCast(look.field.text) },
            .{ .i = @bitCast(look.hint_color) },
            .{ .f = look.font_size },
            .{ .i = @bitCast(look.button.background) },
            .{ .i = @bitCast(look.button.border) },
            .{ .f = look.button.border_width },
            .{ .f = look.button.corner_radius },
            .{ .f = look.button.padding_x },
            .{ .f = look.button.padding_y },
            .{ .i = @bitCast(look.button.text) },
            .{ .l = font },
        };
        call_void(env, activity, self.set_look, &args[0]);
        if (jni.threw(env)) return error.Unavailable;
    }

    pub fn hide(self: *const Backend, env: jni.JniEnv, activity: jni.JObject) void {
        const call_void = env.*.CallVoidMethodA orelse return;
        call_void(env, activity, self.hide_bar, null);
        _ = jni.threw(env);
    }
};

/// What the bar holds after a change, handed from the UI thread that heard
/// it to the program's: the whole text, and its caret as byte offsets.
pub const Change = struct {
    text: []u8,
    selection_start: usize,
    selection_end: usize,

    /// Null when the string cannot be read, which is a change not heard.
    pub fn fromJava(env: jni.JniEnv, string: jni.JObject, start: i32, end: i32) ?*Change {
        const length = env.*.GetStringLength orelse return null;
        const chars = env.*.GetStringChars orelse return null;
        const release = env.*.ReleaseStringChars orelse return null;
        const units_at = chars(env, string, null) orelse return null;
        defer release(env, string, units_at);
        const units = units_at[0..@intCast(@max(0, length(env, string)))];

        var utf8: std.ArrayListUnmanaged(u8) = .empty;
        clipboard.appendUtf16(heap, &utf8, units) catch {
            utf8.deinit(heap);
            return null;
        };
        const self = heap.create(Change) catch {
            utf8.deinit(heap);
            return null;
        };
        const owned = utf8.toOwnedSlice(heap) catch {
            utf8.deinit(heap);
            heap.destroy(self);
            return null;
        };
        self.* = .{
            .text = owned,
            .selection_start = @min(bytesBefore(units, start), owned.len),
            .selection_end = @min(bytesBefore(units, end), owned.len),
        };
        return self;
    }

    pub fn destroy(self: *Change) void {
        heap.free(self.text);
        heap.destroy(self);
    }
};

/// A print of a look: its numbers, and its face's file by where it is.
fn lookKey(look: ?text.Look) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const given = look orelse return hasher.final();
    std.hash.autoHash(&hasher, true);
    inline for (.{ given.field, given.button }) |box| {
        inline for (std.meta.fields(text.Box)) |field| std.hash.autoHash(&hasher, @as(u32, @bitCast(@field(box, field.name))));
    }
    std.hash.autoHash(&hasher, given.bar);
    std.hash.autoHash(&hasher, given.hint_color);
    std.hash.autoHash(&hasher, @as(u32, @bitCast(given.font_size)));
    std.hash.autoHash(&hasher, @intFromPtr(given.font.ptr));
    std.hash.autoHash(&hasher, given.font.len);
    return hasher.final();
}

/// The UTF-16 units before byte `at` of UTF-8 `utf8`: a caret's place as
/// Java counts it. An offset inside a character counts from its start.
fn unitsBefore(utf8: []const u8, at: usize) i32 {
    var end = @min(at, utf8.len);
    while (end > 0 and end < utf8.len and utf8[end] & 0xC0 == 0x80) end -= 1;
    return @intCast(@min(clipboard.utf16Len(utf8[0..end], .lf), std.math.maxInt(i32)));
}

/// The UTF-8 bytes the first `index` of `units` become, as `appendUtf16`
/// turns them: a place Java counts, as this library does. Past either end,
/// the nearer end.
fn bytesBefore(units: []const u16, index: i32) usize {
    const count: usize = @intCast(std.math.clamp(index, 0, @as(i32, @intCast(@min(units.len, std.math.maxInt(i32))))));
    var bytes: usize = 0;
    var it = std.unicode.Wtf16LeIterator.init(units[0..count]);
    while (it.nextCodepoint()) |c| {
        const whole = if (std.unicode.isSurrogateCodepoint(c)) std.unicode.replacement_character else c;
        bytes += std.unicode.utf8CodepointSequenceLength(whole) catch 3;
    }
    return bytes;
}

/// What a change to the bar is as keys, for a program that described no
/// field: back over what went after the start the two share, then type what
/// came. `back` is how many characters go.
pub fn asKeys(before: []const u8, after: []const u8) struct { back: usize, typed: []const u8 } {
    var shared: usize = 0;
    var old = std.unicode.Utf8View.initUnchecked(before).iterator();
    var new = std.unicode.Utf8View.initUnchecked(after).iterator();
    while (true) {
        const one = old.nextCodepointSlice() orelse break;
        const other = new.nextCodepointSlice() orelse break;
        if (!std.mem.eql(u8, one, other)) break;
        shared += one.len;
    }
    const gone = std.unicode.utf8CountCodepoints(before[shared..]) catch before.len - shared;
    return .{ .back = gone, .typed = after[shared..] };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a bar that never found its activity's methods is not ready" {
    const unopened: Backend = .{};
    try testing.expect(!unopened.ready());
}

test "every method either side calls is declared, as called, in the Java" {
    const java = @embedFile("android/FluxionActivity.java");
    try testing.expect(std.mem.indexOf(u8, java, "private static native void textBarEdited(String text, int start, int end)") != null);
    try testing.expectEqualStrings("(Ljava/lang/String;II)V", edited_signature);
    try testing.expect(std.mem.indexOf(u8, java, "private static native void textBarDone(boolean submitted)") != null);
    try testing.expectEqualStrings("(Z)V", done_signature);
    try testing.expect(std.mem.indexOf(u8, java, "public void showTextBar(String text, int start, int end, boolean password, boolean multiline, int maxLength, String hint)") != null);
    try testing.expectEqualStrings("(Ljava/lang/String;IIZZILjava/lang/String;)V", show_signature);
    // own, bar, the field's fill, edge, edge width, corner, padding across
    // and down, text, hint, text size, the button's seven, the face.
    // A line at a time: the file's line endings are its checkout's.
    for ([_][]const u8{
        "public void setTextBarLook(boolean own, int barColor,",
        "int field, int fieldBorder, float fieldBorderWidth, float fieldRadius, float fieldPaddingX, float fieldPaddingY, int text, int hint, float textSize,",
        "int button, int buttonBorder, float buttonBorderWidth, float buttonRadius, float buttonPaddingX, float buttonPaddingY, int buttonText,",
        "byte[] font) {",
    }) |line| try testing.expect(std.mem.indexOf(u8, java, line) != null);
    try testing.expectEqualStrings("(ZIIIFFFFIIFIIFFFFI[B)V", look_signature);
    try testing.expect(std.mem.indexOf(u8, java, "public void hideTextBar()") != null);
}

test "a look is given again only when something of it changes" {
    const plain: text.Look = .{};
    var other = plain;
    other.field.corner_radius = 4;
    try testing.expect(lookKey(null) != lookKey(plain));
    try testing.expect(lookKey(plain) != lookKey(other));
    try testing.expectEqual(lookKey(other), lookKey(other));
}

test "a caret's place is counted as Java counts it and back, past accents and an emoji" {
    // "é" is one unit and two bytes; the emoji two units and four bytes.
    const utf8 = "Hé \u{1F600}!";
    var units: [16]u16 = undefined;
    const count = clipboard.utf16Len(utf8, .lf);
    clipboard.toUtf16(utf8, .lf, units[0..count]);
    try testing.expectEqual(@as(usize, 6), count);

    for ([_][2]usize{ .{ 0, 0 }, .{ 1, 1 }, .{ 3, 2 }, .{ 4, 3 }, .{ 8, 5 }, .{ 9, 6 } }) |pair| {
        try testing.expectEqual(@as(i32, @intCast(pair[1])), unitsBefore(utf8, pair[0]));
        try testing.expectEqual(pair[0], bytesBefore(units[0..count], @intCast(pair[1])));
    }
    // Inside a character: from its start. Past the end: the end.
    try testing.expectEqual(@as(i32, 1), unitsBefore(utf8, 2));
    try testing.expectEqual(@as(i32, 6), unitsBefore(utf8, 99));
    try testing.expectEqual(@as(usize, 9), bytesBefore(units[0..count], 99));
    try testing.expectEqual(@as(usize, 0), bytesBefore(units[0..count], -4));
}

test "a change is the characters that went back over and what came typed" {
    const typed = asKeys("Pla", "Player");
    try testing.expectEqual(@as(usize, 0), typed.back);
    try testing.expectEqualStrings("yer", typed.typed);

    const erased = asKeys("Player", "Play");
    try testing.expectEqual(@as(usize, 2), erased.back);
    try testing.expectEqualStrings("", erased.typed);

    // A word the keyboard corrected: back to where the two part, then the rest.
    const corrected = asKeys("helo wrld", "helo world");
    try testing.expectEqual(@as(usize, 3), corrected.back);
    try testing.expectEqualStrings("orld", corrected.typed);

    // Characters, not bytes, go back.
    const accent = asKeys("kés", "ké");
    try testing.expectEqual(@as(usize, 1), accent.back);
    const emoji = asKeys("a\u{1F600}", "a");
    try testing.expectEqual(@as(usize, 1), emoji.back);
}
