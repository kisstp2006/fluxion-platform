// SPDX-License-Identifier: BSL-1.0

//! The Android backend: `libandroid.so`, and the glue that makes a `main`
//! possible.
//!
//! Android does not call `main`. It loads the program as a shared library and
//! calls `ANativeActivity_onCreate` on the UI thread, then delivers every
//! lifecycle change as another call on that same thread. A loop that ran there
//! would stop the system talking to the activity, and the app would be killed
//! for not responding.
//!
//! So this file is also the glue: `ANativeActivity_onCreate` starts a thread,
//! runs the program's `main` on it, and turns each UI-thread callback into a
//! command down a pipe that `pump` reads from the app's own thread. That is
//! what `android_native_app_glue` does in C, written here in Zig so that
//! nothing has to be compiled out of the NDK.
//!
//! **The window is not yours.** `ANativeWindow` is created when the activity
//! becomes visible and destroyed when it stops - on rotation, on going to the
//! background - while the process keeps running. `createWindow` therefore does
//! not create anything: it hands back the one window the activity has, and the
//! surface underneath it comes and goes as `.surface_created` and
//! `.surface_lost`.
//!
//! **A destroy has to be answered before it returns.** When the system says the
//! window is going, it waits for the app to say it has let go - so `pump` sends
//! `.surface_lost`, and the UI thread stays blocked until the next `pump`, by
//! which time the frame that handled it has finished. Releasing a swapchain on
//! that event is not advice here; it is the contract.
//!
//! **Keys are Android's own numbering**, not evdev. A phone has no physical
//! keyboard to have positions on, and `AKEYCODE_A` is what arrives whatever is
//! attached, so that is what the table maps.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const dyn = @import("fluxion_dyn");

const backend = @import("../backend.zig");
const event = @import("../event.zig");
const monitor = @import("../monitor.zig");
const gamepad = @import("../gamepad.zig");
const android_gamepad = @import("android_gamepad.zig");
const egl = @import("egl.zig");
const gl = @import("../gl.zig");
const vulkan = @import("../vulkan.zig");
const text_mod = @import("../text.zig");
const android_text = @import("android_text.zig");
const android_clipboard = @import("android_clipboard.zig");
const android_dialog = @import("android_dialog.zig");
const jni = @import("jni.zig");
const virtual_key = @import("virtual_key.zig");
const keys = @import("../keys.zig");
const platform = @import("../platform.zig");
const cursor_mod = @import("../cursor.zig");

const Error = platform.Error;

/// Where any of this can run.
pub const is_android = builtin.abi.isAndroid();

const c = struct {
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn poll(fds: [*]Pollfd, nfds: c_ulong, timeout: c_int) c_int;
};

const Pollfd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};

const pollin: c_short = 0x001;

// -------------------------------------------------------------------------
// The slice of the NDK this backend speaks
// -------------------------------------------------------------------------

const ANativeWindow = opaque {};
const AInputQueue = opaque {};
const AInputEvent = opaque {};
const ALooper = opaque {};
const AAssetManager = opaque {};
const ARect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Every callback the system makes, in declaration order. The order is the
/// struct layout, so one field out of place calls the wrong function with the
/// wrong arguments.
pub const ANativeActivityCallbacks = extern struct {
    onStart: ?*const fn (*ANativeActivity) callconv(.c) void = null,
    onResume: ?*const fn (*ANativeActivity) callconv(.c) void = null,
    onSaveInstanceState: ?*const fn (*ANativeActivity, *usize) callconv(.c) ?*anyopaque = null,
    onPause: ?*const fn (*ANativeActivity) callconv(.c) void = null,
    onStop: ?*const fn (*ANativeActivity) callconv(.c) void = null,
    onDestroy: ?*const fn (*ANativeActivity) callconv(.c) void = null,
    onWindowFocusChanged: ?*const fn (*ANativeActivity, c_int) callconv(.c) void = null,
    onNativeWindowCreated: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void = null,
    onNativeWindowResized: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void = null,
    onNativeWindowRedrawNeeded: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void = null,
    onNativeWindowDestroyed: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void = null,
    onInputQueueCreated: ?*const fn (*ANativeActivity, *AInputQueue) callconv(.c) void = null,
    onInputQueueDestroyed: ?*const fn (*ANativeActivity, *AInputQueue) callconv(.c) void = null,
    onContentRectChanged: ?*const fn (*ANativeActivity, *const ARect) callconv(.c) void = null,
    onConfigurationChanged: ?*const fn (*ANativeActivity) callconv(.c) void = null,
    onLowMemory: ?*const fn (*ANativeActivity) callconv(.c) void = null,
};

pub const ANativeActivity = extern struct {
    callbacks: *ANativeActivityCallbacks,
    vm: ?*anyopaque,
    env: ?*anyopaque,
    clazz: ?*anyopaque,
    internalDataPath: ?[*:0]const u8,
    externalDataPath: ?[*:0]const u8,
    sdkVersion: i32,
    /// Ours, and the only field the system promises not to touch.
    instance: ?*anyopaque,
    assetManager: ?*AAssetManager,
    obbPath: ?[*:0]const u8,
};

const looper_prepare_allow_non_callbacks: c_int = 1 << 0;
const looper_poll_wake: c_int = -1;
const looper_poll_callback: c_int = -2;
const looper_poll_timeout: c_int = -3;
const looper_poll_error: c_int = -4;
const looper_event_input: c_int = 1 << 0;

/// `ANATIVEACTIVITY_SHOW_SOFT_INPUT_IMPLICIT`: the keyboard appears because a
/// text field has focus, rather than because the user asked for it. Implicit is
/// right here - the program said a field has focus, not that a person tapped a
/// keyboard button - and it is what lets the system take the keyboard away
/// again on its own.
const show_soft_input_implicit: u32 = 0x0001;
/// `ANATIVEACTIVITY_HIDE_SOFT_INPUT_NOT_ALWAYS`: hide it unless the user
/// pinned it open.
const hide_soft_input_not_always: u32 = 0x0001;

const input_event_type_key: i32 = 1;
const input_event_type_motion: i32 = 2;

const key_action_down: i32 = 0;
const key_action_up: i32 = 1;

const motion_action_mask: i32 = 0xff;
const motion_action_down: i32 = 0;
const motion_action_up: i32 = 1;
const motion_action_move: i32 = 2;
const motion_action_cancel: i32 = 3;
const motion_action_pointer_down: i32 = 5;
const motion_action_pointer_up: i32 = 6;

const meta_shift_on: i32 = 0x01;
const meta_alt_on: i32 = 0x02;
const meta_ctrl_on: i32 = 0x1000;
const meta_meta_on: i32 = 0x10000;
const meta_caps_lock_on: i32 = 0x100000;
const meta_num_lock_on: i32 = 0x200000;

/// The identifiers the two sources are attached under, so a poll can say which
/// one woke it.
const ident_cmd: c_int = 1;
const ident_input: c_int = 2;

const Android = struct {
    ALooper_prepare: *const fn (c_int) callconv(.c) ?*ALooper,
    ALooper_pollOnce: *const fn (c_int, ?*c_int, ?*c_int, ?*?*anyopaque) callconv(.c) c_int,
    ALooper_wake: *const fn (*ALooper) callconv(.c) void,
    ALooper_addFd: *const fn (*ALooper, c_int, c_int, c_int, ?*const anyopaque, ?*anyopaque) callconv(.c) c_int,
    ALooper_removeFd: *const fn (*ALooper, c_int) callconv(.c) c_int,

    ANativeWindow_acquire: *const fn (*ANativeWindow) callconv(.c) void,
    ANativeWindow_release: *const fn (*ANativeWindow) callconv(.c) void,
    ANativeWindow_getWidth: *const fn (*ANativeWindow) callconv(.c) i32,
    ANativeWindow_getHeight: *const fn (*ANativeWindow) callconv(.c) i32,
    /// Tell the surface which pixel format to allocate. EGL picks a config and
    /// that config names a format; a surface allocated in a different one is a
    /// `BAD_MATCH` from `eglCreateWindowSurface`, so this has to be said before
    /// the surface is made and cannot be said after.
    ANativeWindow_setBuffersGeometry: *const fn (*ANativeWindow, i32, i32, i32) callconv(.c) i32,

    /// The soft keyboard. The one piece of input-method control the NDK does
    /// offer, and the only one a `NativeActivity` needs: everything else about
    /// composing text happens inside the keyboard's own process.
    ANativeActivity_showSoftInput: *const fn (*ANativeActivity, u32) callconv(.c) void,
    ANativeActivity_hideSoftInput: *const fn (*ANativeActivity, u32) callconv(.c) void,

    AInputQueue_attachLooper: *const fn (*AInputQueue, *ALooper, c_int, ?*const anyopaque, ?*anyopaque) callconv(.c) void,
    AInputQueue_detachLooper: *const fn (*AInputQueue) callconv(.c) void,
    AInputQueue_getEvent: *const fn (*AInputQueue, *?*AInputEvent) callconv(.c) i32,
    AInputQueue_finishEvent: *const fn (*AInputQueue, *AInputEvent, c_int) callconv(.c) void,

    AInputEvent_getType: *const fn (*const AInputEvent) callconv(.c) i32,
    AKeyEvent_getAction: *const fn (*const AInputEvent) callconv(.c) i32,
    AKeyEvent_getKeyCode: *const fn (*const AInputEvent) callconv(.c) i32,
    AKeyEvent_getScanCode: *const fn (*const AInputEvent) callconv(.c) i32,
    AKeyEvent_getMetaState: *const fn (*const AInputEvent) callconv(.c) i32,
    AMotionEvent_getAction: *const fn (*const AInputEvent) callconv(.c) i32,
    AMotionEvent_getX: *const fn (*const AInputEvent, usize) callconv(.c) f32,
    AMotionEvent_getY: *const fn (*const AInputEvent, usize) callconv(.c) f32,
    AMotionEvent_getPointerCount: *const fn (*const AInputEvent) callconv(.c) usize,
    /// Which device sent it and what kind of thing that device is, so a
    /// controller's events can be told from a touchscreen's.
    AInputEvent_getDeviceId: *const fn (*const AInputEvent) callconv(.c) i32,
    AInputEvent_getSource: *const fn (*const AInputEvent) callconv(.c) i32,
    /// Any axis by number, which is the only way to read a stick: `getX` and
    /// `getY` are the touchscreen's two and nothing else.
    AMotionEvent_getAxisValue: *const fn (*const AInputEvent, i32, usize) callconv(.c) f32,

    /// The device's configuration, which is where the screen density lives.
    /// Optional as a group: a program that never asks for a monitor does not
    /// need them, and an old device that lacks one still runs.
    AConfiguration_new: ?*const fn () callconv(.c) ?*AConfiguration = null,
    AConfiguration_delete: ?*const fn (*AConfiguration) callconv(.c) void = null,
    AConfiguration_fromAssetManager: ?*const fn (*AConfiguration, *AAssetManager) callconv(.c) void = null,
    AConfiguration_getDensity: ?*const fn (*AConfiguration) callconv(.c) i32 = null,
};

const AConfiguration = opaque {};

/// `ACONFIGURATION_DENSITY_DEFAULT`: 160 dots per inch is what Android calls a
/// scale of one, and every other density is a multiple of it.
const density_default: f32 = 160.0;
/// The two values that are not a number of dots per inch but a request.
const density_any: i32 = 0xfffe;
const density_none: i32 = 0;

const candidates: []const [:0]const u8 = &.{ "libandroid.so", "libandroid.so.0" };

// -------------------------------------------------------------------------
// The glue
//
// Two threads. The system's, which makes the callbacks, and the program's,
// which runs `main`. Everything crosses between them as a one-byte command
// down a pipe, with a mutex around the handful of values that travel with it.
// -------------------------------------------------------------------------

/// What the UI thread tells the app thread.
pub const Cmd = enum(u8) {
    start,
    resume_,
    pause,
    stop,
    destroy,
    window_created,
    window_resized,
    window_redraw,
    window_destroyed,
    input_created,
    input_destroyed,
    focus_gained,
    focus_lost,
    low_memory,
    config_changed,
    /// A file dialog's answer is in `Glue.answer`.
    dialog_answered,
    _,
};

/// The state the two threads share. One per process, because one process is
/// one activity.
///
/// Two pipes and a handful of atomics, and no mutex: `std.Io.Mutex` wants an
/// `Io` to work through, and a callback the system makes on its own thread has
/// none to give. Pipes are what this needs anyway - one carries the command,
/// the other carries the acknowledgement, and the read on each is the ordering
/// that makes the pointers safe to hand across.
pub const Glue = struct {
    activity: ?*ANativeActivity = null,

    /// Set by the UI thread just before the command that announces it, and read
    /// by the app thread just after. The pipe between the two is the barrier.
    pending_window: std.atomic.Value(usize) = .init(0),
    pending_input: std.atomic.Value(usize) = .init(0),

    /// What the app thread is using now.
    window: std.atomic.Value(usize) = .init(0),
    input: std.atomic.Value(usize) = .init(0),

    destroyed: std.atomic.Value(bool) = .init(false),
    focused: std.atomic.Value(bool) = .init(false),

    /// Whether the program's `main` is still running.
    ///
    /// Every waited command needs it. When `main` returns there is nobody left
    /// to read the pipe, and a UI thread that kept waiting for an
    /// acknowledgement would block the system out of the activity for good -
    /// which is an ANR, and which is what a device shows and a desktop never
    /// would.
    app_running: std.atomic.Value(bool) = .init(false),

    /// The last file dialog's answer, as an `*android_dialog.Answer`, set by
    /// the Java thread that heard it just before `.dialog_answered`.
    answer: std.atomic.Value(usize) = .init(0),

    /// UI thread writes commands, app thread reads them.
    cmd_pipe: [2]c_int = .{ -1, -1 },
    /// App thread writes one byte back, UI thread reads it. This is what makes
    /// a destroy wait for the surface to be let go.
    ack_pipe: [2]c_int = .{ -1, -1 },

    pub fn writeCmd(self: *Glue, cmd: Cmd) void {
        const byte = [_]u8{@intFromEnum(cmd)};
        _ = c.write(self.cmd_pipe[1], &byte, 1);
    }

    /// Send a command and block until the app thread says it is done.
    ///
    /// The system requires this for the window going away, and requires it
    /// before the callback returns - which is what makes releasing a swapchain
    /// on `.surface_lost` sufficient rather than merely advisable.
    pub fn writeCmdAndWait(self: *Glue, cmd: Cmd) void {
        self.writeCmd(cmd);
        if (self.ack_pipe[0] < 0) return;
        // Nobody is reading, so nobody will answer. Send it and carry on.
        if (!self.app_running.load(.acquire)) return;

        var byte: [1]u8 = undefined;
        while (true) {
            const n = c.read(self.ack_pipe[0], &byte, 1);
            if (n == 1) return;
            // A read cut short by a signal is not an answer; anything else
            // means the pipe has gone and waiting longer would never end.
            if (n < 0) continue else return;
        }
    }

    pub fn ack(self: *Glue) void {
        if (self.ack_pipe[1] < 0) return;
        const byte = [_]u8{0};
        _ = c.write(self.ack_pipe[1], &byte, 1);
    }

    fn take(value: *std.atomic.Value(usize), comptime T: type) ?*T {
        const raw = value.load(.acquire);
        if (raw == 0) return null;
        return @ptrFromInt(raw);
    }

    fn set(value: *std.atomic.Value(usize), pointer: ?*anyopaque) void {
        value.store(if (pointer) |p| @intFromPtr(p) else 0, .release);
    }
};

/// The one activity this process has.
var glue: Glue = .{};

// -------------------------------------------------------------------------
// The callbacks, all on the UI thread
// -------------------------------------------------------------------------

fn onStart(activity: *ANativeActivity) callconv(.c) void {
    _ = activity;
    glue.writeCmd(.start);
}

fn onResume(activity: *ANativeActivity) callconv(.c) void {
    _ = activity;
    glue.writeCmd(.resume_);
}

fn onPause(activity: *ANativeActivity) callconv(.c) void {
    _ = activity;
    glue.writeCmd(.pause);
}

fn onStop(activity: *ANativeActivity) callconv(.c) void {
    _ = activity;
    glue.writeCmd(.stop);
}

fn onDestroy(activity: *ANativeActivity) callconv(.c) void {
    _ = activity;
    glue.writeCmdAndWait(.destroy);
}

fn onSaveInstanceState(activity: *ANativeActivity, out_size: *usize) callconv(.c) ?*anyopaque {
    _ = activity;
    out_size.* = 0;
    return null;
}

fn onWindowFocusChanged(activity: *ANativeActivity, has_focus: c_int) callconv(.c) void {
    _ = activity;
    glue.writeCmd(if (has_focus != 0) .focus_gained else .focus_lost);
}

fn onNativeWindowCreated(activity: *ANativeActivity, window: *ANativeWindow) callconv(.c) void {
    _ = activity;
    // Set before the command that announces it: the pipe between the two
    // threads is what orders the store against the load.
    Glue.set(&glue.pending_window, window);
    glue.writeCmdAndWait(.window_created);
}

fn onNativeWindowResized(activity: *ANativeActivity, window: *ANativeWindow) callconv(.c) void {
    _ = .{ activity, window };
    glue.writeCmd(.window_resized);
}

fn onNativeWindowRedrawNeeded(activity: *ANativeActivity, window: *ANativeWindow) callconv(.c) void {
    _ = .{ activity, window };
    glue.writeCmdAndWait(.window_redraw);
}

/// The one the whole design turns on.
///
/// The system will unmap the surface as soon as this returns, so it does not
/// return until the app thread has produced `.surface_lost` and finished the
/// frame that handled it.
fn onNativeWindowDestroyed(activity: *ANativeActivity, window: *ANativeWindow) callconv(.c) void {
    _ = .{ activity, window };
    glue.writeCmdAndWait(.window_destroyed);
}

fn onInputQueueCreated(activity: *ANativeActivity, queue: *AInputQueue) callconv(.c) void {
    _ = activity;
    Glue.set(&glue.pending_input, queue);
    glue.writeCmdAndWait(.input_created);
}

fn onInputQueueDestroyed(activity: *ANativeActivity, queue: *AInputQueue) callconv(.c) void {
    _ = .{ activity, queue };
    glue.writeCmdAndWait(.input_destroyed);
}

fn onContentRectChanged(activity: *ANativeActivity, rect: *const ARect) callconv(.c) void {
    _ = .{ activity, rect };
}

fn onConfigurationChanged(activity: *ANativeActivity) callconv(.c) void {
    _ = activity;
    glue.writeCmd(.config_changed);
}

fn onLowMemory(activity: *ANativeActivity) callconv(.c) void {
    _ = activity;
    glue.writeCmd(.low_memory);
}

var callbacks: ANativeActivityCallbacks = .{
    .onStart = onStart,
    .onResume = onResume,
    .onSaveInstanceState = onSaveInstanceState,
    .onPause = onPause,
    .onStop = onStop,
    .onDestroy = onDestroy,
    .onWindowFocusChanged = onWindowFocusChanged,
    .onNativeWindowCreated = onNativeWindowCreated,
    .onNativeWindowResized = onNativeWindowResized,
    .onNativeWindowRedrawNeeded = onNativeWindowRedrawNeeded,
    .onNativeWindowDestroyed = onNativeWindowDestroyed,
    .onInputQueueCreated = onInputQueueCreated,
    .onInputQueueDestroyed = onInputQueueDestroyed,
    .onContentRectChanged = onContentRectChanged,
    .onConfigurationChanged = onConfigurationChanged,
    .onLowMemory = onLowMemory,
};

/// What Android calls instead of `main`.
///
/// Exported by the library, so a program that links this gets an entry point
/// the system recognises without writing one. It fills in the callbacks, opens
/// the command pipe, and starts the thread the program's own `main` runs on.
pub fn nativeActivityOnCreate(
    activity: *ANativeActivity,
    saved_state: ?*anyopaque,
    saved_size: usize,
) callconv(.c) void {
    _ = .{ saved_state, saved_size };

    activity.callbacks.* = callbacks;
    activity.instance = &glue;

    // A process can outlive its activity and be handed a new one. Nothing the
    // last one left behind - its window, its input queue, having been
    // destroyed - belongs to this one. Its pipes are left open rather than
    // closed: its thread may still be writing its last answer into them.
    glue = .{ .activity = activity };
    var cmd_fds: [2]c_int = .{ -1, -1 };
    var ack_fds: [2]c_int = .{ -1, -1 };
    if (c.pipe(&cmd_fds) != 0) return;
    if (c.pipe(&ack_fds) != 0) return;
    glue.cmd_pipe = cmd_fds;
    glue.ack_pipe = ack_fds;

    // Here, on the UI thread, because `onActivityResult` comes on this thread
    // after this returns - even to an activity recreated to hear one.
    if (activity.env) |env| {
        _ = android_dialog.register(@ptrCast(@alignCast(env)), activity.clazz, &answered);
    }

    // The app's thread. Everything after this happens on two threads, and the
    // pipe is the only thing that crosses between them.
    const thread = std.Thread.spawn(.{}, appThread, .{}) catch return;
    thread.detach();
}

// The entry point Android looks for, under the name it looks for. Exported by
// the library rather than written by the program, so that linking this is all
// it takes to have one.
comptime {
    if (is_android) @export(&nativeActivityOnCreate, .{
        .name = "ANativeActivity_onCreate",
        .linkage = .strong,
    });
}

/// Where the program's `main` runs.
///
/// Declared by the program as `export fn fluxionMain() void` - not `main`,
/// because Android never calls one, and a program that has both should say
/// which is which.
extern fn fluxionMain() void;

fn appThread() void {
    glue.app_running.store(true, .release);
    fluxionMain();

    endActivity();
    glue.app_running.store(false, .release);
    // Answer anything the UI thread is waiting on right now.
    glue.ack();
}

/// Let go of the activity once the program's `main` has returned.
///
/// Before `app_running` goes false, which is what keeps a UI thread that is
/// tearing the activity down blocked in its callback, waiting on this one: the
/// input queue and the activity are still there to be let go of.
///
/// The input queue comes off this thread's looper first. Android keeps only a
/// bare pointer to the looper, which ends with this thread, and disposing the
/// queue later unregisters from it all the same - a use-after-free that
/// bionic aborts the process for. Then the activity is asked to finish: a
/// program whose `main` has returned is done, and leaving the activity up
/// would leave a window nothing draws into.
fn endActivity() void {
    var lib = dyn.Library.openAny(candidates) catch return;
    defer lib.close();

    if (Glue.take(&glue.input, AInputQueue)) |queue| {
        Glue.set(&glue.input, null);
        const detach = lib.lookup(*const fn (*AInputQueue) callconv(.c) void, "AInputQueue_detachLooper");
        if (detach) |f| f(queue);
    }

    const activity = liveActivity() orelse return;
    const finish = lib.lookup(*const fn (*ANativeActivity) callconv(.c) void, "ANativeActivity_finish") orelse return;
    finish(activity);
}

/// `FluxionActivity.answered`, on the Java thread that gathered the answer.
/// It is copied out and handed to the app thread the way a window is.
fn answered(env: jni.JniEnv, class: jni.JClass, id: i32, names: jni.JObject, uris: jni.JObject) callconv(.c) void {
    _ = class;
    const answer = android_dialog.Answer.fromJava(env, id, names, uris) orelse
        android_dialog.Answer.empty(id) orelse return;
    const earlier = glue.answer.swap(@intFromPtr(answer), .acq_rel);
    if (earlier != 0) @as(*android_dialog.Answer, @ptrFromInt(earlier)).destroy();
    glue.writeCmd(.dialog_answered);
}

/// The activity, while there is one.
///
/// Null once `onDestroy` has been answered: the system frees the activity as
/// soon as that callback returns, and a program that carries on after
/// `.close` must not reach it through the old pointer. Only the app thread
/// asks, and that thread marks the activity destroyed before it answers - so
/// what this hands out stays good until that thread next pumps.
fn liveActivity() ?*ANativeActivity {
    if (glue.destroyed.load(.acquire)) return null;
    return glue.activity;
}

// -------------------------------------------------------------------------
// The backend proper
// -------------------------------------------------------------------------

const Impl = struct {
    gpa: Allocator,
    lib: dyn.Library,
    a: Android,
    looper: *ALooper,
    /// The single window, handed out by `createWindow` and never created here.
    native: ?*Native = null,
    queue: ?*backend.Queue = null,
    push_failed: bool = false,

    /// Controllers, filled in from the input queue rather than enumerated -
    /// see `android_gamepad` for why there is no list to ask for.
    /// OpenGL ES, through EGL. The only kind of GL an Android driver has.
    gl: egl.Backend = .{},

    pads: android_gamepad.Backend = .{},

    /// What a key types, which only the VM knows - see `android_text`.
    /// Attached on the first key rather than at startup, so a program that
    /// never reads text never touches JNI.
    text: android_text.Backend = .{},
    /// The clipboard, over the same attachment. See `android_clipboard`.
    clipboard: android_clipboard.Backend = .{},
    /// The file dialog, over it too. See `android_dialog`.
    dialog: android_dialog.Backend = .{},
    /// The dialog that is open, until its answer arrives.
    dialog_open: ?event.DialogId = null,
    dialog_window: event.WindowId = .none,
    /// The last answer's URIs, beside the names it gave: what `chosenFile`
    /// reads. Kept until the next answer.
    chosen: std.ArrayListUnmanaged([]u8) = .empty,
    /// The last answer's names, kept until the next pump.
    answers: std.heap.ArenaAllocator,
    /// Nothing composes here: a `NativeActivity` has no `InputConnection`, so
    /// a soft keyboard commits whole characters and never reports a
    /// composition. Empty rather than null, because that is the truth.
    preedit: text_mod.Preedit = .{},
    devices: [gamepad.max_devices]gamepad.Device = @splat(.{}),
};

const Native = struct {
    id: event.WindowId,
    impl: *Impl,
    width: u32,
    height: u32,
    should_close: bool = false,

    /// What the program asked for, kept so that a surface lost and given back
    /// can be rebuilt with the same config. The context itself is null while
    /// there is no surface, which on Android is most of the time an app spends
    /// in the background.
    text_input: bool = false,
    gl_config: ?gl.Config = null,
    context: ?egl.Context = null,
};

pub const vtable: backend.Vtable = .{
    .backend = .android,
    .deinit = deinit,
    .createWindow = createWindow,
    .destroyWindow = destroyWindow,
    .pump = pump,
    .wait = wait,
    .post = post,
    .setTitle = setTitle,
    .setVisible = setVisible,
    .size = size,
    .framebufferSize = framebufferSize,
    .contentScale = contentScale,
    .nativeHandle = nativeHandle,
    .enumerateMonitors = enumerateMonitors,
    .pollGamepads = pollGamepads,
    .makeContextCurrent = makeContextCurrent,
    .clearContext = clearContext,
    .swapBuffers = swapBuffers,
    .setSwapInterval = setSwapInterval,
    .getProcAddress = getProcAddress,
    .contextConfig = contextConfig,
    .createVulkanSurface = createVulkanSurface,
    .setTextInput = setTextInput,
    .setTextInputArea = setTextInputArea,
    .preedit = preedit,
    .setClipboardText = setClipboardText,
    .clipboardText = clipboardText,
    .hasClipboardText = hasClipboardText,
    .showFileDialog = showFileDialog,
    .chosenFile = chosenFile,
    .setFullscreen = setFullscreen,
    .setCursorMode = setCursorMode,
    .setRawMouseMotion = setRawMouseMotion,
    .setCursorPos = setCursorPos,
    .setCursorShape = setCursorShape,
    .position = position,
    .setPosition = setPosition,
    .setSize = setSize,
    .setState = setState,
    .getState = getState,
    .setSizeLimits = setSizeLimits,
    .setOpacity = setOpacity,
};

pub fn open(gpa: Allocator) Error!backend.Impl {
    if (comptime !is_android) return error.Unsupported;

    const self = gpa.create(Impl) catch return error.OutOfMemory;
    errdefer gpa.destroy(self);

    var lib = dyn.Library.openAny(candidates) catch return error.NoDisplay;
    errdefer lib.close();

    const a = lib.bind(Android) catch return error.NoDisplay;

    // The looper for this thread, which is the app thread. Non-callback events
    // are what `pump` reads, so they have to be allowed.
    const looper = a.ALooper_prepare(looper_prepare_allow_non_callbacks) orelse
        return error.ConnectionFailed;

    self.* = .{
        .gpa = gpa,
        .lib = lib,
        .a = a,
        .looper = looper,
        .answers = .init(gpa),
    };

    // Without the pipe there is no glue, which means the program was started
    // some way other than through `ANativeActivity_onCreate`.
    if (glue.cmd_pipe[0] < 0) return error.ConnectionFailed;

    // The command pipe goes on the looper rather than being polled on its own,
    // because the input queue is on there too - and it is the looper that
    // services the queue's channel. Polling the pipe directly would read every
    // lifecycle command and never a single touch.
    _ = a.ALooper_addFd(looper, glue.cmd_pipe[0], ident_cmd, looper_event_input, null, null);

    return self;
}

fn deinit(impl: backend.Impl, gpa: Allocator) void {
    const self = cast(impl);
    // Before the text backend, which detaches the thread it needs.
    if (self.text.env) |env| {
        self.clipboard.close(env);
        self.dialog.close(env);
    }
    self.text.close();
    for (self.chosen.items) |uri| gpa.free(uri);
    self.chosen.deinit(gpa);
    self.answers.deinit();
    const unread = glue.answer.swap(0, .acq_rel);
    if (unread != 0) @as(*android_dialog.Answer, @ptrFromInt(unread)).destroy();
    self.gl.close();
    self.lib.close();
    gpa.destroy(self);
}

fn cast(impl: backend.Impl) *Impl {
    return @ptrCast(@alignCast(impl));
}

fn castWindow(native: backend.NativeWindow) *Native {
    return @ptrCast(@alignCast(native));
}

/// Hand back the one window the activity has.
///
/// Nothing is created: Android made it, or has not made it yet. A second call
/// is `error.Unavailable`, because there is no second window to give.
fn createWindow(
    impl: backend.Impl,
    gpa: Allocator,
    id: event.WindowId,
    desc: backend.WindowDesc,
) Error!backend.NativeWindow {
    const self = cast(impl);
    if (self.native != null) return error.Unavailable;

    const native = gpa.create(Native) catch return error.OutOfMemory;
    errdefer gpa.destroy(native);

    const window = Glue.take(&glue.window, ANativeWindow);

    native.* = .{
        .id = id,
        .impl = self,
        .width = if (window) |w| @intCast(@max(0, self.a.ANativeWindow_getWidth(w))) else desc.width,
        .height = if (window) |w| @intCast(@max(0, self.a.ANativeWindow_getHeight(w))) else desc.height,
        .gl_config = desc.gl,
    };
    self.native = native;

    // Only if there is a surface right now. A window made before the activity
    // has one - which happens, because `main` starts before the first
    // `window_created` - gets its context at `.surface_created` instead, and
    // gets a new one every time the surface comes back.
    if (desc.gl != null and window != null) attachContext(self, native) catch {};

    return native;
}

/// Build the EGL surface and context against the activity's current window.
///
/// Called at creation when there is already a surface, and again on every
/// `.surface_created` - because on Android a surface is destroyed whenever the
/// app goes to the background and the context that was drawing into it goes
/// with it. A program that only ever built one would draw into nothing after
/// the first time the user answered a phone call.
fn attachContext(self: *Impl, native: *Native) Error!void {
    const config = native.gl_config orelse return error.Unavailable;
    // Lazily, and the library stays open across a surface being lost and given
    // back - only a program that asked for a context loads it at all.
    if (!self.gl.available()) self.gl = egl.Backend.open();
    if (!self.gl.available()) return error.Unavailable;

    const window = Glue.take(&glue.window, ANativeWindow) orelse return error.Unavailable;

    // Null: there is one display and EGL knows which.
    const display = try egl.connect(&self.gl, null);
    const egl_config = try egl.chooseConfig(&self.gl, display, config);

    // The surface has to be allocated in the format the config named, and
    // saying so afterwards is too late.
    const format = egl.nativeVisualId(&self.gl, display, egl_config);
    _ = self.a.ANativeWindow_setBuffersGeometry(window, 0, 0, format);

    native.context = try egl.createContext(&self.gl, display, egl_config, window, config);
}

/// Let go of a context whose surface has gone.
fn detachContext(self: *Impl, native: *Native) void {
    const context = native.context orelse return;
    native.context = null;
    const display = self.gl.display orelse return;
    egl.destroyContext(&self.gl, display, context);
}

fn makeContextCurrent(impl: backend.Impl, native: backend.NativeWindow) Error!void {
    const self = cast(impl);
    const context = castWindow(native).context orelse return error.Unavailable;
    const display = self.gl.display orelse return error.Unavailable;
    return egl.makeCurrent(&self.gl, display, context);
}

fn clearContext(impl: backend.Impl) void {
    const self = cast(impl);
    const display = self.gl.display orelse return;
    egl.clearCurrent(&self.gl, display);
}

fn swapBuffers(impl: backend.Impl, native: backend.NativeWindow) Error!void {
    const self = cast(impl);
    const context = castWindow(native).context orelse return error.Unavailable;
    const display = self.gl.display orelse return error.Unavailable;
    return egl.swap(&self.gl, display, context);
}

fn setSwapInterval(impl: backend.Impl, native: backend.NativeWindow, interval: i32) Error!void {
    const self = cast(impl);
    if (castWindow(native).context == null) return error.Unavailable;
    const display = self.gl.display orelse return error.Unavailable;
    return egl.setSwapInterval(&self.gl, display, interval);
}

fn getProcAddress(impl: backend.Impl, native: backend.NativeWindow, name: [*:0]const u8) ?gl.Proc {
    _ = native;
    return egl.getProcAddress(&cast(impl).gl, name);
}

fn contextConfig(impl: backend.Impl, native: backend.NativeWindow) ?gl.Config {
    _ = impl;
    const context = castWindow(native).context orelse return null;
    return context.config;
}

fn createVulkanSurface(
    impl: backend.Impl,
    native: backend.NativeWindow,
    instance: usize,
    get_proc: vulkan.GetInstanceProcAddr,
    allocator: ?*const anyopaque,
) Error!u64 {
    _ = .{ impl, native };

    // The activity's window, not one this backend made: on Android there is
    // one surface and it belongs to the system. Null while the app is in the
    // background, which is a real state and not a failure - a program should
    // make its surface on `.surface_created` and let go of it on
    // `.surface_lost`.
    const window = Glue.take(&glue.window, ANativeWindow) orelse return error.Unavailable;

    const create: *const fn (
        usize,
        *const vulkan.AndroidSurfaceCreateInfo,
        ?*const anyopaque,
        *u64,
    ) callconv(.c) i32 = @ptrCast(get_proc(instance, "vkCreateAndroidSurfaceKHR") orelse
        return error.Unavailable);

    const info: vulkan.AndroidSurfaceCreateInfo = .{ .window = @ptrCast(window) };

    var surface: u64 = 0;
    if (create(instance, &info, allocator, &surface) != vulkan.success) {
        return error.Unavailable;
    }
    return surface;
}

fn destroyWindow(impl: backend.Impl, gpa: Allocator, native: backend.NativeWindow) void {
    const self = cast(impl);
    detachContext(self, castWindow(native));
    self.native = null;
    gpa.destroy(castWindow(native));
}

/// A window title is a thing a desktop has. Android names an app in its
/// manifest, and nothing here can change it.
fn setTitle(impl: backend.Impl, native: backend.NativeWindow, title: []const u8) Error!void {
    _ = .{ impl, native, title };
    return error.Unavailable;
}

fn setVisible(impl: backend.Impl, native: backend.NativeWindow, visible: bool) void {
    _ = .{ impl, native, visible };
}

fn size(impl: backend.Impl, native: backend.NativeWindow) [2]u32 {
    return framebufferSize(impl, native);
}

fn framebufferSize(impl: backend.Impl, native: backend.NativeWindow) [2]u32 {
    _ = impl;
    const win = castWindow(native);
    return .{ win.width, win.height };
}

/// The device's density over the 160 dpi Android calls a scale of one.
///
/// Per device rather than per window, because a phone has one screen and the
/// window is all of it.
fn contentScale(impl: backend.Impl, native: backend.NativeWindow) [2]f32 {
    _ = native;
    const scale = readDensity(cast(impl)) orelse return .{ 1, 1 };
    return .{ scale, scale };
}

/// The screen density as a multiple of 160 dpi, or null where the
/// configuration cannot be read.
fn readDensity(self: *Impl) ?f32 {
    const new = self.a.AConfiguration_new orelse return null;
    const delete = self.a.AConfiguration_delete orelse return null;
    const from = self.a.AConfiguration_fromAssetManager orelse return null;
    const get = self.a.AConfiguration_getDensity orelse return null;

    const activity = liveActivity() orelse return null;
    const assets = activity.assetManager orelse return null;

    const config = new() orelse return null;
    defer delete(config);

    from(config, assets);
    const density = get(config);
    // Both of these mean "whatever suits", which is not a measurement.
    if (density == density_any or density == density_none) return null;
    return @as(f32, @floatFromInt(density)) / density_default;
}

// -------------------------------------------------------------------------
// Text input
// -------------------------------------------------------------------------

/// Ask the VM what a key typed, and say so.
///
/// The JNI side is attached on the first key rather than at startup, so a
/// program that never reads text never crosses into Java at all. A failure
/// anywhere leaves `ready` false and this quietly produces nothing, which is
/// the same as a key that types nothing.
/// Attach to the VM for `getUnicodeChar`, the first time anything asks.
/// False where there is no activity or no VM to ask.
fn ensureText(self: *Impl) bool {
    if (self.text.ready()) return true;
    const activity = liveActivity() orelse return false;
    // `activity.vm` is already C's `JavaVM*` - a pointer to a pointer to the
    // table - so this is a cast and not a dereference.
    const vm: android_text.JavaVm = @ptrCast(@alignCast(activity.vm orelse return false));
    return self.text.open(vm);
}

/// What a key types on its own: `getUnicodeChar` with no meta state, which is
/// its first level on the device's layout. The virtual key is worked out from
/// it. Null where the VM cannot be asked, or the key types nothing.
fn baseChar(self: *Impl, action: i32, code: i32) ?u21 {
    if (!ensureText(self)) return null;
    const codepoint = self.text.unicodeChar(action, code, 0);
    return if (codepoint == 0) null else codepoint;
}

fn pushChar(self: *Impl, id: event.WindowId, action: i32, code: i32, meta: i32) void {
    if (!ensureText(self)) return;

    const codepoint = self.text.unicodeChar(action, code, meta);
    // Zero is "types nothing", which is most keys: the arrows, the volume
    // rocker, and a dead key still waiting for its partner.
    if (codepoint == 0) return;
    if (codepoint < 0x20 or codepoint == 0x7F) return;

    push(self, .{ .char = .{
        .window = id,
        .codepoint = codepoint,
        .mods = modsFromMeta(meta),
    } });
}

/// Raise or dismiss the soft keyboard.
///
/// The whole of input-method control on Android, and the one call that matters:
/// a phone with no hardware keyboard types nothing at all until this is on.
fn setTextInput(impl: backend.Impl, native: backend.NativeWindow, on: bool) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    const activity = liveActivity() orelse return error.Unavailable;

    if (on) {
        self.a.ANativeActivity_showSoftInput(activity, show_soft_input_implicit);
    } else {
        self.a.ANativeActivity_hideSoftInput(activity, hide_soft_input_not_always);
    }
    win.text_input = on;
}

/// Nowhere to put it.
///
/// A soft keyboard occupies the bottom of the screen whatever the program
/// says, and a `NativeActivity` has no `InputConnection` to report a caret
/// through. Refused rather than ignored.
fn setTextInputArea(impl: backend.Impl, native: backend.NativeWindow, area: text_mod.Area) Error!void {
    _ = .{ impl, native, area };
    return error.Unavailable;
}

fn preedit(impl: backend.Impl) ?*const text_mod.Preedit {
    return &cast(impl).preedit;
}

// -------------------------------------------------------------------------
// The clipboard
// -------------------------------------------------------------------------

/// The attached thread, with the clipboard looked up on it. The text backend
/// attached the thread and owns that; the clipboard only borrows it.
fn clipboardEnv(self: *Impl) ?jni.JniEnv {
    if (!ensureText(self)) return null;
    const env = self.text.env orelse return null;
    const activity = liveActivity() orelse return null;
    if (!self.clipboard.open(env, activity.clazz)) return null;
    return env;
}

fn setClipboardText(impl: backend.Impl, text: []const u8) Error!void {
    const self = cast(impl);
    const env = clipboardEnv(self) orelse return error.Unavailable;
    if (!try self.clipboard.setText(env, self.gpa, text)) return error.Unavailable;
}

fn clipboardText(impl: backend.Impl, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    const self = cast(impl);
    const env = clipboardEnv(self) orelse return error.Unavailable;
    const activity = liveActivity() orelse return error.Unavailable;
    try self.clipboard.readText(env, activity.clazz, gpa, out);
}

fn hasClipboardText(impl: backend.Impl) bool {
    const self = cast(impl);
    const env = clipboardEnv(self) orelse return false;
    return self.clipboard.hasText(env);
}

/// The attached thread, with the activity's dialog methods looked up on it -
/// which there are only when the manifest names `FluxionActivity`.
fn dialogEnv(self: *Impl) ?jni.JniEnv {
    if (!ensureText(self)) return null;
    const env = self.text.env orelse return null;
    const activity = liveActivity() orelse return null;
    if (!self.dialog.open(env, activity.clazz)) return null;
    return env;
}

/// The system's document picker, through `FluxionActivity`. A plain
/// `NativeActivity` has no way to hear its answer, and says so here.
fn showFileDialog(impl: backend.Impl, gpa: Allocator, request: backend.DialogRequest) Error!void {
    _ = gpa;
    const self = cast(impl);
    if (self.dialog_open != null) return error.Unavailable;
    const env = dialogEnv(self) orelse return error.Unavailable;
    const activity = liveActivity() orelse return error.Unavailable;
    try self.dialog.ask(env, activity.clazz, request);
    self.dialog_open = request.id;
    self.dialog_window = request.window;
}

/// Through the URI kept beside the name: `path` is only a display name.
fn chosenFile(impl: backend.Impl, index: usize, path: []const u8, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    _ = path;
    const self = cast(impl);
    if (index >= self.chosen.items.len) return error.Unavailable;
    const env = dialogEnv(self) orelse return error.Unavailable;
    const activity = liveActivity() orelse return error.Unavailable;
    try self.dialog.read(env, activity.clazz, self.chosen.items[index], out, gpa);
}

/// The answer the Java side handed over, for the dialog that is open. One
/// for any other - a process started afresh to hear its last one's - is let
/// go.
fn answerDialog(self: *Impl) Error!void {
    const raw = glue.answer.swap(0, .acq_rel);
    if (raw == 0) return;
    const answer: *android_dialog.Answer = @ptrFromInt(raw);
    defer answer.destroy();
    const open_id = self.dialog_open orelse return;
    if (answer.id != @intFromEnum(open_id)) return;
    self.dialog_open = null;

    for (self.chosen.items) |uri| self.gpa.free(uri);
    self.chosen.clearRetainingCapacity();
    try self.chosen.ensureTotalCapacity(self.gpa, answer.uris.len);
    for (answer.uris) |uri| self.chosen.appendAssumeCapacity(try self.gpa.dupe(u8, uri));

    const arena = self.answers.allocator();
    const paths = try arena.alloc([]const u8, answer.names.len);
    for (answer.names, paths) |name, *path| path.* = try arena.dupe(u8, name);
    push(self, .{ .file_dialog = .{ .window = self.dialog_window, .id = open_id, .paths = paths } });
}

/// Route one event to the gamepad state, or leave it for the window.
///
/// True means it was a controller's and nothing else should see it.
fn translateController(self: *Impl, input_event: *AInputEvent) bool {
    const a = self.a;

    const source = a.AInputEvent_getSource(input_event);
    if (!android_gamepad.isController(source)) return false;

    const device_id = a.AInputEvent_getDeviceId(input_event);

    switch (a.AInputEvent_getType(input_event)) {
        input_event_type_key => {
            const action = a.AKeyEvent_getAction(input_event);
            if (action != key_action_down and action != key_action_up) return false;
            return self.pads.key(
                &self.devices,
                device_id,
                source,
                a.AKeyEvent_getKeyCode(input_event),
                action == key_action_down,
            );
        },
        input_event_type_motion => {
            if (a.AMotionEvent_getPointerCount(input_event) == 0) return false;

            var values: [android_gamepad.Backend.axis_count]f32 = @splat(0);
            for (android_gamepad.Backend.axis_codes, 0..) |code, index| {
                values[index] = a.AMotionEvent_getAxisValue(input_event, code, 0);
            }
            return self.pads.motion(&self.devices, device_id, source, values);
        },
        else => return false,
    }
}

/// Hand over what the input queue has already gathered.
///
/// Nothing to ask the system for: the state was built as the events arrived,
/// because that is the only way Android reports a controller.
fn pollGamepads(impl: backend.Impl, devices: *[gamepad.max_devices]gamepad.Device) void {
    devices.* = cast(impl).devices;
}

// -------------------------------------------------------------------------
// Monitors
// -------------------------------------------------------------------------

/// One screen, the size of the surface the activity was given.
///
/// A phone has one display and a program cannot choose it, so this is a list of
/// one - and an empty list before the surface exists, because until then there
/// is nothing whose size could be reported. It comes back on
/// `.surface_created`, which is the event a program should be waiting for
/// anyway.
///
/// No mode list: nothing on Android switches the panel's resolution, and a mode
/// a program cannot ask for is not one worth listing.
fn enumerateMonitors(
    impl: backend.Impl,
    list: *std.ArrayListUnmanaged(monitor.Monitor),
    modes: *std.ArrayListUnmanaged(monitor.VideoMode),
    gpa: Allocator,
) Error!void {
    _ = modes;
    const self = cast(impl);

    const window = Glue.take(&glue.window, ANativeWindow) orelse return;

    const width: u32 = @intCast(@max(0, self.a.ANativeWindow_getWidth(window)));
    const height: u32 = @intCast(@max(0, self.a.ANativeWindow_getHeight(window)));
    if (width == 0 or height == 0) return;

    const scale = readDensity(self) orelse 1;
    const current: monitor.VideoMode = .{ .width = width, .height = height };

    var mon: monitor.Monitor = .{
        .bounds = .{ .x = 0, .y = 0, .width = width, .height = height },
        // The status and navigation bars take a strip, and this backend is not
        // told where: `onContentRectChanged` carries it, and a program that
        // needs the inset should read the rect the event gives it.
        .work_area = .{ .x = 0, .y = 0, .width = width, .height = height },
        .scale_x = scale,
        .scale_y = scale,
        .current = current,
        .primary = true,
    };
    mon.setName("screen");

    try list.append(gpa, mon);
}

/// Nothing to do, and nothing to refuse.
///
/// An Android window is already the whole screen, so being fullscreen is not a
/// state to enter - it is where every window starts. Hiding the system bars is
/// a different thing, needs JNI, and is not what this call means.
fn setFullscreen(
    impl: backend.Impl,
    native: backend.NativeWindow,
    wanted: monitor.Fullscreen,
    target: ?*const monitor.Monitor,
) Error!void {
    _ = .{ impl, native, target };
    // Except a mode change, which no Android device offers.
    if (wanted == .exclusive) return error.Unavailable;
}

/// A window on Android is the screen. None of these mean anything there: no
/// position to read or set, no size to choose, nothing to minimise into, and no
/// window-level transparency. Each says so rather than pretending.
fn position(impl: backend.Impl, native: backend.NativeWindow) [2]i32 {
    _ = .{ impl, native };
    return .{ 0, 0 };
}

fn setPosition(impl: backend.Impl, native: backend.NativeWindow, x: i32, y: i32) Error!void {
    _ = .{ impl, native, x, y };
    return error.Unavailable;
}

fn setSize(impl: backend.Impl, native: backend.NativeWindow, width: u32, height: u32) Error!void {
    _ = .{ impl, native, width, height };
    return error.Unavailable;
}

fn setState(impl: backend.Impl, native: backend.NativeWindow, wanted: backend.WindowState) Error!void {
    _ = .{ impl, native, wanted };
    return error.Unavailable;
}

/// The one that has an answer: an activity either has focus or it does not, and
/// the lifecycle already said which.
fn getState(impl: backend.Impl, native: backend.NativeWindow, which: backend.WindowState) bool {
    _ = .{ impl, native };
    return switch (which) {
        .focused => glue.focused.load(.acquire),
        // Always: there is one window and it fills the screen.
        .maximized => true,
        .iconified, .restored, .attention => false,
    };
}

fn setSizeLimits(impl: backend.Impl, native: backend.NativeWindow, limits: backend.SizeLimits) Error!void {
    _ = .{ impl, native, limits };
    return error.Unavailable;
}

fn setOpacity(impl: backend.Impl, native: backend.NativeWindow, opacity: f32) Error!void {
    _ = .{ impl, native, opacity };
    return error.Unavailable;
}

/// A phone has no pointer to hide, confine or move, and a mouse plugged into
/// one is the system's to draw. Every call says so.
fn setCursorMode(impl: backend.Impl, native: backend.NativeWindow, mode: cursor_mod.Mode) Error!void {
    _ = .{ impl, native, mode };
    return error.Unavailable;
}

fn setRawMouseMotion(impl: backend.Impl, native: backend.NativeWindow, on: bool) bool {
    _ = .{ impl, native, on };
    return false;
}

fn setCursorPos(impl: backend.Impl, native: backend.NativeWindow, x: f64, y: f64) Error!void {
    _ = .{ impl, native, x, y };
    return error.Unavailable;
}

fn setCursorShape(impl: backend.Impl, native: backend.NativeWindow, shape: cursor_mod.Shape) Error!void {
    _ = .{ impl, native, shape };
    return error.Unavailable;
}

/// The `ANativeWindow`, which is what an EGL or Vulkan surface is made from.
///
/// Zero while there is none - between `.surface_lost` and the next
/// `.surface_created`, which on Android is an ordinary state and not an error.
fn nativeHandle(impl: backend.Impl, native: backend.NativeWindow) usize {
    _ = .{ impl, native };
    const window = Glue.take(&glue.window, ANativeWindow) orelse return 0;
    return @intFromPtr(window);
}

// -------------------------------------------------------------------------
// The event loop
// -------------------------------------------------------------------------

fn pump(impl: backend.Impl, queue: *backend.Queue) Error!void {
    const self = cast(impl);

    self.queue = queue;
    self.push_failed = false;
    defer self.queue = null;

    // The last answer's names were promised until now.
    _ = self.answers.reset(.retain_capacity);

    // A zero-timeout poll lets the looper move anything waiting on either
    // source into reach, without blocking a frame that has drawing to do.
    _ = self.a.ALooper_pollOnce(0, null, null, null);

    try drainCommands(self);
    try drainInput(self);

    if (self.push_failed) return error.OutOfMemory;
}

fn wait(impl: backend.Impl, timeout_ms: ?u32) Error!void {
    if (comptime !is_android) return;
    const self = cast(impl);

    // Through the looper, which is what drives both sources: the command pipe
    // added in `open` and the input queue attached when the system made one.
    const timeout: c_int = if (timeout_ms) |ms| @intCast(@min(ms, std.math.maxInt(c_int))) else -1;
    _ = self.a.ALooper_pollOnce(timeout, null, null, null);
}

fn post(impl: backend.Impl) void {
    if (comptime !is_android) return;
    const self = cast(impl);
    self.a.ALooper_wake(self.looper);
}

/// Read whatever the UI thread has sent, and turn it into events.
fn drainCommands(self: *Impl) Error!void {
    const read_fd = glue.cmd_pipe[0];
    if (read_fd < 0) return;

    while (true) {
        var fds = [_]Pollfd{.{ .fd = read_fd, .events = pollin, .revents = 0 }};
        if (c.poll(&fds, 1, 0) <= 0) return;

        var byte: [1]u8 = undefined;
        if (c.read(read_fd, &byte, 1) != 1) return;

        try handleCommand(self, @enumFromInt(byte[0]));
    }
}

/// One command, on the app thread. The whole lifecycle is here.
pub fn handleCommand(self: *Impl, cmd: Cmd) Error!void {
    const id: event.WindowId = if (self.native) |n| n.id else .none;

    switch (cmd) {
        .window_created => {
            const window = Glue.take(&glue.pending_window, ANativeWindow);
            Glue.set(&glue.window, window);
            Glue.set(&glue.pending_window, null);

            if (window) |w| {
                const width: u32 = @intCast(@max(0, self.a.ANativeWindow_getWidth(w)));
                const height: u32 = @intCast(@max(0, self.a.ANativeWindow_getHeight(w)));
                if (self.native) |native| {
                    native.width = width;
                    native.height = height;
                }
                // Before the event, so that a program handling
                // `.surface_created` already has a context to make current.
                if (self.native) |native| {
                    if (native.gl_config != null and native.context == null) {
                        attachContext(self, native) catch {};
                    }
                }

                push(self, .{ .surface_created = .{
                    .window = id,
                    .width = width,
                    .height = height,
                } });
            }
            glue.ack();
        },

        .window_destroyed => {
            // The event goes out first, and only then is the UI thread let go -
            // which is what makes releasing the swapchain on `.surface_lost`
            // sufficient rather than merely advisable.
            push(self, .{ .surface_lost = id });
            // After the event and before the UI thread is let go: the program
            // has been told the surface is going, and the EGL surface built on
            // it must not outlive the `ANativeWindow` underneath.
            if (self.native) |native| detachContext(self, native);
            Glue.set(&glue.window, null);
            glue.ack();
        },

        .window_resized, .window_redraw => {
            const window = Glue.take(&glue.window, ANativeWindow);

            if (window) |w| {
                const width: u32 = @intCast(@max(0, self.a.ANativeWindow_getWidth(w)));
                const height: u32 = @intCast(@max(0, self.a.ANativeWindow_getHeight(w)));
                if (self.native) |native| {
                    if (width != native.width or height != native.height) {
                        native.width = width;
                        native.height = height;
                        push(self, .{ .framebuffer_resize = .{
                            .window = id,
                            .width = width,
                            .height = height,
                        } });
                        push(self, .{ .resize = .{
                            .window = id,
                            .width = width,
                            .height = height,
                        } });
                    }
                }
            }
            if (cmd == .window_redraw) {
                push(self, .{ .refresh = id });
                glue.ack();
            }
        },

        .input_created => {
            const input = Glue.take(&glue.pending_input, AInputQueue);
            Glue.set(&glue.input, input);
            Glue.set(&glue.pending_input, null);

            if (input) |q| {
                self.a.AInputQueue_attachLooper(q, self.looper, ident_input, null, null);
            }
            glue.ack();
        },

        .input_destroyed => {
            const input = Glue.take(&glue.input, AInputQueue);
            Glue.set(&glue.input, null);

            if (input) |q| self.a.AInputQueue_detachLooper(q);
            glue.ack();
        },

        .focus_gained => {
            glue.focused.store(true, .release);
            push(self, .{ .focus = .{ .window = id, .value = true } });
        },
        .focus_lost => {
            glue.focused.store(false, .release);
            push(self, .{ .focus = .{ .window = id, .value = false } });
        },

        .start, .resume_ => push(self, .{ .resumed = {} }),
        .pause, .stop => push(self, .{ .suspended = {} }),
        .low_memory => push(self, .{ .low_memory = {} }),
        .dialog_answered => try answerDialog(self),

        .destroy => {
            push(self, .{ .close = id });
            glue.destroyed.store(true, .release);
            glue.ack();
        },

        .config_changed, _ => {},
    }
}

/// Everything the input queue has, turned into events.
fn drainInput(self: *Impl) Error!void {
    const queue = Glue.take(&glue.input, AInputQueue) orelse return;
    const id: event.WindowId = if (self.native) |n| n.id else .none;

    while (true) {
        var raw: ?*AInputEvent = null;
        if (self.a.AInputQueue_getEvent(queue, &raw) < 0) return;
        const input_event = raw orelse return;

        // **Not pre-dispatched.** `AInputQueue_preDispatchEvent` offers an
        // event to the input method first, which is right for an app with a
        // Java view hierarchy: the method takes the key and commits text
        // through that view's `InputConnection`.
        //
        // A `NativeActivity` has no `InputConnection`. So with the soft
        // keyboard up the method takes every key and has nowhere to put the
        // result, and the app sees nothing at all - which is exactly what
        // happened here before this comment existed: `input keyevent 29`
        // arrived, was pre-dispatched, and vanished.
        //
        // Skipping it means the keys arrive, and `pushChar` turns them into
        // text through the same `KeyEvent.getUnicodeChar` the method would
        // have used. What is given up is composition, which a
        // `NativeActivity` could not have had either way.

        const handled = translate(self, input_event, id);
        self.a.AInputQueue_finishEvent(queue, input_event, if (handled) 1 else 0);
    }
}

fn translate(self: *Impl, input_event: *AInputEvent, id: event.WindowId) bool {
    const a = self.a;

    // A controller first: its buttons carry the same key codes a keyboard
    // would, and letting them through as key events would have the d-pad
    // arrive as arrow keys and `A` arrive as nothing at all.
    if (translateController(self, input_event)) return true;

    switch (a.AInputEvent_getType(input_event)) {
        input_event_type_key => {
            const action = a.AKeyEvent_getAction(input_event);
            if (action != key_action_down and action != key_action_up) return false;

            const code = a.AKeyEvent_getKeyCode(input_event);
            const meta = a.AKeyEvent_getMetaState(input_event);
            const physical = keyFromAndroid(code);
            push(self, .{ .key = .{
                .window = id,
                .key = physical,
                .virtual = virtual_key.fromTyped(physical, baseChar(self, action, code)),
                .scancode = @enumFromInt(@as(u32, @bitCast(a.AKeyEvent_getScanCode(input_event)))),
                .action = if (action == key_action_down) .press else .release,
                .mods = modsFromMeta(meta),
            } });

            // And what it typed. Only on the way down, and only through the
            // VM: the NDK has no call that turns a key code into a character.
            if (action == key_action_down) pushChar(self, id, action, code, meta);

            // The back key is the system's unless a program says otherwise, and
            // reporting it as handled would trap the user in the app.
            return code != android_keycode_back;
        },

        input_event_type_motion => {
            const action = a.AMotionEvent_getAction(input_event) & motion_action_mask;
            if (a.AMotionEvent_getPointerCount(input_event) == 0) return false;

            const x: f64 = a.AMotionEvent_getX(input_event, 0);
            const y: f64 = a.AMotionEvent_getY(input_event, 0);

            switch (action) {
                motion_action_down, motion_action_pointer_down => {
                    // A touch is reported as the left button, so a program
                    // written for a mouse works without knowing where it is.
                    push(self, .{ .cursor = .{ .window = id, .x = x, .y = y, .dx = 0, .dy = 0 } });
                    push(self, .{ .mouse_button = .{
                        .window = id,
                        .button = .left,
                        .action = .press,
                        .mods = .none,
                        .x = x,
                        .y = y,
                    } });
                },
                motion_action_up, motion_action_pointer_up, motion_action_cancel => {
                    push(self, .{ .mouse_button = .{
                        .window = id,
                        .button = .left,
                        .action = .release,
                        .mods = .none,
                        .x = x,
                        .y = y,
                    } });
                },
                motion_action_move => {
                    push(self, .{ .cursor = .{ .window = id, .x = x, .y = y, .dx = 0, .dy = 0 } });
                },
                else => return false,
            }
            return true;
        },

        else => return false,
    }
}

fn push(self: *Impl, ev: event.Event) void {
    const queue = self.queue orelse return;
    queue.push(ev) catch {
        self.push_failed = true;
    };
}

fn modsFromMeta(meta: i32) keys.Mods {
    return .{
        .shift = meta & meta_shift_on != 0,
        .control = meta & meta_ctrl_on != 0,
        .alt = meta & meta_alt_on != 0,
        .super = meta & meta_meta_on != 0,
        .caps_lock = meta & meta_caps_lock_on != 0,
        .num_lock = meta & meta_num_lock_on != 0,
    };
}

// -------------------------------------------------------------------------
// Key codes
//
// Android's own numbering, not evdev. A phone has no physical keyboard to have
// positions on, and an attached one is reported through the same table, so this
// is the mapping that is right on every device rather than only on some.
// -------------------------------------------------------------------------

const android_keycode_back: i32 = 4;

/// The key at `code`, or `unknown` for one this table has no name for.
pub fn keyFromAndroid(code: i32) keys.Key {
    return switch (code) {
        7 => .@"0",
        8 => .@"1",
        9 => .@"2",
        10 => .@"3",
        11 => .@"4",
        12 => .@"5",
        13 => .@"6",
        14 => .@"7",
        15 => .@"8",
        16 => .@"9",

        19 => .up,
        20 => .down,
        21 => .left,
        22 => .right,
        23 => .enter, // DPAD_CENTER, which is what a d-pad's select is

        29 => .a,
        30 => .b,
        31 => .c,
        32 => .d,
        33 => .e,
        34 => .f,
        35 => .g,
        36 => .h,
        37 => .i,
        38 => .j,
        39 => .k,
        40 => .l,
        41 => .m,
        42 => .n,
        43 => .o,
        44 => .p,
        45 => .q,
        46 => .r,
        47 => .s,
        48 => .t,
        49 => .u,
        50 => .v,
        51 => .w,
        52 => .x,
        53 => .y,
        54 => .z,

        55 => .comma,
        56 => .period,
        57 => .left_alt,
        58 => .right_alt,
        59 => .left_shift,
        60 => .right_shift,
        61 => .tab,
        62 => .space,
        66 => .enter,
        67 => .backspace,
        68 => .grave_accent,
        69 => .minus,
        70 => .equal,
        71 => .left_bracket,
        72 => .right_bracket,
        73 => .backslash,
        74 => .semicolon,
        75 => .apostrophe,
        76 => .slash,
        82 => .menu,

        92 => .page_up,
        93 => .page_down,

        111 => .escape,
        112 => .delete,
        113 => .left_control,
        114 => .right_control,
        115 => .caps_lock,
        116 => .scroll_lock,
        117 => .left_super,
        118 => .right_super,
        120 => .print_screen,
        121 => .pause,
        122 => .home,
        123 => .end,
        124 => .insert,

        131 => .f1,
        132 => .f2,
        133 => .f3,
        134 => .f4,
        135 => .f5,
        136 => .f6,
        137 => .f7,
        138 => .f8,
        139 => .f9,
        140 => .f10,
        141 => .f11,
        142 => .f12,

        143 => .num_lock,
        144 => .kp_0,
        145 => .kp_1,
        146 => .kp_2,
        147 => .kp_3,
        148 => .kp_4,
        149 => .kp_5,
        150 => .kp_6,
        151 => .kp_7,
        152 => .kp_8,
        153 => .kp_9,
        154 => .kp_divide,
        155 => .kp_multiply,
        156 => .kp_subtract,
        157 => .kp_add,
        158 => .kp_decimal,
        160 => .kp_enter,
        161 => .kp_equal,

        else => .unknown,
    };
}

// -------------------------------------------------------------------------
// Tests
//
// The ABI and the key table run on any host. The lifecycle does not need a
// device either: the callbacks are ordinary functions, so driving them and
// reading the pipe is a real test of the state machine - which is where the
// bugs in glue code live.
// -------------------------------------------------------------------------

test "the callback struct is sixteen pointers, in the order the system writes" {
    // A field out of place here calls the wrong function with the wrong
    // arguments, and there is no error for that.
    const fields = @typeInfo(ANativeActivityCallbacks).@"struct".fields;
    try testing.expectEqual(@as(usize, 16), fields.len);
    try testing.expectEqual(16 * @sizeOf(usize), @sizeOf(ANativeActivityCallbacks));

    const expected = [_][]const u8{
        "onStart",                 "onResume",
        "onSaveInstanceState",     "onPause",
        "onStop",                  "onDestroy",
        "onWindowFocusChanged",    "onNativeWindowCreated",
        "onNativeWindowResized",   "onNativeWindowRedrawNeeded",
        "onNativeWindowDestroyed", "onInputQueueCreated",
        "onInputQueueDestroyed",   "onContentRectChanged",
        "onConfigurationChanged",  "onLowMemory",
    };
    inline for (fields, expected) |field, want| {
        try testing.expectEqualStrings(want, field.name);
    }
}

test "the activity struct is laid out the way the system fills it" {
    const fields = @typeInfo(ANativeActivity).@"struct".fields;
    try testing.expectEqual(@as(usize, 10), fields.len);

    // `callbacks` first, because that is the pointer the system writes through
    // before anything else happens.
    try testing.expectEqual(@as(usize, 0), @offsetOf(ANativeActivity, "callbacks"));
    // `instance` is ours, and sits after the int that precedes it - which is
    // where padding would put it somewhere else if the layout were wrong.
    try testing.expect(@offsetOf(ANativeActivity, "instance") > @offsetOf(ANativeActivity, "sdkVersion"));
    try testing.expect(@offsetOf(ANativeActivity, "obbPath") > @offsetOf(ANativeActivity, "assetManager"));
}

test "every callback is filled in" {
    // A null one is a lifecycle change the program never hears about, and the
    // system does not warn.
    inline for (@typeInfo(ANativeActivityCallbacks).@"struct".fields) |field| {
        try testing.expect(@field(callbacks, field.name) != null);
    }
}

test "the key table is Android's numbering, not evdev's" {
    try testing.expectEqual(keys.Key.a, keyFromAndroid(29));
    try testing.expectEqual(keys.Key.w, keyFromAndroid(51));
    try testing.expectEqual(keys.Key.escape, keyFromAndroid(111));
    try testing.expectEqual(keys.Key.space, keyFromAndroid(62));
    try testing.expectEqual(keys.Key.enter, keyFromAndroid(66));

    // The evdev code for `a` is 30, which Android uses for `b` - so a table
    // shared with the POSIX backends would be wrong on every letter.
    try testing.expectEqual(keys.Key.b, keyFromAndroid(30));
}

test "an unnamed key is unknown rather than a wrong key" {
    try testing.expectEqual(keys.Key.unknown, keyFromAndroid(0));
    try testing.expectEqual(keys.Key.unknown, keyFromAndroid(3)); // HOME, the system's
    try testing.expectEqual(keys.Key.unknown, keyFromAndroid(9999));
    try testing.expectEqual(keys.Key.unknown, keyFromAndroid(-1));
}

test "no two Android codes name the same key" {
    var seen: [keys.Key.max + 1]bool = @splat(false);
    var code: i32 = 0;
    while (code < 300) : (code += 1) {
        const key = keyFromAndroid(code);
        if (key == .unknown) continue;
        // `enter` is deliberately two codes: the d-pad centre and the key.
        if (key == .enter) continue;
        const index = key.index() orelse continue;
        try testing.expect(!seen[index]);
        seen[index] = true;
    }
}

test "the meta state maps onto the same modifiers as everywhere else" {
    try testing.expectEqual(keys.Mods{ .shift = true }, modsFromMeta(meta_shift_on));
    try testing.expectEqual(keys.Mods{ .control = true }, modsFromMeta(meta_ctrl_on));
    try testing.expectEqual(keys.Mods{ .alt = true }, modsFromMeta(meta_alt_on));
    try testing.expectEqual(keys.Mods{ .super = true }, modsFromMeta(meta_meta_on));
    try testing.expectEqual(keys.Mods{ .caps_lock = true }, modsFromMeta(meta_caps_lock_on));
    try testing.expectEqual(keys.Mods.none, modsFromMeta(0));
}

test "a lifecycle callback writes one command down the pipe" {
    if (comptime !is_android) return error.SkipZigTest;

    // The glue is ordinary code, so it can be driven without a device: call the
    // callback the system would call, then read what the app thread would read.
    var fds: [2]c_int = .{ -1, -1 };
    try testing.expect(c.pipe(&fds) == 0);
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    const saved = glue.cmd_pipe;
    glue.cmd_pipe = fds;
    defer glue.cmd_pipe = saved;

    var activity: ANativeActivity = undefined;
    var cbs: ANativeActivityCallbacks = .{};
    activity.callbacks = &cbs;

    onStart(&activity);
    onWindowFocusChanged(&activity, 1);
    onWindowFocusChanged(&activity, 0);
    onLowMemory(&activity);

    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 1), c.read(fds[0], &byte, 1));
    try testing.expectEqual(Cmd.start, @as(Cmd, @enumFromInt(byte[0])));
    try testing.expectEqual(@as(isize, 1), c.read(fds[0], &byte, 1));
    try testing.expectEqual(Cmd.focus_gained, @as(Cmd, @enumFromInt(byte[0])));
    try testing.expectEqual(@as(isize, 1), c.read(fds[0], &byte, 1));
    try testing.expectEqual(Cmd.focus_lost, @as(Cmd, @enumFromInt(byte[0])));
    try testing.expectEqual(@as(isize, 1), c.read(fds[0], &byte, 1));
    try testing.expectEqual(Cmd.low_memory, @as(Cmd, @enumFromInt(byte[0])));
}

test "opening off Android says so rather than failing to build" {
    const impl = open(testing.allocator) catch |err| {
        try testing.expect(err == error.Unsupported or err == error.NoDisplay or
            err == error.ConnectionFailed);
        return;
    };
    defer vtable.deinit(impl, testing.allocator);
    try testing.expectEqual(platform.Backend.android, vtable.backend);
}
