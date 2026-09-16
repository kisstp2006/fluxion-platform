// SPDX-License-Identifier: BSL-1.0

//! The file dialog on Android: the system's document picker, started and
//! heard through `FluxionActivity` - the one Java class this library has,
//! since a `NativeActivity` never hands `onActivityResult` to native code. See
//! `android/FluxionActivity.java`.
//!
//! An answer names documents by their display names, as a page's does. A
//! `content://` URI is not a path anything here can open, so the bytes come
//! through a file descriptor the activity opens for the URI kept beside each
//! name.

const std = @import("std");
const Allocator = std.mem.Allocator;

const backend = @import("../backend.zig");
const clipboard = @import("clipboard.zig");
const dialog = @import("../dialog.zig");
const jni = @import("jni.zig");
const platform = @import("../platform.zig");

const Error = platform.Error;
const JValue = jni.JValue;

/// The allocator for what crosses from a Java thread, which the program's
/// allocator need not be safe to be called from.
const heap = std.heap.c_allocator;

const c = struct {
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
};

pub const answered_signature = "(I[Ljava/lang/String;[Ljava/lang/String;)V";

/// Give `FluxionActivity.answered` its native half, on the activity's class.
/// False for a plain `NativeActivity`, which has no such method - an app
/// whose manifest does not name `FluxionActivity` simply has no dialog.
pub fn register(env: jni.JniEnv, activity: jni.JObject, function: *const anyopaque) bool {
    const methods = [_]jni.NativeMethod{.{ .name = "answered", .signature = answered_signature, .function = function }};
    return jni.registerNatives(env, activity, &methods);
}

/// The activity's two methods, looked up once on its class.
pub const Backend = struct {
    open_documents: jni.JMethodId = null,
    open_chosen: jni.JMethodId = null,
    /// A global reference: `String[]` is made on every request, long after
    /// the frame that found the class has gone.
    string_class: jni.JObject = null,

    pub fn ready(self: *const Backend) bool {
        return self.open_documents != null and self.open_chosen != null and self.string_class != null;
    }

    pub fn open(self: *Backend, env: jni.JniEnv, activity: jni.JObject) bool {
        if (self.ready()) return true;
        const class_of = env.*.GetObjectClass orelse return false;
        const find = env.*.FindClass orelse return false;
        const new_global = env.*.NewGlobalRef orelse return false;
        const delete_local = env.*.DeleteLocalRef orelse return false;

        const class = class_of(env, activity) orelse return false;
        defer delete_local(env, class);
        self.open_documents = methodOf(env, class, "openDocuments", "(IZZ[Ljava/lang/String;)V");
        self.open_chosen = methodOf(env, class, "openChosen", "(Ljava/lang/String;)I");
        const string = find(env, "java/lang/String");
        if (jni.threw(env) or string == null) return false;
        defer delete_local(env, string);
        self.string_class = new_global(env, string);
        if (self.ready()) return true;
        self.close(env);
        return false;
    }

    pub fn close(self: *Backend, env: jni.JniEnv) void {
        if (self.string_class != null) {
            if (env.*.DeleteGlobalRef) |delete| delete(env, self.string_class);
        }
        self.* = .{};
    }

    /// `openDocuments(id, folder, multiple, extensions)`, which starts the
    /// picker on the UI thread and returns at once.
    pub fn ask(self: *const Backend, env: jni.JniEnv, activity: jni.JObject, request: backend.DialogRequest) Error!void {
        const frame = Frame.enter(env) orelse return error.Unavailable;
        defer frame.leave();
        const new_array = env.*.NewObjectArray orelse return error.Unavailable;
        const set_element = env.*.SetObjectArrayElement orelse return error.Unavailable;
        const call_void = env.*.CallVoidMethodA orelse return error.Unavailable;

        var count: usize = 0;
        for (request.filters) |filter| count += filter.extensions.len;
        const extensions = new_array(env, @intCast(count), self.string_class, null);
        if (jni.threw(env) or extensions == null) return error.Unavailable;
        var at: i32 = 0;
        for (request.filters) |filter| {
            for (filter.extensions) |extension| {
                const string = try newString(env, dialog.bare(extension));
                set_element(env, extensions, at, string);
                if (jni.threw(env)) return error.Unavailable;
                at += 1;
            }
        }

        const args = [_]JValue{
            .{ .i = @bitCast(@intFromEnum(request.id)) },
            .{ .z = @intFromBool(request.folder) },
            .{ .z = @intFromBool(request.multiple) },
            .{ .l = extensions },
        };
        call_void(env, activity, self.open_documents, &args[0]);
        if (jni.threw(env)) return error.Unavailable;
    }

    /// The bytes behind one chosen URI, through the descriptor `openChosen`
    /// hands back.
    pub fn read(self: *const Backend, env: jni.JniEnv, activity: jni.JObject, uri: []const u8, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
        const fd = opened: {
            const frame = Frame.enter(env) orelse return error.Unavailable;
            defer frame.leave();
            const call_int = env.*.CallIntMethodA orelse return error.Unavailable;
            const args = [_]JValue{.{ .l = try newString(env, uri) }};
            const descriptor = call_int(env, activity, self.open_chosen, &args[0]);
            if (jni.threw(env) or descriptor < 0) return error.Unavailable;
            break :opened descriptor;
        };
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
};

/// One answer, handed from the Java thread that heard it to the program's.
pub const Answer = struct {
    id: u32,
    names: [][]u8,
    uris: [][]u8,

    /// Copied out of the two `String[]`, or null where memory or the VM gave
    /// out - which loses the answer rather than half of it.
    pub fn fromJava(env: jni.JniEnv, id: i32, names: jni.JObject, uris: jni.JObject) ?*Answer {
        const self = heap.create(Answer) catch return null;
        self.* = .{ .id = @bitCast(id), .names = &.{}, .uris = &.{} };
        self.names = strings(env, names) catch {
            self.destroy();
            return null;
        };
        self.uris = strings(env, uris) catch {
            self.destroy();
            return null;
        };
        if (self.names.len != self.uris.len) {
            self.destroy();
            return null;
        }
        return self;
    }

    /// An answer with nothing chosen, for when the real one could not be
    /// copied: the program must still hear that its dialog is over.
    pub fn empty(id: i32) ?*Answer {
        const self = heap.create(Answer) catch return null;
        self.* = .{ .id = @bitCast(id), .names = &.{}, .uris = &.{} };
        return self;
    }

    pub fn destroy(self: *Answer) void {
        for (self.names) |name| heap.free(name);
        heap.free(self.names);
        for (self.uris) |uri| heap.free(uri);
        heap.free(self.uris);
        heap.destroy(self);
    }
};

/// Every string of a `String[]`, as UTF-8. Each element's reference is let go
/// as soon as it is read: a folder can hold more files than a thread has
/// local references.
fn strings(env: jni.JniEnv, array: jni.JObject) error{ OutOfMemory, Unavailable }![][]u8 {
    const length = env.*.GetArrayLength orelse return error.Unavailable;
    const element = env.*.GetObjectArrayElement orelse return error.Unavailable;
    const delete_local = env.*.DeleteLocalRef orelse return error.Unavailable;
    const string_length = env.*.GetStringLength orelse return error.Unavailable;
    const chars = env.*.GetStringChars orelse return error.Unavailable;
    const release = env.*.ReleaseStringChars orelse return error.Unavailable;

    const count: usize = @intCast(@max(0, length(env, array)));
    const out = try heap.alloc([]u8, count);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |each| heap.free(each);
        heap.free(out);
    }
    while (filled < count) : (filled += 1) {
        const string = element(env, array, @intCast(filled));
        if (jni.threw(env) or string == null) return error.Unavailable;
        defer delete_local(env, string);
        const units = chars(env, string, null) orelse return error.Unavailable;
        defer release(env, string, units);
        var utf8: std.ArrayListUnmanaged(u8) = .empty;
        errdefer utf8.deinit(heap);
        try clipboard.appendUtf16(heap, &utf8, units[0..@intCast(@max(0, string_length(env, string)))]);
        out[filled] = try utf8.toOwnedSlice(heap);
    }
    return out;
}

/// A Java string from UTF-8, through UTF-16: `NewStringUTF` reads modified
/// UTF-8, which spells a character above U+FFFF differently.
fn newString(env: jni.JniEnv, text: []const u8) Error!jni.JObject {
    const new_string = env.*.NewString orelse return error.Unavailable;
    var units: std.ArrayListUnmanaged(u16) = .empty;
    defer units.deinit(heap);
    try units.resize(heap, clipboard.utf16Len(text, .lf));
    clipboard.toUtf16(text, .lf, units.items);
    const string = new_string(env, units.items.ptr, @intCast(units.items.len));
    if (jni.threw(env) or string == null) return error.Unavailable;
    return string;
}

fn methodOf(env: jni.JniEnv, class: jni.JClass, name: [*:0]const u8, signature: [*:0]const u8) jni.JMethodId {
    const get = env.*.GetMethodID orelse return null;
    const method = get(env, class, name, signature);
    return if (jni.threw(env)) null else method;
}

const Frame = struct {
    env: jni.JniEnv,

    fn enter(env: jni.JniEnv) ?Frame {
        const push = env.*.PushLocalFrame orelse return null;
        if (env.*.PopLocalFrame == null) return null;
        if (push(env, 16) != jni.ok) {
            jni.clearException(env);
            return null;
        }
        return .{ .env = env };
    }

    fn leave(self: Frame) void {
        _ = self.env.*.PopLocalFrame.?(self.env, null);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a dialog that never found its activity's methods is not ready" {
    const unopened: Backend = .{};
    try testing.expect(!unopened.ready());
}

test "every method either side calls is declared, as called, in the Java" {
    const java = @embedFile("android/FluxionActivity.java");
    try testing.expect(std.mem.indexOf(u8, java, "private static native void answered(int id, String[] names, String[] uris)") != null);
    try testing.expectEqualStrings("(I[Ljava/lang/String;[Ljava/lang/String;)V", answered_signature);
    try testing.expect(std.mem.indexOf(u8, java, "public void openDocuments(int id, boolean folder, boolean multiple, String[] extensions)") != null);
    try testing.expect(std.mem.indexOf(u8, java, "public int openChosen(String uri)") != null);
    try testing.expect(std.mem.indexOf(u8, java, "package dev.fluxion.platform;") != null);
}
