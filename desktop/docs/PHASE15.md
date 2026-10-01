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
| Foreign apps | GTK menus in our bar, portals, SSDs, the XCursor theme (Qt's removed: §6.6) | — (Phase 8–11 and U.* did it) |
| Browser | nothing | Firefox ESR, adopted: installed, launched as a bundle, rendering, its file chooser through our portal |
| Text | single-line `TextField` | a multi-line text view: caret, selection, scrolling, undo (P10), clipboard (P9) |
| Terminal | no pty code; the `mono` type role (P11.7) | pty spawn (`openpty`), a VT parser, a character-grid view, scrollback, selection |
| Screenshots | `abyssgrab` (screencopy) and the screenshot portal | Grab: selection rectangle, window picker, save sheet |
| Processes | `KERN_PROC` use in `Launcher` | Activity Monitor: the process table, CPU and memory, quit |
| Disks | `DiskInventory` (installer) | Disk Utility: volumes, mount/unmount, ZFS snapshots — through the settings helper |

---

## 3. Ordered passes

In the order that pays soonest, each with its own live test (§5).

**P15.1 — `.desktop` → `.app` (M).** ✅ **Done 2026-09-30:** `AppBundles` +
`abyss-appgen`, run by `anchor` at login into `~/Applications`, shipped on the
medium; `live-appgen.sh` (kcalc's real entry in the guest — galculator's since §6.6). The guest's 15
entries make 6 applications in 1.4 s, and removing a bundle read its marker
after deleting it — fixed before it shipped. A pure `AppBundles` target (parse a Desktop
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
✅ **Done 2026-09-30**, in three:

- **(a) ✅ Done 2026-09-30 — the tiles are bundles.** `abyss-appgen` writes
  `Contents/app-id`: the app_ids a window of the application may carry —
  `StartupWMClass`, the desktop-file ID, the program's name — and a window
  matches one of them, or the program's name with a `-variant` suffix. That last
  rule is Firefox ESR's: `firefox.desktop`, `Exec=firefox`, and a window that
  says `firefox-esr`. `AppLibrary` reads `~/Applications` then `/Applications`
  (the person's shadows root's); `dock.ini`'s `apps = finder; Galculator; sysprefs`
  pins, by bundle name or path; without it the Dock is the Finder, the browser
  if one is installed, and System Preferences. The Browser, Mail and Music
  placeholders — tiles that launched nothing — are gone (Terminal joins in
  P15.4). A tile draws its bundle's icon, a running unpinned application wears
  its bundle's name and icon, and the library is reread as windows come and go,
  since at first login appgen may still be writing it. The Dock logs where its
  tiles are (`Dock: tiles Finder=346,36 …`); `live-dnd` and `live-sway`'s Trash
  and Finder clicks aim there instead of at x-positions measured once for six
  tiles. The Dock's three goldens moved, on purpose, on both platforms.
  `live-dock-apps.sh`: pinned by name, launched by a click, the running window
  matched to its tile (no second tile), a second click activates rather than
  launches, and an unpinned running application wears its bundle's name.
- **(b) ✅ Done 2026-09-30 — editing.** A bundle dropped anywhere on the Dock
  but the Trash is pinned before the tile it landed on (moved, not doubled, if
  it was already there); a pinned tile's menu has "Remove from Dock" (not the
  Finder's), a running unpinned application's has "Keep in Dock". Each edit
  rewrites `dock.ini`'s `apps`, keeping its other keys. An entry naming a bundle
  that is not installed has no tile but keeps its place in the list, so a
  reinstalled application comes back where it was. A bundle is pinned by name
  when the name finds it again, else by path — a root bundle shadowed by the
  person's own of the same name. A document dropped on an application's tile
  opens with it: the launcher's `"$@"` (P15.1) is given the file. The popup
  now logs where the compositor placed it (`Surface.Popup: placed at X,Y`), so a
  test clicks a Dock menu's row where it really is. `live-dock-apps.sh` claims
  6–9: Keep, Remove and Quit through the tile menu; a bundle dragged out of the
  Finder and onto System Preferences lands before it; a text file dropped on
  the application's tile opens a window.
- **(c) ✅ Done 2026-09-30 — the Apple menu's Recent Items.** The applications
  opened from the Dock (a click, or a document dropped on a tile), the Finder
  and the desktop (`Launcher.open`), and the menu itself — most recent first,
  once each, ten at most — kept in the pool's `recent` domain (`recent.ini`),
  since three processes write it and a fourth reads it; the last writer wins a
  race, and the pool's atomic write means a race never tears the file. The bar
  reads it as the system menu opens: Recent Items is a submenu of bundle names
  and Clear Menu (disabled when empty), and a choice launches on the ordinary
  display, never the bar's privileged one — the System Preferences rule.
  `live-dock-apps.sh` claim 10: the Dock's launches are listed, choosing one
  opens it again on the ordinary display (the fixture records which), and Clear
  Menu empties it. The Finder's half of the recording is `Launcher.open`, which
  no live test drives on a bundle yet — the unit test covers the list.

**P15.3 — the browser (M).** Firefox ESR installed on the medium and in the
guest; a generated `Firefox.app`; rendering under `undertow` (the §4.2 spike);
its file chooser answered by our portal (the P8.4 path, with Firefox's
`widget.use-xdg-desktop-portal.file-picker`); menus in our bar if Firefox
publishes them (it may not — §6.3). *Verified:* a local page's colour read back
through screencopy; a file picked in the Finder reaches the page.

- **(a) ✅ Done 2026-09-30 — the browser in the session.** `live-firefox.sh`, on
  both platforms (Fedora's Firefox 156.0.1 on Linux, `firefox-esr` 153.4 in the 16
  guest): the port's real entry becomes a bundle whose app-ids match its window
  (`firefox`, which `firefox-esr` matches; Fedora's is `org.mozilla.firefox`);
  launched **through that bundle** with a fresh profile and nothing set but what
  the session sets, Firefox picks Wayland itself and its page's colour is read
  back through screencopy; clicking a file input opens **the Finder**, through
  `OpenFile` on the session bus; the file picked there reaches the page, which
  reads its contents. Firefox names no starting folder, so the picker opens on
  the home directory. What made it work in a real session: **`anchor` now
  exports `GTK_USE_PORTAL=1`** while the bridge is in the plan
  (`SessionPlan.applicationEnvironment`) — Firefox's file-picker pref defaults
  to following it, as GTK 3 does; without it both draw GTK's own dialog.
  §6.3, seen: Firefox owns only its remoting name
  (`org.mozilla.firefox.<profile>`) — no `org.gtk.Menus`, no dbusmenu — so its
  menu bar stays its own, and ours shows the standard menus.
- **(b) ✅ Done 2026-09-30 — on the medium (§6.5, decided by the user: "most
  users will need a browser").** `live-image.sh`'s new "the browser" step
  copies the builder's installed `firefox-esr` — the build its libraries are
  linked against, like everything else there — and closes over it. What
  `ldd` cannot see was **measured, not guessed**: `live-firefox.sh` with
  `ABYSS_FF_MAPS` lists every object mapped into Firefox's processes after a
  page and a portal round trip, and the difference from `ldd` was NSS's
  modules (freebl3, freeblpriv3, softokn3, nssckbi), GTK's pixbuf loaders and
  `im-wayland` (reached through `.cache` indexes, read and closed, so never
  mapped), the GSettings schemas, the MIME database and three icon themes.
  Also carried: FFmpeg's `libavcodec.so.63` + `libavutil` for H.264/AAC
  (Firefox 153 knows `.63`; VP9, AV1 and Opus it decodes itself). Audio needs
  nothing — with no PulseAudio, JACK or sndio, cubeb uses OSS. The result:
  Firefox 338 MiB plus 94 more shared objects; `abyss.tzst` 92 → 243 MB, the
  image 1.0 → 1.3 GB, still in 3 GB — and the installed system gets the browser
  too, since the set is the same collection. **Checked without booting:**
  `live-medium-browser.sh` chroots into the kept staging root (base plus only
  what the medium carries), makes Firefox's bundle from the medium's own entry,
  and renders a page on a headless undertow there, then asserts NSS and
  `im-wayland` were loaded. That last assertion earns its place: with
  `libsoftokn3.so` removed, **Firefox still starts and paints** — only the
  mapping check fails. Not yet seen on metal; and the Dock pins Firefox by
  default only once `abyss-appgen` has written its bundle, which at a first
  login can land after the Dock has looked (it looks again when a window opens
  or closes).

**P15.4 — Terminal (L), in three.** (a) `Pty`: spawn a shell on a
pseudo-terminal (`openpty` + `Spawn`), resize (`TIOCSWINSZ`), and a pure VT
parser — an xterm subset: printable text, C0 controls, CSI cursor movement,
erase, SGR colours and attributes, scroll regions, the alternate screen — into
a screen model, unit-tested with no display; (b) the application: the grid drawn
with the `mono` role, keys to bytes, a blinking caret, resize; (c) scrollback,
selection and the clipboard, and the menu vocabulary (New Window, Copy, Paste,
Clear). *Verified:* `vi` and `top` draw correctly (screen-model assertions
after known input), a selection pasted elsewhere arrives intact.

- **(a) ✅ Done 2026-09-30 — the pty and the model.** `ap_pty_spawn` in
  `CPlatform` (posix_openpt, so no libutil; the child only setsid → open the
  slave → TIOCSCTTY → dup2 → execve, async-signal-safe as `Spawn` requires) and
  `Pty` around it; `Terminal`, pure: `VTParser` (Williams' DEC state machine cut
  to ground/ESC/CSI/OSC/DCS-ignored, UTF-8 in ground, a control inside a broken
  rune still acts) and `Screen` — the subset read off xterm's terminfo, not
  guessed: CUP/CUU…/HPA/VPA, ED/EL/ECH, ICH/DCH/IL/DL, SU/SD, scroll regions
  (IL/DL and a region's scrolling are not history), SGR with 256 and direct
  colour, `bce`, pending wrap, tabs, DEC line drawing, `REP` (ncurses 6's
  `rep`), the alternate screen (1049/1047/47), DECCKM, bracketed paste, OSC
  titles, DSR/DA replies, DECSTR (FreeBSD termcap's `is`), scrollback, resize.
  `TERM=xterm` (§6.4). Not yet: double-width characters (one column each),
  combining marks, mouse reporting. `abyss-vt` runs a program on a pty through
  the model with no display, typing on a script and printing the screen.
  `TerminalTests` (16) and `live-vt.sh`, the same assertions against different
  programs — vim and procps top on Linux, nvi and FreeBSD top in the guest: a
  shell's echo and `stty size` (8×40, then 6×30 after a resize); vi draws the
  file, `~` to the status line, cursor 1,1, and `j dd :wq` deletes line two
  **on disk**; top draws its header and table and `q` quits it. Found on the
  way: FreeBSD's termcap `xterm` has no `ti`/`te`, so nvi draws on the main
  screen — correct, and what a real xterm shows.
- **(b) ✅ Done 2026-09-30 — the application.** `TerminalApp` (`AQUA_SCENE=
  terminal`, app_id `org.abyssbsd.terminal`; `-e PROGRAM ARGS…` runs a program
  instead of the shell, as xterm's does): a window per shell, 80×24 from the
  `mono` role's cell, its own Aqua chrome, the grid drawn run by run with
  xterm's palette on Jaguar Terminal's black-on-white, bold as bright, inverse,
  dim, underline and strike, the light box characters drawn edge to edge
  rather than from the font (a glyph is shorter than a cell, and a box of them
  had gaps), a blinking block caret (an outline when the window is not
  active), the window's size given to the shell (TIOCSWINSZ → SIGWINCH), the
  title `program — cols×rows` or the program's own (OSC 0/2), menus (Terminal,
  Shell: New Window ⌘N / Close Window ⌘W, Window), and a window that closes
  when its shell exits — the last one quits. `KeyEncoder` (pure, tested): text,
  Control folding (from the keysym when the toolkit gives no text — Surface
  does not, for a control character), Option as Meta, DECCKM, xterm's
  modified cursor and function keys. `live-terminal.sh`, both platforms: the
  window maps 80×24; typed text runs and is **drawn** (dark pixels on the row
  the model holds, none on a blank one, through screencopy); Ctrl-C stops
  `sleep 30`; vi opens a file, **Down** moves in it and `dd :wq` changes it on
  disk; the zoom button (pressed where the log says it was drawn) enlarges the
  window and `stty size` agrees; ⌘N opens a second shell; `exit` closes each
  window and the last quits. **Found by that test:** Ctrl-C reached the tty
  and stopped nothing — the Terminal had been started by a non-interactive
  shell's `&`, which ignores SIGINT, and an ignored signal survives `exec`
  into the shell and everything it runs. The pty child now resets every
  signal to its default and clears the mask before `execve`, as xterm does.
  Golden: `terminal` and `terminal@2x`, a fixed transcript through the real
  model.
  **And in the Dock, and for ports:** a `terminal` token and tile (an icon in
  each theme — Aqua's drawn to match its tiles, Trench's imported from its own
  `term.svg`), so the default Dock is Finder, the browser, Terminal, System
  Preferences, as P15.2 planned; and `abyss-appgen` no longer skips
  `Terminal=true` entries — with the shell binary beside it, their launcher is
  `exec env AQUA_SCENE=terminal …/AquaDemo -e COMMAND`. `live-dock-apps` claim
  11 (the default Dock, and its Terminal tile opening Terminal) and
  `live-appgen` (a `Terminal=true` fixture becomes `Top.app`, which opens a
  Terminal running `top`). Goldens moved on purpose: the Dock scenes (a fourth
  tile) and the icon sheets (a new icon), on both platforms.
- **(c) ✅ Done 2026-09-30 — scrollback, selection, the clipboard.** The model
  (tested): every line addressable across scrollback and screen (`TextPoint`),
  the text of a selection with a **wrapped line joined back into one** — the
  row's last cell carries `wrapsToNext`, so scrolling, insert/delete and
  scrollback move the flag with the text and erasing clears it — word and line
  ranges, Clear Scrollback, and `Paste.bytes` (newlines as Return; bracketed
  when the program asked, `CSI ?2004h`, with an end marker inside the text
  removed so a paste cannot break out and run commands). The window: the view
  scrolls into the history (wheel; Page Up/Down, Home, End as Mac Terminal —
  Shift sends them to the program, and on the alternate screen they always go
  to it), stays on what is being read while output arrives, and returns to the
  live screen on typing; drag selects, double-click a word (dragging by
  words), triple-click a line, drawn in Jaguar's highlight; an Edit menu —
  Copy ⌘C (only with a selection, so Ctrl-C is still interrupt), Paste ⌘V,
  Select All ⌘A, Clear Scrollback ⌘K. A paste of this process's own copy uses
  what it copied (the clipboard will not read back a selection its own process
  owns). `live-terminal.sh` claims 6–8, both platforms: `seq 1 300` and the
  wheel reaches history, typing returns; **a 200-character line wrapped over
  two rows, dragged and ⌘C'd, is ⌘V'd into a second Terminal *process*
  running `cat > pasted.txt`, and the file holds exactly those 200 characters
  on one line** (the pass's verification); ⌘K leaves the wheel nowhere to go.
  The test's own lessons: `vkeyboard` cannot type `;`, and a zoomed window's
  place is only in undertow's exit summary (it fills the output from 0,0).

**P15.4 ✅ complete 2026-09-30.** §6.4 stands: `TERM=xterm` until the parser
is measured against vttest.

**P15.5 — TextEdit (L).** The toolkit's multi-line text view (it is a toolkit
piece, not TextEdit's: every later editor uses it), then TextEdit on it: open
and save plain text, through the file chooser (our portal, so a sandboxed
editor is possible later), undo, find. *Verified:* a file opened, edited with
the virtual keyboard, saved, and its bytes read back.
✅ **Done 2026-10-01**, in three:

- **(a) the model — `TextModel`, pure, 8 tests.** Lines of Characters (a caret
  never lands inside a grapheme), one `replace` primitive every edit goes
  through so Undo is exact by construction; Mac motion (Option for words —
  from a line's end, to the end of the next word — Command for row ends and the
  document's); **undo that groups a run of typing (or of Backspaces) into one
  "Undo Typing"**, closed by a click, a caret move or a save, with the
  selection put back, and a dirty flag that knows when Undo returns to the saved
  text — and that an edit after undoing past it can never get back there; find,
  either way, round the end, case optionally ignored; and `TextLayout`, which
  wraps lines after the last space that fits (or inside a word longer than the
  row) and maps positions to (row, x) and back — a caret at a wrap starts the
  next row, a click past a wrapped row's end lands at that row's end.
- **(b) the toolkit's `TextView` and TextEdit on it.** The view: scrolled,
  wrapped, Jaguar's selection highlight (a selected newline drawn to the edge),
  a thin blinking caret, keys (arrows, Shift, Option, Command, Page keys,
  Delete both ways, Return, Tab) and the pointer (click, Shift-click, drag,
  double- and triple-click, the wheel). **Fixed pitch for now** (the `mono`
  role), so caret and click positions are exact; proportional text needs only
  another `advance` for the layout. TextEdit (`AQUA_SCENE=textedit`, app_id
  `org.abyssbsd.textedit`; files as arguments): a window per document, title
  `name — Edited`, menus (File: New, Open…, Close, Save, Save As…; Edit: Undo
  and Redo titled from the history, Cut, Copy, Paste, Select All, Find…, Find
  Next/Previous), a find bar. **Open… and Save As… ask the portal** — the
  answer arrives on its socket in the run loop, so the window keeps drawing
  while the person chooses in the Finder; Save is a temporary file and a
  rename, keeping the file's mode; **a file that is not UTF-8 is refused, not
  opened**, because saving replacement characters back would destroy it.
- **(c) around it.** The Finder opens text in TextEdit (`Launcher.open`: a text
  extension, or no extension and UTF-8 with no NUL in the first 4 KB — tested),
  **before** the executable check for a text name, because a file off a FAT
  stick has every execute bit set and a `.txt` must not run; a configured
  opener still wins, being the person's choice. Closing a document with edits
  shows Jaguar's sheet — Save (Return), Don't Save (⌘D), Cancel (Escape) — and
  Quit asks each edited document in turn; Save on an untitled one goes through
  Save As and then closes.

`live-textedit.sh`, both platforms, every claim on the file's bytes: opened by
path; a click at a measured character, typing, ⌘↓, typing, ⌘S — exactly the
expected bytes; typing then ⌘Z ("Undo Typing") — saved again, unchanged; ⌘F
`needle`, Return, Escape, typing — the replacement on disk; ⌘O through the
portal and the Finder opens a second file; an untitled ⌘S is Save As through the
Finder's save picker; the sheet's three answers; and a Finder double-click
opening a `.txt` in TextEdit. Goldens `textedit` and `textedit@2x`.

**P15.6 — Grab (S–M).** A selection rectangle on a layer surface over every
output, a window picker (foreign-toplevel), and a save sheet, over the
screencopy `abyssgrab` already does. *Verified:* a region's pixels in the saved
file match the screen.
✅ **Done 2026-10-01.** Grab (`AQUA_SCENE=grab`, app_id `org.abyssbsd.grab`):
Jaguar's Capture menu — Selection ⇧⌘A (a rubber band on an OVERLAY layer
surface, its size shown), Window ⇧⌘W (the window under the pointer tinted, a
click takes it), Screen ⌘Z, Timed Screen ⇧⌘Z (ten seconds) — each picture in a
window of its own, Save… through the portal's save picker as a PNG, Copy as
`image/png`; a small main window with the four as buttons, because the bar shows
a frontmost window's menus. **The overlay is never in the picture:** it is
closed, and the compositor given a round trip, before the screen is copied.
What it took below Grab:

- **`window_at`** — `abyss_window_manager_v1` v2: foreign-toplevel names windows
  but does not place them, so Window mode asks undertow which window is
  topmost at a point and gets its box, **the frame undertow draws included**
  (a whole window, title bar and all, as Jaguar's took), plus its app_id and
  title. Not privileged: geometry is less than screencopy already gives any
  client. Surface: `Display.windowAt` (one shared listener; Grab asks on every
  motion).
- **Exclusive keyboard for layer surfaces** — undertow honoured
  `keyboard_interactivity` only on a click; an `exclusive` surface on the top
  or overlay layer now gets the keyboard as it maps and hands it back as it
  unmaps (the protocol's rule; a lock screen will need it too). Grab's Escape.
- **A crash only FreeBSD showed** — HANDOFF §2.99: every Surface type left its
  pending frame callback alive when closed, with an unretained `self` as its
  data; Grab's overlay, closed between a commit and its `done`, died with SIGBUS.
  All three now cancel it (and stop leaking a callback proxy per frame).
- **The pointer is in the picture** where it is drawn in software (the build
  VM): wlroots' screencopy can leave out only a hardware cursor. Said in Grab's
  header and asserted honestly below.
- `abyssgrab --convert` (PNG → PPM) and `--diff` (where two PPMs differ), so a
  shell test compares pictures with no image library.

`live-grab.sh`, both platforms, on a still scene (the wallpaper and System
Preferences): a selection across a window's edge, saved through the portal and
the Finder's save picker, **equal to the same region of a screencopy but for
the pointer** where the drag ended (2 pixels, inside its box); a click captures
System Preferences' exact box as undertow reports it, equal likewise (the
pointer's 18×22); Screen is 1024×768; Escape cancels; Timed captures after its
countdown. Goldens `grab` and `grab@2x`. Known limits: one output (the first, at
the layout's origin); Grab's own windows are in a Screen capture.

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
**Decided (user, 2026-09-30): (a).**

**6.2 Where bundles go.** `/Applications` is root's; a session cannot write it
until the `pkg` hook exists. **Recommendation:** the generator writes
`/Applications` when run as root (the medium's build, Phase 17's hook) and
`~/Applications` when run by the session; the Finder and Dock read both.
**Decided (user, 2026-09-30): as recommended.**

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
the browser is installed on first use. Measured in P15.3. **Decided (user, 2026-09-30): on the medium** (P15.3b).

**6.6 One foreign toolkit: GTK.** Found during P15.3: the build guest carried
Qt 6 and KDE Frameworks (kcalc, for P10.7's menus and P15.1's real port) beside
the GTK that Firefox brings. **Decided (user, 2026-09-30): GTK or Qt, not both
— and it is GTK**, since Firefox is GTK-only on FreeBSD and `qt6-base` requires
`gtk3` anyway. Removed: `org_kde_kwin_appmenu` in undertow (focus kind 3
retired, never reused), the `com.canonical.dbusmenu` half of `abyss-dbus` with
its registrar, `QtMenus` and its tests, `live-menus-qt.sh`, and kcalc,
`qt6-wayland` and 43 orphaned Qt/KDE packages from the guest (the seed installs
`galculator`, `firefox-esr` and `ffmpeg` instead). `live-appgen`'s real port is
galculator: `Galculator.app` with a 256 px icon from its hicolor SVG, mapping
its window. The medium never carried Qt. Verified: unit tests (684), goldens,
and the GTK menu, submenu, context, portal, session, palette, appgen, Firefox
and Dock tests, green on Linux and in the guest.
