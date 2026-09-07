// SPDX-License-Identifier: BSL-1.0

//! What a key types on Android, through JNI.
//!
//! **The NDK will not tell you.** There is `AKeyEvent_getKeyCode` and there is
//! `AKeyEvent_getMetaState`, and there is nothing that turns the two into a
//! character. The table that does it - `KeyCharacterMap`, which knows that this
//! device's layout puts `@` on shift-2 - lives in Java and has never been
//! exposed to C. So this file reaches for it: attach the thread to the VM, find
//! `android.view.KeyEvent`, and call `getUnicodeChar(int)` on the event that
//! just arrived.
//!
//! That is a real dependency on the VM from a background thread, and it is
//! written the careful way: the thread attaches once and detaches when the
//! program ends, every local reference is released, and every step is checked -
//! a failure anywhere means no text, never a crash.
//!
//! **This covers a keyboard, not an input method.** A hardware keyboard, and a
//! soft keyboard typing plain characters, both arrive as key events and go
//! through here. Composing Japanese on a soft keyboard does not: that needs an
//! `InputConnection`, which a `NativeActivity` does not provide, and getting one
//! means a Java subclass rather than a few JNI calls. A program that needs it
//! should host its own `EditText` and feed this library.
//!
//! **The JNI function table is indexed by position.** `JNINativeInterface` is a
//! struct of function pointers whose order is fixed by the specification and has
//! not changed since 1.6, so the slots below are named where they are used and
//! padded where they are not. One field out of place calls the wrong function
//! with the wrong arguments, which is why the count is asserted in a test.

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
pub const JavaVm = *const *const JniInvokeInterface;
pub const JniEnv = *const *const JniNativeInterface;
const JObject = ?*anyopaque;
const JClass = JObject;
const JMethodId = ?*anyopaque;

/// `JNI_VERSION_1_6`, which is what every Android since 2.3 answers to.
const jni_version_1_6: i32 = 0x00010006;
const jni_ok: i32 = 0;

/// `JavaVM`'s own table. Three reserved slots come first, which is the
/// specification's own layout and not padding this file invented.
const JniInvokeInterface = extern struct {
    reserved0: ?*anyopaque = null,
    reserved1: ?*anyopaque = null,
    reserved2: ?*anyopaque = null,

    DestroyJavaVM: ?*const fn (JavaVm) callconv(.c) i32 = null,
    AttachCurrentThread: ?*const fn (JavaVm, *JniEnv, ?*anyopaque) callconv(.c) i32 = null,
    DetachCurrentThread: ?*const fn (JavaVm) callconv(.c) i32 = null,
    GetEnv: ?*const fn (JavaVm, *?*anyopaque, i32) callconv(.c) i32 = null,
    AttachCurrentThreadAsDaemon: ?*const fn (JavaVm, *JniEnv, ?*anyopaque) callconv(.c) i32 = null,
};

/// `JNIEnv`'s table, as far as the calls this file makes.
///
/// Four reserved slots, then every function in specification order. Only the
/// five that are used are named; the rest are pointers with no signature,
/// which is enough to put the named ones at the right offsets.
const JniNativeInterface = extern struct {
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
    PushLocalFrame: ?*anyopaque = null, // 19
    PopLocalFrame: ?*anyopaque = null, // 20
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
    GetObjectClass: ?*anyopaque = null, // 31
    IsInstanceOf: ?*anyopaque = null, // 32
    GetMethodID: ?*const fn (JniEnv, JClass, [*:0]const u8, [*:0]const u8) callconv(.c) JMethodId = null, // 33
    CallObjectMethod: ?*anyopaque = null, // 34
    CallObjectMethodV: ?*anyopaque = null, // 35
    CallObjectMethodA: ?*anyopaque = null, // 36
    CallBooleanMethod: ?*anyopaque = null, // 37
    CallBooleanMethodV: ?*anyopaque = null, // 38
    CallBooleanMethodA: ?*anyopaque = null, // 39
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
    /// The array form, because the variadic ones cannot be called portably
    /// from Zig - and because an array of `jvalue` is what this needs anyway.
    CallIntMethodA: ?*const fn (JniEnv, JObject, JMethodId, ?*const JValue) callconv(.c) i32 = null, // 51
};

/// `jvalue`, the union an array-form call takes its arguments as.
const JValue = extern union {
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

/// A thread attached to the VM, and the two things looked up on it.
///
/// Built once, on the first key that needs it, and torn down with the context.
/// Every field being present is what `ready` means; anything missing leaves the
/// whole thing off and text simply does not arrive.
pub const Backend = struct {
    vm: ?JavaVm = null,
    env: ?JniEnv = null,
    attached: bool = false,

    /// A global reference, because a local one dies at the end of the call
    /// that made it and this is kept for the life of the program.
    key_event_class: JObject = null,
    get_unicode_char: JMethodId = null,
    /// `KeyEvent(long downTime, long eventTime, int action, int code,
    /// int repeat, int metaState)`, which is how an event is rebuilt from the
    /// numbers the NDK hands over.
    constructor: JMethodId = null,

    pub fn ready(self: *const Backend) bool {
        return self.env != null and self.get_unicode_char != null and self.constructor != null;
    }

    /// Attach to the VM and find `KeyEvent.getUnicodeChar`.
    ///
    /// Returns false and leaves everything null if any step fails, which is
    /// the only failure mode this has: no text, and nothing broken.
    pub fn open(self: *Backend, vm: JavaVm) bool {
        if (self.ready()) return true;
        self.vm = vm;

        const attach = vm.*.AttachCurrentThread orelse return false;
        var env: JniEnv = undefined;
        if (attach(vm, &env, null) != jni_ok) return false;
        self.env = env;
        self.attached = true;

        const find = env.*.FindClass orelse return self.giveUp();
        const get_method = env.*.GetMethodID orelse return self.giveUp();
        const new_global = env.*.NewGlobalRef orelse return self.giveUp();
        const delete_local = env.*.DeleteLocalRef orelse return self.giveUp();

        const local = find(env, "android/view/KeyEvent") orelse return self.giveUp();
        defer delete_local(env, local);
        clearException(env);

        const global = new_global(env, local) orelse return self.giveUp();
        self.key_event_class = global;

        self.constructor = get_method(env, global, "<init>", "(JJIIII)V");
        clearException(env);
        self.get_unicode_char = get_method(env, global, "getUnicodeChar", "(I)I");
        clearException(env);

        if (!self.ready()) return self.giveUp();
        return true;
    }

    fn giveUp(self: *Backend) bool {
        self.close();
        return false;
    }

    pub fn close(self: *Backend) void {
        if (self.env) |env| {
            if (self.key_event_class) |class| {
                if (env.*.DeleteGlobalRef) |delete| delete(env, class);
            }
        }
        if (self.attached) {
            if (self.vm) |vm| {
                if (vm.*.DetachCurrentThread) |detach| _ = detach(vm);
            }
        }
        self.* = .{};
    }

    /// The character a key press types, or zero for one that types nothing.
    ///
    /// A `KeyEvent` is built rather than passed in, because the NDK's
    /// `AInputEvent` is a native struct with no Java object behind it. The six
    /// numbers below are all `getUnicodeChar` reads.
    pub fn unicodeChar(self: *Backend, action: i32, code: i32, meta: i32) u21 {
        if (!self.ready()) return 0;
        const env = self.env.?;

        const new_object = env.*.NewObjectA orelse return 0;
        const call_int = env.*.CallIntMethodA orelse return 0;
        const delete_local = env.*.DeleteLocalRef orelse return 0;

        const args = [_]JValue{
            .{ .j = 0 }, // downTime, which getUnicodeChar does not read
            .{ .j = 0 }, // eventTime, likewise
            .{ .i = action },
            .{ .i = code },
            .{ .i = 0 }, // repeat count
            .{ .i = meta },
        };
        const object = new_object(env, self.key_event_class, self.constructor, &args[0]) orelse {
            clearException(env);
            return 0;
        };
        defer delete_local(env, object);
        clearException(env);

        const meta_arg = [_]JValue{.{ .i = meta }};
        const result = call_int(env, object, self.get_unicode_char, &meta_arg[0]);
        clearException(env);

        // Negative means a dead key - the accent is waiting for the next
        // keystroke. Combining it needs `KeyCharacterMap.getDeadChar`, which is
        // another lookup and another call; for now a dead key types nothing,
        // which is better than typing the accent on its own.
        if (result <= 0) return 0;
        if (result > 0x10FFFF) return 0;
        return @intCast(result);
    }
};

/// Clear anything the VM threw.
///
/// A pending exception makes the *next* JNI call abort the process, so this
/// runs after every call that can throw - which, in JNI, is most of them.
fn clearException(env: JniEnv) void {
    const occurred = env.*.ExceptionOccurred orelse return;
    const clear = env.*.ExceptionClear orelse return;
    if (occurred(env) != null) clear(env);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "the JNI slots are where the specification puts them" {
    // Indexed by position, so a field in the wrong place calls a different
    // function than the name says. These four offsets are the whole risk.
    const size = @sizeOf(usize);
    try testing.expectEqual(6 * size, @offsetOf(JniNativeInterface, "FindClass"));
    try testing.expectEqual(15 * size, @offsetOf(JniNativeInterface, "ExceptionOccurred"));
    try testing.expectEqual(17 * size, @offsetOf(JniNativeInterface, "ExceptionClear"));
    try testing.expectEqual(21 * size, @offsetOf(JniNativeInterface, "NewGlobalRef"));
    try testing.expectEqual(22 * size, @offsetOf(JniNativeInterface, "DeleteGlobalRef"));
    try testing.expectEqual(23 * size, @offsetOf(JniNativeInterface, "DeleteLocalRef"));
    try testing.expectEqual(30 * size, @offsetOf(JniNativeInterface, "NewObjectA"));
    try testing.expectEqual(33 * size, @offsetOf(JniNativeInterface, "GetMethodID"));
    try testing.expectEqual(51 * size, @offsetOf(JniNativeInterface, "CallIntMethodA"));

    // And the VM table, where three reserved slots come first.
    try testing.expectEqual(4 * size, @offsetOf(JniInvokeInterface, "AttachCurrentThread"));
    try testing.expectEqual(5 * size, @offsetOf(JniInvokeInterface, "DetachCurrentThread"));
}

test "a jvalue is one machine word, as the array form expects" {
    // Every argument in an array-form call is this size, so a struct that came
    // out larger would misalign every argument after the first.
    try testing.expectEqual(@as(usize, 8), @sizeOf(JValue));
}

test "a backend that never attached produces nothing rather than crashing" {
    var backend: Backend = .{};
    try testing.expect(!backend.ready());

    // Every one of these has to notice there is no VM. On a device the first
    // failure would be a call through a null function pointer.
    try testing.expectEqual(@as(u21, 0), backend.unicodeChar(0, 29, 0));
    backend.close();
    try testing.expect(!backend.ready());
}
