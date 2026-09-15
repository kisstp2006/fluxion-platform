// SPDX-License-Identifier: BSL-1.0

//! The Wayland backend: `libwayland-client.so.0`, and the protocol by hand.
//!
//! Wayland is a protocol, not a library API, and that is the whole difficulty.
//! `libwayland-client` marshals messages and nothing more: the descriptions of
//! what the messages *are* - `wl_interface`, one per protocol object, listing
//! every request and event with its wire signature - are normally generated
//! from XML by `wayland-scanner` and compiled into the program.
//!
//! For the core protocol that generated code is already inside the library and
//! its descriptors are exported, so `wl_compositor_interface` and the rest are
//! fetched by name like any other symbol. **xdg-shell is not**: it is a
//! separate protocol whose generated code every client compiles for itself, so
//! the four descriptors it needs are written out below, by hand, from
//! `xdg-shell.xml`. That is what SDL does, and what GLFW does since it started
//! loading Wayland dynamically.
//!
//! Requests go through `wl_proxy_marshal_array_flags`, which takes an array of
//! `wl_argument` rather than varargs - the same call the generated code makes,
//! without a variadic signature to get wrong.
//!
//! **Keys are evdev codes, and arrive that way.** `wl_keyboard.key` carries the
//! kernel's code directly, with no offset - unlike X11, which adds eight. So
//! the same table serves both, which is the one thing about input that Wayland
//! makes simpler.
//!
//! **A window is not visible until something draws into it.** Wayland has no
//! concept of an empty window: a surface with no buffer attached is not mapped,
//! and the compositor shows nothing. That is not a gap here - it is the
//! protocol, and it is why `createWindow` returns a surface that a renderer
//! then has to present to.

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
const egl = @import("egl.zig");
const gl = @import("../gl.zig");
const vulkan = @import("../vulkan.zig");
const text_mod = @import("../text.zig");
const xkb = @import("xkb.zig");
const keys = @import("../keys.zig");
const platform = @import("../platform.zig");
const evdev = @import("evdev.zig");
const virtual_key = @import("virtual_key.zig");
const cursor_mod = @import("../cursor.zig");
const clipboard = @import("clipboard.zig");
const linux_dialog = @import("linux_dialog.zig");

const Error = platform.Error;

/// Where a compositor can be reached. Elsewhere the file still compiles - the
/// protocol descriptors are ordinary data - and `open` refuses.
pub const has_display = switch (builtin.os.tag) {
    .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => !builtin.abi.isAndroid(),
    else => false,
};

const c = struct {
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn poll(fds: [*]Pollfd, nfds: c_ulong, timeout: c_int) c_int;
};

/// `mmap` and `munmap`, which is how the keymap is read: the compositor sends
/// a file descriptor rather than the text, so that one copy is shared by every
/// client on the seat.
const map_private: c_int = 0x02;
const prot_read: c_int = 0x1;
const map_failed: usize = std.math.maxInt(usize);

const Pollfd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};

const pollin: c_short = 0x001;
const pollout: c_short = 0x004;

// -------------------------------------------------------------------------
// The wire ABI
// -------------------------------------------------------------------------

const Proxy = opaque {};
const WlDisplay = opaque {};

/// `wl_fixed_t`: a signed 24.8 fixed-point number, which is how Wayland sends
/// every coordinate.
const Fixed = i32;

fn fixedToDouble(value: Fixed) f64 {
    return @as(f64, @floatFromInt(value)) / 256.0;
}

const WlArray = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

/// One argument on the wire. Every field is at most a pointer wide, so the
/// union is one word.
const WlArgument = extern union {
    i: i32,
    u: u32,
    f: Fixed,
    s: ?[*:0]const u8,
    o: ?*anyopaque,
    n: u32,
    a: ?*WlArray,
    h: i32,
};

const WlMessage = extern struct {
    name: [*:0]const u8,
    /// The wire signature: an optional leading digit for the version this
    /// message appeared in, then one character per argument, with `?` in front
    /// of one that may be null.
    signature: [*:0]const u8,
    /// One entry per argument, non-null only where the argument is an object or
    /// a new id with a known interface.
    types: [*]const ?*const WlInterface,
};

const WlInterface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const WlMessage,
    event_count: c_int,
    events: ?[*]const WlMessage,
};

const marshal_flag_destroy: u32 = 1 << 0;

const Wayland = struct {
    wl_display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*WlDisplay,
    wl_display_disconnect: *const fn (*WlDisplay) callconv(.c) void,
    wl_display_get_fd: *const fn (*WlDisplay) callconv(.c) c_int,
    wl_display_dispatch_pending: *const fn (*WlDisplay) callconv(.c) c_int,
    wl_display_flush: *const fn (*WlDisplay) callconv(.c) c_int,
    wl_display_roundtrip: *const fn (*WlDisplay) callconv(.c) c_int,
    wl_display_prepare_read: *const fn (*WlDisplay) callconv(.c) c_int,
    wl_display_read_events: *const fn (*WlDisplay) callconv(.c) c_int,
    wl_display_cancel_read: *const fn (*WlDisplay) callconv(.c) void,
    wl_proxy_marshal_array_flags: *const fn (
        *Proxy,
        u32,
        ?*const WlInterface,
        u32,
        u32,
        ?[*]WlArgument,
    ) callconv(.c) ?*Proxy,
    wl_proxy_add_listener: *const fn (*Proxy, *const anyopaque, ?*anyopaque) callconv(.c) c_int,
    wl_proxy_destroy: *const fn (*Proxy) callconv(.c) void,
    wl_proxy_get_version: *const fn (*Proxy) callconv(.c) u32,
    wl_proxy_get_user_data: *const fn (*Proxy) callconv(.c) ?*anyopaque,

    /// A queue of one's own, to wait for one object's answer without running
    /// every other listener outside a pump. Optional: without them a file
    /// dialog is only not held in front of its window.
    wl_display_create_queue: ?*const fn (*WlDisplay) callconv(.c) ?*WlEventQueue = null,
    wl_display_roundtrip_queue: ?*const fn (*WlDisplay, *WlEventQueue) callconv(.c) c_int = null,
    wl_proxy_set_queue: ?*const fn (*Proxy, ?*WlEventQueue) callconv(.c) void = null,
    wl_event_queue_destroy: ?*const fn (*WlEventQueue) callconv(.c) void = null,
};

const WlEventQueue = opaque {};

/// The core protocol's descriptors, which live inside the library.
///
/// These are the one thing here that is not an entry point: a `wl_interface` is
/// exported data, so `fluxion-dyn`'s `bind` refuses them by design - an entry
/// point table holds function pointers - and each is taken out with `lookup`
/// instead, which is what that call is for.
const CoreInterfaces = struct {
    wl_registry_interface: *const WlInterface,
    wl_compositor_interface: *const WlInterface,
    wl_surface_interface: *const WlInterface,
    wl_seat_interface: *const WlInterface,
    wl_pointer_interface: *const WlInterface,
    wl_keyboard_interface: *const WlInterface,
    wl_output_interface: *const WlInterface,
    wl_region_interface: *const WlInterface,
    wl_shm_interface: *const WlInterface,
    wl_data_device_manager_interface: *const WlInterface,
    wl_data_device_interface: *const WlInterface,
    wl_data_source_interface: *const WlInterface,
    wl_data_offer_interface: *const WlInterface,

    /// Every name, fetched one at a time. A missing one means this is not a
    /// `libwayland-client`, whatever the file was called.
    ///
    /// Through `get` rather than `lookup`: `lookup` casts to the type asked for
    /// in one step, which a function pointer survives and a `wl_interface` does
    /// not - the descriptor is aligned like a struct, and widening the
    /// alignment is a compile error. So the pointer is taken untyped and
    /// aligned here, where it is known what it points at.
    fn load(lib: *dyn.Library) ?CoreInterfaces {
        var self: CoreInterfaces = undefined;
        inline for (@typeInfo(CoreInterfaces).@"struct".fields) |field| {
            const raw: *const anyopaque = @ptrCast(lib.get(field.name.ptr) orelse return null);
            @field(self, field.name) = @ptrCast(@alignCast(raw));
        }
        return self;
    }
};

const candidates: []const [:0]const u8 = &.{ "libwayland-client.so.0", "libwayland-client.so" };

/// The theme loader, which lives in its own library.
///
/// Optional: without it a program can still hide the pointer and lock it, which
/// is what a game needs, and only the ordinary arrow is unavailable. `open`
/// carries on when it is missing rather than refusing to start.
const cursor_candidates: []const [:0]const u8 = &.{
    "libwayland-cursor.so.0",
    "libwayland-cursor.so",
};

const WlCursorTheme = opaque {};

const WlCursorImage = extern struct {
    width: u32,
    height: u32,
    hotspot_x: u32,
    hotspot_y: u32,
    delay: u32,
};

const WlCursor = extern struct {
    image_count: c_uint,
    images: [*]*WlCursorImage,
    name: [*:0]u8,
};

const WaylandCursor = struct {
    wl_cursor_theme_load: *const fn (?[*:0]const u8, c_int, *Proxy) callconv(.c) ?*WlCursorTheme,
    wl_cursor_theme_destroy: *const fn (*WlCursorTheme) callconv(.c) void,
    wl_cursor_theme_get_cursor: *const fn (*WlCursorTheme, [*:0]const u8) callconv(.c) ?*WlCursor,
    wl_cursor_image_get_buffer: *const fn (*WlCursorImage) callconv(.c) ?*Proxy,
};

/// The names the freedesktop cursor themes use. Not every theme has every one,
/// and `wl_cursor_theme_get_cursor` says so by answering null.
fn themeName(shape: cursor_mod.Shape) [*:0]const u8 {
    return switch (shape) {
        .arrow => "left_ptr",
        .ibeam => "xterm",
        .crosshair => "crosshair",
        .pointing_hand => "hand2",
        .resize_ew => "sb_h_double_arrow",
        .resize_ns => "sb_v_double_arrow",
        .resize_nwse => "bottom_right_corner",
        .resize_nesw => "bottom_left_corner",
        .resize_all => "fleur",
        .not_allowed => "crossed_circle",
    };
}

// Opcodes, from wayland.xml. A wrong one here sends a well-formed message that
// means something else.
const display_get_registry: u32 = 1;
const registry_bind: u32 = 0;
const compositor_create_surface: u32 = 0;
const surface_destroy: u32 = 0;
const surface_attach: u32 = 1;
const surface_damage: u32 = 2;
const surface_commit: u32 = 6;
const seat_get_pointer: u32 = 0;
const seat_get_keyboard: u32 = 1;
const pointer_set_cursor: u32 = 0;
const pointer_release: u32 = 1;

const constraints_lock_pointer: u32 = 1;
const constraints_confine_pointer: u32 = 2;
const locked_pointer_destroy: u32 = 0;
const confined_pointer_destroy: u32 = 0;
const relative_manager_get_relative_pointer: u32 = 1;
const relative_pointer_destroy: u32 = 0;

/// `zwp_pointer_constraints_v1.lifetime`: persistent, so the lock survives the
/// pointer leaving and coming back rather than having to be retaken.
const lifetime_persistent: u32 = 2;
const keyboard_release: u32 = 0;

const wm_base_destroy: u32 = 0;
const wm_base_get_xdg_surface: u32 = 2;
const wm_base_pong: u32 = 3;
const xdg_surface_destroy: u32 = 0;
const xdg_surface_get_toplevel: u32 = 1;
const xdg_surface_ack_configure: u32 = 4;
const toplevel_destroy: u32 = 0;
const toplevel_set_title: u32 = 2;
const toplevel_set_app_id: u32 = 3;
const toplevel_set_max_size: u32 = 7;
const toplevel_set_min_size: u32 = 8;
const toplevel_set_maximized: u32 = 9;
const toplevel_unset_maximized: u32 = 10;
const toplevel_set_fullscreen: u32 = 11;
const toplevel_unset_fullscreen: u32 = 12;
const toplevel_set_minimized: u32 = 13;

/// `wl_output.release`, which exists from version 3. Below that an output is
/// let go by destroying the proxy and nothing else.
const output_release: u32 = 0;

const data_device_manager_create_data_source: u32 = 0;
const data_device_manager_get_data_device: u32 = 1;
const data_device_set_selection: u32 = 1;
/// From version 2, like `wl_output.release`.
const data_device_release: u32 = 2;
const data_source_offer: u32 = 0;
const data_source_destroy: u32 = 1;
const data_offer_receive: u32 = 1;
const data_offer_destroy: u32 = 2;

/// The names text goes by, best first: what a paste asks the owner for.
const text_types = [_][:0]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" };
/// And what a copy offers, which every toolkit and Xwayland asks for by one
/// of these names.
const offered_types = [_][:0]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING" };

/// `wl_seat.capabilities` bits.
const seat_pointer: u32 = 1;
const seat_keyboard: u32 = 2;

/// `wl_keyboard.key_state` and `wl_pointer.button_state`.
const state_released: u32 = 0;

/// `wl_pointer.axis`.
const axis_vertical: u32 = 0;
const axis_horizontal: u32 = 1;

/// Linux button codes, which is what `wl_pointer.button` carries.
const btn_left: u32 = 0x110;
const btn_right: u32 = 0x111;
const btn_middle: u32 = 0x112;
const btn_side: u32 = 0x113;
const btn_extra: u32 = 0x114;

// -------------------------------------------------------------------------
// xdg-shell, written out by hand
//
// From `stable/xdg-shell/xdg-shell.xml`, at version 1 - which is every request
// and the two events a toplevel window needs. Declaring the version-1 subset
// rather than the whole of version 7 is deliberate: a listener array has to be
// as long as the interface says there are events, and the shortest correct
// answer is the one with the least to get wrong.
//
// The `types` arrays hold pointers to core interfaces that are not known until
// the library is open, so they are filled in by `bindProtocol` before any of
// these descriptors is used.
// -------------------------------------------------------------------------

var xdg_positioner_interface: WlInterface = undefined;
var xdg_surface_interface: WlInterface = undefined;
var xdg_toplevel_interface: WlInterface = undefined;
var xdg_wm_base_interface: WlInterface = undefined;

/// Every `types` entry any of the messages below needs. One array, indexed into
/// by slices, which is how the generated code lays them out too.
var xdg_types: [16]?*const WlInterface = @splat(null);

var constraints_interface: WlInterface = undefined;
var locked_pointer_interface: WlInterface = undefined;
var confined_pointer_interface: WlInterface = undefined;
var relative_manager_interface: WlInterface = undefined;
var relative_pointer_interface: WlInterface = undefined;

var pointer_types: [12]?*const WlInterface = @splat(null);
var constraints_requests: [3]WlMessage = undefined;
var locked_requests: [3]WlMessage = undefined;
var locked_events: [2]WlMessage = undefined;
var confined_requests: [2]WlMessage = undefined;
var relative_manager_requests: [2]WlMessage = undefined;
var relative_pointer_requests: [1]WlMessage = undefined;
var relative_pointer_events: [1]WlMessage = undefined;

/// The two unstable protocols a locked pointer needs, from
/// `pointer-constraints-unstable-v1.xml` and
/// `relative-pointer-unstable-v1.xml`.
///
/// Written out for the same reason xdg-shell is: they are not core, so their
/// descriptors are not in the library and every client compiles its own.
fn buildPointerInterfaces(core: CoreInterfaces) void {
    pointer_types = @splat(null);
    pointer_types[0] = &locked_pointer_interface; // lock_pointer id
    pointer_types[1] = core.wl_surface_interface;
    pointer_types[2] = core.wl_pointer_interface;
    pointer_types[3] = core.wl_region_interface;
    // lifetime is a uint, so no type
    pointer_types[5] = &confined_pointer_interface; // confine_pointer id
    pointer_types[6] = core.wl_surface_interface;
    pointer_types[7] = core.wl_pointer_interface;
    pointer_types[8] = core.wl_region_interface;

    pointer_types[10] = &relative_pointer_interface; // get_relative_pointer id
    pointer_types[11] = core.wl_pointer_interface;

    const none: [*]const ?*const WlInterface = @ptrCast(&pointer_types[4]);
    const region_only: [*]const ?*const WlInterface = @ptrCast(&pointer_types[3]);

    constraints_requests = .{
        .{ .name = "destroy", .signature = "", .types = none },
        .{ .name = "lock_pointer", .signature = "noo?ou", .types = @ptrCast(&pointer_types[0]) },
        .{ .name = "confine_pointer", .signature = "noo?ou", .types = @ptrCast(&pointer_types[5]) },
    };
    constraints_interface = .{
        .name = "zwp_pointer_constraints_v1",
        .version = 1,
        .method_count = constraints_requests.len,
        .methods = &constraints_requests,
        .event_count = 0,
        .events = null,
    };

    locked_requests = .{
        .{ .name = "destroy", .signature = "", .types = none },
        .{ .name = "set_cursor_position_hint", .signature = "ff", .types = none },
        .{ .name = "set_region", .signature = "?o", .types = region_only },
    };
    locked_events = .{
        .{ .name = "locked", .signature = "", .types = none },
        .{ .name = "unlocked", .signature = "", .types = none },
    };
    locked_pointer_interface = .{
        .name = "zwp_locked_pointer_v1",
        .version = 1,
        .method_count = locked_requests.len,
        .methods = &locked_requests,
        .event_count = locked_events.len,
        .events = &locked_events,
    };

    confined_requests = .{
        .{ .name = "destroy", .signature = "", .types = none },
        .{ .name = "set_region", .signature = "?o", .types = region_only },
    };
    confined_pointer_interface = .{
        .name = "zwp_confined_pointer_v1",
        .version = 1,
        .method_count = confined_requests.len,
        .methods = &confined_requests,
        // `confined` and `unconfined`, neither of which this backend acts on.
        .event_count = 2,
        .events = &locked_events,
    };

    relative_manager_requests = .{
        .{ .name = "destroy", .signature = "", .types = none },
        .{ .name = "get_relative_pointer", .signature = "no", .types = @ptrCast(&pointer_types[10]) },
    };
    relative_manager_interface = .{
        .name = "zwp_relative_pointer_manager_v1",
        .version = 1,
        .method_count = relative_manager_requests.len,
        .methods = &relative_manager_requests,
        .event_count = 0,
        .events = null,
    };

    relative_pointer_requests = .{
        .{ .name = "destroy", .signature = "", .types = none },
    };
    relative_pointer_events = .{
        .{ .name = "relative_motion", .signature = "uuffff", .types = none },
    };
    relative_pointer_interface = .{
        .name = "zwp_relative_pointer_v1",
        .version = 1,
        .method_count = relative_pointer_requests.len,
        .methods = &relative_pointer_requests,
        .event_count = relative_pointer_events.len,
        .events = &relative_pointer_events,
    };
}

// From `unstable/xdg-foreign/xdg-foreign-unstable-v2.xml`: the handle another
// program - the desktop portal - names this window by, to put its dialog in
// front of it.
var exporter_interface: WlInterface = undefined;
var exported_interface: WlInterface = undefined;
var foreign_types: [3]?*const WlInterface = @splat(null);
var exporter_requests: [2]WlMessage = undefined;
var exported_requests: [1]WlMessage = undefined;
var exported_events: [1]WlMessage = undefined;

const exporter_destroy: u32 = 0;
const exporter_export_toplevel: u32 = 1;
const exported_destroy: u32 = 0;

fn buildForeignInterfaces(core: CoreInterfaces) void {
    foreign_types = .{ &exported_interface, core.wl_surface_interface, null };
    const none: [*]const ?*const WlInterface = @ptrCast(&foreign_types[2]);

    exporter_requests = .{
        .{ .name = "destroy", .signature = "", .types = none },
        .{ .name = "export_toplevel", .signature = "no", .types = @ptrCast(&foreign_types[0]) },
    };
    exporter_interface = .{
        .name = "zxdg_exporter_v2",
        .version = 1,
        .method_count = exporter_requests.len,
        .methods = &exporter_requests,
        .event_count = 0,
        .events = null,
    };
    exported_requests = .{.{ .name = "destroy", .signature = "", .types = none }};
    exported_events = .{.{ .name = "handle", .signature = "s", .types = none }};
    exported_interface = .{
        .name = "zxdg_exported_v2",
        .version = 1,
        .method_count = exported_requests.len,
        .methods = &exported_requests,
        .event_count = exported_events.len,
        .events = &exported_events,
    };
}

var wm_base_requests: [4]WlMessage = undefined;
var wm_base_events: [1]WlMessage = undefined;
var xdg_surface_requests: [5]WlMessage = undefined;
var xdg_surface_events: [1]WlMessage = undefined;
var toplevel_requests: [14]WlMessage = undefined;
var toplevel_events: [2]WlMessage = undefined;
var positioner_requests: [7]WlMessage = undefined;

/// Fill in the hand-written descriptors, now that the core ones are known.
///
/// Called once per `open`. Writing to module-level state is safe because a
/// context is one per process and the values are the same every time.
fn buildXdgInterfaces(core: CoreInterfaces) void {
    // Slots the messages below point into.
    xdg_types = @splat(null);
    xdg_types[0] = &xdg_positioner_interface; // wm_base.create_positioner id
    xdg_types[1] = &xdg_surface_interface; // wm_base.get_xdg_surface id
    xdg_types[2] = core.wl_surface_interface; // wm_base.get_xdg_surface surface
    xdg_types[3] = &xdg_toplevel_interface; // xdg_surface.get_toplevel id
    xdg_types[4] = null; // xdg_surface.get_popup id (xdg_popup, never used)
    xdg_types[5] = &xdg_surface_interface; // xdg_surface.get_popup parent
    xdg_types[6] = &xdg_positioner_interface; // xdg_surface.get_popup positioner
    xdg_types[7] = &xdg_toplevel_interface; // toplevel.set_parent
    xdg_types[8] = core.wl_seat_interface; // toplevel.show_window_menu seat
    xdg_types[9] = core.wl_output_interface; // toplevel.set_fullscreen output

    const none: [*]const ?*const WlInterface = @ptrCast(&xdg_types[10]);

    wm_base_requests = .{
        .{ .name = "destroy", .signature = "", .types = none },
        .{ .name = "create_positioner", .signature = "n", .types = @ptrCast(&xdg_types[0]) },
        .{ .name = "get_xdg_surface", .signature = "no", .types = @ptrCast(&xdg_types[1]) },
        .{ .name = "pong", .signature = "u", .types = none },
    };
    wm_base_events = .{
        .{ .name = "ping", .signature = "u", .types = none },
    };
    xdg_wm_base_interface = .{
        .name = "xdg_wm_base",
        .version = 1,
        .method_count = wm_base_requests.len,
        .methods = &wm_base_requests,
        .event_count = wm_base_events.len,
        .events = &wm_base_events,
    };

    xdg_surface_requests = .{
        .{ .name = "destroy", .signature = "", .types = none },
        .{ .name = "get_toplevel", .signature = "n", .types = @ptrCast(&xdg_types[3]) },
        .{ .name = "get_popup", .signature = "n?oo", .types = @ptrCast(&xdg_types[4]) },
        .{ .name = "set_window_geometry", .signature = "iiii", .types = none },
        .{ .name = "ack_configure", .signature = "u", .types = none },
    };
    xdg_surface_events = .{
        .{ .name = "configure", .signature = "u", .types = none },
    };
    xdg_surface_interface = .{
        .name = "xdg_surface",
        .version = 1,
        .method_count = xdg_surface_requests.len,
        .methods = &xdg_surface_requests,
        .event_count = xdg_surface_events.len,
        .events = &xdg_surface_events,
    };

    toplevel_requests = .{
        .{ .name = "destroy", .signature = "", .types = none },
        .{ .name = "set_parent", .signature = "?o", .types = @ptrCast(&xdg_types[7]) },
        .{ .name = "set_title", .signature = "s", .types = none },
        .{ .name = "set_app_id", .signature = "s", .types = none },
        .{ .name = "show_window_menu", .signature = "ouii", .types = @ptrCast(&xdg_types[8]) },
        .{ .name = "move", .signature = "ou", .types = @ptrCast(&xdg_types[8]) },
        .{ .name = "resize", .signature = "ouu", .types = @ptrCast(&xdg_types[8]) },
        .{ .name = "set_max_size", .signature = "ii", .types = none },
        .{ .name = "set_min_size", .signature = "ii", .types = none },
        .{ .name = "set_maximized", .signature = "", .types = none },
        .{ .name = "unset_maximized", .signature = "", .types = none },
        .{ .name = "set_fullscreen", .signature = "?o", .types = @ptrCast(&xdg_types[9]) },
        .{ .name = "unset_fullscreen", .signature = "", .types = none },
        .{ .name = "set_minimized", .signature = "", .types = none },
    };
    toplevel_events = .{
        .{ .name = "configure", .signature = "iia", .types = none },
        .{ .name = "close", .signature = "", .types = none },
    };
    xdg_toplevel_interface = .{
        .name = "xdg_toplevel",
        .version = 1,
        .method_count = toplevel_requests.len,
        .methods = &toplevel_requests,
        .event_count = toplevel_events.len,
        .events = &toplevel_events,
    };

    positioner_requests = .{
        .{ .name = "destroy", .signature = "", .types = none },
        .{ .name = "set_size", .signature = "ii", .types = none },
        .{ .name = "set_anchor_rect", .signature = "iiii", .types = none },
        .{ .name = "set_anchor", .signature = "u", .types = none },
        .{ .name = "set_gravity", .signature = "u", .types = none },
        .{ .name = "set_constraint_adjustment", .signature = "u", .types = none },
        .{ .name = "set_offset", .signature = "ii", .types = none },
    };
    xdg_positioner_interface = .{
        .name = "xdg_positioner",
        .version = 1,
        .method_count = positioner_requests.len,
        .methods = &positioner_requests,
        .event_count = 0,
        .events = null,
    };
}

// -------------------------------------------------------------------------
// State
// -------------------------------------------------------------------------

const Impl = struct {
    gpa: Allocator,
    lib: dyn.Library,
    w: Wayland,
    core: CoreInterfaces,
    display: *WlDisplay,

    registry: ?*Proxy = null,
    compositor: ?*Proxy = null,
    wm_base: ?*Proxy = null,
    seat: ?*Proxy = null,
    pointer: ?*Proxy = null,
    keyboard: ?*Proxy = null,

    /// The theme loader and the globals a locked pointer needs. Any of them may
    /// be absent on an older compositor, and each call says so rather than
    /// assuming.
    cursor_lib: ?dyn.Library = null,
    wc: ?WaylandCursor = null,
    theme: ?*WlCursorTheme = null,
    shm: ?*Proxy = null,
    constraints: ?*Proxy = null,
    relative_manager: ?*Proxy = null,

    /// The surface the themed cursor image is attached to. One per process,
    /// because one pointer is.
    cursor_surface: ?*Proxy = null,
    /// The serial from the last `wl_pointer.enter`, which `set_cursor` needs
    /// and which nothing else carries.
    enter_serial: u32 = 0,

    /// Where the pointer is now, so a motion event can carry a delta.
    pointer_focus: ?*Native = null,
    keyboard_focus: ?*Native = null,
    mods: keys.Mods = .none,

    /// Set for the length of one `pump`, so a listener called from inside
    /// `wl_display_dispatch_pending` has somewhere to put what it produced.
    queue: ?*backend.Queue = null,
    later: backend.Later = .{},
    push_failed: bool = false,

    /// Every `wl_output` the compositor has announced, in the order it
    /// announced them. Kept up to date by the registry listener rather than
    /// asked for: Wayland pushes this and has no call to ask.
    outputs: std.ArrayListUnmanaged(*Output) = .empty,

    /// Controllers. Not a Wayland idea at all - the same kernel devices the
    /// X11 backend reads, through the same code.
    pads: linux_gamepad.Backend = .{},

    /// What a keycode types. Wayland sends no text at all, only a keymap and
    /// raw codes, so without this there are no `.char` events - see `xkb`.
    xkb: xkb.Backend = .{},
    /// Nothing is composed here yet: this backend does not speak
    /// `zwp_text_input_v3`, so there is no input method to report a
    /// composition from. Kept so `preedit` answers "nothing" rather than
    /// "no idea".
    preedit: text_mod.Preedit = .{},

    /// OpenGL, which on Wayland can only be EGL - there is no GLX equivalent
    /// and no plan for one. Both libraries are optional: a compositor session
    /// without them still opens windows.
    gl: egl.Backend = .{},
    wl_egl_lib: ?dyn.Library = null,
    we: ?WaylandEgl = null,

    windows: std.AutoArrayHashMapUnmanaged(usize, *Native) = .empty,
    wake: if (has_display) [2]c_int else void = if (has_display) .{ -1, -1 } else {},

    /// The clipboard: the seat's data device, the offers it makes, and the
    /// source that serves what this program copied.
    data_manager: ?*Proxy = null,
    data_device: ?*Proxy = null,
    /// Introduced by `data_offer` and named by the event that follows: the
    /// clipboard's contents, or a drag passing over a window.
    new_offer: ?*Offer = null,
    selection_offer: ?*Offer = null,
    drag_offer: ?*Offer = null,
    source: ?*Proxy = null,
    clipboard_text: std.ArrayListUnmanaged(u8) = .empty,
    /// The serial of the last key or click, which a request for the clipboard
    /// has to name.
    input_serial: u32 = 0,

    /// The file dialog that is open, whose end `pump` looks for.
    dialog: ?*linux_dialog.Dialog = null,
    /// What the last dialog's answer carried, kept until the next pump.
    answers: std.heap.ArenaAllocator,
    /// xdg-foreign, where the compositor has it, and the export that names
    /// the dialog's window to the portal for as long as the dialog is open.
    exporter: ?*Proxy = null,
    exported: ?*Proxy = null,
    export_handle: [256]u8 = undefined,
    export_handle_len: usize = 0,
};

/// One `wl_data_offer`, and the best of `text_types` it has said it can give.
const Offer = struct {
    proxy: *Proxy,
    text: ?usize = null,
};

/// One display, as its events arrive.
///
/// Filled in over several messages - geometry, then a mode for each thing it
/// can do, then `done` to say that is all - so it is only worth reading once
/// `done` has been seen at least once.
const Output = struct {
    proxy: *Proxy,
    /// The registry name, which is what `global_remove` names when the monitor
    /// is unplugged.
    global: u32,
    impl: *Impl,

    x: i32 = 0,
    y: i32 = 0,
    physical_width_mm: u32 = 0,
    physical_height_mm: u32 = 0,
    /// Integer in the protocol, and the only scale a Wayland client is told
    /// about without the fractional-scale extension.
    scale: i32 = 1,
    /// The mode marked current, which is the one the display is in.
    current: monitor.VideoMode = .{},
    modes: std.ArrayListUnmanaged(monitor.VideoMode) = .empty,
    name_buf: [monitor.max_name_len + 1]u8 = @splat(0),
    name_len: u8 = 0,
    ready: bool = false,

    fn setName(self: *Output, text: []const u8) void {
        const len = @min(text.len, monitor.max_name_len);
        @memcpy(self.name_buf[0..len], text[0..len]);
        self.name_buf[len] = 0;
        self.name_len = @intCast(len);
    }
};

/// `libwayland-egl`, which is the one piece EGL cannot supply itself: a
/// `wl_surface` is a protocol object and EGL needs something with a size, so
/// this wraps one in a `wl_egl_window` that can be resized.
const WaylandEgl = struct {
    wl_egl_window_create: *const fn (*Proxy, c_int, c_int) callconv(.c) ?*anyopaque,
    wl_egl_window_destroy: *const fn (*anyopaque) callconv(.c) void,
    wl_egl_window_resize: *const fn (*anyopaque, c_int, c_int, c_int, c_int) callconv(.c) void,
};

const wayland_egl_candidates: []const [:0]const u8 = &.{
    "libwayland-egl.so.1",
    "libwayland-egl.so",
};

const mmap_c = struct {
    extern "c" fn mmap(
        addr: ?*anyopaque,
        length: usize,
        prot: c_int,
        flags: c_int,
        fd: c_int,
        offset: i64,
    ) ?*anyopaque;
    extern "c" fn munmap(addr: *anyopaque, length: usize) c_int;
};

const Native = struct {
    surface: *Proxy,
    xdg_surface: *Proxy,
    toplevel: *Proxy,
    id: event.WindowId,
    impl: *Impl,
    width: u32,
    height: u32,
    /// What the last `xdg_toplevel.configure` asked for, applied on the
    /// `xdg_surface.configure` that follows it. The protocol sends the size and
    /// the serial as two messages, and only the second one may be answered.
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    last_x: f64 = 0,
    last_y: f64 = 0,
    has_position: bool = false,
    /// What the last `xdg_toplevel.configure` said the window is.
    maximized: bool = false,
    activated: bool = false,

    mode: cursor_mod.Mode = .normal,
    shape: cursor_mod.Shape = .arrow,
    /// The constraint in force, and the relative pointer that reports motion
    /// while it is. Both are destroyed when the mode changes.
    locked: ?*Proxy = null,
    confined: ?*Proxy = null,
    relative: ?*Proxy = null,
    /// Whether the compositor has the lock in force: only while the window has focus.
    held: bool = false,
    /// The outputs the surface is on, latest last, from `wl_surface.enter`.
    entered: [4]?*Proxy = @splat(null),
    /// Set the first time the compositor answers the opening commit. Until it
    /// does, the two sides have not agreed that this window exists - so it is
    /// the one fact that says the whole handshake worked.
    configured: bool = false,
    /// What the last `xdg_toplevel.configure` said. The compositor's word, not
    /// this program's: a keybinding or a tiling rule can put a window
    /// fullscreen without anyone here asking, and the configure is where that
    /// is found out.
    fullscreen: bool = false,
    /// How big the window was before it filled a monitor.
    ///
    /// Wayland has nowhere else to keep it. Leaving fullscreen brings a
    /// configure that says "you decide", and a client with nothing remembered
    /// decides on the size it has - which is the monitor. So a window that went
    /// fullscreen once would never be small again.
    restore_width: u32 = 0,
    restore_height: u32 = 0,

    text_input: bool = false,

    /// Set only for a window made with a GL config.
    context: ?egl.Context = null,
    /// The `wl_egl_window` the EGL surface sits on. Resized whenever the window
    /// is, because EGL has no way to find out on its own.
    egl_window: ?*anyopaque = null,
};

pub const vtable: backend.Vtable = .{
    .backend = .wayland,
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

// -------------------------------------------------------------------------
// Marshalling
// -------------------------------------------------------------------------

/// A request that makes nothing.
fn request(self: *Impl, proxy: *Proxy, opcode: u32, args: ?[]WlArgument) void {
    _ = self.w.wl_proxy_marshal_array_flags(
        proxy,
        opcode,
        null,
        self.w.wl_proxy_get_version(proxy),
        0,
        if (args) |a| a.ptr else null,
    );
}

/// A request that destroys the object it is sent to.
fn requestDestroy(self: *Impl, proxy: *Proxy, opcode: u32) void {
    _ = self.w.wl_proxy_marshal_array_flags(
        proxy,
        opcode,
        null,
        self.w.wl_proxy_get_version(proxy),
        marshal_flag_destroy,
        null,
    );
}

/// A request that makes a new object. The `new_id` slot in `args` is written by
/// the library, and has to be there.
fn construct(
    self: *Impl,
    proxy: *Proxy,
    opcode: u32,
    interface: *const WlInterface,
    version: u32,
    args: []WlArgument,
) ?*Proxy {
    return self.w.wl_proxy_marshal_array_flags(proxy, opcode, interface, version, 0, args.ptr);
}

// -------------------------------------------------------------------------
// Opening
// -------------------------------------------------------------------------

pub fn open(gpa: Allocator) Error!backend.Impl {
    if (comptime !has_display) return error.Unsupported;

    const self = gpa.create(Impl) catch return error.OutOfMemory;
    errdefer gpa.destroy(self);

    var lib = dyn.Library.openAny(candidates) catch return error.NoDisplay;
    errdefer lib.close();

    const w = lib.bind(Wayland) catch return error.NoDisplay;
    const core = CoreInterfaces.load(&lib) orelse return error.NoDisplay;

    // Null means `$WAYLAND_DISPLAY`. Null back means there is no compositor
    // here, which is the ordinary answer on an X-only machine.
    const display = w.wl_display_connect(null) orelse return error.NoDisplay;
    errdefer w.wl_display_disconnect(display);

    buildXdgInterfaces(core);
    buildPointerInterfaces(core);
    buildForeignInterfaces(core);

    self.* = .{
        .gpa = gpa,
        .lib = lib,
        .w = w,
        .core = core,
        .display = display,
        .answers = .init(gpa),
    };

    if (comptime has_display) {
        var fds: [2]c_int = .{ -1, -1 };
        if (c.pipe(&fds) != 0) return error.ConnectionFailed;
        self.wake = fds;
    }
    errdefer if (comptime has_display) {
        _ = c.close(self.wake[0]);
        _ = c.close(self.wake[1]);
    };

    try bindGlobals(self);

    // After the globals, because the theme needs the `wl_shm` one of them is.
    loadCursorTheme(self);

    return self;
}

/// Ask the registry what the compositor has, and take the three globals a
/// window needs.
fn bindGlobals(self: *Impl) Error!void {
    const w = self.w;

    var args = [_]WlArgument{.{ .n = 0 }};
    self.registry = construct(
        self,
        @ptrCast(self.display),
        display_get_registry,
        self.core.wl_registry_interface,
        1,
        &args,
    ) orelse return error.ConnectionFailed;

    _ = w.wl_proxy_add_listener(self.registry.?, &registry_listener, self);

    // Two round trips: the first brings the `global` events, the second makes
    // sure anything they caused - the seat's capabilities - has arrived too.
    if (w.wl_display_roundtrip(self.display) < 0) return error.ConnectionFailed;
    if (w.wl_display_roundtrip(self.display) < 0) return error.ConnectionFailed;

    // Without these there is no way to put anything on screen, and saying so
    // here beats failing later with a null pointer.
    if (self.compositor == null or self.wm_base == null) return error.ConnectionFailed;

    // The clipboard's, made now rather than when it is first used: the
    // compositor says what the clipboard holds when a window gains the
    // keyboard, and a device made later would have missed hearing it.
    const manager = self.data_manager orelse return;
    const seat = self.seat orelse return;
    var device_args = [_]WlArgument{ .{ .n = 0 }, .{ .o = seat } };
    self.data_device = construct(
        self,
        manager,
        data_device_manager_get_data_device,
        self.core.wl_data_device_interface,
        w.wl_proxy_get_version(manager),
        &device_args,
    );
    if (self.data_device) |device| _ = w.wl_proxy_add_listener(device, &data_device_listener, self);
}

/// Open `libwayland-cursor` and load the user's theme.
///
/// Every step is allowed to fail: without a theme the pointer cannot be given
/// an ordinary arrow, and everything else - hiding it, locking it - still
/// works. That is the difference between a game that runs and one that does
/// not, so none of this is fatal.
fn loadCursorTheme(self: *Impl) void {
    const shm = self.shm orelse return;

    var lib = dyn.Library.openAny(cursor_candidates) catch return;
    const wc = lib.bind(WaylandCursor) catch {
        lib.close();
        return;
    };

    // The name and size a desktop would set. Null asks for the default theme,
    // which is what a program without a setting should use.
    const theme = wc.wl_cursor_theme_load(null, 24, shm) orelse {
        lib.close();
        return;
    };

    self.cursor_lib = lib;
    self.wc = wc;
    self.theme = theme;

    var args = [_]WlArgument{.{ .n = 0 }};
    self.cursor_surface = construct(
        self,
        self.compositor.?,
        compositor_create_surface,
        self.core.wl_surface_interface,
        self.w.wl_proxy_get_version(self.compositor.?),
        &args,
    );
}

/// Put a themed image on the cursor surface and hand it to the compositor.
fn showThemeCursor(self: *Impl, shape: cursor_mod.Shape) bool {
    const wc = self.wc orelse return false;
    const theme = self.theme orelse return false;
    const surface = self.cursor_surface orelse return false;
    const pointer = self.pointer orelse return false;

    const found = wc.wl_cursor_theme_get_cursor(theme, themeName(shape)) orelse return false;
    if (found.image_count == 0) return false;

    const image = found.images[0];
    const buffer = wc.wl_cursor_image_get_buffer(image) orelse return false;

    var attach = [_]WlArgument{ .{ .o = buffer }, .{ .i = 0 }, .{ .i = 0 } };
    request(self, surface, surface_attach, &attach);

    var damage = [_]WlArgument{
        .{ .i = 0 },
        .{ .i = 0 },
        .{ .i = @intCast(image.width) },
        .{ .i = @intCast(image.height) },
    };
    request(self, surface, surface_damage, &damage);
    request(self, surface, surface_commit, null);

    var set = [_]WlArgument{
        .{ .u = self.enter_serial },
        .{ .o = surface },
        .{ .i = @intCast(image.hotspot_x) },
        .{ .i = @intCast(image.hotspot_y) },
    };
    request(self, pointer, pointer_set_cursor, &set);
    _ = self.w.wl_display_flush(self.display);
    return true;
}

/// A null surface is how Wayland hides the pointer.
fn hidePointer(self: *Impl) void {
    const pointer = self.pointer orelse return;
    var set = [_]WlArgument{
        .{ .u = self.enter_serial },
        .{ .o = null },
        .{ .i = 0 },
        .{ .i = 0 },
    };
    request(self, pointer, pointer_set_cursor, &set);
    _ = self.w.wl_display_flush(self.display);
}

/// A disabled window whose lock is not in force shows the pointer passing over it.
fn pointerHidden(win: *const Native) bool {
    return win.mode == .hidden or (win.mode == .disabled and win.held);
}

const LockedListener = extern struct {
    locked: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
    unlocked: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
};

const locked_listener: LockedListener = .{ .locked = onLocked, .unlocked = onUnlocked };

/// A persistent lock is the compositor's to switch on and off with focus.
fn onLocked(data: ?*anyopaque, proxy: *Proxy) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = findByLock(self, proxy) orelse return;
    native.held = true;
    if (self.pointer_focus == native) hidePointer(self);
}

fn onUnlocked(data: ?*anyopaque, proxy: *Proxy) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = findByLock(self, proxy) orelse return;
    native.held = false;
    if (self.pointer_focus == native) _ = showThemeCursor(self, native.shape);
}

fn findByLock(self: *Impl, proxy: *Proxy) ?*Native {
    for (self.windows.values()) |native| {
        if (native.locked == proxy) return native;
    }
    return null;
}

fn releaseConstraint(self: *Impl, win: *Native) void {
    win.held = false;
    if (win.locked) |p| {
        requestDestroy(self, p, locked_pointer_destroy);
        win.locked = null;
    }
    if (win.confined) |p| {
        requestDestroy(self, p, confined_pointer_destroy);
        win.confined = null;
    }
    if (win.relative) |p| {
        requestDestroy(self, p, relative_pointer_destroy);
        win.relative = null;
    }
}

fn setCursorShape(impl: backend.Impl, native: backend.NativeWindow, shape: cursor_mod.Shape) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    win.shape = shape;

    if (pointerHidden(win)) return;
    if (!showThemeCursor(self, shape)) return error.Unavailable;
}

fn setCursorMode(impl: backend.Impl, native: backend.NativeWindow, mode: cursor_mod.Mode) Error!void {
    const self = cast(impl);
    const win = castWindow(native);
    if (win.mode == mode) return;

    releaseConstraint(self, win);
    win.mode = mode;

    if (pointerHidden(win)) hidePointer(self) else _ = showThemeCursor(self, win.shape);

    if (!mode.confines()) {
        _ = self.w.wl_display_flush(self.display);
        return;
    }

    const constraints = self.constraints orelse {
        // No `zwp_pointer_constraints_v1`: this compositor cannot hold a
        // pointer, and pretending otherwise would leave a camera that only
        // turns until the cursor hits an edge.
        win.mode = .normal;
        _ = showThemeCursor(self, win.shape);
        return error.Unavailable;
    };
    const pointer = self.pointer orelse {
        win.mode = .normal;
        return error.Unavailable;
    };

    var args = [_]WlArgument{
        .{ .n = 0 },
        .{ .o = win.surface },
        .{ .o = pointer },
        // No region: the whole surface.
        .{ .o = null },
        .{ .u = lifetime_persistent },
    };

    if (mode == .disabled) {
        win.locked = construct(
            self,
            constraints,
            constraints_lock_pointer,
            &locked_pointer_interface,
            1,
            &args,
        );
        if (win.locked) |proxy| _ = self.w.wl_proxy_add_listener(proxy, &locked_listener, self);

        // The lock stops the pointer moving; the relative pointer is what
        // still reports the hand. Without both, a disabled cursor is a frozen
        // one.
        if (self.relative_manager) |manager| {
            var rel = [_]WlArgument{ .{ .n = 0 }, .{ .o = pointer } };
            win.relative = construct(
                self,
                manager,
                relative_manager_get_relative_pointer,
                &relative_pointer_interface,
                1,
                &rel,
            );
            if (win.relative) |proxy| {
                _ = self.w.wl_proxy_add_listener(proxy, &relative_listener, self);
            }
        }
    } else {
        win.confined = construct(
            self,
            constraints,
            constraints_confine_pointer,
            &confined_pointer_interface,
            1,
            &args,
        );
    }

    _ = self.w.wl_display_flush(self.display);
}

/// Wayland has no accelerated pointer to turn off: `relative_motion` carries
/// both the accelerated and the unaccelerated numbers, and this backend already
/// uses the unaccelerated pair.
fn setRawMouseMotion(impl: backend.Impl, native: backend.NativeWindow, on: bool) bool {
    _ = .{ impl, native };
    return on;
}

/// A client cannot put the pointer anywhere.
///
/// The nearest thing is `set_cursor_position_hint`, which says where the cursor
/// should reappear when a lock ends - not where it should be now.
fn setCursorPos(impl: backend.Impl, native: backend.NativeWindow, x: f64, y: f64) Error!void {
    _ = .{ impl, native, x, y };
    return error.Unavailable;
}

const RelativeListener = extern struct {
    relative_motion: *const fn (
        ?*anyopaque,
        *Proxy,
        u32,
        u32,
        Fixed,
        Fixed,
        Fixed,
        Fixed,
    ) callconv(.c) void,
};

const relative_listener: RelativeListener = .{ .relative_motion = onRelativeMotion };

/// Motion with no cursor behind it, which is what a locked pointer reports.
///
/// The unaccelerated pair is used rather than the accelerated one: acceleration
/// is a curve meant to help a cursor land on a button, and it is exactly wrong
/// for aiming.
fn onRelativeMotion(
    data: ?*anyopaque,
    proxy: *Proxy,
    utime_hi: u32,
    utime_lo: u32,
    dx: Fixed,
    dy: Fixed,
    dx_unaccel: Fixed,
    dy_unaccel: Fixed,
) callconv(.c) void {
    _ = .{ proxy, utime_hi, utime_lo, dx, dy };
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = self.pointer_focus orelse return;
    // Without the lock in force the pointer passing over is not the camera's.
    if (!native.held) return;

    push(self, .{ .cursor = .{
        .window = native.id,
        .x = 0,
        .y = 0,
        .dx = fixedToDouble(dx_unaccel),
        .dy = fixedToDouble(dy_unaccel),
    } });
}

fn deinit(impl: backend.Impl, gpa: Allocator) void {
    const self = cast(impl);
    const w = self.w;

    // Before the wake pipe, which the dialog's thread writes to as it ends.
    if (self.dialog) |job| {
        job.cancel();
        job.destroy();
    }
    unexport(self);
    if (self.exporter) |exporter| requestDestroy(self, exporter, exporter_destroy);
    self.answers.deinit();

    if (self.cursor_surface) |surface| requestDestroy(self, surface, surface_destroy);
    if (self.theme) |theme| {
        if (self.wc) |wc| wc.wl_cursor_theme_destroy(theme);
    }
    if (self.cursor_lib) |*lib| lib.close();
    if (self.constraints) |p| w.wl_proxy_destroy(p);
    if (self.relative_manager) |p| w.wl_proxy_destroy(p);
    if (self.shm) |p| w.wl_proxy_destroy(p);

    if (self.new_offer) |offer| destroyOffer(self, offer);
    if (self.selection_offer) |offer| destroyOffer(self, offer);
    if (self.drag_offer) |offer| destroyOffer(self, offer);
    if (self.source) |source| requestDestroy(self, source, data_source_destroy);
    if (self.data_device) |device| {
        if (w.wl_proxy_get_version(device) >= 2) requestDestroy(self, device, data_device_release) else w.wl_proxy_destroy(device);
    }
    if (self.data_manager) |manager| w.wl_proxy_destroy(manager);
    self.clipboard_text.deinit(gpa);
    self.later.deinit(gpa);

    if (self.pointer) |p| requestDestroy(self, p, pointer_release);
    if (self.keyboard) |k| requestDestroy(self, k, keyboard_release);
    if (self.seat) |s| w.wl_proxy_destroy(s);
    if (self.wm_base) |b| requestDestroy(self, b, wm_base_destroy);
    if (self.compositor) |co| w.wl_proxy_destroy(co);
    for (self.outputs.items) |out| destroyOutput(self, out);
    self.outputs.deinit(gpa);
    self.pads.close_();
    self.xkb.close();
    self.gl.close();
    if (self.wl_egl_lib) |*lib| lib.close();
    if (self.registry) |r| w.wl_proxy_destroy(r);

    if (comptime has_display) {
        _ = c.close(self.wake[0]);
        _ = c.close(self.wake[1]);
    }
    self.windows.deinit(gpa);
    w.wl_display_disconnect(self.display);
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
// Listeners
//
// Each is an `extern struct` of function pointers in event order, which is
// exactly the array `wl_proxy_add_listener` expects. The order is the order in
// the protocol XML, and a wrong one calls the wrong handler with the wrong
// arguments.
// -------------------------------------------------------------------------

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, *Proxy, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
};

const registry_listener: RegistryListener = .{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

fn onGlobal(
    data: ?*anyopaque,
    registry: *Proxy,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const text = std.mem.span(interface);

    if (std.mem.eql(u8, text, "wl_compositor")) {
        self.compositor = bindGlobal(self, registry, name, self.core.wl_compositor_interface, @min(version, 4));
    } else if (std.mem.eql(u8, text, "xdg_wm_base")) {
        self.wm_base = bindGlobal(self, registry, name, &xdg_wm_base_interface, 1);
        if (self.wm_base) |base| {
            _ = self.w.wl_proxy_add_listener(base, &wm_base_listener, self);
        }
    } else if (std.mem.eql(u8, text, "wl_shm")) {
        self.shm = bindGlobal(self, registry, name, self.core.wl_shm_interface, 1);
    } else if (std.mem.eql(u8, text, "zwp_pointer_constraints_v1")) {
        self.constraints = bindGlobal(self, registry, name, &constraints_interface, 1);
    } else if (std.mem.eql(u8, text, "zwp_relative_pointer_manager_v1")) {
        self.relative_manager = bindGlobal(self, registry, name, &relative_manager_interface, 1);
    } else if (std.mem.eql(u8, text, "wl_output")) {
        addOutput(self, registry, name, version);
    } else if (std.mem.eql(u8, text, "wl_seat")) {
        self.seat = bindGlobal(self, registry, name, self.core.wl_seat_interface, @min(version, 5));
        if (self.seat) |seat| {
            _ = self.w.wl_proxy_add_listener(seat, &seat_listener, self);
        }
    } else if (std.mem.eql(u8, text, "wl_data_device_manager")) {
        self.data_manager = bindGlobal(self, registry, name, self.core.wl_data_device_manager_interface, @min(version, 3));
    } else if (std.mem.eql(u8, text, "zxdg_exporter_v2")) {
        self.exporter = bindGlobal(self, registry, name, &exporter_interface, 1);
    }
}

/// A global went away. For an output that means a monitor was unplugged, and
/// the entry has to go with it: a proxy for an object the compositor has
/// destroyed is not one to keep using.
fn onGlobalRemove(data: ?*anyopaque, registry: *Proxy, name: u32) callconv(.c) void {
    _ = registry;
    const self: *Impl = @ptrCast(@alignCast(data.?));

    for (self.outputs.items, 0..) |out, index| {
        if (out.global != name) continue;
        for (self.windows.values()) |native| forgetOutput(native, out.proxy);
        _ = self.outputs.orderedRemove(index);
        destroyOutput(self, out);
        return;
    }
}

/// `wl_registry.bind`, whose wire form carries the interface name and version
/// because its `new_id` argument has no interface of its own.
fn bindGlobal(
    self: *Impl,
    registry: *Proxy,
    name: u32,
    interface: *const WlInterface,
    version: u32,
) ?*Proxy {
    var args = [_]WlArgument{
        .{ .u = name },
        .{ .s = interface.name },
        .{ .u = version },
        .{ .n = 0 },
    };
    return construct(self, registry, registry_bind, interface, version, &args);
}

// -------------------------------------------------------------------------
// Monitors
// -------------------------------------------------------------------------

/// `wl_output`'s events, in wire order. Six of them as of wl_output version 4;
/// the last two arrived in libwayland 1.20 and are ignored here beyond taking
/// the name.
const OutputListener = extern struct {
    geometry: *const fn (
        ?*anyopaque,
        *Proxy,
        i32,
        i32,
        i32,
        i32,
        i32,
        [*:0]const u8,
        [*:0]const u8,
        i32,
    ) callconv(.c) void,
    mode: *const fn (?*anyopaque, *Proxy, u32, i32, i32, i32) callconv(.c) void,
    done: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
    scale: *const fn (?*anyopaque, *Proxy, i32) callconv(.c) void,
    name: *const fn (?*anyopaque, *Proxy, [*:0]const u8) callconv(.c) void,
    description: *const fn (?*anyopaque, *Proxy, [*:0]const u8) callconv(.c) void,
};

const output_listener: OutputListener = .{
    .geometry = onOutputGeometry,
    .mode = onOutputMode,
    .done = onOutputDone,
    .scale = onOutputScale,
    .name = onOutputName,
    .description = onOutputDescription,
};

/// `WL_OUTPUT_MODE_CURRENT`: the one the display is actually in. The rest are
/// what it could be switched to by something that is not this program.
const output_mode_current: u32 = 0x1;

fn addOutput(self: *Impl, registry: *Proxy, name: u32, version: u32) void {
    // Four is where `name` arrived. Asking for more than the compositor offers
    // is a protocol error, so it is capped by what was announced.
    const want = @min(version, 4);
    const proxy = bindGlobal(self, registry, name, self.core.wl_output_interface, want) orelse return;

    const out = self.gpa.create(Output) catch {
        self.push_failed = true;
        return;
    };
    out.* = .{ .proxy = proxy, .global = name, .impl = self };

    self.outputs.append(self.gpa, out) catch {
        self.gpa.destroy(out);
        self.push_failed = true;
        return;
    };

    // Only if the listener is the length the installed library expects. A
    // shorter one would have the library call past the end of it, which is a
    // crash rather than a missing feature.
    const events: usize = @intCast(self.core.wl_output_interface.event_count);
    if (events <= @typeInfo(OutputListener).@"struct".fields.len) {
        _ = self.w.wl_proxy_add_listener(proxy, &output_listener, out);
    }
}

fn destroyOutput(self: *Impl, out: *Output) void {
    // `release` from version 3; below that the proxy is simply let go.
    if (self.w.wl_proxy_get_version(out.proxy) >= 3) {
        requestDestroy(self, out.proxy, output_release);
    } else {
        self.w.wl_proxy_destroy(out.proxy);
    }
    out.modes.deinit(self.gpa);
    self.gpa.destroy(out);
}

fn onOutputGeometry(
    data: ?*anyopaque,
    proxy: *Proxy,
    x: i32,
    y: i32,
    physical_width: i32,
    physical_height: i32,
    subpixel: i32,
    make: [*:0]const u8,
    model: [*:0]const u8,
    transform: i32,
) callconv(.c) void {
    _ = .{ proxy, subpixel, transform };
    const out: *Output = @ptrCast(@alignCast(data.?));

    out.x = x;
    out.y = y;
    out.physical_width_mm = @intCast(@max(0, physical_width));
    out.physical_height_mm = @intCast(@max(0, physical_height));

    // The model is what a person would recognise; the connector name arrives
    // later on a compositor new enough to send it, and is better.
    if (out.name_len == 0) {
        const text = std.mem.span(model);
        if (text.len != 0) out.setName(text) else out.setName(std.mem.span(make));
    }
}

fn onOutputMode(data: ?*anyopaque, proxy: *Proxy, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void {
    _ = proxy;
    const out: *Output = @ptrCast(@alignCast(data.?));

    const mode: monitor.VideoMode = .{
        .width = @intCast(@max(0, width)),
        .height = @intCast(@max(0, height)),
        // Wayland has no per-mode depth to report.
        .bits = 0,
        // Millihertz on the wire, rounded to whole hertz here.
        .refresh_hz = @intFromFloat(@round(@as(f64, @floatFromInt(@max(0, refresh))) / 1000.0)),
    };

    if ((flags & output_mode_current) != 0) out.current = mode;

    for (out.modes.items) |existing| {
        if (std.meta.eql(existing, mode)) return;
    }
    out.modes.append(out.impl.gpa, mode) catch {
        out.impl.push_failed = true;
    };
}

fn onOutputDone(data: ?*anyopaque, proxy: *Proxy) callconv(.c) void {
    _ = proxy;
    const out: *Output = @ptrCast(@alignCast(data.?));
    out.ready = true;
}

fn onOutputScale(data: ?*anyopaque, proxy: *Proxy, factor: i32) callconv(.c) void {
    _ = proxy;
    const out: *Output = @ptrCast(@alignCast(data.?));
    if (factor > 0) out.scale = factor;
}

fn onOutputName(data: ?*anyopaque, proxy: *Proxy, name: [*:0]const u8) callconv(.c) void {
    _ = proxy;
    const out: *Output = @ptrCast(@alignCast(data.?));
    // The connector - `HDMI-A-1`, `eDP-1` - which is stable across reboots in
    // a way the model name is not.
    out.setName(std.mem.span(name));
}

fn onOutputDescription(data: ?*anyopaque, proxy: *Proxy, description: [*:0]const u8) callconv(.c) void {
    _ = .{ data, proxy, description };
}

fn enumerateMonitors(
    impl: backend.Impl,
    list: *std.ArrayListUnmanaged(monitor.Monitor),
    modes: *std.ArrayListUnmanaged(monitor.VideoMode),
    gpa: Allocator,
) Error!void {
    const self = cast(impl);

    // Anything the compositor has queued but not delivered - a monitor plugged
    // in a moment ago - arrives here rather than at the next pump.
    _ = self.w.wl_display_roundtrip(self.display);

    for (self.outputs.items) |out| {
        if (!out.ready) continue;

        // The protocol reports the position in logical units and the mode in
        // physical pixels; the two are the same number only at scale 1. Bounds
        // are logical throughout, because a position and a size that do not
        // share units cannot be compared.
        const scale: u32 = @intCast(@max(1, out.scale));
        var mon: monitor.Monitor = .{
            .bounds = .{
                .x = out.x,
                .y = out.y,
                .width = out.current.width / scale,
                .height = out.current.height / scale,
            },
            .physical_width_mm = out.physical_width_mm,
            .physical_height_mm = out.physical_height_mm,
            .scale_x = @floatFromInt(scale),
            .scale_y = @floatFromInt(scale),
            .current = out.current,
            // Wayland has no panels it will admit to and no work area to ask
            // for: a fullscreen surface covers the output, and that is the
            // only answer the protocol gives.
            .work_area = .{
                .x = out.x,
                .y = out.y,
                .width = out.current.width / scale,
                .height = out.current.height / scale,
            },
            // No output is the main one. The first announced is as close as
            // the protocol comes, and a compositor announces them in its own
            // order.
            .primary = list.items.len == 0,
        };
        mon.setName(out.name_buf[0..out.name_len]);

        mon.mode_start = modes.items.len;
        try modes.appendSlice(gpa, out.modes.items);
        mon.mode_count = modes.items.len - mon.mode_start;

        try list.append(gpa, mon);
    }
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
        request(self, win.toplevel, toplevel_unset_fullscreen, null);
        _ = self.w.wl_display_flush(self.display);

        // And the size is put back here rather than waited for. A compositor
        // is supposed to answer a state change with a configure; not all of
        // them do for a surface with no buffer yet, and a window that stayed
        // the size of the monitor after leaving fullscreen is worse than one
        // that resized a frame early.
        if (win.restore_width != 0) {
            const width = win.restore_width;
            const height = win.restore_height;
            win.restore_width = 0;
            win.restore_height = 0;
            applySize(self, win, width, height);
        }
        return;
    }

    // Nothing switches a monitor's mode on Wayland, by design: the compositor
    // owns the display and a client that wants different pixels renders fewer
    // of them and lets the compositor scale. There is no call to refuse with,
    // so it is refused here rather than quietly doing something else.
    if (wanted == .exclusive) return error.Unavailable;

    const mon = target orelse return error.Unavailable;
    const output = outputAt(self, mon) orelse return error.Unavailable;

    // Before the request, and only the first time: a window moved from one
    // monitor to another must not record the fullscreen size as its own.
    if (win.restore_width == 0) {
        win.restore_width = win.width;
        win.restore_height = win.height;
    }

    var args = [_]WlArgument{.{ .o = output }};
    request(self, win.toplevel, toplevel_set_fullscreen, &args);
    _ = self.w.wl_display_flush(self.display);
}

/// The `wl_output` a monitor came from, found by where it is - which is what
/// identifies an output in the compositor's own coordinates.
fn outputAt(self: *Impl, mon: *const monitor.Monitor) ?*Proxy {
    for (self.outputs.items) |out| {
        if (out.x == mon.bounds.x and out.y == mon.bounds.y) return out.proxy;
    }
    return null;
}

const WmBaseListener = extern struct {
    ping: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
};

const wm_base_listener: WmBaseListener = .{ .ping = onPing };

/// The compositor checking the client is alive. Not answering is how a window
/// gets the "application is not responding" treatment.
fn onPing(data: ?*anyopaque, base: *Proxy, serial: u32) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));
    var args = [_]WlArgument{.{ .u = serial }};
    request(self, base, wm_base_pong, &args);
}

const SeatListener = extern struct {
    capabilities: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
    name: *const fn (?*anyopaque, *Proxy, [*:0]const u8) callconv(.c) void,
};

const seat_listener: SeatListener = .{
    .capabilities = onSeatCapabilities,
    .name = onSeatName,
};

fn onSeatCapabilities(data: ?*anyopaque, seat: *Proxy, capabilities: u32) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));

    if (capabilities & seat_pointer != 0 and self.pointer == null) {
        var args = [_]WlArgument{.{ .n = 0 }};
        self.pointer = construct(
            self,
            seat,
            seat_get_pointer,
            self.core.wl_pointer_interface,
            self.w.wl_proxy_get_version(seat),
            &args,
        );
        if (self.pointer) |p| _ = self.w.wl_proxy_add_listener(p, &pointer_listener, self);
    }

    if (capabilities & seat_keyboard != 0 and self.keyboard == null) {
        var args = [_]WlArgument{.{ .n = 0 }};
        self.keyboard = construct(
            self,
            seat,
            seat_get_keyboard,
            self.core.wl_keyboard_interface,
            self.w.wl_proxy_get_version(seat),
            &args,
        );
        if (self.keyboard) |k| _ = self.w.wl_proxy_add_listener(k, &keyboard_listener, self);
    }
}

fn onSeatName(data: ?*anyopaque, seat: *Proxy, name: [*:0]const u8) callconv(.c) void {
    _ = .{ data, seat, name };
}

/// Eleven entries, because that is how many events the library's own
/// `wl_pointer_interface` declares. The ones past the version this client binds
/// never fire, and are stubs rather than absent because the dispatcher indexes
/// this array by opcode.
const PointerListener = extern struct {
    enter: *const fn (?*anyopaque, *Proxy, u32, *Proxy, Fixed, Fixed) callconv(.c) void,
    leave: *const fn (?*anyopaque, *Proxy, u32, *Proxy) callconv(.c) void,
    motion: *const fn (?*anyopaque, *Proxy, u32, Fixed, Fixed) callconv(.c) void,
    button: *const fn (?*anyopaque, *Proxy, u32, u32, u32, u32) callconv(.c) void,
    axis: *const fn (?*anyopaque, *Proxy, u32, u32, Fixed) callconv(.c) void,
    frame: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
    axis_source: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
    axis_stop: *const fn (?*anyopaque, *Proxy, u32, u32) callconv(.c) void,
    axis_discrete: *const fn (?*anyopaque, *Proxy, u32, i32) callconv(.c) void,
    axis_value120: *const fn (?*anyopaque, *Proxy, u32, i32) callconv(.c) void,
    axis_relative_direction: *const fn (?*anyopaque, *Proxy, u32, u32) callconv(.c) void,
};

const pointer_listener: PointerListener = .{
    .enter = onPointerEnter,
    .leave = onPointerLeave,
    .motion = onPointerMotion,
    .button = onPointerButton,
    .axis = onPointerAxis,
    .frame = ignore1,
    .axis_source = ignore2,
    .axis_stop = ignore3,
    .axis_discrete = ignore3i,
    .axis_value120 = ignore3i,
    .axis_relative_direction = ignore3,
};

fn ignore1(data: ?*anyopaque, proxy: *Proxy) callconv(.c) void {
    _ = .{ data, proxy };
}
fn ignore2(data: ?*anyopaque, proxy: *Proxy, a: u32) callconv(.c) void {
    _ = .{ data, proxy, a };
}
fn ignore3(data: ?*anyopaque, proxy: *Proxy, a: u32, b: u32) callconv(.c) void {
    _ = .{ data, proxy, a, b };
}
fn ignore3i(data: ?*anyopaque, proxy: *Proxy, a: u32, b: i32) callconv(.c) void {
    _ = .{ data, proxy, a, b };
}

fn onPointerEnter(
    data: ?*anyopaque,
    proxy: *Proxy,
    serial: u32,
    surface: *Proxy,
    x: Fixed,
    y: Fixed,
) callconv(.c) void {
    _ = proxy;
    const self: *Impl = @ptrCast(@alignCast(data.?));

    // Kept whatever the surface turns out to be: `set_cursor` needs the serial
    // of the last enter, and nothing else carries one.
    self.enter_serial = serial;
    self.input_serial = serial;

    const native = self.windows.get(@intFromPtr(surface)) orelse return;

    // A client must set a cursor on entering, or the pointer is left as
    // whatever the last program made it.
    if (pointerHidden(native)) hidePointer(self) else _ = showThemeCursor(self, native.shape);

    self.pointer_focus = native;
    native.last_x = fixedToDouble(x);
    native.last_y = fixedToDouble(y);
    native.has_position = true;

    push(self, .{ .cursor_enter = .{ .window = native.id, .value = true } });
}

fn onPointerLeave(data: ?*anyopaque, proxy: *Proxy, serial: u32, surface: *Proxy) callconv(.c) void {
    _ = .{ proxy, serial };
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = self.windows.get(@intFromPtr(surface)) orelse return;

    self.pointer_focus = null;
    native.has_position = false;
    push(self, .{ .cursor_enter = .{ .window = native.id, .value = false } });
}

fn onPointerMotion(data: ?*anyopaque, proxy: *Proxy, time: u32, x: Fixed, y: Fixed) callconv(.c) void {
    _ = .{ proxy, time };
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = self.pointer_focus orelse return;

    // While the pointer is locked the relative listener is the one reporting
    // movement; taking this as well would turn a camera at double speed.
    if (native.mode == .disabled) return;

    const px = fixedToDouble(x);
    const py = fixedToDouble(y);
    const dx = if (native.has_position) px - native.last_x else 0;
    const dy = if (native.has_position) py - native.last_y else 0;
    native.last_x = px;
    native.last_y = py;
    native.has_position = true;

    push(self, .{ .cursor = .{ .window = native.id, .x = px, .y = py, .dx = dx, .dy = dy } });
}

fn onPointerButton(
    data: ?*anyopaque,
    proxy: *Proxy,
    serial: u32,
    time: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    _ = .{ proxy, time };
    const self: *Impl = @ptrCast(@alignCast(data.?));
    self.input_serial = serial;
    const native = self.pointer_focus orelse return;

    push(self, .{ .mouse_button = .{
        .window = native.id,
        .button = switch (button) {
            btn_left => .left,
            btn_right => .right,
            btn_middle => .middle,
            btn_side => .button_4,
            btn_extra => .button_5,
            else => .left,
        },
        .action = if (state == state_released) .release else .press,
        .mods = self.mods,
        .x = native.last_x,
        .y = native.last_y,
    } });
}

fn onPointerAxis(data: ?*anyopaque, proxy: *Proxy, time: u32, axis: u32, value: Fixed) callconv(.c) void {
    _ = .{ proxy, time };
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = self.pointer_focus orelse return;

    const amount = scrollFromAxis(axis, fixedToDouble(value)) orelse return;
    push(self, .{ .scroll = .{
        .window = native.id,
        .x = amount[0],
        .y = amount[1],
        .mods = self.mods,
    } });
}

/// One `wl_pointer.axis` value as the notches `.scroll` counts, as `.{ x, y }`
/// with right and up positive - which is what every other backend reports.
///
/// Wayland measures an axis in surface units, in the same space as pointer
/// motion: x grows to the right and y grows downwards. So the horizontal axis
/// already means what `.scroll` means, and only the vertical one is turned
/// round. Negating both, as this once did, sent a sideways swipe the wrong way
/// on this backend alone. One notch is fifteen units, which is what turns
/// either back into the step a wheel means.
///
/// Null for an axis this backend has never heard of, which a later version of
/// the protocol could add and which is not a scroll it knows how to report.
fn scrollFromAxis(axis: u32, value: f64) ?[2]f64 {
    const notches = value / 15.0;
    return switch (axis) {
        axis_horizontal => .{ notches, 0 },
        axis_vertical => .{ 0, -notches },
        else => null,
    };
}

const KeyboardListener = extern struct {
    keymap: *const fn (?*anyopaque, *Proxy, u32, i32, u32) callconv(.c) void,
    enter: *const fn (?*anyopaque, *Proxy, u32, *Proxy, *WlArray) callconv(.c) void,
    leave: *const fn (?*anyopaque, *Proxy, u32, *Proxy) callconv(.c) void,
    key: *const fn (?*anyopaque, *Proxy, u32, u32, u32, u32) callconv(.c) void,
    modifiers: *const fn (?*anyopaque, *Proxy, u32, u32, u32, u32, u32) callconv(.c) void,
    repeat_info: *const fn (?*anyopaque, *Proxy, i32, i32) callconv(.c) void,
};

const keyboard_listener: KeyboardListener = .{
    .keymap = onKeymap,
    .enter = onKeyboardEnter,
    .leave = onKeyboardLeave,
    .key = onKey,
    .modifiers = onModifiers,
    .repeat_info = onRepeatInfo,
};

/// The layout, as a file descriptor onto an XKB keymap.
///
/// Keys are positions, taken from the evdev code the protocol already carries,
/// so the layout is not needed to know *which key* moved. It is needed to know
/// what that key would type, and this is the only place a Wayland client is
/// ever told: the compositor sends the keymap once and raw codes thereafter.
///
/// The descriptor is ours to close whatever happens, which is why it is closed
/// on every path out of here.
fn onKeymap(data: ?*anyopaque, proxy: *Proxy, format: u32, fd: i32, bytes: u32) callconv(.c) void {
    _ = proxy;
    if (comptime !has_display) return;
    defer _ = c.close(fd);

    const self: *Impl = @ptrCast(@alignCast(data.?));
    if (format != xkb.format_text_v1) return;
    if (bytes == 0) return;

    // Opened lazily: a program that never looks at `.char` still pays for the
    // library once a keyboard arrives, which is cheap enough, and a session
    // with no libxkbcommon simply types nothing.
    if (!self.xkb.available()) self.xkb = xkb.Backend.open();
    if (!self.xkb.available()) return;

    // Private, because the file is shared with every other client on the seat
    // and libxkbcommon is about to read it as a C string.
    const raw = mmap_c.mmap(null, bytes, prot_read, map_private, fd, 0) orelse return;
    if (@intFromPtr(raw) == map_failed) return;
    defer _ = mmap_c.munmap(raw, bytes);

    self.xkb.setKeymap(@ptrCast(raw));
}

fn onKeyboardEnter(
    data: ?*anyopaque,
    proxy: *Proxy,
    serial: u32,
    surface: *Proxy,
    pressed: *WlArray,
) callconv(.c) void {
    _ = .{ proxy, pressed };
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = self.windows.get(@intFromPtr(surface)) orelse return;

    self.input_serial = serial;
    self.keyboard_focus = native;
    push(self, .{ .focus = .{ .window = native.id, .value = true } });
}

fn onKeyboardLeave(data: ?*anyopaque, proxy: *Proxy, serial: u32, surface: *Proxy) callconv(.c) void {
    _ = .{ proxy, serial };
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = self.windows.get(@intFromPtr(surface)) orelse return;

    self.keyboard_focus = null;
    push(self, .{ .focus = .{ .window = native.id, .value = false } });
}

fn onKey(
    data: ?*anyopaque,
    proxy: *Proxy,
    serial: u32,
    time: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    _ = .{ proxy, time };
    const self: *Impl = @ptrCast(@alignCast(data.?));
    self.input_serial = serial;
    const native = self.keyboard_focus orelse return;

    // The kernel's own code, with no offset - unlike X11, which adds eight.
    // What the layout calls the key is libxkbcommon's to say as well; without
    // it the virtual key is the physical one.
    const physical = evdev.keyFromEvdev(key);
    push(self, .{ .key = .{
        .window = native.id,
        .key = physical,
        .virtual = virtual_key.fromTyped(physical, virtual_key.typedByKeysym(self.xkb.baseSym(key))),
        .scancode = @enumFromInt(key),
        .action = if (state == state_released) .release else .press,
        .mods = self.mods,
    } });

    // And what it typed, which on Wayland only libxkbcommon can say. A release
    // types nothing, and neither does a key that is part-way through a compose
    // sequence.
    if (state == state_released) return;
    const typed = self.xkb.keyText(key);
    var it = std.unicode.Utf8Iterator{ .bytes = typed.text, .i = 0 };
    while (it.nextCodepoint()) |codepoint| {
        // Control characters are the key event's business, not text.
        if (codepoint < 0x20 or codepoint == 0x7F) continue;
        push(self, .{ .char = .{
            .window = native.id,
            .codepoint = @intCast(codepoint),
            .mods = self.mods,
        } });
    }
}

/// The XKB modifier masks the compositor computed.
///
/// Handed to libxkbcommon, which is what makes shift and the layout group
/// change what a key types - without this every key types its unshifted
/// character forever.
///
/// The `Mods` this library reports are still read from the bit layout every
/// desktop keymap shares, rather than from the keymap itself. That is right for
/// the four modifiers a game binds and is an approximation for a keymap that
/// arranged them differently.
fn onModifiers(
    data: ?*anyopaque,
    proxy: *Proxy,
    serial: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    _ = .{ proxy, serial };
    const self: *Impl = @ptrCast(@alignCast(data.?));
    self.xkb.updateMods(depressed, latched, locked, group);
    self.mods = modsFromXkb(depressed, locked);
}

fn onRepeatInfo(data: ?*anyopaque, proxy: *Proxy, rate: i32, delay: i32) callconv(.c) void {
    _ = .{ data, proxy, rate, delay };
}

/// The first eight XKB modifier indices, which every keymap built from the
/// standard rules puts in the same order.
const xkb_shift: u32 = 1 << 0;
const xkb_lock: u32 = 1 << 1;
const xkb_control: u32 = 1 << 2;
const xkb_mod1: u32 = 1 << 3;
const xkb_mod2: u32 = 1 << 4;
const xkb_mod4: u32 = 1 << 6;
const xkb_mod5: u32 = 1 << 7;

fn modsFromXkb(depressed: u32, locked: u32) keys.Mods {
    return .{
        .shift = depressed & xkb_shift != 0,
        .control = depressed & xkb_control != 0,
        .alt = depressed & xkb_mod1 != 0,
        .super = depressed & xkb_mod4 != 0,
        .caps_lock = locked & xkb_lock != 0,
        .num_lock = locked & xkb_mod2 != 0,
        .alt_graph = depressed & xkb_mod5 != 0,
    };
}

const XdgSurfaceListener = extern struct {
    configure: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
};

const xdg_surface_listener: XdgSurfaceListener = .{ .configure = onXdgSurfaceConfigure };

/// The compositor has finished describing a new state, and this is the serial
/// that answers for all of it.
///
/// Everything `xdg_toplevel.configure` said arrives first and is only applied
/// here, because until the acknowledgement the two sides do not agree on what
/// the window is.
fn onXdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: *Proxy, serial: u32) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));

    var args = [_]WlArgument{.{ .u = serial }};
    request(self, xdg_surface, xdg_surface_ack_configure, &args);

    const native = findByXdgSurface(self, xdg_surface) orelse return;
    native.configured = true;
    if (native.pending_width == 0 or native.pending_height == 0) return;

    applySize(self, native, native.pending_width, native.pending_height);
}

/// Take a new size and tell the program about it, if it is new.
fn applySize(self: *Impl, native: *Native, width: u32, height: u32) void {
    if (width == native.width and height == native.height) return;
    native.width = width;
    native.height = height;
    native.pending_width = width;
    native.pending_height = height;
    push(self, .{ .framebuffer_resize = .{
        .window = native.id,
        .width = width,
        .height = height,
    } });
    push(self, .{ .resize = .{
        .window = native.id,
        .width = width,
        .height = height,
    } });
}

fn findByXdgSurface(self: *Impl, xdg_surface: *Proxy) ?*Native {
    var it = self.windows.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.xdg_surface == xdg_surface) return entry.value_ptr.*;
    }
    return null;
}

const ToplevelListener = extern struct {
    configure: *const fn (?*anyopaque, *Proxy, i32, i32, *WlArray) callconv(.c) void,
    close: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
};

const toplevel_listener: ToplevelListener = .{
    .configure = onToplevelConfigure,
    .close = onToplevelClose,
};

/// What size the compositor would like. Zero means "you decide", which is what
/// arrives the first time and whenever nothing constrains the window.
/// `xdg_toplevel.state`, from xdg-shell.xml.
const toplevel_state_maximized: u32 = 1;
const toplevel_state_fullscreen: u32 = 2;
const toplevel_state_activated: u32 = 4;

fn onToplevelConfigure(
    data: ?*anyopaque,
    toplevel: *Proxy,
    width: i32,
    height: i32,
    states: *WlArray,
) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = findByToplevel(self, toplevel) orelse return;

    // The state array is the whole truth: anything not in it is off. So the
    // flags are cleared first rather than only set.
    const was_fullscreen = native.fullscreen;
    const was_maximized = native.maximized;
    defer {
        if (native.maximized != was_maximized) push(self, .{ .maximize = .{ .window = native.id, .value = native.maximized } });
    }
    native.maximized = false;
    native.activated = false;
    native.fullscreen = false;
    if (states.data) |raw| {
        const count = states.size / @sizeOf(u32);
        const list: [*]const u32 = @ptrCast(@alignCast(raw));
        for (list[0..count]) |value| switch (value) {
            toplevel_state_maximized => native.maximized = true,
            toplevel_state_activated => native.activated = true,
            // The compositor's word, not ours: a keybinding or a tiling rule
            // can put a window fullscreen without this program asking.
            toplevel_state_fullscreen => native.fullscreen = true,
            else => {},
        };
    }

    if (was_fullscreen and !native.fullscreen and native.restore_width != 0) {
        // Came out of fullscreen without this program asking - a keybinding, a
        // tiling rule. The size named here is the fullscreen one, because the
        // compositor has no idea what the window was before, so the remembered
        // size wins over the hint.
        native.pending_width = native.restore_width;
        native.pending_height = native.restore_height;
        native.restore_width = 0;
        native.restore_height = 0;
    } else if (width > 0 and height > 0) {
        native.pending_width = @intCast(width);
        native.pending_height = @intCast(height);
    } else {
        // Keep what we have, and acknowledge it as ours.
        native.pending_width = native.width;
        native.pending_height = native.height;
    }
}

fn onToplevelClose(data: ?*anyopaque, toplevel: *Proxy) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = findByToplevel(self, toplevel) orelse return;
    push(self, .{ .close = native.id });
}

/// `wl_surface`'s events to version 6; the scale and transform hints are not used yet.
const SurfaceListener = extern struct {
    enter: *const fn (?*anyopaque, *Proxy, ?*Proxy) callconv(.c) void,
    leave: *const fn (?*anyopaque, *Proxy, ?*Proxy) callconv(.c) void,
    preferred_buffer_scale: *const fn (?*anyopaque, *Proxy, i32) callconv(.c) void,
    preferred_buffer_transform: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
};

const surface_listener: SurfaceListener = .{
    .enter = onSurfaceEnter,
    .leave = onSurfaceLeave,
    .preferred_buffer_scale = onSurfaceScale,
    .preferred_buffer_transform = onSurfaceTransform,
};

fn onSurfaceEnter(data: ?*anyopaque, surface: *Proxy, output: ?*Proxy) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = self.windows.get(@intFromPtr(surface)) orelse return;
    enterOutput(native, output orelse return);
}

fn enterOutput(native: *Native, output: *Proxy) void {
    forgetOutput(native, output);
    std.mem.copyForwards(?*Proxy, native.entered[0 .. native.entered.len - 1], native.entered[1..]);
    native.entered[native.entered.len - 1] = output;
}

fn onSurfaceLeave(data: ?*anyopaque, surface: *Proxy, output: ?*Proxy) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const native = self.windows.get(@intFromPtr(surface)) orelse return;
    forgetOutput(native, output orelse return);
}

fn onSurfaceScale(data: ?*anyopaque, surface: *Proxy, factor: i32) callconv(.c) void {
    _ = .{ data, surface, factor };
}

fn onSurfaceTransform(data: ?*anyopaque, surface: *Proxy, transform: u32) callconv(.c) void {
    _ = .{ data, surface, transform };
}

/// Keeps the rest in order and packed at the end, nulls first.
fn forgetOutput(native: *Native, output: *Proxy) void {
    var kept: usize = native.entered.len;
    var index: usize = native.entered.len;
    while (index > 0) {
        index -= 1;
        const one = native.entered[index] orelse continue;
        if (one == output) continue;
        kept -= 1;
        native.entered[kept] = one;
    }
    @memset(native.entered[0..kept], null);
}

/// The output the surface entered last, found in the list by where it is.
fn windowMonitor(impl: backend.Impl, native: backend.NativeWindow, list: []const monitor.Monitor) ?usize {
    const self = cast(impl);
    const win = castWindow(native);
    const latest = win.entered[win.entered.len - 1] orelse return null;
    for (self.outputs.items) |out| {
        if (out.proxy != latest) continue;
        for (list, 0..) |mon, index| {
            if (mon.bounds.x == out.x and mon.bounds.y == out.y) return index;
        }
    }
    return null;
}

fn findByToplevel(self: *Impl, toplevel: *Proxy) ?*Native {
    var it = self.windows.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.toplevel == toplevel) return entry.value_ptr.*;
    }
    return null;
}

/// Push, or remember there was no room. A listener cannot fail, so the failure
/// is carried to the end of `pump`.
fn push(self: *Impl, ev: event.Event) void {
    const queue = self.queue orelse return self.later.keep(self.gpa, ev);
    queue.push(ev) catch {
        self.push_failed = true;
    };
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
    const w = self.w;

    const native = gpa.create(Native) catch return error.OutOfMemory;
    errdefer gpa.destroy(native);

    var surface_args = [_]WlArgument{.{ .n = 0 }};
    const surface = construct(
        self,
        self.compositor.?,
        compositor_create_surface,
        self.core.wl_surface_interface,
        w.wl_proxy_get_version(self.compositor.?),
        &surface_args,
    ) orelse return error.WindowCreationFailed;
    errdefer w.wl_proxy_destroy(surface);

    var xdg_args = [_]WlArgument{ .{ .n = 0 }, .{ .o = surface } };
    const xdg_surface = construct(
        self,
        self.wm_base.?,
        wm_base_get_xdg_surface,
        &xdg_surface_interface,
        1,
        &xdg_args,
    ) orelse return error.WindowCreationFailed;
    errdefer w.wl_proxy_destroy(xdg_surface);

    var toplevel_args = [_]WlArgument{.{ .n = 0 }};
    const toplevel = construct(
        self,
        xdg_surface,
        xdg_surface_get_toplevel,
        &xdg_toplevel_interface,
        1,
        &toplevel_args,
    ) orelse return error.WindowCreationFailed;
    errdefer w.wl_proxy_destroy(toplevel);

    _ = w.wl_proxy_add_listener(xdg_surface, &xdg_surface_listener, self);
    _ = w.wl_proxy_add_listener(toplevel, &toplevel_listener, self);
    // Only as long as the installed library expects, as for `wl_output`.
    if (self.core.wl_surface_interface.event_count <= @typeInfo(SurfaceListener).@"struct".fields.len) {
        _ = w.wl_proxy_add_listener(surface, &surface_listener, self);
    }

    native.* = .{
        .surface = surface,
        .xdg_surface = xdg_surface,
        .toplevel = toplevel,
        .id = id,
        .impl = self,
        .width = desc.width,
        .height = desc.height,
    };
    self.windows.put(gpa, @intFromPtr(surface), native) catch return error.OutOfMemory;
    errdefer _ = self.windows.swapRemove(@intFromPtr(surface));

    try sendTitle(self, toplevel, desc.title);

    // The first commit with no buffer is what asks the compositor for a
    // configure. Nothing is on screen yet, and nothing can be until a renderer
    // attaches a buffer - which is the protocol, not a gap here.
    request(self, surface, surface_commit, null);
    _ = w.wl_display_flush(self.display);

    if (desc.gl) |config| try attachContext(self, native, config);

    return native;
}

/// Wrap the surface in a `wl_egl_window` and make a context on it.
///
/// The extra object is not ceremony: a `wl_surface` is a protocol handle with
/// no size, and EGL needs something it can allocate buffers for. That is what a
/// `wl_egl_window` is, and it is also what has to be told when the window
/// resizes - EGL has no way to find out on its own.
fn attachContext(self: *Impl, native: *Native, config: gl.Config) Error!void {
    // Opened on the first window that wants one rather than at startup: a
    // program that never asks for a context never pays for loading a driver,
    // and on a compositor session most programs never do.
    if (!self.gl.available()) self.gl = egl.Backend.open();
    if (!self.gl.available()) return error.Unavailable;

    if (self.we == null) {
        var lib = dyn.Library.openAny(wayland_egl_candidates) catch return error.Unavailable;
        const we = lib.bind(WaylandEgl) catch {
            lib.close();
            return error.Unavailable;
        };
        self.wl_egl_lib = lib;
        self.we = we;
    }
    const we = self.we.?;

    const display = try egl.connect(&self.gl, @ptrCast(self.display));
    const egl_config = try egl.chooseConfig(&self.gl, display, config);

    const egl_window = we.wl_egl_window_create(
        native.surface,
        @intCast(@max(1, native.width)),
        @intCast(@max(1, native.height)),
    ) orelse return error.Unavailable;
    errdefer we.wl_egl_window_destroy(egl_window);

    native.context = try egl.createContext(&self.gl, display, egl_config, egl_window, config);
    native.egl_window = egl_window;
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
    const win = castWindow(native);
    const context = win.context orelse return error.Unavailable;
    const display = self.gl.display orelse return error.Unavailable;

    // The buffer this swap produces is the one the compositor will show, so the
    // `wl_egl_window` has to already be the size the last configure asked for -
    // otherwise the frame goes up at the old size and the window flickers back
    // a frame later.
    if (self.we) |we| {
        if (win.egl_window) |egl_window| {
            we.wl_egl_window_resize(
                egl_window,
                @intCast(@max(1, win.width)),
                @intCast(@max(1, win.height)),
                0,
                0,
            );
        }
    }

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

// -------------------------------------------------------------------------
// Text input
// -------------------------------------------------------------------------

/// Remembered, and nothing more.
///
/// Turning text input on is what would enable `zwp_text_input_v3` - the
/// protocol that raises an on-screen keyboard and runs an input method - and
/// this backend does not speak it yet. Keys already produce text through
/// libxkbcommon either way, including dead keys and compose sequences, so a
/// program that only wanted Latin text loses nothing by this.
///
/// Not an error, because the thing a caller asked for - text arriving - does
/// happen. `setTextInputArea` is the one that refuses, because placing a
/// candidate window this backend cannot open would be a lie.
fn setTextInput(impl: backend.Impl, native: backend.NativeWindow, on: bool) Error!void {
    _ = impl;
    castWindow(native).text_input = on;
}

fn setTextInputArea(impl: backend.Impl, native: backend.NativeWindow, area: text_mod.Area) Error!void {
    _ = .{ impl, native, area };
    return error.Unavailable;
}

fn preedit(impl: backend.Impl) ?*const text_mod.Preedit {
    return &cast(impl).preedit;
}

// -------------------------------------------------------------------------
// The clipboard
//
// The compositor keeps no text either. A copy is a data source that offers
// types and writes its contents down a pipe whenever the compositor passes on
// a request; a paste is a data offer, which a program asks to write to a pipe
// of its own. The compositor says what the clipboard offers only to the
// program with the keyboard, and takes the clipboard only from that program.
// -------------------------------------------------------------------------

fn setClipboardText(impl: backend.Impl, text: []const u8) Error!void {
    const self = cast(impl);
    const manager = self.data_manager orelse return error.Unavailable;
    const device = self.data_device orelse return error.Unavailable;
    // The request has to name the last key or click, to prove the program
    // was being used.
    if (self.keyboard_focus == null or self.input_serial == 0) return error.Unavailable;

    self.clipboard_text.clearRetainingCapacity();
    try self.clipboard_text.appendSlice(self.gpa, text);

    var args = [_]WlArgument{.{ .n = 0 }};
    const source = construct(
        self,
        manager,
        data_device_manager_create_data_source,
        self.core.wl_data_source_interface,
        self.w.wl_proxy_get_version(manager),
        &args,
    ) orelse return error.Unavailable;
    _ = self.w.wl_proxy_add_listener(source, &data_source_listener, self);
    for (offered_types) |mime| {
        var offer = [_]WlArgument{.{ .s = mime.ptr }};
        request(self, source, data_source_offer, &offer);
    }
    var select = [_]WlArgument{ .{ .o = source }, .{ .u = self.input_serial } };
    request(self, device, data_device_set_selection, &select);

    // Replaced: left alive, it would be asked for the new text.
    if (self.source) |old| requestDestroy(self, old, data_source_destroy);
    self.source = source;
    _ = self.w.wl_display_flush(self.display);
}

fn clipboardText(impl: backend.Impl, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    const self = cast(impl);
    if (self.data_device == null) return error.Unavailable;
    // This program's own. Asked through the compositor, the request would
    // come back to a program busy waiting for its answer.
    if (self.source != null) return out.appendSlice(gpa, self.clipboard_text.items);
    const offer = self.selection_offer orelse return;
    const best = offer.text orelse return;
    try receive(self, offer.proxy, text_types[best], out, gpa);
}

fn hasClipboardText(impl: backend.Impl) bool {
    const self = cast(impl);
    if (self.source != null) return self.clipboard_text.items.len > 0;
    const offer = self.selection_offer orelse return false;
    return offer.text != null;
}

/// Wayland has no dialog of its own: the desktop's portal is asked, or zenity
/// or kdialog - see `linux_dialog`. The portal is told the window through
/// xdg-foreign, where the compositor has it, and is told nothing otherwise.
fn showFileDialog(impl: backend.Impl, gpa: Allocator, wanted: backend.DialogRequest) Error!void {
    if (comptime !has_display or builtin.single_threaded) return error.Unavailable;
    const self = cast(impl);
    if (self.dialog != null) return error.Unavailable;
    var parent: [300]u8 = undefined;
    const handle = if (wanted.owner) |native| exportWindow(self, castWindow(native), &parent) else "";
    self.dialog = linux_dialog.Dialog.start(gpa, wanted, handle, self.wake[1]) catch |err| {
        unexport(self);
        return err;
    };
}

/// `wayland:HANDLE`, or nothing where there is no handle to be had.
///
/// Waited for on a queue of its own: a roundtrip on the display's queue would
/// run every listener, outside a pump, where what they pushed would be lost.
fn exportWindow(self: *Impl, win: *Native, buffer: []u8) []const u8 {
    const exporter = self.exporter orelse return "";
    const create_queue = self.w.wl_display_create_queue orelse return "";
    const roundtrip = self.w.wl_display_roundtrip_queue orelse return "";
    const set_queue = self.w.wl_proxy_set_queue orelse return "";
    const destroy_queue = self.w.wl_event_queue_destroy orelse return "";

    const queue = create_queue(self.display) orelse return "";
    defer destroy_queue(queue);
    var args = [_]WlArgument{ .{ .n = 0 }, .{ .o = win.surface } };
    const exported = construct(self, exporter, exporter_export_toplevel, &exported_interface, 1, &args) orelse return "";
    set_queue(exported, queue);
    self.export_handle_len = 0;
    _ = self.w.wl_proxy_add_listener(exported, &exported_listener, self);
    const answered = roundtrip(self.display, queue) >= 0 and self.export_handle_len > 0;
    // Back on the display's queue before this one is destroyed under it.
    set_queue(exported, null);
    if (!answered) {
        requestDestroy(self, exported, exported_destroy);
        return "";
    }
    self.exported = exported;
    return std.fmt.bufPrint(buffer, "wayland:{s}", .{self.export_handle[0..self.export_handle_len]}) catch "";
}

fn unexport(self: *Impl) void {
    if (self.exported) |exported| requestDestroy(self, exported, exported_destroy);
    self.exported = null;
}

const ExportedListener = extern struct {
    handle: *const fn (?*anyopaque, *Proxy, [*:0]const u8) callconv(.c) void,
};

const exported_listener: ExportedListener = .{ .handle = onExportedHandle };

fn onExportedHandle(data: ?*anyopaque, proxy: *Proxy, handle: [*:0]const u8) callconv(.c) void {
    _ = proxy;
    const self: *Impl = @ptrCast(@alignCast(data.?));
    const text = std.mem.span(handle);
    if (text.len > self.export_handle.len) return;
    @memcpy(self.export_handle[0..text.len], text);
    self.export_handle_len = text.len;
}

fn chosenFile(impl: backend.Impl, index: usize, path: []const u8, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    _ = .{ impl, index };
    if (comptime !has_display) return error.Unavailable;
    return linux_dialog.readFile(path, out, gpa);
}

fn answerDialog(self: *Impl) void {
    const job = self.dialog orelse return;
    if (!job.finished()) return;
    self.dialog = null;
    defer job.destroy();
    unexport(self);
    const paths = job.paths(self.answers.allocator()) catch {
        self.push_failed = true;
        return;
    };
    push(self, .{ .file_dialog = .{ .window = job.request.window, .id = job.request.id, .paths = paths } });
}

/// Have the clipboard's owner write it down a pipe, and read until the owner
/// closes it - or until it goes quiet for longer than `clipboard.timeout_ms`,
/// which leaves nothing rather than half.
fn receive(self: *Impl, offer: *Proxy, mime: [:0]const u8, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) Error!void {
    if (comptime !has_display) return;
    var fds: [2]c_int = .{ -1, -1 };
    if (c.pipe(&fds) != 0) return error.Unavailable;
    defer _ = c.close(fds[0]);

    var args = [_]WlArgument{ .{ .s = mime.ptr }, .{ .h = fds[1] } };
    request(self, offer, data_offer_receive, &args);
    _ = self.w.wl_display_flush(self.display);
    // The request carried a copy. With this one closed, the pipe ends when the
    // owner's copy does.
    _ = c.close(fds[1]);

    const start = out.items.len;
    var chunk: [4096]u8 = undefined;
    while (true) {
        var ready = [_]Pollfd{.{ .fd = fds[0], .events = pollin, .revents = 0 }};
        const polled = c.poll(&ready, 1, clipboard.timeout_ms);
        if (polled < 0 and std.c.errno(polled) == .INTR) continue;
        if (polled <= 0) break;
        const n = c.read(fds[0], &chunk, chunk.len);
        if (n == 0) return;
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            break;
        }
        try out.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
    out.shrinkRetainingCapacity(start);
}

/// Write `bytes` down a pipe to the program pasting them, giving up if it
/// stops reading. SIGPIPE is ignored for the length of it: a reader that
/// closes its end early would otherwise end this process.
fn writeAll(fd: c_int, bytes: []const u8) void {
    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, &ignore, &previous);
    defer std.posix.sigaction(.PIPE, &previous, null);

    var sent: usize = 0;
    while (sent < bytes.len) {
        var ready = [_]Pollfd{.{ .fd = fd, .events = pollout, .revents = 0 }};
        const polled = c.poll(&ready, 1, clipboard.timeout_ms);
        if (polled < 0 and std.c.errno(polled) == .INTR) continue;
        if (polled <= 0) return;
        const n = c.write(fd, bytes[sent..].ptr, @min(bytes.len - sent, 4096));
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return;
        }
        sent += @intCast(n);
    }
}

fn destroyOffer(self: *Impl, offer: *Offer) void {
    requestDestroy(self, offer.proxy, data_offer_destroy);
    self.gpa.destroy(offer);
}

/// The offer a `data_offer` event introduced, found through its proxy.
fn offerOf(self: *Impl, proxy: ?*Proxy) ?*Offer {
    const named = proxy orelse return null;
    const raw = self.w.wl_proxy_get_user_data(named) orelse return null;
    const offer: *Offer = @ptrCast(@alignCast(raw));
    if (self.new_offer == offer) self.new_offer = null;
    return offer;
}

const DataDeviceListener = extern struct {
    data_offer: *const fn (?*anyopaque, *Proxy, *Proxy) callconv(.c) void,
    enter: *const fn (?*anyopaque, *Proxy, u32, ?*Proxy, Fixed, Fixed, ?*Proxy) callconv(.c) void,
    leave: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
    motion: *const fn (?*anyopaque, *Proxy, u32, Fixed, Fixed) callconv(.c) void,
    drop: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
    selection: *const fn (?*anyopaque, *Proxy, ?*Proxy) callconv(.c) void,
};

const data_device_listener: DataDeviceListener = .{
    .data_offer = onDataOffer,
    .enter = onDragEnter,
    .leave = onDragEnd,
    .motion = onDragMotion,
    .drop = onDragEnd,
    .selection = onSelection,
};

fn onDataOffer(data: ?*anyopaque, device: *Proxy, proxy: *Proxy) callconv(.c) void {
    _ = device;
    const self: *Impl = @ptrCast(@alignCast(data.?));
    if (self.new_offer) |unnamed| destroyOffer(self, unnamed);
    self.new_offer = null;

    const offer = self.gpa.create(Offer) catch {
        requestDestroy(self, proxy, data_offer_destroy);
        return;
    };
    offer.* = .{ .proxy = proxy };
    _ = self.w.wl_proxy_add_listener(proxy, &data_offer_listener, offer);
    self.new_offer = offer;
}

fn onSelection(data: ?*anyopaque, device: *Proxy, proxy: ?*Proxy) callconv(.c) void {
    _ = device;
    const self: *Impl = @ptrCast(@alignCast(data.?));
    if (self.selection_offer) |old| destroyOffer(self, old);
    self.selection_offer = offerOf(self, proxy);
}

/// A drag passing over a window. Nothing here accepts one yet, so its offer
/// is only kept to be let go of when the drag leaves or drops.
fn onDragEnter(
    data: ?*anyopaque,
    device: *Proxy,
    serial: u32,
    surface: ?*Proxy,
    x: Fixed,
    y: Fixed,
    proxy: ?*Proxy,
) callconv(.c) void {
    _ = .{ device, serial, surface, x, y };
    const self: *Impl = @ptrCast(@alignCast(data.?));
    if (self.drag_offer) |old| destroyOffer(self, old);
    self.drag_offer = offerOf(self, proxy);
}

fn onDragEnd(data: ?*anyopaque, device: *Proxy) callconv(.c) void {
    _ = device;
    const self: *Impl = @ptrCast(@alignCast(data.?));
    if (self.drag_offer) |old| destroyOffer(self, old);
    self.drag_offer = null;
}

fn onDragMotion(data: ?*anyopaque, device: *Proxy, time: u32, x: Fixed, y: Fixed) callconv(.c) void {
    _ = .{ data, device, time, x, y };
}

const DataOfferListener = extern struct {
    offer: *const fn (?*anyopaque, *Proxy, [*:0]const u8) callconv(.c) void,
    source_actions: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
    action: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
};

const data_offer_listener: DataOfferListener = .{
    .offer = onOfferType,
    .source_actions = ignore2,
    .action = ignore2,
};

fn onOfferType(data: ?*anyopaque, proxy: *Proxy, mime: [*:0]const u8) callconv(.c) void {
    _ = proxy;
    const offer: *Offer = @ptrCast(@alignCast(data.?));
    const name = std.mem.span(mime);
    for (text_types, 0..) |candidate, rank| {
        if (!std.mem.eql(u8, name, candidate)) continue;
        if (offer.text == null or rank < offer.text.?) offer.text = rank;
    }
}

const DataSourceListener = extern struct {
    target: *const fn (?*anyopaque, *Proxy, ?[*:0]const u8) callconv(.c) void,
    send: *const fn (?*anyopaque, *Proxy, [*:0]const u8, i32) callconv(.c) void,
    cancelled: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
    dnd_drop_performed: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
    dnd_finished: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
    action: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
};

const data_source_listener: DataSourceListener = .{
    .target = onSourceTarget,
    .send = onSourceSend,
    .cancelled = onSourceCancelled,
    .dnd_drop_performed = ignore1,
    .dnd_finished = ignore1,
    .action = ignore2,
};

fn onSourceTarget(data: ?*anyopaque, source: *Proxy, mime: ?[*:0]const u8) callconv(.c) void {
    _ = .{ data, source, mime };
}

/// Another program is pasting what this one copied.
fn onSourceSend(data: ?*anyopaque, source: *Proxy, mime: [*:0]const u8, fd: i32) callconv(.c) void {
    _ = mime;
    const self: *Impl = @ptrCast(@alignCast(data.?));
    defer _ = c.close(fd);
    if (self.source != source) return;
    writeAll(fd, self.clipboard_text.items);
}

/// Another program has taken the clipboard.
fn onSourceCancelled(data: ?*anyopaque, source: *Proxy) callconv(.c) void {
    const self: *Impl = @ptrCast(@alignCast(data.?));
    requestDestroy(self, source, data_source_destroy);
    if (self.source != source) return;
    self.source = null;
    self.clipboard_text.clearAndFree(self.gpa);
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
        *const vulkan.WaylandSurfaceCreateInfo,
        ?*const anyopaque,
        *u64,
    ) callconv(.c) i32 = @ptrCast(get_proc(instance, "vkCreateWaylandSurfaceKHR") orelse
        return error.Unavailable);

    const info: vulkan.WaylandSurfaceCreateInfo = .{
        .display = @ptrCast(self.display),
        .surface = @ptrCast(win.surface),
    };

    var surface: u64 = 0;
    if (create(instance, &info, allocator, &surface) != vulkan.success) {
        return error.Unavailable;
    }
    return surface;
}

fn sendTitle(self: *Impl, toplevel: *Proxy, title: []const u8) Error!void {
    const zeroed = self.gpa.dupeZ(u8, title) catch return error.OutOfMemory;
    defer self.gpa.free(zeroed);

    var args = [_]WlArgument{.{ .s = zeroed.ptr }};
    request(self, toplevel, toplevel_set_title, &args);

    // The app id is what a desktop matches against a `.desktop` file for the
    // icon and the taskbar grouping.
    var id_args = [_]WlArgument{.{ .s = zeroed.ptr }};
    request(self, toplevel, toplevel_set_app_id, &id_args);
}

fn destroyWindow(impl: backend.Impl, gpa: Allocator, native: backend.NativeWindow) void {
    const self = cast(impl);
    const win = castWindow(native);

    // The export names this surface, and goes before it does.
    if (self.dialog) |job| {
        if (job.request.window == win.id) {
            job.cancel();
            unexport(self);
        }
    }
    releaseConstraint(self, win);

    // The context and its surface first, then the `wl_egl_window`, then the
    // protocol objects underneath. Each layer holds the one below it, and
    // letting go in the other order hands the compositor a destroyed surface.
    if (win.context) |context| {
        if (self.gl.display) |display| egl.destroyContext(&self.gl, display, context);
    }
    if (win.egl_window) |egl_window| {
        if (self.we) |we| we.wl_egl_window_destroy(egl_window);
    }

    _ = self.windows.swapRemove(@intFromPtr(win.surface));
    if (self.pointer_focus == win) self.pointer_focus = null;
    if (self.keyboard_focus == win) self.keyboard_focus = null;

    // In order, innermost first: a toplevel outliving its surface is a protocol
    // error and the compositor drops the connection for it.
    requestDestroy(self, win.toplevel, toplevel_destroy);
    requestDestroy(self, win.xdg_surface, xdg_surface_destroy);
    requestDestroy(self, win.surface, surface_destroy);
    _ = self.w.wl_display_flush(self.display);

    gpa.destroy(win);
}

fn setTitle(impl: backend.Impl, native: backend.NativeWindow, title: []const u8) Error!void {
    const self = cast(impl);
    try sendTitle(self, castWindow(native).toplevel, title);
    _ = self.w.wl_display_flush(self.display);
}

/// Wayland has no hide: a surface is shown by attaching a buffer and hidden by
/// attaching none. Both are the renderer's business, so this backend has no
/// honest answer and says nothing rather than pretending.
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

/// One, until this backend reads `wl_output.scale`.
///
/// Wayland reports the scale per output rather than per window, and a surface
/// that spans two monitors is on both - so the honest answer needs the output
/// listener, and until then a program gets the size in pixels and a scale that
/// does not lie about being unknown.
fn contentScale(impl: backend.Impl, native: backend.NativeWindow) [2]f32 {
    _ = .{ impl, native };
    return .{ 1, 1 };
}

/// The `wl_surface`, which is what an EGL or Vulkan surface is made from.
fn nativeHandle(impl: backend.Impl, native: backend.NativeWindow) usize {
    _ = impl;
    return @intFromPtr(castWindow(native).surface);
}

/// Zero, always.
///
/// Wayland deliberately does not tell a client where its own window is: the
/// compositor places windows, and a client that knew could argue with it. Not a
/// gap to fill later - there is no call to make.
fn position(impl: backend.Impl, native: backend.NativeWindow) [2]i32 {
    _ = .{ impl, native };
    return .{ 0, 0 };
}

/// And for the same reason, a client cannot move itself.
fn setPosition(impl: backend.Impl, native: backend.NativeWindow, x: i32, y: i32) Error!void {
    _ = .{ impl, native, x, y };
    return error.Unavailable;
}

/// A client asks for a size by drawing one.
///
/// The compositor's `configure` is a suggestion and the buffer the program
/// attaches is the answer, so there is no request that sets a size. Recording
/// it is what makes the next `framebufferSize` agree with the program.
fn setSize(impl: backend.Impl, native: backend.NativeWindow, width: u32, height: u32) Error!void {
    _ = impl;
    const win = castWindow(native);
    win.width = @max(1, width);
    win.height = @max(1, height);
}

fn setState(impl: backend.Impl, native: backend.NativeWindow, wanted: backend.WindowState) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    switch (wanted) {
        .iconified => request(self, win.toplevel, toplevel_set_minimized, null),
        .maximized => request(self, win.toplevel, toplevel_set_maximized, null),
        .restored => request(self, win.toplevel, toplevel_unset_maximized, null),
        // Raising yourself is exactly what Wayland set out to prevent, and
        // without `xdg-activation` there is no protocol for asking either.
        .focused, .attention => return error.Unavailable,
    }
    _ = self.w.wl_display_flush(self.display);
}

/// From the states the last `configure` listed.
///
/// Wayland has no query: the compositor says what a window is when it changes,
/// and a client that wants to know remembers.
fn getState(impl: backend.Impl, native: backend.NativeWindow, which: backend.WindowState) bool {
    _ = impl;
    const win = castWindow(native);
    return switch (which) {
        .maximized => win.maximized,
        .focused => win.activated,
        .iconified => false,
        .restored => !win.maximized,
        .attention => false,
    };
}

fn setSizeLimits(impl: backend.Impl, native: backend.NativeWindow, limits: backend.SizeLimits) Error!void {
    const self = cast(impl);
    const win = castWindow(native);

    var min = [_]WlArgument{
        .{ .i = @intCast(limits.min_width) },
        .{ .i = @intCast(limits.min_height) },
    };
    request(self, win.toplevel, toplevel_set_min_size, &min);

    var max = [_]WlArgument{
        .{ .i = @intCast(limits.max_width) },
        .{ .i = @intCast(limits.max_height) },
    };
    request(self, win.toplevel, toplevel_set_max_size, &max);

    request(self, win.surface, surface_commit, null);
    _ = self.w.wl_display_flush(self.display);

    // A floating window's size is the client's to choose, so it is chosen here.
    if (win.maximized or win.fullscreen) return;
    const now: [2]u32 = .{ win.width, win.height };
    const inside = limits.clamp(now);
    if (!std.meta.eql(inside, now)) applySize(self, win, inside[0], inside[1]);
}

/// Transparency is in the pixels a program draws.
///
/// Wayland surfaces are composited with their alpha channel, so a program that
/// wants a see-through window draws one. There is no window-level setting.
fn setOpacity(impl: backend.Impl, native: backend.NativeWindow, opacity: f32) Error!void {
    _ = .{ impl, native, opacity };
    return error.Unavailable;
}

// -------------------------------------------------------------------------
// The event loop
// -------------------------------------------------------------------------

fn pump(impl: backend.Impl, queue: *backend.Queue) Error!void {
    const self = cast(impl);
    const w = self.w;

    if (comptime has_display) drainWake(self);

    self.queue = queue;
    self.push_failed = false;
    defer self.queue = null;

    // The last answer's paths were promised until now.
    _ = self.answers.reset(.retain_capacity);
    self.later.hand(queue) catch {
        self.push_failed = true;
    };
    answerDialog(self);

    // Anything already in the client's buffer, then whatever is on the socket.
    _ = w.wl_display_dispatch_pending(self.display);
    _ = w.wl_display_flush(self.display);

    if (comptime has_display) {
        // The read has to be announced before the socket is polled, or an event
        // that arrives in between is one this thread waits forever for.
        while (w.wl_display_prepare_read(self.display) != 0) {
            _ = w.wl_display_dispatch_pending(self.display);
        }

        var fds = [_]Pollfd{
            .{ .fd = w.wl_display_get_fd(self.display), .events = pollin, .revents = 0 },
        };
        if (c.poll(&fds, 1, 0) > 0) {
            _ = w.wl_display_read_events(self.display);
            _ = w.wl_display_dispatch_pending(self.display);
        } else {
            w.wl_display_cancel_read(self.display);
        }
    }

    if (self.push_failed) return error.OutOfMemory;
}

fn wait(impl: backend.Impl, timeout_ms: ?u32) Error!void {
    if (comptime !has_display) return;

    const self = cast(impl);
    _ = self.w.wl_display_flush(self.display);

    var fds = [_]Pollfd{
        .{ .fd = self.w.wl_display_get_fd(self.display), .events = pollin, .revents = 0 },
        .{ .fd = self.wake[0], .events = pollin, .revents = 0 },
    };
    const timeout: c_int = if (timeout_ms) |ms| @intCast(@min(ms, std.math.maxInt(c_int))) else -1;
    _ = c.poll(&fds, fds.len, timeout);
}

fn post(impl: backend.Impl) void {
    if (comptime !has_display) return;
    const self = cast(impl);
    const byte = [_]u8{0};
    _ = c.write(self.wake[1], &byte, 1);
}

fn drainWake(self: *Impl) void {
    var scratch: [64]u8 = undefined;
    var fds = [_]Pollfd{.{ .fd = self.wake[0], .events = pollin, .revents = 0 }};
    while (c.poll(&fds, 1, 0) > 0) {
        if (c.read(self.wake[0], &scratch, scratch.len) <= 0) return;
    }
}

// -------------------------------------------------------------------------
// Tests
//
// The protocol descriptors are ordinary data, so they are checked on any host.
// A wrong signature or a listener in the wrong order is not an error at run
// time - it is a message that means something else - and that deserves a test
// that runs everywhere rather than only where a compositor is.
// -------------------------------------------------------------------------

fn fakeCore() CoreInterfaces {
    const stub = struct {
        var iface: WlInterface = .{
            .name = "stub",
            .version = 1,
            .method_count = 0,
            .methods = null,
            .event_count = 0,
            .events = null,
        };
    };
    return .{
        .wl_registry_interface = &stub.iface,
        .wl_compositor_interface = &stub.iface,
        .wl_surface_interface = &stub.iface,
        .wl_seat_interface = &stub.iface,
        .wl_pointer_interface = &stub.iface,
        .wl_keyboard_interface = &stub.iface,
        .wl_output_interface = &stub.iface,
        .wl_region_interface = &stub.iface,
        .wl_shm_interface = &stub.iface,
        .wl_data_device_manager_interface = &stub.iface,
        .wl_data_device_interface = &stub.iface,
        .wl_data_source_interface = &stub.iface,
        .wl_data_offer_interface = &stub.iface,
    };
}

test "one wire argument is one word" {
    // Every `wl_argument` is at most a pointer wide, and the array form of
    // marshalling depends on it.
    try testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(WlArgument));
    try testing.expectEqual(@as(usize, 4), @sizeOf(Fixed));
}

test "the descriptor structs match libwayland's" {
    // Three pointers, and six fields with the ints between the pointers - which
    // is where padding could put them somewhere else.
    try testing.expectEqual(3 * @sizeOf(usize), @sizeOf(WlMessage));
    try testing.expectEqual(@as(usize, 0), @offsetOf(WlInterface, "name"));
    try testing.expectEqual(@sizeOf(usize), @offsetOf(WlInterface, "version"));
    try testing.expect(@offsetOf(WlInterface, "methods") > @offsetOf(WlInterface, "method_count"));
    try testing.expect(@offsetOf(WlInterface, "events") > @offsetOf(WlInterface, "event_count"));
}

test "fixed point is 24.8" {
    try testing.expectEqual(@as(f64, 1), fixedToDouble(256));
    try testing.expectEqual(@as(f64, 0.5), fixedToDouble(128));
    try testing.expectEqual(@as(f64, -1), fixedToDouble(-256));
    try testing.expectEqual(@as(f64, 0), fixedToDouble(0));
}

test "a scroll is right and up positive, as on every other backend" {
    // A notch to the right is already positive on the wire, like a pointer
    // moving right, and stays so. This is the half that used to be flipped.
    try testing.expectEqual([2]f64{ 1, 0 }, scrollFromAxis(axis_horizontal, 15).?);
    try testing.expectEqual([2]f64{ -1, 0 }, scrollFromAxis(axis_horizontal, -15).?);

    // A notch down is positive on the wire, like a pointer moving down, and
    // `.scroll` counts up as positive - so this half is turned round.
    try testing.expectEqual([2]f64{ 0, -1 }, scrollFromAxis(axis_vertical, 15).?);
    try testing.expectEqual([2]f64{ 0, 1 }, scrollFromAxis(axis_vertical, -15).?);

    // A trackpad's glide is a fraction of a notch, not a whole one.
    try testing.expectApproxEqAbs(@as(f64, 0.2), scrollFromAxis(axis_horizontal, 3).?[0], 1e-9);

    // And an axis the protocol does not have yet is not a scroll.
    try testing.expectEqual(@as(?[2]f64, null), scrollFromAxis(2, 15));
}

test "the hand-written xdg descriptors match the protocol" {
    buildXdgInterfaces(fakeCore());

    // Counts, from xdg-shell.xml at version 1.
    try testing.expectEqualStrings("xdg_wm_base", std.mem.span(xdg_wm_base_interface.name));
    try testing.expectEqual(@as(c_int, 4), xdg_wm_base_interface.method_count);
    try testing.expectEqual(@as(c_int, 1), xdg_wm_base_interface.event_count);

    try testing.expectEqual(@as(c_int, 5), xdg_surface_interface.method_count);
    try testing.expectEqual(@as(c_int, 1), xdg_surface_interface.event_count);

    try testing.expectEqual(@as(c_int, 14), xdg_toplevel_interface.method_count);
    try testing.expectEqual(@as(c_int, 2), xdg_toplevel_interface.event_count);

    try testing.expectEqual(@as(c_int, 7), xdg_positioner_interface.method_count);
    try testing.expectEqual(@as(c_int, 0), xdg_positioner_interface.event_count);
}

test "the opcodes name the messages they are used for" {
    buildXdgInterfaces(fakeCore());

    // A wrong opcode sends a well-formed message that means something else, so
    // each constant is checked against the name at that index.
    const base = xdg_wm_base_interface.methods.?;
    try testing.expectEqualStrings("get_xdg_surface", std.mem.span(base[wm_base_get_xdg_surface].name));
    try testing.expectEqualStrings("pong", std.mem.span(base[wm_base_pong].name));
    try testing.expectEqualStrings("destroy", std.mem.span(base[wm_base_destroy].name));

    const surf = xdg_surface_interface.methods.?;
    try testing.expectEqualStrings("get_toplevel", std.mem.span(surf[xdg_surface_get_toplevel].name));
    try testing.expectEqualStrings("ack_configure", std.mem.span(surf[xdg_surface_ack_configure].name));
    try testing.expectEqualStrings("destroy", std.mem.span(surf[xdg_surface_destroy].name));

    const top = xdg_toplevel_interface.methods.?;
    try testing.expectEqualStrings("set_title", std.mem.span(top[toplevel_set_title].name));
    try testing.expectEqualStrings("set_app_id", std.mem.span(top[toplevel_set_app_id].name));
    try testing.expectEqualStrings("destroy", std.mem.span(top[toplevel_destroy].name));

    // And the events, whose order is the listener's order.
    const top_events = xdg_toplevel_interface.events.?;
    try testing.expectEqualStrings("configure", std.mem.span(top_events[0].name));
    try testing.expectEqualStrings("close", std.mem.span(top_events[1].name));
}

test "the signatures are the ones on the wire" {
    buildXdgInterfaces(fakeCore());

    const base = xdg_wm_base_interface.methods.?;
    try testing.expectEqualStrings("no", std.mem.span(base[wm_base_get_xdg_surface].signature));
    try testing.expectEqualStrings("u", std.mem.span(base[wm_base_pong].signature));

    const surf = xdg_surface_interface.methods.?;
    try testing.expectEqualStrings("n", std.mem.span(surf[xdg_surface_get_toplevel].signature));

    const top = xdg_toplevel_interface.methods.?;
    try testing.expectEqualStrings("s", std.mem.span(top[toplevel_set_title].signature));

    // `iia`: two ints and the state array.
    try testing.expectEqualStrings("iia", std.mem.span(xdg_toplevel_interface.events.?[0].signature));
    try testing.expectEqualStrings("", std.mem.span(xdg_toplevel_interface.events.?[1].signature));
}

test "an object argument carries the interface it has to be" {
    const core = fakeCore();
    buildXdgInterfaces(core);

    // `get_xdg_surface` takes a new xdg_surface and an existing wl_surface, and
    // the second has to point at the core descriptor the library exported.
    const types = xdg_wm_base_interface.methods.?[wm_base_get_xdg_surface].types;
    try testing.expectEqual(@as(?*const WlInterface, &xdg_surface_interface), types[0]);
    try testing.expectEqual(@as(?*const WlInterface, core.wl_surface_interface), types[1]);

    // `get_toplevel` makes an xdg_toplevel and takes nothing else.
    const toplevel_types = xdg_surface_interface.methods.?[xdg_surface_get_toplevel].types;
    try testing.expectEqual(@as(?*const WlInterface, &xdg_toplevel_interface), toplevel_types[0]);
}

test "a listener is one function pointer per event, in order" {
    // The array `wl_proxy_add_listener` is handed has to be exactly as long as
    // the interface says there are events.
    buildXdgInterfaces(fakeCore());

    try testing.expectEqual(
        @as(usize, @intCast(xdg_toplevel_interface.event_count)),
        @typeInfo(ToplevelListener).@"struct".fields.len,
    );
    try testing.expectEqual(
        @as(usize, @intCast(xdg_surface_interface.event_count)),
        @typeInfo(XdgSurfaceListener).@"struct".fields.len,
    );
    try testing.expectEqual(
        @as(usize, @intCast(xdg_wm_base_interface.event_count)),
        @typeInfo(WmBaseListener).@"struct".fields.len,
    );

    // The core ones are the library's own descriptors, so their lengths come
    // from wayland.xml rather than from anything here.
    try testing.expectEqual(@as(usize, 2), @typeInfo(RegistryListener).@"struct".fields.len);
    try testing.expectEqual(@as(usize, 2), @typeInfo(SeatListener).@"struct".fields.len);
    try testing.expectEqual(@as(usize, 6), @typeInfo(KeyboardListener).@"struct".fields.len);
    try testing.expectEqual(@as(usize, 11), @typeInfo(PointerListener).@"struct".fields.len);
    try testing.expectEqual(@as(usize, 6), @typeInfo(DataDeviceListener).@"struct".fields.len);
    try testing.expectEqual(@as(usize, 3), @typeInfo(DataOfferListener).@"struct".fields.len);
    try testing.expectEqual(@as(usize, 6), @typeInfo(DataSourceListener).@"struct".fields.len);
    try testing.expectEqual(@as(usize, 4), @typeInfo(SurfaceListener).@"struct".fields.len);
    buildPointerInterfaces(fakeCore());
    try testing.expectEqual(
        @as(usize, @intCast(locked_pointer_interface.event_count)),
        @typeInfo(LockedListener).@"struct".fields.len,
    );

    // And every entry is a pointer, so the struct is the flat array C expects.
    inline for (@typeInfo(PointerListener).@"struct".fields) |field| {
        try testing.expectEqual(@sizeOf(usize), @sizeOf(field.type));
    }
}

fn fakeNative(self: *Impl, toplevel: *Proxy) Native {
    return .{
        .surface = @ptrFromInt(0x1000),
        .xdg_surface = @ptrFromInt(0x2000),
        .toplevel = toplevel,
        .id = @enumFromInt(5),
        .impl = self,
        .width = 640,
        .height = 480,
    };
}

test "the outputs a surface is on are kept latest last, and one that goes is forgotten" {
    var self: Impl = undefined;
    var native = fakeNative(&self, @ptrFromInt(0x3000));
    const left: *Proxy = @ptrFromInt(0x10);
    const right: *Proxy = @ptrFromInt(0x20);
    const third: *Proxy = @ptrFromInt(0x30);

    enterOutput(&native, left);
    enterOutput(&native, right);
    try testing.expectEqual(@as(?*Proxy, right), native.entered[native.entered.len - 1]);

    enterOutput(&native, left);
    try testing.expectEqual(@as(?*Proxy, left), native.entered[native.entered.len - 1]);
    try testing.expectEqual(@as(?*Proxy, right), native.entered[native.entered.len - 2]);

    forgetOutput(&native, left);
    try testing.expectEqual(@as(?*Proxy, right), native.entered[native.entered.len - 1]);
    forgetOutput(&native, third);
    forgetOutput(&native, right);
    try testing.expectEqual(@as(?*Proxy, null), native.entered[native.entered.len - 1]);

    for (0..10) |i| enterOutput(&native, @ptrFromInt(0x100 + 0x10 * i));
    try testing.expectEqual(@as(?*Proxy, @ptrFromInt(0x190)), native.entered[native.entered.len - 1]);
    try testing.expectEqual(@as(?*Proxy, @ptrFromInt(0x160)), native.entered[0]);
}

test "the compositor maximising and restoring the window comes out as events" {
    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    var self: Impl = undefined;
    self.gpa = testing.allocator;
    self.windows = .empty;
    self.queue = &queue;
    self.later = .{};
    self.push_failed = false;
    defer self.windows.deinit(testing.allocator);

    const toplevel: *Proxy = @ptrFromInt(0x3000);
    var native = fakeNative(&self, toplevel);
    try self.windows.put(testing.allocator, @intFromPtr(native.surface), &native);

    var states = [_]u32{ toplevel_state_maximized, toplevel_state_activated };
    var maximized: WlArray = .{ .size = @sizeOf(@TypeOf(states)), .alloc = 0, .data = &states };
    onToplevelConfigure(&self, toplevel, 1280, 720, &maximized);
    try testing.expectEqual(event.Event{ .maximize = .{ .window = native.id, .value = true } }, queue.next().?);
    try testing.expect(native.maximized and native.activated);

    onToplevelConfigure(&self, toplevel, 1280, 720, &maximized);
    try testing.expectEqual(@as(?event.Event, null), queue.next());

    var none: WlArray = .{ .size = 0, .alloc = 0, .data = null };
    onToplevelConfigure(&self, toplevel, 0, 0, &none);
    try testing.expectEqual(event.Event{ .maximize = .{ .window = native.id, .value = false } }, queue.next().?);
    try testing.expectEqual(@as(?event.Event, null), queue.next());
}

test "the clipboard's opcodes name the messages they are used for" {
    var lib = dyn.Library.openAny(candidates) catch return error.SkipZigTest;
    defer lib.close();
    const core = CoreInterfaces.load(&lib) orelse return error.SkipZigTest;

    const Name = struct {
        fn of(interface: *const WlInterface, opcode: u32) []const u8 {
            return std.mem.span(interface.methods.?[opcode].name);
        }
    };
    try testing.expectEqualStrings("create_data_source", Name.of(core.wl_data_device_manager_interface, data_device_manager_create_data_source));
    try testing.expectEqualStrings("get_data_device", Name.of(core.wl_data_device_manager_interface, data_device_manager_get_data_device));
    try testing.expectEqualStrings("set_selection", Name.of(core.wl_data_device_interface, data_device_set_selection));
    try testing.expectEqualStrings("release", Name.of(core.wl_data_device_interface, data_device_release));
    try testing.expectEqualStrings("offer", Name.of(core.wl_data_source_interface, data_source_offer));
    try testing.expectEqualStrings("destroy", Name.of(core.wl_data_source_interface, data_source_destroy));
    try testing.expectEqualStrings("receive", Name.of(core.wl_data_offer_interface, data_offer_receive));
    try testing.expectEqualStrings("destroy", Name.of(core.wl_data_offer_interface, data_offer_destroy));

    try testing.expectEqualStrings("?ou", std.mem.span(core.wl_data_device_interface.methods.?[data_device_set_selection].signature));
    try testing.expectEqualStrings("sh", std.mem.span(core.wl_data_offer_interface.methods.?[data_offer_receive].signature));
    try testing.expectEqualStrings("selection", std.mem.span(core.wl_data_device_interface.events.?[5].name));
    try testing.expectEqualStrings("send", std.mem.span(core.wl_data_source_interface.events.?[1].name));
}

test "keys are evdev codes with no offset, unlike X11" {
    // The one thing Wayland makes simpler: the kernel's code arrives as it is.
    try testing.expectEqual(keys.Key.w, evdev.keyFromEvdev(17));
    try testing.expectEqual(keys.Key.a, evdev.keyFromEvdev(30));
    try testing.expectEqual(keys.Key.escape, evdev.keyFromEvdev(1));
    try testing.expectEqual(keys.Key.space, evdev.keyFromEvdev(57));
}

test "modifier masks map onto the same bits everywhere" {
    try testing.expectEqual(keys.Mods{ .shift = true }, modsFromXkb(xkb_shift, 0));
    try testing.expectEqual(keys.Mods{ .control = true }, modsFromXkb(xkb_control, 0));
    try testing.expectEqual(keys.Mods{ .alt = true }, modsFromXkb(xkb_mod1, 0));
    try testing.expectEqual(keys.Mods{ .super = true }, modsFromXkb(xkb_mod4, 0));
    // The locks are read from the locked mask, not the depressed one.
    try testing.expectEqual(keys.Mods{ .caps_lock = true }, modsFromXkb(0, xkb_lock));
    try testing.expectEqual(keys.Mods{ .num_lock = true }, modsFromXkb(0, xkb_mod2));
    try testing.expectEqual(keys.Mods{ .alt_graph = true }, modsFromXkb(xkb_mod5, 0));
    try testing.expectEqual(keys.Mods.none, modsFromXkb(0, 0));
}

test "a window completes the xdg-shell handshake with a real compositor" {
    // The end-to-end check for this backend. Reaching `configured` means every
    // step worked: the registry listed the globals, `xdg_wm_base` and
    // `wl_compositor` bound, a surface and an xdg_surface and a toplevel were
    // constructed with the right opcodes and signatures, the opening commit
    // went out, the compositor answered, and the listener fired at the right
    // index with the serial this code then acknowledged.
    //
    // A wrong opcode or a listener in the wrong order does not get here.
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);

    const native = try vtable.createWindow(impl, testing.allocator, @enumFromInt(7), .{
        .title = "fluxion-platform handshake test",
        .width = 320,
        .height = 240,
        .resizable = true,
        .decorated = true,
        .visible = true,
        .maximized = false,
        .gl = null,
    });
    defer vtable.destroyWindow(impl, testing.allocator, native);

    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();

    var tries: usize = 0;
    while (tries < 100 and !castWindow(native).configured) : (tries += 1) {
        try vtable.pump(impl, &queue);
        if (castWindow(native).configured) break;
        try vtable.wait(impl, 50);
    }

    try testing.expect(castWindow(native).configured);
}

test "the wake pipe stops a wait that has nothing to wait for" {
    const impl = open(testing.allocator) catch return error.SkipZigTest;
    defer vtable.deinit(impl, testing.allocator);

    vtable.post(impl);
    try vtable.wait(impl, 5_000);

    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);
}

test "opening without a compositor says so rather than failing to build" {
    const impl = open(testing.allocator) catch |err| {
        try testing.expect(err == error.NoDisplay or err == error.Unsupported or
            err == error.ConnectionFailed);
        return;
    };
    defer vtable.deinit(impl, testing.allocator);

    try testing.expectEqual(platform.Backend.wayland, vtable.backend);

    var queue: backend.Queue = .init(testing.allocator);
    defer queue.deinit();
    try vtable.pump(impl, &queue);
}
