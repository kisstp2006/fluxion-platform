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
| `dialog` | Asking the user for files or a folder, in the system's own dialog. |
| `trash` | A file or a folder moved to the system's trash, where the user can take it back from. No window needed. |
| `folders` | Home, documents, and where a program keeps its settings, its data and its cache - the system's own answer. |
| `fonts` | The font the system draws its own interface in, as a file a font library can open. |
| `shell` | A file, a folder or an address handed to the system: opened, or shown in the file manager. |
| `web` | What a browser build needs and `std` cannot give it: a console, a panic that says what it was, and the bytes of a dropped file. |
| `backend` | What a windowing system has to answer to — the seam a new backend is written against. |

The shape is GLFW's: window hints, key tokens at GLFW's own numbers, and
`shouldClose` as a flag the program owns rather than something the system does
to you. One thing is deliberately different, and one thing GLFW does not do at
all.

## Status

| Backend | State |
| --- | --- |
| `win32` | Window, message pump, keyboard, mouse, wheel, resize, DPI, monitors, fullscreen with mode switching, XInput controllers, WGL, Vulkan surface, IMM32 text and composition, clipboard, file and folder dialogs, dropped files |
| `x11` | Window, event loop, keyboard, mouse, wheel, resize, focus, `Xft.dpi`, RandR monitors, fullscreen with mode switching, evdev controllers, GLX, Vulkan surface, XIM text, clipboard, file and folder dialogs |
| `wayland` | Window, xdg-shell, event loop, keyboard, mouse, wheel, resize, focus, `wl_output` monitors, fullscreen, evdev controllers, EGL, Vulkan surface, xkbcommon text and compose, clipboard, file and folder dialogs |
| `android` | Activity lifecycle, surface create and loss, focus, keys, touch, screen and density, controllers, EGL, Vulkan surface, soft keyboard and text, clipboard, file and folder dialogs (with `FluxionActivity`) |
| `web` | Canvas, both loop models, keyboard, text and composition, mouse, touch, wheel, pointer lock, fullscreen, device pixel ratio, screen, gamepads, WebGL context and its loss, dropped files, clipboard, file and folder dialogs |
| `none` | Compiles and runs everywhere, makes no windows |

On Linux `auto` opens Wayland where there is a compositor and falls through to
X11 where there is not — the run-time selection the whole design exists for.
The library still builds for macOS and WASI: `backend` is `.none` there and
every call says so, rather than the build failing. That is what keeps a program
that only wanted `Key` compiling on a target this library has never heard of.

`wasm32-freestanding` is the browser, and gets `web`. WASI does not, and that
is deliberate: a WASI runtime is a command line with no page behind it, and a
module that imported a canvas from one would not even instantiate.

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

Two more are named in `build.zig.zon` and are *not* fetched for you:
[Fluxion Vulkan](https://github.com/kisstp2006/fluxion-vulkan), which the
Vulkan example makes its instance with, and
[Fluxion WebGL](https://github.com/kisstp2006/fluxion-webgl), which the browser
examples draw with. Both are `lazy`, and `build.zig` asks for them only when
this is the package being built - a program that depends on `fluxion_platform`
downloads nothing of either, and the library links nothing of them. Pass
`-Dexamples=false` to skip them in a checkout of this repository too.

A program built for the browser needs one file more, and it is JavaScript: the
other half of the web backend, which the page loads beside the module. It is
exported under a name, so there is no path into this package to spell:

```zig
b.getInstallStep().dependOn(&b.addInstallFile(
    fluxion.namedLazyPath("fluxion-platform.js"),
    "web/fluxion-platform.js",
).step);
```

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

A program's own calls are heard the same way: `maximize()` comes back as
`.maximize` at the next pump on every backend, though Windows answers it
before the call has even returned.

## A minimised window keeps its size

```zig
.iconify => |s| paused = s.value,     // a swapchain waits; it is not resized
.maximize => |s| layout.maximized = s.value,
```

**No backend reports a window of nought by nought.** Minimising is an
`.iconify` event and nothing else, and `framebufferSize` keeps answering the
last real size until the window comes back - a swapchain cannot be 0x0, and a
program that resized to one crashed on the way back. Coming back says so:
`.iconify` false, and `.maximize` false when a maximised window is restored.

**`restore()` reaches the state it reports**, neither minimised nor
maximised, in one step - Windows alone would bring a window minimised from
maximised back maximised. **`setSizeLimits` applies at once**, to a window
already outside the limits as well as to the next drag, except while the
window is maximised, minimised or fullscreen, when it meets them on becoming a
window again.

**`win.monitor()` is the monitor the window is on**, as an index into
`ctx.monitors()`: the one Windows says, the one a Wayland surface last
entered, the one showing most of an X11 window - and the primary one where the
system cannot tell. What `setFullscreen(.{ .borderless = win.monitor().? })`
wants.

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

**A mode that holds the pointer holds it only while the window has focus.**
Alt-tab lets it go and coming back takes it again, on every backend, and a
mode asked for in the background waits for the window to come forward - so a
game never traps the pointer of someone using another program. Closing the
window lets go too, and puts back a display mode an exclusive fullscreen
changed: both belong to the whole machine, and would outlive the program.

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

**A position is in the framebuffer's pixels, on every backend**: a
`.cursor`, a button's `x` and `y`, a drop's, `setCursorPos` and
`setTextInputArea`. They are the pixels a program draws, so a click lands on
what was drawn under it without converting anything - where Windows and X11
already count, and where a browser's CSS pixels and a Wayland surface's are
turned by the backend. `win.size()` is the one answer in logical units, for a
layout written in them: divide a position by `framebufferSize` over `size`.

**A wheel turns in notches, and a text view scrolls by the user's setting.**
`.scroll` counts notches, which is what a zoom wants; `ctx.scrollLines()` is
how many lines - and characters, sideways - the user has the system scroll
text by for one. Windows' own setting, `.page` when it is a screen at a time;
KDE's `WheelScrollLines`; three wherever a system has no such setting, which
is GNOME, Android and a browser, where the page has had it applied already.

**A double click is the system's.** A press that makes one says so with
`double_click`, and a third press starts again. Windows decides by its own
setting; X11 and Wayland by KDE's `DoubleClickInterval`, or 400 ms, within
5 logical pixels; a browser by 400 ms too. A finger's double tap is Android's
rule, on Android and on a page: 300 ms from the first lift, within 100 dp. The
two times behind a text field are there to ask: `ctx.doubleClickTime()` and
`ctx.caretBlinkTime()`, how long a caret shows before it hides, null where the
user turned blinking off.

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

**AltGr is its own modifier, `mods.alt_graph`.** Windows - and every browser
on it - reports the right alt of a European layout as control and alt held
together, so a program that treated control as a shortcut ate every `@` a
Hungarian typed, and one that refused control-with-alt lost real shortcuts.
Here `control` means a control key on every backend, and the left control
Windows invents for AltGr is not reported as a key at all.

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
| `web` | `KeyboardEvent.key`, or a hidden text field once text input is on | composition events, delivered as `.preedit` |

Two of those are real gaps rather than platform limits, and they are written
down rather than papered over. On X11 the composition is drawn by the input
method itself, which is what the root preedit style means and what every
toolkit falls back to; delivering it to the program needs
`XIMPreeditCallbacks`. On Wayland there is no input method at all yet, though
dead keys and compose sequences work.

## The clipboard is text, and the same text everywhere

```zig
const command = k.mods.control and !k.mods.alt;               // not AltGr
if (command and k.virtual == .c) try ctx.setClipboardText(field.selected());
if (command and k.virtual == .v) field.insert(try ctx.clipboardText());
```

UTF-8 with `\n` between lines, going in and coming out, on every backend.
Windows keeps UTF-16 with `\r\n`, Android keeps UTF-16, an old X11 program
offers Latin-1, and whatever copied may have written any of those - or bytes
that are not text at all. Each is converted at the edge, and what cannot be
read as text arrives as U+FFFD rather than as an error. The answer is the
context's, valid until the next call.

**Pasting is the program's.** Ctrl+V arrives as the key it is, and the
program asks `clipboardText` what to insert - which is why the shortcut
compares `virtual`, the letter the layout puts on the key.
`hasClipboardText` answers without reading, for a Paste entry that greys out.

**A read may wait.** On X11 and Wayland nothing keeps the clipboard: the
program that copied holds it, and reading means asking that program. The
read gives up after a second in which that program has said nothing, so one
that has hung costs a second and an empty answer rather than this program's
whole future.

| | copy | paste | worth knowing |
| --- | --- | --- | --- |
| `win32` | `CF_UNICODETEXT`, with `\r\n` | the same, which Windows makes from any other text format | outlives the program |
| `x11` | owns `CLIPBOARD`, answers `UTF8_STRING` and `text/plain;charset=utf-8` | asks the owner, in pieces (`INCR`) when it is large | handed to a clipboard manager at exit, where one runs; a copy goes out in one request, so 16 MB at most |
| `wayland` | a data source, written down a pipe | a data offer, read from a pipe | only while a window has the keyboard, which is Wayland's own rule |
| `android` | `ClipboardManager`, over JNI | the same | read only in the foreground from Android 10, with a notice from 12 |
| `web` | `navigator.clipboard`, or the copy command over plain http | the last paste the page heard | a page may read only when somebody pastes |

**On a page, the paste comes with the key.** A browser lets a page read the
clipboard only inside a paste, so the glue keeps the text of the last one -
and ctrl+V's paste arrives in the same pump as ctrl+V's key, which is all a
program pasting on the shortcut needs. That paste is kept out of the hidden
text field, so it is inserted once, by the program, as it would be anywhere
else; a paste from the browser's own menu still types into the field.
Writing may want a key press or a click first, in Firefox and Safari, and is
tried again inside the next one.

## Files and folders come from the system's dialog

```zig
const asked = try ctx.openFileDialog(.{
    .window = win,
    .multiple = true,
    .filters = &.{.{ .name = "Scenes", .extensions = &.{ "scene", "json" } }},
});
_ = try ctx.openFolderDialog(.{ .window = win, .title = "Open project" });

switch (ev) {
    .file_dialog => |d| if (d.id == asked) for (d.paths, 0..) |path, i| {
        const bytes = try ctx.chosenFile(i, gpa); // or open `path` yourself, on a desktop
        defer gpa.free(bytes);
        try load(path, bytes);
    },
    else => {},
}
```

**The call does not wait.** It hands back an id at once, and the answer is a
`.file_dialog` event some frames later with that id and the paths - none when
the user cancelled. The loop goes on while the dialog is open, so the window
keeps drawing and its events keep coming, and a program asks the same way on
every platform, including the ones that could not wait for a dialog if they
wanted to. The paths are the library's until the next `pump`, like a drop's.

**A path is not always a path.** On the desktop it is one, and a folder answers
with itself. A page and an Android app are handed documents rather than paths,
so there the answer names them - a folder answers with every file inside it,
named by its path in the folder - and `ctx.chosenFile` has the bytes. It works
on the desktop too, reading the path, so the loop above is the same everywhere.

A folder to start in may be written with either slash, on Windows as well.

**One at a time.** Asking while a dialog is open is `error.Unavailable`, and
so is a filter that some system would read differently: an extension is
`"png"` or `".png"`, never `"*.png"` or `"png;jpg"`, and `"*"` lets any file
through.

| | files | a folder | worth knowing |
| --- | --- | --- | --- |
| `win32` | `IFileOpenDialog`, several with `multiple` | the same, picking folders | on a thread of its own and modal over the window, which is disabled meanwhile; paths are WTF-8, which is what Zig's file functions take; a dialog still open when its window or the context goes is closed as Cancel |
| `x11`, `wayland` | the desktop portal's `FileChooser`, over D-Bus | the same, with `directory` | on a thread of its own; told the window as `x11:<id>`, or on Wayland through xdg-foreign where the compositor has it; with no portal, zenity or kdialog (KDE first on KDE); closed through `Request.Close` when its window or the context goes |
| `android` | the system's document picker, `ACTION_OPEN_DOCUMENT` | `ACTION_OPEN_DOCUMENT_TREE`, every file inside | names, never paths; needs `FluxionActivity` in the manifest - see below; a filter is MIME types, and an extension Android has no type for lets everything through |
| `web` | an `<input type="file">` | `webkitdirectory`, every file inside | names, never paths; opened inside a click or a key press - the next one, if none has just happened; no title and no folder to start in |

**On Android the dialog needs one Java class.** A `NativeActivity` never hands
`onActivityResult` to native code, and the document picker answers nowhere
else, so this library carries `FluxionActivity`: a `NativeActivity` with that
one method. An app names it in its manifest and packs it into its APK:

```xml
<application android:hasCode="true" ...>
    <activity android:name="dev.fluxion.platform.FluxionActivity" ...>
        <meta-data android:name="android.app.lib_name" android:value="yourlib" />
```

```bash
zig build android-dex -Dandroid-sdk=<sdk>   # zig-out/android/classes.dex; ANDROID_HOME works too
aapt add app.apk classes.dex                # beside lib/<abi>/libyourlib.so, before zipalign
```

An app still on `android.app.NativeActivity` runs as before, and its dialog is
`error.Unavailable`. The Java side answers even an activity the system rebuilt
while the picker was open - which a low-memory phone does - and the answer is
let go there rather than crashing it. A package that builds its own APK can
compile the source itself: it is `b.dependency(...).namedLazyPath("FluxionActivity.java")`.

## Files dropped on a window, and the trash

```zig
switch (ev) {
    .drop => |d| for (d.paths) |path| try bringIn(path, d.x, d.y), // where they were let go
    else => {},
}
if (platform.trash.available) try platform.trash.move(gpa, io, "C:/game/art/old.png");
```

**A drop is one event for the whole armful**: every path, and the point it
was let go at, in content-area coordinates like a `.cursor` event's - the
folder or the thing under it is where it goes. The paths are the library's
until the next `pump`, as a dialog's answer is. Windows (`WM_DROPFILES`) and
the web have drops; X11 and Wayland do not yet.

**The trash needs no window**, so a tool with none can use it, and a test.
On Windows it asks the shell - `SHFileOperationW` with undo, the call
Explorer's own Delete makes - and something the Recycle Bin cannot take is
asked about before it is deleted for good, never deleted without a word. On
a Linux desktop it follows the freedesktop.org Trash specification in the
home trash, so a file manager's Restore puts the file back; one on another
drive is `error.OtherDrive`, since moving it there would be copying it.
`trash.freedesktop.move` does the same into any folder, which is what a test
uses. Anywhere else it is `error.Unsupported`, and `trash.available` says so
before anything is tried.

## The system's folders, its font, and handing things over

```zig
const settings = try platform.folders.path(gpa, io, .config);   // %APPDATA%, ~/.config
const face = try platform.fonts.systemUi(gpa, io);              // Segoe UI, what fontconfig picks
try platform.shell.showInFolder(gpa, io, "C:/game/art/hero.png");
try platform.shell.openUrl(gpa, io, "https://ziglang.org/");
```

Three things a program otherwise finds out from environment variables and a
list of guesses, and gets wrong on somebody's machine. None needs a window.

**`folders.path` is the system's answer**: `home`, `documents`, and `config`,
`data` and `cache` for what a program keeps. Documents moved to OneDrive, and
a Linux desktop's in its own language - `~/Dokumentumok` - are where they
really are. A folder that is not there is not made.

**`fonts.systemUi` is the font the system's own dialogs use**, as a path and,
for a collection, which face in it: the message font Windows is set to, found
in the registry's list of installed fonts; what fontconfig makes of
`sans-serif`; Roboto on a phone. A face inside a collection comes back as
the file and its index - Microsoft YaHei UI is the second face of `msyh.ttc`.

**`shell` says what went wrong**, where starting `explorer` or `xdg-open` and
hoping says nothing: `error.FileNotFound`, `error.NoHandler` when nothing opens
that kind of thing, `error.Refused`. `shell.support` says which of the three
calls a build has.

| | `folders` | `fonts.systemUi` | `shell` |
| --- | --- | --- | --- |
| Windows | `SHGetKnownFolderPath`: the roaming profile for config and data, the local one for the cache | `SPI_GETNONCLIENTMETRICS`, then the registry's font list | `ShellExecuteW`; `SHOpenFolderAndSelectItems`, with the file selected |
| Linux, BSD | the XDG base directories, and `user-dirs.dirs` for documents | fontconfig, loaded when asked; a list of the usual files without it | the portal's `OpenURI` for an address and the file manager's `ShowItems` over D-Bus, then `xdg-open`, whose exit code is read |
| macOS | `~/Library/Application Support` and `Caches` | San Francisco, then Helvetica | `open`, and `open -R` to show |
| Android | the app's own storage; documents are the part a file manager sees | Roboto | `openUrl` only, as an `ACTION_VIEW` intent - which also opens the `content://` a file dialog answers with |
| web | `error.Unsupported` | `error.Unsupported` | `openUrl` only, in a new tab; `error.Refused` when the popup blocker says no |

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
the one to use. The window is itself a resolver in `fluxion-dyn`'s sense - it
has a `get` - so `api.load(win)` is the whole handover, with no wrapper and no
`Chain`: the backend already looks in both places a command can be. Note that a non-null answer is not proof a function exists —
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

**A shortcut wants the other name.** Ctrl+Z means the Z the user can see, and
on a German or Hungarian keyboard that is the key `Key.y` names. So a key event
carries two, and only two: `key`, the physical key, and `virtual`, the key as
the layout in use names it.

```zig
.key => |k| {
    if (k.key == .w) camera.forward();                         // a position
    if (k.mods.control and k.virtual == .z) history.undo();    // a letter
},
```

On Windows, AltGr arrives as control and alt together, and types characters -
`@` on a Hungarian keyboard is AltGr and V - so a program that reads control as
a command wants alt not held as well.

Only letters move. A key that types a Latin letter is that letter, wherever the
layout put it; a letter from another alphabet is the Latin letter of its place,
the way every system does it for shortcuts, so ctrl+C still copies on a
Cyrillic or a Greek keyboard; and a letter's place that holds something else -
AZERTY's comma, where US has M - is `unknown`, so that no two keys claim one
letter. Digits and punctuation stay where they are, because on AZERTY and on a
Czech keyboard the digits are the shifted half of their keys.

Each system is asked the same question - what does this key type on its own,
before shift or AltGr choose another character - and answers it its own way:
Windows with its virtual key, a browser with `KeyboardEvent.key` and its layout
map, X11 and Wayland with the keysym on the key's first level, Android with
`getUnicodeChar`. One rule, in `backend/virtual_key.zig`, turns the answer into
`virtual` everywhere.

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

## A browser owns the loop

Built for `wasm32-freestanding`, a window is a `<canvas>` and the events come
from the page, through `fluxion-platform.js` — the JavaScript half of the
backend, one file with no dependencies. Everything above holds: the same
queue, the same `Key` at the same positions, the same `.char` for what was
typed. What does not hold is `while`.

**A page cannot be blocked.** Nothing is drawn and no event is delivered until
the module returns to the browser, so a loop that never returns is a frozen
tab. There are two ways to live with that, and the glue picks by what the
module exports:

```zig
// Everywhere, Safari included: the page calls these, once per animation frame.
export fn init() bool { ... }
export fn frame() bool {
    ctx.pump() catch return false;
    while (ctx.poll()) |ev| handle(ev);
    draw();
    return !win.shouldClose();
}
```

The body of `frame` is the body of a desktop loop, `pump` included. Only the
`while` moved into the browser — and the state moved to module scope, because
there is no `main` to own it and a `Context` must not move once it has a
window. It is the shape `fluxion-webgl` already has, and a page can drive
both with one module.

Or keep `main`, and its loop, exactly as it is on the desktop:

```zig
pub fn main() !void {
    ...
    while (!win.shouldClose()) {
        try ctx.pump(); // the browser's turn - back at the next animation frame
        ...
    }
}
```

Here `pump` is where the module is *suspended*, handing the browser its turn,
and resumed at the next animation frame with whatever the page heard. That
takes JavaScript Promise Integration: Chrome and Edge since 137 and Firefox
since 153 have it, and Safari does not yet — where it is missing the glue
refuses by name rather than hanging the tab. A loop that pumps once a frame is
paced by the display, the way a desktop loop is paced by its swap.

The page itself is three lines:

```js
import { Platform } from "./fluxion-platform.js";

const platform = new Platform({ canvas: document.querySelector("canvas") });
await platform.run("./game.wasm");
```

The first windows take the canvases the page handed over, in order; any after
that are made and appended. `run(url, { with: [glue] })` merges another glue's
imports into the same module — `fluxion-webgl.js`, say — and hands it the
module's memory afterwards. `platform.canvas(win.native())` is the element
behind a window, for a WebGPU binding that wants to make a surface from it.

**What a page cannot do is refused by name**, as everywhere else: there is no
screen position to read or set, nothing to iconify, no visible pointer held
inside an element (`.captured`), no warping the pointer, no display mode to
switch (`.exclusive`), and no Vulkan. The rest maps onto the page: a title is
`document.title`, maximised is filling the page, sizes are CSS pixels and the
framebuffer is device pixels, the scale is `devicePixelRatio` and changes when
the page is zoomed.

**Some things need a person to have just done something.** Browsers grant
pointer lock, fullscreen and a phone's soft keyboard only in answer to a click
or a key. The call is accepted either way, and if the browser turned it down
the glue asks again inside the next click or key press on the canvas — which is
what "click to capture the mouse" means on every web game. Escape always takes
pointer lock and fullscreen back; the next click takes the pointer again.

**OpenGL is WebGL, and it is not reached through addresses.** A window made
with `.gl = .{ .api = .opengl_es, .major = 3, .minor = 0 }` gets WebGL 2 on its
canvas, ES 2.0 gets WebGL 1 or 2, and desktop OpenGL is refused rather than
quietly handed ES, whose shaders are another language. `contextConfig` reads
back what the browser really gave. But `getProcAddress` answers null for every
name: WebGL is JavaScript, a wasm module calls it through imports rather than
pointers, and [Fluxion WebGL](https://github.com/kisstp2006/fluxion-webgl) is
the binding that declares them. Both glues can own one canvas — whichever asks
for a context first makes it, and the other gets the same one.

**A lost context is the Android pair of events.** A GPU reset, or a phone
taking the memory back, arrives as `.surface_lost`; the context coming back
arrives as `.surface_created`. A program already written for a phone rebuilds
its GL objects there and is correct in a browser too. Likewise a hidden tab is
`.suspended` and a shown one `.resumed`: animation frames stop in between, and
a program gets one last turn to hear that they are about to.

**Text goes through a hidden field once text input is on**, because an input
method and a soft keyboard attach only to something editable and a canvas is
not. With it off, `.char` comes straight from the keyboard as on a desktop.
Dropped files arrive as `.drop` with names rather than paths — a page never
sees a path — and `platform.web.droppedFile` hands over the bytes. A file
dialog's answer is the same, with `ctx.chosenFile`; the glue reads the files
before the answer arrives, a whole folder only as far as its `maxChosenBytes`
goes (256 MB unless the page says otherwise), and a file past that is named
but not read.

Controllers need no mapping file in the common case, for the same reason as
everywhere else: a browser that recognises a pad says `mapping: "standard"` and
puts every control where the W3C layout says, which is this library's layout.
And a pad appears only once a button has been pressed with the page visible —
browsers keep them hidden until then, so that a page cannot fingerprint what is
plugged in.

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

The web backend is the one that loads nothing, because there is nothing to
open: its calls are WebAssembly imports, resolved by the page before the
module runs. It is imported only for `wasm32-freestanding` - the one target
where a page is what is on the other side.

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
zig build example-window   # a window, every event it produces, and the file dialogs
zig build example-gl       # an OpenGL context, clearing to a colour that moves
zig build example-text     # typing, the difference between a key and a letter, and the clipboard
zig build example-vulkan   # an instance from fluxion-vulkan, and the surface made from a window
zig build example-web      # the browser examples, into zig-out/web
zig build android-dex      # FluxionActivity for an APK, into zig-out/android
```

The second takes `--frames N` so a run ends on its own.

The browser examples are a page rather than a program: both modules, both
glues and an `index.html`, in `zig-out/web`. Serve that directory rather than
opening it - a page cannot `fetch` its own `file://` neighbours, and ES modules
will not load from one either:

```bash
python -m http.server 8000 --directory zig-out/web
```

`web.wasm` exports `frame` and runs everywhere; `web_loop.wasm` is `gl.zig`'s
desktop loop, unchanged, for a browser with JavaScript Promise Integration.
The page switches between them, and prints every event either produces.

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

The clipboard is read on a real backend but never written: a test run that
replaced whatever the person running it had copied would be a nuisance. The
writing is checked against the web backend's fake page, the conversions on
every host, and the rest by `example-text`.

No test shows a file dialog, for the same reason. The Windows one is taken up
to the moment it would be shown and abandoned there - which still makes the
COM object and calls every method before `Show`, whose places in its table a
test counts against the header - and its empty answer comes out of a real
pump. The web one is checked against the fake page. What Linux says to the
portal and to zenity and kdialog is bytes and strings, checked on every host
down to the D-Bus alignment, and so are the JNI slots and the methods the Java
and the Zig halves of `FluxionActivity` expect of each other. O and D in
`example-window` and `example-web` open the real ones.

`shell` is tested the same way: nothing is opened, only a path that is not
there is refused before anything starts, and what goes over D-Bus and what
`xdg-open`'s exit code means are checked as bytes. What a window does when
focus moves, when it is minimised and when AltGr goes down is driven with the
messages the system would send - posted to a hidden window on Windows, sent
through the server on X11 - so the pointer is held for no longer than a test.

The web backend runs its tests on every host, against a page that is not
there: `web_stub.zig` answers every import the browser would, and a test
queues what a listener would have heard and reads back the event the backend
made of it. What keeps the stub honest is the suite's other half - it also
*compiles* the library and both browser examples for `wasm32-freestanding`,
where `web.verify` compares every import against the stub's signature, so the
two cannot drift apart without the build saying so.

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
