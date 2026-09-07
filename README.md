# Fluxion Platform

Windows, input and the event loop, on whatever this machine has. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `platform` | Which windowing system this build can reach, and which one this run got. Chosen at startup, not at compile time. |
| `Context` | The connection, the windows on it, and the event queue. One per process, on one thread. |
| `Window` | One window, as a handle you can copy. Two words, and copying it copies nothing. |
| `event` | Everything that can happen, as one tagged union. |
| `keys` | What a key is, what a button is, and what was held down at the time. |
| `input` | What is held down right now, kept up to date as events go past. |
| `cursor` | Where the pointer may go, and whether it can be seen. |
| `monitor` | The displays attached, what each can do, and how a window fills one. |
| `gamepad` | Controllers: what is plugged in, what it is doing, and how to read an unfamiliar one. |
| `gl` | Asking a window for an OpenGL context, and driving the one it gives back. |
| `vulkan` | Which instance extensions this session needs, and turning a window into a surface. |
| `text` | The text a keyboard actually produces, and the input method between the two. |
| `backend` | What a windowing system has to answer to — the seam a new backend is written against. |

The shape is GLFW's: window hints, key tokens at GLFW's own numbers, and
`shouldClose` as a flag the program owns rather than something the system does
to you. One thing is deliberately different, and one thing GLFW does not do at
all.

## Status

| Backend | State |
| --- | --- |
| `win32` | Window, message pump, keyboard, mouse, wheel, resize, DPI, monitors, fullscreen with mode switching, XInput controllers, WGL, Vulkan surface, IMM32 text and composition |
| `x11` | Window, event loop, keyboard, mouse, wheel, resize, focus, `Xft.dpi`, RandR monitors, fullscreen with mode switching, evdev controllers, GLX, Vulkan surface, XIM text |
| `wayland` | Window, xdg-shell, event loop, keyboard, mouse, wheel, resize, focus, `wl_output` monitors, fullscreen, evdev controllers, EGL, Vulkan surface, xkbcommon text and compose |
| `android` | Activity lifecycle, surface create and loss, focus, keys, touch, screen and density, controllers, EGL, Vulkan surface, soft keyboard and text |
| `none` | Compiles and runs everywhere, makes no windows |

On Linux `auto` opens Wayland where there is a compositor and falls through to
X11 where there is not — the run-time selection the whole design exists for.
The library still builds for Android, macOS and `wasm32`: `backend` is `.none`
there and every call says so, rather than the build failing. That is what keeps
a program that only wanted `Key` compiling on a target this library has never
heard of.

**Text input is the gap on both.** X11 goes through `XLookupString`, which
answers in Latin-1: ASCII and the western European letters and nothing else.
Wayland produces no `.char` events at all yet. Both need the same thing — an
input method, `XIC` on one side and `libxkbcommon` on the other — and that is
the next thing either file should grow.

**A window is not visible until something draws into it**, on Wayland and on
Android both. Neither has an empty window: a surface with no buffer attached
is not mapped, and on Android an unmapped window is not touchable either -
keys reach it because focus is a window-manager idea, but touch is routed by
hit-testing what is on screen. That is not a gap here, it is the platform,
and it is why `createWindow` hands back a surface a renderer then presents to.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-platform
```

Then in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_platform", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_platform", fluxion.module("fluxion_platform"));
```

```zig
const platform = @import("fluxion_platform");
```

One dependency comes with it, fetched the same way and needing nothing from
you: [Fluxion Dyn](https://github.com/kisstp2006/fluxion-dyn), which is how
every backend is opened.

## The short version

```zig
var ctx = try platform.Context.init(gpa, .{});
defer ctx.deinit();

var win = try ctx.createWindow(.{ .title = "hello", .width = 1280, .height = 720 });
defer win.destroy();

while (!win.shouldClose()) {
    try ctx.pump();
    while (ctx.poll()) |ev| switch (ev) {
        .close => win.setShouldClose(true),
        .key => |k| if (k.key == .escape and k.action == .press) win.setShouldClose(true),
        .framebuffer_resize => |r| resize(r.width, r.height),
        else => {},
    };
    draw();
}
```

## Events are pulled, not pushed

GLFW hands you callbacks. This hands you a queue, and the difference is the one
deliberate departure.

A callback fires in the middle of somebody else's pump, so everything it
touches has to be reachable through a user pointer and safe to touch at a
moment the program did not choose. A queue is read at one point in the frame,
by code that already has everything in scope:

```zig
try ctx.pump();                     // talk to the system
while (ctx.poll()) |ev| switch (ev) // read what it said
```

`pump` does not block. `pumpWait(timeout_ms)` sleeps until something arrives,
for a program that redraws only when something changed, and `post` wakes it
from another thread — the one call on a context that may be made from anywhere.

## The cursor is what makes a camera possible

Four modes, and the difference between two of them is the difference between
a program with a cursor and a game with a camera:

```zig
try win.setCursorMode(.disabled);   // invisible, held, and unbounded
_ = win.setRawMouseMotion(true);    // and not through pointer acceleration
```

`captured` keeps a visible cursor inside the window, which is what a strategy
game wants. `disabled` takes the pointer out of the picture entirely: the
`.cursor` events carry `dx` and `dy` that keep going however far the mouse
moves, and `x` and `y` stop meaning anything. Without it a fast turn runs out
of screen and the camera stops with it.

`setRawMouseMotion` returns whether it was granted rather than assuming.
Acceleration is a curve meant to help a cursor land on a button and is exactly
wrong for aiming - but not every system will turn it off, and a program that
is told no can turn down its own sensitivity instead of pretending.

What a session can actually do differs by compositor, not by platform. `zig
build example` asks and prints the answers.

## Polled input, as well as the queue

The queue says what happened; these say what is:

```zig
if (ctx.key(.w)) camera.forward();
const at = ctx.cursorPos();
```

Both are fed by the same pump, so they never disagree. Two things come with
it that a program would otherwise write for itself, with the same two bugs:
losing focus lets go of every held key - otherwise alt-tab leaves a camera
drifting forever - and `setStickyKeys` keeps a press readable until it has
been polled once, so a tap that begins and ends inside one frame is not lost.

## A key is not a letter

```zig
try win.setTextInput(true);                                  // a field has focus
try win.setTextInputArea(.{ .x = caret_x, .y = caret_y, .height = 20 });

switch (ev) {
    .key => |k| if (k.key == .w) camera.forward(),           // a position
    .char => |c| field.append(c.codepoint),                  // a letter
    .preedit => draw_underlined(ctx.preedit().text()),       // not committed yet
    else => {},
}
```

`.key` says which key moved, at its position on the keyboard. `.char` says
what was typed, after the layout, the dead keys, the compose sequence and any
input method have all had their say. A game reads the first; a text field
reads the second, and reading the first spells the user's name wrong on every
layout but one. On the machine this was tested on, shift-1 is a key called `1`
and a character called `'`.

**Text input is off until asked for.** That is what raises the soft keyboard
on a phone and what lets an input method open a candidate window; a game that
never calls it never gets one mid-firefight.

**A composition is a state, not an event.** While an input method is being
used there is text on screen that has not been committed and may still change.
`.preedit` says it changed and `ctx.preedit()` says what it is now — the same
split the rest of this library uses. A program that does not draw it can
ignore all of this and still get correct text, because a composition commits
through `.char` in the end.

How far each platform goes differs, and it is worth knowing which:

| | text | composition |
| --- | --- | --- |
| `win32` | `WM_CHAR`, surrogate pairs joined | IMM32, delivered as `.preedit` |
| `x11` | XIM and `Xutf8LookupString` | the input method draws its own |
| `wayland` | libxkbcommon, with the locale's compose table | none yet — needs `zwp_text_input_v3` |
| `android` | `KeyEvent.getUnicodeChar` over JNI | none — needs an `InputConnection` |

Two of those are real gaps rather than platform limits, and they are written
down rather than papered over. On X11 the composition is drawn by the input
method itself, which is what the root preedit style means and what every
toolkit falls back to; delivering it to the program needs
`XIMPreeditCallbacks`. On Wayland there is no input method at all yet, though
dead keys and compose sequences work.

## Drawing: a context, or a surface, and nothing after that

```zig
var win = try ctx.createWindow(.{ .gl = .{ .major = 3, .minor = 3 } });
try win.makeContextCurrent();
try win.setSwapInterval(.vsync);
// ... every frame:
draw();
try win.swapBuffers();
```

WGL on Windows, GLX on X11, EGL on Wayland and Android — one API over four,
including the parts that are only reachable by asking a throwaway context
where the real entry points are.

**The context is asked for when the window is made**, not afterwards. That is
not an API preference: Win32 allows one `SetPixelFormat` per window, X11 needs
the window built on the visual its framebuffer config named, and EGL wants a
surface made against a config. A window has a context from the moment it
exists or never gets one.

**Nothing here loads a GL function.** `win.getProcAddress` is the whole of it;
sorting what it returns into a table is a loader's job, and `fluxion-gl` is
the one to use. Note that a non-null answer is not proof a function exists —
EGL is allowed to return a dispatch stub for any `gl` name, and Mesa does.

Vulkan is two calls and no linking:

```zig
const extensions = ctx.requiredVulkanExtensions(); // enable these on the instance
const surface = try win.createVulkanSurface(instance, vkGetInstanceProcAddr, null);
```

The instance goes in as an integer and the surface comes back as one, because
declaring `VkInstance` would mean declaring half of `vulkan.h` to go with it.
The entry point is looked up through the caller's own loader, so there is
exactly one Vulkan in the process — the program's. Which extensions to enable
depends on the session rather than the build: a binary that could open either
X11 or Wayland has to ask after it knows which it got.

On Android both of these come and go with the surface. The context is
destroyed on `.surface_lost` and a new one is built before `.surface_created`,
so every GL pointer has to be looked up again — caching them across a trip to
the background is calling into a driver that has moved on.

## Two ways to fill a monitor, and they are not the same

```zig
for (ctx.monitors(), 0..) |*mon, i| {
    std.debug.print("{d}: {f}\n", .{ i, mon.* });
}
try win.setFullscreen(.{ .borderless = 0 });
```

`.borderless` covers the monitor at whatever it is already set to. Nothing
changes mode, so alt-tab is instant and no other window on the desktop is
resized. It is what a game should use.

`.exclusive` switches the display first. It rearranges every other window on
the machine and is slow to leave, and it is worth that only when a different
resolution genuinely is the point. Windows and X11 do it; Wayland refuses,
because the protocol has no such request and never will — a client that wants
fewer pixels renders fewer and lets the compositor scale.

Two things the list will not do. It will not tell you a monitor's real size in
millimetres, because that comes from the display's own EDID and displays lie —
the 4K television this was tested on claims to be 1.6 metres across. And it
will not always be non-empty: a headless session has no monitors, and an
Android app has none until its surface exists. Both are answers, not failures.

## A controller is polled, not listened to

```zig
if (ctx.firstGamepad()) |pad| {
    if (pad.state.button(.a)) jump();
    move(pad.state.axisDeadzone(.left_x, 0.15));
}
```

A stick is a position rather than a thing that happened, so there are no
button events — a frame reads the whole state and compares it to the last
one. Only plugging in and unplugging arrive as events, because those genuinely
are events.

**Most controllers need no mapping file.** Every platform here has already
normalised the common case: XInput *is* the Xbox layout, the Linux kernel's
gamepad spec says `BTN_SOUTH` is the button under the thumb, and Android's
compatibility rules say the same about `AKEYCODE_BUTTON_A`. So a pad arrives
mapped and `.a` is the bottom face button on all three. For the device that
follows none of that, `updateGamepadMappings` reads SDL's
`gamecontrollerdb.txt` format — the community's file, unmodified.

`.a` is a *position*, not a letter. It is the bottom face button: `A` on an
Xbox pad, cross on a PlayStation one, and `B` on a Nintendo one, because
Nintendo swapped them. A program that means "the button under the thumb"
should say `.a` and let the pad print whatever it likes on the plastic.

Two platform limits worth knowing. Windows reports four controllers, not
sixteen, because that is what XInput holds — a flight stick or a wheel with
a hundred buttons is a DirectInput device and is not here. And on Android a
pad appears the first time it *sends* something, because the NDK has no call
that lists input devices; "press A to start" is the right prompt there.

## Which key `Key.a` is

The one left of `s`, whatever the keyboard is set to. That is what WASD wants,
and it is read from the scancode rather than the virtual key, so a binding does
not move under a user on AZERTY. What that key *types* is a `.char` event, and
the difference is the section above.

A key this library has no name for keeps its value rather than collapsing into
one `unknown`, and its `Scancode` still tells it apart from any other. A
keystroke with no scancode at all - which is what an on-screen keyboard, a
remote desktop, a screen reader and an automation tool all send on Windows - is
turned back into a position rather than reported as unknown.

## Android is not a small desktop

GLFW does not support Android, and the reason is not effort: the model is
different in a way that reaches the API.

There, the system takes the drawing surface away when the app goes to the
background or the screen rotates, and hands back a different one later, while
the process keeps running. A `Window` that is yours from `create` to `destroy`
is a lie on a phone.

So the surface has a lifecycle of its own, and it is in the event union:

```zig
.surface_lost    => releaseSwapchain(),   // release everything pointing at it
.surface_created => |s| createSwapchain(s.width, s.height),
```

No desktop backend ever sends either. A program written to handle them is
correct on a phone and unchanged on a PC — and the reverse cannot happen
quietly, which is the point of putting them in the union that every `switch`
sees.

## Backends are loaded, not linked

Every entry point is fetched by name through
[Fluxion Dyn](https://github.com/kisstp2006/fluxion-dyn), for the same reason
Direct3D and Vulkan are:

* `GetDpiForWindow` arrived in Windows 10 1607 and
  `SetProcessDpiAwarenessContext` in 1703. A program that imports either the
  ordinary way does not start on anything older — the loader fails before
  `main`, and the fallback that lives inside the program never runs.
* On Linux the choice is not made until the program runs. The same binary opens
  Wayland in one session and X11 in the next, which cannot work if either
  library is linked.

Wayland asks for one thing more. It is a protocol rather than a library API:
`libwayland-client` marshals messages, and the descriptions of what the
messages *are* are normally generated from XML and compiled in. The core
protocol's descriptors are exported by the library and fetched by name;
xdg-shell's are not, so this library writes those four out by hand — which is
what SDL does, and what GLFW does since it started loading Wayland
dynamically.

`platform.supported` is what this build could open; `ctx.backend()` is what this
run actually got.

## Threads, and one thing that does not move

A context belongs to the thread that made it, and so does every call on it
except `post`.

That is not caution. Windows delivers messages to the queue of the thread that
created the window, and Android's looper belongs to the thread that attached
it — a context pumped from a second thread simply never sees an event. The rule
comes from the platforms, so it is stated rather than locked around.

It fits a loop where the main thread owns events and presentation while a scene
thread runs the simulation: pump and draw on one, everything else on the other,
and one barrier at the end of the frame.

**A context also does not move once a window exists.** A `Window` is an id and
a pointer back to the context that owns it, so copying the context - returning
it from a function, putting it in a struct that is then moved - leaves every
window handle pointing at where it used to be. Keep it where it was made.

## Examples

```bash
zig build example          # what this machine's windowing is, opening nothing
zig build example-window   # a window, and every event it produces
zig build example-gl       # an OpenGL context, clearing to a colour that moves
zig build example-text     # typing, and the difference between a key and a letter
zig build example-vulkan   # an instance, and the surface made from a window
```

The second takes `--frames N` so a run ends on its own.

## Tests

```bash
zig build test
```

Everything that can be checked without a display is, including the X11 struct
layouts — a field at the wrong offset there is a window id read out of the
middle of a timestamp, which deserves a check that runs on every host and not
only where X is.

Both desktop backends carry the same end-to-end test: open a hidden window,
put a real message into the system's own queue, and check it comes back out of
`poll` as an event naming that window. They skip rather than fail where there
is no session to open.

To run the Linux tests from a Windows checkout:

```bash
zig build test -Dtarget=x86_64-linux-gnu
```

## Licence


`SPDX-License-Identifier: BSL-1.0`

[Boost Software License 1.0](LICENSE) - permissive, and short enough to read
in a minute: use it, change it, ship it, in anything. The one obligation is
that the copyright notice and the licence text travel with the *source*; a
binary built from it carries nothing, which is the difference from MIT and
BSD and the reason this is the usual choice for a library that ends up
compiled into somebody else's program.

Fluxion libraries are licensed by layer: the foundation is CC0, the engine
infrastructure this one belongs to is BSL-1.0, and what builds on top of it
is BSD.
