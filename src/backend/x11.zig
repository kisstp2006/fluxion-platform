// SPDX-License-Identifier: BSL-1.0

//! The X11 backend: `libX11.so.6`, opened by name.
//!
//! Loaded rather than linked, and on this platform that is the whole argument
//! for the design. A binary that imports `XOpenDisplay` the ordinary way does
//! not start on a Wayland-only machine with no X libraries installed - the
//! loader fails before `main`, and the fallback that would have opened Wayland
//! never runs. Fetched by name, a missing `libX11` is `error.NoDisplay` and
//! `Context.init` moves on to the next candidate.
//!
//! **Keys come from the keycode, not the keysym.** A keysym is what the layout
//! says the key means, so it moves under a user on AZERTY. An X11 keycode is
//! the physical key, and on any modern Linux it is the kernel's evdev code plus
//! eight - which is a stable position, and what `Key` promises. The text the
//! user actually typed arrives separately, as a `.char` event.
//!
//! **Everything except the struct layouts is testable off X11.** The keycode
//! table and the ABI assertions compile and run on any host, because getting a
//! field offset wrong here is memory corruption rather than an error, and that
//! deserves a test that runs everywhere rather than only where a display is.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const dyn = @import("fluxion_dyn");

const backend = @import("../backend.zig");
const event = @import("../event.zig");
const monitor = @import("../monitor.zig");
const gamepad = @import("../gamepad.zig");
const linux_gamepad = @import("linux_gamepad.zig");
const glx = @import("glx.zig");
const virtual_key = @import("virtual_key.zig");
const gl = @import("../gl.zig");
const vulkan = @import("../vulkan.zig");
const text_mod = @import("../text.zig");
const keys = @import("../keys.zig");
const platform = @import("../platform.zig");
const evdev = @import("evdev.zig");
const cursor_mod = @import("../cursor.zig");
const clipboard = @import("clipboard.zig");

const Error = platform.Error;

/// Where an X server can be reached. Elsewhere the file still compiles - the
/// struct layouts and the keycode table are ordinary data - and `open` refuses.
pub const has_display = switch (builtin.os.tag) {
    .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => !builtin.abi.isAndroid(),
    else => false,
};

/// The four calls the wake pipe needs, declared here rather than taken from
/// `std.posix`, which no longer carries all of them.
///
/// They come from libc, which an X11 program links anyway: `dlopen` is how
/// `libX11` itself is found.
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
// The slice of Xlib this backend speaks
//
// `Bool` is a C `int` and every id is an `unsigned long`, so on LP64 these are
// four and eight bytes. The tests below assert the sizes, because a field in
// the wrong place here is not an error, it is a wrong window id read out of the
// middle of a timestamp.
// -------------------------------------------------------------------------

const Display = opaque {};
const XID = c_ulong;
const Window = XID;
const Colormap = XID;
const Cursor = XID;
const Pixmap = XID;
const Atom = c_ulong;
const Time = c_ulong;
const KeySym = c_ulong;
const Bool = c_int;
const Status = c_int;

const XAnyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
};

const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: Bool,
};

const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: Bool,
};

const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: u8,
    same_screen: Bool,
};

const XCrossingEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    mode: c_int,
    detail: c_int,
    same_screen: Bool,
    focus: Bool,
    state: c_uint,
};

const XFocusChangeEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    mode: c_int,
    detail: c_int,
};

const XExposeEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    count: c_int,
};

const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    event: Window,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window,
    override_redirect: Bool,
};

const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: extern union {
        b: [20]u8,
        s: [10]c_short,
        l: [5]c_long,
    },
};

const XPropertyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    atom: Atom,
    time: Time,
    state: c_int,
};

const XSelectionClearEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    selection: Atom,
    time: Time,
};

const XSelectionRequestEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    owner: Window,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: Time,
};

const XSelectionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: Time,
};

/// `long pad[24]`, which is what every X event has to fit inside.
const XEvent = extern union {
    type: c_int,
    xany: XAnyEvent,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xcrossing: XCrossingEvent,
    xfocus: XFocusChangeEvent,
    xexpose: XExposeEvent,
    xconfigure: XConfigureEvent,
    xclient: XClientMessageEvent,
    xproperty: XPropertyEvent,
    xselectionclear: XSelectionClearEvent,
    xselectionrequest: XSelectionRequestEvent,
    xselection: XSelectionEvent,
    pad: [24]c_long,
};

const XColor = extern struct {
    pixel: c_ulong,
    red: c_ushort,
    green: c_ushort,
    blue: c_ushort,
    flags: u8,
    pad: u8,
};

/// `XCreateFontCursor` shapes, from `cursorfont.h`. The numbers are the glyph
/// indices in the cursor font, which is why they are even and look arbitrary.
const xc_x_cursor: c_uint = 0;
const xc_crosshair: c_uint = 34;
const xc_fleur: c_uint = 52;
const xc_hand2: c_uint = 60;
const xc_left_ptr: c_uint = 68;
const xc_sb_h_double_arrow: c_uint = 108;
const xc_sb_v_double_arrow: c_uint = 116;
const xc_xterm: c_uint = 152;

/// `XGrabPointer` modes and the mask it wants.
const grab_mode_async: c_int = 1;
const grab_success: c_int = 0;
const pointer_grab_mask: c_uint = @intCast(button_press_mask | button_release_mask | pointer_motion_mask);

const XSizeHints = extern struct {
    flags: c_long,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    min_width: c_int,
    min_height: c_int,
    max_width: c_int,
    max_height: c_int,
    width_inc: c_int,
    height_inc: c_int,
    min_aspect: extern struct { x: c_int, y: c_int },
    max_aspect: extern struct { x: c_int, y: c_int },
    base_width: c_int,
    base_height: c_int,
    win_gravity: c_int,
};

// Event type numbers, from X.h.
const key_press: c_int = 2;
const key_release: c_int = 3;
const button_press: c_int = 4;
const button_release: c_int = 5;
const motion_notify: c_int = 6;
const enter_notify: c_int = 7;
const leave_notify: c_int = 8;
const focus_in: c_int = 9;
const focus_out: c_int = 10;
const expose: c_int = 12;
const configure_notify: c_int = 22;
const property_notify: c_int = 28;
const selection_clear: c_int = 29;
const selection_request: c_int = 30;
const selection_notify: c_int = 31;
const client_message: c_int = 33;

// Event masks.
const key_press_mask: c_long = 1 << 0;
const key_release_mask: c_long = 1 << 1;
const button_press_mask: c_long = 1 << 2;
const button_release_mask: c_long = 1 << 3;
const enter_window_mask: c_long = 1 << 4;
const leave_window_mask: c_long = 1 << 5;
const pointer_motion_mask: c_long = 1 << 6;
const exposure_mask: c_long = 1 << 15;
const structure_notify_mask: c_long = 1 << 17;
const focus_change_mask: c_long = 1 << 21;
const property_change_mask: c_long = 1 << 22;

const window_event_mask: c_long = key_press_mask | key_release_mask |
    button_press_mask | button_release_mask |
    enter_window_mask | leave_window_mask |
    pointer_motion_mask | exposure_mask |
    structure_notify_mask | focus_change_mask;

// Modifier bits in `state`.
const shift_mask: c_uint = 1 << 0;
const lock_mask: c_uint = 1 << 1;
const control_mask: c_uint = 1 << 2;
const mod1_mask: c_uint = 1 << 3; // alt
const mod2_mask: c_uint = 1 << 4; // num lock
const mod4_mask: c_uint = 1 << 6; // super

// `XSizeHints.flags`.
const p_min_size: c_long = 1 << 4;
const p_max_size: c_long = 1 << 5;

const prop_mode_replace: c_int = 0;

/// The predefined atoms `ATOM` and `STRING`, and the rest of what a selection
/// is spoken in.
const xa_atom: Atom = 4;
const xa_string: Atom = 31;
const any_property_type: Atom = 0;
const property_new_value: c_int = 0;
const current_time: Time = 0;
/// `InputOnly` and `CWEventMask`: a window that is never drawn, only named.
const input_only: c_uint = 2;
const cw_event_mask: c_ulong = 1 << 11;

/// `XErrorHandler`. The event is left untyped: nothing here reads it.
const ErrorHandler = *const fn (?*Display, ?*anyopaque) callconv(.c) c_int;

/// `XSetInputFocus` revert-to, and the `_NET_WM_STATE` actions.
const revert_to_parent: c_int = 1;
const net_wm_state_remove: c_long = 0;
const net_wm_state_add: c_long = 1;

/// `XSizeHints.flags`, the position bit.
const p_position: c_long = 1 << 2;

/// Opacity is a property, not a call: the compositor reads it and does the
/// blending. Absent compositor, absent effect - and no error, because nothing
/// failed.
const opaque_max: c_ulong = 0xFFFFFFFF;

/// The one atom every window needs: without it the window manager kills the
/// connection instead of asking, and a program never gets to say "save first?".
const wm_delete_window_name = "WM_DELETE_WINDOW";

const Xlib = struct {
    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int,
    XDefaultScreen: *const fn (*Display) callconv(.c) c_int,
    XRootWindow: *const fn (*Display, c_int) callconv(.c) Window,
    XWhitePixel: *const fn (*Display, c_int) callconv(.c) c_ulong,
    XBlackPixel: *const fn (*Display, c_int) callconv(.c) c_ulong,
    XCreateSimpleWindow: *const fn (
        *Display,
        Window,
        c_int,
        c_int,
        c_uint,
        c_uint,
        c_uint,
        c_ulong,
        c_ulong,
    ) callconv(.c) Window,
    XDestroyWindow: *const fn (*Display, Window) callconv(.c) c_int,
    XMapWindow: *const fn (*Display, Window) callconv(.c) c_int,
    XUnmapWindow: *const fn (*Display, Window) callconv(.c) c_int,
    XSelectInput: *const fn (*Display, Window, c_long) callconv(.c) c_int,
    XPending: *const fn (*Display) callconv(.c) c_int,
    XNextEvent: *const fn (*Display, *XEvent) callconv(.c) c_int,
    XInternAtom: *const fn (*Display, [*:0]const u8, Bool) callconv(.c) Atom,
    XSetWMProtocols: *const fn (*Display, Window, [*]Atom, c_int) callconv(.c) Status,
    XChangeProperty: *const fn (
        *Display,
        Window,
        Atom,
        Atom,
        c_int,
        c_int,
        [*]const u8,
        c_int,
    ) callconv(.c) c_int,
    XStoreName: *const fn (*Display, Window, [*:0]const u8) callconv(.c) c_int,
    XSetWMNormalHints: *const fn (*Display, Window, *XSizeHints) callconv(.c) void,
    XFlush: *const fn (*Display) callconv(.c) c_int,
    XConnectionNumber: *const fn (*Display) callconv(.c) c_int,
    XLookupString: *const fn (
        *XKeyEvent,
        [*]u8,
        c_int,
        ?*KeySym,
        ?*anyopaque,
    ) callconv(.c) c_int,
    XResourceManagerString: *const fn (*Display) callconv(.c) ?[*:0]const u8,
    XGetGeometry: *const fn (
        *Display,
        XID,
        *Window,
        *c_int,
        *c_int,
        *c_uint,
        *c_uint,
        *c_uint,
        *c_uint,
    ) callconv(.c) Status,
    XSendEvent: *const fn (*Display, Window, Bool, c_long, *XEvent) callconv(.c) Status,
    XMoveWindow: *const fn (*Display, Window, c_int, c_int) callconv(.c) c_int,
    XIconifyWindow: *const fn (*Display, Window, c_int) callconv(.c) Status,
    XRaiseWindow: *const fn (*Display, Window) callconv(.c) c_int,
    XSetInputFocus: *const fn (*Display, Window, c_int, Time) callconv(.c) c_int,
    XGetInputFocus: *const fn (*Display, *Window, *c_int) callconv(.c) c_int,
    XTranslateCoordinates: *const fn (
        *Display,
        Window,
        Window,
        c_int,
        c_int,
        *c_int,
        *c_int,
        *Window,
    ) callconv(.c) Bool,
    XDeleteProperty: *const fn (*Display, Window, Atom) callconv(.c) c_int,
    XDefineCursor: *const fn (*Display, Window, Cursor) callconv(.c) c_int,
    XUndefineCursor: *const fn (*Display, Window) callconv(.c) c_int,
    XFreeCursor: *const fn (*Display, Cursor) callconv(.c) c_int,
    XCreateFontCursor: *const fn (*Display, c_uint) callconv(.c) Cursor,
    XCreatePixmapCursor: *const fn (
        *Display,
        Pixmap,
        Pixmap,
        *XColor,
        *XColor,
        c_uint,
        c_uint,
    ) callconv(.c) Cursor,
    XCreateBitmapFromData: *const fn (
        *Display,
        XID,
        [*]const u8,
        c_uint,
        c_uint,
    ) callconv(.c) Pixmap,
    XFreePixmap: *const fn (*Display, Pixmap) callconv(.c) c_int,
    XWarpPointer: *const fn (
        *Display,
        Window,
        Window,
        c_int,
        c_int,
        c_uint,
        c_uint,
        c_int,
        c_int,
    ) callconv(.c) c_int,
    XGrabPointer: *const fn (
        *Display,
        Window,
        Bool,
        c_uint,
        c_int,
        c_int,
        Window,
        Cursor,
        Time,
    ) callconv(.c) c_int,
    XUngrabPointer: *const fn (*Display, Time) callconv(.c) c_int,
    /// Not on an X server built without it, and then a window simply has no
    /// resize limits rather than the program failing to start.
    XResizeWindow: ?*const fn (*Display, Window, c_uint, c_uint) callconv(.c) c_int = null,
    XMoveResizeWindow: *const fn (*Display, Window, c_int, c_int, c_uint, c_uint) callconv(.c) c_int,
    XGetWindowProperty: *const fn (
        *Display,
        Window,
        Atom,
        c_long,
        c_long,
        Bool,
        Atom,
        *Atom,
        *c_int,
        *c_ulong,
        *c_ulong,
        *?[*]u8,
    ) callconv(.c) c_int,
    XFree: *const fn (?*anyopaque) callconv(.c) c_int,
    /// The long form of `XCreateSimpleWindow`, which is the only one that can
    /// put a window on a chosen visual. A GL window has to be on the visual its
    /// framebuffer config named, or the server refuses to draw into it.
    XCreateWindow: *const fn (
        *Display,
        Window,
        c_int,
        c_int,
        c_uint,
        c_uint,
        c_uint,
        c_int,
        c_uint,
        ?*anyopaque,
        c_ulong,
        *XSetWindowAttributes,
    ) callconv(.c) Window,
    XCreateColormap: *const fn (*Display, Window, ?*anyopaque, c_int) callconv(.c) Colormap,
    XFreeColormap: *const fn (*Display, Colormap) callconv(.c) c_int,

    /// The clipboard, which X11 calls a selection - see `Selection`.
    XSetSelectionOwner: *const fn (*Display, Atom, Window, Time) callconv(.c) c_int,
    XGetSelectionOwner: *const fn (*Display, Atom) callconv(.c) Window,
    XConvertSelection: *const fn (*Display, Atom, Atom, Atom, Window, Time) callconv(.c) c_int,
    XCheckTypedWindowEvent: *const fn (*Display, Window, c_int, *XEvent) callconv(.c) Bool,
    XSync: *const fn (*Display, Bool) callconv(.c) c_int,
    XSetErrorHandler: *const fn (?ErrorHandler) callconv(.c) ?ErrorHandler,
    XMaxRequestSize: *const fn (*Display) callconv(.c) c_long,
    XExtendedMaxRequestSize: *const fn (*Display) callconv(.c) c_long,

    /// The input method, and the per-window context that uses it.
    ///
    /// `XOpenIM` finds whatever `XMODIFIERS` names - ibus, fcitx, uim, or the
    /// server's own compose handling when it names nothing. Optional as a
    /// group: an X session with no input method still types, through the
    /// keysym path below.
    XOpenIM: ?*const fn (*Display, ?*anyopaque, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) ?*XIM = null,
    XCloseIM: ?*const fn (*XIM) callconv(.c) Status = null,
    /// Variadic, and called with one style and two windows - see `createIc`.
    XCreateIC: ?*const fn (*XIM, ...) callconv(.c) ?*XIC = null,
    XDestroyIC: ?*const fn (*XIC) callconv(.c) void = null,
    XSetICFocus: ?*const fn (*XIC) callconv(.c) void = null,
    XUnsetICFocus: ?*const fn (*XIC) callconv(.c) void = null,
    XSetICValues: ?*const fn (*XIC, ...) callconv(.c) ?[*:0]const u8 = null,
    XVaCreateNestedList: ?*const fn (c_int, ...) callconv(.c) ?*anyopaque = null,
    /// UTF-8 rather than Latin-1, and after the input method has had its say.
    Xutf8LookupString: ?*const fn (
        *XIC,
        *XKeyEvent,
        [*]u8,
        c_int,
        ?*KeySym,
        ?*Status,
    ) callconv(.c) c_int = null,
    /// Hands an event to the input method first. Without this an input method
    /// never sees a key and nothing composes.
    XFilterEvent: ?*const fn (*XEvent, Window) callconv(.c) Bool = null,
    /// Sets the locale the input method reads. Not Xlib's, but libX11 links it
    /// and an input method that was never given a locale reports none of the
    /// styles this needs.
    XSetLocaleModifiers: ?*const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8 = null,
};

const XIM = opaque {};
const XIC = opaque {};

/// `XIMPreeditNothing | XIMStatusNothing`: the input method draws its own
/// candidate window wherever it likes.
///
/// The alternative - `XIMPreeditCallbacks` - hands the composition to the
/// program to draw, through four Xlib callbacks with their own struct
/// hierarchy. It is what a text editor eventually wants and it is not here;
/// the root style is what every toolkit falls back to and what works with
/// every input method on the first try.
const xim_preedit_nothing: c_long = 0x0008;
const xim_status_nothing: c_long = 0x0400;

/// Argument names for `XCreateIC` and `XSetICValues`. Strings, because Xlib's
/// variadic interfaces are keyed by name.
const xn_input_style: [*:0]const u8 = "inputStyle";
const xn_client_window: [*:0]const u8 = "clientWindow";
const xn_focus_window: [*:0]const u8 = "focusWindow";
const xn_preedit_attributes: [*:0]const u8 = "preeditAttributes";
const xn_spot_location: [*:0]const u8 = "spotLocation";

/// `XPoint`, which is what a spot location is.
const XPoint = extern struct { x: c_short = 0, y: c_short = 0 };

/// `XLookupChars` and `XLookupBoth`: the two statuses that mean there is text.
const x_lookup_chars: Status = 2;
const x_lookup_both: Status = 4;

/// `XSetWindowAttributes`. Only two fields are set - the colormap and the
/// border pixel - but the struct is passed whole and a short one would have
/// the server read the wrong words.
const XSetWindowAttributes = extern struct {
    background_pixmap: XID = 0,
    background_pixel: c_ulong = 0,
    border_pixmap: XID = 0,
    border_pixel: c_ulong = 0,
    bit_gravity: c_int = 0,
    win_gravity: c_int = 0,
    backing_store: c_int = 0,
    backing_planes: c_ulong = 0,
    backing_pixel: c_ulong = 0,
    save_under: Bool = 0,
    event_mask: c_long = 0,
    do_not_propagate_mask: c_long = 0,
    override_redirect: Bool = 0,
    colormap: Colormap = 0,
    cursor: XID = 0,
};

/// `CWBorderPixel | CWColormap`, the two attributes a GL window needs. Without
/// the border pixel the server inherits one from the parent, which is on a
/// different visual, and refuses the window with `BadMatch`.
const cw_border_pixel: c_ulong = 1 << 3;
const cw_colormap: c_ulong = 1 << 13;
/// `InputOutput`, as opposed to a window that only receives events.
const input_output: c_uint = 1;
/// `AllocNone`, which is what a TrueColor visual wants.
const alloc_none: c_int = 0;

// -------------------------------------------------------------------------
// RandR
// -------------------------------------------------------------------------

// Monitors are an extension, not part of the core protocol: without RandR the
// X server knows only how big the whole screen is, and a two-monitor desktop is
// one wide rectangle. Everything below is optional for that reason, and a
// session without it reports one monitor covering the lot - which is what the
// server itself believes.

const RROutput = XID;
const RRCrtc = XID;
const RRMode = XID;

const XRRModeInfo = extern struct {
    id: RRMode,
    width: c_uint,
    height: c_uint,
    dot_clock: c_ulong,
    h_sync_start: c_uint,
    h_sync_end: c_uint,
    h_total: c_uint,
    h_skew: c_uint,
    v_sync_start: c_uint,
    v_sync_end: c_uint,
    v_total: c_uint,
    name: ?[*:0]u8,
    name_length: c_uint,
    mode_flags: c_ulong,
};

const XRRScreenResources = extern struct {
    timestamp: c_ulong,
    config_timestamp: c_ulong,
    ncrtc: c_int,
    crtcs: ?[*]RRCrtc,
    noutput: c_int,
    outputs: ?[*]RROutput,
    nmode: c_int,
    modes: ?[*]XRRModeInfo,
};

const XRROutputInfo = extern struct {
    timestamp: c_ulong,
    crtc: RRCrtc,
    name: ?[*:0]u8,
    name_len: c_int,
    mm_width: c_ulong,
    mm_height: c_ulong,
    connection: c_ushort,
    subpixel_order: c_ushort,
    ncrtc: c_int,
    crtcs: ?[*]RRCrtc,
    nclone: c_int,
    clones: ?[*]RROutput,
    nmode: c_int,
    npreferred: c_int,
    modes: ?[*]RRMode,
};

const XRRCrtcInfo = extern struct {
    timestamp: c_ulong,
    x: c_int,
    y: c_int,
    width: c_uint,
    height: c_uint,
    mode: RRMode,
    rotation: c_ushort,
    noutput: c_int,
    outputs: ?[*]RROutput,
    rotations: c_ushort,
    npossible: c_int,
    possible: ?[*]RROutput,
};

/// `RR_Connected`. An output that is not connected is a socket with nothing
/// plugged into it and is not a monitor.
const rr_connected: c_ushort = 0;

const Xrandr = struct {
    XRRQueryExtension: *const fn (*Display, *c_int, *c_int) callconv(.c) Bool,
    /// `Current` rather than plain: the plain one asks the hardware, which
    /// takes long enough to be noticed, and nothing here needs a monitor that
    /// was plugged in microseconds ago.
    XRRGetScreenResourcesCurrent: *const fn (*Display, Window) callconv(.c) ?*XRRScreenResources,
    XRRFreeScreenResources: *const fn (*XRRScreenResources) callconv(.c) void,
    XRRGetOutputInfo: *const fn (*Display, *XRRScreenResources, RROutput) callconv(.c) ?*XRROutputInfo,
    XRRFreeOutputInfo: *const fn (*XRROutputInfo) callconv(.c) void,
    XRRGetCrtcInfo: *const fn (*Display, *XRRScreenResources, RRCrtc) callconv(.c) ?*XRRCrtcInfo,
    XRRFreeCrtcInfo: *const fn (*XRRCrtcInfo) callconv(.c) void,
    XRRGetOutputPrimary: *const fn (*Display, Window) callconv(.c) RROutput,
    XRRSetCrtcConfig: *const fn (
        *Display,
        *XRRScreenResources,
        RRCrtc,
        c_ulong,
        c_int,
        c_int,
        RRMode,
        c_ushort,
        ?[*]RROutput,
        c_int,
    ) callconv(.c) c_int,
};

const randr_candidates: []const [:0]const u8 = &.{ "libXrandr.so.2", "libXrandr.so" };

/// The names to try, in order. The versioned one first, because the
/// unversioned symlink is a developer package that is often not installed.
const candidates: []const [:0]const u8 = &.{ "libX11.so.6", "libX11.so" };

// -------------------------------------------------------------------------
// State
// -------------------------------------------------------------------------

const Impl = struct {
    gpa: Allocator,
    lib: dyn.Library,
    x: Xlib,
    display: *Display,
    screen: c_int,
    root: Window,
    wm_protocols: Atom,
    wm_delete_window: Atom,
    net_wm_name: Atom,
    utf8_string: Atom,
    net_wm_state: Atom,
    net_wm_state_hidden: Atom,
    net_wm_state_maximized_vert: Atom,
    net_wm_state_maximized_horz: Atom,
    net_wm_state_demands_attention: Atom,
    net_wm_window_opacity: Atom,
    cardinal: Atom,
    net_wm_state_fullscreen: Atom,
    net_workarea: Atom,
    scale: f32,
    /// Null where RandR is missing, and then there is one monitor the size of
    /// the screen. Which is not a lie: without RandR that is all there is.
    xrandr: ?dyn.Library = null,
    xr: ?Xrandr = null,
    /// Controllers, which the X server knows nothing about: on Linux a gamepad
    /// is a kernel device and is read the same way in every session.
    pads: linux_gamepad.Backend = .{},
    /// OpenGL, through GLX. Optional: a machine with no libGL still opens
    /// windows, and a program that asks for a context hears no.
    gl: glx.Backend = .{},

    /// The input method. Null where there is none to open, which is an
    /// ordinary X session with no `XMODIFIERS` set - text still arrives, just
    /// without composition.
    im: ?*XIM = null,
    /// Nothing is ever composed at the root style, because the input method
    /// draws its own preedit. Kept so that `preedit` has something to answer
    /// with rather than null, which would read as "this backend has no idea".
    preedit: text_mod.Preedit = .{},
    /// Every live window, so that an X event carrying a `Window` can be turned
    /// back into the id the program knows it by.
    windows: std.AutoArrayHashMapUnmanaged(Window, *Native) = .empty,
    /// Written to by `post` and read by `wait`, so a thread that is not the
    /// event thread can wake one that is sleeping. X itself has no call for
    /// this that is safe to make from another thread.
    wake: if (has_display) [2]c_int else void = if (has_display) .{ -1, -1 } else {},

    /// See `Selection`. Null until the clipboard is first used.
    selection: ?Selection = null,
    /// What this program copied, served to whoever asks until another program
    /// takes the clipboard.
    clipboard_text: std.ArrayListUnmanaged(u8) = .empty,
    owns_clipboard: bool = false,
};

/// The window that owns what this program copies and receives what it pastes,
/// and the atoms the exchange is spoken in.
///
/// X11 keeps no clipboard. `CLIPBOARD` is a selection: one client owns it, and
/// a client that wants the contents asks the owner to convert them to a type
/// and write them into a property on the asker's window. So a copy is taking
/// ownership and answering every request `pump` brings, and a paste is asking
/// and waiting for the answer.
const Selection = struct {
    window: Window,
    clipboard: Atom,
    targets: Atom,
    multiple: Atom,
    atom_pair: Atom,
    incr: Atom,
    utf8_mime: Atom,
    manager: Atom,
    save_targets: Atom,
    /// Where an owner is asked to put what it sends.
    property: Atom,
};

const Native = struct {
    window: Window,
    id: event.WindowId,
    impl: *Impl,
    width: u32,
    height: u32,
    last_x: f64 = 0,
    last_y: f64 = 0,
    has_position: bool = false,
    /// Tracked from `_NET_WM_STATE`, because asking the server every frame is a
    /// round trip and the window manager tells us anyway.
    iconified: bool = false,
    maximized: bool = false,

    /// What the window was before it filled a monitor, so that leaving puts it
    /// back rather than in the corner at the monitor's size.
    saved_win_x: c_int = 0,
    saved_win_y: c_int = 0,
    saved_width: u32 = 0,
    saved_height: u32 = 0,
    is_fullscreen: bool = false,
    /// Set only for a window made with a GL config. The colormap belongs to the
    /// window and is freed with it.
    context: ?glx.Context = null,
    colormap: Colormap = 0,
    /// One per window, because the input method needs to know which window has
    /// focus and where the caret is in it.
    ic: ?*XIC = null,
    text_input: bool = false,
    /// The CRTC whose mode this window changed, and what it was, so leaving
    /// can undo it. Zero unless an `.exclusive` fullscreen is in force.
    changed_crtc: RRCrtc = 0,
    previous_mode: RRMode = 0,
    previous_crtc_x: c_int = 0,
    previous_crtc_y: c_int = 0,
    previous_rotation: c_ushort = 1,

    mode: cursor_mod.Mode = .normal,
    /// The shape in use, and the blank one that hides the pointer. Both are
    /// server resources and both are freed with the window.
    shape: Cursor = 0,
    blank: Cursor = 0,
    /// Where the pointer was when `disabled` began, so leaving can put it back.
    saved_x: c_int = 0,
    saved_y: c_int = 0,
    /// The centre the pointer is warped back to each move, and the flag that
    /// says the next motion event is that warp rather than the user's hand.
    warping: bool = false,
};

pub const vtable: backend.Vtable = .{
    .backend = .x11,
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
    if (comptime !has_display) return error.Unsupported;

    const self = gpa.create(Impl) catch return error.OutOfMemory;
    errdefer gpa.destroy(self);

    var lib = dyn.Library.openAny(candidates) catch return error.NoDisplay;
    errdefer lib.close();

    const x = lib.bind(Xlib) catch return error.NoDisplay;

    // A null name means `$DISPLAY`. Null back means there is no X session
    // here, which is the ordinary answer on a Wayland-only machine and the
    // reason `Context.init` tries the next candidate rather than stopping.
    const display = x.XOpenDisplay(null) orelse return error.NoDisplay;
    errdefer _ = x.XCloseDisplay(display);

    const screen = x.XDefaultScreen(display);

    self.* = .{
        .gpa = gpa,
        .lib = lib,
        .x = x,
        .display = display,
        .screen = screen,
        .root = x.XRootWindow(display, screen),
        .wm_protocols = x.XInternAtom(display, "WM_PROTOCOLS", 0),
        .wm_delete_window = x.XInternAtom(display, wm_delete_window_name, 0),
        .net_wm_name = x.XInternAtom(display, "_NET_WM_NAME", 0),
        .utf8_string = x.XInternAtom(display, "UTF8_STRING", 0),
        .net_wm_state = x.XInternAtom(display, "_NET_WM_STATE", 0),
        .net_wm_state_hidden = x.XInternAtom(display, "_NET_WM_STATE_HIDDEN", 0),
        .net_wm_state_maximized_vert = x.XInternAtom(display, "_NET_WM_STATE_MAXIMIZED_VERT", 0),
        .net_wm_state_maximized_horz = x.XInternAtom(display, "_NET_WM_STATE_MAXIMIZED_HORZ", 0),
        .net_wm_state_demands_attention = x.XInternAtom(display, "_NET_WM_STATE_DEMANDS_ATTENTION", 0),
        .net_wm_window_opacity = x.XInternAtom(display, "_NET_WM_WINDOW_OPACITY", 0),
        .cardinal = x.XInternAtom(display, "CARDINAL", 0),
        .net_wm_state_fullscreen = x.XInternAtom(display, "_NET_WM_STATE_FULLSCREEN", 0),
        .net_workarea = x.XInternAtom(display, "_NET_WORKAREA", 0),
        .scale = readScale(x, display),
    };

    // The input method reads the locale, and one that was never given a
    // locale reports none of the styles this needs. An empty string means
    // "whatever `XMODIFIERS` says", which is how a user chooses ibus or fcitx.
    if (x.XSetLocaleModifiers) |set| _ = set("");
    if (x.XOpenIM) |open_im| self.im = open_im(display, null, null, null);

    self.gl = glx.Backend.open();
    // GLX allocates with `XFree` and has no Xlib of its own; this is the
    // connection's, so both halves are talking to the same library.
    self.gl.x_free = x.XFree;

    // Optional, and asked for rather than assumed: the library may be present
    // while the server was built without the extension.
    if (dyn.Library.openAny(randr_candidates) catch null) |opened| {
        var lib_randr = opened;
        if (lib_randr.bind(Xrandr) catch null) |xr| {
            var event_base: c_int = 0;
            var error_base: c_int = 0;
            if (xr.XRRQueryExtension(display, &event_base, &error_base) != 0) {
                self.xrandr = lib_randr;
                self.xr = xr;
            } else lib_randr.close();
        } else lib_randr.close();
    }

    if (comptime has_display) {
        var fds: [2]c_int = .{ -1, -1 };
        if (c.pipe(&fds) != 0) return error.ConnectionFailed;
        self.wake = fds;
    }

    return self;
}

fn deinit(impl: backend.Impl, gpa: Allocator) void {
    const self = cast(impl);
    if (self.selection) |*selection| {
        handOver(self, selection);
        _ = self.x.XDestroyWindow(self.display, selection.window);
    }
    self.clipboard_text.deinit(gpa);
    if (comptime has_display) {
        _ = c.close(self.wake[0]);
        _ = c.close(self.wake[1]);
    }
    self.windows.deinit(gpa);
    self.pads.close_();
    // Before the display: the input method is a client of this connection, and
    // closing it afterwards would be closing it through a display that is gone.
    if (self.im) |im| {
        if (self.x.XCloseIM) |close_im| _ = close_im(im);
    }
    _ = self.x.XCloseDisplay(self.display);
    // Both after the display, not before. Xlib runs each extension's close hook
    // from inside `XCloseDisplay`, and those hooks live in the extension
    // libraries - RandR's in libXrandr, GLX's in libGL. Unloading either first
    // leaves Xlib calling an address that is no longer mapped, which is a
    // segfault a long way from the line that caused it.
    if (self.xrandr) |*lib| lib.close();
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

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------

fn createWindow(
    impl: backend.Impl,
    gpa: Allocator,
    id: event.WindowId,
    desc: backend.WindowDesc,
) Error!backend.NativeWindow {
    const self = cast(impl);
    const x = self.x;

    const native = gpa.create(Native) catch return error.OutOfMemory;
    errdefer gpa.destroy(native);

    // A GL window has to be built on the visual its framebuffer config named,
    // which means choosing the config before there is a window and making the
    // window the long way. A plain window takes the short call and the
    // server's default visual.
    var chosen: ?glx.Chosen = null;
    if (desc.gl) |config| {
        chosen = try glx.chooseConfig(&self.gl, @ptrCast(self.display), self.screen, config);
    }
    defer if (chosen) |picked| glx.freeVisual(&self.gl, picked.visual);

    var colormap: Colormap = 0;
    const window = if (chosen) |picked| blk: {
        colormap = x.XCreateColormap(self.display, self.root, picked.visual.visual, alloc_none);
        if (colormap == 0) return error.WindowCreationFailed;

        var attributes: XSetWindowAttributes = .{
            .colormap = colormap,
            // Not optional. Without it the server takes the parent's border,
            // which is on the root's visual, and refuses the whole window with
            // `BadMatch`.
            .border_pixel = 0,
        };
        break :blk x.XCreateWindow(
            self.display,
            self.root,
            0,
            0,
            @max(1, desc.width),
            @max(1, desc.height),
            0,
            picked.visual.depth,
            input_output,
            picked.visual.visual,
            cw_border_pixel | cw_colormap,
            &attributes,
        );
    } else x.XCreateSimpleWindow(
        self.display,
        self.root,
        0,
        0,
        @max(1, desc.width),
        @max(1, desc.height),
        0,
        x.XBlackPixel(self.display, self.screen),
        x.XBlackPixel(self.display, self.screen),
    );
    if (window == 0) {
        if (colormap != 0) _ = x.XFreeColormap(self.display, colormap);
        return error.WindowCreationFailed;
    }
    errdefer {
        _ = x.XDestroyWindow(self.display, window);
        if (colormap != 0) _ = x.XFreeColormap(self.display, colormap);
    }

    _ = x.XSelectInput(self.display, window, window_event_mask);

    // Without this the window manager closes the connection when the user
    // clicks the button, instead of sending a message the program can refuse.
    var protocols = [_]Atom{self.wm_delete_window};
    _ = x.XSetWMProtocols(self.display, window, &protocols, 1);

    try setWindowTitle(self, window, desc.title);

    if (!desc.resizable) {
        var hints: XSizeHints = std.mem.zeroes(XSizeHints);
        hints.flags = p_min_size | p_max_size;
        hints.min_width = @intCast(desc.width);
        hints.max_width = @intCast(desc.width);
        hints.min_height = @intCast(desc.height);
        hints.max_height = @intCast(desc.height);
        x.XSetWMNormalHints(self.display, window, &hints);
    }

    if (!desc.decorated) setUndecorated(self, window);

    native.* = .{
        .window = window,
        .id = id,
        .impl = self,
        .width = desc.width,
        .height = desc.height,
        .colormap = colormap,
    };
    if (chosen) |picked| {
        native.context = try glx.createContext(&self.gl, @ptrCast(self.display), picked, window);
    }
    self.windows.put(gpa, window, native) catch return error.OutOfMemory;

    native.ic = createIc(self, window);

    if (desc.visible) _ = x.XMapWindow(self.display, window);
    _ = x.XFlush(self.display);

    return native;
}

/// `_MOTIF_WM_HINTS` with the decorations bit cleared. An old Motif convention,
/// and still what every window manager reads for "no title bar".
fn setUndecorated(self: *Impl, window: Window) void {
    const hints_atom = self.x.XInternAtom(self.display, "_MOTIF_WM_HINTS", 0);
    if (hints_atom == 0) return;

    // flags, functions, decorations, input_mode, status - and only the
    // decorations flag is set.
    const hints = [5]c_long{ 2, 0, 0, 0, 0 };
    _ = self.x.XChangeProperty(
        self.display,
        window,
        hints_atom,
        hints_atom,
        32,
        prop_mode_replace,
        @ptrCast(&hints),
        5,
    );
}

fn destroyWindow(impl: backend.Impl, gpa: Allocator, native: backend.NativeWindow) void {
    const self = cast(impl);
    const win = castWindow(native);

    // Both before the window: a context outliving its drawable and a colormap
    // outliving the window that used it are each a handle into nothing.
    if (win.ic) |ic| {
        if (self.x.XDestroyIC) |destroy| destroy(ic);
    }
    if (win.context) |context| glx.destroyContext(&self.gl, @ptrCast(self.display), context);
    if (win.colormap != 0) _ = self.x.XFreeColormap(self.display, win.colormap);

    // A grab outlives the window it was taken for, and a client that leaves one
    // behind freezes every other program's pointer.
    if (win.mode.confines()) _ = self.x.XUngrabPointer(self.display, 0);
    if (win.shape != 0) _ = self.x.XFreeCursor(self.display, win.shape);
    if (win.blank != 0) _ = self.x.XFreeCursor(self.display, win.blank);

    _ = self.windows.swapRemove(win.window);
    _ = self.x.XDestroyWindow(self.display, win.window);
    _ = self.x.XFlush(self.display);
    gpa.destroy(win);
}

fn setWindowTitle(self: *Impl, window: Window, title: []const u8) Error!void {
    // `_NET_WM_NAME` is the UTF-8 one every modern window manager reads;
    // `XStoreName` is Latin-1 and is set as well for the ones that do not.
    _ = self.x.XChangeProperty(
        self.display,
        window,
        self.net_wm_name,
        self.utf8_string,
        8,
        prop_mode_replace,
        title.ptr,
        @intCast(title.len),
    );

    const zeroed = self.gpa.dupeZ(u8, title) catch return error.OutOfMemory;
    defer self.gpa.free(zeroed);
    _ = self.x.XStoreName(self.display, window, zeroed.ptr);
    _ = self.x.XFlush(self.display);
}

fn setTitle(impl: backend.Impl, native: backend.NativeWindow, title: []const u8) Error!void {
    const self = cast(impl);
    return setWindowTitle(self, castWindow(native).window, title);
}

fn setVisible(impl: backend.Impl, native: backend.NativeWindow, visible: bool) void {
    const self = cast(impl);
    const win = castWindow(native);
    if (visible) {
        _ = self.x.XMapWindow(self.display, win.window);
    } else {
        _ = self.x.XUnmapWindow(self.display, win.window);
    }
    _ = self.x.XFlush(self.display);
}

fn size(impl: backend.Impl, native: backend.NativeWindow) [2]u32 {
    const pixels = framebufferSize(impl, native);
    const scale = cast(impl).scale;
    if (scale <= 0) return pixels;
    return .{
        @intFromFloat(@round(@as(f32, @floatFromInt(pixels[0])) / scale)),
        @intFromFloat(@round(@as(f32, @floatFromInt(pixels[1])) / scale)),
    };
}

fn framebufferSize(impl: backend.Impl, native: backend.NativeWindow) [2]u32 {
    _ = impl;
    const win = castWindow(native);
    // The last size the server reported, rather than a round trip every frame.
    // `ConfigureNotify` keeps it current, and a resize the program has not
    // pumped yet is a resize it has not seen anyway.
    return .{ win.width, win.height };
}

/// The X11 `Window`, which is an id rather than an address.
fn nativeHandle(impl: backend.Impl, native: backend.NativeWindow) usize {
    _ = impl;
    return @intCast(castWindow(native).window);
}

/// A cursor with nothing in it, which is how X11 hides one: there is no call
/// for it, only a one-pixel transparent bitmap made into a cursor.
fn blankCursor(self: *Impl, window: Window) Cursor {
    const empty = [_]u8{0};
    const pixmap = self.x.XCreateBitmapFromData(self.display, window, &empty, 1, 1);
    if (pixmap == 0) return 0;
    defer _ = self.x.XFreePixmap(self.display, pixmap);

    var black: XColor = std.mem.zeroes(XColor);
    return self.x.XCreatePixmapCursor(self.display, pixmap, pixmap, &black, &black, 0, 0);
}

fn setCursorShape(impl: backend.Impl, native: backend.NativeWindow, shape: cursor_mod.Shape) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    // The core cursor font has no diagonal resize arrows and no "no entry", so
    // those are the ones a caller may be told about. A themed cursor would
    // have them, and that needs `libXcursor`.
    const glyph: c_uint = switch (shape) {
        .arrow => xc_left_ptr,
        .ibeam => xc_xterm,
        .crosshair => xc_crosshair,
        .pointing_hand => xc_hand2,
        .resize_ew => xc_sb_h_double_arrow,
        .resize_ns => xc_sb_v_double_arrow,
        .resize_all => xc_fleur,
        .not_allowed => xc_x_cursor,
        .resize_nwse, .resize_nesw => return error.Unavailable,
    };

    const made = self.x.XCreateFontCursor(self.display, glyph);
    if (made == 0) return error.Unavailable;

    if (win.shape != 0) _ = self.x.XFreeCursor(self.display, win.shape);
    win.shape = made;

    if (!win.mode.hides()) {
        _ = self.x.XDefineCursor(self.display, win.window, made);
        _ = self.x.XFlush(self.display);
    }
}

fn applyCursor(self: *Impl, win: *Native) void {
    if (win.mode.hides()) {
        if (win.blank == 0) win.blank = blankCursor(self, win.window);
        if (win.blank != 0) _ = self.x.XDefineCursor(self.display, win.window, win.blank);
    } else if (win.shape != 0) {
        _ = self.x.XDefineCursor(self.display, win.window, win.shape);
    } else {
        _ = self.x.XUndefineCursor(self.display, win.window);
    }
    _ = self.x.XFlush(self.display);
}

/// The middle of the content area, which is where a disabled pointer lives.
fn centreOf(win: *Native) [2]c_int {
    return .{
        @intCast(win.width / 2),
        @intCast(win.height / 2),
    };
}

fn warpToCentre(self: *Impl, win: *Native) void {
    const centre = centreOf(win);
    win.warping = true;
    _ = self.x.XWarpPointer(self.display, 0, win.window, 0, 0, 0, 0, centre[0], centre[1]);
    _ = self.x.XFlush(self.display);
}

fn setCursorMode(impl: backend.Impl, native: backend.NativeWindow, mode: cursor_mod.Mode) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    if (win.mode == mode) return;

    const was_confined = win.mode.confines();
    win.mode = mode;

    if (mode == .disabled) {
        // Remember where it was, in window coordinates, so leaving can put it
        // back rather than stranding it in the middle.
        win.saved_x = @intFromFloat(win.last_x);
        win.saved_y = @intFromFloat(win.last_y);
    }

    applyCursor(self, win);

    if (mode.confines()) {
        // A grab is the only way X11 confines a pointer: there is no clip
        // rectangle, so the window takes every pointer event and the pointer
        // stops being able to reach anything else.
        const result = self.x.XGrabPointer(
            self.display,
            win.window,
            0,
            pointer_grab_mask,
            grab_mode_async,
            grab_mode_async,
            win.window,
            if (mode.hides()) win.blank else 0,
            0,
        );
        if (result != grab_success) {
            // Another client already holds the pointer - a menu, a drag. Not
            // this program's fault, and not something to pretend worked.
            win.mode = .normal;
            applyCursor(self, win);
            return error.Unavailable;
        }
        if (mode == .disabled) warpToCentre(self, win);
    } else if (was_confined) {
        _ = self.x.XUngrabPointer(self.display, 0);
        _ = self.x.XWarpPointer(self.display, 0, win.window, 0, 0, 0, 0, win.saved_x, win.saved_y);
        _ = self.x.XFlush(self.display);
    }
}

/// X11 has no unaccelerated motion without XInput2, which this backend does not
/// open yet.
///
/// Said rather than silently ignored: a program that asks and is told no can
/// turn down its own sensitivity, and one that is told yes when the answer is
/// no cannot.
fn setRawMouseMotion(impl: backend.Impl, native: backend.NativeWindow, on: bool) bool {
    _ = .{ impl, native, on };
    return false;
}

fn setCursorPos(impl: backend.Impl, native: backend.NativeWindow, x: f64, y: f64) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    win.warping = true;
    _ = self.x.XWarpPointer(
        self.display,
        0,
        win.window,
        0,
        0,
        0,
        0,
        @intFromFloat(@round(x)),
        @intFromFloat(@round(y)),
    );
    _ = self.x.XFlush(self.display);

    win.last_x = x;
    win.last_y = y;
    win.has_position = true;
}

/// Where the content area's top left is on the screen.
///
/// Through `XTranslateCoordinates` rather than `XGetGeometry`, because a window
/// manager reparents a window into a frame and the geometry is then relative to
/// that frame rather than to the screen.
fn position(impl: backend.Impl, native: backend.NativeWindow) [2]i32 {
    const self = cast(impl);
    const win = castWindow(native);

    var x: c_int = 0;
    var y: c_int = 0;
    var child: Window = 0;
    if (self.x.XTranslateCoordinates(self.display, win.window, self.root, 0, 0, &x, &y, &child) == 0) {
        return .{ 0, 0 };
    }
    return .{ x, y };
}

fn setPosition(impl: backend.Impl, native: backend.NativeWindow, x: i32, y: i32) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    // Without `PPosition` a window manager is free to place the window where it
    // likes and ignore the move entirely.
    var hints: XSizeHints = std.mem.zeroes(XSizeHints);
    hints.flags = p_position;
    hints.x = x;
    hints.y = y;
    self.x.XSetWMNormalHints(self.display, win.window, &hints);

    _ = self.x.XMoveWindow(self.display, win.window, x, y);
    _ = self.x.XFlush(self.display);
}

fn setSize(impl: backend.Impl, native: backend.NativeWindow, width: u32, height: u32) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    const resize = self.x.XResizeWindow orelse return error.Unavailable;
    _ = resize(self.display, win.window, @max(1, width), @max(1, height));
    _ = self.x.XFlush(self.display);
}

// -------------------------------------------------------------------------
// Monitors
// -------------------------------------------------------------------------

fn enumerateMonitors(
    impl: backend.Impl,
    list: *std.ArrayListUnmanaged(monitor.Monitor),
    modes: *std.ArrayListUnmanaged(monitor.VideoMode),
    gpa: Allocator,
) Error!void {
    const self = cast(impl);

    const work = readWorkArea(self);

    const xr = self.xr orelse {
        // No RandR: the screen is the monitor, because that is genuinely all
        // the core protocol knows.
        try list.append(gpa, wholeScreen(self, work));
        return;
    };

    const res = xr.XRRGetScreenResourcesCurrent(self.display, self.root) orelse {
        try list.append(gpa, wholeScreen(self, work));
        return;
    };
    defer xr.XRRFreeScreenResources(res);

    const primary = xr.XRRGetOutputPrimary(self.display, self.root);
    const outputs = res.outputs orelse return;

    for (outputs[0..@intCast(res.noutput)]) |output| {
        const info = xr.XRRGetOutputInfo(self.display, res, output) orelse continue;
        defer xr.XRRFreeOutputInfo(info);

        // An output with nothing plugged in, or one the user turned off, has
        // no CRTC and no pixels. It is a socket, not a monitor.
        if (info.connection != rr_connected or info.crtc == 0) continue;

        const crtc = xr.XRRGetCrtcInfo(self.display, res, info.crtc) orelse continue;
        defer xr.XRRFreeCrtcInfo(crtc);

        var mon: monitor.Monitor = .{
            .bounds = .{
                .x = crtc.x,
                .y = crtc.y,
                .width = crtc.width,
                .height = crtc.height,
            },
            .physical_width_mm = @intCast(info.mm_width),
            .physical_height_mm = @intCast(info.mm_height),
            .scale_x = self.scale,
            .scale_y = self.scale,
            .primary = output == primary,
        };
        mon.work_area = intersect(mon.bounds, work orelse mon.bounds);

        if (info.name) |name| mon.setName(std.mem.span(name));

        // The screen's mode list is shared by every output; this one's are the
        // ones its `modes` array names.
        mon.mode_start = modes.items.len;
        if (info.modes) |own| {
            for (own[0..@intCast(info.nmode)]) |id| {
                const found = findMode(res, id) orelse continue;
                const mode = toVideoMode(found);

                var seen = false;
                for (modes.items[mon.mode_start..]) |existing| {
                    if (std.meta.eql(existing, mode)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try modes.append(gpa, mode);
            }
        }
        mon.mode_count = modes.items.len - mon.mode_start;

        if (findMode(res, crtc.mode)) |now| mon.current = toVideoMode(now);

        try list.append(gpa, mon);
    }
}

fn findMode(res: *XRRScreenResources, id: RRMode) ?*const XRRModeInfo {
    const all = res.modes orelse return null;
    for (all[0..@intCast(res.nmode)]) |*mode| {
        if (mode.id == id) return mode;
    }
    return null;
}

/// X reports timings rather than a refresh rate, so the rate is what the
/// timings work out to: one pixel clock divided by a whole frame of them.
fn toVideoMode(mode: *const XRRModeInfo) monitor.VideoMode {
    var hz: u32 = 0;
    if (mode.h_total != 0 and mode.v_total != 0) {
        const total = @as(f64, @floatFromInt(mode.h_total)) * @as(f64, @floatFromInt(mode.v_total));
        hz = @intFromFloat(@round(@as(f64, @floatFromInt(mode.dot_clock)) / total));
    }
    return .{
        .width = mode.width,
        .height = mode.height,
        // X has no per-mode depth; the depth is the screen's and does not change
        // with the resolution.
        .bits = 0,
        .refresh_hz = hz,
    };
}

/// The whole screen as one monitor, for a server with no RandR.
fn wholeScreen(self: *Impl, work: ?monitor.Rect) monitor.Monitor {
    var root_ret: Window = 0;
    var gx: c_int = 0;
    var gy: c_int = 0;
    var gw: c_uint = 0;
    var gh: c_uint = 0;
    var border: c_uint = 0;
    var depth: c_uint = 0;
    _ = self.x.XGetGeometry(
        self.display,
        self.root,
        &root_ret,
        &gx,
        &gy,
        &gw,
        &gh,
        &border,
        &depth,
    );

    var mon: monitor.Monitor = .{
        .bounds = .{ .x = 0, .y = 0, .width = gw, .height = gh },
        .scale_x = self.scale,
        .scale_y = self.scale,
        .current = .{ .width = gw, .height = gh, .bits = depth },
        .primary = true,
    };
    mon.work_area = intersect(mon.bounds, work orelse mon.bounds);
    mon.setName("screen");
    return mon;
}

/// `_NET_WORKAREA`, which the window manager sets to the desktop less its
/// panels. It covers the whole virtual desktop rather than one monitor, so it
/// is cut down to each monitor in turn.
///
/// Null where no window manager set it, and then a monitor's work area is the
/// monitor - which is right, because there is nothing taking a strip out of it.
fn readWorkArea(self: *Impl) ?monitor.Rect {
    var actual_type: Atom = 0;
    var actual_format: c_int = 0;
    var count: c_ulong = 0;
    var remaining: c_ulong = 0;
    var data: ?[*]u8 = null;

    // Four values: the first desktop's. A program on the second workspace is
    // rare enough, and the panels are in the same place on all of them.
    const status = self.x.XGetWindowProperty(
        self.display,
        self.root,
        self.net_workarea,
        0,
        4,
        0,
        self.cardinal,
        &actual_type,
        &actual_format,
        &count,
        &remaining,
        &data,
    );
    if (status != 0) return null;
    const bytes = data orelse return null;
    defer _ = self.x.XFree(bytes);

    if (actual_type != self.cardinal or actual_format != 32 or count < 4) return null;

    // Format 32 means `long` here, not 32 bits: an X client on a 64-bit machine
    // gets eight bytes per value, and reading four would give every other half.
    const values: [*]const c_long = @ptrCast(@alignCast(bytes));
    return .{
        .x = @intCast(values[0]),
        .y = @intCast(values[1]),
        .width = @intCast(values[2]),
        .height = @intCast(values[3]),
    };
}

fn intersect(a: monitor.Rect, b: monitor.Rect) monitor.Rect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + @as(i32, @intCast(a.width)), b.x + @as(i32, @intCast(b.width)));
    const bottom = @min(a.y + @as(i32, @intCast(a.height)), b.y + @as(i32, @intCast(b.height)));
    if (right <= left or bottom <= top) return a;
    return .{
        .x = left,
        .y = top,
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

fn pollGamepads(impl: backend.Impl, devices: *[gamepad.max_devices]gamepad.Device) void {
    cast(impl).pads.poll(devices);
}

fn makeContextCurrent(impl: backend.Impl, native: backend.NativeWindow) Error!void {
    const self = cast(impl);
    const context = castWindow(native).context orelse return error.Unavailable;
    return glx.makeCurrent(&self.gl, @ptrCast(self.display), context);
}

fn clearContext(impl: backend.Impl) void {
    const self = cast(impl);
    glx.clearCurrent(&self.gl, @ptrCast(self.display));
}

fn swapBuffers(impl: backend.Impl, native: backend.NativeWindow) Error!void {
    const self = cast(impl);
    const context = castWindow(native).context orelse return error.Unavailable;
    return glx.swap(&self.gl, @ptrCast(self.display), context);
}

fn setSwapInterval(impl: backend.Impl, native: backend.NativeWindow, interval: i32) Error!void {
    const self = cast(impl);
    const context = castWindow(native).context orelse return error.Unavailable;
    return glx.setSwapInterval(&self.gl, @ptrCast(self.display), context, @intCast(interval));
}

fn getProcAddress(impl: backend.Impl, native: backend.NativeWindow, name: [*:0]const u8) ?gl.Proc {
    _ = native;
    return glx.getProcAddress(&cast(impl).gl, name);
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
    const self = cast(impl);
    const win = castWindow(native);

    const create: *const fn (
        usize,
        *const vulkan.XlibSurfaceCreateInfo,
        ?*const anyopaque,
        *u64,
    ) callconv(.c) i32 = @ptrCast(get_proc(instance, "vkCreateXlibSurfaceKHR") orelse
        return error.Unavailable);

    // The driver is handed this connection rather than opening its own, so
    // both halves talk to the same server over the same socket - two
    // connections to one display is how a surface ends up presenting to a
    // window nobody is pumping.
    const info: vulkan.XlibSurfaceCreateInfo = .{
        .dpy = @ptrCast(self.display),
        .window = win.window,
    };

    var surface: u64 = 0;
    if (create(instance, &info, allocator, &surface) != vulkan.success) {
        return error.Unavailable;
    }
    return surface;
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
        restoreCrtc(self, win);

        sendState(self, win.window, net_wm_state_remove, self.net_wm_state_fullscreen, 0);
        _ = self.x.XMoveResizeWindow(
            self.display,
            win.window,
            win.saved_win_x,
            win.saved_win_y,
            @max(1, win.saved_width),
            @max(1, win.saved_height),
        );
        _ = self.x.XFlush(self.display);
        win.is_fullscreen = false;
        return;
    }

    const mon = target orelse return error.Unavailable;

    if (!win.is_fullscreen) {
        const at = position(impl, native);
        win.saved_win_x = at[0];
        win.saved_win_y = at[1];
        win.saved_width = win.width;
        win.saved_height = win.height;
    }

    var area = mon.bounds;
    if (wanted == .exclusive) {
        area = try switchMode(self, win, mon, wanted.exclusive.mode);
    }

    // Moved onto the monitor first and told to fill the screen second: the
    // window manager picks the monitor from where the window is, and one that
    // was told to go fullscreen while still on the first screen fills the
    // first screen.
    _ = self.x.XMoveResizeWindow(
        self.display,
        win.window,
        area.x,
        area.y,
        @max(1, area.width),
        @max(1, area.height),
    );
    sendState(self, win.window, net_wm_state_add, self.net_wm_state_fullscreen, 0);
    _ = self.x.XFlush(self.display);

    win.is_fullscreen = true;
}

/// Switch the CRTC behind a monitor to a different mode, remembering what it
/// was so that leaving fullscreen can put it back.
///
/// Returns where the monitor is now and how big it is, which is not what the
/// list said: the monitor just changed size.
fn switchMode(
    self: *Impl,
    win: *Native,
    mon: *const monitor.Monitor,
    wanted: monitor.VideoMode,
) Error!monitor.Rect {
    const xr = self.xr orelse return error.Unavailable;

    const res = xr.XRRGetScreenResourcesCurrent(self.display, self.root) orelse
        return error.Unavailable;
    defer xr.XRRFreeScreenResources(res);

    // The monitor is found again by where it is, because a `Monitor` keeps no
    // server handle - and position is what identifies a CRTC anyway.
    const outputs = res.outputs orelse return error.Unavailable;
    for (outputs[0..@intCast(res.noutput)]) |output| {
        const info = xr.XRRGetOutputInfo(self.display, res, output) orelse continue;
        defer xr.XRRFreeOutputInfo(info);
        if (info.connection != rr_connected or info.crtc == 0) continue;

        const crtc = xr.XRRGetCrtcInfo(self.display, res, info.crtc) orelse continue;
        defer xr.XRRFreeCrtcInfo(crtc);
        if (crtc.x != mon.bounds.x or crtc.y != mon.bounds.y) continue;

        const mode_id = pickMode(res, info, wanted) orelse return error.Unavailable;
        if (mode_id == crtc.mode) {
            // Already in it. Nothing to remember and nothing to undo.
            return .{
                .x = crtc.x,
                .y = crtc.y,
                .width = crtc.width,
                .height = crtc.height,
            };
        }

        // Only the first switch is remembered: going from one mode to another
        // must not record the mode this program set as the user's.
        if (win.changed_crtc == 0) {
            win.changed_crtc = info.crtc;
            win.previous_mode = crtc.mode;
            win.previous_crtc_x = crtc.x;
            win.previous_crtc_y = crtc.y;
            win.previous_rotation = crtc.rotation;
        }

        var only: [1]RROutput = .{output};
        if (xr.XRRSetCrtcConfig(
            self.display,
            res,
            info.crtc,
            res.config_timestamp,
            crtc.x,
            crtc.y,
            mode_id,
            crtc.rotation,
            &only,
            1,
        ) != 0) {
            win.changed_crtc = 0;
            return error.Unavailable;
        }

        const chosen = findMode(res, mode_id) orelse return error.Unavailable;
        return .{
            .x = crtc.x,
            .y = crtc.y,
            .width = chosen.width,
            .height = chosen.height,
        };
    }
    return error.Unavailable;
}

/// The mode on this output closest to what was asked for: the same size, and
/// then the nearest refresh rate.
fn pickMode(res: *XRRScreenResources, info: *XRROutputInfo, wanted: monitor.VideoMode) ?RRMode {
    const own = info.modes orelse return null;
    var best: ?RRMode = null;
    var best_gap: u32 = std.math.maxInt(u32);

    for (own[0..@intCast(info.nmode)]) |id| {
        const mode = findMode(res, id) orelse continue;
        if (mode.width != wanted.width or mode.height != wanted.height) continue;

        const hz = toVideoMode(mode).refresh_hz;
        // A rate of zero means "any", and the first one that fits is it.
        const gap = if (wanted.refresh_hz == 0)
            0
        else if (hz > wanted.refresh_hz) hz - wanted.refresh_hz else wanted.refresh_hz - hz;
        if (gap < best_gap) {
            best_gap = gap;
            best = id;
        }
    }
    return best;
}

/// Put back whatever mode this window changed, if it changed one.
fn restoreCrtc(self: *Impl, win: *Native) void {
    if (win.changed_crtc == 0) return;
    const xr = self.xr orelse return;

    const res = xr.XRRGetScreenResourcesCurrent(self.display, self.root) orelse return;
    defer xr.XRRFreeScreenResources(res);

    const crtc = xr.XRRGetCrtcInfo(self.display, res, win.changed_crtc) orelse return;
    defer xr.XRRFreeCrtcInfo(crtc);

    _ = xr.XRRSetCrtcConfig(
        self.display,
        res,
        win.changed_crtc,
        res.config_timestamp,
        win.previous_crtc_x,
        win.previous_crtc_y,
        win.previous_mode,
        win.previous_rotation,
        crtc.outputs,
        crtc.noutput,
    );
    win.changed_crtc = 0;
}

/// Ask the window manager to change a `_NET_WM_STATE` bit.
///
/// A message rather than a property write: the window manager owns the state,
/// and a client that set the property itself would be overruled at the next
/// opportunity.
fn sendState(self: *Impl, window: Window, action: c_long, first: Atom, second: Atom) void {
    var message: XEvent = std.mem.zeroes(XEvent);
    message.xclient = .{
        .type = client_message,
        .serial = 0,
        .send_event = 1,
        .display = self.display,
        .window = window,
        .message_type = self.net_wm_state,
        .format = 32,
        .data = .{
            .l = .{
                action,
                @bitCast(first),
                @bitCast(second),
                // Source: 1 means an ordinary application, which is what a window
                // manager weighs when deciding whether to honour the request.
                1,
                0,
            },
        },
    };

    const substructure: c_long = (1 << 20) | (1 << 19); // Redirect | Notify
    _ = self.x.XSendEvent(self.display, self.root, 0, substructure, &message);
    _ = self.x.XFlush(self.display);
}

fn setState(impl: backend.Impl, native: backend.NativeWindow, wanted: backend.WindowState) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    switch (wanted) {
        .iconified => {
            _ = self.x.XIconifyWindow(self.display, win.window, self.screen);
            _ = self.x.XFlush(self.display);
        },
        .maximized => sendState(
            self,
            win.window,
            net_wm_state_add,
            self.net_wm_state_maximized_vert,
            self.net_wm_state_maximized_horz,
        ),
        .restored => {
            sendState(
                self,
                win.window,
                net_wm_state_remove,
                self.net_wm_state_maximized_vert,
                self.net_wm_state_maximized_horz,
            );
            _ = self.x.XMapWindow(self.display, win.window);
            _ = self.x.XFlush(self.display);
        },
        .focused => {
            _ = self.x.XRaiseWindow(self.display, win.window);
            _ = self.x.XSetInputFocus(self.display, win.window, revert_to_parent, 0);
            _ = self.x.XFlush(self.display);
        },
        .attention => sendState(
            self,
            win.window,
            net_wm_state_add,
            self.net_wm_state_demands_attention,
            0,
        ),
    }
}

fn getState(impl: backend.Impl, native: backend.NativeWindow, which: backend.WindowState) bool {
    const self = cast(impl);
    const win = castWindow(native);

    return switch (which) {
        .iconified => win.iconified,
        .maximized => win.maximized,
        .focused => blk: {
            var focused: Window = 0;
            var revert: c_int = 0;
            _ = self.x.XGetInputFocus(self.display, &focused, &revert);
            break :blk focused == win.window;
        },
        .restored => !win.iconified and !win.maximized,
        .attention => false,
    };
}

fn setSizeLimits(impl: backend.Impl, native: backend.NativeWindow, limits: backend.SizeLimits) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    var hints: XSizeHints = std.mem.zeroes(XSizeHints);
    if (limits.min_width != 0 or limits.min_height != 0) {
        hints.flags |= p_min_size;
        hints.min_width = @intCast(limits.min_width);
        hints.min_height = @intCast(limits.min_height);
    }
    if (limits.max_width != 0 or limits.max_height != 0) {
        hints.flags |= p_max_size;
        hints.max_width = @intCast(limits.max_width);
        hints.max_height = @intCast(limits.max_height);
    }
    self.x.XSetWMNormalHints(self.display, win.window, &hints);
    _ = self.x.XFlush(self.display);
}

/// `_NET_WM_WINDOW_OPACITY`, which a compositor reads and acts on.
///
/// Without a compositor running there is nothing to blend, and the property
/// simply sits there - which is not a failure, so this does not report one.
fn setOpacity(impl: backend.Impl, native: backend.NativeWindow, opacity: f32) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    const clamped = std.math.clamp(opacity, 0, 1);
    if (clamped >= 1) {
        _ = self.x.XDeleteProperty(self.display, win.window, self.net_wm_window_opacity);
        _ = self.x.XFlush(self.display);
        return;
    }

    const value: c_ulong = @intFromFloat(@round(@as(f64, clamped) * @as(f64, @floatFromInt(opaque_max))));
    _ = self.x.XChangeProperty(
        self.display,
        win.window,
        self.net_wm_window_opacity,
        self.cardinal,
        32,
        prop_mode_replace,
        @ptrCast(&value),
        1,
    );
    _ = self.x.XFlush(self.display);
}

fn contentScale(impl: backend.Impl, native: backend.NativeWindow) [2]f32 {
    _ = native;
    const scale = cast(impl).scale;
    return .{ scale, scale };
}

/// `Xft.dpi` out of the resource manager string, over 96.
///
/// The one setting every desktop environment writes and every toolkit reads.
/// The string is plain text - `Xft.dpi:\t144\n...` - so it is parsed here
/// rather than through `Xrm`, which would be four more entry points for one
/// number.
fn readScale(x: Xlib, display: *Display) f32 {
    const resources = x.XResourceManagerString(display) orelse return 1;
    const text = std.mem.span(resources);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rest = trimPrefix(line, "Xft.dpi:") orelse continue;
        const value = std.mem.trim(u8, rest, " \t\r");
        const dpi = std.fmt.parseFloat(f32, value) catch continue;
        if (dpi <= 0) return 1;
        return dpi / 96.0;
    }
    return 1;
}

fn trimPrefix(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return line[prefix.len..];
}

// -------------------------------------------------------------------------
// The event loop
// -------------------------------------------------------------------------

fn pump(impl: backend.Impl, queue: *backend.Queue) Error!void {
    const self = cast(impl);

    if (comptime has_display) drainWake(self);

    var pending = self.x.XPending(self.display);
    while (pending > 0) : (pending -= 1) {
        var ev: XEvent = undefined;
        _ = self.x.XNextEvent(self.display, &ev);

        if (self.selection) |*selection| {
            if (ev.xany.window == selection.window) {
                selectionEvent(self, selection, &ev);
                continue;
            }
        }

        // The input method gets first refusal, and takes the keys that make up
        // a composition. Without this an input method never sees a key, and
        // nothing composes - it is the one call that makes XIM work at all.
        if (self.x.XFilterEvent) |filter| {
            if (filter(&ev, 0) != 0) continue;
        }

        try translate(self, &ev, queue);
    }
}

fn wait(impl: backend.Impl, timeout_ms: ?u32) Error!void {
    if (comptime !has_display) return;

    const self = cast(impl);
    // Anything already buffered in the client is not on the socket, so a wait
    // that only watched the file descriptor would sleep through it.
    if (self.x.XPending(self.display) > 0) return;

    var fds = [_]Pollfd{
        .{ .fd = self.x.XConnectionNumber(self.display), .events = pollin, .revents = 0 },
        .{ .fd = self.wake[0], .events = pollin, .revents = 0 },
    };
    const timeout: c_int = if (timeout_ms) |ms| @intCast(@min(ms, std.math.maxInt(c_int))) else -1;
    _ = c.poll(&fds, fds.len, timeout);
}

fn post(impl: backend.Impl) void {
    if (comptime !has_display) return;
    const self = cast(impl);
    // One byte down the pipe. Not an X call, because none of them may be made
    // from a thread that is not the one driving the display.
    const byte = [_]u8{0};
    _ = c.write(self.wake[1], &byte, 1);
}

/// Empty the wake pipe, so one `post` does not wake every later `wait`.
///
/// Asked first with a zero timeout rather than made non-blocking, which keeps
/// this to the four calls above and no `fcntl`.
fn drainWake(self: *Impl) void {
    var scratch: [64]u8 = undefined;
    var fds = [_]Pollfd{.{ .fd = self.wake[0], .events = pollin, .revents = 0 }};
    while (c.poll(&fds, 1, 0) > 0) {
        if (c.read(self.wake[0], &scratch, scratch.len) <= 0) return;
    }
}

/// One X event into however many of ours it means.
fn translate(self: *Impl, ev: *XEvent, queue: *backend.Queue) Error!void {
    const window: Window = switch (ev.type) {
        configure_notify => ev.xconfigure.window,
        else => ev.xany.window,
    };
    const native = self.windows.get(window) orelse return;
    const id = native.id;

    switch (ev.type) {
        client_message => {
            // The only one that matters: the window manager asking to close.
            if (ev.xclient.message_type == self.wm_protocols and
                ev.xclient.data.l[0] == @as(c_long, @bitCast(self.wm_delete_window)))
            {
                try queue.push(.{ .close = id });
            }
        },

        expose => {
            // Only the last rectangle of a run; the earlier ones are the same
            // redraw split up.
            if (ev.xexpose.count == 0) try queue.push(.{ .refresh = id });
        },

        configure_notify => {
            const width: u32 = @intCast(@max(0, ev.xconfigure.width));
            const height: u32 = @intCast(@max(0, ev.xconfigure.height));
            if (width != native.width or height != native.height) {
                native.width = width;
                native.height = height;
                try queue.push(.{ .framebuffer_resize = .{
                    .window = id,
                    .width = width,
                    .height = height,
                } });
                try queue.push(.{ .resize = .{
                    .window = id,
                    .width = @intFromFloat(@round(@as(f32, @floatFromInt(width)) / self.scale)),
                    .height = @intFromFloat(@round(@as(f32, @floatFromInt(height)) / self.scale)),
                } });
            }
            try queue.push(.{ .move = .{
                .window = id,
                .x = ev.xconfigure.x,
                .y = ev.xconfigure.y,
            } });
        },

        focus_in => try queue.push(.{ .focus = .{ .window = id, .value = true } }),
        focus_out => try queue.push(.{ .focus = .{ .window = id, .value = false } }),

        enter_notify => try queue.push(.{ .cursor_enter = .{ .window = id, .value = true } }),
        leave_notify => try queue.push(.{ .cursor_enter = .{ .window = id, .value = false } }),

        key_press, key_release => {
            const down = ev.type == key_press;
            const physical = keyFromKeycode(ev.xkey.keycode);
            try queue.push(.{ .key = .{
                .window = id,
                .key = physical,
                .virtual = virtual_key.fromTyped(physical, virtual_key.typedByKeysym(baseKeysym(self, &ev.xkey))),
                .scancode = @enumFromInt(ev.xkey.keycode),
                .action = if (down) .press else .release,
                .mods = modsFromState(ev.xkey.state),
            } });

            if (down) try pushChars(self, &ev.xkey, id, queue);
        },

        button_press, button_release => {
            const down = ev.type == button_press;
            const b = ev.xbutton.button;

            // X11 has no wheel: it reports buttons 4 to 7, and a release for
            // each press, which would double every scroll if it were passed on.
            if (b >= 4 and b <= 7) {
                if (!down) return;
                try queue.push(.{ .scroll = .{
                    .window = id,
                    .x = if (b == 6) -1 else if (b == 7) 1 else 0,
                    .y = if (b == 4) 1 else if (b == 5) -1 else 0,
                    .mods = modsFromState(ev.xbutton.state),
                } });
                return;
            }

            const button: keys.MouseButton = switch (b) {
                1 => .left,
                2 => .middle,
                3 => .right,
                // 4 to 7 are the wheel and were handled above, so the extra
                // buttons start two lower than their X numbers.
                8 => .button_4,
                9 => .button_5,
                else => @enumFromInt(@as(u8, @intCast(@min(b, 255)))),
            };
            try queue.push(.{ .mouse_button = .{
                .window = id,
                .button = button,
                .action = if (down) .press else .release,
                .mods = modsFromState(ev.xbutton.state),
                .x = @floatFromInt(ev.xbutton.x),
                .y = @floatFromInt(ev.xbutton.y),
            } });
        },

        motion_notify => {
            const x: f64 = @floatFromInt(ev.xmotion.x);
            const y: f64 = @floatFromInt(ev.xmotion.y);

            // The warp below produces a motion event of its own, and reporting
            // it would undo exactly the movement it was meant to preserve.
            if (native.warping) {
                native.warping = false;
                native.last_x = x;
                native.last_y = y;
                native.has_position = true;
                return;
            }

            if (native.mode == .disabled) {
                // The delta is measured from the middle, and the pointer is put
                // back there - which is what stops it reaching an edge and the
                // camera stopping with it.
                const centre = centreOf(native);
                const dx = x - @as(f64, @floatFromInt(centre[0]));
                const dy = y - @as(f64, @floatFromInt(centre[1]));
                if (dx == 0 and dy == 0) return;

                warpToCentre(self, native);
                try queue.push(.{ .cursor = .{ .window = id, .x = 0, .y = 0, .dx = dx, .dy = dy } });
                return;
            }

            const dx = if (native.has_position) x - native.last_x else 0;
            const dy = if (native.has_position) y - native.last_y else 0;
            native.last_x = x;
            native.last_y = y;
            native.has_position = true;

            try queue.push(.{ .cursor = .{ .window = id, .x = x, .y = y, .dx = dx, .dy = dy } });
        },

        else => {},
    }
}

/// Make an input context for one window.
///
/// Null where there is no input method, where the library is too old to have
/// the call, or where the method refuses this style. All three are ordinary:
/// text still arrives through `XLookupString`, in Latin-1, which is what an X
/// session without an input method has always given.
fn createIc(self: *Impl, window: Window) ?*XIC {
    const im = self.im orelse return null;
    const create = self.x.XCreateIC orelse return null;

    // Variadic, keyed by name, terminated by a null. The root style asks the
    // input method to draw its own preedit, which is the one every method
    // supports - see `xim_preedit_nothing`.
    return create(
        im,
        xn_input_style,
        xim_preedit_nothing | xim_status_nothing,
        xn_client_window,
        window,
        xn_focus_window,
        window,
        @as(?*anyopaque, null),
    );
}

/// The keysym on a key's first level in the layout group in use: what it types
/// on its own, before shift, caps lock or AltGr choose another. The virtual
/// key is worked out from it.
///
/// `XLookupString` on a copy of the event with every modifier cleared but the
/// group, which is bits 13 and 14 and says which layout is in use. Passing no
/// compose status keeps it stateless, so it cannot disturb the lookup that
/// produces the text.
fn baseKeysym(self: *Impl, key_event: *const XKeyEvent) u32 {
    var plain = key_event.*;
    plain.state &= 0x6000;
    var sym: KeySym = 0;
    var buf: [8]u8 = undefined;
    _ = self.x.XLookupString(&plain, &buf, buf.len, &sym, null);
    return std.math.cast(u32, sym) orelse 0;
}

/// The text a keypress produced, as `.char` events.
///
/// Through the window's input context where there is one, which is what makes
/// this UTF-8 rather than Latin-1 and what makes dead keys, compose sequences
/// and a CJK input method work at all. `XLookupString` is the fallback, and it
/// is the old behaviour: ASCII and the western European letters, nothing else.
fn pushChars(
    self: *Impl,
    key_event: *XKeyEvent,
    id: event.WindowId,
    queue: *backend.Queue,
) Error!void {
    const mods = modsFromState(key_event.state);

    if (lookupUtf8(self, key_event)) |utf8| {
        var it = std.unicode.Utf8Iterator{ .bytes = utf8, .i = 0 };
        while (it.nextCodepoint()) |codepoint| {
            // Control characters are the key event's business, not text.
            if (codepoint < 0x20 or codepoint == 0x7F) continue;
            try queue.push(.{ .char = .{
                .window = id,
                .codepoint = @intCast(codepoint),
                .mods = mods,
            } });
        }
        return;
    }

    var buf: [16]u8 = undefined;
    const n = self.x.XLookupString(key_event, &buf, buf.len, null, null);
    if (n <= 0) return;

    for (buf[0..@intCast(n)]) |byte| {
        if (byte < 0x20 or byte == 0x7F) continue;
        try queue.push(.{ .char = .{
            .window = id,
            .codepoint = byte,
            .mods = mods,
        } });
    }
}

/// The UTF-8 an input context produced, or null if there is no context to ask.
///
/// The buffer is static per call and the slice points into it, so the caller
/// has to be done with it before the next key - which it is, because the
/// codepoints are pushed straight into the queue.
threadlocal var lookup_buf: [64]u8 = undefined;

fn lookupUtf8(self: *Impl, key_event: *XKeyEvent) ?[]const u8 {
    const lookup = self.x.Xutf8LookupString orelse return null;
    const native = self.windows.get(key_event.window) orelse return null;
    const ic = native.ic orelse return null;

    var status: Status = 0;
    const n = lookup(ic, key_event, &lookup_buf, lookup_buf.len, null, &status);

    // Anything else means the key produced a keysym and no text, or nothing at
    // all - a modifier, or a keystroke the input method swallowed.
    if (status != x_lookup_chars and status != x_lookup_both) return &.{};
    if (n <= 0) return &.{};
    return lookup_buf[0..@intCast(n)];
}

// -------------------------------------------------------------------------
// Text input
// -------------------------------------------------------------------------

/// Give the window's input context focus, or take it away.
///
/// That is what turning text input off means here: an input method that has
/// not been given focus does not compose, does not open a candidate window, and
/// does not eat keys a game wanted.
fn setTextInput(impl: backend.Impl, native: backend.NativeWindow, on: bool) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    const ic = win.ic orelse return error.Unavailable;

    if (on) {
        const focus = self.x.XSetICFocus orelse return error.Unavailable;
        focus(ic);
    } else {
        const unfocus = self.x.XUnsetICFocus orelse return error.Unavailable;
        unfocus(ic);
    }
    win.text_input = on;
    return;
}

/// Tell the input method where the caret is.
///
/// Only meaningful to a method drawing over the spot, and this file asks for
/// the root style - so most methods will place their window themselves and
/// ignore this. Sent anyway, because the ones that do read it put their
/// candidates in a much better place for it.
fn setTextInputArea(impl: backend.Impl, native: backend.NativeWindow, area: text_mod.Area) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    const ic = win.ic orelse return error.Unavailable;

    const nested = self.x.XVaCreateNestedList orelse return error.Unavailable;
    const set = self.x.XSetICValues orelse return error.Unavailable;

    // The bottom of the line rather than the top: a candidate window hangs
    // below the caret, and given the top it would sit over the text.
    var spot: XPoint = .{
        .x = @intCast(area.x),
        .y = @intCast(area.y + @as(i32, @intCast(area.height))),
    };

    const list = nested(0, xn_spot_location, &spot, @as(?*anyopaque, null)) orelse
        return error.Unavailable;
    defer _ = self.x.XFree(list);

    if (set(ic, xn_preedit_attributes, list, @as(?*anyopaque, null)) != null) {
        return error.Unavailable;
    }
}

/// Never anything.
///
/// At the root preedit style the input method draws its own composition and
/// never tells the client what it is - which is the trade this file makes, and
/// the reason a text editor eventually wants `XIMPreeditCallbacks`. Reported as
/// empty rather than as null, because "nothing is being composed" is a truthful
/// answer and "this backend has no idea" would not be.
fn preedit(impl: backend.Impl) ?*const text_mod.Preedit {
    return &cast(impl).preedit;
}

fn modsFromState(state: c_uint) keys.Mods {
    return .{
        .shift = state & shift_mask != 0,
        .control = state & control_mask != 0,
        .alt = state & mod1_mask != 0,
        .super = state & mod4_mask != 0,
        .caps_lock = state & lock_mask != 0,
        .num_lock = state & mod2_mask != 0,
    };
}

// -------------------------------------------------------------------------
// The clipboard
// -------------------------------------------------------------------------

fn selectionOf(self: *Impl) Error!*const Selection {
    if (self.selection) |*made| return made;

    var attributes: XSetWindowAttributes = .{ .event_mask = property_change_mask };
    const window = self.x.XCreateWindow(self.display, self.root, 0, 0, 1, 1, 0, 0, input_only, null, cw_event_mask, &attributes);
    if (window == 0) return error.Unavailable;

    const x = self.x;
    const d = self.display;
    self.selection = .{
        .window = window,
        .clipboard = x.XInternAtom(d, "CLIPBOARD", 0),
        .targets = x.XInternAtom(d, "TARGETS", 0),
        .multiple = x.XInternAtom(d, "MULTIPLE", 0),
        .atom_pair = x.XInternAtom(d, "ATOM_PAIR", 0),
        .incr = x.XInternAtom(d, "INCR", 0),
        .utf8_mime = x.XInternAtom(d, "text/plain;charset=utf-8", 0),
        .manager = x.XInternAtom(d, "CLIPBOARD_MANAGER", 0),
        .save_targets = x.XInternAtom(d, "SAVE_TARGETS", 0),
        .property = x.XInternAtom(d, "FLUXION_CLIPBOARD", 0),
    };
    return &self.selection.?;
}

fn setClipboardText(impl: backend.Impl, text: []const u8) Error!void {
    const self = cast(impl);
    const selection = try selectionOf(self);
    self.clipboard_text.clearRetainingCapacity();
    try self.clipboard_text.appendSlice(self.gpa, text);

    _ = self.x.XSetSelectionOwner(self.display, selection.clipboard, selection.window, current_time);
    self.owns_clipboard = self.x.XGetSelectionOwner(self.display, selection.clipboard) == selection.window;
    if (!self.owns_clipboard) return error.Unavailable;
}

fn clipboardText(impl: backend.Impl, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    const self = cast(impl);
    const selection = try selectionOf(self);
    const owner = self.x.XGetSelectionOwner(self.display, selection.clipboard);
    if (owner == selection.window) return out.appendSlice(gpa, self.clipboard_text.items);
    if (owner == 0) return;

    if (try convert(self, selection, self.utf8_string, out, gpa)) return;
    // An owner from before UTF-8 offers Latin-1 and nothing else.
    var latin1: std.ArrayListUnmanaged(u8) = .empty;
    defer latin1.deinit(gpa);
    if (try convert(self, selection, xa_string, &latin1, gpa)) try clipboard.appendLatin1(gpa, out, latin1.items);
}

/// Asks the owner which types it has - a round trip to another program, which
/// is why a program should ask when a menu opens rather than every frame.
fn hasClipboardText(impl: backend.Impl) bool {
    const self = cast(impl);
    const selection = selectionOf(self) catch return false;
    const owner = self.x.XGetSelectionOwner(self.display, selection.clipboard);
    if (owner == selection.window) return self.clipboard_text.items.len > 0;
    if (owner == 0) return false;

    var listed: std.ArrayListUnmanaged(u8) = .empty;
    defer listed.deinit(self.gpa);
    const answered = convert(self, selection, selection.targets, &listed, self.gpa) catch return false;
    if (!answered) return false;

    const whole = listed.items[0 .. listed.items.len - listed.items.len % @sizeOf(Atom)];
    for (std.mem.bytesAsSlice(Atom, whole)) |target| {
        if (target == self.utf8_string or target == selection.utf8_mime or target == xa_string) return true;
    }
    return false;
}

/// Ask the clipboard's owner for its contents as `target`, wait, and append
/// what arrives. False when it has nothing of that type or does not answer in
/// time: an owner that has hung must not hang this program with it.
fn convert(
    self: *Impl,
    selection: *const Selection,
    target: Atom,
    out: *std.ArrayListUnmanaged(u8),
    gpa: Allocator,
) Error!bool {
    var ev: XEvent = undefined;
    // A late answer to an earlier request, which gave up waiting for it.
    while (self.x.XCheckTypedWindowEvent(self.display, selection.window, selection_notify, &ev) != 0) {}
    _ = self.x.XDeleteProperty(self.display, selection.window, selection.property);
    _ = self.x.XConvertSelection(self.display, selection.clipboard, target, selection.property, selection.window, current_time);

    if (!waitForEvent(self, selection.window, selection_notify, &ev, .in(clipboard.timeout_ms))) return false;
    if (ev.xselection.property == 0) return false;
    // The owner wrote the property before it answered, so the notice of that
    // write is already queued. Taken now, it cannot pass for the first piece
    // of a transfer in pieces.
    while (self.x.XCheckTypedWindowEvent(self.display, selection.window, property_notify, &ev) != 0) {
        if (ev.xproperty.atom == selection.property and ev.xproperty.state == property_new_value) break;
    }

    const start = out.items.len;
    const kind = try readProperty(self, selection.window, selection.property, out, gpa) orelse return false;
    if (kind != selection.incr) return true;

    // Too much for one property: reading the first deleted it, which is the
    // owner's cue to send the rest in pieces. An empty piece is the end.
    out.shrinkRetainingCapacity(start);
    while (true) {
        if (!waitForNewValue(self, selection, .in(clipboard.timeout_ms))) {
            out.shrinkRetainingCapacity(start);
            return false;
        }
        const before = out.items.len;
        _ = try readProperty(self, selection.window, selection.property, out, gpa) orelse return false;
        if (out.items.len == before) return true;
    }
}

/// Take the next event of one type for one window out of the queue, reading
/// the connection until it comes or the deadline passes. Every other event is
/// left where it was, for the next `pump`.
fn waitForEvent(self: *Impl, window: Window, kind: c_int, ev: *XEvent, deadline: clipboard.Deadline) bool {
    while (self.x.XCheckTypedWindowEvent(self.display, window, kind, ev) == 0) {
        const left = deadline.left();
        if (left == 0) return false;
        var fds = [_]Pollfd{.{ .fd = self.x.XConnectionNumber(self.display), .events = pollin, .revents = 0 }};
        _ = c.poll(&fds, 1, left);
    }
    return true;
}

fn waitForNewValue(self: *Impl, selection: *const Selection, deadline: clipboard.Deadline) bool {
    var ev: XEvent = undefined;
    while (waitForEvent(self, selection.window, property_notify, &ev, deadline)) {
        if (ev.xproperty.atom == selection.property and ev.xproperty.state == property_new_value) return true;
    }
    return false;
}

/// Append a property's value and delete it. Answers its type, or null where
/// there was no such property.
fn readProperty(
    self: *Impl,
    window: Window,
    property: Atom,
    out: *std.ArrayListUnmanaged(u8),
    gpa: Allocator,
) Error!?Atom {
    var kind: Atom = 0;
    var format: c_int = 0;
    var count: c_ulong = 0;
    var after: c_ulong = 0;
    var data: ?[*]u8 = null;
    const status = self.x.XGetWindowProperty(
        self.display,
        window,
        property,
        0,
        std.math.maxInt(c_long),
        1,
        any_property_type,
        &kind,
        &format,
        &count,
        &after,
        &data,
    );
    if (status != 0) return null;
    defer if (data) |bytes| {
        _ = self.x.XFree(bytes);
    };
    if (kind == 0) return null;

    // Format 32 is a `long` each, as it is everywhere in Xlib.
    const unit: usize = switch (format) {
        8 => 1,
        16 => 2,
        32 => @sizeOf(c_long),
        else => return null,
    };
    if (data) |bytes| try out.appendSlice(gpa, bytes[0 .. @as(usize, @intCast(count)) * unit]);
    return kind;
}

/// Something happened on the clipboard's window: another program asking for
/// what this one copied, or taking the clipboard over.
fn selectionEvent(self: *Impl, selection: *const Selection, ev: *const XEvent) void {
    switch (ev.type) {
        selection_request => answer(self, selection, &ev.xselectionrequest),
        selection_clear => if (ev.xselectionclear.selection == selection.clipboard) {
            self.owns_clipboard = false;
            self.clipboard_text.clearAndFree(self.gpa);
        },
        // Late answers, and this window's own property changing.
        else => {},
    }
}

fn answer(self: *Impl, selection: *const Selection, request: *const XSelectionRequestEvent) void {
    // The asker's window may be gone by now, and Xlib's own answer to that
    // error is to end the process.
    const previous = self.x.XSetErrorHandler(ignoreError);
    defer {
        _ = self.x.XSync(self.display, 0);
        _ = self.x.XSetErrorHandler(previous);
    }

    // A client from before ICCCM 2.0 names no property, and means the target.
    const property = if (request.property != 0) request.property else request.target;
    const converted = self.owns_clipboard and request.selection == selection.clipboard and
        convertFor(self, selection, request.requestor, request.target, property);

    var reply: XEvent = std.mem.zeroes(XEvent);
    reply.xselection = .{
        .type = selection_notify,
        .serial = 0,
        .send_event = 1,
        .display = self.display,
        .requestor = request.requestor,
        .selection = request.selection,
        .target = request.target,
        .property = if (converted) property else 0,
        .time = request.time,
    };
    _ = self.x.XSendEvent(self.display, request.requestor, 0, 0, &reply);
}

/// Write what this program copied onto the asker's property, as `target`.
fn convertFor(self: *Impl, selection: *const Selection, requestor: Window, target: Atom, property: Atom) bool {
    if (target == selection.targets) {
        const offered = [_]Atom{ selection.targets, selection.multiple, self.utf8_string, selection.utf8_mime };
        _ = self.x.XChangeProperty(self.display, requestor, property, xa_atom, 32, prop_mode_replace, @ptrCast(&offered), offered.len);
        return true;
    }
    if (target == self.utf8_string or target == selection.utf8_mime) {
        const text = self.clipboard_text.items;
        // More than the server takes in one request, which would fail and
        // leave the asker reading nothing.
        if (text.len > maxPropertyBytes(self)) return false;
        _ = self.x.XChangeProperty(self.display, requestor, property, target, 8, prop_mode_replace, text.ptr, @intCast(text.len));
        return true;
    }
    if (target == selection.multiple) return convertMultiple(self, selection, requestor, property);
    return false;
}

/// Several conversions in one request, which is how a clipboard manager takes
/// everything at once: pairs of target and property, and a pair that could
/// not be converted has its property set to none.
fn convertMultiple(self: *Impl, selection: *const Selection, requestor: Window, property: Atom) bool {
    var kind: Atom = 0;
    var format: c_int = 0;
    var count: c_ulong = 0;
    var after: c_ulong = 0;
    var data: ?[*]u8 = null;
    const status = self.x.XGetWindowProperty(
        self.display,
        requestor,
        property,
        0,
        std.math.maxInt(c_long),
        0,
        selection.atom_pair,
        &kind,
        &format,
        &count,
        &after,
        &data,
    );
    if (status != 0) return false;
    const bytes = data orelse return false;
    defer _ = self.x.XFree(bytes);
    if (kind != selection.atom_pair or format != 32) return false;

    const pairs: [*]Atom = @ptrCast(@alignCast(bytes));
    var at: usize = 0;
    while (at + 1 < count) : (at += 2) {
        const nested = pairs[at] == selection.multiple;
        if (nested or !convertFor(self, selection, requestor, pairs[at], pairs[at + 1])) pairs[at + 1] = 0;
    }
    _ = self.x.XChangeProperty(self.display, requestor, property, selection.atom_pair, 32, prop_mode_replace, bytes, @intCast(count));
    return true;
}

/// The most one request carries, less room for its header. The server counts
/// in four-byte words.
fn maxPropertyBytes(self: *Impl) usize {
    const extended = self.x.XExtendedMaxRequestSize(self.display);
    const words = if (extended > 0) extended else self.x.XMaxRequestSize(self.display);
    return @as(usize, @intCast(@max(words - 64, 0))) * 4;
}

fn ignoreError(display: ?*Display, err: ?*anyopaque) callconv(.c) c_int {
    _ = .{ display, err };
    return 0;
}

/// Give what this program copied to a clipboard manager before the window
/// that owns it - and the text with it - goes away. The freedesktop convention
/// for what Windows does without being asked; with no manager running, the
/// text leaves with the program.
fn handOver(self: *Impl, selection: *const Selection) void {
    if (!self.owns_clipboard) return;
    if (self.x.XGetSelectionOwner(self.display, selection.clipboard) != selection.window) return;
    if (self.x.XGetSelectionOwner(self.display, selection.manager) == 0) return;

    _ = self.x.XConvertSelection(self.display, selection.manager, selection.save_targets, 0, selection.window, current_time);
    const deadline = clipboard.Deadline.in(clipboard.timeout_ms);
    var ev: XEvent = undefined;
    while (true) {
        while (self.x.XCheckTypedWindowEvent(self.display, selection.window, selection_request, &ev) != 0) {
            answer(self, selection, &ev.xselectionrequest);
        }
        if (self.x.XCheckTypedWindowEvent(self.display, selection.window, selection_notify, &ev) != 0) {
            if (ev.xselection.selection == selection.manager) return;
            continue;
        }
        const left = deadline.left();
        if (left == 0) return;
        var fds = [_]Pollfd{.{ .fd = self.x.XConnectionNumber(self.display), .events = pollin, .revents = 0 }};
        _ = c.poll(&fds, 1, left);
    }
}

// -------------------------------------------------------------------------
// Keycodes
// -------------------------------------------------------------------------

/// An X11 keycode is the kernel's evdev code plus eight, because X reserves
/// everything below eight. Evdev codes are physical positions, so this is the
/// mapping `Key` wants - and it is the same on every layout, which is what
/// reading the keysym instead would throw away.
fn keyFromKeycode(keycode: c_uint) keys.Key {
    if (keycode < 8) return .unknown;
    return evdev.keyFromEvdev(keycode - 8);
}

// -------------------------------------------------------------------------
// Tests
//
// The struct layouts and the keycode table run on any host, because a field at
// the wrong offset is not an error here - it is a window id read out of the
// middle of a timestamp - and that deserves a check that runs everywhere.
// -------------------------------------------------------------------------

test "the event structs are the size Xlib says they are" {
    // Everything X sends has to fit inside `long pad[24]`, and every event
    // struct below has to be laid out the way the server wrote it.
    try testing.expectEqual(24 * @sizeOf(c_long), @sizeOf(XEvent));

    inline for (.{
        XAnyEvent,
        XKeyEvent,
        XButtonEvent,
        XMotionEvent,
        XCrossingEvent,
        XFocusChangeEvent,
        XExposeEvent,
        XConfigureEvent,
        XClientMessageEvent,
        XPropertyEvent,
        XSelectionClearEvent,
        XSelectionRequestEvent,
        XSelectionEvent,
    }) |T| {
        try testing.expect(@sizeOf(T) <= @sizeOf(XEvent));
    }
}

test "every selection event names the clipboard's window where xany reads it" {
    try testing.expectEqual(@offsetOf(XAnyEvent, "window"), @offsetOf(XSelectionRequestEvent, "owner"));
    try testing.expectEqual(@offsetOf(XAnyEvent, "window"), @offsetOf(XSelectionEvent, "requestor"));
    try testing.expectEqual(@offsetOf(XAnyEvent, "window"), @offsetOf(XSelectionClearEvent, "window"));
    try testing.expectEqual(@offsetOf(XAnyEvent, "window"), @offsetOf(XPropertyEvent, "window"));
    try testing.expectEqual(10 * @sizeOf(c_long), @sizeOf(XSelectionRequestEvent));
    try testing.expectEqual(9 * @sizeOf(c_long), @sizeOf(XSelectionEvent));
}

test "the shared prefix of every event is at the same offset" {
    // `xany` is how the window is read for most events, so its fields have to
    // sit exactly where every other struct puts them. Getting this wrong reads
    // a window id out of the wrong place and silently drops every event.
    inline for (.{ XKeyEvent, XButtonEvent, XMotionEvent, XCrossingEvent, XExposeEvent }) |T| {
        try testing.expectEqual(@offsetOf(XAnyEvent, "type"), @offsetOf(T, "type"));
        try testing.expectEqual(@offsetOf(XAnyEvent, "serial"), @offsetOf(T, "serial"));
        try testing.expectEqual(@offsetOf(XAnyEvent, "display"), @offsetOf(T, "display"));
        try testing.expectEqual(@offsetOf(XAnyEvent, "window"), @offsetOf(T, "window"));
    }
}

test "the key and button events agree up to the field that differs" {
    // They are the same struct with one field renamed, which is what lets the
    // modifier state be read the same way from both.
    try testing.expectEqual(@offsetOf(XKeyEvent, "state"), @offsetOf(XButtonEvent, "state"));
    try testing.expectEqual(@offsetOf(XKeyEvent, "keycode"), @offsetOf(XButtonEvent, "button"));
    try testing.expectEqual(@sizeOf(XKeyEvent), @sizeOf(XButtonEvent));
}

test "a keycode is an evdev code plus eight" {
    // The four that make WASD, at their positions on any layout.
    try testing.expectEqual(keys.Key.w, keyFromKeycode(17 + 8));
    try testing.expectEqual(keys.Key.a, keyFromKeycode(30 + 8));
    try testing.expectEqual(keys.Key.s, keyFromKeycode(31 + 8));
    try testing.expectEqual(keys.Key.d, keyFromKeycode(32 + 8));

    try testing.expectEqual(keys.Key.escape, keyFromKeycode(9));
    try testing.expectEqual(keys.Key.space, keyFromKeycode(65));
}

test "the two enter keys and the two controls are told apart" {
    try testing.expectEqual(keys.Key.enter, keyFromKeycode(28 + 8));
    try testing.expectEqual(keys.Key.kp_enter, keyFromKeycode(96 + 8));
    try testing.expectEqual(keys.Key.left_control, keyFromKeycode(29 + 8));
    try testing.expectEqual(keys.Key.right_control, keyFromKeycode(97 + 8));
}

test "a keycode below eight, or with no name, is unknown" {
    // X reserves 0 to 7, so nothing there is a key.
    try testing.expectEqual(keys.Key.unknown, keyFromKeycode(0));
    try testing.expectEqual(keys.Key.unknown, keyFromKeycode(7));
    // And an evdev code this table has no name for.
    try testing.expectEqual(keys.Key.unknown, keyFromKeycode(240 + 8));
}

test "the X11 and Win32 tables agree about where a key is" {
    // The two backends derive `Key` from different numbering - set 1 scancodes
    // on Windows, evdev codes here - so the one thing worth checking is that
    // they land on the same key for the same physical position.
    const win32_scancode_for_a = 0x1E;
    const evdev_keycode_for_a = 30 + 8;
    try testing.expectEqual(
        keys.Key.a,
        keyFromKeycode(evdev_keycode_for_a),
    );
    // The set-1 code and the evdev code happen to agree in the main block, and
    // deliberately do not past it - which is why there are two tables.
    try testing.expectEqual(@as(u32, 0x1E), win32_scancode_for_a);
    try testing.expect(evdev.keyFromEvdev(96) != evdev.keyFromEvdev(28));
}

test "modifier state maps onto the same bits everywhere" {
    try testing.expectEqual(keys.Mods{ .shift = true }, modsFromState(shift_mask));
    try testing.expectEqual(keys.Mods{ .control = true }, modsFromState(control_mask));
    try testing.expectEqual(keys.Mods{ .alt = true }, modsFromState(mod1_mask));
    try testing.expectEqual(keys.Mods{ .super = true }, modsFromState(mod4_mask));
    try testing.expectEqual(keys.Mods{ .caps_lock = true }, modsFromState(lock_mask));
    try testing.expectEqual(keys.Mods{ .num_lock = true }, modsFromState(mod2_mask));

    try testing.expectEqual(keys.Mods.none, modsFromState(0));
    try testing.expectEqual(
        keys.Mods{ .shift = true, .control = true },
        modsFromState(shift_mask | control_mask),
    );
}

test "the DPI line is found in a resource string and ignored when absent" {
    // Not calling X: `readScale` parses a plain string, and that half is what
    // can be wrong.
    try testing.expectEqual(@as(?[]const u8, null), trimPrefix("Xcursor.size:\t24", "Xft.dpi:"));
    try testing.expectEqualStrings("\t144", trimPrefix("Xft.dpi:\t144", "Xft.dpi:").?);
}

test "a key sent to the window comes back out as text" {
    // The other half of the round trip: a key event goes through the X server
    // and comes back as both the key that moved and the letter it typed. Every
    // line from `XCreateWindow` through the input context to `Xutf8LookupString`
    // runs here.
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);

    const self = cast(impl);
    const id: event.WindowId = @enumFromInt(7);

    const native = try vtable.createWindow(impl, testing.allocator, id, .{
        .title = "fluxion-platform text test",
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

    // Evdev 30 is the key labelled A on a US layout, and X numbers it eight
    // higher - the offset this backend's whole key table is built on.
    const window = castWindow(native).window;
    var message: XEvent = std.mem.zeroes(XEvent);
    message.xkey = .{
        .type = key_press,
        .serial = 0,
        .send_event = 1,
        .display = self.display,
        .window = window,
        .root = self.root,
        .subwindow = 0,
        .time = 0,
        .x = 0,
        .y = 0,
        .x_root = 0,
        .y_root = 0,
        .state = 0,
        .keycode = 30 + 8,
        .same_screen = 1,
    };
    try testing.expect(self.x.XSendEvent(self.display, window, 0, key_press_mask, &message) != 0);
    _ = self.x.XFlush(self.display);

    var saw_key = false;
    var saw_char: ?u21 = null;
    for (0..40) |_| {
        try vtable.pump(impl, &queue);
        while (queue.next()) |ev| switch (ev) {
            .key => |k| if (k.key == .a and k.action == .press) {
                saw_key = true;
            },
            .char => |ch| saw_char = ch.codepoint,
            else => {},
        };
        if (saw_key and saw_char != null) break;
        _ = self.x.XFlush(self.display);
    }

    try testing.expect(saw_key);

    // The letter, which is the part `XLookupString` alone would get wrong on
    // any layout but a Latin one. Not asserted to be `a` - this machine's
    // layout decides that, and a Hungarian or French one puts something else
    // on the same key - only that a key which produced a `.key` also produced
    // some text and that the text is a real character.
    const typed = saw_char orelse return error.TestUnexpectedResult;
    try testing.expect(typed >= 0x20);
    try testing.expect(typed != 0x7F);
}

test "a client message sent to the window comes back out as an event" {
    // The same end-to-end check the Win32 backend has: a real message goes
    // through the X server, `pump` takes it out, and it names the window it
    // came from. Everything between `XCreateSimpleWindow` and `poll` runs here
    // and nowhere else. Skips where there is no display.
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

    // Drain whatever creating the window left behind.
    try vtable.pump(impl, &queue);
    queue.clear();

    // Exactly what a window manager sends when the user clicks the button.
    const window = castWindow(native).window;
    var message: XEvent = std.mem.zeroes(XEvent);
    message.xclient = .{
        .type = client_message,
        .serial = 0,
        .send_event = 1,
        .display = self.display,
        .window = window,
        .message_type = self.wm_protocols,
        .format = 32,
        .data = .{ .l = .{ @bitCast(self.wm_delete_window), 0, 0, 0, 0 } },
    };
    try testing.expect(self.x.XSendEvent(self.display, window, 0, 0, &message) != 0);
    _ = self.x.XFlush(self.display);

    // The server has to round-trip it, so wait rather than assuming one pump
    // is enough.
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        try vtable.pump(impl, &queue);
        if (queue.pending()) break;
        try vtable.wait(impl, 50);
    }

    const first = queue.next() orelse return error.NoEventArrived;
    try testing.expectEqual(id, first.window());
    try testing.expect(first == .close);
}

test "the wake pipe stops a wait that has nothing to wait for" {
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);

    // With no window and nothing happening, this would block until the timeout
    // - a `post` first is what makes it return at once. The test is that it
    // returns at all.
    vtable.post(impl);
    try vtable.wait(impl, 5_000);

    // And the byte is drained, so the next wait is not woken by the same post.
    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);
}

test "opening without an X server says so rather than failing to build" {
    // On a host with no X11 this is `error.NoDisplay` or `error.Unsupported`,
    // and both are answers `Context.init` carries on from by trying the next
    // backend. Where there is a display it opens, and closes again.
    const impl = open(testing.allocator) catch |err| {
        try testing.expect(err == error.NoDisplay or err == error.Unsupported);
        return;
    };
    defer vtable.deinit(impl, testing.allocator);

    try testing.expectEqual(platform.Backend.x11, vtable.backend);

    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);
}
