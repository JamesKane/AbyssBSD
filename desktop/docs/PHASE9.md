# Phase 9 — the interaction substrate (scope)

The first phase after [PRODUCT.md](PRODUCT.md), and the one that stops the
desktop making claims it cannot keep. Read [PLAN.md](PLAN.md) for the dependency
order and the locked decisions, [PHASE6.md](PHASE6.md) for the compositor this
extends and the frame contract it must not disturb, and
[HANDOFF.md](HANDOFF.md) for the interop traps — §2.1 and §2.3 are load-bearing
here for the third time.

Last updated: 2026-09-05. **Scoped. Four risks were spiked first, on both
platforms, before any of this was written — and one of them changed the phase's
shape** (§4.1): the clipboard is not missing for *our* applications, it is broken
for *everyone*, including the foreign GTK apps Phase 8 exists to serve.

---

## 1. What this phase is

Everything since Phase 1 has been additive: a toolkit, a shell, a control plane,
portals, a compositor, an installer. This phase is the opposite. It is a list of
things the desktop already appears to offer and does not.

> The menu bar's Edit menu lists **Undo, Redo, Cut, Copy, Paste, Select All**
> (`de/aqua/MenuBar.swift`). None of them does anything. No Aqua window can be
> moved with the mouse. `request_resize` reaches the compositor and is dropped on
> the floor. A GTK application on a Jaguar desktop wears a GNOME headerbar.
> Pressing a key combination the whole world agrees on — Cmd-Tab, Cmd-Q, Cmd-Space
> — reaches nothing, because `undertow` has no hotkey table at all.

The claim this phase has to make:

> Every gesture the desktop *depicts* actually works: copy in one process and
> paste in another (ours or theirs), drag a file onto the Trash, move and resize
> and zoom a window, press a global key, and see every window — foreign ones
> included — wearing the same frame.

**None of it is research.** The whole phase is small pieces of protocol that
other compositors have had for years, and its difficulty is entirely in the
count. What makes it Phase 9 rather than a cleanup is fan-out: [PLAN.md](PLAN.md)
puts five later phases behind it, and every application in Phase 15 assumes all
of it exists.

### What is genuinely different about this phase

**It is the first phase whose work is mostly on the *client* side of protocols
the compositor already speaks.** Phases 6–8 built server halves; here the missing
half is usually `Surface`'s. That inverts the usual debugging shape: when a copy
does not arrive, the compositor is not the suspect.

**And it is the first phase where `undertow` needs to draw something that is not
a client's buffer.** Server-side decorations mean the compositor paints Aqua
chrome, which is a dependency it has never had and an open decision (§6.1).

---

## 2. What we already have vs. what's new

| Need | Have | New in Phase 9 |
|---|---|---|
| A selection arbiter | `wlr_data_device_manager_create` — the global, and **nothing that answers it** (§4.1) | `request_set_selection` → `wlr_seat_set_selection`, and the same for drag |
| A client-side clipboard | **nothing.** `Surface` never binds `wl_data_device_manager` | `wl_data_device`, `wl_data_source`, `wl_data_offer` + the pipe I/O |
| Something to copy | `FinderApp.clipboard` — a `(path, cut)` field, **process-local** (§4.2) | the same clipboard, published as `text/uri-list` |
| Interactive move | `request_move` handled (P6.x) — and **no client here ever sends it** (§4.2) | the title-bar drag, in `Aqua`, for every Aqua window |
| Interactive resize | `request_resize` **unhandled** | handled, plus resize edges on the frame and edge snapping |
| Zoom / minimize / fullscreen | **no handlers, and no client requests either** | both halves, and the Dock's minimize target |
| Global key bindings | **none.** `Seat` forwards every key to the focused client | a `PoolConfig`-backed table, matched by a pure function |
| Decorations for foreign windows | **none** — no `xdg-decoration` global | the protocol, always SERVER_SIDE, painted by `Draw` |
| X11 applications | **none**, and no decision on record | the decision, with a measured cost (§4.4) |

---

## 3. Ordered passes

The order is the dependency order inside the phase: the selection before the
things that travel on it, the client half of a window request before the server
half that answers it, and the keybind table before anything that would want a
key.

**P9.1 — the selection, both ends. ✅ done, and it found the protocol's own
guard.**
The pass that turns out to be a repair rather than a feature (§4.1). Two halves,
and the server one is four lines:

- **Server.** Listen to `wlr_seat.events.request_set_selection` and call
  `wlr_seat_set_selection`. wlroots' own header says the compositor must, and
  `undertow` never has, so **today a client's copy is discarded no matter who the
  client is.** The same shape for `request_start_drag` in P9.3.
- **Client.** `Surface` binds `wl_data_device_manager`, gets a `wl_data_device`
  for the seat, and implements both directions: a `wl_data_source` with `offer`
  for each MIME type and a `send` handler that writes to the descriptor the
  compositor hands over, and a `wl_data_offer` whose `receive` reads the other
  end of a pipe we create. `wl_data_device` is **core wayland**, so there is no
  new XML and no scanner line — but its requests are static inlines, so it is
  `aw_*` wrappers as usual (§2.1) and **every listener slot filled** (§2.3):
  `data_offer`, `enter`, `leave`, `motion`, `drop`, `selection`.

**The trap this pass is designed around (§2.37): a clipboard test with no
positive control asserts nothing.** "Paste produced no error" passes on a system
where nothing was ever copied. Every test here asserts on the **bytes that came
back through the pipe**, and the negative case — paste with an empty selection —
is exercised so we know the check can fail.

**What P9.1 landed, and the thing it discovered:**

- **Server:** `undertow` answers `request_set_selection` and calls
  `wlr_seat_set_selection`. Four lines, and until now the global was published
  with nothing behind it — so a copy was discarded for *every* client, ours and
  the foreign GTK applications Phase 8 exists to serve.
- **Client:** `Surface.Clipboard` — `wl_data_device`, a source that answers
  `send` by writing into the descriptor and **closing it** (a source that writes
  and does not close is a paste that hangs), and a reader that makes a pipe,
  flushes, closes its own write end, and reads to EOF. Every listener slot
  filled, including the four drag events that fire whether or not P9.3 exists.
- `abyssclip copy|paste`, on `abyssgrab`'s pattern.

> **The finding: a client may only take the clipboard using a serial from an
> input event it received.** wlroots checks it and says so —
> *"Rejecting set_selection request, serial 0 was never given to client"* — and
> that is the protocol stopping a background process quietly owning your
> selection. It is a security property, not an obstacle.

`abyssclip` has no surface, so it receives no input, so it has no serial and
**cannot legitimately copy**. That is why `wl-clipboard` and every other
clipboard CLI uses `wlr-data-control`: a protocol whose entire purpose is
clipboard access without a surface. §6.7 records that decision rather than
making it here.

So `live-clipboard.sh` pins what is real today — an empty clipboard reads empty
rather than stale, and a copy with no input behind it is refused *by name*, which
also proves the compositor is now receiving and judging these requests instead of
ignoring them. **The round trip belongs to P9.2**, where the Finder copies from a
⌘C that has a serial because a person pressed it.

**P9.2 — the Finder's clipboard gets a wire. ✅ done, and it found two defects
older than this phase.**
`FinderApp.clipboard` already exists and already backs ⌘C/⌘X/⌘V; it is a field on
the application object, so it works between Finder windows and reaches nothing
else (§4.2). This pass gives it a wire rather than replacing it: the copy
publishes a `wl_data_source` offering `text/uri-list` (the `file://` URI) and
`text/plain` (the path), the paste reads the current selection instead of the
field, and the field becomes a cache of what we ourselves put on the seat.

The observable win is the one the phase exists for: **copy a file in the Finder,
paste it in a GTK application, and back** — which is `live-gtk.sh`'s existing
shape (§2.39: the other end is never ours) pointed at a new protocol.

Cut keeps its current semantics — the move happens on paste, not on cut — because
that is what the Finder already does and what a user expects from a file manager
rather than a text field.

**What P9.2 landed, and the three things that had to be true first:**

- `setClipboard` publishes a `text/uri-list` (`file://…`) and `text/plain`, with
  the serial of the ⌘C that caused it. `clipboardPath()` reads the seat and falls
  back to the cache; the field survives only because **`cut` has no
  representation on the wire** — the selection carries a path, and whether the
  person meant *move* is ours to remember.
- **The keyboard serial was being discarded.** `wl_keyboard.key` carries one and
  `Display` ignored it, so every keyboard-driven copy would have quoted a stale
  pointer serial, or none at all on a desktop nobody had clicked.
- **`undertow` gave keyboard focus only on click.** Until somebody clicked, every
  application was deaf — on the live medium, an installer you cannot type into
  until you have clicked it. No test had caught it because every harness mode
  that uses a keyboard drives a pointer first. Mapping now focuses.
- **And focus recorded before a keyboard existed was never delivered.**
  `Seat.focus` returned early with a comment saying the client would be told when
  one arrived; nothing told it. With focus-on-map that became *every* window on a
  machine whose keyboard is a virtual device created afterwards.

> **Then `fileops` hung**, and the reason is the one every clipboard
> implementation meets: **a client must never read a selection it owns.** A
> selection is a promise to write into a descriptor when asked, so reading your
> own means asking yourself, from the thread about to block on the read, for a
> `send` only the event loop you just stopped servicing can deliver. Copy and
> paste in one window — the first thing anybody does — deadlocks.
>
> `Clipboard.ownsSelection` answers from the cache instead. Worth noting the
> coverage: `live-clipboard.sh` uses two processes throughout and **cannot** find
> this; `fileops` did.

The reading half has a limit worth stating: `wl_data_device.selection` is
delivered only to the client with keyboard focus, so a surfaceless tool cannot
read the clipboard any more than it can write one. That is the same guard from
both sides, and it is why §6.7's decision covers both directions.

**P9.3 — drag and drop.**
The same protocol, one more grab. Server: `request_start_drag` →
`wlr_seat_start_drag`, and the drag icon becomes a surface in the scene, which
the SoA scene already draws with an arbitrary `dst_box` and will shortly draw
with an alpha (Phase 13 needs the same array). Client: `start_drag` from a
pointer press with the right serial, and the offer side's
`accept`/`set_actions`/`finish`.

Three targets, because they are the three the shell already draws: the Trash (a
Dock tile that already knows how to receive a file), a Finder window (which
already knows how to copy into its own directory — `finderCopyPath` and
`finderPasteName` are written and tested), and a Dock tile (open this document
with that application).

**What P9.3 landed, and the three things that were broken underneath it:**

- **Server:** `request_start_drag` → `wlr_seat_validate_pointer_grab_serial` →
  `wlr_seat_start_pointer_drag`, the drag icon tracked as a surface and drawn
  under the cursor, and `drags-started=` reported as it happens — the positive
  control, because a drop that did nothing and a drag the compositor refused to
  start look identical from outside.
- **Client:** the four data-device drag slots filled for real — `enter` accepts a
  MIME (which is what makes the *source's* cursor say yes, so it must happen on
  enter and not on drop) and asks for COPY; `drop` receives, reads to EOF,
  `finish`es and destroys. `Clipboard.dragSurface` records which of our surfaces
  the drag is over, because a drop arrives on the **seat** and a drag is a grab —
  the last pointer event a multi-window client saw is from before the drag began,
  and names the window the file came *out* of.
- **One parser for what a drop contains, and one encoder for what we hand out.**
  `text/uri-list` is CRLF-separated with `#` comments and percent-encoded URIs;
  taking the bytes as a path mangles any name with a space in it, and handing out
  a raw path makes one entry look like two to anything that follows the RFC.
  `finderDroppedPath` and `finderFileURI` are pure, unit-tested as a round trip
  and separately for the refusals (a remote `file://host/…`, a malformed escape).
  Adding the encoder immediately broke ⌘V — the paste side was still stripping
  `file://` by hand — which is the argument for one parser rather than three:
  P9.2's test caught it in the same minute.
- **Three targets, all asserted on disk:** the Trash (a Dock tile in another
  process — the file is in `~/.Trash` and gone from where it was), another window
  of the *same* Finder (the case that discriminates: "the first window" is also
  the right answer whenever a process has one), and the Finder tile (a folder
  dropped on it opens in a new window).

> Three things had to be fixed to make any of that reach the screen, and all
> three had been broken since long before this pass — §2.55, §2.56, §2.57:
>
> - **A drag that ends where it started deadlocks** the same way reading your own
>   selection does, and drag-between-my-own-windows is a far more ordinary thing
>   to do than copy-and-paste-in-one-window.
> - **undertow never hit-tested layer surfaces**, so under our own compositor the
>   Dock, the menu bar and the desktop could not be clicked at all. Every test
>   that clicks the Dock runs on sway.
> - **`wl_proxy_destroy` sends no request**, so every window this project has
>   ever closed leaked a mapped, hit-testable surface in the compositor and left
>   a rectangle of dead screen behind it.
>
> The last two are the same lesson twice: the shell's own surfaces had no test
> that ran against the shell's own compositor.

`abyss/tests/live-dnd.sh` is the whole of it — undertow, a Dock, a Finder, and a
virtual pointer that presses, moves and releases.

**P9.4 — the window requests we ignore, and the ones we never send.**
The client half first, because there is not one. `Surface.Window` sends exactly
two toplevel requests today, `set_title` and `set_app_id`, which is why **no Aqua
window in this tree can be dragged by its title bar** — the only client that has
ever issued `xdg_toplevel.move` is `abyss/tests/adversary.c` in its `move` mode,
written to test the compositor's half (§4.2).

- **Client:** `aw_*` wrappers for `move`, `resize`, `set_maximized` /
  `unset_maximized`, `set_minimized`, `set_fullscreen` / `unset_fullscreen`; and
  in `Aqua`, a title-bar drag that issues `move`, a resize edge that issues
  `resize` with the right `xdg_toplevel_resize_edge`, and the **zoom and minimize
  traffic lights wired to something** — today only the red one is (`Finder.swift`
  handles `close`).
- **Server:** `request_resize` (with the edge, so the anchored corner stays put),
  `request_maximize` (to `usableArea`, not the output — the menu bar's exclusive
  zone is already computed and this is the first thing that consumes it),
  `request_minimize`, `request_fullscreen` (to the output, ignoring the zone).
- **Snapping:** drag to an edge, get a half. The one tiling affordance worth
  offering (PLAN §"What is deliberately not on this roadmap"), and it is a pure
  function from a cursor position and an output rectangle to a target rectangle —
  which is where its test goes, not in a live run.

Minimize needs somewhere to go, and the Dock is it. The genie is a Phase 13
concern (it wants the same alpha and the same scaled `dst_box` Ebb wants); this
pass minimizes to the tile without an animation and says so.

**What P9.4 landed, and the tile that was never there:**

- **Client:** `aw_*` wrappers for `move`, `resize`, `set_maximized`/`unset`,
  `set_minimized`, `set_fullscreen`/`unset`, and — the half that is easy to
  forget — the **states on a configure**. `Surface.Window` had been discarding
  them, so a window could be maximized and not know it: its zoom light then asks
  to maximize a second time and it never un-zooms. A configure is one atomic
  answer; applying the size and dropping the states is applying half of it.
- **Server:** `request_resize` (anchored: a resize from the left leaves the right
  edge exactly where it was, fixed up on the client's commit rather than guessed
  from the lagging size), `request_maximize` **to the usable area**, and
  `request_minimize` / `request_fullscreen`. The menu bar's exclusive zone has
  been computed since P6.4 and until now *nothing consumed it* — a maximized
  window sliding under the menu bar is what an unconsumed zone looks like.
- **One chrome rule for every window.** `windowChromeHit` is pure and shared, so
  the Finder and the demo scenes answer a press on the frame the same way.
  Resizing is the bottom edge and the two bottom corners only: 10.2 resized from
  the grip, *and* a side band would take the outer 6px of every scrollbar thumb
  in the Finder, whose scrollbar is the rightmost 15px of its window. The sway
  suite passed with side bands in — no test drags a thumb by its outer edge, and
  a person would have found it in a day.
- **Snapping** is `WindowSnap`: a pure function from a cursor and a rectangle to
  a rectangle, with its own unit tests, applied on release. The halves tile the
  usable area exactly (a one-pixel gutter down the middle of the screen is the
  kind of thing nobody reports and everybody sees) and the top corners maximize
  rather than halve, because both readings are defensible and only one can
  happen.

> **The Dock had no tiles to minimize into.** undertow created the
> `wlr-foreign-toplevel-management` *manager* and never made a single handle, so
> under our own compositor the Dock listed no running applications, its tiles had
> no dots, and clicking one raised nothing. Every test that showed otherwise ran
> on sway — §2.56 again, one pass later and in the same place. Handles are made
> on map, carry title/app_id/activated/minimized/maximized, and answer
> activate/close/minimize/maximize; the window that focus moves to is now the one
> the shell is told about.

`abyss/tests/live-window.sh` is the pass: a menu bar (so the usable area is not
the output), a window, a Dock and a virtual pointer. It drags the title bar,
zooms and un-zooms, resizes from the corner, snaps to an edge, minimizes with the
yellow light and **brings the window back by clicking its Dock tile**. Every
claim is undertow's own geometry line — a Wayland client is never told where it
is, so the compositor is the only witness.

**P9.5 — the keybind table.**
`Seat`'s key handler forwards unconditionally to
`wlr_seat_keyboard_notify_key`. Interception goes in front of it:

- **The keysym.** `wlr_keyboard` carries an `xkb_state`, so
  `xkb_state_key_get_syms` on `keycode + 8` gives the symbol, and
  `wlr_keyboard_get_modifiers` gives the modifier mask. No new dependency —
  `de/cxkb` is already a target and the client side has used it since Phase 1.
- **The table** is `PoolConfig`-backed (`~/.config/abyss/keys.ini`), so it
  hot-reloads like everything else the shell reads, and the parse is pure.
- **The match is a pure function** — `KeyBindings.match(sym:modifiers:) -> Action?`
  — for the same reason `PointerRouting.hit` is: the rule that decides what a key
  does must not need a running desktop to verify (§2.9).
- **A bound key is consumed and never forwarded.** That is the whole contract,
  and it is also the trap: get it wrong in the other direction and an application
  can never see the combination itself. §6.2.

Defaults: Cmd-Tab (application switcher — the switcher UI is Phase 13's, the
binding and the raise are this pass's), Cmd-Q, Cmd-W, Cmd-Space, Cmd-Shift-3 and
Cmd-Shift-4 (`abyssgrab` already exists and the portal already forks it), and the
volume/brightness keys through `Vents`.

**This is the pass Phase 13 is blocked on**, so it is worth finishing rather than
half-finishing: an island switcher with no keyboard route is a toy.

**What P9.5 landed, and the state no window could see:**

- **The table** is `KeyBindings` — parse and match, both pure and unit-tested,
  for the same reason `PointerRouting.hit` and `WindowSnap.zone` are (§2.9).
  Modifiers must match *exactly* (Cmd-Q and Cmd-Shift-Q are different
  keystrokes), and the lock states are masked off, because a table that
  distinguished Caps Lock would disable every shortcut the moment somebody left
  it on.
- **Two symbols are tried, translated and raw.** With Shift held, a US layout
  turns the 3 key into `numbersign` — so a table written the way a person thinks
  ("Cmd, Shift and the 3 key") only works if the symbol printed on the key is
  tried as well as the one the layout produced.
- **A consumed press consumes its release.** Forwarding the release of a key
  whose press we swallowed hands the client half an event, which toolkits
  variously ignore, log, or treat as a stuck modifier.
- **Actions are compositor verbs or commands.** `next-window`,
  `previous-window`, `close-window`, `quit-app` — and `run: …`, which is how the
  volume keys reach `ventsctl` without the compositor taking a dependency on the
  hardware bridges, and how a person binds anything else. Not a shell: no
  quoting, no globbing, no `rm -rf $HOME` out of a config file the desktop reads
  at every keystroke.
- **The defaults are compiled in** and `~/.config/abyss/keys.ini` overrides them
  row by row, re-read when its timestamp moves — checked at most once a second
  and only on a keystroke, which is the only moment the answer can matter.

**§6.2 is decided: an application may keep a combination, and it says so in the
table.** `[passthrough] app_id = Cmd+Q Cmd+W`, with `*` for "this application
keeps everything" — the case a virtual machine window or a remote desktop needs.
Per-application, not a modifier that suppresses the table for one keystroke:
a terminal declares itself once, in data, where a person can read it; a
suppression modifier is a thing you have to know, and nothing on screen can tell
you it exists. Phase 15's terminal now has a supported answer rather than a
retrofit.

> **And no window could tell whether it had focus.** `Seat.focus` routed the
> keyboard and never called `wlr_xdg_toplevel_set_activated`, so every Aqua
> window in this tree has drawn itself as the active one since Phase 6 —
> including the five that were not. It surfaced here because Cmd-Tab's only
> observable effect *is* which window says it now has focus, so the test needed
> the thing that was missing (HANDOFF §2.59).

`abyss/tests/live-keys.sh` drives a real keyboard through undertow and checks all
four directions: an unbound key reaches the application (the control the rest
rests on), a bound one is answered *and* withheld, a kept one arrives with the
window still open, and Cmd-Tab moves focus to the other window — the raise
Phase 13 is blocked on.

**P9.6 — server-side decorations.**
`xdg-decoration-unstable-v1` is the only new protocol XML in the phase, and it is
present in `wayland-protocols` on both platforms (§4.3). The server side is
`wlr_xdg_decoration_manager_v1`, a listener on `new_toplevel_decoration`, and
`wlr_xdg_toplevel_decoration_v1_set_mode(..., SERVER_SIDE)` — we always answer
server-side, because a desktop with two window styles has failed at the one thing
this project is for.

The rest is drawing, and **that is the open decision** (§6.1): the frame is an
Aqua title bar with gel traffic lights and a pinstriped edge, which is
`de/aqua/Drawing.swift`'s vocabulary and cairo's. The recommendation is that
`undertow` renders each distinct frame size **once** into a cached texture and
never rasterises on the frame path — but "never" is a claim the C1 bench has to
check, not one this document gets to assert.

**Highest visual payoff in the gap map, by a distance.** A GTK headerbar on a
Jaguar desktop looks broken in a way no missing feature does, and one protocol's
work makes every foreign window Mac-shaped.

**What P9.6 landed, and §6.1 decided by moving code rather than arguing:**

- **`AquaDraw` is a target now.** `Rect`, `Theme`, `Draw`, `Text` and the window
  chrome they compose into — none of which ever depended on `Surface`, which is
  what made them separable — moved out of the toolkit so **the compositor can
  link them**. `Aqua` re-exports the module, so the extraction changed no call
  site in a toolkit that uses `Draw` and `Theme` unqualified everywhere. That is
  §6.1's first option taken: the alternatives were a rect-and-gradient renderer
  inside undertow, which cannot draw a gel traffic light and so fails the only
  test that matters, or writing Aqua twice and keeping two of them in step.
- **The frame is rasterised once per window** and cached against its size, title
  and focus, so a desktop nobody is resizing does no cairo work at all. §6.1
  asked for that to be measured rather than asserted, so undertow reports
  `frame-rasterisations=` as it happens and the live test asserts it is 1.
- **`FrameMetrics` is pure and shared** by placement, the hit-test, the move
  grab and the maximize rectangle. A frame whose geometry the input path
  computes differently from the paint path is a title bar you can see and cannot
  click, so there is one function and four callers.
- **The frame is a first-class pointer target.** `PointerTarget.frame` carries no
  surface, because no client owns those pixels — a press there is answered by the
  compositor and forwarded to nobody. Maximizing a decorated window fits the
  *frame* into the usable area, not the surface; otherwise the title bar goes off
  the top of the screen and takes every control with it.

> **Two things this pass had to find out the hard way.** `set_mode` schedules a
> configure, and scheduling one before the client's initial commit is an
> assertion failure *inside wlroots* — `surface->initialized` — which takes the
> compositor down with the ordinary ordering, where a client asks for
> decorations while setting the window up. The answer is deferred to the initial
> configure it belongs in.
>
> And **the obvious test client cannot play the part**: GTK draws its own
> decorations on Wayland whatever the compositor offers and does not implement
> this protocol at all, `GTK_CSD=0` included. So the client that asks is a new
> `decorated` mode of `adversary.c`, which is otherwise P6.5's hostile-client
> harness.

`abyss/tests/live-decorations.sh` runs that client against undertow and asserts
the compositor took the decoration, rasterised exactly one frame for it, and that
the yellow light **where the frame was painted** puts the window away — which is
the claim a screenshot cannot make.

**What P9.7 landed: the decision, and a test that keeps it.**

**No XWayland.** §6.3 has the argument and the price; the short of it is that
nothing on this roadmap needs it — the browser this project adopts is
Wayland-native, and every application it writes is its own client — so what
XWayland would buy is the long tail of ports rather than anything we ship. An
X11-only port will not run on this desktop, and that is the cost of the decision
rather than an oversight in it.

One correction is recorded with it, because the wrong reason would have been
easy: **the cost is not the frame path.** wlroots starts XWayland lazily, so a
compositor built with it and no X client connected has no server process and
nothing in the present loop that knows it exists. What an X11 application loses
under XWayland, it loses under every compositor. The decision is about scope and
attack surface, not about frames.

And it is enforced rather than remembered: `live-session.sh` asserts that
`undertow` names none of wlroots' XWayland symbols, so wiring it in fails the
suite. The check is the **binary**, not the process table — looking for a running
`Xwayland` finds the dev box's own desktop session and fails on a machine that is
behaving perfectly, and would find nothing on a compositor that *does* have it
compiled in, since no X client connects during the test. The guard was broken on
purpose to confirm it fails (§2.37).

**P9.7 — the XWayland decision.**
Not a line of code until the decision is written down, which is the pass. §4.4
measured it: wlroots has XWayland compiled in on both platforms, `Xwayland` is in
ports, and the medium's incremental cost is **about 6 MiB** once you subtract
what `undertow`'s own closure already carries. So this is a policy question and
not a feasibility or a size one, and it should be decided the way the D-Bus
bridge was: take the thing we do not love, scope it to the legacy path, and say
so in writing. §6.3 is the recommendation and the argument.

---

## 4. The spikes — four, and one of them moved the phase

Read out of the tree and the two toolchains, not assumed.

### 4.1 Does the clipboard work today? — **No, and not for anybody.**

PRODUCT.md §4.2 said `undertow` creates `wlr_data_device_manager` "so *foreign*
apps can copy to each other". **That is wrong, and this spike is why the
selection is P9.1 rather than a mid-phase pass.**

`wlr_data_device_manager_create` publishes the global and nothing else. wlroots'
`wlr_seat.h` says it in the header, in a comment on the signal:

> `request_set_selection` — Called when an application _wants_ to set the
> selection (user copies some data). **Compositors should listen to this event and
> call `wlr_seat_set_selection()`** if they want to accept the client's request.

`undertow` listens to no such thing — `grep request_set_selection de/undertow`
returns nothing — so a client's `set_selection` is dropped, and **the clipboard
is broken under `undertow` for every client, ours and theirs alike.** It has
never been noticed because every live test that involves a GTK application runs
the *file chooser*, and no test in this tree has ever copied anything.

Two consequences. The obvious one: the server fix is four lines and comes first.
The instructive one: **this is a graceful degradation nobody can see** (§2.45) —
no error, no log line, no protocol violation, just a copy that goes nowhere. The
phase adds the assertion that would have caught it.

### 4.2 What does the Finder's ⌘C actually do? — **It works, in one process.**

The tree is further along than PRODUCT.md's "no Aqua app in this tree can copy or
paste" and further behind than it looks:

- `FinderApp.clipboard` is `(path: String, cut: Bool)?` — a field
  (`de/aqua/Finder.swift`), documented as "shared by every window (copy in one,
  paste in another — which is the point of having several open)". It is shared by
  every window **of that process**. Copy in the Finder and paste in a second
  Finder *process*, or in `AquaDemo`, or in a GTK app, and nothing happens.
- `finderCopyName`, `finderPasteName`, `finderCopyPath` are written and unit
  tested. The file-operation half of paste is done.
- The menu bar's Edit menu lists Cut/Copy/Paste and is wired to nothing at all.

So P9.2 is "give the existing clipboard a wire", not "write a clipboard" — a
materially smaller pass, and a better-shaped one, because the semantics are
already settled and tested.

The same spike found the matching hole one layer up: **`Surface.Window` sends
only `set_title` and `set_app_id`.** There is no `aw_xdg_toplevel_move` in
`de/cwayland/include/cwayland.h`, and the only client in the repo that has ever
issued `xdg_toplevel.move` is `abyss/tests/adversary.c`, written in Phase 6 to
prove the compositor's half worked. **The compositor can move a window; no
application here can ask it to.**

### 4.3 Is everything this phase needs in wlroots 0.19? — **Yes, on both platforms.**

Checked against the headers actually installed, on Linux (`wlroots-0.19`) and in
the FreeBSD build VM (`wlroots019-0.19.3`):

| Need | Header / symbol | Linux | FreeBSD |
|---|---|---|---|
| Selection arbitration | `wlr_seat.events.request_set_selection`, `wlr_seat_set_selection` | ✅ | ✅ |
| Drag | `request_start_drag`, `wlr_seat_start_drag`, `wlr_drag_create` | ✅ | ✅ |
| Resize / zoom / minimize / fullscreen | `wlr_xdg_toplevel.events.request_{resize,maximize,minimize,fullscreen}` | ✅ | ✅ |
| Decorations | `wlr_xdg_decoration_v1.h`, `wlr_xdg_toplevel_decoration_v1_set_mode` | ✅ | ✅ |
| Keysyms in the compositor | `wlr_keyboard.xkb_state`, `wlr_keyboard_get_modifiers` | ✅ | ✅ |
| The one new protocol XML | `wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml` | ✅ | ✅ |

**One new XML, one scanner line, and no new library on either platform.** Client
`wl_data_device` needs no XML at all — it is core wayland, already in
`wayland-client-protocol.h` as static inlines.

Also noted for later phases, since the same check answered it: `wlr_session_lock_v1.h`,
`wlr_idle_notify_v1.h` and `wlr_output_management_v1.h` are present on both, so
Phases 14 and 16 do not have a wlroots problem either.

### 4.4 What does XWayland actually cost? — **About 6 MiB, measured.**

The question that has been open since PHASE3 §6.1 and was never given a number.

- **wlroots is built with it, on both platforms:** `WLR_HAS_XWAYLAND 1` in
  `wlr/config.h` on Linux and in the FreeBSD VM. Nothing has to be rebuilt.
- **The server exists in ports:** `/usr/local/bin/Xwayland`, `xwayland-24.1.13`.
- **The package closure is 66 MiB, and that number is misleading.** Resolving
  `xwayland`'s dependencies against the packages `undertow`'s own `ldd` closure
  already pulls in (mesa-libs, libglvnd, libdrm, pixman, wayland, libxcb and
  friends — 7 of the 17 shared), what XWayland *adds* is:

  | Package | Size |
  |---|---|
  | xkeyboard-config | 10.2 MiB — **already on the medium** for libxkbcommon |
  | libepoxy | 2.7 MiB |
  | xwayland | 2.2 MiB |
  | libXfont2, libei, libdecor, xkbcomp, libxkbfile, libxcvt, libxshmfence | 1.7 MiB together |
  | **Total** | **16.9 MiB gross, ≈6.7 MiB net of what the medium already carries** |

So the medium grows by about six megabytes on a three-gigabyte image. **Cost is
not the argument against XWayland, and pretending it is would be dishonest.**
§6.3 argues it on the merits instead.

---

## 5. Verification

Unchanged where it can be: `abyss/tests/run.sh --vm --live` on both platforms,
unit tests for every pure function, and **nothing in this phase may make an
existing live mode depend on hardware.**

**Pure, tested with no compositor:**

- `KeyBindings.match(sym:modifiers:)` and the `keys.ini` parse — including that
  an unbound key returns nil, which is the case that decides whether an
  application can ever see Cmd-Q itself.
- Resize geometry: an edge plus a delta gives a rectangle whose anchored corner
  did not move. Eight edges, and the two-axis corners.
- Snap geometry: a cursor position and an output rectangle give a half, and the
  usable area's top is respected so a snapped window never hides under the menu
  bar.
- MIME negotiation: given the offers a source published and the types a target
  accepts, which one is chosen.

**Live, and asserting on the thing rather than the run (§2.43, §2.46):**

| Script | What it proves |
|---|---|
| `live-clipboard.sh` | two of our processes: copy in one, **read the bytes** in the other — and the empty-selection case returns nothing rather than succeeding vacuously (§2.37) |
| `live-clipboard-gtk.sh` | the same across the boundary, both directions, with `gtkpick` as the other end so it is never ours (§2.39) |
| `live-dnd.sh` | a real pointer drags a file from a Finder window onto the Trash tile, and the file is on disk in the Trash afterwards |
| `live-window-ops.sh` | resize by an edge, zoom to the usable area (**not** the output — the menu bar's strip is the assertion), minimize, restore, snap to a half |
| `live-keybind.sh` | a bound combination fires with no application focused; a bound combination is **not** delivered to the focused client; an unbound one is |
| `live-decorations.sh` | a stock GTK window under `undertow` reports server-side decorations and the captured frame has an Aqua title bar in it |

**Extending the harness the way `undertow` already does it:** the binary's
`--assert-*` family grows `--assert-selection`, `--assert-decorated` and
`--assert-consumed-keys`, so a live script's failure names the thing that failed
rather than a screenshot difference.

**And the C1 gate is unchanged and still gating.** P9.6 is the one pass that can
touch the frame path; if a decorated window costs measurable frame time, the
cache is wrong and the bench says so before the phase ends.

---

## 6. Risks / open decisions

**6.1 Where the frame is drawn, and what `undertow` links.**
Server-side decorations mean the compositor paints Aqua chrome, and `Draw`'s
vocabulary is cairo's. Three options:

- **`undertow` links `Aqua` and rasterises each frame size once into a cached
  texture.** Faithful, reuses the whole drawing grammar, and puts cairo in the
  compositor process. The frame path only samples the cache; the rasterise
  happens on resize.
- **A small rect-and-gradient frame renderer inside `undertow`**, using
  `wlr_render_pass_add_rect`. No cairo, no toolkit dependency — and it cannot
  draw a gel traffic light, so it fails the one test that matters.
- **A decoration helper process.** Clean, and a per-window round trip on the
  frame path, which is the thing this project does not do.

**Recommendation: the first**, with the cache measured rather than assumed. It
also sets up Phase 11 correctly: once the theme is data, the compositor and the
toolkit read the *same* tokens, and a re-skin reaches the window frames without a
second implementation. Deciding it the other way would mean writing Aqua twice
and having to keep two of them in step.

**6.2 A bound key is consumed, and that cuts both ways.**
The contract is that a bound combination never reaches the focused client. That
is correct for Cmd-Tab and wrong for an application that legitimately wants
Cmd-Q — a terminal, most of all, which is Phase 15's and will want a way to pass
combinations through. The mechanism to decide now, before there are applications:
either a per-application pass-through list in `keys.ini`, or a modifier that
suppresses the compositor's table for one keystroke. **Pick one and write it in
the table's format**, because retrofitting it after Phase 15 means changing every
application.

**6.3 XWayland — DECIDED: no. Not now, and not silently later.**
The recommendation in this document was to take it, scoped and off by default.
The decision went the other way, and the reasoning is worth keeping because the
question will come back.

*What was measured, and what it settled.* §4.4 priced it: wlroots is built with
`WLR_HAS_XWAYLAND` on both platforms, `Xwayland` is in ports, and the medium
grows by ≈6 MiB net. **Cost was never the argument, and neither is the frame
path** — wlroots starts XWayland *lazily*, so with no X11 client connected there
is no server process and nothing in the present loop knows it exists. The
performance an X11 application loses is lost by that application, under any
compositor. Saying otherwise would be an easier argument and a false one.

*What actually decided it.* Nothing on this roadmap needs it. PLAN.md's own note
is the load-bearing sentence: **the browser does not force it** — both GTK stacks
are Wayland-native and Chromium's FreeBSD port depends on `wayland` outright —
and every application this project writes is its own client. What XWayland buys
is the long tail of ports, which is thesis 5's promise and not thesis 5's
deliverable.

*What it costs, said plainly.* An X11-only port will not run on this desktop.
That is a real narrowing of "it just runs", and it is the price of the decision
rather than an oversight in it. Two smaller things come free with the no: an X
client cannot be given an Aqua frame the way P9.6 gives one to a Wayland client
(`wlr_xwayland_surface` is not an `xdg_toplevel`, so the decoration path would
need a second branch), and a session that contains no X server has no X server's
attack surface.

**What would flip it: a named application somebody actually wants that is
X11-only.** Not "the long tail" in the abstract — a name, in a phase that has
users. Phase 15 and 16 are where that would surface, and the work is bounded:
one global, one surface branch in the decoration path, one line in the medium.

**And the decision is a test, not a memory.** `live-session.sh` asserts the
running desktop has no X server in it and no `DISPLAY` in its environment, so
wiring XWayland in by accident fails the suite rather than passing unnoticed —
the same discipline as §2.56 and §2.58, applied to something we chose not to
have rather than something we forgot to finish.

**6.4 Primary selection is deliberately out.**
`zwp_primary_selection` (middle-click paste) is an X11 idiom and not a Mac one.
Not implementing it is a decision, not an oversight, and it is written here so
nobody re-litigates it in a later phase. `wlr_data_control_v1` /
`ext_data_control_v1` — the clipboard-manager protocols — are the same call and
the same answer: not until something asks for them.

**6.5 Undo belongs to Phase 10, and it is easy to lose.**
PLAN.md puts "decide undo before there are applications to retrofit" in the menu
protocol, because that is where a command gets a definition. The Edit menu that
this phase makes half-real still lists Undo and Redo, and after P9.2 they will be
the only two items in it that do nothing. **That is the right outcome for this
phase** and worth saying so, because the temptation to fix it here is exactly how
a toolkit-level decision gets made by accident in one application.

**6.7 A clipboard tool needs `wlr-data-control`, and that is a decision.**
P9.1 established that `wl_data_device.set_selection` requires an input serial, so
a surfaceless tool cannot copy — correctly. Every real clipboard CLI and every
clipboard manager therefore speaks `zwlr_data_control_manager_v1` (or its `ext-`
successor), which exists precisely to grant that access deliberately rather than
by accident.

wlroots ships both (`wlr_data_control_v1.h`, `wlr_ext_data_control_v1.h`), so the
compositor half is one call. The client half is a vendored XML, a scanner line
and a binding — the `wlr-screencopy` shape.

**The reason it is a decision and not a task:** it is a protocol that hands any
client that can bind it the whole clipboard, in both directions, with no serial
and no window. That is the right answer for a clipboard manager and a
deliberately wide door for anything else — so it wants the same treatment §5.2
gave XWayland: take it or refuse it, scope it, and write down which.

**6.6 This phase can quietly become Phase 15.**
Every pass here ends in something that would be nicer with one more application
in front of it — a text field that can paste, a terminal to test the keybind
pass-through, a second Aqua app to drag between. **The scope is the substrate,
not the users of it.** The check is `live-gtk.sh`'s: where a test needs a second
process, the second process should be somebody else's, so no application gets
written to make this phase's tests pass.
