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
  safeArea: 18,
  touch: 19,
  textEdited: 20,
  textDone: 21,
};

/// `TextField`: what kind of field the bar above a phone's keyboard shows,
/// and how it looks - 32-bit integers from offset 0, floats from 48.
const FIELD_PASSWORD = 1 << 0;
const FIELD_MULTILINE = 1 << 1;
const FIELD_LOOK = 1 << 2;

/// The most bytes of the bar's text one record carries: half the heap a
/// drain fills, so each piece fits one whole.
const BAR_PIECE = 2048;

/// `Record`: kind, window, a, b, c, d as 32-bit integers from offset 0, then
/// x, y, dx, dy as doubles from 24, then where its text is at 56 and 60.
const RECORD_SIZE = 64;
/// `WindowInfo`.
const INFO_SIZE = 72;
/// `GamepadRecord`, and the longest `id` it holds.
const PAD_SIZE = 312;
const PAD_ID = 128;

/// `keys.Mods`, bit for bit.
const MOD = { shift: 1, control: 2, alt: 4, super: 8, capsLock: 16, numLock: 32, altGraph: 64 };

/// `createWindow`'s flags, and its context flags.
const FLAG = { resizable: 1, decorated: 2, visible: 4, maximized: 8 };
const CONTEXT = { depth: 1, stencil: 2, antialias: 4 };

/// The WebGL extensions a context is given as it is made: see `makeContext`.
const WIDENING = ["EXT_color_buffer_float", "EXT_color_buffer_half_float", "EXT_texture_filter_anisotropic"];

/// `openFileDialog`'s flags.
const DIALOG = { multiple: 1, folder: 2 };

/// `backend.WindowState` and `cursor.Mode`, by number.
const STATE = { iconified: 0, maximized: 1, restored: 2, focused: 3, attention: 4 };
const MODE = { normal: 0, hidden: 1, captured: 2, disabled: 3, confinedHidden: 4 };

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
  "wait",
  "progress",
  "help",
  "grabbing",
  "copy",
  "row-resize",
  "col-resize",
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
  // Windows browsers report AltGr as control and alt as well.
  if (event.getModifierState?.("AltGraph")) bits = (bits & ~(MOD.control | MOD.alt)) | MOD.altGraph;
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

/// Where `bytes` of UTF-8 into `text` falls, in its UTF-16 units: a caret's
/// place as the program says it and as a field takes it.
function unitsAt(text, bytes) {
  let seen = 0;
  let units = 0;
  for (const ch of text) {
    if (seen >= bytes) break;
    seen += utf8Length(ch);
    units += ch.length;
  }
  return units;
}

/// `text` cut into pieces of at most `limit` bytes of UTF-8, never inside a
/// character; one empty piece for an empty text.
function piecesOf(text, limit) {
  const pieces = [];
  let piece = "";
  let bytes = 0;
  for (const ch of text) {
    const size = utf8Length(ch);
    if (bytes + size > limit && piece.length > 0) {
      pieces.push(piece);
      piece = "";
      bytes = 0;
    }
    piece += ch;
    bytes += size;
  }
  pieces.push(piece);
  return pieces;
}

/// 0xAARRGGBB as CSS.
function cssColor(argb) {
  const alpha = ((argb >>> 24) & 0xff) / 255;
  return `rgba(${(argb >>> 16) & 0xff}, ${(argb >>> 8) & 0xff}, ${argb & 0xff}, ${alpha})`;
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

    /// `env(safe-area-inset-*)` as they were last measured, in the drawing
    /// buffer's pixels. Null until the first measurement.
    this.insets = null;

    this.mode = MODE.normal;
    this.shape = 0;
    /// The program's own cursor, as a whole CSS `cursor` value, or null for
    /// whichever shape is set.
    this.image = null;
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

    /// The bar above a phone's keyboard: the field the program last said it
    /// has - null until it says, each time text input starts - the bar's
    /// elements once made, whether it shows, what it last said, and whether
    /// the last press was a finger's, which is what wants it.
    this.barField = null;
    this.bar = null;
    this.barShown = false;
    this.barSaid = "";
    this.fingerLast = false;

    /// Asked for and turned down, for want of a click. Tried again inside
    /// the next one.
    this.pendingLock = false;
    this.pendingFullscreen = false;
  }
}

// -------------------------------------------------------------------------
// The glue
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// Files: what a WASI module is given for an operating system
// -------------------------------------------------------------------------
//
// A module built for `wasm32-wasi` reads and writes files, asks the time and
// for random bytes through WASI's calls - which is how Zig's `std.Io` does it
// there, so a program's file code is the same in a page as on a disc. These
// are those calls, against a file system in memory:
//
//   /           opened for the module, as its working folder
//   /user       the player's own, kept in IndexedDB between visits - when the
//               page names a `storage` to keep it under
//   /picked     the files dropped on the page or chosen in its file dialog
//   /tmp        scratch, gone with the page
//
// and anything the page puts there before the module runs: a game's pack, a
// font. A file put there stays in JavaScript's memory and is copied into the
// module's a read at a time, so a large one costs the module nothing until it
// is read. What the page does not have - sockets, links - answers ENOSYS.
// Nothing here waits: a page's frame is the browser's to give, so a sleep
// returns at once.

const ERRNO = { success: 0, badf: 8, exist: 20, inval: 28, isdir: 31, noent: 44, nosys: 52, notdir: 54, notempty: 55, notsup: 58, spipe: 70 };
const FILETYPE = { char: 2, directory: 3, file: 4 };
const OFLAGS = { creat: 1, directory: 2, excl: 4, trunc: 8 };
const FDFLAG_APPEND = 1;

/// Thrown by `proc_exit`, which ends the module where it stands.
export class Exit extends Error {
  constructor(code) {
    super(`the program exited with ${code}`);
    this.code = code;
  }
}

let nextNode = 1;

class FileNode {
  constructor(directory) {
    this.ino = nextNode++;
    this.type = directory ? FILETYPE.directory : FILETYPE.file;
    this.mtime = BigInt(Date.now()) * 1000000n;
    if (directory) this.children = new Map();
    else {
      this.data = new Uint8Array(0);
      this.size = 0;
    }
  }

  bytes() {
    return this.data.subarray(0, this.size);
  }

  reserve(length) {
    if (length <= this.data.length) return;
    const grown = new Uint8Array(Math.max(length, this.data.length * 2, 64));
    grown.set(this.bytes());
    this.data = grown;
  }
}

export class Files {
  /// `args` is the program's command line and `env` its environment.
  /// `storage` names the IndexedDB database `/user` is kept in - a game's own
  /// name, so two games on one site keep theirs apart - or nothing keeps it.
  /// `log(level, line)` hears standard output and error a line at a time.
  constructor({ args = [], env = {}, storage = null, log = defaultLog } = {}) {
    this.args = args;
    this.env = Object.entries(env).map(([key, value]) => `${key}=${value}`);
    this.storage = storage;
    this.log = log;
    this.root = new FileNode(true);
    for (const folder of ["/user", "/picked", "/tmp"]) this.make(folder, true);
    this.fds = new Map([[3, { node: this.root, path: "/", pos: 0n, preopen: "/" }]]);
    this.nextFd = 4;
    this.lines = { 1: "", 2: "" };
    this.dirty = new Set();
    this.flushing = null;
    this.soon = null;
    this.memory = null;
    this.encoder = new TextEncoder();
    this.decoder = new TextDecoder();
  }

  /// Put a file in place: a pack before the module runs, a dropped file.
  put(path, bytes) {
    const node = this.make(path, false);
    node.data = bytes;
    node.size = bytes.length;
    node.mtime = BigInt(Date.now()) * 1000000n;
    this.touched(Files.normalize(path));
  }

  /// The bytes of a file, or null.
  get(path) {
    const node = this.find(path);
    return node && node.type === FILETYPE.file ? node.bytes() : null;
  }

  /// `/user` as it was left, from IndexedDB.
  async load() {
    if (!this.storage || typeof indexedDB === "undefined") return;
    const db = await this.database();
    const kept = await new Promise((resolve, reject) => {
      const request = db.transaction("files").objectStore("files").getAll();
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    for (const entry of kept) {
      if (!Files.kept(entry.path)) continue;
      if (entry.directory) {
        this.make(entry.path, true);
        continue;
      }
      const node = this.make(entry.path, false);
      node.data = new Uint8Array(entry.data);
      node.size = node.data.length;
      node.mtime = BigInt(entry.mtime);
    }
    this.dirty.clear();
    if (this.soon) clearTimeout(this.soon);
    this.soon = null;
  }

  /// What changed in `/user` since, written to IndexedDB. One write at a
  /// time; a change made during one is written by the next.
  flush() {
    if (!this.storage || this.dirty.size === 0 || typeof indexedDB === "undefined") return this.flushing ?? Promise.resolve();
    if (this.flushing) return this.flushing.then(() => this.flush());
    const paths = [...this.dirty];
    this.dirty.clear();
    this.flushing = this.database()
      .then((db) => new Promise((resolve, reject) => {
        const transaction = db.transaction("files", "readwrite");
        const store = transaction.objectStore("files");
        for (const path of paths) {
          const node = this.find(path);
          if (!node) store.delete(path);
          else if (node.type === FILETYPE.directory) store.put({ path, directory: true });
          else store.put({ path, data: node.bytes().slice(), mtime: node.mtime.toString() });
        }
        transaction.oncomplete = resolve;
        transaction.onerror = () => reject(transaction.error);
      }))
      .catch((error) => this.log(2, `the player's files were not kept: ${error}`))
      .finally(() => {
        this.flushing = null;
      });
    return this.flushing;
  }

  database() {
    this.db ??= new Promise((resolve, reject) => {
      const request = indexedDB.open(this.storage, 1);
      request.onupgradeneeded = () => request.result.createObjectStore("files", { keyPath: "path" });
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    return this.db;
  }

  static kept(path) {
    return path === "/user" || path.startsWith("/user/");
  }

  /// A change in `/user`, written a moment later - by a timer rather than
  /// the next frame, which a hidden tab never gets.
  touched(path) {
    if (!Files.kept(path)) return;
    this.dirty.add(path);
    if (this.storage && !this.soon && typeof setTimeout === "function") {
      this.soon = setTimeout(() => {
        this.soon = null;
        this.flush();
      }, 50);
    }
  }

  // -- paths --

  static normalize(path) {
    const parts = [];
    for (const part of path.split("/")) {
      if (part === "" || part === ".") continue;
      if (part === "..") parts.pop();
      else parts.push(part);
    }
    return "/" + parts.join("/");
  }

  find(path) {
    let node = this.root;
    for (const part of Files.normalize(path).split("/")) {
      if (part === "") continue;
      if (node.type !== FILETYPE.directory) return null;
      node = node.children.get(part);
      if (!node) return null;
    }
    return node;
  }

  /// The node at `path`, made with the folders above it where missing.
  make(path, directory) {
    const parts = Files.normalize(path).split("/").filter(Boolean);
    let node = this.root;
    parts.forEach((part, index) => {
      let next = node.children.get(part);
      if (!next) {
        next = new FileNode(directory || index < parts.length - 1);
        node.children.set(part, next);
      }
      node = next;
    });
    return node;
  }

  split(path) {
    const full = Files.normalize(path);
    const at = full.lastIndexOf("/");
    return { parent: this.find(full.slice(0, at) || "/"), name: full.slice(at + 1) };
  }

  // -- the module's memory --

  get u8() {
    if (!this.cachedU8 || this.cachedU8.buffer !== this.memory.buffer) this.cachedU8 = new Uint8Array(this.memory.buffer);
    return this.cachedU8;
  }

  get view() {
    if (!this.cachedView || this.cachedView.buffer !== this.memory.buffer) this.cachedView = new DataView(this.memory.buffer);
    return this.cachedView;
  }

  /// The path a call names, under the folder `fd` is open on - or null.
  pathAt(fd, ptr, len) {
    const folder = this.fds.get(fd);
    if (!folder || folder.node.type !== FILETYPE.directory) return null;
    const named = this.decoder.decode(this.u8.subarray(ptr, ptr + len));
    return Files.normalize(named.startsWith("/") ? named : `${folder.path}/${named}`);
  }

  iovs(ptr, count) {
    const out = [];
    for (let i = 0; i < count; i++) {
      const base = this.view.getUint32(ptr + i * 8, true);
      out.push(this.u8.subarray(base, base + this.view.getUint32(ptr + i * 8 + 4, true)));
    }
    return out;
  }

  writeStat(ptr, node) {
    const view = this.view;
    view.setBigUint64(ptr, 0n, true);
    view.setBigUint64(ptr + 8, BigInt(node.ino), true);
    view.setUint8(ptr + 16, node.type);
    view.setBigUint64(ptr + 24, 1n, true);
    view.setBigUint64(ptr + 32, BigInt(node.type === FILETYPE.file ? node.size : 0), true);
    view.setBigUint64(ptr + 40, node.mtime, true);
    view.setBigUint64(ptr + 48, node.mtime, true);
    view.setBigUint64(ptr + 56, node.mtime, true);
  }

  writeAt(entry, bytes, offset) {
    const node = entry.node;
    const at = Number(offset);
    const end = at + bytes.length;
    node.reserve(end);
    if (at > node.size) node.data.fill(0, node.size, at);
    node.data.set(bytes, at);
    node.size = Math.max(node.size, end);
    node.mtime = BigInt(Date.now()) * 1000000n;
    this.touched(entry.path);
  }

  readAt(entry, iovs, count, offset) {
    const node = entry.node;
    let at = Number(offset);
    let read = 0;
    for (const part of this.iovs(iovs, count)) {
      const take = Math.max(0, Math.min(part.length, node.size - at));
      part.set(node.data.subarray(at, at + take));
      at += take;
      read += take;
      if (take < part.length) break;
    }
    return read;
  }

  /// A line written to standard output or error, said at the level its
  /// prefix names.
  say(fd, bytes) {
    this.lines[fd] += this.decoder.decode(bytes);
    let end;
    while ((end = this.lines[fd].indexOf("\n")) >= 0) {
      const line = this.lines[fd].slice(0, end);
      this.lines[fd] = this.lines[fd].slice(end + 1);
      const level = /^error/.test(line) ? 3 : /^warn/.test(line) ? 2 : /^debug/.test(line) ? 0 : 1;
      this.log(level, line);
    }
  }

  listSizes(list, count, size) {
    this.view.setUint32(count, list.length, true);
    this.view.setUint32(size, list.reduce((sum, item) => sum + this.encoder.encode(item).length + 1, 0), true);
    return ERRNO.success;
  }

  listWrite(list, pointers, buffer) {
    let at = buffer;
    list.forEach((item, index) => {
      const bytes = this.encoder.encode(item);
      this.view.setUint32(pointers + index * 4, at, true);
      this.u8.set(bytes, at);
      this.u8[at + bytes.length] = 0;
      at += bytes.length + 1;
    });
    return ERRNO.success;
  }

  renamedUnder(from, to, node) {
    if (node.type !== FILETYPE.directory) return;
    for (const [name, child] of node.children) {
      this.touched(`${from}/${name}`);
      this.touched(`${to}/${name}`);
      this.renamedUnder(`${from}/${name}`, `${to}/${name}`, child);
    }
  }

  // -- the calls --

  /// The WASI calls `module` imports, each answered here or with ENOSYS.
  imports(module) {
    const self = this;
    const fileOf = (fd) => {
      const entry = self.fds.get(fd);
      return entry && entry.node.type === FILETYPE.file ? entry : null;
    };
    const calls = {
      args_sizes_get: (count, size) => self.listSizes(self.args, count, size),
      args_get: (argv, buffer) => self.listWrite(self.args, argv, buffer),
      environ_sizes_get: (count, size) => self.listSizes(self.env, count, size),
      environ_get: (environ, buffer) => self.listWrite(self.env, environ, buffer),
      clock_res_get: (_id, out) => {
        self.view.setBigUint64(out, 1000n, true);
        return ERRNO.success;
      },
      clock_time_get: (id, _precision, out) => {
        const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
        self.view.setBigUint64(out, ns, true);
        return ERRNO.success;
      },
      random_get: (ptr, len) => {
        for (let at = 0; at < len; at += 65536) crypto.getRandomValues(self.u8.subarray(ptr + at, ptr + Math.min(len, at + 65536)));
        return ERRNO.success;
      },
      poll_oneoff: (input, output, count, events) => {
        const view = self.view;
        for (let i = 0; i < count; i++) {
          view.setBigUint64(output + i * 32, view.getBigUint64(input + i * 48, true), true);
          view.setUint16(output + i * 32 + 8, 0, true);
          view.setUint8(output + i * 32 + 10, view.getUint8(input + i * 48 + 8));
        }
        view.setUint32(events, count, true);
        return ERRNO.success;
      },
      proc_exit: (code) => {
        throw new Exit(code);
      },
      sched_yield: () => ERRNO.success,
      fd_prestat_get: (fd, out) => {
        const entry = self.fds.get(fd);
        if (!entry?.preopen) return ERRNO.badf;
        self.view.setUint8(out, 0);
        self.view.setUint32(out + 4, self.encoder.encode(entry.preopen).length, true);
        return ERRNO.success;
      },
      fd_prestat_dir_name: (fd, ptr, len) => {
        const entry = self.fds.get(fd);
        if (!entry?.preopen) return ERRNO.badf;
        self.u8.set(self.encoder.encode(entry.preopen).subarray(0, len), ptr);
        return ERRNO.success;
      },
      fd_write: (fd, iovs, count, written) => {
        let total = 0;
        for (const part of self.iovs(iovs, count)) {
          if (fd === 1 || fd === 2) self.say(fd, part);
          else {
            const entry = fileOf(fd);
            if (!entry) return ERRNO.badf;
            const at = entry.append ? BigInt(entry.node.size) : entry.pos;
            self.writeAt(entry, part, at);
            entry.pos = at + BigInt(part.length);
          }
          total += part.length;
        }
        self.view.setUint32(written, total, true);
        return ERRNO.success;
      },
      fd_pwrite: (fd, iovs, count, offset, written) => {
        const entry = fileOf(fd);
        if (!entry) return ERRNO.badf;
        let total = 0;
        let at = offset;
        for (const part of self.iovs(iovs, count)) {
          self.writeAt(entry, part, at);
          at += BigInt(part.length);
          total += part.length;
        }
        self.view.setUint32(written, total, true);
        return ERRNO.success;
      },
      fd_read: (fd, iovs, count, read) => {
        if (fd === 0) {
          self.view.setUint32(read, 0, true);
          return ERRNO.success;
        }
        const entry = self.fds.get(fd);
        if (!entry) return ERRNO.badf;
        if (entry.node.type !== FILETYPE.file) return ERRNO.isdir;
        const got = self.readAt(entry, iovs, count, entry.pos);
        entry.pos += BigInt(got);
        self.view.setUint32(read, got, true);
        return ERRNO.success;
      },
      fd_pread: (fd, iovs, count, offset, read) => {
        const entry = self.fds.get(fd);
        if (!entry) return ERRNO.badf;
        if (entry.node.type !== FILETYPE.file) return ERRNO.isdir;
        self.view.setUint32(read, self.readAt(entry, iovs, count, offset), true);
        return ERRNO.success;
      },
      fd_seek: (fd, offset, whence, out) => {
        if (fd < 3) return ERRNO.spipe;
        const entry = self.fds.get(fd);
        if (!entry) return ERRNO.badf;
        const base = whence === 0 ? 0n : whence === 1 ? entry.pos : BigInt(entry.node.size ?? 0);
        if (base + offset < 0n) return ERRNO.inval;
        entry.pos = base + offset;
        self.view.setBigUint64(out, entry.pos, true);
        return ERRNO.success;
      },
      fd_tell: (fd, out) => {
        const entry = self.fds.get(fd);
        if (!entry) return ERRNO.badf;
        self.view.setBigUint64(out, entry.pos, true);
        return ERRNO.success;
      },
      fd_close: (fd) => {
        const entry = self.fds.get(fd);
        if (!entry) return ERRNO.badf;
        if (!entry.preopen) self.fds.delete(fd);
        return ERRNO.success;
      },
      fd_sync: () => ERRNO.success,
      fd_datasync: () => ERRNO.success,
      fd_advise: () => ERRNO.success,
      fd_allocate: () => ERRNO.success,
      fd_fdstat_get: (fd, out) => {
        const entry = self.fds.get(fd);
        const type = fd < 3 ? FILETYPE.char : entry?.node.type;
        if (type === undefined) return ERRNO.badf;
        self.view.setUint8(out, type);
        self.view.setUint16(out + 2, entry?.append ? FDFLAG_APPEND : 0, true);
        self.view.setBigUint64(out + 8, 0xffffffffffffffffn, true);
        self.view.setBigUint64(out + 16, 0xffffffffffffffffn, true);
        return ERRNO.success;
      },
      fd_fdstat_set_flags: (fd, flags) => {
        const entry = self.fds.get(fd);
        if (!entry) return ERRNO.badf;
        entry.append = (flags & FDFLAG_APPEND) !== 0;
        return ERRNO.success;
      },
      fd_filestat_get: (fd, out) => {
        if (fd < 3) {
          self.writeStat(out, { ino: 0, type: FILETYPE.char, mtime: 0n });
          return ERRNO.success;
        }
        const entry = self.fds.get(fd);
        if (!entry) return ERRNO.badf;
        self.writeStat(out, entry.node);
        return ERRNO.success;
      },
      fd_filestat_set_size: (fd, size) => {
        const entry = fileOf(fd);
        if (!entry) return ERRNO.badf;
        const node = entry.node;
        const length = Number(size);
        node.reserve(length);
        if (length > node.size) node.data.fill(0, node.size, length);
        node.size = length;
        self.touched(entry.path);
        return ERRNO.success;
      },
      fd_filestat_set_times: () => ERRNO.success,
      fd_readdir: (fd, buffer, len, cookie, used) => {
        const entry = self.fds.get(fd);
        if (!entry) return ERRNO.badf;
        if (entry.node.type !== FILETYPE.directory) return ERRNO.notdir;
        const names = [...entry.node.children.keys()];
        let at = 0;
        for (let i = Number(cookie); i < names.length && at < len; i++) {
          const name = self.encoder.encode(names[i]);
          const record = new Uint8Array(24 + name.length);
          const view = new DataView(record.buffer);
          view.setBigUint64(0, BigInt(i + 1), true);
          view.setBigUint64(8, BigInt(entry.node.children.get(names[i]).ino), true);
          view.setUint32(16, name.length, true);
          view.setUint8(20, entry.node.children.get(names[i]).type);
          record.set(name, 24);
          const room = Math.min(record.length, len - at);
          self.u8.set(record.subarray(0, room), buffer + at);
          at += room;
        }
        self.view.setUint32(used, at, true);
        return ERRNO.success;
      },
      path_open: (fd, _dirflags, ptr, len, oflags, _base, _inheriting, fdflags, out) => {
        const path = self.pathAt(fd, ptr, len);
        if (path === null) return ERRNO.badf;
        let node = self.find(path);
        if (node && oflags & OFLAGS.creat && oflags & OFLAGS.excl) return ERRNO.exist;
        if (!node) {
          if (!(oflags & OFLAGS.creat)) return ERRNO.noent;
          const { parent, name } = self.split(path);
          if (!parent) return ERRNO.noent;
          if (parent.type !== FILETYPE.directory) return ERRNO.notdir;
          node = new FileNode(false);
          parent.children.set(name, node);
          self.touched(path);
        }
        if (oflags & OFLAGS.directory && node.type !== FILETYPE.directory) return ERRNO.notdir;
        if (oflags & OFLAGS.trunc && node.type === FILETYPE.file) {
          node.size = 0;
          self.touched(path);
        }
        const handle = self.nextFd++;
        self.fds.set(handle, { node, path, pos: 0n, append: (fdflags & FDFLAG_APPEND) !== 0 });
        self.view.setUint32(out, handle, true);
        return ERRNO.success;
      },
      path_filestat_get: (fd, _flags, ptr, len, out) => {
        const path = self.pathAt(fd, ptr, len);
        if (path === null) return ERRNO.badf;
        const node = self.find(path);
        if (!node) return ERRNO.noent;
        self.writeStat(out, node);
        return ERRNO.success;
      },
      path_filestat_set_times: () => ERRNO.success,
      path_create_directory: (fd, ptr, len) => {
        const path = self.pathAt(fd, ptr, len);
        if (path === null) return ERRNO.badf;
        if (self.find(path)) return ERRNO.exist;
        const { parent, name } = self.split(path);
        if (!parent) return ERRNO.noent;
        if (parent.type !== FILETYPE.directory) return ERRNO.notdir;
        parent.children.set(name, new FileNode(true));
        self.touched(path);
        return ERRNO.success;
      },
      path_unlink_file: (fd, ptr, len) => {
        const path = self.pathAt(fd, ptr, len);
        if (path === null) return ERRNO.badf;
        const { parent, name } = self.split(path);
        const node = parent?.children?.get(name);
        if (!node) return ERRNO.noent;
        if (node.type === FILETYPE.directory) return ERRNO.isdir;
        parent.children.delete(name);
        self.touched(path);
        return ERRNO.success;
      },
      path_remove_directory: (fd, ptr, len) => {
        const path = self.pathAt(fd, ptr, len);
        if (path === null) return ERRNO.badf;
        const { parent, name } = self.split(path);
        const node = parent?.children?.get(name);
        if (!node) return ERRNO.noent;
        if (node.type !== FILETYPE.directory) return ERRNO.notdir;
        if (node.children.size > 0) return ERRNO.notempty;
        parent.children.delete(name);
        self.touched(path);
        return ERRNO.success;
      },
      path_rename: (fd, ptr, len, toFd, toPtr, toLen) => {
        const from = self.pathAt(fd, ptr, len);
        const to = self.pathAt(toFd, toPtr, toLen);
        if (from === null || to === null) return ERRNO.badf;
        const source = self.split(from);
        const target = self.split(to);
        const node = source.parent?.children?.get(source.name);
        if (!node) return ERRNO.noent;
        if (!target.parent || target.parent.type !== FILETYPE.directory) return ERRNO.noent;
        source.parent.children.delete(source.name);
        target.parent.children.set(target.name, node);
        self.touched(from);
        self.touched(to);
        self.renamedUnder(from, to, node);
        return ERRNO.success;
      },
      path_readlink: () => ERRNO.inval,
      path_symlink: () => ERRNO.notsup,
      path_link: () => ERRNO.notsup,
    };
    // Every number WASI passes is unsigned - a descriptor, an address, a
    // length, flags - but a wasm32 one reaches JavaScript signed, negative
    // past 2 GB, which a view or a typed array refuses. Read as what they
    // are, here, for every call; the 64-bit ones come as BigInts and are
    // left alone.
    const unsigned = (call) => (...args) => call(...args.map((arg) => (typeof arg === "number" ? arg >>> 0 : arg)));
    const out = {};
    for (const imported of WebAssembly.Module.imports(module)) {
      if (imported.module === "wasi_snapshot_preview1" && imported.kind === "function") {
        const call = calls[imported.name];
        out[imported.name] = call ? unsigned(call) : () => ERRNO.nosys;
      }
    }
    return { wasi_snapshot_preview1: out };
  }
}

// -------------------------------------------------------------------------
// The platform
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
  /// `args`, `env` and `storage` are a WASI module's command line,
  /// environment, and the IndexedDB database its `/user` is kept in: see
  /// `Files`, which is `files` here.
  constructor(options = {}) {
    this.options = options;
    this.pool = canvasesFrom(options.canvas).map((canvas) => ({ canvas, taken: false }));
    this.container = options.container ?? null;
    this.logSink = options.log ?? defaultLog;
    this.maxDropBytes = options.maxDropBytes ?? 256 * 1024 * 1024;
    this.maxChosenBytes = options.maxChosenBytes ?? 256 * 1024 * 1024;
    this.files = new Files({ args: options.args, env: options.env, storage: options.storage, log: (level, line) => this.logSink(level, line) });
    /// Whether the module is a WASI one, whose files are `files`.
    this.wasi = false;

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

    /// The faces bars above a phone's keyboard were given, by where the
    /// program keeps them: one `FontFace` each.
    this.barFaces = new Map();

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

  /// `text` into `ptr[0..len]`, as much as fits on a whole character.
  /// Answers how many bytes were written.
  writeText(text, ptr, len) {
    const { written } = this.encoder.encodeInto(text, this.u8.subarray(ptr >>> 0, (ptr >>> 0) + (len >>> 0)));
    return written;
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
          // A pointer held inside an element while it still has a position is
          // the one thing here no browser can do, seen or unseen: a lock is
          // the only confinement, and it takes the position away.
          if (!win || mode === MODE.captured || mode === MODE.confinedHidden) return 0;
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

        safeArea: (handle, out) => {
          const win = self.windows.get(handle);
          const edges = win ? (win.insets ?? self.measureSafeArea(win)) : [0, 0, 0, 0];
          const at = out >>> 0;
          for (let i = 0; i < 4; i++) self.view.setUint32(at + i * 4, edges[i], true);
        },

        setIcon: (handle, pixels, len, width, height) => {
          if (!self.windows.get(handle)) return 0;
          const link = self.favicon();
          if (!link) return 0;
          if (!pixels) {
            self.resetFavicon();
            return 1;
          }
          const url = self.pngUrl(pixels, len, width, height);
          if (!url) return 0;
          link.href = url;
          return 1;
        },

        setCursorImage: (handle, pixels, len, width, height, hotX, hotY) => {
          const win = self.windows.get(handle);
          if (!win) return 0;
          if (!pixels) {
            win.image = null;
            self.applyCursor(win);
            return 1;
          }
          const url = self.pngUrl(pixels, len, width, height);
          if (!url) return 0;
          win.image = `url(${url}) ${hotX} ${hotY}, auto`;
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

        setTextInputField: (handle, fieldPtr, textPtr, textLen, hintPtr, hintLen, fontPtr, fontLen) => {
          const win = self.windows.get(handle);
          if (!win) return;
          win.barField = self.readField(fieldPtr >>> 0, textPtr, textLen, hintPtr, hintLen, fontPtr >>> 0, fontLen >>> 0);
          if (win.textInput && self.barWanted(win)) self.showBar(win);
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

        openUrl: (ptr, len) => {
          // Not "noopener", which makes `open` answer null even when it worked.
          const opened = globalThis.open?.(self.text(ptr, len), "_blank");
          if (!opened) return 0;
          try {
            opened.opener = null;
          } catch {}
          return 1;
        },

        localeTag: (ptr, len) => self.writeText(globalThis.navigator?.language ?? "", ptr, len),
        // `getTimezoneOffset` is minutes west, for that moment.
        utcOffset: (unixMs) => -new Date(unixMs).getTimezoneOffset() * 60,
        timeZone: (ptr, len) => self.writeText(Intl.DateTimeFormat().resolvedOptions().timeZone ?? "", ptr, len),
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
      for (const [name, functions] of Object.entries(glue.imports(module))) {
        imports[name] = { ...imports[name], ...functions };
      }
    }
    // A WASI module's operating system is `files`, with `/user` as it was
    // left, read before the module can ask for any of it.
    this.wasi = WebAssembly.Module.imports(module).some((entry) => entry.module === "wasi_snapshot_preview1");
    if (this.wasi) {
      await this.files.load();
      Object.assign(imports, this.files.imports(module));
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
    this.files.memory = this.memory;
    // A WASI reactor with a C library sets it up here, before anything else
    // is called.
    if (typeof instance.exports._initialize === "function") instance.exports._initialize();
    if (this.wasi && typeof addEventListener === "function") {
      // What changed in `/user` is kept as the page goes, as well as a moment
      // after it changed.
      const keep = () => this.files.flush();
      addEventListener("pagehide", keep);
      addEventListener("visibilitychange", () => {
        if (document.visibilityState === "hidden") keep();
      });
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
    await this.files.flush();
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
    // A turned phone moves its notch to the side, and neither the canvas nor
    // the page need change size for it.
    window.addEventListener("resize", () => this.safeAreaChanged(), { signal });
    window.addEventListener("orientationchange", () => this.safeAreaChanged(), { signal });
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
    win.bar?.remove();

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
  ///
  /// The extensions in `WIDENING` are switched on as soon as it is made. A
  /// module cannot do that itself - `getExtension` is JavaScript, and the
  /// binding has no import for it - and each only adds to what the context
  /// can do: float colour targets and the anisotropy limit, which a module
  /// finds out about by trying. One the browser lacks is simply not there.
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
    for (const name of WIDENING) gl.getExtension(name);

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
    this.checkSafeArea(win);
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
    return (
      document.hasFocus() &&
      (active === win.canvas || (win.field !== null && active === win.field) || (win.barShown && win.bar.contains(active)))
    );
  }

  /// What takes the keyboard: the bar while it shows - a tap in the game
  /// keeps typing there, and the game says whether it goes on - the hidden
  /// field while text input is on, and the canvas otherwise.
  typingTarget(win) {
    if (win.barShown) return win.barInput;
    return win.textInput && win.field ? win.field : win.canvas;
  }

  focusWindow(win) {
    this.typingTarget(win).focus({ preventScroll: true });
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
    canvas.addEventListener("pointercancel", (event) => this.pointerCancel(win, event), options);
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

  /// Where an event is on the canvas, in its drawing buffer's pixels: the unit
  /// every backend gives a position in.
  local(win, event) {
    const rect = win.canvas.getBoundingClientRect();
    const [perX, perY] = this.pixelsPerCss(win);
    return [
      (event.clientX - rect.left - win.canvas.clientLeft) * perX,
      (event.clientY - rect.top - win.canvas.clientTop) * perY,
    ];
  }

  pixelsPerCss(win) {
    const fallback = win.scale || 1;
    return [
      win.cssWidth > 0 ? win.fbWidth / win.cssWidth : fallback,
      win.cssHeight > 0 ? win.fbHeight / win.cssHeight : fallback,
    ];
  }

  pointerDown(win, event) {
    win.fingerLast = event.pointerType === "touch";
    // Every finger is a touch of its own; the first is the mouse as well, and
    // a second finger is not a second mouse.
    if (event.pointerType === "touch") this.touch(win, event, 0);
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
    this.buttonsTo(win, event.buttons, modsOf(event), event);
  }

  pointerMove(win, event) {
    if (event.pointerType === "touch") this.touch(win, event, 1);
    if (event.pointerType === "touch" && !event.isPrimary) return;
    this.moved(win, event, true);
    // A second button pressed during a drag arrives as a move, not a down.
    if (event.buttons !== win.buttons) this.buttonsTo(win, event.buttons, modsOf(event), event);
  }

  pointerUp(win, event) {
    if (event.pointerType === "touch") this.touch(win, event, 2);
    if (event.pointerType === "touch" && !event.isPrimary) return;
    if (event.pointerType === "touch") {
      // Safari raises a phone's keyboard only for a field focused inside a
      // tap, and a tap is this.
      this.gesture();
      if (win.textInput) {
        const target = this.typingTarget(win);
        target.blur();
        target.focus({ preventScroll: true });
      }
    }
    this.moved(win, event, false);
    this.buttonsTo(win, event.buttons, modsOf(event), event);
  }

  pointerCancel(win, event) {
    if (event.pointerType === "touch") this.touch(win, event, 3);
    if (event.pointerType === "touch" && !event.isPrimary) return;
    this.buttonsTo(win, 0, 0, event);
  }

  /// One finger, whichever it is: `phase` 0 touched, 1 moved, 2 lifted, 3
  /// taken by the browser.
  touch(win, event, phase) {
    const [x, y] = this.local(win, event);
    this.queue({ kind: KIND.touch, win: win.id, a: phase, b: event.pointerId | 0, x, y, dx: event.pressure ?? 1 });
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
      this.queue({ kind: KIND.cursor, win: win.id, a: event.pointerType === "touch" ? 1 : 0, x, y, dx, dy });
    }
  }

  /// Report whichever buttons changed since the last pointer event.
  buttonsTo(win, buttons, mods, event) {
    const changed = (buttons ?? 0) ^ win.buttons;
    if (changed === 0) return;
    const locked = document.pointerLockElement === win.canvas;
    const x = locked ? 0 : win.lastX;
    const y = locked ? 0 : win.lastY;
    const d = Math.round(event.timeStamp) | 0;
    const dx = event.pointerType === "touch" ? 1 : 0;
    for (const [bit, number] of BUTTON_BITS) {
      if ((changed & bit) === 0) continue;
      const down = (buttons & bit) !== 0;
      this.queue({ kind: KIND.button, win: win.id, a: number, b: down ? 1 : 0, c: mods, d, x, y, dx });
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
    files.forEach((file, index) => this.queue({ kind: KIND.dropFile, win: win.id, a: index, text: this.picked(file.name, bytes[index]) }));
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
    files.forEach((file, index) => this.queue({ kind: KIND.dialogFile, win: dialog.win, a: index, text: this.picked(file.name, file.bytes) }));
  }

  /// What a dropped or chosen file is called to the program: for a WASI one,
  /// its path under `/picked`, where its bytes are put for its file code to
  /// read; for any other, its name.
  picked(name, bytes) {
    if (!this.wasi) return name;
    const path = Files.normalize(`/picked/${name}`);
    if (bytes) this.files.put(path, bytes);
    return path;
  }

  // -- the pointer --

  applyCursor(win) {
    if (win.mode === MODE.hidden) {
      win.canvas.style.cursor = "none";
      return;
    }
    win.canvas.style.cursor = win.image ?? (SHAPES[win.shape] ?? "default");
  }

  // -- the edges a phone draws over --

  /// `env(safe-area-inset-*)` for one canvas, in its drawing buffer's pixels.
  ///
  /// Measured off a hidden element rather than asked for: there is no call for
  /// these, only the CSS environment, and a padding is the shortest way to
  /// read four of them. Zero on a page whose viewport meta tag does not say
  /// `viewport-fit=cover`, which is what makes a browser report them at all.
  measureSafeArea(win) {
    const probe = this.insetProbe ?? this.makeInsetProbe();
    if (!probe || typeof getComputedStyle !== "function") return [0, 0, 0, 0];
    const style = getComputedStyle(probe);
    const [perX, perY] = this.pixelsPerCss(win);
    const css = (value) => Math.max(0, parseFloat(value) || 0);
    return [
      Math.round(css(style.paddingLeft) * perX),
      Math.round(css(style.paddingTop) * perY),
      Math.round(css(style.paddingRight) * perX),
      Math.round(css(style.paddingBottom) * perY),
    ];
  }

  makeInsetProbe() {
    const body = document.body;
    if (!body) return null;
    const probe = document.createElement("div");
    Object.assign(probe.style, {
      position: "fixed",
      left: "0",
      top: "0",
      width: "0",
      height: "0",
      visibility: "hidden",
      pointerEvents: "none",
      paddingLeft: "env(safe-area-inset-left, 0px)",
      paddingTop: "env(safe-area-inset-top, 0px)",
      paddingRight: "env(safe-area-inset-right, 0px)",
      paddingBottom: "env(safe-area-inset-bottom, 0px)",
    });
    body.appendChild(probe);
    this.insetProbe = probe;
    return probe;
  }

  /// Measure again, and say so where they moved. The first measurement is not
  /// a change: a program asks for it.
  checkSafeArea(win) {
    const now = this.measureSafeArea(win);
    const before = win.insets;
    win.insets = now;
    if (!before || now.every((value, index) => value === before[index])) return;
    this.queue({ kind: KIND.safeArea, win: win.id, a: now[0], b: now[1], c: now[2], d: now[3] });
  }

  safeAreaChanged() {
    for (const win of this.windows.values()) this.checkSafeArea(win);
  }

  /// The page's `<link rel="icon">`, made if the page has none.
  favicon() {
    if (this.iconLink) return this.iconLink;
    let link = document.querySelector?.("link[rel~='icon']") ?? null;
    this.iconMade = !link;
    if (!link) {
      const head = document.head ?? document.body;
      if (!head) return null;
      link = document.createElement("link");
      link.rel = "icon";
      head.appendChild(link);
    }
    this.iconWas = link.href ?? "";
    this.iconLink = link;
    return link;
  }

  /// Back to the page's own icon: the address it had, or no link at all where
  /// the page never had one.
  resetFavicon() {
    const link = this.iconLink;
    if (!link) return;
    if (this.iconMade) {
      link.remove?.();
    } else {
      link.href = this.iconWas;
    }
    this.iconLink = null;
  }

  /// The program's pixels as a PNG in a `data:` address.
  ///
  /// CSS takes an image and nothing else - there is no way to hand a page raw
  /// pixels for a cursor - so they go through a canvas, whose `toDataURL` is
  /// the one encoder every browser already has. Null where the page would not
  /// give a 2D context, which is a browser with canvas turned off.
  pngUrl(pixels, len, width, height) {
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d");
    if (!context || !canvas.toDataURL) return null;
    const bytes = new Uint8ClampedArray(this.u8.buffer, pixels >>> 0, len >>> 0).slice();
    context.putImageData(new ImageData(bytes, width, height), 0, 0);
    return canvas.toDataURL("image/png");
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
    win.barField = null;
    this.hideBar(win);
    if (win.composing) {
      win.composing = false;
      this.queue({ kind: KIND.preedit, win: win.id, a: -1, b: -1, text: "" });
    }
    if (win.field && document.activeElement === win.field) {
      win.canvas.focus({ preventScroll: true });
    }
  }

  // -- the bar above a phone's keyboard --

  /// A phone's: a page pressed last with a finger, or one whose pointer is a
  /// finger. A mouse and a keyboard type into the program's own field, as
  /// they would on a desktop.
  barWanted(win) {
    return win.fingerLast || window.matchMedia?.("(pointer: coarse)")?.matches === true;
  }

  /// `setTextInputField`'s field: its text, caret, kind, placeholder, face
  /// and look, read from the program's memory - the face copied once, by
  /// where it is kept.
  readField(fieldPtr, textPtr, textLen, hintPtr, hintLen, fontPtr, fontLen) {
    const view = this.view;
    const u32 = (offset) => view.getUint32(fieldPtr + offset, true);
    const f32 = (offset) => view.getFloat32(fieldPtr + offset, true);
    const text = this.text(textPtr, textLen);
    const flags = u32(8);
    const box = (at) => ({ background: u32(at), border: u32(at + 4), text: u32(at + 8) });
    const sizes = (at) => ({ borderWidth: f32(at), radius: f32(at + 4), paddingX: f32(at + 8), paddingY: f32(at + 12) });
    let look = null;
    if (flags & FIELD_LOOK) {
      const fontKey = fontLen > 0 ? `${fontPtr}:${fontLen}` : "";
      if (fontKey && !this.barFaces.has(fontKey)) this.barFace(fontKey, this.u8.slice(fontPtr, fontPtr + fontLen));
      look = {
        bar: u32(16),
        field: { ...box(20), ...sizes(48) },
        hint: u32(32),
        button: { ...box(36), ...sizes(64) },
        fontSize: f32(80),
        fontKey,
      };
    }
    return {
      text,
      start: unitsAt(text, u32(0)),
      end: unitsAt(text, u32(4)),
      password: (flags & FIELD_PASSWORD) !== 0,
      multiline: (flags & FIELD_MULTILINE) !== 0,
      maxLength: u32(12),
      hint: this.text(hintPtr, hintLen),
      look,
    };
  }

  /// A face from a file's bytes, loaded once and named after where the
  /// program keeps it.
  barFace(key, bytes) {
    const family = `fluxion-bar-${this.barFaces.size}`;
    this.barFaces.set(key, family);
    try {
      new FontFace(family, bytes).load().then(
        (face) => document.fonts.add(face),
        () => {},
      );
    } catch {
      // A face the browser cannot read: the bar keeps the system's.
    }
  }

  /// The bar up with the program's field in it, or brought up to it: its
  /// text, caret, kind, placeholder and look. Typing goes there from now on.
  showBar(win) {
    const field = win.barField;
    if (!win.bar) this.makeBar(win);
    const input = field.multiline ? win.barArea : win.barLine;
    (field.multiline ? win.barLine : win.barArea).style.display = "none";
    input.style.display = "";
    win.barInput = input;
    if (!field.multiline) input.type = field.password ? "password" : "text";
    input.placeholder = field.hint;
    if (field.maxLength > 0) input.maxLength = field.maxLength;
    else input.removeAttribute("maxlength");
    if (input.value !== field.text) input.value = field.text;
    input.setSelectionRange(field.start, field.end);
    // What the bar holds now is what the program said: not said back to it.
    win.barSaid = `${input.selectionStart}:${input.selectionEnd}:${input.value}`;
    this.styleBar(win, field);
    win.bar.style.display = "flex";
    win.barShown = true;
    this.placeBar(win);
    if (document.activeElement !== input) input.focus({ preventScroll: true });
  }

  hideBar(win) {
    if (!win.bar || !win.barShown) return;
    win.barShown = false;
    win.bar.style.display = "none";
    if (win.bar.contains(document.activeElement)) win.canvas.focus({ preventScroll: true });
  }

  makeBar(win) {
    const options = { signal: win.controller.signal };
    const bar = document.createElement("div");
    bar.className = `fluxion-bar-${win.id}`;
    Object.assign(bar.style, {
      position: "fixed",
      left: "0px",
      top: "0px",
      display: "none",
      alignItems: "center",
      gap: "8px",
      padding: "6px 8px",
      boxSizing: "border-box",
      zIndex: "2147483647",
    });
    // The placeholder's colour has no style property of its own.
    const sheet = document.createElement("style");
    const line = document.createElement("input");
    const area = document.createElement("textarea");
    area.rows = 3;
    for (const input of [line, area]) {
      for (const [name, value] of [
        ["autocomplete", "off"],
        ["aria-label", "text input"],
        ["enterkeyhint", "done"],
      ]) {
        input.setAttribute(name, value);
      }
      Object.assign(input.style, { flex: "1", minWidth: "0", boxSizing: "border-box", outline: "none", resize: "none", margin: "0" });
      input.addEventListener("input", () => this.barEdited(win), options);
      input.addEventListener("keydown", (event) => this.barKeyDown(win, event), options);
      // The window keeps the keyboard while the bar has it.
      input.addEventListener("focus", () => this.focusChanged(), options);
      input.addEventListener("blur", () => this.focusChanged(), options);
      // A caret moved with no change to the text: the arrows, a tap, a
      // selection. Said once whichever of these a browser has.
      for (const name of ["select", "selectionchange", "keyup", "pointerup"]) {
        input.addEventListener(name, () => this.barEdited(win), options);
      }
    }
    document.addEventListener(
      "selectionchange",
      () => {
        if (win.barShown && document.activeElement === win.barInput) this.barEdited(win);
      },
      options,
    );
    const ok = document.createElement("button");
    ok.type = "button";
    ok.textContent = "OK";
    // Pressed without taking the focus, so the keyboard stays up till it is let go.
    ok.addEventListener("pointerdown", (event) => event.preventDefault(), options);
    ok.addEventListener("click", () => this.barDone(win, true), options);
    bar.append(sheet, line, area, ok);
    document.body.appendChild(bar);
    for (const name of ["resize", "scroll"]) window.visualViewport?.addEventListener(name, () => this.placeBar(win), options);
    window.addEventListener("resize", () => this.placeBar(win), options);
    win.bar = bar;
    win.barSheet = sheet;
    win.barLine = line;
    win.barArea = area;
    win.barOk = ok;
  }

  /// At the bottom of what the reader sees, which a keyboard that came up has
  /// moved: on top of the keyboard.
  placeBar(win) {
    if (!win.barShown) return;
    const view = window.visualViewport;
    const width = view ? view.width : window.innerWidth;
    const bottom = view ? view.offsetTop + view.height : window.innerHeight;
    Object.assign(win.bar.style, {
      left: `${view ? view.offsetLeft : 0}px`,
      width: `${width}px`,
      top: `${Math.max(0, bottom - win.bar.offsetHeight)}px`,
    });
  }

  /// The program's look, its sizes from the drawing buffer's pixels to CSS
  /// ones; or the bar's own.
  styleBar(win, field) {
    const look = field.look;
    const [perX] = this.pixelsPerCss(win);
    const px = (value) => `${value / perX}px`;
    // Sixteen pixels at least: Safari zooms the page in on smaller text.
    const size = look ? Math.max(16, look.fontSize / perX) : 18;
    const family = look?.fontKey ? `"${this.barFaces.get(look.fontKey)}", sans-serif` : "";
    const boxStyle = (box) => ({
      background: cssColor(box.background),
      color: cssColor(box.text),
      border: box.borderWidth > 0 ? `${px(box.borderWidth)} solid ${cssColor(box.border)}` : "none",
      borderRadius: px(box.radius),
      padding: `${px(box.paddingY)} ${px(box.paddingX)}`,
      fontSize: `${size}px`,
      fontFamily: family,
    });
    win.bar.style.background = look ? cssColor(look.bar) : "rgba(32, 32, 36, 0.94)";
    const plain = { background: "#2e2e34", color: "#ffffff", border: "1px solid #5a5a66", borderRadius: "6px", padding: "8px 12px", fontSize: "18px", fontFamily: "" };
    for (const input of [win.barLine, win.barArea]) Object.assign(input.style, look ? boxStyle(look.field) : plain);
    Object.assign(
      win.barOk.style,
      look ? boxStyle(look.button) : { background: "", color: "", border: "", borderRadius: "", padding: "8px 14px", fontSize: "16px", fontFamily: "" },
    );
    win.barSheet.textContent = `.fluxion-bar-${win.id} ::placeholder { color: ${look ? cssColor(look.hint) : "#8a8a94"}; }`;
  }

  /// What the bar holds and where its caret is, to the program, whole -
  /// in pieces a drain holds - when either changed.
  barEdited(win) {
    const input = win.barInput;
    if (!win.barShown || !input) return;
    const value = input.value;
    const start = input.selectionStart ?? value.length;
    const end = input.selectionEnd ?? value.length;
    const said = `${start}:${end}:${value}`;
    if (said === win.barSaid) return;
    win.barSaid = said;
    const a = utf8Length(value.slice(0, start));
    const b = utf8Length(value.slice(0, end));
    const pieces = piecesOf(value, BAR_PIECE);
    pieces.forEach((piece, at) => {
      this.queue({ kind: KIND.textEdited, win: win.id, a, b, c: at + 1 < pieces.length ? 1 : 0, text: piece });
    });
  }

  /// Enter finishes a field that takes no lines, as OK does; Escape puts the
  /// bar away. The rest is the field's own.
  barKeyDown(win, event) {
    if (event.key === "Enter" && !win.barField?.multiline) {
      event.preventDefault();
      this.barDone(win, true);
    } else if (event.key === "Escape") {
      event.preventDefault();
      this.barDone(win, false);
    }
  }

  barDone(win, submitted) {
    this.barEdited(win);
    this.queue({ kind: KIND.textDone, win: win.id, a: submitted ? 1 : 0 });
    this.hideBar(win);
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
    // The area is in the drawing buffer's pixels, and a style in CSS pixels.
    const [perX, perY] = this.pixelsPerCss(win);
    Object.assign(field.style, {
      left: `${rect.left + win.canvas.clientLeft + area.x / perX}px`,
      top: `${rect.top + win.canvas.clientTop + area.y / perY}px`,
      width: `${Math.max(1, area.width / perX)}px`,
      height: `${Math.max(1, area.height / perY)}px`,
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
