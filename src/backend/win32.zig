// SPDX-License-Identifier: BSL-1.0

//! The Win32 backend: `user32.dll`, and one window class.
//!
//! Every entry point is fetched by name through `fluxion-dyn` rather than
//! imported. Not ceremony: `GetDpiForWindow` arrived in Windows 10 1607 and
//! `SetProcessDpiAwarenessContext` in 1703, and a program that imports either
//! the ordinary way does not start on anything older - the loader fails before
//! `main`, with no chance to fall back to the 96-DPI answer. Declared optional
//! here, they are `null` on such a machine and the code asks.
//!
//! **Messages arrive on the thread that made the window.** Windows delivers to
//! the creating thread's queue, so `pump` has to run there, and a context used
//! from a second thread simply never sees an event. That is the rule `Context`
//! documents, and this is where it comes from.
//!
//! **Keys are read from the scancode, not the virtual key.** A `VK_` code is
//! what the current layout says the key means, so `VK_Q` is a different
//! physical key on AZERTY than on QWERTY and a WASD binding moves under the
//! user. The scancode in `lParam` is the position, which is what `Key` promises.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const dyn = @import("fluxion_dyn");

const backend = @import("../backend.zig");
const cursor_mod = @import("../cursor.zig");
const event = @import("../event.zig");
const input = @import("../input.zig");
const monitor = @import("../monitor.zig");
const gamepad = @import("../gamepad.zig");
const xinput = @import("xinput.zig");
const wgl = @import("wgl.zig");
const gl = @import("../gl.zig");
const vulkan = @import("../vulkan.zig");
const text_mod = @import("../text.zig");
const keys = @import("../keys.zig");
const platform = @import("../platform.zig");
const virtual_key = @import("virtual_key.zig");
const clipboard = @import("clipboard.zig");
const win32_dialog = @import("win32_dialog.zig");

const Error = platform.Error;

comptime {
    if (builtin.os.tag != .windows) @compileError(
        "fluxion-platform: the win32 backend builds only for a Windows target",
    );
}

// -------------------------------------------------------------------------
// The slice of Win32 this backend speaks
// -------------------------------------------------------------------------

const HWND = *opaque {};
const HINSTANCE = *opaque {};
const HICON = *opaque {};
const HCURSOR = *opaque {};
const HBRUSH = *opaque {};
const HMENU = *opaque {};

const LRESULT = isize;
const WPARAM = usize;
const LPARAM = isize;

const WndProc = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const Point = extern struct { x: i32 = 0, y: i32 = 0 };
const Rect = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

/// `MONITORINFOEXW`. The plain `MONITORINFO` stops before `device`, and the
/// device name is the whole point: it is what `EnumDisplaySettingsW` wants.
const MonitorInfoExW = extern struct {
    size: u32 = @sizeOf(MonitorInfoExW),
    monitor: Rect = .{},
    work: Rect = .{},
    flags: u32 = 0,
    device: [32]u16 = @splat(0),
};

/// `DEVMODEW`, in full. Only a handful of the fields are read, but the struct
/// is passed to Windows by size and a short one would be filled in wrongly.
const DevModeW = extern struct {
    device_name: [32]u16 = @splat(0),
    spec_version: u16 = 0,
    driver_version: u16 = 0,
    size: u16 = @sizeOf(DevModeW),
    driver_extra: u16 = 0,
    fields: u32 = 0,
    position: Point = .{},
    display_orientation: u32 = 0,
    display_fixed_output: u32 = 0,
    color: i16 = 0,
    duplex: i16 = 0,
    y_resolution: i16 = 0,
    tt_option: i16 = 0,
    collate: i16 = 0,
    form_name: [32]u16 = @splat(0),
    log_pixels: u16 = 0,
    bits_per_pel: u32 = 0,
    pels_width: u32 = 0,
    pels_height: u32 = 0,
    display_flags: u32 = 0,
    display_frequency: u32 = 0,
    icm_method: u32 = 0,
    icm_intent: u32 = 0,
    media_type: u32 = 0,
    dither_type: u32 = 0,
    reserved1: u32 = 0,
    reserved2: u32 = 0,
    panning_width: u32 = 0,
    panning_height: u32 = 0,
};

/// `DISPLAY_DEVICEW`, for turning `\\.\DISPLAY1` into something a person
/// would recognise.
const DisplayDeviceW = extern struct {
    size: u32 = @sizeOf(DisplayDeviceW),
    device_name: [32]u16 = @splat(0),
    device_string: [128]u16 = @splat(0),
    state_flags: u32 = 0,
    device_id: [128]u16 = @splat(0),
    device_key: [128]u16 = @splat(0),
};

/// `COMPOSITIONFORM`, which is where the composed text is drawn.
const CompositionForm = extern struct {
    style: u32 = 0,
    current_pos: Point = .{},
    area: Rect = .{},
};

/// `CANDIDATEFORM`, which is where the list of candidates goes. Separate from
/// the composition, because an input method draws them in different places.
const CandidateForm = extern struct {
    index: u32 = 0,
    style: u32 = 0,
    current_pos: Point = .{},
    area: Rect = .{},
};

const Msg = extern struct {
    hwnd: ?HWND = null,
    message: u32 = 0,
    wparam: WPARAM = 0,
    lparam: LPARAM = 0,
    time: u32 = 0,
    pt: Point = .{},
};

const WndClassExW = extern struct {
    size: u32,
    style: u32,
    wnd_proc: WndProc,
    cls_extra: i32,
    wnd_extra: i32,
    instance: HINSTANCE,
    icon: ?HICON,
    cursor: ?HCURSOR,
    background: ?HBRUSH,
    menu_name: ?[*:0]const u16,
    class_name: [*:0]const u16,
    icon_small: ?HICON,
};

const CreateStructW = extern struct {
    create_params: ?*anyopaque,
    instance: ?HINSTANCE,
    menu: ?HMENU,
    parent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    name: ?[*:0]const u16,
    class: ?[*:0]const u16,
    ex_style: u32,
};

const cs_hredraw: u32 = 0x0002;
const cs_vredraw: u32 = 0x0001;
const cs_owndc: u32 = 0x0020;
const cs_dblclks: u32 = 0x0008;

const ws_overlapped: u32 = 0x00000000;
const ws_caption: u32 = 0x00C00000;
const ws_sysmenu: u32 = 0x00080000;
const ws_thickframe: u32 = 0x00040000;
const ws_minimizebox: u32 = 0x00020000;
const ws_maximizebox: u32 = 0x00010000;
const ws_popup: u32 = 0x80000000;
const ws_visible: u32 = 0x10000000;
const ws_maximize: u32 = 0x01000000;
const ws_clipsiblings: u32 = 0x04000000;
const ws_clipchildren: u32 = 0x02000000;

const sw_hide: i32 = 0;
const sw_show: i32 = 5;

const pm_noremove: u32 = 0x0000;
const pm_remove: u32 = 0x0001;
const qs_sendmessage: u32 = 0x0040;
const pm_qs_sendmessage: u32 = qs_sendmessage << 16;
const wait_object_0: u32 = 0;
const cw_usedefault: i32 = @bitCast(@as(u32, 0x80000000));

const gwlp_userdata: i32 = -21;
const gwl_exstyle: i32 = -20;

const sw_minimize: i32 = 6;
const sw_restore: i32 = 9;
const sw_maximize: i32 = 3;
const sw_shownormal: u32 = 1;

const WindowPlacement = extern struct {
    length: u32 = @sizeOf(WindowPlacement),
    flags: u32 = 0,
    show_cmd: u32 = 0,
    min_position: Point = .{},
    max_position: Point = .{},
    normal_position: Rect = .{},
};

/// Set on a window minimised from maximised: un-minimising maximises it again.
const wpf_restoretomaximized: u32 = 0x0002;
/// Answers for a minimised window too, from where it will come back.
const monitor_defaulttonearest: u32 = 0x00000002;

const swp_nosize: u32 = 0x0001;
const swp_nomove: u32 = 0x0002;
const swp_nozorder: u32 = 0x0004;
const swp_noactivate: u32 = 0x0010;

const gwl_style: i32 = -16;
const swp_framechanged: u32 = 0x0020;
const swp_showwindow: u32 = 0x0040;
const swp_nocopybits: u32 = 0x0100;
/// `HWND_TOP`, which is a window handle that is really a small number.
const hwnd_top: ?HWND = null;

/// `MONITORINFOF_PRIMARY`.
const monitorinfof_primary: u32 = 0x00000001;
/// `ENUM_CURRENT_SETTINGS`, as an unsigned mode index of -1.
const enum_current_settings: u32 = 0xFFFFFFFF;
/// `DISPLAY_DEVICE_ACTIVE`.
const display_device_active: u32 = 0x00000001;
/// `CDS_FULLSCREEN`: the change is temporary and belongs to this program, so
/// closing it - or crashing - puts the desktop back.
const cds_fullscreen: u32 = 0x00000004;
const disp_change_successful: i32 = 0;
/// `MDT_EFFECTIVE_DPI`: the DPI the user chose, which is the one to scale by.
const mdt_effective_dpi: u32 = 0;
/// `GetDeviceCaps` indices for the screen in millimetres. Not 4 and 8: 8 is
/// `HORZRES`, which is pixels, and reads as a plausible number of millimetres.
const horzsize: i32 = 4;
const vertsize: i32 = 6;

const ws_ex_layered: u32 = 0x00080000;
const lwa_alpha: u32 = 0x00000002;

/// `WM_GETMINMAXINFO` carries these, and this is where a size limit is applied.
const wm_getminmaxinfo: u32 = 0x0024;

const MinMaxInfo = extern struct {
    reserved: Point,
    max_size: Point,
    max_position: Point,
    min_track_size: Point,
    max_track_size: Point,
};

// The standard cursors, as the integer resource ids `LoadCursorW` takes.
const idc_arrow: *const anyopaque = @ptrFromInt(32512);
const idc_ibeam: *const anyopaque = @ptrFromInt(32513);
const idc_cross: *const anyopaque = @ptrFromInt(32515);
const idc_sizenwse: *const anyopaque = @ptrFromInt(32642);
const idc_sizenesw: *const anyopaque = @ptrFromInt(32643);
const idc_sizewe: *const anyopaque = @ptrFromInt(32644);
const idc_sizens: *const anyopaque = @ptrFromInt(32645);
const idc_sizeall: *const anyopaque = @ptrFromInt(32646);
const idc_no: *const anyopaque = @ptrFromInt(32648);
const idc_hand: *const anyopaque = @ptrFromInt(32649);

const wm_setcursor: u32 = 0x0020;
const wm_mouseactivate: u32 = 0x0021;
const wm_capturechanged: u32 = 0x0215;
const wm_input: u32 = 0x00FF;
const htclient: isize = 1;

/// `RAWINPUTDEVICE`, and the two flags this needs: no legacy messages while
/// the mouse is captured, and remove the device when the window goes.
const RawInputDevice = extern struct {
    usage_page: u16,
    usage: u16,
    flags: u32,
    target: ?HWND,
};

const hid_usage_page_generic: u16 = 0x01;
const hid_usage_generic_mouse: u16 = 0x02;
const ridev_remove: u32 = 0x00000001;
const ridev_inputsink: u32 = 0x00000100;
const rid_input: u32 = 0x10000003;

/// The head of a `RAWINPUT`, followed by the mouse payload.
const RawInputHeader = extern struct {
    kind: u32,
    size: u32,
    device: ?*anyopaque,
    wparam: usize,
};

const RawMouse = extern struct {
    flags: u16,
    button_flags: u16,
    button_data: u16,
    raw_buttons: u32,
    last_x: i32,
    last_y: i32,
    extra: u32,
};

const RawInput = extern struct {
    header: RawInputHeader,
    mouse: RawMouse,
};

const rim_typemouse: u32 = 0;
/// `MOUSE_MOVE_ABSOLUTE`: some devices - a tablet, a remote desktop - report a
/// position rather than a delta, and the difference has to be taken by hand.
const mouse_move_absolute: u16 = 0x01;

const wm_destroy: u32 = 0x0002;
const wm_size: u32 = 0x0005;
const wm_setfocus: u32 = 0x0007;
const wm_killfocus: u32 = 0x0008;
const wm_close: u32 = 0x0010;
const wm_paint: u32 = 0x000F;
const wm_nccreate: u32 = 0x0081;
const wm_keydown: u32 = 0x0100;
const wm_keyup: u32 = 0x0101;
const wm_char: u32 = 0x0102;
const wm_syskeydown: u32 = 0x0104;
const wm_syskeyup: u32 = 0x0105;
const wm_move: u32 = 0x0003;
const wm_mousemove: u32 = 0x0200;
const wm_lbuttondown: u32 = 0x0201;
const wm_lbuttonup: u32 = 0x0202;
const wm_lbuttondblclk: u32 = 0x0203;
const wm_rbuttondown: u32 = 0x0204;
const wm_rbuttonup: u32 = 0x0205;
const wm_rbuttondblclk: u32 = 0x0206;
const wm_mbuttondown: u32 = 0x0207;
const wm_mbuttonup: u32 = 0x0208;
const wm_mbuttondblclk: u32 = 0x0209;
const wm_mousewheel: u32 = 0x020A;
const wm_xbuttondown: u32 = 0x020B;
const wm_xbuttonup: u32 = 0x020C;
const wm_xbuttondblclk: u32 = 0x020D;
const wm_mousehwheel: u32 = 0x020E;
const wm_dpichanged: u32 = 0x02E0;
const wm_dropfiles: u32 = 0x0233;
const wm_null: u32 = 0x0000;
const wm_ime_startcomposition: u32 = 0x010D;
const wm_ime_endcomposition: u32 = 0x010E;
const wm_ime_composition: u32 = 0x010F;

/// `GCS_*`: which part of the composition to read.
const gcs_compstr: u32 = 0x0008;
const gcs_cursorpos: u32 = 0x0080;
const gcs_resultstr: u32 = 0x0800;

/// `CFS_POINT` and `CFS_EXCLUDE`: place the composition at a point, and keep
/// the candidate list clear of a rectangle.
const cfs_point: u32 = 0x0002;
const cfs_exclude: u32 = 0x0080;

/// `IACE_DEFAULT`, which gives a window the system's own input context back.
const iace_default: u32 = 0x0010;

const size_restored: WPARAM = 0;
const size_minimized: WPARAM = 1;
const size_maximized: WPARAM = 2;

const vk_shift: i32 = 0x10;
const vk_control: i32 = 0x11;
const vk_menu: i32 = 0x12;
const vk_lcontrol: i32 = 0xA2;
const vk_rcontrol: i32 = 0xA3;
const vk_lmenu: i32 = 0xA4;
const vk_rmenu: i32 = 0xA5;
const vk_lwin: i32 = 0x5B;
const vk_rwin: i32 = 0x5C;
const vk_capital: i32 = 0x14;
const vk_numlock: i32 = 0x90;
/// What every key arrives as while an input method is working on it: the
/// method has the key, and which one it was is not this message's to say.
const vk_processkey: WPARAM = 0xE5;

/// `MAPVK_VK_TO_VSC`, which is the direction this needs: a virtual key back to
/// the position it would have come from.
const mapvk_vk_to_vsc: u32 = 0;

const wheel_delta: f64 = 120.0;

/// The `user32.dll` entry points this backend needs.
///
/// The optional ones are the DPI calls, which are Windows 10 and later. A
/// machine without them is not a machine this library refuses to run on: it is
/// one where every window reports a content scale of 1.
const User32 = struct {
    RegisterClassExW: *const fn (*const WndClassExW) callconv(.winapi) u16,
    UnregisterClassW: *const fn ([*:0]const u16, HINSTANCE) callconv(.winapi) i32,
    CreateWindowExW: *const fn (
        u32,
        [*:0]const u16,
        [*:0]const u16,
        u32,
        i32,
        i32,
        i32,
        i32,
        ?HWND,
        ?HMENU,
        HINSTANCE,
        ?*anyopaque,
    ) callconv(.winapi) ?HWND,
    DestroyWindow: *const fn (HWND) callconv(.winapi) i32,
    DefWindowProcW: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    ShowWindow: *const fn (HWND, i32) callconv(.winapi) i32,
    PeekMessageW: *const fn (*Msg, ?HWND, u32, u32, u32) callconv(.winapi) i32,
    TranslateMessage: *const fn (*const Msg) callconv(.winapi) i32,
    DispatchMessageW: *const fn (*const Msg) callconv(.winapi) LRESULT,
    PostMessageW: *const fn (?HWND, u32, WPARAM, LPARAM) callconv(.winapi) i32,
    GetClientRect: *const fn (HWND, *Rect) callconv(.winapi) i32,
    SetWindowTextW: *const fn (HWND, [*:0]const u16) callconv(.winapi) i32,
    AdjustWindowRectEx: *const fn (*Rect, u32, i32, u32) callconv(.winapi) i32,
    /// The second argument is either a name or, as here, an integer id wearing
    /// a pointer's type - `MAKEINTRESOURCE`. Untyped, because half the ids are
    /// odd addresses and a `u16` pointer may not be.
    LoadCursorW: *const fn (?HINSTANCE, ?*const anyopaque) callconv(.winapi) ?HCURSOR,
    GetKeyState: *const fn (i32) callconv(.winapi) i16,
    GetMessageTime: *const fn () callconv(.winapi) i32,
    SystemParametersInfoW: *const fn (u32, u32, ?*anyopaque, u32) callconv(.winapi) i32,
    GetDoubleClickTime: *const fn () callconv(.winapi) u32,
    GetCaretBlinkTime: *const fn () callconv(.winapi) u32,
    /// A virtual key into a scan code, for a keystroke that arrived without
    /// one. See `scancodeFrom`.
    MapVirtualKeyW: *const fn (u32, u32) callconv(.winapi) u32,
    MsgWaitForMultipleObjects: *const fn (u32, ?*const anyopaque, i32, u32, u32) callconv(.winapi) u32,

    // 64-bit Windows exports the `Ptr` forms and 32-bit does not; on 32-bit the
    // plain ones are the same width anyway. All four are optional, and the code
    // takes whichever this machine turned out to have, because one build has to
    // run on both.
    SetWindowLongPtrW: ?*const fn (HWND, i32, isize) callconv(.winapi) isize = null,
    GetWindowLongPtrW: ?*const fn (HWND, i32) callconv(.winapi) isize = null,
    SetWindowLongW: ?*const fn (HWND, i32, i32) callconv(.winapi) i32 = null,
    GetWindowLongW: ?*const fn (HWND, i32) callconv(.winapi) i32 = null,

    GetWindowRect: *const fn (HWND, *Rect) callconv(.winapi) i32,
    /// A window's own drawing surface, which is what a GL context is made
    /// against. `CS_OWNDC` on the class means one per window that lives as
    /// long as the window does, so it is fetched once and never released.
    GetDC: *const fn (?HWND) callconv(.winapi) ?*anyopaque,
    ReleaseDC: *const fn (?HWND, ?*anyopaque) callconv(.winapi) i32,
    EnumDisplayMonitors: *const fn (
        ?*anyopaque,
        ?*const Rect,
        *const fn (?*anyopaque, ?*anyopaque, *Rect, isize) callconv(.winapi) i32,
        isize,
    ) callconv(.winapi) i32,
    GetMonitorInfoW: *const fn (?*anyopaque, *MonitorInfoExW) callconv(.winapi) i32,
    EnumDisplaySettingsW: *const fn (?[*:0]const u16, u32, *DevModeW) callconv(.winapi) i32,
    EnumDisplayDevicesW: *const fn (?[*:0]const u16, u32, *DisplayDeviceW, u32) callconv(.winapi) i32,
    ChangeDisplaySettingsExW: *const fn (
        ?[*:0]const u16,
        ?*DevModeW,
        ?HWND,
        u32,
        ?*anyopaque,
    ) callconv(.winapi) i32,
    SetCursor: *const fn (?HCURSOR) callconv(.winapi) ?HCURSOR,
    SetCursorPos: *const fn (i32, i32) callconv(.winapi) i32,
    GetCursorPos: *const fn (*Point) callconv(.winapi) i32,
    ScreenToClient: *const fn (HWND, *Point) callconv(.winapi) i32,
    ClipCursor: *const fn (?*const Rect) callconv(.winapi) i32,
    RegisterRawInputDevices: *const fn ([*]const RawInputDevice, u32, u32) callconv(.winapi) i32,
    GetRawInputData: *const fn (?*anyopaque, u32, ?*anyopaque, *u32, u32) callconv(.winapi) u32,
    SetWindowPos: *const fn (HWND, ?HWND, i32, i32, i32, i32, u32) callconv(.winapi) i32,
    IsIconic: *const fn (HWND) callconv(.winapi) i32,
    IsZoomed: *const fn (HWND) callconv(.winapi) i32,
    GetWindowPlacement: *const fn (HWND, *WindowPlacement) callconv(.winapi) i32,
    SetWindowPlacement: *const fn (HWND, *const WindowPlacement) callconv(.winapi) i32,
    MonitorFromWindow: *const fn (HWND, u32) callconv(.winapi) ?*anyopaque,
    GetForegroundWindow: *const fn () callconv(.winapi) ?HWND,
    SetForegroundWindow: *const fn (HWND) callconv(.winapi) i32,
    FlashWindow: *const fn (HWND, i32) callconv(.winapi) i32,
    ClientToScreen: *const fn (HWND, *Point) callconv(.winapi) i32,
    OpenClipboard: *const fn (?HWND) callconv(.winapi) i32,
    CloseClipboard: *const fn () callconv(.winapi) i32,
    EmptyClipboard: *const fn () callconv(.winapi) i32,
    SetClipboardData: *const fn (u32, ?*anyopaque) callconv(.winapi) ?*anyopaque,
    GetClipboardData: *const fn (u32) callconv(.winapi) ?*anyopaque,
    IsClipboardFormatAvailable: *const fn (u32) callconv(.winapi) i32,
    EnumThreadWindows: *const fn (u32, *const fn (HWND, LPARAM) callconv(.winapi) i32, LPARAM) callconv(.winapi) i32,
    GetClassNameW: *const fn (HWND, [*]u16, i32) callconv(.winapi) i32,
    /// Layered-window transparency. Windows 2000 and later, so present
    /// everywhere this library runs, but optional rather than assumed.
    SetLayeredWindowAttributes: ?*const fn (HWND, u32, u8, u32) callconv(.winapi) i32 = null,

    /// Windows 10 1607. Absent before it, and then every window is 96 DPI.
    GetDpiForWindow: ?*const fn (HWND) callconv(.winapi) u32 = null,
    /// Windows 10 1703. Without it a program is scaled by the system and gets
    /// a blurry window rather than a wrong one, which is the better failure.
    SetProcessDpiAwarenessContext: ?*const fn (isize) callconv(.winapi) i32 = null,
};

const Kernel32 = struct {
    GetModuleHandleW: *const fn (?[*:0]const u16) callconv(.winapi) ?HINSTANCE,
    /// The clipboard takes its text as a movable global block, which it then
    /// owns - the one allocator it will accept.
    GlobalAlloc: *const fn (u32, usize) callconv(.winapi) ?*anyopaque,
    GlobalFree: *const fn (?*anyopaque) callconv(.winapi) ?*anyopaque,
    GlobalLock: *const fn (?*anyopaque) callconv(.winapi) ?*anyopaque,
    GlobalUnlock: *const fn (?*anyopaque) callconv(.winapi) i32,
    GlobalSize: *const fn (?*anyopaque) callconv(.winapi) usize,
    Sleep: *const fn (u32) callconv(.winapi) void,
    WaitForSingleObject: *const fn (*anyopaque, u32) callconv(.winapi) u32,
    GetThreadId: *const fn (*anyopaque) callconv(.winapi) u32,
    CreateFileW: *const fn ([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) ?*anyopaque,
    GetFileSizeEx: *const fn (*anyopaque, *i64) callconv(.winapi) i32,
    ReadFile: *const fn (*anyopaque, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32,
    CloseHandle: *const fn (*anyopaque) callconv(.winapi) i32,
};

/// `CF_UNICODETEXT`. Windows makes the other text formats from it, and it from
/// them, so it is the only one to write and the only one to ask for.
const cf_unicodetext: u32 = 13;
const gmem_moveable: u32 = 0x0002;
/// `HWND_MESSAGE`: the parent that makes a window message-only - never shown,
/// never enumerated, there only to be named.
const hwnd_message: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

/// Only for a monitor's size in millimetres, which is the one thing `user32`
/// will not say. A machine without it reports zero rather than failing.
const Gdi32 = struct {
    CreateDCW: *const fn (?[*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, ?*const anyopaque) callconv(.winapi) ?*anyopaque,
    DeleteDC: *const fn (?*anyopaque) callconv(.winapi) i32,
    GetDeviceCaps: *const fn (?*anyopaque, i32) callconv(.winapi) i32,
};

/// Windows 8.1 and later. Before it every monitor is 96 DPI as far as this
/// library can tell, which is what the machine was anyway.
const Shcore = struct {
    GetDpiForMonitor: *const fn (?*anyopaque, u32, *u32, *u32) callconv(.winapi) i32,
};

/// The input method: composing text that has not been committed, and the
/// candidate window that goes with it.
///
/// A separate library from `user32`, and one a machine can be missing - a
/// Windows install with no input method installed at all. Then text still
/// arrives through `WM_CHAR` and only the composition is absent, which is the
/// right way round.
const Imm32 = struct {
    ImmGetContext: *const fn (HWND) callconv(.winapi) ?*anyopaque,
    ImmReleaseContext: *const fn (HWND, ?*anyopaque) callconv(.winapi) i32,
    ImmGetCompositionStringW: *const fn (?*anyopaque, u32, ?*anyopaque, u32) callconv(.winapi) i32,
    ImmSetCompositionWindow: *const fn (?*anyopaque, *const CompositionForm) callconv(.winapi) i32,
    ImmSetCandidateWindow: *const fn (?*anyopaque, *const CandidateForm) callconv(.winapi) i32,
    /// Detaching the input context is how text input is turned off: a window
    /// with none cannot open a candidate window over a game.
    ImmAssociateContextEx: *const fn (HWND, ?*anyopaque, u32) callconv(.winapi) i32,
};

/// Files dropped on a window from the file manager: a window says it takes
/// them, and each drop arrives as a `WM_DROPFILES` whose handle holds the
/// paths and the point. In `shell32.dll`, which every Windows has; optional
/// all the same, like the rest - without it a window takes no drops.
const Drops = struct {
    DragAcceptFiles: *const fn (HWND, i32) callconv(.winapi) void,
    DragQueryFileW: *const fn (?*anyopaque, u32, ?[*]u16, u32) callconv(.winapi) u32,
    DragQueryPoint: *const fn (?*anyopaque, *Point) callconv(.winapi) i32,
    DragFinish: *const fn (?*anyopaque) callconv(.winapi) void,
};

/// `DragQueryFileW`'s index for "how many files".
const drop_count: u32 = 0xFFFFFFFF;

/// `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`, which is the handle -4 rather
/// than a pointer to anything.
const dpi_per_monitor_v2: isize = -4;

// -------------------------------------------------------------------------
// State
// -------------------------------------------------------------------------

const class_name: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("fluxion.platform.window");

const Impl = struct {
    gpa: Allocator,
    user32: dyn.Library,
    kernel32: dyn.Library,
    u: User32,
    k: Kernel32,
    instance: HINSTANCE,
    atom: u16,
    /// Null on a machine that has neither, which costs a monitor's physical
    /// size and its per-monitor scale and nothing else.
    /// Controllers, which are not a windowing-system idea at all: XInput is a
    /// separate library and a separate question, asked from the same pump.
    pads: xinput.Backend = .{},
    /// OpenGL, which on Windows means WGL and a dance with a throwaway window.
    /// See `wgl` for why.
    gl: wgl.Backend = .{},

    /// The input method, and what it is composing. One composition at a time,
    /// because one window has focus at a time.
    imm32: ?dyn.Library = null,
    imm: ?Imm32 = null,
    preedit: text_mod.Preedit = .{},
    gdi32: ?dyn.Library = null,
    g: ?Gdi32 = null,
    shcore: ?dyn.Library = null,
    sh: ?Shcore = null,
    shell32: ?dyn.Library = null,
    drops: ?Drops = null,
    /// Where a window procedure puts what it produced. Set for the length of
    /// one `pump` and null the rest of the time, because a message that arrives
    /// outside a pump - Windows sends a few during `CreateWindowExW` - has
    /// nowhere to go and is kept in `later` rather than written through a
    /// stale pointer.
    queue: ?*backend.Queue = null,
    later: backend.Later = .{},
    /// Set when pushing an event ran out of memory. Reported by `pump`, because
    /// a window procedure has no way to fail.
    push_failed: bool = false,
    /// AltGr is down: the left control Windows made up for it was taken out.
    alt_graph: bool = false,
    /// What owns the text this program puts on the clipboard. Made on the first
    /// copy; see `clipboardOwner`.
    clipboard_owner: ?HWND = null,

    /// Loaded for the first file dialog.
    shell: ?win32_dialog.Shell = null,
    /// The file dialog that is open, whose thread's end `pump` looks for.
    dialog: ?*win32_dialog.Dialog = null,
    /// What the last dialog's answer and the last drop carried, kept until
    /// the next pump.
    answers: std.heap.ArenaAllocator,
};

const Native = struct {
    hwnd: HWND,
    id: event.WindowId,
    impl: *Impl,
    /// The last cursor position, for the delta in a `.cursor` event.
    last_x: f64 = 0,
    last_y: f64 = 0,
    has_position: bool = false,
    /// A high surrogate waiting for its low half. UTF-16 splits a codepoint
    /// above the BMP across two `WM_CHAR` messages, and an emoji is two.
    pending_surrogate: ?u16 = null,
    /// Applied in `WM_GETMINMAXINFO`, which is the only place Windows asks.
    limits: backend.SizeLimits = .{},
    style: u32 = 0,

    iconified: bool = false,
    maximized: bool = false,
    /// The last real content area: Windows reports a minimised window as 0x0.
    fb_width: u32 = 0,
    fb_height: u32 = 0,

    focused: bool = false,
    held: bool = false,
    /// Activated by a click on the frame: holding the pointer now would stop the drag.
    frame_click: bool = false,

    mode: cursor_mod.Mode = .normal,
    raw_motion: bool = false,
    /// The shape to put back whenever Windows asks, which it does every time
    /// the pointer moves over the window.
    shape: ?HCURSOR = null,
    /// Where the pointer was parked when `disabled` began, so `normal` can put
    /// it back rather than leaving it in the middle of the screen.
    saved_x: i32 = 0,
    saved_y: i32 = 0,
    /// The last absolute position a raw device reported, for the ones that
    /// report where rather than how far.
    raw_last_x: i32 = 0,
    raw_last_y: i32 = 0,
    has_raw_last: bool = false,

    /// Where the window was before it went fullscreen, so that leaving puts it
    /// back rather than in the corner.
    saved_frame: Rect = .{},
    saved_style: u32 = 0,
    /// The display whose mode this window changed, so leaving can change it
    /// back. Empty unless an `.exclusive` fullscreen is in force.
    mode_changed_on: [32]u16 = @splat(0),
    is_fullscreen: bool = false,

    /// Set only when the window was asked for one. A window's pixel format is
    /// chosen once, so this is decided at creation and never after.
    context: ?wgl.Context = null,
};

// -------------------------------------------------------------------------
// Opening
// -------------------------------------------------------------------------

pub const vtable: backend.Vtable = .{
    .backend = .win32,
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
    .scrollLines = scrollLines,
    .doubleClickTime = doubleClickTime,
    .caretBlinkTime = caretBlinkTime,
    .windowMonitor = windowMonitor,
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
    const self = gpa.create(Impl) catch return error.OutOfMemory;
    errdefer gpa.destroy(self);

    var user32 = dyn.openSystem("user32.dll") catch return error.ConnectionFailed;
    errdefer user32.close();
    var kernel32 = dyn.openSystem("kernel32.dll") catch return error.ConnectionFailed;
    errdefer kernel32.close();

    const u = user32.bind(User32) catch return error.ConnectionFailed;
    const k = kernel32.bind(Kernel32) catch return error.ConnectionFailed;

    const instance = k.GetModuleHandleW(null) orelse return error.ConnectionFailed;

    // Before the first window, so that it is created at the monitor's real
    // resolution rather than scaled up from a third of the pixels.
    if (u.SetProcessDpiAwarenessContext) |aware| {
        _ = aware(dpi_per_monitor_v2);
    }

    const class: WndClassExW = .{
        .size = @sizeOf(WndClassExW),
        .style = cs_hredraw | cs_vredraw | cs_owndc | cs_dblclks,
        .wnd_proc = windowProc,
        .cls_extra = 0,
        .wnd_extra = 0,
        .instance = instance,
        .icon = null,
        .cursor = u.LoadCursorW(null, idc_arrow),
        .background = null,
        .menu_name = null,
        .class_name = class_name,
        .icon_small = null,
    };
    const atom = u.RegisterClassExW(&class);
    if (atom == 0) return error.ConnectionFailed;

    // Optional, and separately: a machine may have one and not the other, and
    // neither is worth refusing to open a window over.
    var gdi32: ?dyn.Library = dyn.openSystem("gdi32.dll") catch null;
    const g: ?Gdi32 = if (gdi32) |*lib| (lib.bind(Gdi32) catch null) else null;
    if (g == null) {
        if (gdi32) |*lib| lib.close();
        gdi32 = null;
    }

    // Optional, like the rest: text still arrives without it.
    var imm32: ?dyn.Library = dyn.openSystem("imm32.dll") catch null;
    const imm: ?Imm32 = if (imm32) |*lib| (lib.bind(Imm32) catch null) else null;
    if (imm == null) {
        if (imm32) |*lib| lib.close();
        imm32 = null;
    }

    var shcore: ?dyn.Library = dyn.openSystem("shcore.dll") catch null;
    const sh: ?Shcore = if (shcore) |*lib| (lib.bind(Shcore) catch null) else null;
    if (sh == null) {
        if (shcore) |*lib| lib.close();
        shcore = null;
    }

    var shell32: ?dyn.Library = dyn.openSystem("shell32.dll") catch null;
    const drops: ?Drops = if (shell32) |*lib| (lib.bind(Drops) catch null) else null;
    if (drops == null) {
        if (shell32) |*lib| lib.close();
        shell32 = null;
    }

    self.* = .{
        .gpa = gpa,
        .pads = xinput.Backend.open(),
        .gl = wgl.Backend.open(),
        .user32 = user32,
        .kernel32 = kernel32,
        .gdi32 = gdi32,
        .g = g,
        .imm32 = imm32,
        .imm = imm,
        .shcore = shcore,
        .sh = sh,
        .shell32 = shell32,
        .drops = drops,
        .u = u,
        .k = k,
        .instance = instance,
        .atom = atom,
        .answers = .init(gpa),
    };
    return self;
}

fn deinit(impl: backend.Impl, gpa: Allocator) void {
    const self = cast(impl);
    if (self.dialog) |job| endDialog(self, job);
    self.answers.deinit();
    if (self.shell) |*shell| shell.close();
    // The text stays on the clipboard: it was handed over, not lent.
    if (self.clipboard_owner) |hwnd| _ = self.u.DestroyWindow(hwnd);
    _ = self.u.UnregisterClassW(class_name, self.instance);
    self.pads.close();
    self.gl.close();
    if (self.imm32) |*lib| lib.close();
    if (self.gdi32) |*lib| lib.close();
    if (self.shcore) |*lib| lib.close();
    if (self.shell32) |*lib| lib.close();
    self.later.deinit(self.gpa);
    self.user32.close();
    self.kernel32.close();
    gpa.destroy(self);
}

fn cast(impl: backend.Impl) *Impl {
    return @ptrCast(@alignCast(impl));
}

fn castWindow(native: backend.NativeWindow) *Native {
    return @ptrCast(@alignCast(native));
}

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------

fn setUserData(self: *Impl, hwnd: HWND, value: *Native) void {
    if (self.u.SetWindowLongPtrW) |set| {
        _ = set(hwnd, gwlp_userdata, @bitCast(@intFromPtr(value)));
    } else if (self.u.SetWindowLongW) |set| {
        _ = set(hwnd, gwlp_userdata, @truncate(@as(isize, @bitCast(@intFromPtr(value)))));
    }
}

fn userData(self: *Impl, hwnd: HWND) ?*Native {
    const raw: isize = if (self.u.GetWindowLongPtrW) |get|
        get(hwnd, gwlp_userdata)
    else if (self.u.GetWindowLongW) |get|
        get(hwnd, gwlp_userdata)
    else
        0;
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn styleFor(desc: backend.WindowDesc) u32 {
    var style: u32 = ws_clipsiblings | ws_clipchildren;
    if (desc.decorated) {
        style |= ws_overlapped | ws_caption | ws_sysmenu | ws_minimizebox;
        if (desc.resizable) style |= ws_thickframe | ws_maximizebox;
    } else {
        style |= ws_popup;
    }
    if (desc.visible) style |= ws_visible;
    if (desc.maximized and desc.resizable) style |= ws_maximize;
    return style;
}

fn createWindow(
    impl: backend.Impl,
    gpa: Allocator,
    id: event.WindowId,
    desc: backend.WindowDesc,
) Error!backend.NativeWindow {
    const self = cast(impl);

    const native = gpa.create(Native) catch return error.OutOfMemory;
    errdefer gpa.destroy(native);

    const title = try toWide(gpa, desc.title);
    defer gpa.free(title);

    const style = styleFor(desc);

    // The size asked for is the content area, and `CreateWindowExW` takes the
    // whole window, so the frame has to be added on or every window comes out
    // a title bar short.
    var rect: Rect = .{
        .left = 0,
        .top = 0,
        .right = @intCast(desc.width),
        .bottom = @intCast(desc.height),
    };
    _ = self.u.AdjustWindowRectEx(&rect, style, 0, 0);

    native.* = .{ .hwnd = undefined, .id = id, .impl = self, .style = style };

    const hwnd = self.u.CreateWindowExW(
        0,
        class_name,
        title.ptr,
        style,
        cw_usedefault,
        cw_usedefault,
        rect.right - rect.left,
        rect.bottom - rect.top,
        null,
        null,
        self.instance,
        native,
    ) orelse return error.WindowCreationFailed;

    native.hwnd = hwnd;
    // `WM_NCCREATE` already set this from `create_params`, but only on the path
    // where that message reached the procedure. Setting it again is harmless
    // and covers the case where it did not.
    setUserData(self, hwnd, native);
    if (self.drops) |calls| calls.DragAcceptFiles(hwnd, 1);

    if (desc.gl) |config| {
        errdefer _ = self.u.DestroyWindow(hwnd);
        native.context = try attachContext(self, hwnd, config);
    }

    return native;
}

/// Give a freshly made window a pixel format and a GL context.
///
/// The first call also does the throwaway-window dance that finds the modern
/// WGL entry points - see `wgl` for why there is no other way - and it is done
/// here rather than at `open` so that a program which never asks for OpenGL
/// never makes an extra window.
fn attachContext(self: *Impl, hwnd: HWND, config: gl.Config) Error!wgl.Context {
    if (!self.gl.available()) return error.Unavailable;

    if (!self.gl.probed) {
        // A window of its own, because the probe has to set a pixel format and
        // a window only gets one - spending it on the program's window would
        // leave nothing to choose with.
        const helper = self.u.CreateWindowExW(
            0,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral("fluxion.gl.probe"),
            ws_overlapped,
            cw_usedefault,
            cw_usedefault,
            1,
            1,
            null,
            null,
            self.instance,
            null,
        );
        if (helper) |probe_window| {
            defer _ = self.u.DestroyWindow(probe_window);
            if (self.u.GetDC(probe_window)) |probe_dc| {
                defer _ = self.u.ReleaseDC(probe_window, probe_dc);
                wgl.probe(&self.gl, @ptrCast(probe_dc));
            }
        }
    }

    const hdc = self.u.GetDC(hwnd) orelse return error.Unavailable;
    return wgl.createContext(&self.gl, @ptrCast(hdc), config);
}

fn makeContextCurrent(impl: backend.Impl, native: backend.NativeWindow) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    const context = win.context orelse return error.Unavailable;
    return wgl.makeCurrent(&self.gl, context);
}

fn clearContext(impl: backend.Impl) void {
    wgl.clearCurrent(&cast(impl).gl);
}

fn swapBuffers(impl: backend.Impl, native: backend.NativeWindow) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    const context = win.context orelse return error.Unavailable;
    return wgl.swap(&self.gl, context);
}

fn setSwapInterval(impl: backend.Impl, native: backend.NativeWindow, interval: i32) Error!void {
    const self = cast(impl);
    // Not used, but taken: `wglSwapIntervalEXT` applies to the current context
    // rather than to a window, and a caller who has not made one current is
    // asking about nothing.
    if (castWindow(native).context == null) return error.Unavailable;
    return wgl.setSwapInterval(&self.gl, interval);
}

fn getProcAddress(impl: backend.Impl, native: backend.NativeWindow, name: [*:0]const u8) ?gl.Proc {
    _ = native;
    return wgl.getProcAddress(&cast(impl).gl, name);
}

fn contextConfig(impl: backend.Impl, native: backend.NativeWindow) ?gl.Config {
    _ = impl;
    const context = castWindow(native).context orelse return null;
    return context.config;
}

// -------------------------------------------------------------------------
// Text input
// -------------------------------------------------------------------------

/// Attach or detach the window's input context.
///
/// Detaching is the honest way to turn text input off: a window with no input
/// context cannot have a candidate window opened over it, and the input method
/// stops being consulted at all. Turning it back on restores the system's
/// default context rather than one this library made.
fn setTextInput(impl: backend.Impl, native: backend.NativeWindow, on: bool) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    const imm = self.imm orelse return error.Unavailable;

    if (imm.ImmAssociateContextEx(win.hwnd, null, if (on) iace_default else 0) == 0) {
        return error.Unavailable;
    }
    if (!on) self.preedit.clear();
}

fn setTextInputArea(impl: backend.Impl, native: backend.NativeWindow, area: text_mod.Area) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    const imm = self.imm orelse return error.Unavailable;

    const context = imm.ImmGetContext(win.hwnd) orelse return error.Unavailable;
    defer _ = imm.ImmReleaseContext(win.hwnd, context);

    // The composition goes at the caret.
    const form: CompositionForm = .{
        .style = cfs_point,
        .current_pos = .{ .x = area.x, .y = area.y },
    };
    _ = imm.ImmSetCompositionWindow(context, &form);

    // And the candidate list goes clear of the whole caret rectangle, so that
    // it never covers the text being typed.
    const candidates: CandidateForm = .{
        .index = 0,
        .style = cfs_exclude,
        .current_pos = .{ .x = area.x, .y = area.y },
        .area = .{
            .left = area.x,
            .top = area.y,
            .right = area.x + @as(i32, @intCast(area.width)),
            .bottom = area.y + @as(i32, @intCast(area.height)),
        },
    };
    _ = imm.ImmSetCandidateWindow(context, &candidates);
}

fn preedit(impl: backend.Impl) ?*const text_mod.Preedit {
    return &cast(impl).preedit;
}

/// Read what the input method is composing, and say so.
///
/// Only `GCS_COMPSTR` - the uncommitted part. The committed text is left to
/// `DefWindowProc`, which turns it into `WM_CHAR` like any other typing, so
/// there is one path for text and no risk of a composition arriving twice.
fn readComposition(self: *Impl, native: *Native) void {
    const imm = self.imm orelse return;

    const context = imm.ImmGetContext(native.hwnd) orelse return;
    defer _ = imm.ImmReleaseContext(native.hwnd, context);

    // Asked for by size first: the call returns the byte count when handed a
    // null buffer, and a composition longer than this library keeps is cut
    // rather than overflowing.
    const bytes = imm.ImmGetCompositionStringW(context, gcs_compstr, null, 0);
    if (bytes <= 0) {
        self.preedit.clear();
        pushPreedit(self, native);
        return;
    }

    var wide: [text_mod.max_preedit_bytes]u16 = undefined;
    const wanted: u32 = @min(@as(u32, @intCast(bytes)), @as(u32, wide.len * 2));
    const written = imm.ImmGetCompositionStringW(context, gcs_compstr, &wide, wanted);
    if (written <= 0) {
        self.preedit.clear();
        pushPreedit(self, native);
        return;
    }

    // The count is in bytes and the buffer is UTF-16.
    const units: usize = @intCast(@divTrunc(written, 2));
    var utf8: [text_mod.max_preedit_bytes]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8, wide[0..units]) catch {
        self.preedit.clear();
        pushPreedit(self, native);
        return;
    };

    // The caret, in UTF-16 units, converted to the byte offset this library
    // reports - a Japanese composition is three bytes per character and one
    // unit, so the two numbers are nothing like each other.
    const caret_units = imm.ImmGetCompositionStringW(context, gcs_cursorpos, null, 0);
    const caret: i32 = if (caret_units < 0) -1 else blk: {
        const clamped: usize = @min(@as(usize, @intCast(caret_units)), units);
        var prefix: [text_mod.max_preedit_bytes]u8 = undefined;
        const prefix_len = std.unicode.utf16LeToUtf8(&prefix, wide[0..clamped]) catch break :blk -1;
        break :blk @intCast(prefix_len);
    };

    self.preedit.set(utf8[0..len], caret, caret);
    pushPreedit(self, native);
}

fn pushPreedit(self: *Impl, native: *Native) void {
    push(self, .{ .preedit = native.id });
}

// -------------------------------------------------------------------------
// The clipboard
// -------------------------------------------------------------------------

/// A message-only window to own what this program copies. `SetClipboardData`
/// fails after an `OpenClipboard` that named no window, and naming one of the
/// program's own would tie the clipboard to a window it may close.
fn clipboardOwner(self: *Impl) Error!HWND {
    if (self.clipboard_owner) |hwnd| return hwnd;
    const hwnd = self.u.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("fluxion.clipboard"),
        0,
        0,
        0,
        0,
        0,
        hwnd_message,
        null,
        self.instance,
        null,
    ) orelse return error.Unavailable;
    self.clipboard_owner = hwnd;
    return hwnd;
}

/// `OpenClipboard`, a few times over: a clipboard viewer or a remote desktop
/// may be holding it for a moment, and one try would lose to them.
fn openClipboard(self: *Impl, owner: ?HWND) Error!void {
    for (0..5) |_| {
        if (self.u.OpenClipboard(owner) != 0) return;
        self.k.Sleep(5);
    }
    return error.Unavailable;
}

/// As `CF_UNICODETEXT`, with `\r\n` between lines, which is what every
/// Windows program expects to paste. Filled in before the clipboard is opened,
/// so it is held for as short a time as it can be.
fn setClipboardText(impl: backend.Impl, text: []const u8) Error!void {
    const self = cast(impl);
    const owner = try clipboardOwner(self);

    const units = clipboard.utf16Len(text, .crlf);
    const memory = self.k.GlobalAlloc(gmem_moveable, (units + 1) * @sizeOf(u16)) orelse
        return error.OutOfMemory;
    var handed_over = false;
    defer if (!handed_over) {
        _ = self.k.GlobalFree(memory);
    };

    const locked: [*]u16 = @ptrCast(@alignCast(self.k.GlobalLock(memory) orelse return error.OutOfMemory));
    clipboard.toUtf16(text, .crlf, locked[0..units]);
    locked[units] = 0;
    _ = self.k.GlobalUnlock(memory);

    try openClipboard(self, owner);
    defer _ = self.u.CloseClipboard();
    if (self.u.EmptyClipboard() == 0) return error.Unavailable;
    if (self.u.SetClipboardData(cf_unicodetext, memory) == null) return error.Unavailable;
    handed_over = true;
}

fn clipboardText(impl: backend.Impl, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    const self = cast(impl);
    if (self.u.IsClipboardFormatAvailable(cf_unicodetext) == 0) return;

    try openClipboard(self, null);
    defer _ = self.u.CloseClipboard();

    const memory = self.u.GetClipboardData(cf_unicodetext) orelse return;
    const locked = self.k.GlobalLock(memory) orelse return;
    defer _ = self.k.GlobalUnlock(memory);

    // The block may be larger than the text, which ends at its terminator.
    const all = @as([*]const u16, @ptrCast(@alignCast(locked)))[0 .. self.k.GlobalSize(memory) / @sizeOf(u16)];
    try clipboard.appendUtf16(gpa, out, all[0 .. std.mem.indexOfScalar(u16, all, 0) orelse all.len]);
}

fn hasClipboardText(impl: backend.Impl) bool {
    return cast(impl).u.IsClipboardFormatAvailable(cf_unicodetext) != 0;
}

// -------------------------------------------------------------------------
// File dialogs, each on a thread of its own - see `win32_dialog`
// -------------------------------------------------------------------------

fn showFileDialog(impl: backend.Impl, gpa: Allocator, request: backend.DialogRequest) Error!void {
    if (builtin.single_threaded) return error.Unavailable;
    const self = cast(impl);
    if (self.dialog != null) return error.Unavailable;
    if (self.shell == null) self.shell = try win32_dialog.Shell.open();

    const owner: ?*anyopaque = if (request.owner) |native| @ptrCast(castWindow(native).hwnd) else null;
    const job = try win32_dialog.Dialog.create(gpa, self.shell.?.calls, owner, request);
    errdefer job.destroy();
    try job.spawn();
    self.dialog = job;
}

/// The thread has ended, so what it left may be read.
fn answerDialog(self: *Impl, job: *win32_dialog.Dialog) void {
    job.thread.join();
    self.dialog = null;
    defer job.destroy();

    const paths = job.paths(self.answers.allocator()) catch blk: {
        self.push_failed = true;
        break :blk &.{};
    };
    push(self, .{ .file_dialog = .{ .window = job.window, .id = job.id, .paths = paths } });
}

/// Close a dialog and wait for its thread, answering what that thread sends
/// here meanwhile: giving the owner back its keyboard is a message sent across
/// threads, and waiting without answering it would wait for ever.
fn endDialog(self: *Impl, job: *win32_dialog.Dialog) void {
    const thread = job.thread.getHandle();
    while (true) {
        closeDialog(self, job);
        if (self.u.MsgWaitForMultipleObjects(1, @ptrCast(&thread), 0, 50, qs_sendmessage) == wait_object_0) break;
        var msg: Msg = .{};
        _ = self.u.PeekMessageW(&msg, null, 0, 0, pm_noremove | pm_qs_sendmessage);
    }
    job.thread.join();
    job.destroy();
    self.dialog = null;
}

/// Before the dialog is shown the thread gives up on its own; after, closing
/// its window is Cancel, as it is for any dialog box.
fn closeDialog(self: *Impl, job: *win32_dialog.Dialog) void {
    job.abandon();
    const thread = self.k.GetThreadId(job.thread.getHandle());
    if (thread != 0) _ = self.u.EnumThreadWindows(thread, closeIfDialog, @bitCast(@intFromPtr(self)));
}

fn closeIfDialog(hwnd: HWND, lparam: LPARAM) callconv(.winapi) i32 {
    const self: *Impl = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var class: [8]u16 = undefined;
    const len = self.u.GetClassNameW(hwnd, &class, class.len);
    if (len > 0 and std.mem.eql(u16, class[0..@intCast(len)], dialog_class)) {
        _ = self.u.PostMessageW(hwnd, wm_close, 0, 0);
    }
    return 1;
}

/// The class of every dialog box, the file dialog's frame among them.
const dialog_class = std.unicode.utf8ToUtf16LeStringLiteral("#32770");

const generic_read: u32 = 0x80000000;
const file_share_all: u32 = 0x1 | 0x2 | 0x4;
const open_existing: u32 = 3;
const file_attribute_normal: u32 = 0x80;
const invalid_handle: usize = std.math.maxInt(usize);

/// Read the path, which here is a path. Opened to share with anything that
/// has it open for writing, as Explorer does, rather than refused.
fn chosenFile(impl: backend.Impl, index: usize, path: []const u8, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    _ = index;
    const self = cast(impl);
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => error.Unavailable,
    };
    defer gpa.free(wide);

    const file = self.k.CreateFileW(wide.ptr, generic_read, file_share_all, null, open_existing, file_attribute_normal, null) orelse
        return error.Unavailable;
    if (@intFromPtr(file) == invalid_handle) return error.Unavailable;
    defer _ = self.k.CloseHandle(file);

    var file_size: i64 = 0;
    if (self.k.GetFileSizeEx(file, &file_size) != 0) try out.ensureUnusedCapacity(gpa, @intCast(@max(file_size, 0)));
    while (true) {
        try out.ensureUnusedCapacity(gpa, 64 * 1024);
        const room = out.unusedCapacitySlice();
        var got: u32 = 0;
        if (self.k.ReadFile(file, room.ptr, @intCast(@min(room.len, 1 << 30)), &got, null) == 0) return error.Unavailable;
        if (got == 0) return;
        out.items.len += got;
    }
}

fn createVulkanSurface(
    impl: backend.Impl,
    native: backend.NativeWindow,
    instance: usize,
    get_proc: vulkan.GetInstanceProcAddr,
    allocator: ?*const anyopaque,
) Error!u64 {
    const self = cast(impl);
    const win = castWindow(native);

    // Through the caller's loader, so there is only ever one Vulkan in the
    // process. Null means the instance was made without `VK_KHR_win32_surface`.
    const create: *const fn (
        usize,
        *const vulkan.Win32SurfaceCreateInfo,
        ?*const anyopaque,
        *u64,
    ) callconv(.c) i32 = @ptrCast(get_proc(instance, "vkCreateWin32SurfaceKHR") orelse
        return error.Unavailable);

    const info: vulkan.Win32SurfaceCreateInfo = .{
        .hinstance = @ptrCast(self.instance),
        .hwnd = @ptrCast(win.hwnd),
    };

    var surface: u64 = 0;
    if (create(instance, &info, allocator, &surface) != vulkan.success) {
        return error.Unavailable;
    }
    return surface;
}

fn destroyWindow(impl: backend.Impl, gpa: Allocator, native: backend.NativeWindow) void {
    const self = cast(impl);
    const win = castWindow(native);

    if (self.dialog) |job| {
        if (job.owner == @as(?*anyopaque, @ptrCast(win.hwnd))) closeDialog(self, job);
    }

    // Both belong to the whole machine and would outlive the window.
    letGo(self, win);
    restoreDisplayMode(self, win);

    // Before the window: a context outliving its device context is a handle
    // into a window that no longer exists.
    if (win.context) |context| wgl.destroyContext(&self.gl, context);
    _ = self.u.DestroyWindow(win.hwnd);
    gpa.destroy(win);
}

fn toWide(gpa: Allocator, text: []const u8) Error![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Not valid UTF-8. Said rather than mangled: a title with a broken byte
        // in it is a bug in the caller, not something to render as U+FFFD.
        else => error.Unavailable,
    };
}

fn setTitle(impl: backend.Impl, native: backend.NativeWindow, title: []const u8) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    const wide = try toWide(self.gpa, title);
    defer self.gpa.free(wide);
    _ = self.u.SetWindowTextW(win.hwnd, wide.ptr);
}

fn setVisible(impl: backend.Impl, native: backend.NativeWindow, visible: bool) void {
    const self = cast(impl);
    const win = castWindow(native);
    _ = self.u.ShowWindow(win.hwnd, if (visible) sw_show else sw_hide);
}

fn size(impl: backend.Impl, native: backend.NativeWindow) [2]u32 {
    // On Windows the content area is already in pixels, so the logical size is
    // the physical one divided by the scale.
    const pixels = framebufferSize(impl, native);
    const scale = contentScale(impl, native);
    if (scale[0] <= 0 or scale[1] <= 0) return pixels;
    return .{
        @intFromFloat(@round(@as(f32, @floatFromInt(pixels[0])) / scale[0])),
        @intFromFloat(@round(@as(f32, @floatFromInt(pixels[1])) / scale[1])),
    };
}

fn framebufferSize(impl: backend.Impl, native: backend.NativeWindow) [2]u32 {
    const self = cast(impl);
    const win = castWindow(native);
    if (self.u.IsIconic(win.hwnd) != 0) return restoredSize(self, win);
    var rect: Rect = .{};
    if (self.u.GetClientRect(win.hwnd, &rect) == 0) return .{ 0, 0 };
    return .{
        @intCast(@max(0, rect.right - rect.left)),
        @intCast(@max(0, rect.bottom - rect.top)),
    };
}

/// Falls back to the placement for a window minimised before it was ever sized.
fn restoredSize(self: *Impl, win: *Native) [2]u32 {
    if (win.fb_width != 0 and win.fb_height != 0) return .{ win.fb_width, win.fb_height };
    var placement: WindowPlacement = .{};
    if (self.u.GetWindowPlacement(win.hwnd, &placement) == 0) return .{ 0, 0 };
    var frame: Rect = .{};
    _ = self.u.AdjustWindowRectEx(&frame, win.style, 0, 0);
    const area = placement.normal_position;
    return .{
        @intCast(@max(0, (area.right - area.left) - (frame.right - frame.left))),
        @intCast(@max(0, (area.bottom - area.top) - (frame.bottom - frame.top))),
    };
}

fn nativeHandle(impl: backend.Impl, native: backend.NativeWindow) usize {
    _ = impl;
    return @intFromPtr(castWindow(native).hwnd);
}

fn cursorFor(self: *Impl, shape: cursor_mod.Shape) ?HCURSOR {
    return self.u.LoadCursorW(null, switch (shape) {
        .arrow => idc_arrow,
        .ibeam => idc_ibeam,
        .crosshair => idc_cross,
        .pointing_hand => idc_hand,
        .resize_ew => idc_sizewe,
        .resize_ns => idc_sizens,
        .resize_nwse => idc_sizenwse,
        .resize_nesw => idc_sizenesw,
        .resize_all => idc_sizeall,
        .not_allowed => idc_no,
    });
}

fn setCursorShape(impl: backend.Impl, native: backend.NativeWindow, shape: cursor_mod.Shape) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    const wanted = cursorFor(self, shape) orelse return error.Unavailable;
    win.shape = wanted;
    // Applied now only if the pointer is over the window; `WM_SETCURSOR` puts
    // it back every time after that.
    if (!pointerHidden(win)) _ = self.u.SetCursor(wanted);
}

/// A disabled window in the background has let go, and shows the pointer.
fn pointerHidden(win: *const Native) bool {
    return win.mode == .hidden or (win.mode == .disabled and win.held);
}

/// Null is how Windows hides the pointer.
fn pointerShape(self: *Impl, win: *const Native) ?HCURSOR {
    return if (pointerHidden(win)) null else (win.shape orelse cursorFor(self, .arrow));
}

/// Hold the pointer inside the content area, or let it go.
fn clipToWindow(self: *Impl, win: *Native, on: bool) void {
    if (!on) {
        _ = self.u.ClipCursor(null);
        return;
    }
    var rect: Rect = .{};
    if (self.u.GetClientRect(win.hwnd, &rect) == 0) return;

    // `ClipCursor` works in screen coordinates and `GetClientRect` answers in
    // window ones, so the origin has to be moved before it means anything.
    var origin: Point = .{};
    if (self.u.ClientToScreen(win.hwnd, &origin) == 0) return;
    rect.left += origin.x;
    rect.right += origin.x;
    rect.top += origin.y;
    rect.bottom += origin.y;

    _ = self.u.ClipCursor(&rect);
}

/// Ask Windows for the mouse's own numbers rather than the cursor's.
fn registerRawMouse(self: *Impl, win: *Native, on: bool) bool {
    const device = [_]RawInputDevice{.{
        .usage_page = hid_usage_page_generic,
        .usage = hid_usage_generic_mouse,
        .flags = if (on) 0 else ridev_remove,
        // A removal must not name a window, or the call fails.
        .target = if (on) win.hwnd else null,
    }};
    return self.u.RegisterRawInputDevices(&device, 1, @sizeOf(RawInputDevice)) != 0;
}

fn setCursorMode(impl: backend.Impl, native: backend.NativeWindow, mode: cursor_mod.Mode) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    if (win.mode == mode) return;

    letGo(self, win);
    win.mode = mode;
    // From the background it waits for `WM_SETFOCUS`.
    if (win.focused and !win.frame_click) hold(self, win);
    _ = self.u.SetCursor(pointerShape(self, win));
}

/// Windows would leave an alt-tabbed game holding the pointer, so a confining
/// mode holds it only while the window has the keyboard, as GLFW does.
fn hold(self: *Impl, win: *Native) void {
    if (win.held or !win.mode.confines()) return;
    win.held = true;

    if (win.mode == .disabled) {
        var at: Point = .{};
        if (self.u.GetCursorPos(&at) != 0) {
            win.saved_x = at.x;
            win.saved_y = at.y;
        }
        win.has_raw_last = false;
        if (win.raw_motion) _ = registerRawMouse(self, win, true);
        // Centred first, or the first delta is the distance to the middle.
        var rect: Rect = .{};
        if (self.u.GetClientRect(win.hwnd, &rect) != 0) {
            var middle: Point = .{ .x = @divTrunc(rect.right, 2), .y = @divTrunc(rect.bottom, 2) };
            if (self.u.ClientToScreen(win.hwnd, &middle) != 0) _ = self.u.SetCursorPos(middle.x, middle.y);
        }
    }
    clipToWindow(self, win, true);
    _ = self.u.SetCursor(pointerShape(self, win));
}

/// Undo `hold`, if it was done.
fn letGo(self: *Impl, win: *Native) void {
    if (!win.held) return;
    win.held = false;
    clipToWindow(self, win, false);
    if (win.mode == .disabled) {
        if (win.raw_motion) _ = registerRawMouse(self, win, false);
        _ = self.u.SetCursorPos(win.saved_x, win.saved_y);
    }
    _ = self.u.SetCursor(pointerShape(self, win));
}

fn setRawMouseMotion(impl: backend.Impl, native: backend.NativeWindow, on: bool) bool {
    const self = cast(impl);
    const win = castWindow(native);
    if (win.raw_motion == on) return on;

    // Only registered while the pointer is actually disabled; asking for it in
    // any other mode would deliver two sets of movement for one hand.
    if (win.mode == .disabled and win.held) {
        if (!registerRawMouse(self, win, on)) return false;
    }
    win.raw_motion = on;
    win.has_raw_last = false;
    return true;
}

fn setCursorPos(impl: backend.Impl, native: backend.NativeWindow, x: f64, y: f64) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    var origin: Point = .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
    if (self.u.ClientToScreen(win.hwnd, &origin) == 0) return error.Unavailable;
    if (self.u.SetCursorPos(origin.x, origin.y) == 0) return error.Unavailable;

    // The move produces no `WM_MOUSEMOVE` worth a delta, so the last position
    // is updated here - otherwise the next real move reports a jump.
    win.last_x = x;
    win.last_y = y;
    win.has_position = true;
}

/// The top left of the content area, in screen coordinates.
///
/// `GetWindowRect` gives the whole window including the frame, so the origin is
/// taken from the client area instead - which is what a program that positions
/// something relative to its own contents means.
fn position(impl: backend.Impl, native: backend.NativeWindow) [2]i32 {
    const self = cast(impl);
    const win = castWindow(native);
    var origin: Point = .{};
    if (self.u.ClientToScreen(win.hwnd, &origin) == 0) return .{ 0, 0 };
    return .{ origin.x, origin.y };
}

fn setPosition(impl: backend.Impl, native: backend.NativeWindow, x: i32, y: i32) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    // The caller means the content area, and `SetWindowPos` means the frame, so
    // the difference between the two is added back on.
    var rect: Rect = .{ .left = x, .top = y, .right = x, .bottom = y };
    _ = self.u.AdjustWindowRectEx(&rect, win.style, 0, 0);

    if (self.u.SetWindowPos(
        win.hwnd,
        null,
        rect.left,
        rect.top,
        0,
        0,
        swp_nosize | swp_nozorder | swp_noactivate,
    ) == 0) return error.Unavailable;
}

fn setSize(impl: backend.Impl, native: backend.NativeWindow, width: u32, height: u32) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    var rect: Rect = .{
        .left = 0,
        .top = 0,
        .right = @intCast(width),
        .bottom = @intCast(height),
    };
    _ = self.u.AdjustWindowRectEx(&rect, win.style, 0, 0);

    if (self.u.SetWindowPos(
        win.hwnd,
        null,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        swp_nomove | swp_nozorder | swp_noactivate,
    ) == 0) return error.Unavailable;
}

fn setState(impl: backend.Impl, native: backend.NativeWindow, wanted: backend.WindowState) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    switch (wanted) {
        .iconified => _ = self.u.ShowWindow(win.hwnd, sw_minimize),
        .maximized => _ = self.u.ShowWindow(win.hwnd, sw_maximize),
        .restored => {
            // `SW_RESTORE` alone brings a window minimised from maximised back maximised.
            var placement: WindowPlacement = .{};
            if (self.u.GetWindowPlacement(win.hwnd, &placement) != 0) {
                placement.flags &= ~wpf_restoretomaximized;
                placement.show_cmd = sw_shownormal;
                if (self.u.SetWindowPlacement(win.hwnd, &placement) != 0) return;
            }
            _ = self.u.ShowWindow(win.hwnd, sw_restore);
        },
        .focused => {
            _ = self.u.ShowWindow(win.hwnd, sw_show);
            // Refused by Windows unless this process already had focus, and
            // that refusal is deliberate: it is what stops a background program
            // stealing the keyboard mid-sentence.
            _ = self.u.SetForegroundWindow(win.hwnd);
        },
        // Flash until the user looks. The polite version, and the one that
        // works from the background.
        .attention => _ = self.u.FlashWindow(win.hwnd, 1),
    }
}

fn getState(impl: backend.Impl, native: backend.NativeWindow, which: backend.WindowState) bool {
    const self = cast(impl);
    const win = castWindow(native);

    return switch (which) {
        .iconified => self.u.IsIconic(win.hwnd) != 0,
        .maximized => self.u.IsZoomed(win.hwnd) != 0,
        .focused => self.u.GetForegroundWindow() == win.hwnd,
        .restored => self.u.IsIconic(win.hwnd) == 0 and self.u.IsZoomed(win.hwnd) == 0,
        // Not a state anything can be in; it is a thing to ask for.
        .attention => false,
    };
}

/// `WM_GETMINMAXINFO` applies them only to the next drag, so the window is
/// brought inside them here.
fn setSizeLimits(impl: backend.Impl, native: backend.NativeWindow, limits: backend.SizeLimits) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    win.limits = limits;

    if (win.is_fullscreen or self.u.IsIconic(win.hwnd) != 0 or self.u.IsZoomed(win.hwnd) != 0) return;
    const now = framebufferSize(impl, native);
    const inside = limits.clamp(now);
    if (!std.meta.eql(inside, now)) try setSize(impl, native, inside[0], inside[1]);
}

const spi_getwheelscrolllines: u32 = 0x0068;
const spi_getwheelscrollchars: u32 = 0x006C;
/// `WHEEL_PAGESCROLL`: the user chose a screen at a time.
const wheel_pagescroll: u32 = 0xFFFFFFFF;

fn scrollLines(impl: backend.Impl) input.ScrollLines {
    const self = cast(impl);
    var lines: u32 = 3;
    var chars: u32 = 3;
    _ = self.u.SystemParametersInfoW(spi_getwheelscrolllines, 0, &lines, 0);
    _ = self.u.SystemParametersInfoW(spi_getwheelscrollchars, 0, &chars, 0);
    if (lines == wheel_pagescroll) return .{ .x = @floatFromInt(chars), .y = 1, .page = true };
    return .{ .x = @floatFromInt(chars), .y = @floatFromInt(lines) };
}

fn doubleClickTime(impl: backend.Impl) u32 {
    return cast(impl).u.GetDoubleClickTime();
}

/// `INFINITE`: the user turned blinking off.
const caret_never_blinks: u32 = 0xFFFFFFFF;

fn caretBlinkTime(impl: backend.Impl) ?u32 {
    return switch (cast(impl).u.GetCaretBlinkTime()) {
        caret_never_blinks => null,
        // A failure, not a caret that never shows: Windows' own default.
        0 => 530,
        else => |time| time,
    };
}

/// Matched by corner, because a mode change leaves the list's sizes stale.
fn windowMonitor(impl: backend.Impl, native: backend.NativeWindow, list: []const monitor.Monitor) ?usize {
    const self = cast(impl);
    const win = castWindow(native);
    const hmonitor = self.u.MonitorFromWindow(win.hwnd, monitor_defaulttonearest) orelse return null;
    var info: MonitorInfoExW = .{};
    if (self.u.GetMonitorInfoW(hmonitor, &info) == 0) return null;
    for (list, 0..) |mon, index| {
        if (mon.bounds.x == info.monitor.left and mon.bounds.y == info.monitor.top) return index;
    }
    return null;
}

fn setOpacity(impl: backend.Impl, native: backend.NativeWindow, opacity: f32) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    const set = self.u.SetLayeredWindowAttributes orelse return error.Unavailable;

    const get_style = self.u.GetWindowLongPtrW orelse return error.Unavailable;
    const set_style = self.u.SetWindowLongPtrW orelse return error.Unavailable;

    // A window is only see-through once it is layered, and saying so costs a
    // redraw - so it is only turned on when something less than solid is asked
    // for.
    const current: u32 = @truncate(@as(usize, @bitCast(get_style(win.hwnd, gwl_exstyle))));
    const clamped = std.math.clamp(opacity, 0, 1);
    const wanted: u32 = if (clamped < 1) current | ws_ex_layered else current & ~ws_ex_layered;
    if (wanted != current) {
        _ = set_style(win.hwnd, gwl_exstyle, @bitCast(@as(usize, wanted)));
    }
    if (clamped < 1) {
        const alpha: u8 = @intFromFloat(@round(clamped * 255));
        if (set(win.hwnd, 0, alpha, lwa_alpha) == 0) return error.Unavailable;
    }
}

// -------------------------------------------------------------------------
// Monitors
// -------------------------------------------------------------------------

/// Carried through `EnumDisplayMonitors` as an `LPARAM`, because a Windows
/// callback has no other way to reach anything.
const EnumState = struct {
    self: *Impl,
    list: *std.ArrayListUnmanaged(monitor.Monitor),
    modes: *std.ArrayListUnmanaged(monitor.VideoMode),
    gpa: Allocator,
    failed: bool = false,
};

fn enumerateMonitors(
    impl: backend.Impl,
    list: *std.ArrayListUnmanaged(monitor.Monitor),
    modes: *std.ArrayListUnmanaged(monitor.VideoMode),
    gpa: Allocator,
) Error!void {
    const self = cast(impl);
    var state: EnumState = .{ .self = self, .list = list, .modes = modes, .gpa = gpa };

    _ = self.u.EnumDisplayMonitors(null, null, monitorEnumProc, @bitCast(@intFromPtr(&state)));
    if (state.failed) return error.OutOfMemory;
}

fn monitorEnumProc(
    hmonitor: ?*anyopaque,
    hdc: ?*anyopaque,
    clip: *Rect,
    param: isize,
) callconv(.winapi) i32 {
    _ = .{ hdc, clip };
    const state: *EnumState = @ptrFromInt(@as(usize, @bitCast(param)));
    addMonitor(state, hmonitor) catch {
        state.failed = true;
        // Stop: the rest would fail the same way, and the caller is about to
        // throw the list out anyway.
        return 0;
    };
    return 1;
}

fn addMonitor(state: *EnumState, hmonitor: ?*anyopaque) Allocator.Error!void {
    const self = state.self;

    var info: MonitorInfoExW = .{};
    if (self.u.GetMonitorInfoW(hmonitor, &info) == 0) return;

    var mon: monitor.Monitor = .{
        .bounds = rectToBounds(info.monitor),
        .work_area = rectToBounds(info.work),
        .primary = (info.flags & monitorinfof_primary) != 0,
    };

    // `device` is `\\.\DISPLAY1` and is what every other call here wants; the
    // name shown to a person comes from the display attached to it, and falls
    // back to the adapter when there is none.
    const device: [*:0]const u16 = @ptrCast(&info.device);
    var display: DisplayDeviceW = .{};
    if (self.u.EnumDisplayDevicesW(device, 0, &display, 0) != 0 and display.device_string[0] != 0) {
        setNameFromUtf16(&mon, &display.device_string);
    } else {
        setNameFromUtf16(&mon, &info.device);
    }

    var current: DevModeW = .{};
    if (self.u.EnumDisplaySettingsW(device, enum_current_settings, &current) != 0) {
        mon.current = devModeToVideoMode(current);
    }

    mon.scale_x = 1;
    mon.scale_y = 1;
    if (self.sh) |sh| {
        var dpi_x: u32 = 0;
        var dpi_y: u32 = 0;
        if (sh.GetDpiForMonitor(hmonitor, mdt_effective_dpi, &dpi_x, &dpi_y) == 0 and dpi_x != 0) {
            mon.scale_x = @as(f32, @floatFromInt(dpi_x)) / 96.0;
            mon.scale_y = @as(f32, @floatFromInt(dpi_y)) / 96.0;
        }
    }

    if (self.g) |g| {
        const display_str = std.unicode.utf8ToUtf16LeStringLiteral("DISPLAY");
        if (g.CreateDCW(display_str, device, null, null)) |dc| {
            defer _ = g.DeleteDC(dc);
            const mm_x = g.GetDeviceCaps(dc, horzsize);
            const mm_y = g.GetDeviceCaps(dc, vertsize);
            if (mm_x > 0) mon.physical_width_mm = @intCast(mm_x);
            if (mm_y > 0) mon.physical_height_mm = @intCast(mm_y);
        }
    }

    // Every mode this display can be switched to, appended to the shared array;
    // the context turns the range into a slice once it has stopped growing.
    mon.mode_start = state.modes.items.len;
    var index: u32 = 0;
    while (true) : (index += 1) {
        var dm: DevModeW = .{};
        if (self.u.EnumDisplaySettingsW(device, index, &dm) == 0) break;

        const mode = devModeToVideoMode(dm);
        // Windows lists the same resolution once per colour depth and once per
        // rate; only the duplicates that differ in nothing this library reports
        // are dropped.
        var seen = false;
        for (state.modes.items[mon.mode_start..]) |existing| {
            if (std.meta.eql(existing, mode)) {
                seen = true;
                break;
            }
        }
        if (!seen) try state.modes.append(state.gpa, mode);
    }
    mon.mode_count = state.modes.items.len - mon.mode_start;

    try state.list.append(state.gpa, mon);
}

fn rectToBounds(rect: Rect) monitor.Rect {
    return .{
        .x = rect.left,
        .y = rect.top,
        .width = @intCast(@max(0, rect.right - rect.left)),
        .height = @intCast(@max(0, rect.bottom - rect.top)),
    };
}

fn devModeToVideoMode(dm: DevModeW) monitor.VideoMode {
    return .{
        .width = dm.pels_width,
        .height = dm.pels_height,
        .bits = dm.bits_per_pel,
        // Windows says 0 or 1 for "whatever the hardware defaults to", which is
        // not a rate and is better reported as unknown.
        .refresh_hz = if (dm.display_frequency > 1) dm.display_frequency else 0,
    };
}

/// Copy a fixed-size UTF-16 field into the monitor's inline name.
fn setNameFromUtf16(mon: *monitor.Monitor, field: []const u16) void {
    const len = std.mem.indexOfScalar(u16, field, 0) orelse field.len;
    var buf: [monitor.max_name_len]u8 = undefined;
    const written = std.unicode.utf16LeToUtf8(&buf, field[0..len]) catch buf.len;
    mon.setName(buf[0..@min(written, buf.len)]);
}

fn pollGamepads(impl: backend.Impl, devices: *[gamepad.max_devices]gamepad.Device) void {
    cast(impl).pads.poll(devices);
}

fn setFullscreen(
    impl: backend.Impl,
    native: backend.NativeWindow,
    wanted: monitor.Fullscreen,
    target: ?*const monitor.Monitor,
) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    if (wanted == .windowed) {
        if (!win.is_fullscreen) return;
        restoreDisplayMode(self, win);

        setStyle(self, win.hwnd, win.saved_style);
        win.style = win.saved_style;
        _ = self.u.SetWindowPos(
            win.hwnd,
            null,
            win.saved_frame.left,
            win.saved_frame.top,
            win.saved_frame.right - win.saved_frame.left,
            win.saved_frame.bottom - win.saved_frame.top,
            swp_nozorder | swp_noactivate | swp_framechanged,
        );
        win.is_fullscreen = false;
        return;
    }

    const mon = target orelse return error.Unavailable;

    // Only the first crossing is remembered: going straight from one monitor to
    // another must not overwrite the window's real geometry with its fullscreen
    // one.
    if (!win.is_fullscreen) {
        _ = self.u.GetWindowRect(win.hwnd, &win.saved_frame);
        win.saved_style = win.style;
    }

    var area = mon.bounds;
    if (wanted == .exclusive) {
        // The device name is not kept on the monitor - only what a person would
        // read - so it is found again by position, which is what identifies a
        // display to Windows anyway.
        if (deviceNameAt(self, mon)) |device| {
            var dm: DevModeW = .{};
            dm.fields = dm_pelswidth | dm_pelsheight | dm_bitsperpel | dm_displayfrequency;
            dm.pels_width = wanted.exclusive.mode.width;
            dm.pels_height = wanted.exclusive.mode.height;
            dm.bits_per_pel = if (wanted.exclusive.mode.bits != 0) wanted.exclusive.mode.bits else 32;
            dm.display_frequency = wanted.exclusive.mode.refresh_hz;
            if (dm.display_frequency == 0) dm.fields &= ~dm_displayfrequency;

            const name: [*:0]const u16 = @ptrCast(&device);
            if (self.u.ChangeDisplaySettingsExW(name, &dm, null, cds_fullscreen, null) != disp_change_successful) {
                return error.Unavailable;
            }
            win.mode_changed_on = device;
            // The monitor is a different size now than the list says.
            area.width = dm.pels_width;
            area.height = dm.pels_height;
        } else return error.Unavailable;
    }

    // A fullscreen window has no frame: `WS_POPUP` and nothing else, or the
    // caption sits over the top of the monitor and the contents are short by
    // its height.
    const style = (win.style & ~(ws_overlapped | ws_caption | ws_sysmenu | ws_thickframe |
        ws_minimizebox | ws_maximizebox | ws_maximize)) | ws_popup | ws_visible;
    setStyle(self, win.hwnd, style);
    win.style = style;

    if (self.u.SetWindowPos(
        win.hwnd,
        hwnd_top,
        area.x,
        area.y,
        @intCast(area.width),
        @intCast(area.height),
        swp_nozorder | swp_framechanged | swp_showwindow | swp_nocopybits,
    ) == 0) return error.Unavailable;

    win.is_fullscreen = true;
}

const dm_bitsperpel: u32 = 0x00040000;
const dm_pelswidth: u32 = 0x00080000;
const dm_pelsheight: u32 = 0x00100000;
const dm_displayfrequency: u32 = 0x00400000;

/// Put back whatever mode this window changed, if it changed one.
fn restoreDisplayMode(self: *Impl, win: *Native) void {
    if (win.mode_changed_on[0] == 0) return;
    const name: [*:0]const u16 = @ptrCast(&win.mode_changed_on);
    // A null mode means "the one in the registry", which is what the user set.
    _ = self.u.ChangeDisplaySettingsExW(name, null, null, cds_fullscreen, null);
    win.mode_changed_on = @splat(0);
}

/// The `\\.\DISPLAYn` name of the display at a monitor's top left corner.
fn deviceNameAt(self: *Impl, mon: *const monitor.Monitor) ?[32]u16 {
    const Finder = struct {
        want_x: i32,
        want_y: i32,
        found: ?[32]u16 = null,
        u: *const User32,

        fn each(hmonitor: ?*anyopaque, hdc: ?*anyopaque, clip: *Rect, param: isize) callconv(.winapi) i32 {
            _ = .{ hdc, clip };
            const it: *@This() = @ptrFromInt(@as(usize, @bitCast(param)));
            var info: MonitorInfoExW = .{};
            if (it.u.GetMonitorInfoW(hmonitor, &info) == 0) return 1;
            if (info.monitor.left != it.want_x or info.monitor.top != it.want_y) return 1;
            it.found = info.device;
            return 0;
        }
    };

    var finder: Finder = .{ .want_x = mon.bounds.x, .want_y = mon.bounds.y, .u = &self.u };
    _ = self.u.EnumDisplayMonitors(null, null, Finder.each, @bitCast(@intFromPtr(&finder)));
    return finder.found;
}

fn setStyle(self: *Impl, hwnd: HWND, style: u32) void {
    if (self.u.SetWindowLongPtrW) |set| {
        _ = set(hwnd, gwl_style, @bitCast(@as(usize, style)));
    } else if (self.u.SetWindowLongW) |set| {
        _ = set(hwnd, gwl_style, @bitCast(style));
    }
}

fn contentScale(impl: backend.Impl, native: backend.NativeWindow) [2]f32 {
    const self = cast(impl);
    const win = castWindow(native);
    const get = self.u.GetDpiForWindow orelse return .{ 1, 1 };
    const dpi = get(win.hwnd);
    if (dpi == 0) return .{ 1, 1 };
    const scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    return .{ scale, scale };
}

// -------------------------------------------------------------------------
// The message pump
// -------------------------------------------------------------------------

fn pump(impl: backend.Impl, queue: *backend.Queue) Error!void {
    const self = cast(impl);

    self.queue = queue;
    self.push_failed = false;
    defer self.queue = null;

    // The last answer's paths were promised until now.
    _ = self.answers.reset(.retain_capacity);
    self.later.hand(queue) catch {
        self.push_failed = true;
    };

    var msg: Msg = .{};
    while (self.u.PeekMessageW(&msg, null, 0, 0, pm_remove) != 0) {
        _ = self.u.TranslateMessage(&msg);
        _ = self.u.DispatchMessageW(&msg);
    }

    if (self.dialog) |job| {
        if (self.k.WaitForSingleObject(job.thread.getHandle(), 0) == wait_object_0) answerDialog(self, job);
    }

    if (self.push_failed) return error.OutOfMemory;
}

fn wait(impl: backend.Impl, timeout_ms: ?u32) Error!void {
    const self = cast(impl);
    const infinite: u32 = 0xFFFFFFFF;
    const qs_allinput: u32 = 0x04FF;
    // A dialog's thread ending is as much a reason to pump as a message.
    var handles: [1]*anyopaque = undefined;
    var count: u32 = 0;
    if (self.dialog) |job| {
        handles[0] = job.thread.getHandle();
        count = 1;
    }
    _ = self.u.MsgWaitForMultipleObjects(count, &handles, 0, timeout_ms orelse infinite, qs_allinput);
}

fn post(impl: backend.Impl) void {
    const self = cast(impl);
    // A null window posts to the thread queue, which is what wakes a
    // `MsgWaitForMultipleObjects` that is waiting on it.
    _ = self.u.PostMessageW(null, wm_null, 0, 0);
}

// -------------------------------------------------------------------------
// The window procedure
// -------------------------------------------------------------------------

fn windowProc(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    // The first message a window gets, and the one that carries the pointer
    // `CreateWindowExW` was handed. Every message after this can find it.
    if (message == wm_nccreate) {
        const create: *const CreateStructW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (create.create_params) |params| {
            const native: *Native = @ptrCast(@alignCast(params));
            setUserData(native.impl, hwnd, native);
            return native.impl.u.DefWindowProcW(hwnd, message, wparam, lparam);
        }
        return 1;
    }

    // Before `WM_NCCREATE`, or on a window this backend did not make.
    const native = blk: {
        const raw = fallbackUserData(hwnd) orelse return defaultProc(hwnd, message, wparam, lparam);
        break :blk raw;
    };
    const self = native.impl;

    if (handle(self, native, hwnd, message, wparam, lparam)) |result| return result;
    return self.u.DefWindowProcW(hwnd, message, wparam, lparam);
}

/// Reading the user data without an `Impl` in hand, for the messages that
/// arrive before one is reachable. Uses the Ptr form where the target has it.
fn fallbackUserData(hwnd: HWND) ?*Native {
    const get = struct {
        extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
        extern "user32" fn GetWindowLongW(HWND, i32) callconv(.winapi) i32;
    };
    const raw: isize = if (@sizeOf(usize) == 8)
        get.GetWindowLongPtrW(hwnd, gwlp_userdata)
    else
        get.GetWindowLongW(hwnd, gwlp_userdata);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn defaultProc(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) LRESULT {
    const proc = struct {
        extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
    };
    return proc.DefWindowProcW(hwnd, message, wparam, lparam);
}

/// Turn one message into events, or return null to let Windows have it.
fn handle(
    self: *Impl,
    native: *Native,
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) ?LRESULT {
    const id = native.id;

    switch (message) {
        wm_close => {
            // Deliberately not destroying anything: a close is a request, and
            // the program decides. Returning 0 says "handled", which is what
            // stops Windows destroying the window out from under it.
            push(self, .{ .close = id });
            return 0;
        },

        wm_paint => {
            push(self, .{ .refresh = id });
            return null;
        },

        wm_size => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            const iconified = wparam == size_minimized;
            // `SIZE_MAXSHOW` and `SIZE_MAXHIDE` are about other windows.
            const maximized = wparam == size_maximized or (native.maximized and wparam != size_restored);

            if (iconified != native.iconified) {
                native.iconified = iconified;
                push(self, .{ .iconify = .{ .window = id, .value = iconified } });
            }
            if (maximized != native.maximized) {
                native.maximized = maximized;
                push(self, .{ .maximize = .{ .window = id, .value = maximized } });
            }
            if (native.held) clipToWindow(self, native, true);

            if (iconified or (width == native.fb_width and height == native.fb_height)) return 0;
            native.fb_width = width;
            native.fb_height = height;
            // The client rect is in pixels, so this is the framebuffer size;
            // the logical one is that divided by the scale.
            push(self, .{ .framebuffer_resize = .{ .window = id, .width = width, .height = height } });

            const scale = contentScale(self, native);
            push(self, .{ .resize = .{
                .window = id,
                .width = @intFromFloat(@round(@as(f32, @floatFromInt(width)) / scale[0])),
                .height = @intFromFloat(@round(@as(f32, @floatFromInt(height)) / scale[1])),
            } });
            return 0;
        },

        wm_move => {
            if (native.held) clipToWindow(self, native, true);
            push(self, .{ .move = .{
                .window = id,
                .x = @as(i16, @truncate(lparam & 0xFFFF)),
                .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
            } });
            return 0;
        },

        wm_dpichanged => {
            const dpi: u32 = @intCast(wparam & 0xFFFF);
            const scale = @as(f32, @floatFromInt(dpi)) / 96.0;
            push(self, .{ .scale = .{ .window = id, .x = scale, .y = scale } });
            return null;
        },

        wm_dropfiles => {
            dropFiles(self, id, @ptrFromInt(wparam));
            return 0;
        },

        wm_setfocus => {
            native.focused = true;
            if (!native.frame_click) hold(self, native);
            push(self, .{ .focus = .{ .window = id, .value = true } });
            return 0;
        },
        wm_killfocus => {
            native.focused = false;
            native.frame_click = false;
            self.alt_graph = false;
            letGo(self, native);
            push(self, .{ .focus = .{ .window = id, .value = false } });
            return 0;
        },

        wm_mouseactivate => {
            // A click on the frame keeps its capture until the title bar drag is over.
            const clicked = (lparam >> 16) & 0xFFFF == @as(isize, wm_lbuttondown);
            if (clicked and lparam & 0xFFFF != htclient) native.frame_click = true;
            return null;
        },
        wm_capturechanged => {
            if (lparam == 0 and native.frame_click) {
                native.frame_click = false;
                if (native.focused) hold(self, native);
            }
            return null;
        },

        wm_keydown, wm_syskeydown, wm_keyup, wm_syskeyup => {
            const down = message == wm_keydown or message == wm_syskeydown;
            if (wparam == @as(WPARAM, @intCast(vk_control)) and (lparam >> 24) & 1 == 0 and rightAltNext(self)) {
                self.alt_graph = down;
                return null;
            }
            // Bit 30 of lParam is the previous state: set means the key was
            // already down, which is what makes this a repeat and not a press.
            const was_down = (lparam >> 30) & 1 != 0;
            const action: keys.Action = if (!down)
                .release
            else if (was_down)
                .repeat
            else
                .press;

            const scancode = scancodeFrom(self, wparam, lparam);
            const physical = keyFromScancode(scancode);

            push(self, .{ .key = .{
                .window = id,
                .key = physical,
                .virtual = virtualFrom(physical, wparam),
                .scancode = @enumFromInt(scancode),
                .action = action,
                .mods = readMods(self),
            } });
            // Not handled: `TranslateMessage` still has to see it to produce
            // the `WM_CHAR` that becomes a `.char` event. `WM_SYSKEYDOWN` goes
            // on to the default handler too, or alt+F4 stops working.
            return null;
        },

        // The composition changed, or ended. `GCS_RESULTSTR` is deliberately
        // not read here: letting the default handler turn it into `WM_CHAR`
        // keeps one path for committed text.
        wm_ime_composition => {
            if (self.imm != null) {
                if ((@as(u32, @truncate(@as(usize, @bitCast(lparam)))) & gcs_compstr) != 0) {
                    readComposition(self, native);
                }
            }
            // Null rather than zero: the default handler still has to see
            // this, because it is what turns the committed result into
            // `WM_CHAR`. Answering it here would swallow the text.
            return null;
        },

        wm_ime_endcomposition => {
            self.preedit.clear();
            pushPreedit(self, native);
            return null;
        },

        wm_char => {
            const unit: u16 = @intCast(wparam & 0xFFFF);
            if (charFrom(native, unit)) |codepoint| {
                push(self, .{ .char = .{
                    .window = id,
                    .codepoint = codepoint,
                    .mods = readMods(self),
                } });
            }
            return 0;
        },

        wm_setcursor => {
            // Windows resets the cursor whenever the pointer moves over a
            // window, so the shape has to be put back here rather than once.
            // Only for the content area: the frame's own cursors - the resize
            // arrows on the border - belong to Windows.
            if (lparam & 0xFFFF != htclient) return null;
            _ = self.u.SetCursor(pointerShape(self, native));
            return 1;
        },

        wm_input => {
            // Only in `disabled`: in every other mode `WM_MOUSEMOVE` is the
            // right source, and taking both would double every movement.
            if (native.mode != .disabled or !native.raw_motion or !native.held) return null;

            var raw: RawInput = undefined;
            var raw_size: u32 = @sizeOf(RawInput);
            const got = self.u.GetRawInputData(
                @ptrFromInt(@as(usize, @bitCast(lparam))),
                rid_input,
                &raw,
                &raw_size,
                @sizeOf(RawInputHeader),
            );
            if (got == 0 or got == std.math.maxInt(u32)) return null;
            if (raw.header.kind != rim_typemouse) return null;

            var dx: f64 = @floatFromInt(raw.mouse.last_x);
            var dy: f64 = @floatFromInt(raw.mouse.last_y);

            // A tablet or a remote desktop reports where the pointer is rather
            // than how far it moved, and the difference has to be taken here.
            if (raw.mouse.flags & mouse_move_absolute != 0) {
                if (!native.has_raw_last) {
                    native.raw_last_x = raw.mouse.last_x;
                    native.raw_last_y = raw.mouse.last_y;
                    native.has_raw_last = true;
                    return 0;
                }
                dx = @floatFromInt(raw.mouse.last_x - native.raw_last_x);
                dy = @floatFromInt(raw.mouse.last_y - native.raw_last_y);
                native.raw_last_x = raw.mouse.last_x;
                native.raw_last_y = raw.mouse.last_y;
            }

            if (dx == 0 and dy == 0) return 0;

            // No position: in this mode there is no cursor to have one.
            push(self, .{ .cursor = .{
                .window = id,
                .x = 0,
                .y = 0,
                .dx = dx,
                .dy = dy,
            } });
            return 0;
        },

        wm_mousemove => {
            const x: f64 = @floatFromInt(@as(i16, @truncate(lparam & 0xFFFF)));
            const y: f64 = @floatFromInt(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));

            if (native.mode == .disabled) {
                // Let go in the background: the pointer passing over is not the camera's.
                if (!native.held) return 0;
                // Raw input is already reporting this hand movement; taking it
                // twice would turn every camera at double speed.
                if (native.raw_motion) return 0;

                // No raw input, so the delta comes from the middle of the
                // window and the pointer is put back there - which is what
                // stops it reaching an edge and the camera stopping with it.
                var rect: Rect = .{};
                if (self.u.GetClientRect(native.hwnd, &rect) == 0) return 0;
                const centre_x: f64 = @floatFromInt(@divTrunc(rect.right - rect.left, 2));
                const centre_y: f64 = @floatFromInt(@divTrunc(rect.bottom - rect.top, 2));

                const dx = x - centre_x;
                const dy = y - centre_y;
                if (dx == 0 and dy == 0) return 0;

                var origin: Point = .{
                    .x = @intFromFloat(centre_x),
                    .y = @intFromFloat(centre_y),
                };
                if (self.u.ClientToScreen(native.hwnd, &origin) != 0) {
                    _ = self.u.SetCursorPos(origin.x, origin.y);
                }

                push(self, .{ .cursor = .{ .window = id, .x = 0, .y = 0, .dx = dx, .dy = dy } });
                return 0;
            }

            const dx = if (native.has_position) x - native.last_x else 0;
            const dy = if (native.has_position) y - native.last_y else 0;
            native.last_x = x;
            native.last_y = y;
            native.has_position = true;

            push(self, .{ .cursor = .{ .window = id, .x = x, .y = y, .dx = dx, .dy = dy } });
            return 0;
        },

        wm_lbuttondown,
        wm_lbuttonup,
        wm_lbuttondblclk,
        wm_rbuttondown,
        wm_rbuttonup,
        wm_rbuttondblclk,
        wm_mbuttondown,
        wm_mbuttonup,
        wm_mbuttondblclk,
        wm_xbuttondown,
        wm_xbuttonup,
        wm_xbuttondblclk,
        => {
            const button: keys.MouseButton = switch (message) {
                wm_lbuttondown, wm_lbuttonup, wm_lbuttondblclk => .left,
                wm_rbuttondown, wm_rbuttonup, wm_rbuttondblclk => .right,
                wm_mbuttondown, wm_mbuttonup, wm_mbuttondblclk => .middle,
                // The high word says which of the two extra buttons it was.
                else => if ((wparam >> 16) & 0xFFFF == 1)
                    keys.MouseButton.button_4
                else
                    keys.MouseButton.button_5,
            };
            const double = switch (message) {
                wm_lbuttondblclk, wm_rbuttondblclk, wm_mbuttondblclk, wm_xbuttondblclk => true,
                else => false,
            };
            const down = double or switch (message) {
                wm_lbuttondown, wm_rbuttondown, wm_mbuttondown, wm_xbuttondown => true,
                else => false,
            };

            push(self, .{ .mouse_button = .{
                .window = id,
                .button = button,
                .action = if (down) .press else .release,
                .mods = readMods(self),
                .x = @floatFromInt(@as(i16, @truncate(lparam & 0xFFFF))),
                .y = @floatFromInt(@as(i16, @truncate((lparam >> 16) & 0xFFFF))),
                .double_click = double,
            } });
            // The X buttons want a non-zero return to say they were handled.
            return switch (message) {
                wm_xbuttondown, wm_xbuttonup, wm_xbuttondblclk => 1,
                else => 0,
            };
        },

        wm_mousewheel, wm_mousehwheel => {
            const raw: i16 = @truncate(@as(isize, @bitCast(wparam >> 16)));
            const amount = @as(f64, @floatFromInt(raw)) / wheel_delta;
            push(self, .{ .scroll = .{
                .window = id,
                .x = if (message == wm_mousehwheel) amount else 0,
                .y = if (message == wm_mousewheel) amount else 0,
                .mods = readMods(self),
            } });
            return 0;
        },

        wm_getminmaxinfo => {
            // The only place Windows asks about size limits, and the only place
            // they can be applied.
            if (native.limits.min_width == 0 and native.limits.min_height == 0 and
                native.limits.max_width == 0 and native.limits.max_height == 0) return null;

            const info: *MinMaxInfo = @ptrFromInt(@as(usize, @bitCast(lparam)));

            // The caller means the content area, and this message means the
            // whole window, so the frame is added on.
            var frame: Rect = .{};
            _ = self.u.AdjustWindowRectEx(&frame, native.style, 0, 0);
            const extra_x = frame.right - frame.left;
            const extra_y = frame.bottom - frame.top;

            if (native.limits.min_width != 0) {
                info.min_track_size.x = @as(i32, @intCast(native.limits.min_width)) + extra_x;
            }
            if (native.limits.min_height != 0) {
                info.min_track_size.y = @as(i32, @intCast(native.limits.min_height)) + extra_y;
            }
            if (native.limits.max_width != 0) {
                info.max_track_size.x = @as(i32, @intCast(native.limits.max_width)) + extra_x;
            }
            if (native.limits.max_height != 0) {
                info.max_track_size.y = @as(i32, @intCast(native.limits.max_height)) + extra_y;
            }
            return 0;
        },

        wm_destroy => {
            _ = hwnd;
            return 0;
        },

        else => return null,
    }
}

/// Files let go over a window: one event with every path, as UTF-8 - WTF-8,
/// for a name Windows allows and Unicode does not - and the point they were
/// let go at. The paths live in `answers`, which lasts until the next pump.
/// The handle is Windows' to free, and is freed however far this gets.
fn dropFiles(self: *Impl, id: event.WindowId, drop: ?*anyopaque) void {
    const calls = self.drops orelse return;
    defer calls.DragFinish(drop);
    const arena = self.answers.allocator();
    const count = calls.DragQueryFileW(drop, drop_count, null, 0);
    const paths = arena.alloc([]const u8, count) catch {
        self.push_failed = true;
        return;
    };
    var kept: usize = 0;
    for (0..count) |i| {
        const index: u32 = @intCast(i);
        const len = calls.DragQueryFileW(drop, index, null, 0);
        if (len == 0) continue;
        const wide = arena.alloc(u16, len + 1) catch {
            self.push_failed = true;
            return;
        };
        const got = calls.DragQueryFileW(drop, index, wide.ptr, len + 1);
        paths[kept] = std.unicode.wtf16LeToWtf8Alloc(arena, wide[0..got]) catch {
            self.push_failed = true;
            return;
        };
        kept += 1;
    }
    // In the client area's pixels, as a cursor's position is.
    var at: Point = .{};
    _ = calls.DragQueryPoint(drop, &at);
    push(self, .{ .drop = .{
        .window = id,
        .paths = paths[0..kept],
        .x = @floatFromInt(at.x),
        .y = @floatFromInt(at.y),
    } });
}

/// Push, or remember that there was no room. A window procedure cannot fail, so
/// the failure is carried to the end of `pump` and returned from there.
fn push(self: *Impl, ev: event.Event) void {
    const queue = self.queue orelse return self.later.keep(self.gpa, ev);
    queue.push(ev) catch {
        self.push_failed = true;
    };
}

/// Where on the keyboard a key message came from.
///
/// Normally straight out of `lParam`, where bits 16 to 23 hold the scan code
/// and bit 24 says it was one of the extended keys - the right-hand control,
/// the arrow cluster, the numeric enter.
///
/// **A synthesised keystroke has no scan code.** `SendInput`, `keybd_event`,
/// an on-screen keyboard, a remote desktop, a screen reader and a macro tool
/// all send a virtual key with `lParam` zero. Taking that at face value reports
/// every one of those keys as `.unknown`, so a zero is turned back into a
/// position with `MapVirtualKeyW` - which is what the virtual key would have
/// come from on this layout.
fn scancodeFrom(self: *Impl, wparam: WPARAM, lparam: LPARAM) u32 {
    const raw: u32 = @intCast((lparam >> 16) & 0xFF);
    const extended = (lparam >> 24) & 1 != 0;
    if (raw != 0) return if (extended) raw | 0x100 else raw;

    const vk: u32 = @intCast(wparam & 0xFF);
    const mapped = self.u.MapVirtualKeyW(vk, mapvk_vk_to_vsc);
    // A virtual key the layout has no position for. Nothing to report but the
    // zero, which `keyFromScancode` already answers `.unknown` to.
    if (mapped == 0) return 0;
    return if (extended) mapped | 0x100 else mapped;
}

/// `KeyEvent.virtual`, from the virtual key Windows sent with the message.
///
/// Windows has worked this out already. A layout gives each letter key the
/// virtual key of the letter printed on it - `VK_Z` for the key marked Z,
/// wherever that is - and a layout whose letters are not Latin gives them the
/// Latin letter of their place, which is the rule `virtual_key` writes down
/// for every backend. A key the layout gives no letter is anything but one.
fn virtualFrom(physical: keys.Key, vk: WPARAM) keys.Key {
    if (vk == vk_processkey) return physical;
    const letter: ?u8 = if (vk >= 'A' and vk <= 'Z') @intCast(vk) else null;
    return virtual_key.fromLetter(physical, letter);
}

/// One `WM_CHAR` into a codepoint, or null where there is no text in it.
///
/// Two reasons for null. A high surrogate is half a character and has to wait
/// for its partner - an emoji arrives as two messages. And a control code is
/// not text at all: `WM_CHAR` carries one for escape, tab, enter and backspace,
/// and those are `.key` events rather than something to append to a string.
fn charFrom(native: *Native, unit: u16) ?u21 {
    if (native.pending_surrogate) |high| {
        native.pending_surrogate = null;
        if (unit >= 0xDC00 and unit <= 0xDFFF) {
            const value = 0x10000 +
                (@as(u21, high - 0xD800) << 10) +
                @as(u21, unit - 0xDC00);
            return value;
        }
        // A high surrogate followed by something that is not a low one. The
        // pair is broken; drop it rather than emitting a lone surrogate, which
        // is not a codepoint.
        return null;
    }

    if (unit >= 0xD800 and unit <= 0xDBFF) {
        native.pending_surrogate = unit;
        return null;
    }
    if (unit >= 0xDC00 and unit <= 0xDFFF) return null;

    // Not text. Windows sends a `WM_CHAR` for escape, tab, enter and backspace
    // carrying their control code, and a text field that appended what it was
    // given would grow a `\x1b` every time the user pressed escape. Those keys
    // are `.key` events and nothing else, which is what the other three
    // backends already do.
    if (unit < 0x20 or unit == 0x7F) return null;
    // And the C1 block, which no keyboard produces and which arrives from
    // nothing but a program injecting keystrokes.
    if (unit >= 0x80 and unit < 0xA0) return null;

    return unit;
}

fn readMods(self: *Impl) keys.Mods {
    const get = self.u.GetKeyState;
    // The high bit is "down now"; the low bit is "toggled on", which is what a
    // lock key means.
    const down = struct {
        fn f(state: i16) bool {
            return @as(u16, @bitCast(state)) & 0x8000 != 0;
        }
    }.f;
    const toggled = struct {
        fn f(state: i16) bool {
            return @as(u16, @bitCast(state)) & 1 != 0;
        }
    }.f;

    // The made-up left control stays down in the key state for as long as AltGr is.
    const alt_graph = self.alt_graph and down(get(vk_rmenu));
    return .{
        .shift = down(get(vk_shift)),
        .control = down(get(vk_rcontrol)) or (down(get(vk_lcontrol)) and !alt_graph),
        .alt = down(get(vk_lmenu)) or (down(get(vk_rmenu)) and !alt_graph),
        .super = down(get(vk_lwin)) or down(get(vk_rwin)),
        .caps_lock = toggled(get(vk_capital)),
        .num_lock = toggled(get(vk_numlock)),
        .alt_graph = alt_graph,
    };
}

/// AltGr arrives as a left control Windows made up, then the right alt,
/// stamped with the same time. GLFW spots it the same way.
fn rightAltNext(self: *Impl) bool {
    var next: Msg = .{};
    if (self.u.PeekMessageW(&next, null, 0, 0, pm_noremove) == 0) return false;
    const key = switch (next.message) {
        wm_keydown, wm_syskeydown, wm_keyup, wm_syskeyup => true,
        else => false,
    };
    const extended = (next.lparam >> 24) & 1 != 0;
    return key and extended and next.wparam == @as(WPARAM, @intCast(vk_menu)) and
        next.time == @as(u32, @bitCast(self.u.GetMessageTime()));
}

// -------------------------------------------------------------------------
// Scancodes
// -------------------------------------------------------------------------

/// Set 1 make codes, which is what `lParam` carries, with `0x100` added for the
/// ones behind an `E0` prefix.
fn keyFromScancode(scancode: u32) keys.Key {
    return switch (scancode) {
        0x01 => .escape,
        0x02 => .@"1",
        0x03 => .@"2",
        0x04 => .@"3",
        0x05 => .@"4",
        0x06 => .@"5",
        0x07 => .@"6",
        0x08 => .@"7",
        0x09 => .@"8",
        0x0A => .@"9",
        0x0B => .@"0",
        0x0C => .minus,
        0x0D => .equal,
        0x0E => .backspace,
        0x0F => .tab,
        0x10 => .q,
        0x11 => .w,
        0x12 => .e,
        0x13 => .r,
        0x14 => .t,
        0x15 => .y,
        0x16 => .u,
        0x17 => .i,
        0x18 => .o,
        0x19 => .p,
        0x1A => .left_bracket,
        0x1B => .right_bracket,
        0x1C => .enter,
        0x1D => .left_control,
        0x1E => .a,
        0x1F => .s,
        0x20 => .d,
        0x21 => .f,
        0x22 => .g,
        0x23 => .h,
        0x24 => .j,
        0x25 => .k,
        0x26 => .l,
        0x27 => .semicolon,
        0x28 => .apostrophe,
        0x29 => .grave_accent,
        0x2A => .left_shift,
        0x2B => .backslash,
        0x2C => .z,
        0x2D => .x,
        0x2E => .c,
        0x2F => .v,
        0x30 => .b,
        0x31 => .n,
        0x32 => .m,
        0x33 => .comma,
        0x34 => .period,
        0x35 => .slash,
        0x36 => .right_shift,
        0x37 => .kp_multiply,
        0x38 => .left_alt,
        0x39 => .space,
        0x3A => .caps_lock,
        0x3B => .f1,
        0x3C => .f2,
        0x3D => .f3,
        0x3E => .f4,
        0x3F => .f5,
        0x40 => .f6,
        0x41 => .f7,
        0x42 => .f8,
        0x43 => .f9,
        0x44 => .f10,
        0x45 => .num_lock,
        0x46 => .scroll_lock,
        0x47 => .kp_7,
        0x48 => .kp_8,
        0x49 => .kp_9,
        0x4A => .kp_subtract,
        0x4B => .kp_4,
        0x4C => .kp_5,
        0x4D => .kp_6,
        0x4E => .kp_add,
        0x4F => .kp_1,
        0x50 => .kp_2,
        0x51 => .kp_3,
        0x52 => .kp_0,
        0x53 => .kp_decimal,
        // The extra key an ISO keyboard has and an ANSI one does not.
        0x56 => .world_2,
        0x57 => .f11,
        0x58 => .f12,
        0x64 => .f13,
        0x65 => .f14,
        0x66 => .f15,
        0x67 => .f16,
        0x68 => .f17,
        0x69 => .f18,
        0x6A => .f19,
        0x6B => .f20,
        0x6C => .f21,
        0x6D => .f22,
        0x6E => .f23,
        0x76 => .f24,

        // Behind an E0 prefix: the duplicates on the right and the island keys.
        0x11C => .kp_enter,
        0x11D => .right_control,
        0x135 => .kp_divide,
        0x137 => .print_screen,
        0x138 => .right_alt,
        0x145 => .pause,
        0x147 => .home,
        0x148 => .up,
        0x149 => .page_up,
        0x14B => .left,
        0x14D => .right,
        0x14F => .end,
        0x150 => .down,
        0x151 => .page_down,
        0x152 => .insert,
        0x153 => .delete,
        0x15B => .left_super,
        0x15C => .right_super,
        0x15D => .menu,

        else => .unknown,
    };
}

// -------------------------------------------------------------------------
// Tests
//
// Everything here that can be tested without a window is. Opening one needs a
// desktop session, which a build machine may not have, so those tests skip
// rather than fail.
// -------------------------------------------------------------------------

test "the scancode table is the physical layout, not the letters" {
    // The four that make WASD, at their positions on any layout.
    try testing.expectEqual(keys.Key.w, keyFromScancode(0x11));
    try testing.expectEqual(keys.Key.a, keyFromScancode(0x1E));
    try testing.expectEqual(keys.Key.s, keyFromScancode(0x1F));
    try testing.expectEqual(keys.Key.d, keyFromScancode(0x20));

    try testing.expectEqual(keys.Key.escape, keyFromScancode(0x01));
    try testing.expectEqual(keys.Key.space, keyFromScancode(0x39));
    try testing.expectEqual(keys.Key.f1, keyFromScancode(0x3B));
}

test "the extended prefix tells the two enter keys apart" {
    try testing.expectEqual(keys.Key.enter, keyFromScancode(0x1C));
    try testing.expectEqual(keys.Key.kp_enter, keyFromScancode(0x11C));

    try testing.expectEqual(keys.Key.left_control, keyFromScancode(0x1D));
    try testing.expectEqual(keys.Key.right_control, keyFromScancode(0x11D));

    // And the arrows, which exist only as extended codes.
    try testing.expectEqual(keys.Key.up, keyFromScancode(0x148));
    try testing.expectEqual(keys.Key.left, keyFromScancode(0x14B));
}

test "a scancode with no name is unknown, not a wrong key" {
    try testing.expectEqual(keys.Key.unknown, keyFromScancode(0x00));
    try testing.expectEqual(keys.Key.unknown, keyFromScancode(0xFE));
    try testing.expectEqual(keys.Key.unknown, keyFromScancode(0x1FF));
}

test "the virtual key is the letter the layout gave the key" {
    // Hungarian and German: the key where US has Y sends VK_Z, and the other
    // way round.
    try testing.expectEqual(keys.Key.z, virtualFrom(keyFromScancode(0x15), 'Z'));
    try testing.expectEqual(keys.Key.y, virtualFrom(keyFromScancode(0x2C), 'Y'));
    // Russian sends VK_Z from the place US has Z, which is where it stays.
    try testing.expectEqual(keys.Key.z, virtualFrom(.z, 'Z'));
    // AZERTY's comma, where US has M, is VK_OEM_COMMA and claims no letter.
    try testing.expectEqual(keys.Key.unknown, virtualFrom(.m, 0xBC));
    // Digits and the keys that type nothing keep their names.
    try testing.expectEqual(keys.Key.@"1", virtualFrom(.@"1", '1'));
    try testing.expectEqual(keys.Key.left, virtualFrom(.left, 0x25));
    // While an input method has the keys, which one it was is not known.
    try testing.expectEqual(keys.Key.q, virtualFrom(.q, vk_processkey));
}

test "a surrogate pair becomes one codepoint" {
    var native: Native = .{ .hwnd = undefined, .id = @enumFromInt(1), .impl = undefined };

    // U+1F600, which UTF-16 splits into D83D DE00 and Windows sends as two
    // WM_CHAR messages.
    try testing.expectEqual(@as(?u21, null), charFrom(&native, 0xD83D));
    try testing.expectEqual(@as(?u21, 0x1F600), charFrom(&native, 0xDE00));
    // And the pair is finished, so the next unit stands alone.
    try testing.expectEqual(@as(?u16, null), native.pending_surrogate);
}

test "an ordinary character passes straight through" {
    var native: Native = .{ .hwnd = undefined, .id = @enumFromInt(1), .impl = undefined };
    try testing.expectEqual(@as(?u21, 'a'), charFrom(&native, 'a'));
    // Above ASCII but still one unit.
    try testing.expectEqual(@as(?u21, 0x00E9), charFrom(&native, 0x00E9));
}

test "a broken surrogate pair is dropped rather than emitted" {
    var native: Native = .{ .hwnd = undefined, .id = @enumFromInt(1), .impl = undefined };

    // A high surrogate followed by an ordinary character: the pair is broken.
    try testing.expectEqual(@as(?u21, null), charFrom(&native, 0xD83D));
    try testing.expectEqual(@as(?u21, null), charFrom(&native, 'a'));

    // A lone low surrogate is not a codepoint either.
    try testing.expectEqual(@as(?u21, null), charFrom(&native, 0xDE00));
}

test "the window style follows the description" {
    const plain = styleFor(.{
        .title = "",
        .width = 1,
        .height = 1,
        .resizable = true,
        .decorated = true,
        .visible = true,
        .maximized = false,
        .gl = null,
    });
    try testing.expect(plain & ws_caption != 0);
    try testing.expect(plain & ws_thickframe != 0);
    try testing.expect(plain & ws_visible != 0);

    // Undecorated is a popup, and has no frame to resize.
    const bare = styleFor(.{
        .title = "",
        .width = 1,
        .height = 1,
        .resizable = false,
        .decorated = false,
        .visible = false,
        .maximized = false,
        .gl = null,
    });
    try testing.expect(bare & ws_popup != 0);
    try testing.expect(bare & ws_caption == 0);
    try testing.expect(bare & ws_thickframe == 0);
    try testing.expect(bare & ws_visible == 0);

    // Maximized needs a frame to maximize into.
    const fixed_max = styleFor(.{
        .title = "",
        .width = 1,
        .height = 1,
        .resizable = false,
        .decorated = true,
        .visible = true,
        .maximized = true,
        .gl = null,
    });
    try testing.expect(fixed_max & ws_maximize == 0);
}

test "opening the backend, on a machine with a desktop" {
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);

    try testing.expectEqual(platform.Backend.win32, vtable.backend);

    // Pumping with no windows is valid and produces nothing about a window.
    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);
}

test "a window, its size, and the events it makes" {
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);

    const native = try vtable.createWindow(impl, testing.allocator, @enumFromInt(1), .{
        .title = "fluxion-platform test",
        .width = 320,
        .height = 240,
        .resizable = true,
        .decorated = true,
        // Not shown: a test that flashes a window on screen is a nuisance, and
        // everything checked here works on a hidden one.
        .visible = false,
        .maximized = false,
        .gl = null,
    });
    defer vtable.destroyWindow(impl, testing.allocator, native);

    // The size asked for is the content area, which is what comes back.
    const fb = vtable.framebufferSize(impl, native);
    try testing.expectEqual(@as(u32, 320), fb[0]);
    try testing.expectEqual(@as(u32, 240), fb[1]);

    // A scale is always positive, whether or not this Windows has the DPI call.
    const scale = vtable.contentScale(impl, native);
    try testing.expect(scale[0] > 0 and scale[1] > 0);

    try vtable.setTitle(impl, native, "renamed");
    // Invalid UTF-8 is refused rather than mangled on the way to UTF-16.
    try testing.expectError(error.Unavailable, vtable.setTitle(impl, native, "\xFF\xFE"));

    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);
}

test "a message posted to the window comes back out as an event" {
    // The whole path in one go: a real message goes into the system's queue,
    // `pump` takes it out, the window procedure turns it into an event, and the
    // event names the window it came from. Everything between `CreateWindowExW`
    // and `poll` is exercised here and nowhere else.
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);

    const self = cast(impl);
    const id: event.WindowId = @enumFromInt(42);

    const native = try vtable.createWindow(impl, testing.allocator, id, .{
        .title = "fluxion-platform pump test",
        .width = 320,
        .height = 240,
        .resizable = true,
        .decorated = true,
        .visible = false,
        .maximized = false,
        .gl = null,
    });
    defer vtable.destroyWindow(impl, testing.allocator, native);

    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();

    // Drain whatever creating the window left behind, so the next pump sees
    // only what this test posts.
    try vtable.pump(impl, &queue);
    queue.clear();

    const hwnd = castWindow(native).hwnd;
    try testing.expect(self.u.PostMessageW(hwnd, wm_close, 0, 0) != 0);

    try vtable.pump(impl, &queue);

    const first = queue.next() orelse return error.NoEventArrived;
    try testing.expectEqual(id, first.window());
    try testing.expect(first == .close);

    // And the window is still open: a close is a request, and nothing here
    // acted on it.
    var after: Rect = .{};
    try testing.expect(self.u.GetClientRect(hwnd, &after) != 0);
}

test "files dropped on a window come out as one event, every path and the point they were let go at" {
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);
    const self = cast(impl);
    if (self.drops == null) return error.SkipZigTest;

    const id: event.WindowId = @enumFromInt(7);
    const native = try vtable.createWindow(impl, testing.allocator, id, .{
        .title = "fluxion-platform drop test",
        .width = 320,
        .height = 240,
        .resizable = true,
        .decorated = true,
        .visible = false,
        .maximized = false,
        .gl = null,
    });
    defer vtable.destroyWindow(impl, testing.allocator, native);
    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);
    queue.clear();

    // What the file manager hands over, made by hand: a `DROPFILES` header -
    // where the names start, the point, not the frame, wide names - and the
    // names after it, each ended, and the list ended by one more nothing.
    const names = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Levels\\meadow.json\x00C:\\Art\\hérø.png\x00\x00");
    const DropFiles = extern struct { files: u32, x: i32, y: i32, non_client: i32, wide: i32 };
    const bytes = @sizeOf(DropFiles) + names.len * 2;
    const gmem_zeroinit: u32 = 0x0040;
    const memory = self.k.GlobalAlloc(gmem_moveable | gmem_zeroinit, bytes) orelse return error.OutOfMemory;
    const at: [*]u8 = @ptrCast(self.k.GlobalLock(memory) orelse return error.OutOfMemory);
    const header: DropFiles = .{ .files = @sizeOf(DropFiles), .x = 120, .y = 45, .non_client = 0, .wide = 1 };
    @memcpy(at[0..@sizeOf(DropFiles)], std.mem.asBytes(&header));
    @memcpy(at[@sizeOf(DropFiles)..bytes], std.mem.sliceAsBytes(names[0..names.len]));
    _ = self.k.GlobalUnlock(memory);
    try testing.expect(self.u.PostMessageW(castWindow(native).hwnd, wm_dropfiles, @intFromPtr(memory), 0) != 0);

    try vtable.pump(impl, &queue);
    const dropped = (queue.next() orelse return error.NoEventArrived).drop;
    try testing.expectEqual(id, dropped.window);
    try testing.expectEqual(@as(usize, 2), dropped.paths.len);
    try testing.expectEqualStrings("C:\\Levels\\meadow.json", dropped.paths[0]);
    try testing.expectEqualStrings("C:\\Art\\hérø.png", dropped.paths[1]);
    try testing.expectEqual(@as(f64, 120), dropped.x);
    try testing.expectEqual(@as(f64, 45), dropped.y);
}

test "a dialog's answer comes out of a pump, naming its window and its id" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);
    const self = cast(impl);

    const native = try vtable.createWindow(impl, testing.allocator, @enumFromInt(5), .{
        .title = "fluxion-platform dialog test",
        .width = 320,
        .height = 240,
        .resizable = true,
        .decorated = true,
        .visible = false,
        .maximized = false,
        .gl = null,
    });
    defer vtable.destroyWindow(impl, testing.allocator, native);

    const request: backend.DialogRequest = .{
        .id = @enumFromInt(7),
        .window = @enumFromInt(5),
        .folder = true,
        .multiple = false,
        .title = null,
        .filters = &.{},
        .initial_folder = null,
    };
    self.shell = win32_dialog.Shell.open() catch return error.SkipZigTest;
    const job = try win32_dialog.Dialog.create(testing.allocator, self.shell.?.calls, @ptrCast(castWindow(native).hwnd), request);
    job.abandon();
    try job.spawn();
    self.dialog = job;

    try testing.expectError(error.Unavailable, vtable.showFileDialog(impl, testing.allocator, request));

    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    var answer: ?event.FileDialogEvent = null;
    for (0..50) |_| {
        try vtable.wait(impl, 100);
        queue.clear();
        try vtable.pump(impl, &queue);
        while (queue.next()) |ev| {
            if (ev == .file_dialog) answer = ev.file_dialog;
        }
        if (answer != null) break;
    }

    const got = answer orelse return error.NoAnswerArrived;
    try testing.expectEqual(request.id, got.id);
    try testing.expectEqual(request.window, got.window);
    try testing.expectEqual(@as(usize, 0), got.paths.len);
    try testing.expectEqual(@as(?*win32_dialog.Dialog, null), self.dialog);
}

fn hiddenWindow(impl: backend.Impl, id: event.WindowId) !*Native {
    return castWindow(try vtable.createWindow(impl, testing.allocator, id, .{
        .title = "fluxion-platform state test",
        .width = 320,
        .height = 240,
        .resizable = true,
        .decorated = true,
        .visible = false,
        .maximized = false,
        .gl = null,
    }));
}

fn postAndPump(impl: backend.Impl, queue: *backend.Queue, win: *Native, message: u32, wparam: WPARAM, lparam: LPARAM) !void {
    queue.clear();
    try testing.expect(cast(impl).u.PostMessageW(win.hwnd, message, wparam, lparam) != 0);
    try vtable.pump(impl, queue);
}

test "minimising is one iconify and no size, and coming back says what it left" {
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);
    const id: event.WindowId = @enumFromInt(3);
    const win = try hiddenWindow(impl, id);
    defer vtable.destroyWindow(impl, testing.allocator, win);
    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);

    try postAndPump(impl, &queue, win, wm_size, size_minimized, 0);
    try testing.expectEqual(event.Event{ .iconify = .{ .window = id, .value = true } }, queue.next().?);
    try testing.expectEqual(@as(?event.Event, null), queue.next());

    try postAndPump(impl, &queue, win, wm_size, size_maximized, 640 | (480 << 16));
    try testing.expectEqual(event.Event{ .iconify = .{ .window = id, .value = false } }, queue.next().?);
    try testing.expectEqual(event.Event{ .maximize = .{ .window = id, .value = true } }, queue.next().?);
    try testing.expectEqual(event.Event{ .framebuffer_resize = .{ .window = id, .width = 640, .height = 480 } }, queue.next().?);

    try postAndPump(impl, &queue, win, wm_size, size_minimized, 0);
    try testing.expectEqual(event.Event{ .iconify = .{ .window = id, .value = true } }, queue.next().?);
    try testing.expectEqual(@as(?event.Event, null), queue.next());

    try postAndPump(impl, &queue, win, wm_size, size_restored, 640 | (480 << 16));
    try testing.expectEqual(event.Event{ .iconify = .{ .window = id, .value = false } }, queue.next().?);
    try testing.expectEqual(event.Event{ .maximize = .{ .window = id, .value = false } }, queue.next().?);
    try testing.expectEqual(@as(?event.Event, null), queue.next());
}

test "a confining mode holds the pointer only while the window has focus" {
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);
    const self = cast(impl);
    var was: Point = .{};
    _ = self.u.GetCursorPos(&was);
    defer _ = self.u.SetCursorPos(was.x, was.y);

    const win = try hiddenWindow(impl, @enumFromInt(4));
    defer vtable.destroyWindow(impl, testing.allocator, win);
    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);

    try vtable.setCursorMode(impl, win, .captured);
    try testing.expect(!win.held);

    try postAndPump(impl, &queue, win, wm_setfocus, 0, 0);
    try testing.expect(win.held);
    try postAndPump(impl, &queue, win, wm_killfocus, 0, 0);
    try testing.expect(!win.held);
    try testing.expectEqual(cursor_mod.Mode.captured, win.mode);

    const on_caption: LPARAM = (@as(LPARAM, wm_lbuttondown) << 16) | 2;
    try postAndPump(impl, &queue, win, wm_mouseactivate, 0, on_caption);
    try postAndPump(impl, &queue, win, wm_setfocus, 0, 0);
    try testing.expect(!win.held);
    try postAndPump(impl, &queue, win, wm_capturechanged, 0, 0);
    try testing.expect(win.held);

    try vtable.setCursorMode(impl, win, .normal);
    try testing.expect(!win.held);
}

test "Windows' own double click is a press that says so, an extra button's too" {
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);
    const win = try hiddenWindow(impl, @enumFromInt(9));
    defer vtable.destroyWindow(impl, testing.allocator, win);
    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);

    const at: LPARAM = 12 | (34 << 16);
    try postAndPump(impl, &queue, win, wm_lbuttondown, 0, at);
    try testing.expect(!queue.next().?.mouse_button.double_click);

    try postAndPump(impl, &queue, win, wm_lbuttondblclk, 0, at);
    const double = queue.next().?.mouse_button;
    try testing.expect(double.double_click);
    try testing.expectEqual(keys.MouseButton.left, double.button);
    try testing.expectEqual(keys.Action.press, double.action);
    try testing.expectEqual(@as(f64, 34), double.y);

    try postAndPump(impl, &queue, win, wm_xbuttondblclk, 2 << 16, at);
    const extra = queue.next().?.mouse_button;
    try testing.expect(extra.double_click);
    try testing.expectEqual(keys.MouseButton.button_5, extra.button);

    try testing.expect(vtable.doubleClickTime(impl) > 0);
}

fn keyLparam(scancode: u32, extended: bool, up: bool) LPARAM {
    var bits: usize = 1 | (@as(usize, scancode) << 16);
    if (extended) bits |= 1 << 24;
    if (up) bits |= 0xC000_0000;
    return @bitCast(bits);
}

test "the left control Windows makes up for AltGr is no key, and AltGr is not control" {
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);
    const self = cast(impl);
    const win = try hiddenWindow(impl, @enumFromInt(8));
    defer vtable.destroyWindow(impl, testing.allocator, win);
    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);
    queue.clear();

    const control: WPARAM = @intCast(vk_control);
    const menu: WPARAM = @intCast(vk_menu);
    try testing.expect(self.u.PostMessageW(win.hwnd, wm_keydown, control, keyLparam(0x1D, false, false)) != 0);
    try testing.expect(self.u.PostMessageW(win.hwnd, wm_keydown, menu, keyLparam(0x38, true, false)) != 0);
    try vtable.pump(impl, &queue);
    const pressed = queue.next().?.key;
    try testing.expectEqual(keys.Key.right_alt, pressed.key);
    try testing.expectEqual(keys.Action.press, pressed.action);
    try testing.expectEqual(@as(?event.Event, null), queue.next());
    try testing.expect(self.alt_graph);

    queue.clear();
    try testing.expect(self.u.PostMessageW(win.hwnd, wm_keyup, control, keyLparam(0x1D, false, true)) != 0);
    try testing.expect(self.u.PostMessageW(win.hwnd, wm_keyup, menu, keyLparam(0x38, true, true)) != 0);
    try vtable.pump(impl, &queue);
    try testing.expectEqual(keys.Action.release, queue.next().?.key.action);
    try testing.expectEqual(@as(?event.Event, null), queue.next());
    try testing.expect(!self.alt_graph);

    queue.clear();
    try testing.expect(self.u.PostMessageW(win.hwnd, wm_keydown, control, keyLparam(0x1D, false, false)) != 0);
    try vtable.pump(impl, &queue);
    try testing.expectEqual(keys.Key.left_control, queue.next().?.key.key);
}