# Phase 15 — the application layer (scope)

The answer to "how do I do X", for the X a person actually has. Read
[PLAN.md](PLAN.md) for where this sits (it needs 9, 10, 11 and 14, all done;
it unblocks Phase 17's `pkg` hook and thesis 1), [PRODUCT.md §4.1](PRODUCT.md)
for the shopping list and §5.1 for the browser, and [HANDOFF.md](HANDOFF.md) for
the traps: §2.43 (assert on the thing, not the run), §2.45 (a silent fallback
is invisible) and §2.37 (a probe with no positive control).

Last updated: 2026-09-30. **Scoped, with the spikes run on the 16-CURRENT
guest** (§4). What changed from PLAN before a line was written:

- **The browser is Firefox ESR, not Epiphany.** PLAN's own rule: Firefox ESR
  "if WebKitGTK's port is still at 2.46.6 when this comes due". It is — on the
  16-CURRENT *latest* branch, `webkit2-gtk_*` 2.46.6 and `epiphany` 47.7, beside
  `firefox-esr` 153.4 (§4.2).
- **The protocols bullet is already done.** PLAN listed the extension
  protocols applications expect; BACKLOG's U.1–U.10 shipped every one it ranked
  (subsurfaces, linux-dmabuf, presentation-time, text-input, pointer lock,
  cursor-shape, viewporter, fractional scale, explicit sync, surface enter).
- **Two toolkit pieces do not exist and gate two applications**: a multi-line
  text view (TextEdit) and a character grid over a pty (Terminal). Neither is
  in the tree (§2).

---

## 1. What this phase is

**Goal (PLAN):** every installed port shows up as a Mac-shaped application, a
browser renders the web under our compositor, and the escape hatch — a Terminal
— exists, with TextEdit, Grab, Activity Monitor and Disk Utility covering the
rest of PRODUCT §4.1's everyday list.

**What it is not:** printing, Bluetooth and a git client stay deferred, as PLAN
says, with their reasons. No IDE, no office suite, no browser engine of our own
(PRODUCT §10). And not Phase 17: the generator is *run* here by hand and by the
session; wiring it to `pkg` as a hook is delivery's.

---

## 2. What we have vs. what's new

| Piece | Have | New |
|---|---|---|
| Application bundles | The Finder launches `Foo.app/Contents/MacOS/Foo` and draws `Contents/Resources/*.png|icns` (`Launcher`, `AppIcon`, P2.11). No Info.plist, no LaunchServices | A generator that writes bundles from `.desktop` files |
| Icons | PNG and `.icns` decoding | Icon-theme lookup (hicolor, then the others), SVG through `rsvg-convert` at generation time |
| Foreign apps | GTK and Qt menus in our bar, portals, SSDs, the XCursor theme | — (Phase 8–11 and U.* did it) |
| Browser | nothing | Firefox ESR, adopted: installed, launched as a bundle, rendering, its file chooser through our portal |
| Text | single-line `TextField` | a multi-line text view: caret, selection, scrolling, undo (P10), clipboard (P9) |
| Terminal | no pty code; the `mono` type role (P11.7) | pty spawn (`openpty`), a VT parser, a character-grid view, scrollback, selection |
| Screenshots | `abyssgrab` (screencopy) and the screenshot portal | Grab: selection rectangle, window picker, save sheet |
| Processes | `KERN_PROC` use in `Launcher` | Activity Monitor: the process table, CPU and memory, quit |
| Disks | `DiskInventory` (installer) | Disk Utility: volumes, mount/unmount, ZFS snapshots — through the settings helper |

---

## 3. Ordered passes

In the order that pays soonest, each with its own live test (§5).

**P15.1 — `.desktop` → `.app` (M).** A pure `AppBundles` target (parse a Desktop
Entry, decide whether it becomes an application, choose its icon, describe the
bundle) and an `abyss-appgen` tool that writes them. Rules from §4.1:
`Type=Application` only; `NoDisplay=true` and `Hidden=true` skipped; `Exec`'s
field codes (`%f %F %u %U`) become `"$@"`, the rest dropped (`%i %c %k`, per the
spec); `Terminal=true` waits for P15.4 and is skipped until then. The bundle:
`/Applications/<Name>.app/Contents/MacOS/<Name>` (a two-line `sh` that `exec`s
the command), `Contents/Resources/<Name>.png` (the best icon, SVG rasterised to
256 px), and a marker naming the `.desktop` it came from, so regeneration
replaces and removes only what it made. Run by hand now, and at session start
by `anchor` into `~/Applications` until Phase 17 makes it a `pkg` hook.
*Verified:* the guest's kcalc becomes `KCalc.app` with its breeze icon; the
Finder opens `/Applications`, a double-click maps kcalc's window.

**P15.2 — the Dock and the Apple menu carry real applications (S–M).** The
Dock's tiles become a list of bundles (defaults: Finder, the browser, Terminal,
System Preferences), editable by dragging a bundle on and off; the Apple menu's
Recent Items. *Verified:* a tile launches its application and shows it running.

**P15.3 — the browser (M).** Firefox ESR installed on the medium and in the
guest; a generated `Firefox.app`; rendering under `undertow` (the §4.2 spike);
its file chooser answered by our portal (the P8.4 path, with Firefox's
`widget.use-xdg-desktop-portal.file-picker`); menus in our bar if Firefox
publishes them (it may not — §6.3). *Verified:* a local page's colour read back
through screencopy; a file picked in the Finder reaches the page.

**P15.4 — Terminal (L), in three.** (a) `Pty`: spawn a shell on a
pseudo-terminal (`openpty` + `Spawn`), resize (`TIOCSWINSZ`), and a pure VT
parser — an xterm subset: printable text, C0 controls, CSI cursor movement,
erase, SGR colours and attributes, scroll regions, the alternate screen — into
a screen model, unit-tested with no display; (b) the application: the grid drawn
with the `mono` role, keys to bytes, a blinking caret, resize; (c) scrollback,
selection and the clipboard, and the menu vocabulary (New Window, Copy, Paste,
Clear). *Verified:* `vi` and `top` draw correctly (screen-model assertions
after known input), a selection pasted elsewhere arrives intact.

**P15.5 — TextEdit (L).** The toolkit's multi-line text view (it is a toolkit
piece, not TextEdit's: every later editor uses it), then TextEdit on it: open
and save plain text, through the file chooser (our portal, so a sandboxed
editor is possible later), undo, find. *Verified:* a file opened, edited with
the virtual keyboard, saved, and its bytes read back.

**P15.6 — Grab (S–M).** A selection rectangle on a layer surface over every
output, a window picker (foreign-toplevel), and a save sheet, over the
screencopy `abyssgrab` already does. *Verified:* a region's pixels in the saved
file match the screen.

**P15.7 — Activity Monitor (M).** The process table from `kern.proc.all`
(sysctl, no `kvm` needed for our own view), CPU and memory, sorted and
refreshed; quitting a process of one's own with a signal, another user's
through the helper (administrators only, as P14.3). *Verified:* a process
started by the test appears, is quit from the window, and is gone.

**P15.8 — Disk Utility (M–L).** Volumes from `DiskInventory`, mount and unmount,
and ZFS snapshots — list, create, roll back — through the settings helper as
typed plans. *Verified:* a snapshot of a scratch dataset is made, a file is
changed, and a rollback brings it back.

---

## 4. The spikes

### 4.1 What `.desktop` files look like — **messier than the spec, as expected.**

On the guest (15 entries: Qt tools, GTK demos, kcalc, Xwayland, KDE URL
handlers):

- **8 of 15 are `NoDisplay=true`** — URL handlers (`kde-geo-uri-handler … %u`),
  daemons (`kded6`, whose `Exec=` is empty), Xwayland. Skipping them is the
  difference between an Applications folder and a junk drawer.
- **Field codes appear** (`%F`, `%u`), and one `Exec` is a long quoted command
  line — the generator keeps the words, not a shell re-parse.
- **Icons are spread across themes and formats.** `hicolor` has PNGs (up to
  256 px for the GTK demos, 128 for Qt's tools); kcalc's `accessories-calculator`
  is 16–48 px PNG in `AdwaitaLegacy` and **SVG only** in `breeze`. 48 px is too
  small for the Finder or the Dock, so **SVG has to be rasterised**:
  `rsvg-convert` is on the guest (librsvg, a GTK dependency), used at
  generation time only, with the best PNG as the fallback.

### 4.2 Does a real browser render under `undertow`? — **Yes, after one crash.**

Firefox ESR 153.4 in the 16 guest, native Wayland (`MOZ_ENABLE_WAYLAND=1`),
`--kiosk` on a page of one colour (#e8b04c), a pixel read back through
`abyssgrab`: **the whole 1024×768 output is the page, within a second of
Firefox starting**, on the pixman renderer (no GPU in the guest; Firefox draws
in software into shm buffers).

**The first attempt took `undertow` down**:
`Assertion failed: (surface->initialized), function
wlr_xdg_surface_schedule_configure`. `--kiosk` asks for fullscreen *before* the
window's first commit, and `undertow` answered `request_fullscreen` with a
configure at once — which wlroots forbids until the surface is initialized.
Decorations had met the same trap in P9.6 and been guarded; maximize, minimize
and fullscreen had not, because no client of ours asks that early. They are now
deferred to the initial commit, which answers whatever was requested
(HANDOFF §2.98). **Every real browser was one fullscreen request from crashing
the desktop.**

And one sampling lesson, re-learned: the first "grey" reading was the pointer,
which rests at the exact centre of the display (§2.85) — sample off-centre.

### 4.3 Terminal and TextEdit — **nothing to reuse, and nothing in the way.**

No pty code and no multi-line text in the tree. `openpty` is in libutil on
FreeBSD and libc on Linux; `Spawn` already starts processes async-signal-safely
and needs only a "use this fd as the controlling terminal" option. The `mono`
role (IBM Plex Mono, vendored) exists for the grid.

---

## 5. Verification

As every phase since 9: each application driven live under `undertow` in the
harness and clicked by the virtual pointer and keyboard, asserting on the thing
— a mapped window's app_id, a file's bytes, a pixel, a process that is gone —
on Linux and the FreeBSD guest. The pure parts (Desktop Entry parsing, the VT
parser, the text model) are unit-tested with no display.

---

## 6. Risks and open decisions

**6.1 Web applications with Firefox.** PRODUCT §6.1 promised web apps as
bundles "for free" through a browser's `--app=` mode. Firefox removed its
site-specific-browser mode; Epiphany and Chromium have one. Options: (a) web
apps are bundles that open a Firefox window on the site — honest, but a browser
window, not an app; (b) Chromium for web apps only (503 MiB) — **not
recommended**; (c) defer web apps. **Recommendation: (a) now, and say so on the
bundle** — revisit if WebKitGTK's port moves and Epiphany comes back.

**6.2 Where bundles go.** `/Applications` is root's; a session cannot write it
until the `pkg` hook exists. **Recommendation:** the generator writes
`/Applications` when run as root (the medium's build, Phase 17's hook) and
`~/Applications` when run by the session; the Finder and Dock read both.

**6.3 Foreign menus in our bar.** Firefox does not export `org.gtk.Menus` or
dbusmenu on Wayland by default; its menu bar is its own. The bar will show the
application's name and our standard menus until it does — to be seen, not
assumed, in P15.3.

**6.4 Terminal scope.** An xterm subset, not a full emulator: enough for `vi`,
`top`, `less` and a shell's line editing. `TERM=xterm-256color` promises more
than that; **recommendation:** advertise `xterm` (fewer claims) until the
parser is measured against `vttest`.

**6.5 The browser is the biggest thing on the medium.** Firefox ESR and its
dependencies are hundreds of megabytes on a 3 GB image; the medium grows, or
the browser is installed on first use. Measured in P15.3.
