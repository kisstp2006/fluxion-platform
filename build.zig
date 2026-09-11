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

    // The other half of the web backend: the JavaScript every page needs beside
    // the module. Named, so that a program building for the browser installs
    // it with
    //   b.addInstallFile(fluxion.namedLazyPath("fluxion-platform.js"), "web/fluxion-platform.js");
    // rather than reaching into this package's source tree by path.
    const web_glue = b.path("src/backend/web.js");
    b.addNamedLazyPath("fluxion-platform.js", web_glue);

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-platform-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // The tests above run on this machine, where the web backend talks to its
    // stub and never to `web_imports.zig` - the whole point of that file is
    // that it exists for one target. So the suite also *builds* the library for
    // that target, through every vtable entry, without running anything.
    //
    // That is not a formality. Compiling for the browser is what analyses the
    // imports, and analysing them is what runs `web.verify`, which is what
    // proves the stub the tests just used has the same signatures the page
    // will be handed. A mismatch is a compile error here rather than an
    // argument quietly coerced in somebody's tab.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_dyn", .module = b.dependency("fluxion_dyn", .{
                .target = wasm_target,
                .optimize = optimize,
            }).module("fluxion_dyn") },
        },
    });
    const wasm_check = b.addExecutable(.{
        .name = "fluxion-platform-wasm-check",
        .root_module = b.createModule(.{
            .root_source_file = b.addWriteFiles().add("wasm_check.zig",
                \\//! The library as a browser build sees it. Nothing calls this: that
                \\//! it compiles, imports and all, is the test.
                \\const std = @import("std");
                \\const platform = @import("fluxion_platform");
                \\
                \\pub const std_options: std.Options = .{ .logFn = platform.web.logFn };
                \\pub const panic = platform.web.panic;
                \\
                \\export fn check() void {
                \\    var ctx = platform.Context.init(std.heap.wasm_allocator, .{}) catch return;
                \\    defer ctx.deinit();
                \\    const win = ctx.createWindow(.{}) catch return;
                \\    defer win.destroy();
                \\    ctx.pump() catch {};
                \\    if (platform.web.droppedFile(&ctx, 0, std.heap.wasm_allocator)) |bytes| {
                \\        std.log.info("{d} dropped bytes", .{bytes.len});
                \\        std.heap.wasm_allocator.free(bytes);
                \\    } else |_| {}
                \\}
            ),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fluxion_platform", .module = wasm_mod }},
        }),
    });
    wasm_check.entry = .disabled;
    wasm_check.rdynamic = true;
    test_step.dependOn(&wasm_check.step);

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

    // On the first run after a clean checkout these come back null and the
    // build runner fetches them and starts again, so returning here is not
    // giving up - it is the first half of the fetch. Both are asked for before
    // either is checked, so that one fetch brings both.
    const maybe_vulkan = b.lazyDependency("fluxion_vulkan", .{
        .target = target,
        .optimize = optimize,
    });
    // The browser examples draw with `fluxion-webgl`, for the reason the
    // Vulkan one makes its instance with `fluxion-vulkan`: this library ends
    // at the canvas, and a program brings its own binding. Always for the
    // browser, whatever `-Dtarget` said, because a browser will take nothing
    // else.
    const maybe_webgl = b.lazyDependency("fluxion_webgl", .{
        .target = wasm_target,
        .optimize = optimize,
    });
    const vulkan_dep = maybe_vulkan orelse return;
    const webgl_dep = maybe_webgl orelse return;

    addWebExamples(b, .{
        .platform = wasm_mod,
        .webgl = webgl_dep,
        .glue = web_glue,
        .target = wasm_target,
        .optimize = optimize,
        .test_step = test_step,
    });

    // A desktop example wants a process, stdout and an `Io` to write it
    // through, and a wasm module has none of the three. The browser has its
    // own examples, above.
    if (target.result.cpu.arch.isWasm()) return;

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

const WebExamples = struct {
    /// The library, built for the browser.
    platform: *std.Build.Module,
    webgl: *std.Build.Dependency,
    /// `src/backend/web.js`.
    glue: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
};

/// The browser examples: two modules, the two glues they are instantiated
/// with, and a page to open them in - all in `zig-out/web`, which is the
/// directory to serve. A page cannot `fetch` its own `file://` neighbours, so
/// it has to be served rather than opened.
fn addWebExamples(b: *std.Build, web: WebExamples) void {
    const step = b.step(
        "example-web",
        "The browser examples, into zig-out/web - serve that directory and open it",
    );

    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("examples/web"),
        .install_dir = .prefix,
        .install_subdir = "web",
    }).step);
    step.dependOn(&b.addInstallFile(web.glue, "web/fluxion-platform.js").step);
    step.dependOn(&b.addInstallFile(
        web.webgl.path("examples/web/fluxion-webgl.js"),
        "web/fluxion-webgl.js",
    ).step);

    const examples = [_]struct {
        name: []const u8,
        /// Exports `init`, `frame` and `deinit` for the page to call, rather
        /// than having a `main` of its own.
        exports_frame: bool,
    }{
        // The shape that runs in every browser.
        .{ .name = "web", .exports_frame = true },
        // A desktop loop, unchanged, for a browser that can suspend a module.
        .{ .name = "web_loop", .exports_frame = false },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
                .target = web.target,
                .optimize = web.optimize,
                .imports = &.{
                    .{ .name = "fluxion_platform", .module = web.platform },
                    .{ .name = "fluxion_webgl", .module = web.webgl.module("fluxion_webgl") },
                },
            }),
        });
        if (example.exports_frame) {
            // No `main`: the page calls the exports when it is ready, and
            // without `rdynamic` the linker drops every one of them as unused.
            exe.entry = .disabled;
            exe.rdynamic = true;
        }
        step.dependOn(&b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "web" } },
        }).step);

        // Built, not run, by `zig build test`: a module compiles or it does
        // not, and whether it draws is for a browser to say.
        web.test_step.dependOn(&exe.step);
    }
}
