// SPDX-License-Identifier: BSL-1.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // fluxion-dyn: opening a shared library at run time and binding a struct of
    // entry points. Every backend here is loaded that way - `user32.dll`,
    // `libX11.so.6`, `libwayland-client.so.0`, `libandroid.so` - so that one
    // binary runs on a machine that has only some of them.
    const dyn = b.dependency("fluxion_dyn", .{
        .target = target,
        .optimize = optimize,
    });

    // Every POSIX backend needs libc: the wake pipe and `poll` come from it, and
    // so does the `dlopen` that finds `libX11`, `libwayland-client` or
    // `libandroid` in the first place. A Windows build links nothing extra -
    // there `user32.dll` is reached through the system loader.
    const needs_libc = switch (target.result.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
        else => false,
    };

    // The importable module. Consumers do:
    //   const platform = @import("fluxion_platform");
    const mod = b.addModule("fluxion_platform", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (needs_libc) true else null,
        .imports = &.{
            .{ .name = "fluxion_dyn", .module = dyn.module("fluxion_dyn") },
        },
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-platform-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-platform",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // -------------------------------------------------------------------
    // Examples
    // -------------------------------------------------------------------

    // The Vulkan example makes its instance with `fluxion-vulkan`, which is
    // a lazy dependency: fetched only when the examples are actually wanted,
    // which is when this is the package being built and not when it is
    // somebody else's dependency. `-Dexamples=false` builds the library's own
    // tests alone; `-Dexamples=true` asks for them from inside another package.
    const examples_wanted = b.option(
        bool,
        "examples",
        "Build the examples and their tests (pulls fluxion-vulkan)",
    ) orelse (b.pkg_hash.len == 0);
    if (!examples_wanted) return;

    // On the first run after a clean checkout this comes back null and the
    // build runner fetches it and starts again, so returning here is not
    // giving up - it is the first half of the fetch.
    const vulkan_dep = b.lazyDependency("fluxion_vulkan", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;

    // zig build example runs the tour; zig build example-<name> runs one of the
    // others; zig build examples runs all of them, in this order.
    const examples = [_]struct {
        name: []const u8,
        step: []const u8,
        about: []const u8,
        needs_window: bool = false,
    }{
        .{ .name = "demo", .step = "example", .about = "What this machine's windowing is, without opening anything" },
        .{
            .name = "window",
            .step = "example-window",
            .about = "A window, and every event it produces",
            .needs_window = true,
        },
        .{
            .name = "gl",
            .step = "example-gl",
            .about = "A window with an OpenGL context, clearing to a colour that moves",
            .needs_window = true,
        },
        .{
            .name = "text",
            .step = "example-text",
            .about = "A window that takes typing, and the difference between a key and a letter",
            .needs_window = true,
        },
        .{
            .name = "vulkan",
            .step = "example-vulkan",
            .about = "A window, an instance, and the surface made from the two",
            .needs_window = true,
        },
    };

    // A window needs a windowing system, which a cross-compiled build has no
    // way to reach. The library itself still builds everywhere - `backend` is
    // `.none` there and every call says so rather than failing to compile.
    const host = target.result.os.tag == @import("builtin").os.tag;

    const all_examples = b.step("examples", "Build and run every example in turn");
    var previous: ?*std.Build.Step = null;

    for (examples) |example| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluxion_platform", .module = mod },
                // The Vulkan example brings its own binding, because that is
                // what a program does - this library never links Vulkan, and
                // `createVulkanSurface` takes the binding's
                // `vkGetInstanceProcAddr` rather than finding one itself.
                .{ .name = "fluxion_vulkan", .module = vulkan_dep.module("fluxion_vulkan") },
            },
            .link_libc = if (needs_libc) true else null,
        });
        const exe = b.addExecutable(.{
            .name = b.fmt("fluxion-platform-{s}", .{example.name}),
            .root_module = example_mod,
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        // Anything after `--` goes through: `zig build example-window -- --frames 60`.
        if (b.args) |args| run.addArgs(args);
        b.step(example.step, example.about).dependOn(&run.step);

        if (example.needs_window and !host) continue;

        // A second run for the aggregate step, chained one after another so
        // that `zig build examples` reads as a page rather than as several
        // programs shouting at once.
        const in_order = b.addRunArtifact(exe);
        in_order.step.dependOn(b.getInstallStep());
        if (previous) |earlier| in_order.step.dependOn(earlier);
        previous = &in_order.step;
        all_examples.dependOn(&in_order.step);

        const example_tests = b.addTest(.{
            .name = b.fmt("fluxion-platform-{s}-tests", .{example.name}),
            .root_module = example_mod,
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }
}
