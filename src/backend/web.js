// SPDX-License-Identifier: BSL-1.0
//
// The other side of `web.zig`: every import `web_imports.zig` declares,
// implemented against a page. Installed beside a program as
// `fluxion-platform.js`, and the only JavaScript the platform layer needs -
// one file, no dependencies, no build step.
//
//   import { Platform } from "./fluxion-platform.js";
//
//   const platform = new Platform({ canvas: document.querySelector("canvas") });
//   await platform.run("./game.wasm");
//
// Four jobs, and every one of them is a job some other backend's operating
// system does for it:
//
//   1. Listen. Keys, the pointer, the wheel, focus, resizes, visibility,
//      drops, a lost WebGL context - each listener turns what it heard into a
//      plain object on `events`, and does nothing else. Nothing calls into
//      the module from a listener: the module reads the queue when it pumps,
//      which is the whole design of the library on the other side.
//
//   2. Hand it over. `drain` writes the queue into the module's memory as
//      sixty-four-byte records, at the offsets `web_wire.zig` pins in its
//      tests. Text rides alongside in a second buffer.
//
//   3. Stand in for the parts of a window a page does not have: a hidden text
//      field for the input method and the soft keyboard, pointer lock for a
//      captured mouse, the Fullscreen API for a fullscreen window, the last
//      paste for a clipboard it may not read, a hidden file input for the
//      system's file dialog - and asking again on the next click for anything
//      the browser would only grant to a person who had just done something.
//
//   4. Run the program, one of two ways. A module that exports `frame` is
//      called once per animation frame. A module whose `main` is a loop is
//      suspended in `pump` until the next frame, through JavaScript Promise
//      Integration, and a browser that has none says so rather than hanging.
//
// It composes: `instantiate(url, { with: [other] })` merges another glue's
// imports - `fluxion-webgl.js`, say - into the same module, and hands it the
// module's memory afterwards. Both can own the same canvas: whichever asks
// for a WebGL context first makes it, and the other gets the same one.

// -------------------------------------------------------------------------
// The wire. Every number here is also in `web_wire.zig` or `web.zig`, and the
// tests there fail if either side moves.
// -------------------------------------------------------------------------

const KIND = {
  key: 1,
  char: 2,
  button: 3,
  cursor: 4,
  scroll: 5,
  enter: 6,
  focus: 7,
  resize: 8,
  visibility: 9,
  maximize: 10,
  preedit: 11,
  dropBegin: 12,
  dropFile: 13,
  surfaceLost: 14,
  surfaceCreated: 15,
  dialogBegin: 16,
  dialogFile: 17,
};

/// `Record`: kind, window, a, b, c, d as 32-bit integers from offset 0, then
/// x, y, dx, dy as doubles from 24, then where its text is at 56 and 60.
const RECORD_SIZE = 64;
/// `WindowInfo`.
const INFO_SIZE = 72;
/// `GamepadRecord`, and the longest `id` it holds.
const PAD_SIZE = 312;
const PAD_ID = 128;

/// `keys.Mods`, bit for bit.
const MOD = { shift: 1, control: 2, alt: 4, super: 8, capsLock: 16, numLock: 32 };

/// `createWindow`'s flags, and its context flags.
const FLAG = { resizable: 1, decorated: 2, visible: 4, maximized: 8 };
const CONTEXT = { depth: 1, stencil: 2, antialias: 4 };

/// `openFileDialog`'s flags.
const DIALOG = { multiple: 1, folder: 2 };

/// `backend.WindowState` and `cursor.Mode`, by number.
const STATE = { iconified: 0, maximized: 1, restored: 2, focused: 3, attention: 4 };
const MODE = { normal: 0, hidden: 1, captured: 2, disabled: 3 };

/// `cursor.Shape`, in order, as the CSS cursors that draw them.
const SHAPES = [
  "default",
  "text",
  "crosshair",
  "pointer",
  "ew-resize",
  "ns-resize",
  "nwse-resize",
  "nesw-resize",
  "move",
  "not-allowed",
];

/// `MouseEvent.buttons` is a bitmask, and `MouseEvent.button` a number, and
/// the two count differently: bit 2 is the right button and number 2 is too,
/// but bit 4 is the middle one, which is number 1. This is the table between.
const BUTTON_BITS = [
  [1, 0],
  [2, 2],
  [4, 1],
  [8, 3],
  [16, 4],
];

// -------------------------------------------------------------------------
// Keys
// -------------------------------------------------------------------------

/// The key names a soft keyboard sends with no `code` - it has no positions
/// to report - but which still name one key. Spelled the same as the codes,
/// so the table on the Zig side takes them as they are.
const NAMED_WITHOUT_CODE = new Set([
  "Enter",
  "Backspace",
  "Tab",
  "Escape",
  "Delete",
  "Insert",
  "Home",
  "End",
  "PageUp",
  "PageDown",
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
]);

/// What the browser keeps even from a focused canvas: reload, its own
/// fullscreen, and its developer tools. Everything else a game may want -
/// space, the arrows, tab, backspace - is taken, or the page scrolls, focus
/// leaves and the browser goes back a page.
const BROWSER_KEYS = new Set(["F5", "F11", "F12"]);

/// The keys that would move the hidden text field's caret or its focus. The
/// program has its own caret and handles these as keys; the field must stay
/// exactly as it is, or the next edit is read against the wrong text.
const FIELD_KEYS = new Set([
  "Tab",
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "Home",
  "End",
  "PageUp",
  "PageDown",
]);

/// The shortcuts that would select, undo or redo inside the hidden text field,
/// by the letter the layout puts on the key - which is how the browser picks
/// them. The program has its own selection and its own history, and hears
/// these as keys. Run in the field as well, a select-all there takes in the
/// field's one character, and the next letter typed over it is read as a
/// backspace.
const FIELD_SHORTCUTS = new Set(["a", "z", "y"]);

/// What the hidden field holds when nothing is being typed. Never empty: a
/// soft keyboard's backspace in an empty field deletes nothing, and some send
/// no event at all for it. With a character there to delete there is always
/// an `input` event to read the deletion from.
const SENTINEL = " ";

/// Apple keyboards send no `keyup` for a key released while command is held,
/// which would leave it down in `input.State` for ever.
const APPLE = /Mac|iPhone|iPad|iPod/.test(
  (typeof navigator !== "undefined" &&
    (navigator.userAgentData?.platform || navigator.platform)) ||
    "",
);

/// JavaScript Promise Integration: the one way to suspend a wasm module in
/// the middle of a call and resume it later. Chrome and Edge since 137,
/// Firefox since 153; not Safari, yet.
const JSPI =
  typeof WebAssembly !== "undefined" &&
  typeof WebAssembly.Suspending === "function" &&
  typeof WebAssembly.promising === "function";

/// A page that never pumps would otherwise collect events until it ran out of
/// memory. A hundred thousand is minutes of a mouse being waved about.
const MAX_EVENTS = 100000;

function modsOf(event) {
  let bits = 0;
  if (event.shiftKey) bits |= MOD.shift;
  if (event.ctrlKey) bits |= MOD.control;
  if (event.altKey) bits |= MOD.alt;
  if (event.metaKey) bits |= MOD.super;
  if (event.getModifierState?.("CapsLock")) bits |= MOD.capsLock;
  if (event.getModifierState?.("NumLock")) bits |= MOD.numLock;
  return bits;
}

/// Where a key is: its `code`, or for the few keys a soft keyboard sends
/// without one, its name. Empty for a key with neither, which is not reported
/// as a key at all - it has no position to report.
function positionOf(event) {
  if (event.code && event.code !== "Unidentified") return event.code;
  if (NAMED_WITHOUT_CODE.has(event.key) || /^F\d{1,2}$/.test(event.key)) return event.key;
  return "";
}

/// Whether a key is one of `FIELD_SHORTCUTS`: control or command with the
/// letter, and not AltGr, which Windows reports as control and alt together.
function isFieldShortcut(event) {
  const command = (event.ctrlKey || event.metaKey) && !event.getModifierState?.("AltGraph");
  return command && FIELD_SHORTCUTS.has(event.key?.toLowerCase());
}

/// Whether a key is the paste shortcut: control or command with the V the
/// layout puts on its key - or with the key where V is, on a layout with no
/// Latin letters, which is where the browser looks - or shift with insert.
function isPasteShortcut(event) {
  const command = (event.ctrlKey || event.metaKey) && !event.getModifierState?.("AltGraph");
  if (!command) return event.shiftKey && event.key === "Insert";
  const key = event.key?.toLowerCase() ?? "";
  return key === "v" || (!/^[a-z]$/.test(key) && event.code === "KeyV");
}

/// What a key typed, when the field is not in the way: `key`, if it is one
/// codepoint. A named key is longer - `Enter`, `Dead`, `Shift` - and a
/// shortcut is not typing. AltGr is control and alt together on Windows, and
/// what it types is text, which is what `AltGraph` is there to say.
function typedBy(event) {
  const key = event.key;
  if (!key || [...key].length !== 1) return "";
  if ((event.ctrlKey || event.metaKey) && !event.getModifierState?.("AltGraph")) return "";
  return key;
}

/// How many bytes of UTF-8 a string is.
function utf8Length(text) {
  let bytes = 0;
  for (const ch of text) {
    const code = ch.codePointAt(0);
    bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
  }
  return bytes;
}

/// The longest prefix of `bytes` no longer than `limit` that does not cut a
/// character in half.
function cutUtf8(bytes, limit) {
  if (bytes.length <= limit) return bytes.length;
  let end = limit;
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end -= 1;
  return end;
}

function canvasesFrom(option) {
  if (!option) return [];
  if (typeof option === "string") return [...document.querySelectorAll(option)];
  if (option instanceof Element) return [option];
  return [...option];
}

async function compileModule(source) {
  if (source instanceof WebAssembly.Module) return source;
  if (source instanceof ArrayBuffer || ArrayBuffer.isView(source)) {
    return WebAssembly.compile(source);
  }
  const response = source instanceof Response ? source : await fetch(source);
  if (!response.ok) {
    throw new Error(`could not fetch ${response.url || source}: ${response.status}`);
  }
  // `compileStreaming` wants the server to say `application/wasm`, and most
  // one-line servers do not. The bytes work everywhere.
  return WebAssembly.compile(await response.arrayBuffer());
}

function defaultLog(level, text) {
  const method = ["debug", "info", "warn", "error"][level] ?? "log";
  console[method](text);
}

// -------------------------------------------------------------------------
// One window: a canvas, and everything the glue remembers about it
// -------------------------------------------------------------------------

class Win {
  constructor(id, handle, canvas, entry) {
    this.id = id;
    this.handle = handle;
    this.canvas = canvas;
    /// The page's own canvas, lent for as long as the window lives - or null
    /// for one made here, which is removed again afterwards.
    this.entry = entry;
    this.savedStyle = entry ? canvas.getAttribute("style") : null;
    this.savedTabIndex = entry ? canvas.getAttribute("tabindex") : null;
    /// Every listener hangs off this, so one `abort` takes them all away.
    this.controller = new AbortController();
    this.observer = null;
    this.devicePixelBox = false;

    this.gl = null;
    this.glVersion = 0;

    this.cssWidth = 0;
    this.cssHeight = 0;
    this.fbWidth = 0;
    this.fbHeight = 0;
    this.scale = 1;
    this.reported = null;

    this.focused = false;
    this.maximized = false;
    this.unfilled = null;

    this.mode = MODE.normal;
    this.shape = 0;
    this.rawWanted = false;
    this.locked = false;
    this.skipMotion = false;
    this.buttons = 0;
    this.lastX = 0;
    this.lastY = 0;
    this.hasPosition = false;
    this.lastMods = 0;
    this.down = new Set();

    this.textInput = false;
    this.field = null;
    /// What the field held after the last edit was read: everything before
    /// the caret that has already been reported.
    this.base = SENTINEL;
    this.composing = false;
    this.area = null;
    this.sawDelete = false;
    this.sawEnter = false;

    /// Asked for and turned down, for want of a click. Tried again inside
    /// the next one.
    this.pendingLock = false;
    this.pendingFullscreen = false;
  }
}

// -------------------------------------------------------------------------
// The glue
// -------------------------------------------------------------------------

export class Platform {
  /// Whether this browser can suspend a module, which a program whose `main`
  /// is a loop needs.
  static get jspi() {
    return JSPI;
  }

  /// `canvas` is a canvas, a list of them, or a selector: the page's own,
  /// taken by the first windows in order. Windows after those get canvases of
  /// their own, appended to `container` - the body, unless told otherwise.
  /// `log(level, text)` is where the program's console lines go.
  /// `maxDropBytes` is the largest dropped file read into memory for
  /// `web.droppedFile`, and `maxChosenBytes` the most read of one file
  /// dialog's answer, every file together, for `Context.chosenFile`.
  constructor(options = {}) {
    this.options = options;
    this.pool = canvasesFrom(options.canvas).map((canvas) => ({ canvas, taken: false }));
    this.container = options.container ?? null;
    this.logSink = options.log ?? defaultLog;
    this.maxDropBytes = options.maxDropBytes ?? 256 * 1024 * 1024;
    this.maxChosenBytes = options.maxChosenBytes ?? 256 * 1024 * 1024;

    this.windows = new Map();
    this.nextHandle = 1;
    this.events = [];
    this.warnedFull = false;

    this.memory = null;
    this.exports = null;
    this.model = null;
    this.running = false;
    this.stopped = false;
    this.frameRequest = 0;

    this.frameWaiters = [];
    this.eventWaiters = new Set();
    this.yielded = false;
    this.tickPending = false;
    this.lastTick = 0;
    this.gaps = [];

    this.dropped = [];
    /// The file dialog that is open, or waiting for a click to open in.
    this.dialog = null;
    /// The files of the last dialog's answer, as `Context.chosenFile` reads them.
    this.chosen = [];
    this.rawSupported = undefined;
    this.global = null;
    this.focusQueued = false;

    /// The clipboard as far as the page knows it - the last paste, or what
    /// the program put there since - and null until it knows anything.
    this.clipboard = null;
    this.clipboardBytes = null;
    /// Text the browser has not taken yet, offered again in the next gesture.
    this.clipboardPending = null;
    /// Set by the paste shortcut and read by the paste it causes, which the
    /// browser fires before the key comes back up.
    this.pasteShortcut = false;

    this.decoder = new TextDecoder();
    this.encoder = new TextEncoder();
    this.cachedU8 = null;
    this.cachedView = null;

    // What each key types on its own, by position, as far as it is known -
    // see `labelOf`. The browser's own map of the layout where it has one,
    // which knows every key before any has been pressed; otherwise learnt a
    // key at a time, from the keys pressed with nothing held.
    this.labels = new Map();
    if (typeof navigator !== "undefined" && navigator.keyboard?.getLayoutMap) {
      navigator.keyboard
        .getLayoutMap()
        .then((map) => {
          for (const [code, key] of map) if (!this.labels.has(code)) this.labels.set(code, key);
        })
        .catch(() => {});
    }
  }

  // -- reading and writing the module's memory --
  //
  // Rebuilt whenever the buffer has been swapped underneath: a module that
  // grows its memory detaches the old `ArrayBuffer`, and a view kept across
  // that call reads nothing.

  get u8() {
    if (!this.cachedU8 || this.cachedU8.buffer !== this.memory.buffer) {
      this.cachedU8 = new Uint8Array(this.memory.buffer);
    }
    return this.cachedU8;
  }

  get view() {
    if (!this.cachedView || this.cachedView.buffer !== this.memory.buffer) {
      this.cachedView = new DataView(this.memory.buffer);
    }
    return this.cachedView;
  }

  text(ptr, len) {
    return this.decoder.decode(this.u8.subarray(ptr >>> 0, (ptr >>> 0) + (len >>> 0)));
  }

  // -- the import object --

  /// Every import `web_imports.zig` declares, under `fluxion_platform`.
  ///
  /// `sync` and `wait` are the two that suspend, and only when the program is
  /// a loop - which `instantiate` works out before it asks for these. A page
  /// that builds its own import object gets the frame model.
  imports() {
    const self = this;
    const suspend = this.model === "loop" && JSPI;

    const sync = () => {
      if (self.model !== "loop") return undefined;
      // A `wait` already gave the browser its turn since the last pump.
      if (self.yielded) {
        self.yielded = false;
        return Promise.resolve();
      }
      return self.nextFrame();
    };

    const wait = (timeout) => {
      if (self.model !== "loop") return undefined;
      if (self.events.length > 0) return Promise.resolve();
      return new Promise((resolve) => {
        let timer = 0;
        const done = () => {
          clearTimeout(timer);
          self.eventWaiters.delete(done);
          self.yielded = true;
          resolve();
        };
        self.eventWaiters.add(done);
        if (timeout >= 0) timer = setTimeout(done, timeout);
      });
    };

    return {
      fluxion_platform: {
        open: () => {
          if (typeof document === "undefined") return 0;
          self.listen();
          return 1;
        },

        close: () => {
          for (const win of [...self.windows.values()]) self.release(win);
          self.dialog?.input.remove();
          self.dialog = null;
          self.global?.abort();
          self.global = null;
          self.events.length = 0;
        },

        createWindow: (id, titlePtr, titleLen, width, height, flags, glVersion, glFlags, infoPtr) =>
          self.createWindow(id >>> 0, self.text(titlePtr, titleLen), width >>> 0, height >>> 0, flags, glVersion, glFlags, infoPtr >>> 0),

        destroyWindow: (handle) => {
          const win = self.windows.get(handle);
          if (win) self.release(win);
        },

        windowInfo: (handle, infoPtr) => {
          const win = self.windows.get(handle);
          if (win) self.writeInfo(win, infoPtr >>> 0);
        },

        setTitle: (handle, ptr, len) => {
          document.title = self.text(ptr, len);
        },

        setVisible: (handle, visible) => {
          const win = self.windows.get(handle);
          // `visibility` rather than `display`: a hidden canvas keeps its
          // size, so a window shown later is the size it was made.
          if (win) win.canvas.style.visibility = visible ? "" : "hidden";
        },

        setSize: (handle, width, height) => {
          const win = self.windows.get(handle);
          if (!win) return;
          self.fill(win, false);
          win.canvas.style.width = `${width >>> 0}px`;
          win.canvas.style.height = `${height >>> 0}px`;
        },

        setSizeLimits: (handle, minWidth, minHeight, maxWidth, maxHeight) => {
          const win = self.windows.get(handle);
          if (!win) return;
          const px = (value) => (value >>> 0 === 0 ? "" : `${value >>> 0}px`);
          Object.assign(win.canvas.style, {
            minWidth: px(minWidth),
            minHeight: px(minHeight),
            maxWidth: px(maxWidth),
            maxHeight: px(maxHeight),
          });
        },

        setOpacity: (handle, opacity) => {
          const win = self.windows.get(handle);
          if (win) win.canvas.style.opacity = String(opacity);
        },

        setState: (handle, state) => {
          const win = self.windows.get(handle);
          if (!win) return 0;
          switch (state) {
            case STATE.maximized:
              self.fill(win, true);
              return 1;
            case STATE.restored:
              self.fill(win, false);
              return 1;
            case STATE.focused:
              self.focusWindow(win);
              return 1;
            // A page cannot minimise the browser, and has no taskbar to
            // flash.
            default:
              return 0;
          }
        },

        getState: (handle, state) => {
          const win = self.windows.get(handle);
          if (!win) return 0;
          switch (state) {
            case STATE.maximized:
              return win.maximized ? 1 : 0;
            case STATE.restored:
              return win.maximized ? 0 : 1;
            case STATE.focused:
              return self.hasFocus(win) ? 1 : 0;
            default:
              return 0;
          }
        },

        setCursorMode: (handle, mode) => {
          const win = self.windows.get(handle);
          // A visible pointer held inside an element is the one thing here no
          // browser can do.
          if (!win || mode === MODE.captured) return 0;
          win.mode = mode;
          if (mode === MODE.disabled) {
            if (document.pointerLockElement !== win.canvas) self.lock(win);
          } else {
            win.pendingLock = false;
            if (document.pointerLockElement === win.canvas) document.exitPointerLock?.();
          }
          self.applyCursor(win);
          return 1;
        },

        setRawMouseMotion: (handle, on) => {
          const win = self.windows.get(handle);
          if (!win) return 0;
          const wanted = on !== 0;
          const changed = wanted !== win.rawWanted;
          win.rawWanted = wanted;
          // Chromium changes a lock's options in place when asked again.
          if (changed && document.pointerLockElement === win.canvas) self.lock(win);
          return self.rawPossible() ? 1 : 0;
        },

        setCursorShape: (handle, shape) => {
          const win = self.windows.get(handle);
          if (!win) return 0;
          win.shape = shape;
          self.applyCursor(win);
          return 1;
        },

        setFullscreen: (handle, on) => {
          const win = self.windows.get(handle);
          if (!win) return 0;
          const canvas = win.canvas;
          // An iPhone's Safari has fullscreen for video and nothing else.
          if (!canvas.requestFullscreen && !canvas.webkitRequestFullscreen) return 0;
          win.pendingFullscreen = false;
          const current = document.fullscreenElement ?? document.webkitFullscreenElement;
          if (on) {
            if (current !== canvas) self.enterFullscreen(win);
          } else if (current === canvas) {
            const exit = document.exitFullscreen ?? document.webkitExitFullscreen;
            exit?.call(document)?.catch?.(() => {});
          }
          return 1;
        },

        setTextInput: (handle, on) => {
          const win = self.windows.get(handle);
          if (!win) return 0;
          if (on) self.startText(win);
          else self.stopText(win);
          return 1;
        },

        setTextInputArea: (handle, x, y, width, height) => {
          const win = self.windows.get(handle);
          if (!win) return;
          win.area = { x, y, width: width >>> 0, height: height >>> 0 };
          self.placeField(win);
        },

        monitor: (ptr) => self.writeMonitor(ptr >>> 0),

        gamepads: (ptr, capacity) => self.writeGamepads(ptr >>> 0, capacity >>> 0),

        drain: (recordsPtr, capacity, heapPtr, heapCapacity) =>
          self.drain(recordsPtr >>> 0, capacity >>> 0, heapPtr >>> 0, heapCapacity >>> 0),

        sync: suspend ? new WebAssembly.Suspending(sync) : sync,
        wait: suspend ? new WebAssembly.Suspending(wait) : wait,

        post: () => self.wakeWaiters(),

        log: (level, ptr, len) => self.logSink(level, self.text(ptr, len)),

        droppedSize: (index) => {
          const file = self.dropped[index >>> 0];
          return file && file.bytes ? file.bytes.length : -1;
        },

        droppedRead: (index, ptr, len) => {
          const file = self.dropped[index >>> 0];
          if (!file || !file.bytes) return 0;
          const count = Math.min(len >>> 0, file.bytes.length);
          self.u8.set(file.bytes.subarray(0, count), ptr >>> 0);
          return count;
        },

        setClipboard: (ptr, len) => self.setClipboard(self.text(ptr, len)),

        clipboardSize: () => (self.clipboard === null ? -1 : self.clipboardEncoded().length),

        clipboardRead: (ptr, len) => {
          if (self.clipboard === null) return 0;
          const bytes = self.clipboardEncoded();
          const count = Math.min(len >>> 0, bytes.length);
          self.u8.set(bytes.subarray(0, count), ptr >>> 0);
          return count;
        },

        openFileDialog: (win, id, flags, acceptPtr, acceptLen) =>
          self.openFileDialog(win >>> 0, id >>> 0, flags >>> 0, self.text(acceptPtr, acceptLen)),

        chosenSize: (index) => {
          const file = self.chosen[index >>> 0];
          return file && file.bytes ? file.bytes.length : -1;
        },

        chosenRead: (index, ptr, len) => {
          const file = self.chosen[index >>> 0];
          if (!file || !file.bytes) return 0;
          const count = Math.min(len >>> 0, file.bytes.length);
          self.u8.set(file.bytes.subarray(0, count), ptr >>> 0);
          return count;
        },
      },
    };
  }

  // -- running a program --

  /// Compile a module, work out how it wants to run, and instantiate it with
  /// these imports and those of every glue in `with`.
  ///
  /// `source` is a URL, a `Response`, bytes, or a compiled module.
  async instantiate(source, { with: others = [] } = {}) {
    const module = await compileModule(source);

    // The model is read off the exports before the imports are made, because
    // the imports differ: a loop needs `sync` and `wait` to suspend it, and a
    // frame must never be suspended at all.
    const names = new Set(WebAssembly.Module.exports(module).map((entry) => entry.name));
    this.model = names.has("frame") ? "frame" : names.has("_start") ? "loop" : null;
    if (!this.model) {
      throw new Error(
        "the module exports neither `frame` nor `_start`: build it with " +
          "`entry = .disabled` and `rdynamic` to export `frame`, or give it a `main`",
      );
    }
    if (this.model === "loop" && !JSPI) {
      throw new Error(
        "this program's `main` is a loop, and this browser cannot suspend WebAssembly " +
          "to let it run one (it has no JavaScript Promise Integration). Chrome and " +
          "Edge 137 and Firefox 153 can; for anything else, export `frame` instead.",
      );
    }

    const imports = {};
    for (const glue of [...others, this]) {
      for (const [name, functions] of Object.entries(glue.imports())) {
        imports[name] = { ...imports[name], ...functions };
      }
    }
    const instance = await WebAssembly.instantiate(module, imports);

    this.attach(instance);
    // The other glues read the same memory, and `fluxion-webgl.js` looks for
    // it under these two names.
    for (const glue of others) {
      glue.memory = instance.exports.memory;
      glue.exports = instance.exports;
      glue.attach?.(instance);
    }
    return instance.exports;
  }

  attach(instance) {
    this.exports = instance.exports;
    this.memory = instance.exports.memory;
    if (!(this.memory instanceof WebAssembly.Memory)) {
      throw new Error("the module does not export its memory, and the glue reads events into it");
    }
  }

  /// Run it until it ends. Resolves when `frame` answers false or `main`
  /// returns, and rejects if the module traps.
  async start() {
    if (!this.exports) throw new Error("instantiate the module first");
    if (this.model === "frame") return this.runFrames();
    return this.runLoop();
  }

  /// `instantiate`, then `start`.
  async run(source, options = {}) {
    await this.instantiate(source, options);
    return this.start();
  }

  /// Stop calling `frame`. A loop cannot be stopped from outside - it is in
  /// the middle of a call - so it is left suspended at its next pump, for
  /// ever, which from the page's side is the same thing.
  stop() {
    this.stopped = true;
    this.running = false;
    if (this.frameRequest) cancelAnimationFrame(this.frameRequest);
    this.frameRequest = 0;
  }

  /// The canvas behind a window's `native()` handle - what a WebGPU binding
  /// wants a surface made from.
  canvas(handle) {
    return this.windows.get(handle)?.canvas ?? null;
  }

  async runFrames() {
    const { init, frame, deinit } = this.exports;
    this.running = true;
    if (typeof init === "function") {
      const ok = init();
      if (ok === 0 || ok === false) {
        this.running = false;
        throw new Error("init() answered false - the console says why");
      }
    }

    await new Promise((resolve, reject) => {
      this.frameDone = resolve;
      this.frameFailed = reject;
      this.frameRequest = requestAnimationFrame((time) => this.step(time));
    });

    if (typeof deinit === "function") deinit();
  }

  /// One animation frame of a frame-model program.
  step(time) {
    this.frameRequest = 0;
    if (!this.running) return this.frameDone?.();
    this.measure(time);
    if (!this.callFrame()) return;
    this.frameRequest = requestAnimationFrame((next) => this.step(next));
  }

  /// Call `frame` once. False when the program is over, one way or the other.
  callFrame() {
    let result;
    try {
      result = this.exports.frame();
    } catch (error) {
      this.running = false;
      this.frameFailed?.(error);
      return false;
    }
    if (result === 0 || result === false) {
      this.running = false;
      this.frameDone?.();
      return false;
    }
    return true;
  }

  async runLoop() {
    this.running = true;
    try {
      await WebAssembly.promising(this.exports._start)();
    } finally {
      this.running = false;
    }
  }

  /// A promise for the next animation frame, which is what `sync` suspends a
  /// loop on.
  nextFrame() {
    return new Promise((resolve) => {
      if (this.stopped) return;
      this.frameWaiters.push(resolve);
      this.requestTick();
    });
  }

  requestTick() {
    if (this.tickPending) return;
    this.tickPending = true;
    requestAnimationFrame((time) => this.tick(time, true));
  }

  /// Resolve everything waiting for a frame. `fromFrame` is false for the one
  /// extra turn a hidden page is given, which must not be mistaken for a
  /// frame: the animation frame asked for earlier is still coming, and the
  /// next wait should be answered by that rather than by a second one.
  tick(time, fromFrame) {
    if (fromFrame) {
      this.tickPending = false;
      this.measure(time);
    }
    const waiters = this.frameWaiters;
    this.frameWaiters = [];
    for (const resolve of waiters) resolve();
  }

  /// Keep the gaps between animation frames, which is the only way a page can
  /// learn how fast its display refreshes.
  measure(time) {
    if (this.lastTick > 0) {
      const gap = time - this.lastTick;
      // A long gap is a frame the program was too busy for, or a tab in the
      // background, and says nothing about the display.
      if (gap > 3 && gap < 100) {
        this.gaps.push(gap);
        if (this.gaps.length > 64) this.gaps.shift();
      }
    }
    this.lastTick = time;
  }

  refreshHz() {
    if (this.gaps.length < 16) return 0;
    const sorted = [...this.gaps].sort((a, b) => a - b);
    return Math.round(1000 / sorted[sorted.length >> 1]);
  }

  // -- the queue --

  queue(event) {
    if (this.events.length >= MAX_EVENTS) {
      this.events.shift();
      if (!this.warnedFull) {
        this.warnedFull = true;
        console.warn("fluxion-platform: the program is not pumping, and old events are being dropped");
      }
    }
    this.events.push(event);
    this.wakeWaiters();
  }

  wakeWaiters() {
    for (const done of [...this.eventWaiters]) done();
  }

  queueText(win, text, mods) {
    for (const ch of text) {
      this.queue({ kind: KIND.char, win: win.id, a: ch.codePointAt(0), b: mods });
    }
  }

  /// A press and a release, for the keys a soft keyboard reports only as an
  /// edit: backspace as a deletion, enter as a new line.
  tap(win, code) {
    this.queue({ kind: KIND.key, win: win.id, a: 1, b: win.lastMods, text: code });
    this.queue({ kind: KIND.key, win: win.id, a: 0, b: win.lastMods, text: code });
  }

  /// Write as much of the queue as fits, and keep the rest for the next call.
  drain(recordsPtr, capacity, heapPtr, heapCapacity) {
    const view = this.view;
    const u8 = this.u8;
    let count = 0;
    let used = 0;

    while (count < capacity && count < this.events.length) {
      const event = this.events[count];
      if (event.text && !event.bytes) event.bytes = this.encoder.encode(event.text);
      const bytes = event.bytes;
      let len = bytes ? bytes.length : 0;
      if (used + len > heapCapacity) {
        // Waiting only helps if the next drain has room, and a text longer
        // than the whole heap never will. Cut it, or it would sit at the
        // front and hold everything behind it.
        if (count > 0) break;
        len = cutUtf8(bytes, heapCapacity);
      }

      const at = recordsPtr + count * RECORD_SIZE;
      view.setUint32(at, event.kind, true);
      view.setUint32(at + 4, event.win ?? 0, true);
      view.setInt32(at + 8, event.a ?? 0, true);
      view.setInt32(at + 12, event.b ?? 0, true);
      view.setInt32(at + 16, event.c ?? 0, true);
      view.setInt32(at + 20, event.d ?? 0, true);
      view.setFloat64(at + 24, event.x ?? 0, true);
      view.setFloat64(at + 32, event.y ?? 0, true);
      view.setFloat64(at + 40, event.dx ?? 0, true);
      view.setFloat64(at + 48, event.dy ?? 0, true);
      view.setUint32(at + 56, used, true);
      view.setUint32(at + 60, len, true);
      if (len > 0) u8.set(bytes.subarray(0, len), heapPtr + used);
      used += len;
      count += 1;
    }

    this.events.splice(0, count);
    return count;
  }

  // -- the page as a whole --

  listen() {
    if (this.global) return;
    this.global = new AbortController();
    const signal = this.global.signal;

    document.addEventListener(
      "visibilitychange",
      () => {
        const hidden = document.visibilityState === "hidden";
        this.queue({ kind: KIND.visibility, win: 0, a: hidden ? 1 : 0 });
        if (hidden) this.lastFrameBeforeHiding();
      },
      { signal },
    );

    document.addEventListener("pointerlockchange", () => this.lockChanged(), { signal });
    document.addEventListener(
      "pointerlockerror",
      () => {
        for (const win of this.windows.values()) {
          if (win.mode === MODE.disabled && !win.locked) win.pendingLock = true;
        }
      },
      { signal },
    );

    window.addEventListener("focus", () => this.focusChanged(), { signal });
    window.addEventListener("blur", () => this.focusChanged(), { signal });
    document.addEventListener("paste", (event) => this.pasted(event), { signal });

    this.watchScale(signal);
  }

  /// A hidden page gets no animation frames, so a program waiting for one
  /// would not hear that it had been hidden until it was shown again. It gets
  /// one more turn now, with `.suspended` in its queue, and then waits.
  lastFrameBeforeHiding() {
    setTimeout(() => {
      if (document.visibilityState !== "hidden" || !this.running) return;
      if (this.model === "loop") this.tick(0, false);
      else if (this.model === "frame") this.callFrame();
    }, 0);
  }

  /// Safari's resize observer has no device-pixel box, so a new scale at the
  /// same CSS size - the window dragged to another display - goes unseen by
  /// it. A media query on the current ratio is the one thing that notices.
  watchScale(signal) {
    if (typeof matchMedia !== "function") return;
    const arm = () => {
      if (signal.aborted) return;
      const query = matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
      query.addEventListener(
        "change",
        () => {
          for (const win of this.windows.values()) {
            if (!win.devicePixelBox) this.measureNow(win);
          }
          arm();
        },
        { once: true, signal },
      );
    };
    arm();
  }

  // -- windows --

  createWindow(id, title, width, height, flags, glVersion, glFlags, infoPtr) {
    if (typeof document === "undefined") return 0;

    const entry = this.pool.find((candidate) => !candidate.taken) ?? null;
    let canvas;
    if (entry) {
      entry.taken = true;
      canvas = entry.canvas;
    } else {
      canvas = document.createElement("canvas");
      Object.assign(canvas.style, { display: "block", width: `${width}px`, height: `${height}px` });
      (this.container ?? document.body).appendChild(canvas);
    }

    const win = new Win(id, this.nextHandle++, canvas, entry);
    this.windows.set(win.handle, win);

    Object.assign(canvas.style, {
      // No panning, zooming or long-press menus from the canvas: those are
      // the page's gestures, and on a canvas they are the program's input.
      touchAction: "none",
      userSelect: "none",
      webkitUserSelect: "none",
      webkitTouchCallout: "none",
      webkitTapHighlightColor: "transparent",
      outline: "none",
    });
    if (canvas.tabIndex < 0) canvas.tabIndex = 0;
    if ((flags & FLAG.visible) === 0) canvas.style.visibility = "hidden";
    if (title) document.title = title;

    if (glVersion) this.makeContext(win, glVersion, glFlags);
    if (flags & FLAG.maximized) this.fill(win, true, false);

    this.wire(win);
    this.measureNow(win, false);
    this.observe(win);
    this.writeInfo(win, infoPtr);

    // The first window takes the keyboard, so that a page opened to play a
    // game can be played without a click first - unless something else on
    // the page already has it.
    const active = document.activeElement;
    if (flags & FLAG.visible && (!active || active === document.body)) {
      canvas.focus({ preventScroll: true });
    }
    return win.handle;
  }

  release(win) {
    win.controller.abort();
    win.observer?.disconnect();
    if (document.pointerLockElement === win.canvas) document.exitPointerLock?.();
    if ((document.fullscreenElement ?? document.webkitFullscreenElement) === win.canvas) {
      (document.exitFullscreen ?? document.webkitExitFullscreen)?.call(document)?.catch?.(() => {});
    }
    win.field?.remove();

    if (win.entry) {
      // The page's canvas goes back the way it came, and back in the pool.
      const restore = (name, value) =>
        value === null ? win.canvas.removeAttribute(name) : win.canvas.setAttribute(name, value);
      restore("style", win.savedStyle);
      restore("tabindex", win.savedTabIndex);
      win.entry.taken = false;
    } else {
      // Let the GPU memory go now rather than whenever the collector gets
      // round to the canvas.
      win.gl?.getExtension("WEBGL_lose_context")?.loseContext();
      win.canvas.remove();
    }
    this.windows.delete(win.handle);
  }

  /// A WebGL context on the canvas: 2 if the program asked for ES 3.0, and 2
  /// or else 1 for ES 2.0.
  ///
  /// `getContext` hands back the context a canvas already has, whatever
  /// attributes it is asked for - which is how this and `fluxion-webgl.js`
  /// share one. The attributes the context really has are read back
  /// afterwards, in `writeInfo`.
  makeContext(win, version, flags) {
    const attributes = {
      // Opaque: on a page an alpha channel is transparency against whatever
      // is behind the canvas, which is not what an alpha channel means to a
      // renderer.
      alpha: false,
      depth: (flags & CONTEXT.depth) !== 0,
      stencil: (flags & CONTEXT.stencil) !== 0,
      antialias: (flags & CONTEXT.antialias) !== 0,
      preserveDrawingBuffer: false,
      powerPreference: "high-performance",
    };
    let gl = null;
    let got = 0;
    try {
      gl = win.canvas.getContext("webgl2", attributes);
      got = gl ? 2 : 0;
      if (!gl && version <= 1) {
        gl = win.canvas.getContext("webgl", attributes);
        got = gl ? 1 : 0;
      }
    } catch {
      gl = null;
      got = 0;
    }
    win.gl = gl;
    win.glVersion = got;
    if (!gl) return;

    const options = { signal: win.controller.signal };
    // Prevented, or the browser never tries to give the context back.
    win.canvas.addEventListener(
      "webglcontextlost",
      (event) => {
        event.preventDefault();
        this.queue({ kind: KIND.surfaceLost, win: win.id });
      },
      options,
    );
    win.canvas.addEventListener(
      "webglcontextrestored",
      () => {
        this.queue({ kind: KIND.surfaceCreated, win: win.id, a: win.canvas.width, b: win.canvas.height });
      },
      options,
    );
    if (gl.isContextLost()) this.queue({ kind: KIND.surfaceLost, win: win.id });
  }

  writeInfo(win, ptr) {
    const view = this.view;
    this.u8.fill(0, ptr, ptr + INFO_SIZE);
    view.setFloat64(ptr, win.cssWidth, true);
    view.setFloat64(ptr + 8, win.cssHeight, true);
    view.setUint32(ptr + 16, win.fbWidth, true);
    view.setUint32(ptr + 20, win.fbHeight, true);
    view.setFloat64(ptr + 24, win.scale, true);
    view.setUint32(ptr + 32, this.hasFocus(win) ? 1 : 0, true);
    view.setUint32(ptr + 36, win.glVersion, true);

    const gl = win.gl;
    if (!gl) return;
    const read = (name) => {
      try {
        return gl.getParameter(name) | 0;
      } catch {
        return 0;
      }
    };
    view.setUint32(ptr + 40, read(gl.RED_BITS), true);
    view.setUint32(ptr + 44, read(gl.GREEN_BITS), true);
    view.setUint32(ptr + 48, read(gl.BLUE_BITS), true);
    view.setUint32(ptr + 52, read(gl.ALPHA_BITS), true);
    view.setUint32(ptr + 56, read(gl.DEPTH_BITS), true);
    view.setUint32(ptr + 60, read(gl.STENCIL_BITS), true);
    view.setUint32(ptr + 64, read(gl.SAMPLES), true);
  }

  /// The canvas's sizes as the page lays it out now.
  measureNow(win, report = true) {
    const rect = win.canvas.getBoundingClientRect();
    const scale = window.devicePixelRatio || 1;
    const width = Math.max(0, rect.width - 2 * win.canvas.clientLeft);
    const height = Math.max(0, rect.height - 2 * win.canvas.clientTop);
    this.resized(win, width, height, Math.round(width * scale), Math.round(height * scale), scale, report);
  }

  /// Follow the canvas's size, in device pixels where the browser will say.
  ///
  /// `device-pixel-content-box` is the exact number of pixels the canvas
  /// covers, which no amount of multiplying CSS pixels by the ratio reliably
  /// is - the layout snaps to the pixel grid. Where it is missing, the
  /// multiplication is the best there is.
  observe(win) {
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) this.observed(win, entry);
    });
    try {
      observer.observe(win.canvas, { box: "device-pixel-content-box" });
      win.devicePixelBox = true;
    } catch {
      observer.observe(win.canvas, { box: "content-box" });
    }
    win.observer = observer;
  }

  observed(win, entry) {
    const scale = window.devicePixelRatio || 1;
    const content = entry.contentBoxSize?.[0] ?? entry.contentBoxSize;
    const width = content ? content.inlineSize : entry.contentRect.width;
    const height = content ? content.blockSize : entry.contentRect.height;
    const device = entry.devicePixelContentBoxSize?.[0];
    const fbWidth = device ? device.inlineSize : Math.round(width * scale);
    const fbHeight = device ? device.blockSize : Math.round(height * scale);
    this.resized(win, width, height, fbWidth, fbHeight, scale, true);
  }

  resized(win, width, height, fbWidth, fbHeight, scale, report) {
    win.cssWidth = width;
    win.cssHeight = height;
    win.fbWidth = fbWidth;
    win.fbHeight = fbHeight;
    win.scale = scale;

    // The drawing buffer follows the element, which is what keeps it sharp.
    // Setting it clears it - hence the refresh the Zig side sends after.
    const bufferWidth = Math.max(1, fbWidth);
    const bufferHeight = Math.max(1, fbHeight);
    if (win.canvas.width !== bufferWidth) win.canvas.width = bufferWidth;
    if (win.canvas.height !== bufferHeight) win.canvas.height = bufferHeight;

    const sizes = [Math.round(width), Math.round(height), fbWidth, fbHeight, scale];
    const same = win.reported && sizes.every((value, index) => value === win.reported[index]);
    win.reported = sizes;
    if (report && !same) {
      this.queue({ kind: KIND.resize, win: win.id, a: sizes[0], b: sizes[1], c: fbWidth, d: fbHeight, x: scale });
    }
    if (win.textInput) this.placeField(win);
  }

  /// Fill the page, or give the space back. Maximised, as a page means it.
  fill(win, on, report = true) {
    if (on === win.maximized) return;
    const style = win.canvas.style;
    if (on) {
      win.unfilled = {
        position: style.position,
        left: style.left,
        top: style.top,
        width: style.width,
        height: style.height,
        zIndex: style.zIndex,
      };
      Object.assign(style, {
        position: "fixed",
        left: "0px",
        top: "0px",
        width: "100%",
        height: "100%",
        zIndex: "2147483000",
      });
    } else {
      Object.assign(style, win.unfilled ?? {});
      win.unfilled = null;
    }
    win.maximized = on;
    if (report) this.queue({ kind: KIND.maximize, win: win.id, a: on ? 1 : 0 });
  }

  // -- focus --

  hasFocus(win) {
    const active = document.activeElement;
    return document.hasFocus() && (active === win.canvas || (win.field !== null && active === win.field));
  }

  focusWindow(win) {
    const target = win.textInput && win.field ? win.field : win.canvas;
    target.focus({ preventScroll: true });
  }

  /// Worked out once the focus has settled rather than in the handler: moving
  /// it from the canvas to the text field is a blur and then a focus, and the
  /// window has not lost the keyboard in between.
  focusChanged() {
    if (this.focusQueued) return;
    this.focusQueued = true;
    queueMicrotask(() => {
      this.focusQueued = false;
      for (const win of this.windows.values()) {
        const focused = this.hasFocus(win);
        if (focused === win.focused) continue;
        win.focused = focused;
        if (!focused) win.down.clear();
        this.queue({ kind: KIND.focus, win: win.id, a: focused ? 1 : 0 });
      }
    });
  }

  // -- the listeners on one canvas --

  wire(win) {
    const canvas = win.canvas;
    const options = { signal: win.controller.signal };

    canvas.addEventListener("keydown", (event) => this.keyDown(win, event, false), options);
    canvas.addEventListener("keyup", (event) => this.keyUp(win, event, false), options);
    canvas.addEventListener("focus", () => this.focusChanged(), options);
    canvas.addEventListener("blur", () => this.focusChanged(), options);

    canvas.addEventListener("pointerdown", (event) => this.pointerDown(win, event), options);
    canvas.addEventListener("pointermove", (event) => this.pointerMove(win, event), options);
    canvas.addEventListener("pointerup", (event) => this.pointerUp(win, event), options);
    canvas.addEventListener("pointercancel", () => this.buttonsTo(win, 0, 0), options);
    canvas.addEventListener(
      "pointerenter",
      (event) => {
        if (event.pointerType !== "touch") this.queue({ kind: KIND.enter, win: win.id, a: 1 });
      },
      options,
    );
    canvas.addEventListener(
      "pointerleave",
      (event) => {
        if (event.pointerType === "touch") return;
        win.hasPosition = false;
        this.queue({ kind: KIND.enter, win: win.id, a: 0 });
      },
      options,
    );
    // Not passive, or it could not be prevented and the page would scroll.
    canvas.addEventListener("wheel", (event) => this.wheel(win, event), { ...options, passive: false });
    canvas.addEventListener("contextmenu", (event) => event.preventDefault(), options);

    canvas.addEventListener(
      "dragover",
      (event) => {
        event.preventDefault();
        if (event.dataTransfer) event.dataTransfer.dropEffect = "copy";
      },
      options,
    );
    canvas.addEventListener("drop", (event) => this.drop(win, event), options);
  }

  keyDown(win, event, fromField) {
    this.gesture();
    win.lastMods = modsOf(event);
    if (isPasteShortcut(event)) this.pasteShortcut = true;

    // An input method is working on this key, and what it makes of it
    // arrives as a composition. Reporting the key as well would have a
    // Japanese name typed into a game as a volley of WASD.
    const composing = event.isComposing || event.keyCode === 229;
    const position = positionOf(event);
    if (position && !composing) {
      const c = this.labelOf(event, position);
      this.queue({ kind: KIND.key, win: win.id, a: event.repeat ? 2 : 1, b: win.lastMods, c, text: position });
      win.down.add(position);
      if (position === "Backspace") win.sawDelete = true;
      if (position === "Enter" || position === "NumpadEnter") win.sawEnter = true;
    }

    if (win.textInput && fromField) {
      // Typing belongs to the field now, and its text comes from its own
      // events. Only the keys that would move its caret or its focus are
      // kept from it, and the shortcuts that would select or undo in it.
      if (FIELD_KEYS.has(event.key) || isFieldShortcut(event)) event.preventDefault();
      return;
    }

    if (!composing) {
      const typed = typedBy(event);
      if (typed) this.queueText(win, typed, win.lastMods);
    }
    // The browser's shortcuts stay the browser's.
    if (!event.ctrlKey && !event.metaKey && !BROWSER_KEYS.has(event.code)) event.preventDefault();
  }

  keyUp(win, event, fromField) {
    win.lastMods = modsOf(event);
    this.pasteShortcut = false;
    const position = positionOf(event);
    if (position && !(event.isComposing || event.keyCode === 229)) {
      const c = this.labelOf(event, position);
      this.queue({ kind: KIND.key, win: win.id, a: 0, b: win.lastMods, c, text: position });
      win.down.delete(position);
    }
    if (APPLE && /^(Meta|OS)(Left|Right)$/.test(position)) {
      for (const held of win.down) {
        const c = this.labels.get(held)?.codePointAt(0) ?? 0;
        this.queue({ kind: KIND.key, win: win.id, a: 0, b: win.lastMods, c, text: held });
      }
      win.down.clear();
    }
    if (!(win.textInput && fromField) && !event.ctrlKey && !event.metaKey && !BROWSER_KEYS.has(event.code)) {
      event.preventDefault();
    }
  }

  /// What a key types on its own on the layout in use, as a code point, or 0
  /// where that cannot be told. `KeyEvent.virtual` is worked out from it, on
  /// the Zig side, by the rule every backend shares.
  ///
  /// `key` says exactly that for a key pressed with nothing held, and it is
  /// remembered for the position. With something held it may not: shift
  /// makes a letter a capital, which is still the letter, but AltGr and alt
  /// choose another character altogether. So a chord is answered from what
  /// the same key typed on its own - remembered, or from the browser's map
  /// of the layout - and failing that a letter held with shift or control is
  /// taken as it comes.
  labelOf(event, position) {
    const key = event.key ?? "";
    const one = [...key].length === 1;
    const altGraph = event.getModifierState?.("AltGraph") ?? false;
    if (one && !event.shiftKey && !event.ctrlKey && !event.altKey && !event.metaKey && !altGraph) {
      this.labels.set(position, key);
      return key.codePointAt(0);
    }
    const known = this.labels.get(position);
    if (known) return known.codePointAt(0);
    if (one && !event.altKey && !altGraph) return key.toLowerCase().codePointAt(0);
    return 0;
  }

  /// Everything the browser would only grant a person who had just done
  /// something, asked for again now that one has.
  gesture() {
    for (const win of this.windows.values()) {
      if (win.pendingLock && win.mode === MODE.disabled && document.pointerLockElement !== win.canvas) {
        this.lock(win);
      }
      if (win.pendingFullscreen) {
        win.pendingFullscreen = false;
        this.enterFullscreen(win);
      }
    }
    if (this.clipboardPending !== null) this.writeClipboard();
    if (this.dialog && !this.dialog.shown) this.showDialog(this.dialog);
  }

  local(win, event) {
    const rect = win.canvas.getBoundingClientRect();
    return [
      event.clientX - rect.left - win.canvas.clientLeft,
      event.clientY - rect.top - win.canvas.clientTop,
    ];
  }

  pointerDown(win, event) {
    // One pointer is the mouse. A second finger is not a second mouse, and
    // there is no event in the library for it to be.
    if (event.pointerType === "touch" && !event.isPrimary) return;
    this.gesture();
    // No text selection, and no focus change of the browser's choosing: the
    // focus below is the one wanted.
    event.preventDefault();
    this.focusWindow(win);
    try {
      win.canvas.setPointerCapture(event.pointerId);
    } catch {
      // A locked pointer cannot also be captured, and does not need to be.
    }
    // A finger has no position until it lands, so it moves there first.
    this.moved(win, event, event.pointerType === "touch");
    this.buttonsTo(win, event.buttons, modsOf(event));
  }

  pointerMove(win, event) {
    if (event.pointerType === "touch" && !event.isPrimary) return;
    this.moved(win, event, true);
    // A second button pressed during a drag arrives as a move, not a down.
    if (event.buttons !== win.buttons) this.buttonsTo(win, event.buttons, modsOf(event));
  }

  pointerUp(win, event) {
    if (event.pointerType === "touch" && !event.isPrimary) return;
    if (event.pointerType === "touch") {
      // Safari raises a phone's keyboard only for a field focused inside a
      // tap, and a tap is this.
      this.gesture();
      if (win.textInput && win.field) {
        win.field.blur();
        win.field.focus({ preventScroll: true });
      }
    }
    this.moved(win, event, false);
    this.buttonsTo(win, event.buttons, modsOf(event));
  }

  moved(win, event, report) {
    if (document.pointerLockElement === win.canvas) {
      if (!report) return;
      // The first move after a lock can carry the whole jump to wherever the
      // browser parked the pointer, which a camera would spin through.
      if (win.skipMotion) {
        win.skipMotion = false;
        return;
      }
      if (event.movementX || event.movementY) {
        this.queue({ kind: KIND.cursor, win: win.id, x: 0, y: 0, dx: event.movementX, dy: event.movementY });
      }
      return;
    }

    const [x, y] = this.local(win, event);
    const dx = win.hasPosition ? x - win.lastX : 0;
    const dy = win.hasPosition ? y - win.lastY : 0;
    const first = !win.hasPosition;
    win.lastX = x;
    win.lastY = y;
    win.hasPosition = true;
    if (report && (first || dx !== 0 || dy !== 0)) {
      this.queue({ kind: KIND.cursor, win: win.id, x, y, dx, dy });
    }
  }

  /// Report whichever buttons changed since the last pointer event.
  buttonsTo(win, buttons, mods) {
    const changed = (buttons ?? 0) ^ win.buttons;
    if (changed === 0) return;
    const locked = document.pointerLockElement === win.canvas;
    const x = locked ? 0 : win.lastX;
    const y = locked ? 0 : win.lastY;
    for (const [bit, number] of BUTTON_BITS) {
      if ((changed & bit) === 0) continue;
      const down = (buttons & bit) !== 0;
      this.queue({ kind: KIND.button, win: win.id, a: number, b: down ? 1 : 0, c: mods, x, y });
    }
    win.buttons = buttons ?? 0;
  }

  wheel(win, event) {
    event.preventDefault();
    // Where the wheel turned, first. What scrolls is whatever is under the
    // pointer, and the pointer need not have moved there since a move was
    // last heard: a page that has not seen the mouse yet, or a wheel turned
    // over the canvas the moment the page opened.
    this.moved(win, event, true);
    // The mode first: Firefox reports lines only to a page that asks what it
    // is measuring in before it reads the deltas, and pixels otherwise.
    const mode = event.deltaMode;
    this.queue({ kind: KIND.scroll, win: win.id, a: mode, b: modsOf(event), x: event.deltaX, y: event.deltaY });
  }

  /// Files, read into memory as they land - a page gets their names and their
  /// bytes, and never a path - and only then announced, so that everything
  /// `web.droppedFile` might be asked for is already here.
  async drop(win, event) {
    event.preventDefault();
    const files = [...(event.dataTransfer?.files ?? [])];
    if (files.length === 0) return;
    const bytes = await Promise.all(
      files.map((file) =>
        file.size > this.maxDropBytes
          ? null
          : file.arrayBuffer().then(
              (buffer) => new Uint8Array(buffer),
              () => null,
            ),
      ),
    );
    this.dropped = files.map((file, index) => ({ name: file.name, bytes: bytes[index] }));
    // Where it was let go, the way a pointer's place is said.
    const [x, y] = this.local(win, event);
    this.queue({ kind: KIND.dropBegin, win: win.id, a: files.length, x, y });
    files.forEach((file, index) => this.queue({ kind: KIND.dropFile, win: win.id, a: index, text: file.name }));
  }

  // -- the file dialog --

  /// An `<input type="file">`, clicked for the program. The browser opens it
  /// only inside a click or a key press, so a request from anywhere else waits
  /// for the next one - see `gesture`.
  openFileDialog(win, id, flags, accept) {
    if (typeof document === "undefined" || this.dialog) return 0;
    const input = document.createElement("input");
    input.type = "file";
    input.multiple = (flags & DIALOG.multiple) !== 0;
    input.webkitdirectory = (flags & DIALOG.folder) !== 0;
    if (accept) input.accept = accept;
    // In the document, or Safari opens nothing; out of sight, because it is
    // not the page's to show.
    Object.assign(input.style, { position: "fixed", left: "-10000px", top: "0px", width: "1px", height: "1px", opacity: "0" });
    document.body.appendChild(input);

    const dialog = { win, id, input, shown: false };
    this.dialog = dialog;
    input.addEventListener("change", () => this.dialogChosen(dialog), { once: true });
    input.addEventListener("cancel", () => this.dialogAnswered(dialog, []), { once: true });
    if (navigator.userActivation?.isActive ?? true) this.showDialog(dialog);
    return 1;
  }

  /// `showPicker` throws when the browser refuses, where `click` fails without
  /// a word - and a refusal is what tells `gesture` to try again.
  showDialog(dialog) {
    try {
      if (typeof dialog.input.showPicker === "function") dialog.input.showPicker();
      else dialog.input.click();
      dialog.shown = true;
    } catch {
      dialog.shown = false;
    }
  }

  /// Read before the answer is queued, as a drop is, so that everything
  /// `Context.chosenFile` may be asked for is already here - as much as
  /// `maxChosenBytes` holds, which a whole folder may not fit in.
  async dialogChosen(dialog) {
    const files = [...(dialog.input.files ?? [])];
    let budget = this.maxChosenBytes;
    const bytes = await Promise.all(
      files.map((file) => {
        if (file.size > budget) return null;
        budget -= file.size;
        return file.arrayBuffer().then(
          (buffer) => new Uint8Array(buffer),
          () => null,
        );
      }),
    );
    // A folder's files are named by their path inside it: the one path a page
    // is ever shown.
    const chosen = files.map((file, index) => ({ name: file.webkitRelativePath || file.name, bytes: bytes[index] }));
    this.dialogAnswered(dialog, chosen);
  }

  dialogAnswered(dialog, files) {
    if (this.dialog !== dialog) return;
    this.dialog = null;
    dialog.input.remove();
    this.chosen = files;
    this.queue({ kind: KIND.dialogBegin, win: dialog.win, a: files.length, b: dialog.id });
    files.forEach((file, index) => this.queue({ kind: KIND.dialogFile, win: dialog.win, a: index, text: file.name }));
  }

  // -- the pointer --

  applyCursor(win) {
    win.canvas.style.cursor = win.mode === MODE.hidden ? "none" : (SHAPES[win.shape] ?? "default");
  }

  /// Ask for pointer lock, and if the browser says no, remember to ask again
  /// inside the next click or key press on the canvas.
  lock(win) {
    win.pendingLock = false;
    if (!win.canvas.requestPointerLock) return;
    const raw = win.rawWanted && this.rawSupported !== false;
    let request;
    try {
      request = raw ? win.canvas.requestPointerLock({ unadjustedMovement: true }) : win.canvas.requestPointerLock();
    } catch {
      win.pendingLock = true;
      return;
    }
    // Firefox answers nothing and reports failure as an event instead; the
    // listener for `pointerlockerror` covers that.
    if (!request || typeof request.then !== "function") return;
    request.then(
      () => {
        if (raw) this.rawSupported = true;
      },
      (error) => {
        if (raw && error?.name === "NotSupportedError") {
          // Now known for certain, and asked again without it.
          this.rawSupported = false;
          if (win.mode === MODE.disabled) this.lock(win);
          return;
        }
        if (win.mode === MODE.disabled && document.pointerLockElement !== win.canvas) win.pendingLock = true;
      },
    );
  }

  lockChanged() {
    const element = document.pointerLockElement;
    for (const win of this.windows.values()) {
      const mine = element === win.canvas;
      if (mine && !win.locked) {
        win.locked = true;
        win.skipMotion = true;
      } else if (!mine && win.locked) {
        win.locked = false;
        win.hasPosition = false;
        // Escape, or the browser deciding. The program still wants it, so
        // the next click takes it back - which is what every web game does.
        if (win.mode === MODE.disabled) win.pendingLock = true;
      }
    }
  }

  /// Whether a lock without acceleration is to be had. Known for certain after
  /// the first lock; until then a guess, and the guess is Chromium's own
  /// list: Windows, macOS and ChromeOS.
  rawPossible() {
    if (this.rawSupported !== undefined) return this.rawSupported;
    const data = navigator.userAgentData;
    if (!data?.brands?.some((brand) => brand.brand === "Chromium")) return false;
    return data.platform !== "Linux" && data.platform !== "Android";
  }

  enterFullscreen(win) {
    const canvas = win.canvas;
    try {
      const result = canvas.requestFullscreen
        ? canvas.requestFullscreen({ navigationUI: "hide" })
        : canvas.webkitRequestFullscreen();
      result?.catch?.(() => {
        win.pendingFullscreen = true;
      });
    } catch {
      win.pendingFullscreen = true;
    }
  }

  // -- text --

  startText(win) {
    if (!win.field) this.makeField(win);
    win.textInput = true;
    this.placeField(win);
    this.resetField(win);
    // The keyboard moves from the canvas to the field, if the window had it.
    if (document.activeElement === win.canvas) win.field.focus({ preventScroll: true });
  }

  stopText(win) {
    win.textInput = false;
    if (win.composing) {
      win.composing = false;
      this.queue({ kind: KIND.preedit, win: win.id, a: -1, b: -1, text: "" });
    }
    if (win.field && document.activeElement === win.field) {
      win.canvas.focus({ preventScroll: true });
    }
  }

  /// The hidden field an input method and a soft keyboard attach to, which a
  /// canvas cannot be. Transparent, one pixel, and behind everything; it only
  /// has to be focusable and to be where the caret is.
  makeField(win) {
    const field = document.createElement("textarea");
    for (const [name, value] of [
      ["autocomplete", "off"],
      ["autocorrect", "off"],
      ["autocapitalize", "off"],
      ["spellcheck", "false"],
      ["aria-label", "text input"],
    ]) {
      field.setAttribute(name, value);
    }
    field.tabIndex = -1;
    Object.assign(field.style, {
      position: "fixed",
      left: "0px",
      top: "0px",
      width: "1px",
      height: "1px",
      padding: "0",
      border: "0",
      margin: "0",
      outline: "none",
      resize: "none",
      overflow: "hidden",
      opacity: "0",
      color: "transparent",
      background: "transparent",
      caretColor: "transparent",
      // Sixteen pixels at least: Safari on a phone zooms the whole page in on
      // any field with smaller text the moment it is focused.
      fontSize: "16px",
      lineHeight: "1",
      whiteSpace: "pre",
      zIndex: "-1",
      pointerEvents: "none",
    });
    document.body.appendChild(field);

    const options = { signal: win.controller.signal };
    field.addEventListener("keydown", (event) => this.keyDown(win, event, true), options);
    field.addEventListener("keyup", (event) => this.keyUp(win, event, true), options);
    field.addEventListener("focus", () => this.focusChanged(), options);
    field.addEventListener("blur", () => this.focusChanged(), options);
    field.addEventListener(
      "compositionstart",
      () => {
        win.composing = true;
      },
      options,
    );
    field.addEventListener("compositionupdate", (event) => this.composed(win, event.data ?? ""), options);
    field.addEventListener("compositionend", (event) => this.committed(win, event.data ?? ""), options);
    field.addEventListener("input", (event) => this.edited(win, event), options);
    win.field = field;
  }

  placeField(win) {
    const field = win.field;
    if (!field) return;
    const rect = win.canvas.getBoundingClientRect();
    const area = win.area ?? { x: 0, y: 0, width: 1, height: 16 };
    Object.assign(field.style, {
      left: `${rect.left + area.x}px`,
      top: `${rect.top + area.y}px`,
      width: `${Math.max(1, area.width)}px`,
      height: `${Math.max(1, area.height)}px`,
    });
  }

  resetField(win) {
    const field = win.field;
    if (field.value !== SENTINEL) field.value = SENTINEL;
    field.setSelectionRange(SENTINEL.length, SENTINEL.length);
    win.base = SENTINEL;
  }

  /// Report whatever the field says now that it did not say last time: what
  /// was inserted as text, what was deleted as backspaces.
  ///
  /// A difference rather than the field's contents, because the field is not
  /// always emptied between two edits - see `committed` - and text already
  /// reported must not be reported twice.
  consume(win) {
    const value = win.field.value;
    const base = win.base;
    let common = 0;
    while (common < value.length && common < base.length && value[common] === base[common]) common += 1;

    // Characters, not UTF-16 units: an emoji deleted is one backspace.
    const removed = [...base.slice(common)].length;
    const inserted = value.slice(common);

    // A physical key already said so as a key. A soft keyboard's backspace
    // and enter arrive only as edits.
    if (removed > 0 && !win.sawDelete) {
      for (let i = 0; i < removed; i += 1) this.tap(win, "Backspace");
    }
    if (inserted.includes("\n") && !win.sawEnter) this.tap(win, "Enter");
    this.queueText(win, inserted, win.lastMods);

    win.sawDelete = false;
    win.sawEnter = false;
    win.base = value;
  }

  /// The composition changed. It is the last thing in the field, so where the
  /// field's caret sits past its start is where the caret is inside the
  /// composition - in UTF-16 units, where the library wants bytes of UTF-8.
  composed(win, data) {
    win.composing = true;
    const field = win.field;
    const start = field.value.length - data.length;
    const toBytes = (units) => {
      const inside = units - start;
      if (!(inside >= 0 && inside <= data.length)) return utf8Length(data);
      return utf8Length(data.slice(0, inside));
    };
    const begin = toBytes(field.selectionStart);
    const end = toBytes(field.selectionEnd);
    this.queue({ kind: KIND.preedit, win: win.id, a: begin, b: end, text: data });
  }

  /// The composition was committed, and its text is in the field.
  ///
  /// Read from the field rather than from `data`, which not every browser
  /// fills in faithfully - and the field is *not* emptied here. A Korean input
  /// method commits one syllable and starts composing the next in the same
  /// breath, and changing the field under it in between breaks the second
  /// one. It is emptied a moment later, if nothing has started by then.
  committed(win, data) {
    win.composing = false;
    this.queue({ kind: KIND.preedit, win: win.id, a: -1, b: -1, text: "" });
    if (win.field.value === win.base && data) {
      // A browser that commits by event and not by edit: the text is only in
      // `data`.
      this.queueText(win, data, 0);
    } else {
      this.consume(win);
    }
    setTimeout(() => {
      if (win.textInput && !win.composing && win.field) this.resetField(win);
    }, 0);
  }

  /// Something was typed into the field outside a composition - a key, a
  /// paste, a soft keyboard's suggestion - or something was deleted from it.
  edited(win, event) {
    if (win.composing || event.isComposing) return;
    this.consume(win);
    this.resetField(win);
  }

  // -- the clipboard --

  remember(text) {
    this.clipboard = text;
    this.clipboardBytes = null;
  }

  clipboardEncoded() {
    this.clipboardBytes ??= this.encoder.encode(this.clipboard);
    return this.clipboardBytes;
  }

  /// Put text on the clipboard, and keep it for `clipboardText`. A browser
  /// that wants a person to have just done something is asked again inside
  /// the next key press or click - see `gesture`.
  setClipboard(text) {
    this.remember(text);
    if (!navigator.clipboard?.writeText && typeof document.execCommand !== "function") return 0;
    this.clipboardPending = text;
    this.writeClipboard();
    return 1;
  }

  writeClipboard() {
    const text = this.clipboardPending;
    const written = () => {
      if (this.clipboardPending === text) this.clipboardPending = null;
    };
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text).then(written, () => {});
    } else if (this.copyCommand(text)) {
      written();
    }
  }

  /// The old way, for a page with no `navigator.clipboard` - one served over
  /// plain http, say: copy the selection of a field made for the purpose.
  copyCommand(text) {
    const field = document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    Object.assign(field.style, { position: "fixed", left: "-9999px", top: "0px", opacity: "0" });
    const focused = document.activeElement;
    document.body.appendChild(field);
    field.select();
    let copied = false;
    try {
      copied = document.execCommand("copy");
    } catch {
      copied = false;
    }
    field.remove();
    focused?.focus?.({ preventScroll: true });
    return copied;
  }

  /// Somebody pasted, which is the one time a page may read the clipboard.
  /// The text is kept for `clipboardText`, and a shortcut's paste is kept out
  /// of the hidden field: the program hears the shortcut as a key and pastes
  /// for itself, as it would on a desktop. Any other paste - the browser's own
  /// menu - still types into the field.
  pasted(event) {
    this.remember(event.clipboardData?.getData("text/plain") ?? "");
    // What the clipboard holds is known now, and a copy the browser has not
    // taken yet would replace it behind the user's back.
    this.clipboardPending = null;
    const field = [...this.windows.values()].some((win) => win.field !== null && win.field === event.target);
    if (field && this.pasteShortcut) event.preventDefault();
    this.pasteShortcut = false;
  }

  // -- the screen and the controllers --

  writeMonitor(ptr) {
    const screen = window.screen;
    // A page with no screen to speak of - a hidden webview, a headless
    // browser - reports one that is zero by zero. No monitor is the truth.
    if (!screen || !(screen.width > 0) || !(screen.height > 0)) return 0;
    const view = this.view;
    view.setFloat64(ptr, screen.left ?? 0, true);
    view.setFloat64(ptr + 8, screen.top ?? 0, true);
    view.setFloat64(ptr + 16, screen.width, true);
    view.setFloat64(ptr + 24, screen.height, true);
    view.setFloat64(ptr + 32, screen.availLeft ?? 0, true);
    view.setFloat64(ptr + 40, screen.availTop ?? 0, true);
    view.setFloat64(ptr + 48, screen.availWidth ?? screen.width, true);
    view.setFloat64(ptr + 56, screen.availHeight ?? screen.height, true);
    view.setFloat64(ptr + 64, window.devicePixelRatio || 1, true);
    view.setUint32(ptr + 72, screen.colorDepth ?? 0, true);
    view.setUint32(ptr + 76, this.refreshHz(), true);
    return 1;
  }

  writeGamepads(ptr, capacity) {
    let pads;
    try {
      pads = navigator.getGamepads ? navigator.getGamepads() : [];
    } catch {
      // Refused by a permissions policy, in a frame that was not allowed them.
      return 0;
    }
    let count = 0;
    for (const pad of pads) {
      if (!pad || !pad.connected) continue;
      if (count >= capacity) break;
      this.writePad(ptr + count * PAD_SIZE, pad);
      count += 1;
    }
    return count;
  }

  writePad(at, pad) {
    const view = this.view;
    const u8 = this.u8;
    u8.fill(0, at, at + PAD_SIZE);
    view.setUint32(at, pad.index, true);
    view.setUint32(at + 4, pad.mapping === "standard" ? 1 : 0, true);
    view.setUint32(at + 8, pad.axes.length, true);
    view.setUint32(at + 12, pad.buttons.length, true);

    let pressed = 0;
    const buttons = Math.min(pad.buttons.length, 32);
    for (let i = 0; i < buttons; i += 1) {
      const button = pad.buttons[i];
      if (button.pressed) pressed |= 1 << i;
      view.setFloat32(at + 56 + i * 4, button.value, true);
    }
    view.setUint32(at + 16, pressed >>> 0, true);

    const axes = Math.min(pad.axes.length, 8);
    for (let i = 0; i < axes; i += 1) view.setFloat32(at + 24 + i * 4, pad.axes[i], true);

    const id = this.encoder.encode(pad.id ?? "");
    const len = cutUtf8(id, PAD_ID);
    u8.set(id.subarray(0, len), at + 184);
    view.setUint32(at + 20, len, true);
  }
}

/// Instantiate a module against a new `Platform` and run it until it ends.
///
///   await run("./game.wasm", { canvas: "#game", with: [webgl] });
export async function run(source, options = {}) {
  const platform = new Platform(options);
  await platform.run(source, { with: options.with ?? [] });
  return platform;
}
