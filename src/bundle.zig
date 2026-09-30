// SPDX-License-Identifier: BSL-1.0

//! A file that came inside the program's own package, read where it lies.
//!
//! ```zig
//! const pack = try platform.bundle.open("game.fxpack");
//! defer pack.file.close(io);
//! // pack.len bytes of pack.file, from pack.start on
//! ```
//!
//! On Android the APK is the package, and a file stored in its `assets/`
//! without compression is a range of the APK itself. `open` hands back the
//! APK's file and where in it the file lies, so a program reads it with plain
//! positional reads - or maps it - and no copy of it is ever made. A file
//! that was compressed into the APK is no range of it, and is refused: store
//! it as it is. Everywhere else a program's files are beside it, and there is
//! no package to open.

const std = @import("std");
const builtin = @import("builtin");

const android = @import("backend/android.zig");

pub const Bundled = struct {
    /// The package's file, open for reading. The caller closes it.
    file: std.Io.File,
    /// Where the file starts in the package, and how long it is.
    start: u64,
    len: u64,
};

pub const Error = error{
    /// This system has no package: a program's files are beside it.
    Unsupported,
    /// The package has no file of that name, or there is no package yet.
    NotFound,
    /// The file was compressed into the package, and is no range of it.
    Compressed,
};

/// The file `name` - `game.fxpack` for the APK's `assets/game.fxpack`.
pub fn open(name: [:0]const u8) Error!Bundled {
    if (comptime !builtin.abi.isAndroid()) return error.Unsupported;
    return android.bundledFile(name);
}

test "only a package has files inside it" {
    if (comptime builtin.abi.isAndroid()) return error.SkipZigTest;
    try std.testing.expectError(error.Unsupported, open("game.fxpack"));
}
