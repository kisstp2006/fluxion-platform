// SPDX-License-Identifier: BSL-1.0

//! `shell` on Android: an `ACTION_VIEW` intent, as a tapped link starts one.

const std = @import("std");
const Allocator = std.mem.Allocator;

const jni = @import("jni.zig");

const JValue = jni.JValue;

pub const Outcome = enum { done, no_handler, unavailable };

const flag_grant_read_uri_permission: i32 = 0x1;

/// `startActivity(new Intent(ACTION_VIEW, Uri.parse(uri)))`, and a
/// `content://` one's reader let in to read it.
pub fn view(env: jni.JniEnv, activity: jni.JObject, gpa: Allocator, uri: []const u8) Allocator.Error!Outcome {
    const units = std.unicode.utf8ToUtf16LeAlloc(gpa, uri) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .unavailable,
    };
    defer gpa.free(units);

    const push = env.*.PushLocalFrame orelse return .unavailable;
    const pop = env.*.PopLocalFrame orelse return .unavailable;
    if (push(env, 16) != jni.ok) {
        jni.clearException(env);
        return .unavailable;
    }
    defer _ = pop(env, null);
    return intent(env, activity, units, std.ascii.startsWithIgnoreCase(uri, "content:"));
}

fn intent(env: jni.JniEnv, activity: jni.JObject, units: []const u16, content: bool) Outcome {
    const new_string = env.*.NewString orelse return .unavailable;
    const new_ascii = env.*.NewStringUTF orelse return .unavailable;
    const new_object = env.*.NewObjectA orelse return .unavailable;
    const call_static = env.*.CallStaticObjectMethodA orelse return .unavailable;
    const call_object = env.*.CallObjectMethodA orelse return .unavailable;
    const call_void = env.*.CallVoidMethodA orelse return .unavailable;
    const class_of = env.*.GetObjectClass orelse return .unavailable;

    const uri_class = find(env, "android/net/Uri") orelse return .unavailable;
    const parse = staticMethod(env, uri_class, "parse", "(Ljava/lang/String;)Landroid/net/Uri;") orelse return .unavailable;
    const text = new_string(env, units.ptr, @intCast(units.len));
    if (jni.threw(env) or text == null) return .unavailable;
    const text_arg = [_]JValue{.{ .l = text }};
    const parsed = call_static(env, uri_class, parse, &text_arg[0]);
    if (jni.threw(env) or parsed == null) return .unavailable;

    const intent_class = find(env, "android/content/Intent") orelse return .unavailable;
    const make = method(env, intent_class, "<init>", "(Ljava/lang/String;Landroid/net/Uri;)V") orelse return .unavailable;
    const action = new_ascii(env, "android.intent.action.VIEW");
    if (jni.threw(env) or action == null) return .unavailable;
    const make_args = [_]JValue{ .{ .l = action }, .{ .l = parsed } };
    const viewing = new_object(env, intent_class, make, &make_args[0]);
    if (jni.threw(env) or viewing == null) return .unavailable;

    if (content) {
        const add_flags = method(env, intent_class, "addFlags", "(I)Landroid/content/Intent;") orelse return .unavailable;
        const flags = [_]JValue{.{ .i = flag_grant_read_uri_permission }};
        _ = call_object(env, viewing, add_flags, &flags[0]);
        if (jni.threw(env)) return .unavailable;
    }

    const activity_class = class_of(env, activity) orelse return .unavailable;
    const start = method(env, activity_class, "startActivity", "(Landroid/content/Intent;)V") orelse return .unavailable;
    const start_args = [_]JValue{.{ .l = viewing }};
    call_void(env, activity, start, &start_args[0]);
    // `ActivityNotFoundException`: nothing on the phone views this.
    return if (jni.threw(env)) .no_handler else .done;
}

fn find(env: jni.JniEnv, name: [*:0]const u8) jni.JClass {
    const find_class = env.*.FindClass orelse return null;
    const class = find_class(env, name);
    return if (jni.threw(env)) null else class;
}

fn method(env: jni.JniEnv, class: jni.JClass, name: [*:0]const u8, signature: [*:0]const u8) jni.JMethodId {
    const get = env.*.GetMethodID orelse return null;
    const id = get(env, class, name, signature);
    return if (jni.threw(env)) null else id;
}

fn staticMethod(env: jni.JniEnv, class: jni.JClass, name: [*:0]const u8, signature: [*:0]const u8) jni.JMethodId {
    const get = env.*.GetStaticMethodID orelse return null;
    const id = get(env, class, name, signature);
    return if (jni.threw(env)) null else id;
}
