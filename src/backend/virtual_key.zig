// SPDX-License-Identifier: BSL-1.0

//! How a backend works out `KeyEvent.virtual`: the key as the layout names it,
//! from the physical key and what that key types on the layout in use.
//!
//! Every backend asks its own system the same question - what does this key
//! type on its own, before shift or AltGr choose another character - and
//! answers with the rule below, which lives here so that it is one rule and
//! not five. **Only letters move.** A layout rearranges its letters and a
//! shortcut is written against a letter; digits and punctuation stay where
//! they are, because on AZERTY and on a Czech keyboard the digits are the
//! shifted half of their keys and what a key types on its own would name them
//! wrong. So:
//!
//!   * A key that types a Latin letter is that letter. The key marked Z on a
//!     German or Hungarian keyboard, where a US one has Y, is `.z`.
//!   * A key that types a letter from another alphabet is the Latin letter of
//!     its place. Cyrillic and Greek keyboards have no Latin letters at all,
//!     and every system lets ctrl+C copy there by falling back to the letter
//!     a US keyboard has in the same position.
//!   * A letter's place that holds something else is `.unknown` - AZERTY's
//!     comma, where US has M. That layout's M is elsewhere, and one letter
//!     must not be claimed by two keys.
//!   * Everything else is the physical key: digits, punctuation, and the keys
//!     that type nothing at all, and any key whose character cannot be told.

const std = @import("std");
const testing = std.testing;

const keys = @import("../keys.zig");

/// The virtual key for `physical`, given what it types on its own on the
/// layout in use - null where that cannot be told.
pub fn fromTyped(physical: keys.Key, typed: ?u21) keys.Key {
    const c = typed orelse return physical;
    // A control character is what a key types with control held, or what
    // Enter and Tab type; neither says anything about which key it is.
    if (c < 0x20 or c == 0x7F) return physical;
    if (c < 0x80) {
        const ascii: u8 = @intCast(c);
        if (std.ascii.isAlphabetic(ascii)) return @enumFromInt(std.ascii.toUpper(ascii));
        return if (isLetter(physical)) .unknown else physical;
    }
    return physical;
}

/// The same, for a system that names the letter on a key directly rather
/// than saying what it types - Windows, whose virtual keys `VK_A` to `VK_Z`
/// already follow the rule above. `letter` is that letter, or null for a key
/// the system gives no letter.
pub fn fromLetter(physical: keys.Key, letter: ?u8) keys.Key {
    if (letter) |l| {
        if (std.ascii.isAlphabetic(l)) return @enumFromInt(std.ascii.toUpper(l));
    }
    return if (isLetter(physical)) .unknown else physical;
}

/// What an X keysym types, as far as `fromTyped` needs to know: the character
/// itself for ASCII, Latin-1 and the keysyms that are Unicode; U+FFFD, a
/// stand-in outside ASCII, for the older blocks - Cyrillic, Greek, Arabic and
/// the rest - whose exact character the rule never asks for; and null for a
/// keysym that types nothing, which is every function key, modifier and dead
/// key. X11 and libxkbcommon both number keysyms this way.
pub fn typedByKeysym(sym: u32) ?u21 {
    if (sym >= 0x20 and sym <= 0x7E) return @intCast(sym);
    if (sym >= 0xA0 and sym <= 0xFF) return @intCast(sym);
    if (sym >= 0x0100_0100 and sym <= 0x0110_FFFF) return @intCast(sym - 0x0100_0000);
    if (sym >= 0x100 and sym < 0xFD00) return 0xFFFD;
    return null;
}

fn isLetter(key: keys.Key) bool {
    const value = @intFromEnum(key);
    return value >= 'A' and value <= 'Z';
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a key that types a Latin letter is that letter, wherever it is" {
    // German and Hungarian: the key where US has Y is marked Z, and the other
    // way round.
    try testing.expectEqual(keys.Key.z, fromTyped(.y, 'z'));
    try testing.expectEqual(keys.Key.y, fromTyped(.z, 'y'));
    // Shift does not change which letter it is.
    try testing.expectEqual(keys.Key.z, fromTyped(.y, 'Z'));
    // AZERTY: A where US has Q, and M where US has the semicolon.
    try testing.expectEqual(keys.Key.a, fromTyped(.q, 'a'));
    try testing.expectEqual(keys.Key.m, fromTyped(.semicolon, 'm'));
    // A US keyboard is the same both ways.
    try testing.expectEqual(keys.Key.w, fromTyped(.w, 'w'));
}

test "a letter from another alphabet keeps the Latin letter of its place" {
    // Russian ЙЦУКЕН: я where US has Z, с where it has C.
    try testing.expectEqual(keys.Key.z, fromTyped(.z, 'я'));
    try testing.expectEqual(keys.Key.c, fromTyped(.c, 'с'));
    // Greek: ζ where US has Z.
    try testing.expectEqual(keys.Key.z, fromTyped(.z, 'ζ'));
}

test "a letter's place that holds something else claims no letter" {
    // AZERTY's comma is where US has M; its M is elsewhere.
    try testing.expectEqual(keys.Key.unknown, fromTyped(.m, ','));
    try testing.expectEqual(keys.Key.unknown, fromLetter(.m, null));
}

test "digits, punctuation and keys that type nothing stay where they are" {
    // Hungarian ö is where US has 0, and the digit is not moved to follow it.
    try testing.expectEqual(keys.Key.@"0", fromTyped(.@"0", 'ö'));
    // AZERTY's top row types & on its own; it is still the 1 key.
    try testing.expectEqual(keys.Key.@"1", fromTyped(.@"1", '&'));
    try testing.expectEqual(keys.Key.comma, fromTyped(.comma, ';'));
    try testing.expectEqual(keys.Key.enter, fromTyped(.enter, null));
    try testing.expectEqual(keys.Key.left, fromTyped(.left, null));
    try testing.expectEqual(keys.Key.space, fromTyped(.space, ' '));
    // Enter and Tab type control characters, which name nothing.
    try testing.expectEqual(keys.Key.enter, fromTyped(.enter, '\r'));
    try testing.expectEqual(keys.Key.tab, fromTyped(.tab, '\t'));
    try testing.expectEqual(keys.Key.enter, fromLetter(.enter, null));
}

test "a key whose character cannot be told is the physical key" {
    try testing.expectEqual(keys.Key.z, fromTyped(.z, null));
    try testing.expectEqual(keys.Key.unknown, fromTyped(.unknown, null));
}

test "the letter a system names is the letter, in either case" {
    try testing.expectEqual(keys.Key.z, fromLetter(.y, 'Z'));
    try testing.expectEqual(keys.Key.z, fromLetter(.y, 'z'));
    // Anything else the system says is not a letter, and is treated as none.
    try testing.expectEqual(keys.Key.@"1", fromLetter(.@"1", '1'));
}

test "keysyms say what they type, or that they type nothing" {
    try testing.expectEqual(@as(?u21, 'z'), typedByKeysym(0x7A)); // XK_z
    try testing.expectEqual(@as(?u21, 'Z'), typedByKeysym(0x5A)); // XK_Z
    try testing.expectEqual(@as(?u21, ','), typedByKeysym(0x2C)); // XK_comma
    try testing.expectEqual(@as(?u21, 0xF6), typedByKeysym(0xF6)); // XK_odiaeresis
    try testing.expectEqual(@as(?u21, 0x3B6), typedByKeysym(0x0100_03B6)); // U+03B6, ζ
    // XK_Cyrillic_ya, from the old block: outside ASCII, which is all the
    // rule wants to know.
    try testing.expectEqual(@as(?u21, 0xFFFD), typedByKeysym(0x6D1));
    try testing.expectEqual(@as(?u21, null), typedByKeysym(0)); // NoSymbol
    try testing.expectEqual(@as(?u21, null), typedByKeysym(0xFF0D)); // XK_Return
    try testing.expectEqual(@as(?u21, null), typedByKeysym(0xFE51)); // XK_dead_acute
    try testing.expectEqual(@as(?u21, null), typedByKeysym(0xFFE1)); // XK_Shift_L

    // And through the rule, the Cyrillic key keeps its Latin letter.
    try testing.expectEqual(keys.Key.z, fromTyped(.z, typedByKeysym(0x6D1)));
}
