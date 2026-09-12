// SPDX-License-Identifier: BSL-1.0

//! The slice of JNI the Android backend reaches the VM through: what a key
//! types (`android_text`), the clipboard (`android_clipboard`) and the file
//! dialog (`android_dialog`), none of which the NDK exposes to C.
//!
//! **The function tables are indexed by position.** `JNINativeInterface` is a
//! struct of function pointers whose order is fixed by the specification and
//! has not changed since 1.6, so the slots below are named where they are used
//! and padded where they are not. One field out of place calls the wrong
//! function with the wrong arguments, which is why every named slot's offset
//! is asserted in a test.

const std = @import("std");

/// C's `JavaVM*` and `JNIEnv*`, which are **double** pointers.
///
/// In C++ a `JavaVM` is the interface struct itself and a method is called on
/// it directly. In C it is a struct with one field - a pointer to that
/// interface - so `JavaVM*` is a pointer to a pointer to the table, and every
/// call is `(*vm)->Method(vm, ...)`.
///
/// `ANativeActivity.vm` is the C spelling. Getting this wrong reads the wrong
/// words as function pointers and jumps to whatever is there: the first attempt
/// here died at address 1.
pub const JavaVm = *const *const InvokeInterface;
pub const JniEnv = *const *const NativeInterface;
pub const JObject = ?*anyopaque;
pub const JClass = JObject;
pub const JMethodId = ?*anyopaque;

/// `JNI_VERSION_1_6`, which is what every Android since 2.3 answers to.
pub const version_1_6: i32 = 0x00010006;
pub const ok: i32 = 0;

/// `JavaVM`'s own table. Three reserved slots come first, which is the
/// specification's own layout and not padding this file invented.
pub const InvokeInterface = extern struct {
    reserved0: ?*anyopaque = null,
    reserved1: ?*anyopaque = null,
    reserved2: ?*anyopaque = null,

    DestroyJavaVM: ?*const fn (JavaVm) callconv(.c) i32 = null,
    AttachCurrentThread: ?*const fn (JavaVm, *JniEnv, ?*anyopaque) callconv(.c) i32 = null,
    DetachCurrentThread: ?*const fn (JavaVm) callconv(.c) i32 = null,
    GetEnv: ?*const fn (JavaVm, *?*anyopaque, i32) callconv(.c) i32 = null,
    AttachCurrentThreadAsDaemon: ?*const fn (JavaVm, *JniEnv, ?*anyopaque) callconv(.c) i32 = null,
};

/// `JNIEnv`'s table, as far as the calls this backend makes.
///
/// Four reserved slots, then every function in specification order: the ones
/// used are named and typed, the rest are untyped pointers or runs of them,
/// which is enough to put the named ones at the right offsets.
pub const NativeInterface = extern struct {
    reserved0: ?*anyopaque = null,
    reserved1: ?*anyopaque = null,
    reserved2: ?*anyopaque = null,
    reserved3: ?*anyopaque = null,

    GetVersion: ?*anyopaque = null, // 4
    DefineClass: ?*anyopaque = null, // 5
    FindClass: ?*const fn (JniEnv, [*:0]const u8) callconv(.c) JClass = null, // 6
    FromReflectedMethod: ?*anyopaque = null, // 7
    FromReflectedField: ?*anyopaque = null, // 8
    ToReflectedMethod: ?*anyopaque = null, // 9
    GetSuperclass: ?*anyopaque = null, // 10
    IsAssignableFrom: ?*anyopaque = null, // 11
    ToReflectedField: ?*anyopaque = null, // 12
    Throw: ?*anyopaque = null, // 13
    ThrowNew: ?*anyopaque = null, // 14
    ExceptionOccurred: ?*const fn (JniEnv) callconv(.c) JObject = null, // 15
    ExceptionDescribe: ?*anyopaque = null, // 16
    ExceptionClear: ?*const fn (JniEnv) callconv(.c) void = null, // 17
    FatalError: ?*anyopaque = null, // 18
    PushLocalFrame: ?*const fn (JniEnv, i32) callconv(.c) i32 = null, // 19
    PopLocalFrame: ?*const fn (JniEnv, JObject) callconv(.c) JObject = null, // 20
    NewGlobalRef: ?*const fn (JniEnv, JObject) callconv(.c) JObject = null, // 21
    DeleteGlobalRef: ?*const fn (JniEnv, JObject) callconv(.c) void = null, // 22
    DeleteLocalRef: ?*const fn (JniEnv, JObject) callconv(.c) void = null, // 23
    IsSameObject: ?*anyopaque = null, // 24
    NewLocalRef: ?*anyopaque = null, // 25
    EnsureLocalCapacity: ?*anyopaque = null, // 26
    AllocObject: ?*anyopaque = null, // 27
    NewObject: ?*anyopaque = null, // 28
    NewObjectV: ?*anyopaque = null, // 29
    NewObjectA: ?*const fn (JniEnv, JClass, JMethodId, ?*const JValue) callconv(.c) JObject = null, // 30
    GetObjectClass: ?*const fn (JniEnv, JObject) callconv(.c) JClass = null, // 31
    IsInstanceOf: ?*anyopaque = null, // 32
    GetMethodID: ?*const fn (JniEnv, JClass, [*:0]const u8, [*:0]const u8) callconv(.c) JMethodId = null, // 33
    CallObjectMethod: ?*anyopaque = null, // 34
    CallObjectMethodV: ?*anyopaque = null, // 35
    /// The array forms throughout, because the variadic ones cannot be called
    /// portably from Zig - and because an array of `jvalue` is what this needs
    /// anyway.
    CallObjectMethodA: ?*const fn (JniEnv, JObject, JMethodId, ?*const JValue) callconv(.c) JObject = null, // 36
    CallBooleanMethod: ?*anyopaque = null, // 37
    CallBooleanMethodV: ?*anyopaque = null, // 38
    CallBooleanMethodA: ?*const fn (JniEnv, JObject, JMethodId, ?*const JValue) callconv(.c) u8 = null, // 39
    CallByteMethod: ?*anyopaque = null, // 40
    CallByteMethodV: ?*anyopaque = null, // 41
    CallByteMethodA: ?*anyopaque = null, // 42
    CallCharMethod: ?*anyopaque = null, // 43
    CallCharMethodV: ?*anyopaque = null, // 44
    CallCharMethodA: ?*anyopaque = null, // 45
    CallShortMethod: ?*anyopaque = null, // 46
    CallShortMethodV: ?*anyopaque = null, // 47
    CallShortMethodA: ?*anyopaque = null, // 48
    CallIntMethod: ?*anyopaque = null, // 49
    CallIntMethodV: ?*anyopaque = null, // 50
    CallIntMethodA: ?*const fn (JniEnv, JObject, JMethodId, ?*const JValue) callconv(.c) i32 = null, // 51
    /// 52 to 60: the calls returning long, float and double.
    unused_52: [9]?*anyopaque = @splat(null),
    CallVoidMethod: ?*anyopaque = null, // 61
    CallVoidMethodV: ?*anyopaque = null, // 62
    CallVoidMethodA: ?*const fn (JniEnv, JObject, JMethodId, ?*const JValue) callconv(.c) void = null, // 63
    /// 64 to 112: the non-virtual calls, and the instance fields.
    unused_64: [49]?*anyopaque = @splat(null),
    GetStaticMethodID: ?*const fn (JniEnv, JClass, [*:0]const u8, [*:0]const u8) callconv(.c) JMethodId = null, // 113
    CallStaticObjectMethod: ?*anyopaque = null, // 114
    CallStaticObjectMethodV: ?*anyopaque = null, // 115
    CallStaticObjectMethodA: ?*const fn (JniEnv, JClass, JMethodId, ?*const JValue) callconv(.c) JObject = null, // 116
    /// 117 to 162: the other static calls, and the static fields.
    unused_117: [46]?*anyopaque = @splat(null),
    NewString: ?*const fn (JniEnv, [*]const u16, i32) callconv(.c) JObject = null, // 163
    GetStringLength: ?*const fn (JniEnv, JObject) callconv(.c) i32 = null, // 164
    GetStringChars: ?*const fn (JniEnv, JObject, ?*u8) callconv(.c) ?[*]const u16 = null, // 165
    ReleaseStringChars: ?*const fn (JniEnv, JObject, [*]const u16) callconv(.c) void = null, // 166
    /// Modified UTF-8, which is not UTF-8: a character above U+FFFF is two
    /// surrogates of three bytes each, and a real four-byte sequence is refused
    /// or corrupted. Only ever handed ASCII here; text goes through `NewString`.
    NewStringUTF: ?*const fn (JniEnv, [*:0]const u8) callconv(.c) JObject = null, // 167
    /// 168 to 170: the modified-UTF-8 reads, which this backend never makes.
    unused_168: [3]?*anyopaque = @splat(null),
    GetArrayLength: ?*const fn (JniEnv, JObject) callconv(.c) i32 = null, // 171
    NewObjectArray: ?*const fn (JniEnv, i32, JClass, JObject) callconv(.c) JObject = null, // 172
    GetObjectArrayElement: ?*const fn (JniEnv, JObject, i32) callconv(.c) JObject = null, // 173
    SetObjectArrayElement: ?*const fn (JniEnv, JObject, i32, JObject) callconv(.c) void = null, // 174
    /// 175 to 214: the primitive arrays.
    unused_175: [40]?*anyopaque = @splat(null),
    RegisterNatives: ?*const fn (JniEnv, JClass, [*]const NativeMethod, i32) callconv(.c) i32 = null, // 215
};

/// `JNINativeMethod`: a Java `native` method, and the C function behind it.
pub const NativeMethod = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    function: *const anyopaque,
};

/// `jvalue`, the union an array-form call takes its arguments as.
pub const JValue = extern union {
    z: u8,
    b: i8,
    c: u16,
    s: i16,
    i: i32,
    j: i64,
    f: f32,
    d: f64,
    l: JObject,
};

/// Clear anything the VM threw.
///
/// A pending exception makes the *next* JNI call abort the process, so this
/// runs after every call that can throw - which, in JNI, is most of them.
pub fn clearException(env: JniEnv) void {
    _ = threw(env);
}

/// The same, saying whether there was anything to clear.
pub fn threw(env: JniEnv) bool {
    const occurred = env.*.ExceptionOccurred orelse return false;
    const clear = env.*.ExceptionClear orelse return false;
    if (occurred(env) == null) return false;
    clear(env);
    return true;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "the JNI slots are where the specification puts them" {
    const size = @sizeOf(usize);
    const slots = .{
        .{ "FindClass", 6 },
        .{ "ExceptionOccurred", 15 },
        .{ "ExceptionClear", 17 },
        .{ "PushLocalFrame", 19 },
        .{ "PopLocalFrame", 20 },
        .{ "NewGlobalRef", 21 },
        .{ "DeleteGlobalRef", 22 },
        .{ "DeleteLocalRef", 23 },
        .{ "NewObjectA", 30 },
        .{ "GetObjectClass", 31 },
        .{ "GetMethodID", 33 },
        .{ "CallObjectMethodA", 36 },
        .{ "CallBooleanMethodA", 39 },
        .{ "CallIntMethodA", 51 },
        .{ "CallVoidMethodA", 63 },
        .{ "GetStaticMethodID", 113 },
        .{ "CallStaticObjectMethodA", 116 },
        .{ "NewString", 163 },
        .{ "GetStringLength", 164 },
        .{ "GetStringChars", 165 },
        .{ "ReleaseStringChars", 166 },
        .{ "NewStringUTF", 167 },
        .{ "GetArrayLength", 171 },
        .{ "NewObjectArray", 172 },
        .{ "GetObjectArrayElement", 173 },
        .{ "SetObjectArrayElement", 174 },
        .{ "RegisterNatives", 215 },
    };
    inline for (slots) |slot| {
        try testing.expectEqual(slot[1] * size, @offsetOf(NativeInterface, slot[0]));
    }
    try testing.expectEqual(216 * size, @sizeOf(NativeInterface));

    try testing.expectEqual(4 * size, @offsetOf(InvokeInterface, "AttachCurrentThread"));
    try testing.expectEqual(5 * size, @offsetOf(InvokeInterface, "DetachCurrentThread"));
}

test "a jvalue is one machine word, as the array form expects" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(JValue));
}
