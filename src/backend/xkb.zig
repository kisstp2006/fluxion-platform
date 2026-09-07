// SPDX-License-Identifier: BSL-1.0

//! Turning Wayland's keycodes into text, through libxkbcommon.
//!
//! **A Wayland compositor sends no text.** It sends a keymap once, as a file
//! descriptor onto an XKB layout, and after that only raw evdev codes. Working
//! out that shift-2 is `"` on a British layout and `@` on an American one is the
//! client's job, and libxkbcommon is the library that does it. There is no
//! alternative and no fallback: a Wayland backend that does not link this
//! produces no `.char` events at all.
//!
//! That is a change from X11, where the server has always done the translation
//! and `XLookupString` was there from the start.
//!
//! **Compose is separate from the keymap.** Dead keys and the compose key are a
//! second table, loaded from the locale, and a keystroke goes through it before
//! it becomes text: `´` then `e` is one `é` rather than two characters. It is
//! optional - a locale with no compose file simply has none - and a session
//! without it still types.
//!
//! **Not an input method.** Composing Japanese needs
//! `zwp_text_input_v3`, a protocol this file does not speak, and a compositor
//! that does. What is here covers every Latin, Cyrillic and Greek layout,
//! dead keys and compose sequences, which is what most programs mean by text.

const std = @import("std");

const dyn = @import("fluxion_dyn");

pub const Context = opaque {};
pub const Keymap = opaque {};
pub const State = opaque {};
pub const ComposeTable = opaque {};
pub const ComposeState = opaque {};

/// `XKB_KEYMAP_FORMAT_TEXT_V1`, the only format a compositor sends.
pub const format_text_v1: u32 = 1;
const compile_no_flags: u32 = 0;
const keymap_compile_no_flags: u32 = 0;
const compose_compile_no_flags: u32 = 0;
const compose_state_no_flags: u32 = 0;

/// `xkb_state_component`, the four groups of modifier state a compositor sends
/// separately.
const state_mods_depressed: u32 = 1 << 0;
const state_mods_latched: u32 = 1 << 1;
const state_mods_locked: u32 = 1 << 2;
const state_layout_effective: u32 = 1 << 7;

/// `xkb_compose_status`.
pub const compose_nothing: u32 = 0;
pub const compose_composing: u32 = 1;
pub const compose_composed: u32 = 2;
pub const compose_cancelled: u32 = 3;

/// `xkb_compose_feed_result`.
const compose_feed_ignored: u32 = 0;
const compose_feed_accepted: u32 = 1;

const Xkb = struct {
    xkb_context_new: *const fn (u32) callconv(.c) ?*Context,
    xkb_context_unref: *const fn (*Context) callconv(.c) void,
    xkb_keymap_new_from_string: *const fn (*Context, [*:0]const u8, u32, u32) callconv(.c) ?*Keymap,
    xkb_keymap_unref: *const fn (*Keymap) callconv(.c) void,
    xkb_state_new: *const fn (*Keymap) callconv(.c) ?*State,
    xkb_state_unref: *const fn (*State) callconv(.c) void,
    xkb_state_update_mask: *const fn (*State, u32, u32, u32, u32, u32, u32) callconv(.c) u32,
    /// The text one key produces, in UTF-8, given everything held down.
    xkb_state_key_get_utf8: *const fn (*State, u32, [*]u8, usize) callconv(.c) c_int,
    xkb_state_key_get_one_sym: *const fn (*State, u32) callconv(.c) u32,

    /// Compose. Optional as a group: a locale with no compose file has none,
    /// and then a dead key is simply a key that types nothing.
    xkb_compose_table_new_from_locale: ?*const fn (*Context, [*:0]const u8, u32) callconv(.c) ?*ComposeTable = null,
    xkb_compose_table_unref: ?*const fn (*ComposeTable) callconv(.c) void = null,
    xkb_compose_state_new: ?*const fn (*ComposeTable, u32) callconv(.c) ?*ComposeState = null,
    xkb_compose_state_unref: ?*const fn (*ComposeState) callconv(.c) void = null,
    xkb_compose_state_feed: ?*const fn (*ComposeState, u32) callconv(.c) u32 = null,
    xkb_compose_state_get_status: ?*const fn (*ComposeState) callconv(.c) u32 = null,
    xkb_compose_state_get_utf8: ?*const fn (*ComposeState, [*]u8, usize) callconv(.c) c_int = null,
    xkb_compose_state_reset: ?*const fn (*ComposeState) callconv(.c) void = null,
};

const candidates: []const [:0]const u8 = &.{
    "libxkbcommon.so.0",
    "libxkbcommon.so",
};

/// What one keystroke produced.
pub const Typed = struct {
    /// The text, or empty where the key produced none - a modifier, a function
    /// key, or a dead key that is still waiting for the next one.
    text: []const u8 = &.{},
    /// True while a compose sequence is part-way through. The program has
    /// typed something and nothing has appeared yet, which is correct and is
    /// worth being able to tell from a key that did nothing.
    composing: bool = false,
};

pub const Backend = struct {
    lib: ?dyn.Library = null,
    x: ?Xkb = null,
    context: ?*Context = null,
    keymap: ?*Keymap = null,
    state: ?*State = null,
    compose_table: ?*ComposeTable = null,
    compose: ?*ComposeState = null,

    /// One keystroke's worth. Long enough for any single character and the
    /// longest compose result, which is a handful of bytes.
    buf: [64]u8 = undefined,

    pub fn open() Backend {
        var self: Backend = .{};

        var lib = dyn.Library.openAny(candidates) catch return self;
        const x = lib.bind(Xkb) catch {
            lib.close();
            return self;
        };
        const context = x.xkb_context_new(compile_no_flags) orelse {
            lib.close();
            return self;
        };

        self.lib = lib;
        self.x = x;
        self.context = context;
        self.openCompose();
        return self;
    }

    /// Load the compose table for the user's locale.
    ///
    /// Best-effort in every direction: the library may be too old to have the
    /// calls, the locale may have no compose file, and neither is a reason for
    /// text input not to work. A session without it just has no dead keys.
    fn openCompose(self: *Backend) void {
        const x = self.x orelse return;
        const context = self.context orelse return;

        const new_table = x.xkb_compose_table_new_from_locale orelse return;
        const new_state = x.xkb_compose_state_new orelse return;

        // The compose file is chosen by locale, and the environment is where
        // the locale lives. `LC_ALL` wins, then `LC_CTYPE`, then `LANG` - the
        // order the C library itself uses.
        const locale = firstEnv(&.{ "LC_ALL", "LC_CTYPE", "LANG" }) orelse "C";

        const table = new_table(context, locale, compose_compile_no_flags) orelse return;
        const state = new_state(table, compose_state_no_flags) orelse {
            if (x.xkb_compose_table_unref) |unref| unref(table);
            return;
        };
        self.compose_table = table;
        self.compose = state;
    }

    pub fn close(self: *Backend) void {
        if (self.x) |x| {
            if (self.compose) |state| {
                if (x.xkb_compose_state_unref) |unref| unref(state);
            }
            if (self.compose_table) |table| {
                if (x.xkb_compose_table_unref) |unref| unref(table);
            }
            if (self.state) |state| x.xkb_state_unref(state);
            if (self.keymap) |keymap| x.xkb_keymap_unref(keymap);
            if (self.context) |context| x.xkb_context_unref(context);
        }
        if (self.lib) |*lib| lib.close();
        self.* = .{};
    }

    pub fn available(self: *const Backend) bool {
        return self.x != null;
    }

    /// True once a keymap has arrived and been compiled, which is the point
    /// from which text can be produced at all.
    pub fn ready(self: *const Backend) bool {
        return self.state != null;
    }

    /// Take the keymap the compositor sent.
    ///
    /// `source` is the mapped file, which the caller unmaps afterwards -
    /// libxkbcommon copies what it needs.
    pub fn setKeymap(self: *Backend, source: [*:0]const u8) void {
        const x = self.x orelse return;
        const context = self.context orelse return;

        const keymap = x.xkb_keymap_new_from_string(
            context,
            source,
            format_text_v1,
            keymap_compile_no_flags,
        ) orelse return;

        const state = x.xkb_state_new(keymap) orelse {
            x.xkb_keymap_unref(keymap);
            return;
        };

        // Only after the new one is built: a compositor that sends a second
        // keymap - the user changed layout - must not leave a window with no
        // way to type between the two.
        if (self.state) |old| x.xkb_state_unref(old);
        if (self.keymap) |old| x.xkb_keymap_unref(old);

        self.keymap = keymap;
        self.state = state;
    }

    /// What the compositor says is held down, latched and locked.
    pub fn updateMods(
        self: *Backend,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) void {
        const x = self.x orelse return;
        const state = self.state orelse return;
        _ = x.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
    }

    /// The text one key press produced.
    ///
    /// `code` is the evdev code from the protocol; XKB numbers keys eight
    /// higher, the same offset X11 uses, and the caller passes the raw one.
    pub fn keyText(self: *Backend, code: u32) Typed {
        const x = self.x orelse return .{};
        const state = self.state orelse return .{};

        const keycode = code + 8;
        const sym = x.xkb_state_key_get_one_sym(state, keycode);

        // Through compose first. A dead key is accepted and produces nothing;
        // the key after it produces both characters' worth in one go.
        if (self.compose) |compose| {
            if (x.xkb_compose_state_feed) |feed| {
                if (feed(compose, sym) == compose_feed_accepted) {
                    const status = if (x.xkb_compose_state_get_status) |get|
                        get(compose)
                    else
                        compose_nothing;

                    switch (status) {
                        compose_composing => return .{ .composing = true },
                        compose_composed => {
                            const get_utf8 = x.xkb_compose_state_get_utf8 orelse return .{};
                            const n = get_utf8(compose, &self.buf, self.buf.len);
                            if (x.xkb_compose_state_reset) |reset| reset(compose);
                            if (n <= 0) return .{};
                            return .{ .text = self.buf[0..@intCast(@min(n, self.buf.len - 1))] };
                        },
                        compose_cancelled => {
                            // A sequence that went nowhere. Nothing is typed,
                            // which is what every other toolkit does too.
                            if (x.xkb_compose_state_reset) |reset| reset(compose);
                            return .{};
                        },
                        // Not part of a sequence: fall through to the keymap.
                        else => {},
                    }
                }
            }
        }

        const n = x.xkb_state_key_get_utf8(state, keycode, &self.buf, self.buf.len);
        if (n <= 0) return .{};
        return .{ .text = self.buf[0..@intCast(@min(n, self.buf.len - 1))] };
    }
};

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

/// The first of these environment variables that is set and not empty.
///
/// libc's own `getenv` rather than the standard library's: this file is only
/// ever compiled for a target that links libc, and the C string it hands back
/// is exactly what libxkbcommon wants - no copy and no allocator.
fn firstEnv(names: []const [:0]const u8) ?[*:0]const u8 {
    for (names) |name| {
        const value = getenv(name.ptr) orelse continue;
        if (value[0] == 0) continue;
        return value;
    }
    return null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// The smallest keymap libxkbcommon will accept, with two keys on it.
///
/// Written out rather than taken from the system so that the test asserts
/// something fixed: `q` at keycode 24, which is evdev's 16 plus the eight that
/// XKB numbers everything higher by, and a shift key that turns it into `Q`.
const tiny_keymap =
    \\xkb_keymap {
    \\  xkb_keycodes "tiny" {
    \\    minimum = 8;
    \\    maximum = 255;
    \\    <AD01> = 24;
    \\    <LFSH> = 50;
    \\  };
    \\  xkb_types "tiny" {
    \\    virtual_modifiers NumLock;
    \\    type "ONE_LEVEL" {
    \\      modifiers = none;
    \\      level_name[1] = "Any";
    \\    };
    \\    type "ALPHABETIC" {
    \\      modifiers = Shift+Lock;
    \\      map[Shift] = 2;
    \\      map[Lock] = 2;
    \\      level_name[1] = "Base";
    \\      level_name[2] = "Caps";
    \\    };
    \\  };
    \\  xkb_compatibility "tiny" {
    \\    interpret Shift_L {
    \\      action = SetMods(modifiers = Shift);
    \\    };
    \\  };
    \\  xkb_symbols "tiny" {
    \\    key <AD01> { type = "ALPHABETIC", [ q, Q ] };
    \\    key <LFSH> { type = "ONE_LEVEL", [ Shift_L ] };
    \\    modifier_map Shift { <LFSH> };
    \\  };
    \\};
;

test "a real keymap turns a keycode into the text it types" {
    // Against the installed libxkbcommon, so this is the whole Wayland text
    // path bar the compositor handing over the keymap. Skipped where the
    // library is absent, which is every platform but Linux.
    var backend: Backend = Backend.open();
    defer backend.close();
    if (!backend.available()) return error.SkipZigTest;

    backend.setKeymap(tiny_keymap);
    if (!backend.ready()) return error.SkipZigTest;

    // Evdev 16 is the key labelled Q on a US layout, and XKB numbers it 24.
    // Passing the evdev code and letting this add the eight is the whole
    // reason `keyText` takes the raw one.
    try testing.expectEqualStrings("q", backend.keyText(16).text);

    // Shift is index 0 in the mask, which is what `modifier_map Shift` above
    // bound the left shift key to.
    backend.updateMods(1, 0, 0, 0);
    try testing.expectEqualStrings("Q", backend.keyText(16).text);

    backend.updateMods(0, 0, 0, 0);
    try testing.expectEqualStrings("q", backend.keyText(16).text);

    // A key the keymap has nothing on types nothing, rather than a stray byte
    // left over from the last lookup.
    try testing.expectEqualStrings("", backend.keyText(200).text);
}

test "a keymap that will not compile leaves the last one working" {
    var backend: Backend = Backend.open();
    defer backend.close();
    if (!backend.available()) return error.SkipZigTest;

    backend.setKeymap(tiny_keymap);
    if (!backend.ready()) return error.SkipZigTest;

    // A compositor that sends rubbish - or a keymap from a newer XKB than this
    // machine understands - must not leave a window unable to type at all.
    backend.setKeymap("this is not a keymap");
    try testing.expect(backend.ready());
    try testing.expectEqualStrings("q", backend.keyText(16).text);
}

test "a backend with nothing open produces no text and says so" {
    var backend: Backend = .{};
    try testing.expect(!backend.available());
    try testing.expect(!backend.ready());

    const typed = backend.keyText(30);
    try testing.expectEqualStrings("", typed.text);
    try testing.expect(!typed.composing);

    // And none of the setters may reach through a null.
    backend.setKeymap("nonsense");
    backend.updateMods(0, 0, 0, 0);
    backend.close();
}

test "the compose statuses are the numbers libxkbcommon publishes" {
    // Checked rather than derived: a wrong number here makes a dead key look
    // like a finished sequence and types the accent on its own.
    try testing.expectEqual(@as(u32, 0), compose_nothing);
    try testing.expectEqual(@as(u32, 1), compose_composing);
    try testing.expectEqual(@as(u32, 2), compose_composed);
    try testing.expectEqual(@as(u32, 3), compose_cancelled);
    try testing.expectEqual(@as(u32, 1), format_text_v1);
}

test "the locale comes from the first variable that is set" {
    // Nothing to assert about the machine's own environment beyond this: the
    // function must not return an empty string, because libxkbcommon would
    // take it as a locale name and find no compose file for it.
    if (firstEnv(&.{"LC_ALL"})) |value| {
        try testing.expect(std.mem.span(value).len > 0);
    }
    // A list of names that cannot exist has no answer.
    try testing.expectEqual(
        @as(?[*:0]const u8, null),
        firstEnv(&.{"FLUXION_NOT_A_REAL_VARIABLE_AT_ALL"}),
    );
}
