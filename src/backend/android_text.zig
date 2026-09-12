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
//! The JNI tables themselves are in `jni`, which the clipboard shares.

const std = @import("std");

const jni = @import("jni.zig");

pub const JavaVm = jni.JavaVm;
pub const JniEnv = jni.JniEnv;
const JObject = jni.JObject;
const JMethodId = jni.JMethodId;
const JValue = jni.JValue;
const jni_ok = jni.ok;
const clearException = jni.clearException;

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

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a backend that never attached produces nothing rather than crashing" {
    var backend: Backend = .{};
    try testing.expect(!backend.ready());

    // Every one of these has to notice there is no VM. On a device the first
    // failure would be a call through a null function pointer.
    try testing.expectEqual(@as(u21, 0), backend.unicodeChar(0, 29, 0));
    backend.close();
    try testing.expect(!backend.ready());
}
