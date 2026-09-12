// SPDX-License-Identifier: BSL-1.0

//! The Android clipboard, through JNI: `ClipboardManager` has no NDK
//! counterpart, so the activity is asked for it the way `android_text` asks a
//! `KeyEvent` what it types.
//!
//! **Text crosses as UTF-16.** `NewStringUTF` and `GetStringUTFChars` speak
//! modified UTF-8, which writes a character above U+FFFF as two three-byte
//! surrogates - so an emoji copied through them comes out as six bytes no
//! UTF-8 reader accepts, and one copied in may abort the VM. `NewString` and
//! `GetStringChars` take and give UTF-16, and the conversion is done here.
//!
//! **Every call is inside a local frame.** The app thread was attached from
//! native code and never returns into Java, so nothing ever frees its local
//! references for it; a frame popped after each call frees them all at once.

const std = @import("std");
const Allocator = std.mem.Allocator;

const jni = @import("jni.zig");
const clipboard = @import("clipboard.zig");

const JValue = jni.JValue;

/// What the calls reach through, looked up once and kept: two global
/// references, since a local one dies with the frame that made it, and the
/// methods, which live as long as their classes do.
pub const Backend = struct {
    manager: jni.JObject = null,
    clip_data: jni.JObject = null,

    new_plain_text: jni.JMethodId = null,
    set_primary_clip: jni.JMethodId = null,
    get_primary_clip: jni.JMethodId = null,
    has_primary_clip: jni.JMethodId = null,
    get_description: jni.JMethodId = null,
    has_mime_type: jni.JMethodId = null,
    item_count: jni.JMethodId = null,
    item_at: jni.JMethodId = null,
    coerce_to_text: jni.JMethodId = null,
    to_string: jni.JMethodId = null,

    pub fn ready(self: *const Backend) bool {
        inline for (@typeInfo(Backend).@"struct".fields) |field| {
            if (@field(self, field.name) == null) return false;
        }
        return true;
    }

    /// Ask the activity for its `ClipboardManager` and find every method this
    /// needs. False, with everything let go again, if any of it is missing.
    pub fn open(self: *Backend, env: jni.JniEnv, activity: jni.JObject) bool {
        if (self.ready()) return true;
        const frame = Frame.enter(env) orelse return false;
        defer frame.leave();

        self.lookUp(env, activity);
        if (self.ready()) return true;
        self.close(env);
        return false;
    }

    fn lookUp(self: *Backend, env: jni.JniEnv, activity: jni.JObject) void {
        const class_of = env.*.GetObjectClass orelse return;
        const call_object = env.*.CallObjectMethodA orelse return;
        const new_global = env.*.NewGlobalRef orelse return;
        const new_ascii = env.*.NewStringUTF orelse return;

        const activity_class = class_of(env, activity) orelse return;
        const get_service = methodOf(env, activity_class, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;") orelse return;
        const service = new_ascii(env, "clipboard");
        if (jni.threw(env) or service == null) return;
        const name = [_]JValue{.{ .l = service }};
        const manager = call_object(env, activity, get_service, &name[0]);
        if (jni.threw(env) or manager == null) return;
        self.manager = new_global(env, manager);

        const manager_class = classOf(env, "android/content/ClipboardManager") orelse return;
        self.set_primary_clip = methodOf(env, manager_class, "setPrimaryClip", "(Landroid/content/ClipData;)V");
        self.get_primary_clip = methodOf(env, manager_class, "getPrimaryClip", "()Landroid/content/ClipData;");
        self.has_primary_clip = methodOf(env, manager_class, "hasPrimaryClip", "()Z");
        self.get_description = methodOf(env, manager_class, "getPrimaryClipDescription", "()Landroid/content/ClipDescription;");

        const clip_data = classOf(env, "android/content/ClipData") orelse return;
        self.clip_data = new_global(env, clip_data);
        self.new_plain_text = staticMethodOf(env, clip_data, "newPlainText", "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;");
        self.item_count = methodOf(env, clip_data, "getItemCount", "()I");
        self.item_at = methodOf(env, clip_data, "getItemAt", "(I)Landroid/content/ClipData$Item;");

        const item = classOf(env, "android/content/ClipData$Item") orelse return;
        self.coerce_to_text = methodOf(env, item, "coerceToText", "(Landroid/content/Context;)Ljava/lang/CharSequence;");
        const description = classOf(env, "android/content/ClipDescription") orelse return;
        self.has_mime_type = methodOf(env, description, "hasMimeType", "(Ljava/lang/String;)Z");
        const object = classOf(env, "java/lang/Object") orelse return;
        self.to_string = methodOf(env, object, "toString", "()Ljava/lang/String;");
    }

    pub fn close(self: *Backend, env: jni.JniEnv) void {
        if (env.*.DeleteGlobalRef) |delete| {
            if (self.manager != null) delete(env, self.manager);
            if (self.clip_data != null) delete(env, self.clip_data);
        }
        self.* = .{};
    }

    /// `setPrimaryClip(ClipData.newPlainText(null, text))`. False if the VM
    /// refused any of it.
    pub fn setText(self: *const Backend, env: jni.JniEnv, gpa: Allocator, text: []const u8) Allocator.Error!bool {
        const units = try gpa.alloc(u16, clipboard.utf16Len(text, .lf));
        defer gpa.free(units);
        clipboard.toUtf16(text, .lf, units);

        const frame = Frame.enter(env) orelse return false;
        defer frame.leave();
        const new_string = env.*.NewString orelse return false;
        const call_static = env.*.CallStaticObjectMethodA orelse return false;
        const call_void = env.*.CallVoidMethodA orelse return false;

        const string = new_string(env, units.ptr, @intCast(units.len));
        if (jni.threw(env) or string == null) return false;
        const plain = [_]JValue{ .{ .l = null }, .{ .l = string } };
        const clip = call_static(env, self.clip_data, self.new_plain_text, &plain[0]);
        if (jni.threw(env) or clip == null) return false;
        const args = [_]JValue{.{ .l = clip }};
        call_void(env, self.manager, self.set_primary_clip, &args[0]);
        return !jni.threw(env);
    }

    /// Whether the clip is text, from its description alone. Reading the clip
    /// itself is what Android 12 and later announce with a notice.
    pub fn hasText(self: *const Backend, env: jni.JniEnv) bool {
        const frame = Frame.enter(env) orelse return false;
        defer frame.leave();
        const call_bool = env.*.CallBooleanMethodA orelse return false;
        const call_object = env.*.CallObjectMethodA orelse return false;
        const new_ascii = env.*.NewStringUTF orelse return false;

        const has = call_bool(env, self.manager, self.has_primary_clip, null);
        if (jni.threw(env) or has == 0) return false;
        const description = call_object(env, self.manager, self.get_description, null);
        if (jni.threw(env) or description == null) return false;
        const pattern = new_ascii(env, "text/*");
        if (jni.threw(env) or pattern == null) return false;
        const text = [_]JValue{.{ .l = pattern }};
        const is_text = call_bool(env, description, self.has_mime_type, &text[0]);
        return !jni.threw(env) and is_text != 0;
    }

    /// The first item of the clip, as text, appended to `out`. Nothing when
    /// the clip is not text, and nothing on Android 10 and later while this is
    /// not the app in front - which is when the system hands out a null clip.
    pub fn readText(
        self: *const Backend,
        env: jni.JniEnv,
        activity: jni.JObject,
        gpa: Allocator,
        out: *std.ArrayListUnmanaged(u8),
    ) Allocator.Error!void {
        if (!self.hasText(env)) return;
        const frame = Frame.enter(env) orelse return;
        defer frame.leave();
        const call_object = env.*.CallObjectMethodA orelse return;
        const call_int = env.*.CallIntMethodA orelse return;
        const length = env.*.GetStringLength orelse return;
        const chars = env.*.GetStringChars orelse return;
        const release = env.*.ReleaseStringChars orelse return;

        const clip = call_object(env, self.manager, self.get_primary_clip, null);
        if (jni.threw(env) or clip == null) return;
        const count = call_int(env, clip, self.item_count, null);
        if (jni.threw(env) or count < 1) return;
        const first = [_]JValue{.{ .i = 0 }};
        const item = call_object(env, clip, self.item_at, &first[0]);
        if (jni.threw(env) or item == null) return;
        const context = [_]JValue{.{ .l = activity }};
        const sequence = call_object(env, item, self.coerce_to_text, &context[0]);
        if (jni.threw(env) or sequence == null) return;
        const string = call_object(env, sequence, self.to_string, null);
        if (jni.threw(env) or string == null) return;

        const len = length(env, string);
        const units = chars(env, string, null) orelse {
            jni.clearException(env);
            return;
        };
        defer release(env, string, units);
        try clipboard.appendUtf16(gpa, out, units[0..@intCast(@max(len, 0))]);
    }
};

/// A class by name, or null with its exception cleared.
fn classOf(env: jni.JniEnv, name: [*:0]const u8) jni.JClass {
    const find = env.*.FindClass orelse return null;
    const class = find(env, name);
    return if (jni.threw(env)) null else class;
}

fn methodOf(env: jni.JniEnv, class: jni.JClass, name: [*:0]const u8, signature: [*:0]const u8) jni.JMethodId {
    const get = env.*.GetMethodID orelse return null;
    const method = get(env, class, name, signature);
    return if (jni.threw(env)) null else method;
}

fn staticMethodOf(env: jni.JniEnv, class: jni.JClass, name: [*:0]const u8, signature: [*:0]const u8) jni.JMethodId {
    const get = env.*.GetStaticMethodID orelse return null;
    const method = get(env, class, name, signature);
    return if (jni.threw(env)) null else method;
}

/// A local frame: every reference made inside it is freed by `leave`.
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

test "a clipboard that never opened is not ready" {
    const backend: Backend = .{};
    try testing.expect(!backend.ready());
}
