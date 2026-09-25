# Phase 10 — the menu protocol (scope)

The phase that makes the menu bar true. Read [PLAN.md](PLAN.md) for the
dependency order (this phase is `Before` 15 and a hard edge into 18),
[PRODUCT.md §5.5](PRODUCT.md) for why what travels is a *vocabulary* rather than
a menu, [PHASE9.md](PHASE9.md) for the keybind table and §6.5's undo hand-off,
[PHASE8.md](PHASE8.md) for `abyss-dbus`, and [HANDOFF.md](HANDOFF.md) for the
traps — §2.39 and §2.40 are this phase's foreign half, and §2.58 is its whole
shape.

Last updated: 2026-09-25. **Scoped. Four risks were spiked first, on both
platforms, before any of this was written — and one of them moved work into the
compositor** (§4.2): a GTK application under `undertow` publishes its menus on
the bus and **tells nobody where they are**. The only thing that can learn the
address is the compositor, through a protocol GTK already speaks and we do not.
**§6.1, §6.3, §6.4 and §6.5 are decided** (2026-09-25), each as recommended.
**Phase 10 is COMPLETE (2026-09-25): all eight passes, and its gates green.**
`run.sh --live` on Linux and `run.sh --vm --live --full` on FreeBSD, with 466
unit tests each and 35 of 35 live modes each. The `--full` lane passed both
nested installs: the installer's own (193 s) and **empty disk to Jaguar
desktop** (428 s), in which an installed machine booted to wallpaper, menu bar
and Dock through the session P10.4 changed (the privileged socket, the bar on
it, and the `menus` bridge). That clears the `--full` P10.4 had owed.

---

## 1. What this phase is

> The menu bar draws **File, Edit, View, Go, Window, Help** for an application
> named "Finder" (`MenuBar.defaultMenus`, hard-coded). No process publishes a
> menu to it. Choosing an item logs its title and does nothing. The Finder's
> real commands — ⌘C, ⌘X, ⌘V, ⌘D, ⌘O, ⌘⇧N, ⌘⌫ — live in a `switch` inside
> `FinderWindow.commandKey`, and the menu bar has never heard of it. A GTK
> application draws its own menubar inside its own window, on a desktop whose
> whole premise is that it does not.

In Jaguar the global menu bar *is* the WIMP contract: every command an
application has is discoverable in one place, with a mouse, without memorising
anything, and it shows the key that does the same thing. **Thesis 2 is
undelivered until menus travel from applications to the bar** (PRODUCT.md §4.2).

The claim this phase has to make:

> The frontmost application's own commands are in the bar, enabled when they can
> run and disabled when they cannot, showing their key equivalents; choosing one
> does exactly what its key does; this is true of the Finder and of an
> unmodified GTK application; and a program that is not the menu bar can ask any
> of them *what can you do* and invoke a verb by name.

### What is genuinely different about this phase

**It is the first phase in which `undertow` implements a protocol wlroots does
not ship.** Every global the compositor has advertised so far came from a
`wlr_*_create` call (§4.3). This phase needs at least two it must write itself,
because the only party that knows *which surface belongs to which menu* is the
compositor.

**And the thing it publishes has two consumers from day one.** The bar is the
first; Phase 18's agent is the second, and the design points that serve it cost
nothing now and a second automation surface later (PLAN.md, Phase 10). This
phase's verify includes a consumer that is not the bar precisely so that the
vocabulary cannot quietly degrade into a drawing routine.

---

## 2. What we already have vs. what's new

| Need | Have | New in Phase 10 |
|---|---|---|
| A definition of a command | **two, unrelated:** the Finder's `commandKey` switch, and `defaultMenus`' strings | one `Command` value — verb, title, key equivalent, argument types, a sentence of description — that both the key handler and the menu are *derived* from |
| A menu that can say no | `AquaMenu` draws items as strings — **no disabled state, no key equivalents, no separators, no submenus** | all four, because a bar that cannot grey out Paste is lying about the clipboard |
| A channel from app to bar | `CurrentIPC` — request/response, flat fields, fds (§4.4) | a menu service: query the vocabulary, activate a verb and get a **result**, and be told when it changes |
| Knowing whose menu to show | `ForeignToplevels` — `app_id` and `activated`, both **self-declared** by the client | the compositor binds a menu address to a **surface** and tells the bar, and only the bar, which one is focused |
| GTK's menus | GTK **already exports** them — `org.gtk.Menus` + `org.gtk.Actions` (§4.1) | `gtk_shell1` in undertow, so GTK says where, and hides its own menubar; `abyss-dbus` translates |
| Qt's menus | `libQt6WaylandClient` binds `org_kde_kwin_appmenu_manager` (§4.2) | that global, a `com.canonical.AppMenu.Registrar` name, and a `dbusmenu` translation — **unmeasured** (§4.2) |
| Undo | Edit ▸ Undo and Redo, **drawn and inert** (PHASE9 §6.5) | the decision, in `Aqua`, and the Finder's file operations undoable through it |
| The Apple menu | ten items that log their titles | the ones something can already do (Log Out, Force Quit, About, System Preferences) |
| Contextual menus | the Trash tile's, only (`Dock.swift`) | the desktop, the Finder and every Dock tile, from the same `Command`s |

---

## 3. Ordered passes

The order is the dependency order inside the phase: the definition before the
things that carry it, our own application end to end before anybody else's, and
undo after there is a channel for Undo to be enabled through.

**P10.1 — one definition of a command. ✅ done.**
A `Command` in `Aqua` is a value: a **verb** (`file.duplicate` — stable, never
localised, what a script says), a **title** (`Duplicate` — what a person reads),
a **key equivalent** (`⌘D`), **argument types** and **a sentence of description**
(both for Phase 18; the Finder's verbs mostly take the selection, which is state,
not an argument), and a **validator** that says whether it can run *now*. A
`MenuModel` is titles, separators and submenus over `Command`s.

The Finder's `commandKey` switch is deleted and replaced by a lookup in its own
model: the key equivalent in the table *is* the key the handler answers. **That is
the whole point of the pass** — a command has one definition and two routes, and
a test proves it by walking the model and pressing every equivalent. The default
menu set stops being strings: the Finder's menus are the Finder's model.

`AquaMenu` learns disabled items, key equivalents drawn right-aligned in the
Jaguar style, separators and submenus. All pure where it can be (the layout that
feeds paint and hit-test, §2.9).

**What P10.1 landed.** `MenuModel` (`de/menumodel`) is a target that depends on
nothing — `Command`, `KeyEquivalent`, `Menu`, `MenuBarModel`, `Enablement`,
`CommandResult` — so P10.2's wire and `abyssmenu` can link it without linking an
application. The Finder's commands are `finderMenuBar()` over an exhaustive
`FinderVerb`; `FinderWindow.perform(_:)` switches over it with **no `default:`**,
so a verb added to the menus does not compile until the window says what it
does, and `validate(_:)` answers with a *reason* ("nothing is selected", "the
Trash is empty"). `commandKey` is now three lines: look the press up in the
model, perform the verb. The menu bar draws the same model — `defaultMenus`'
strings are gone — and `AquaMenu` draws disabled rows, separators, a key column
and a submenu arrow from one row layout for paint and hit-test. Things the
Finder cannot do yet (About, Get Info, Undo, as Columns, …) are **drawn
disabled, not left out**, and the system menu is entirely disabled until P10.8.

**What it found in the switch it replaced:**

- **Modifiers were ignored for every letter but N.** The old `commandKey` matched
  `case "c"` whether Shift was held or not, so ⇧⌘C copied, ⇧⌘D duplicated,
  ⇧⌘O opened. In Jaguar ⇧⌘C is *Go ▸ Computer*. Matching is exact now, as the
  compositor's table already was (P9.5).
- **An injected fault proved the walk test matters.** With Shift dropped from
  `keyEquivalent(keysym:modifiers:)`, the test that presses every key in the
  model failed — and named the dangerous case: ⇧⌘⌫ (Empty Trash) would have run
  ⌘⌫ (Move to Trash), and ⇧⌘N would have opened a window instead of a folder.
- **Up from nothing highlighted the second-to-last row** (`(start + d + n) % n`
  from `-1`). The step is `aquaMenuStep` now, pure and tested, and it skips
  separators and disabled rows the way Jaguar does.
- **Shifted punctuation cannot be a key equivalent yet.** On a US layout ⌘? is
  keysym `question` with Shift held, so a model that bound `.cmd("?")` would
  never match. The Help item carries no key rather than a key that does
  nothing; the fix is the compositor's two-symbol rule (P9.5), when something
  needs it.

**The live test changed with the behaviour.** `live-sway.sh --menubar --keys`
used to press Down and choose "About Finder". About is disabled now, so the test
asserts the *opposite* of what it used to — that Down skips it, that it was
never chosen, and that Return chose `Empty Trash… (finder.empty-trash)` **by
verb**. What the bar does with a choice is still only a log line; P10.4 routes
it.

**P10.2 — the menu service, and the consumer that is not the bar. ✅ done.**
The wire (`de/menuwire`, a target the way `InstallWire` is, so the bar links it
without linking an application). Three requests and one push:

- **`describe`** → the whole vocabulary: the menu tree, each verb's title, key,
  argument types, description and current enablement. *What can you do.*
- **`activate verb [args]`** → a **result**, not nothing: `ok`, `refused` with a
  reason (the validator said no between the bar drawing it and the click
  arriving), or a value (`file.new-folder` answers with the name it chose).
- **`validate`** → enablement only, cheap enough to ask when a menu opens.
- **`changed`** → pushed on a held connection when the vocabulary itself changes
  (a window closed; a document gained Undo). Enablement is *pulled* on open, as
  Jaguar does it, so a clipboard change does not fan out to every client.

Nesting: `Msg` is flat (§4.4), and a menu is a tree. A submenu travels as a
packed `Msg` in a `.bytes` field — nesting for free, one parser, and `maxFrame`
(1 MiB) is three orders of magnitude above a real menu bar.

The Finder serves it. So does a one-screen CLI, **`abyssmenu`**: `abyssmenu
describe SERVICE` prints the vocabulary; `abyssmenu run SERVICE VERB` invokes one
and prints the result. That is PLAN.md's non-bar consumer, and it exists in this
pass — before the bar is wired — so the first client of the vocabulary is
something that cannot draw it.

**What P10.2 landed.** `MenuWire` (`de/menuwire`, on `MenuModel` and
`CurrentIPC` only) carries the four methods; `MenuService` folds into an
application's run loop and does the checking no application should repeat —
the verb exists, the arguments are exactly the declared ones and parse as their
types, and the command is enabled — so a refusal arrives in the same words the
menu would have greyed out with. `MenuClient` resolves `finder` to a live
`menus.finder.<pid>` and skips sockets left by a crash. `abyssmenu` exits 0 on
`ok`, 1 on `refused` with the reason on stderr, and 2 when nothing answered —
a script can tell "no" from "nobody". The Finder serves as
`menus.finder.<pid>`; a command from outside goes to the window the compositor
last said was **activated** (P9.5's §2.59 fix is what makes that knowable),
else the newest, and `file.new-window` and `finder.empty-trash` work with no
window open at all, which on the desktop is the common case. Verbs now return
what they made: `file.new-folder` answers with the path.

**Go to Folder… (⇧⌘G) is the verb with an argument,** `path: path`, because
it is the Jaguar command whose whole content *is* an argument. From a script it
is complete; from the key or the menu it would open a sheet to type the path
into, there is no sheet, and it says so rather than doing nothing.

**What it found:**

- **A picker must not publish a vocabulary.** A Finder running as a portal's
  file chooser acts for the application that asked, and its only output is the
  file a *person* chose. Published, `abyssmenu run finder file.open` would choose
  for them — a confused deputy with a command line. `publishMenus` refuses when
  `FinderPicker.isPicking`; `live-vocabulary.sh` asserts the picker is absent
  from `list`, and **failed** with the guard removed.
- **There are two kinds of refusal, and the first draft of the test could not
  tell them apart.** The service refuses what is malformed or disabled, and the
  application is never called; the application refuses what is well-formed and
  impossible (`go.to-folder` on a file), which only it can know. The test
  asserted that no refusal reached the Finder's `perform` and failed on the
  second kind, correctly. It now asserts each kind separately.
- **`subscribe` has no customer yet.** The mechanism is in and tested (a push
  arrives; a subscriber that went away is dropped on the next push), but nothing
  in the Finder's vocabulary changes at runtime until P10.5 gives Undo a title
  that does. Stated so nobody assumes the bar is kept current by it.
- **A client that connects and says nothing stalls the application for up to
  two seconds** — `Current.Server.requestTimeout`, inherited, and the same for
  every service on the plane. For a notification centre that was harmless; for
  an application whose run loop draws frames it is not, and P10.4, which puts
  a round trip in front of every menu opening, is where it gets measured.

**Verified:** `run.sh --live` on Linux and `run.sh --vm --live` on FreeBSD, both
green — 438 unit tests each, 35 live modes, and `live-vocabulary.sh` (eight
refusals by reason, a folder checked on disk, a window checked by the Finder's
own log, a picker absent from the list). **Two runs, not one:** `--vm` runs the
suite only in the guest, and P10.1's commit claimed both platforms off a single
`--vm` run. That Linux gate had not been run; this one, which includes P10.1's
code, is it.

**P10.3 — the compositor learns whose menu is whose. ✅ done.**
Two protocols of our own, in `protocols/`, server-side in undertow (§4.3):

- **`abyss_menu_v1`** — any client: `set_address(wl_surface, service)`. Our
  applications call it when a window maps. It is our `org_kde_kwin_appmenu`, and
  it is the same shape on purpose: the menu is bound to a **surface**, by the
  process that owns the surface, on the connection that proves it.
- **`abyss_menubar_v1`** — **the bar only**: `focused(kind, address, app_id)`
  whenever the keyboard focus moves to a toplevel, where `kind` is `abyss`,
  `gtk` or `dbusmenu`. Ordered on the same connection as the foreign-toplevel
  events, so the bar never draws one application's menus under another's name.

"The bar only" is decided (§6.1): the global is offered only on undertow's
privileged socket. A global that tells any client which
application is focused and where its menus live is a keylogger's index.

**What P10.3 landed.** `protocols/abyss-menu-v1.xml` — both interfaces, with
`set_address` on the manager itself rather than a per-surface object, since an
address is one string and is forgotten with its surface. undertow implements it
(`de/undertow/Menus.swift` for the policy, `de/cwlroots/menus.c` for the
plumbing) and grows `--privileged-socket NAME`, announced as
`WAYLAND_PRIVILEGED=` beside `WAYLAND_DISPLAY=`. A client reaches it with
nothing but `WAYLAND_DISPLAY=<name>`. `Surface` gains `Window.publishMenus(at:)`
and `MenuBarFocus`; every Finder window publishes `menus.finder.<pid>`; the menu
bar binds `MenuBarFocus` and, for now, logs what it is told — drawing it is
P10.4, and so is threading the privileged socket through `abyss-session` and
`anchor` to the real bar.

**Three pieces of it are C, and why is worth one line each.** The generated
`abyss_menubar_v1_send_focused` is a `static inline` over the *variadic*
`wl_resource_post_event` — §2.1 from the server side. Knowing which socket a
client came through means accepting it ourselves and calling `wl_client_create`,
because libwayland does not record it for sockets it accepted. And the
interface tables live in a target of their own, `CAbyssProtocols`, because a
client copy and a server copy would be one symbol twice in every `swift test`
binary, which links both halves.

**What it found:**

- **Closing the focused window left focus on nothing.** `Seat.focused` is
  `weak`, so when the window went the reference went quietly nil: no other
  window was activated and the keyboard went nowhere until a click. P9.4 fixed
  exactly this for *minimize* and the close path had the same hole. The bar is
  the first thing that has to be told who is frontmost after a close, so it is
  what noticed. `forget` now focuses the topmost window, and
  `live-menu-focus.sh` **failed** with that line removed.
- **The C state has to be per display.** `UndertowTests` builds several
  compositors in one process; module-level statics would have given the second
  one no menu globals and every later test a compositor that silently lacked
  them. `tw_menus` is allocated per display, and its teardown detaches every
  resource and client entry that may outlive it. `Compositor.deinit` calls it
  explicitly, while the `wl_display` is certainly alive — left to Swift's
  release order it would have been a use-after-free waiting for a slow day.
- **A wait that the past can satisfy is not a wait.** The live test's last step
  waited for "frontmost: nothing" — which the bar had already logged once, on
  bind — and so checked the count before the new event had arrived. The
  compositor was right and the test failed; it now waits for a *second*
  occurrence. The same shape as §2.37, in a harness: polling for a line proves
  nothing if the line was there before you started.

**What the privileged socket does and does not protect, stated plainly.** It is
0600 in a 0700 directory, so any process of the same user can connect to it —
which that user's unconfined processes could anyway, since they can read each
other's memory. What it keeps out is a **confined** client (Phase 17), which is
handed the ordinary socket or a security context and never this one. That is
the real threat model, and it arrives with Phase 17; until then the global is
hidden from the wrong connection rather than from the wrong person.

**Verified:** `live-menu-focus.sh` — a bar on the ordinary socket is told
nothing (the control), the same binary on the privileged one is told on bind;
the Finder's address and app_id reach the bar when it is focused; an app with
no menus says so; closing it hands focus back to the Finder; closing the Finder
leaves nothing frontmost; the socket is 0600. Both of its fault injections
(the global filter disabled, the close fix removed) failed it. Unit tests: two
compositors each get their own globals; the socket is 0600 and removed with its
compositor; an impossible path is an error that names it.

**P10.4 — the bar is real. ✅ done.**
`MenuBar` binds `abyss_menubar_v1`, connects to the focused application's
service, `describe`s it, and draws *that*. The system menu stays the bar's own;
everything to its right belongs to the application, with its name bold. Opening
a menu `validate`s it; choosing an item `activate`s it and logs the **result**,
not the title. When nothing is focused — the desktop was clicked — the Finder is
frontmost, as it was in Jaguar, because the desktop *is* the Finder's process.

**What P10.4 landed.** The bar follows `MenuBarFocus`: on every focus event it
`describe`s the frontmost application (about 2 ms), subscribes to its changes,
and draws *its* menus; opening a menu `validate`s it (**777–853 µs measured**,
so the §6.4 round trip is about 5% of a 16.7 ms frame and the menu opens on the
next one); choosing an item `activate`s it and logs the result the application
returned. A window whose menus the bar cannot read still shows its name,
bold. With no window focused undertow reports the address the **desktop's**
background surface published, which is the desktop-hosted Finder's — Jaguar's
rule ("the desktop is the Finder"), through the compositor rather than a
special case in the bar. `anchor --menubar-display` hands the bar, and only the
bar, the privileged socket, and `abyss-session` and `live-session-gtk.sh` use
it. Under a compositor with no view of focus (sway, in `live-sway.sh`) the bar
keeps its P10.1 behaviour: the Finder's definition, static enablement.

**What it found — the pass was mostly this:**

- **undertow had never drawn, hit-tested or paced an `xdg_popup`** (HANDOFF
  §2.62). wlroots speaks the protocol and configures popups itself, so every
  menu in this tree *mapped* under our compositor and was then invisible and
  unclickable — the bar's dropdowns, the Dock's Trash menu, pop-up buttons.
  Every test that opened one ran on sway. `Popups.swift` gives them an
  unconstrained box, a position (a pure, tested function of the parent's window
  geometry), the top of the paint order and the hit-test, and frame callbacks.
  *The first draft said the missing piece was the initial configure. Removing
  that call changed nothing — wlroots sends it — so the claim was withdrawn;
  removing the hit-test is what breaks the menus, and removing them from the
  scene is what fails the pixel check.*
- **undertow ignored `keyboard_interactivity`** (§2.63). Only windows ever got
  the keyboard, so under our compositor the bar's arrow keys went to the window
  behind the menu. Now a click on an `on_demand` layer hands it the keyboard
  *without* changing who is frontmost, and the keyboard goes back to the active
  window when the last menu closes — after 100 ms, because walking the bar with
  ← → closes one menu and opens the next with a moment of no popups between
  them. An idle callback was tried first and lost that race.
- **`Display.run` crashed when a handler registered a descriptor from inside a
  Wayland event** (§2.64). The poll set was built from `extraFds`, the Wayland
  events were dispatched, and *then* the list was snapshotted to match against
  the poll results — one entry longer if the dispatch had added one. The bar
  subscribing to an application on a focus event was the first thing ever to
  do that. The snapshot is taken where the set is polled.
- **The key column drew as empty boxes on a box without DejaVu.** Noto Sans has
  no ⌘ ⇧ ⌫; the fallback list named DejaVu and Noto Symbols, neither installed
  on the dev box. Adwaita Sans joins the list, and — §2.45 — `Text.announce`
  now says `NO GLYPHS for …` when a menu glyph has no face, a unit test asserts
  coverage (with an unassigned codepoint as the control that must fail), and
  `live-menus.sh` fails if the bar ever announced a gap. Seen only by looking
  at a screenshot: every functional check passed with boxes in the menu.
  **And the FreeBSD guest then failed the new test on one glyph, ⎋** (Force
  Quit's ⌥⌘⎋): DejaVu Sans lacks it and Adwaita is not installed there. DejaVu
  Sans Mono has it, and the medium already carries the whole DejaVu directory,
  so it joins the end of the list. The check paid for itself on its first run
  on the second platform.

**Verified:** `live-menus.sh`, on undertow with a real pointer and keyboard —
the bar shows the Finder's menus; **the open menu is on screen** (a pixel in
its margin is the menu's white, not the desktop's blue); Paste is disabled with
an empty clipboard and enabled after Edit ▸ Copy chosen from the bar; File ▸
New Folder makes a folder on disk and the bar logs the path the Finder
returned; Down + Return chooses from the keyboard; → walks to the next menu and
Escape still reaches the bar; with the menu closed a key reaches the Finder
again (the rename New Folder left open is completed, checked on disk); and with
no window left, the desktop's Finder is frontmost. **Five injected faults each
failed it:** popups out of the hit-test, popups out of the scene, no keyboard
hand-off to the bar, no hand-back to the window — and, as the control that
disproved a claim, no explicit initial configure, which did *not*. Plus
`live-session-gtk.sh`: the real session's bar is on the privileged socket and
shows the desktop's Finder. Screenshot: `docs/screenshots/live-menubar-undertow.png`.
Gates: `run.sh --live` (Linux) and `run.sh --vm --live` (FreeBSD) green at 444
unit tests. **The `--full` lane was not run to completion** — this pass changed
how `abyss-session` starts undertow and the bar on the medium, which is the
case HANDOFF asks `--full` for; it was stopped partway (nothing had failed) and
is owed.

**P10.5 — undo, decided. ✅ done.**
Decided (§6.3): an undo stack per **window** in `Aqua`, of named,
inverse-carrying entries (`Undo Move to Trash`); Edit ▸ Undo and Redo are
*derived* from the top of the stack — title and enablement — and are ordinary
`Command`s with verbs `edit.undo`/`edit.redo`, so a script can undo too. A verb
that mutates either pushes its inverse or declares itself not undoable, in its
definition, where a reviewer can see it. The Finder's rename, move to Trash, new
folder, duplicate and paste become undoable.

**What P10.5 landed.** `UndoStack` (`de/aqua/Undo.swift`), held by each
`FinderWindow`. `edit.undo` and `edit.redo` are implemented verbs, so ⌘Z,
⇧⌘Z, the Edit menu and `abyssmenu run finder edit.undo` are one command; their
titles come from the stack through `MenuBarModel.retitled` — the model has one
definition, and "Undo Move to Trash" is state applied to it, not a second
menu. When the stack changes, or another window becomes key, the Finder calls
`MenuService.changed()`, and the bar — subscribed since P10.4 — redescribes:
**`subscribe`'s first customer**, and the injected fault that removed the call
failed the test. Undoable today: New Folder, Rename, Duplicate, Paste (copy),
Move (paste after cut), Move to Trash.

**Two rules the Finder follows, both in the code rather than in each verb:**

- **Undoing a creation puts it in the Trash; it never deletes.** That is the
  Finder's own behaviour, and it means no undo in this tree can destroy data —
  an undone New Folder with a week's work in it is in the Trash, not gone.
  Redo takes it back out.
- **An undo the world has moved under is refused, with the reason, and stays on
  the stack.** Something now has the old name; the reply says so, the Edit menu
  still offers the same undo, and once the way is clear it works.

**What it did not find.** Unlike every pass before it in this phase, P10.5 found
nothing already broken — it is the first pass here that was purely additive, and
worth saying so rather than inventing a finding. What it leaves:

- **A drop is not undoable** (`FinderWindow.receiveDrop` copies without pushing).
  A drag is not a menu command, so nothing in this phase reaches it; it is one
  `pushCreation` when something wants it.
- **Rename's undo is not exercised live** — renaming is an inline edit driven
  by keys, and `live-undo.sh` drives the vocabulary; the unit tests cover the
  stack, and the rename's push is the same `pushMove` Move to Trash uses.
- **Foreign applications' undo is theirs.** GTK's Edit ▸ Undo is its own action
  and arrives through P10.6 like any other; nothing here reaches into it.

**Verified (short checks only — see below):** `live-undo.sh` (under a second):
nothing to undo is disabled with a reason; New Folder retitles Undo and the bar
is told; undo is the Trash and redo brings it back; Move to Trash undone; an
undo into an occupied name refused, kept, and successful once clear. Its
injected fault (no change pushed) failed it. Unit: titles and enablement
derived from the stack, a new change forgetting redo, a failed undo kept, the
bound, and retitling touching nothing but the title. `swift test` on Linux:
449 tests, green; `live-vocabulary.sh`, `live-menus.sh`, `live-menu-focus.sh`
re-run green. **Not run in this pass:** `run.sh --live`, `run.sh --vm --live` —
so nothing in P10.5 has been run on FreeBSD yet — and `--full`, owed at the end
of the phase.

**P10.6 — GTK's menus in our bar. ✅ done.**
undertow advertises **`gtk_shell1`** with the `GLOBAL_MENU_BAR` capability (so
GTK sets `gtk-shell-shows-menubar` and stops drawing its own) and records
`gtk_surface1.set_dbus_properties` — unique bus name, application object path,
menubar path, window object path — against the surface. `abyss_menubar_v1`
reports it as `kind=gtk`. `abyss-dbus` subscribes with `org.gtk.Menus.Start`,
reads enablement from `org.gtk.Actions.DescribeAll`, activates with
`org.gtk.Actions.Activate` — and **serves the result as `menuwire`**, so the bar
speaks one protocol and the translation lives where PLAN.md put it. `app.*`
actions resolve on the application path, `win.*` on the window path, which only
`set_dbus_properties` can supply (§4.2).

**What P10.6 landed.**

- **`gtk_shell1` in undertow**, all of it, version 5. `protocols/gtk-shell.xml`
  is vendored unmodified from GTK's 3.24.52 tag (LGPL-2.1+), the version both
  platforms run. Every request has a handler, most of them no-ops.
  `set_dbus_properties` goes to `Menus` as a `gtk`-kind address.
  `capabilities` is sent on bind as `global_app_menu | global_menu_bar`, but
  only when undertow has a privileged socket, i.e. a session with a bar (§6.5).
  GTK reads the capability as `1 << (value − 1)`, and the first live run
  confirmed it: `gtk-shell-shows-menubar=1`, and the window's own menubar is
  gone.
- **`GtkMenuAddress`** in `MenuModel` is one encoding shared by the three
  parties that carry it: undertow, the bar and the bridge.
- **`DBusMenus`**, run as `abyss-dbus --menus`, is a process of its own because
  the portal half blocks behind a file dialog (PHASE8 §6.7). It serves one
  MenuWire service, `menus-gtk` (renamed `menus-dbus` in P10.7, when it began
  serving Qt too), whose requests carry the GTK address as
  `target`:
  - `describe` follows `org.gtk.Menus.Start` link by link until no group is
    missing, then `End`s the subscription;
  - `validate` is `org.gtk.Actions.DescribeAll` on the application path (as
    `app.`) and the window path (as `win.`);
  - `activate` is `Activate` on whichever path owns the action.

  `anchor` starts it as the `menus` component, on the bus and waiting for it.
- **The bar treats a `gtk` focus like its own apps' focus**, sending the
  service `menus-gtk` with the address as its target. It is one protocol, and
  the bar knows no D-Bus at all.
- **Every `MenuClient` call now has a 2 s timeout.** Until now a bar asking a
  stuck application would have waited for ever. That was left over from P10.4,
  and it mattered the moment one of the bar's servers could be somebody else's
  program.

**What GTK does not give us, and the bridge does not invent** (written in
`GtkMenus.swift` so nobody hunts for it):
- **Descriptions.** The summary is the label.
- **Argument types.** A parameterised item (`target`) is drawn and refused as
  "a parameterised action, which the bridge does not carry yet", rather than
  bridged wrong.
- **Accelerators set with `set_accels_for_action`**, as in §4.1. Only an
  `accel` attribute in the model shows one.
- **`Changed` is not watched.** A GTK menu rebuilt while it is on screen is
  stale until it is opened again.

**What it did not find.** Nothing already broken, for the second pass running.
The spikes had already mapped this ground (§4.1, §4.2), and the pass went as
they said. That is worth recording, because it is what spiking first is for.

**Verified (short checks only):** `live-menus-gtk.sh` (4 s), where the other
end is a stock GtkApplication (§2.39):
- GTK hid its own menubar, by its own setting;
- undertow recorded GTK's address;
- the bar shows MenuSpike, File and Edit;
- Paste is disabled because GTK disabled it;
- File ▸ Open…, chosen with a real pointer, printed `activated=open` in GTK's
  own process.

Its two injected faults both failed it:
- no capability advertised, so GTK kept its own menubar;
- GTK's address dropped in undertow, so the bar never saw GTK's menus.

Also: unit tests on the spike's real `Start` reply (links, sections,
mnemonics, accelerators, a self-linking model that must terminate,
`DescribeAll`, parameterised items, the address round trip); `swift test` on
Linux, 458 tests, green; and `live-session-gtk.sh` (the `menus` component in
the real session), `live-menus.sh`, `live-vocabulary.sh`, `live-undo.sh` and
`live-menu-focus.sh`, all re-run green.

**Not run:** `run.sh --live` and `run.sh --vm --live`, so neither P10.5 nor
P10.6 has run on FreeBSD yet. `--full` is owed at the end of the phase.

**P10.7 — Qt's, if the spike says so. ✅ done — the spike said so (§4.5).**
`org_kde_kwin_appmenu_manager` in undertow, `abyss-dbus` owning
`com.canonical.AppMenu.Registrar`, and a `com.canonical.dbusmenu` translation.
**Gated on its own spike** (§4.2): Qt's side is read out of the library's
symbols, not run, because this box has no Qt headers. The pass does not start
until a Qt application has been seen exporting a menu on both platforms.

**What P10.7 landed.**

- **`org_kde_kwin_appmenu` in undertow.** `protocols/kde-appmenu.xml` is
  vendored from the copy Qt installs (LGPL-2.1+). `set_address(service, path)`
  becomes a `dbusmenu`-kind address against the surface, the same shape as our
  own `abyss_menu_v1`, which was modelled on it. `release` does not withdraw
  the address. Qt releases and re-creates the object when it rebuilds its
  menubar, and the next `set_address` replaces the old one.
- **`com.canonical.AppMenu.Registrar`**, owned by `abyss-dbus --menus`
  (`de/dbusmenus/Registrar.swift`). Without it Qt exports nothing, and the
  injected fault that removed it failed the test at the first step.
- **`QtMenus`** turns `GetLayout` into our model, calling `AboutToShow` first
  on lazy submenus. The bridge serves it through the same MenuWire service,
  renamed `menus-dbus`. A target tagged `dbusmenu` tells it this is a Qt
  address, and a test asserts the bridge can never read one as GTK's.
  `activate` is `Event(id, "clicked", …)`.
- **The bar treats a `dbusmenu` focus like the other kinds**, with the app_id
  supplying the name.

**Two decisions the spike forced:**

- **Verbs are menu paths (`edit.undo`, `settings.science-mode`), not dbusmenu
  ids.** Qt renumbers its items when it rebuilds, and kcalc did so under a live
  window in the spike. A verb built from an id would change between a script
  reading the vocabulary and running it. The id is looked up again, by verb,
  from a fresh layout at activation.
- **Shortcuts are drawn as the keys that work.** kcalc's Undo is Ctrl+Z, so
  the bar shows ⌃Z, not ⌘Z. Qt listens for Ctrl, and ⌘Z would be a key that
  does nothing. (⌘Q, for its part, is the compositor's, P9.5.) A Mac-style
  remapping of Primary to Command, for Qt as for GTK, would be a keyboard
  policy, not a menu one, and it belongs with the keybind table.

**What it did not find, and what it leaves.** Nothing already broken; the
spike had mapped it. Left:
- **Toggle state is read and not drawn.** Radio and checkmark items appear as
  plain commands, so "Science Mode" carries no ✓.
- **`LayoutUpdated` and `ItemsPropertiesUpdated` are not watched**, the same
  as GTK's `Changed`.
- **The build VM now has `kcalc` and `qt6-wayland` installed** (58 packages,
  2026-09-25), which is the environment `live-menus-qt.sh` needs. On a box
  without kcalc the test skips, and says so.

**Verified (short checks only):** `live-menus-qt.sh` (3 s) against stock
kcalc:
- undertow recorded its dbusmenu address;
- the bar shows kcalc, File, Edit and Settings;
- Undo shows ⌃Z;
- Settings ▸ Science Mode, chosen with a real pointer, switched kcalc's mode,
  **asserted on kcalc's own layout through `gdbus`**, not on the bar's log.

Both of its injected faults failed it:
- no registrar, so kcalc never gave an address;
- `activate` that says ok without sending the event, so the bar logged ok and
  kcalc's mode stayed off. That is the lie only the other end can catch.

Also: unit tests on kcalc's layout (verbs, ids, enablement, invisible items,
separators, shortcuts, a lazy submenu, duplicate labels, the address never
read as GTK's); `swift test` on Linux, 463 tests, green; `live-menus-gtk.sh`,
`live-menus.sh`, `live-session-gtk.sh`, `live-undo.sh`, `live-vocabulary.sh`
and `live-menu-focus.sh` re-run green. **On FreeBSD:** the spike itself, and
`live-menus-qt.sh` green in the guest — all four steps, against the guest's
own kcalc. **Not run:** `run.sh --live`, `run.sh --vm --live` (the whole
FreeBSD suite has not run since P10.4), and `--full`, owed at phase end.

**P10.8 — the menus the desktop owns. ✅ done.**
The Apple menu's items that something can already do — **Log Out** (`anchor`),
**Force Quit…** (the foreign-toplevel list and `close`), **About This
Computer** (the `Fathom` report, rendered), **System Preferences…** (launch) —
and the rest *disabled*, not removed and not logging. Contextual menus on the
desktop, in Finder windows and on every Dock tile, built from the same
`Command`s the bar shows, so a right-click and the menu bar can never disagree.

**What P10.8 landed.**

**The system menu does what its items say:**
- **About This Computer** posts a notification naming the OS, the host, the
  CPUs and the memory.
- **System Preferences…** opens it.
- **Force Quit <frontmost>** is a privileged request to the compositor
  (`abyss_menubar_v1` version 2, `force_quit`). Only undertow knows which
  process is behind a window. It sends `SIGKILL` to the pids found through the
  clients' credentials, never its own. Jaguar's Force Quit is a dialog that
  preselects the frontmost application, and the bar can host neither a dialog
  nor a submenu, so the item names what it would quit.
- **Log Out** acts at once. That is Jaguar's ⌥ variant, and it carries no
  "…" because there is no confirmation sheet yet.
- **Sleep, Restart and Shut Down** are disabled, with "needs a privileged
  helper this desktop does not have yet".

**The contextual menus:**
- **Finder windows:** right-clicking selects what is under the pointer and
  offers `FinderContext.item` or `FinderContext.background`, verbs picked from
  `finderMenuBar()`. They are the menu bar's own commands, with the same
  titles, keys and enablement, and a test asserts it.
- **Dock tiles:** Open or Quit, depending on whether the application runs.
  Quit is the polite request, through `ForeignToplevels.close(appID:)`.
- **The desktop:** New Folder in `~/Desktop`.

`ContextMenu` is the one helper all three use. Every row is logged with its
offset inside the popup, and **undertow logs where each popup actually landed**
(`popup mapped at X,Y WxH`), so a test clicks a row without computing
placement.

**What it found:**

- **A child of the bar inherited the bar's privilege.** The bar runs on the
  privileged socket (P10.3), and the first System Preferences it launched
  inherited `WAYLAND_DISPLAY`. It was therefore privileged too: it could watch
  focus and force-quit any application. `anchor` now gives the bar the ordinary
  display as `ABYSS_APP_WAYLAND_DISPLAY`, and the bar launches on it. If it
  doesn't know that display it refuses to launch; it does not fall back to its
  own socket. `live-context.sh` checks the display the child actually got,
  and it failed with the fix removed. The rule: **a privileged process must
  not hand its privilege to its children by default; what it launches is
  launched on purpose, with the environment chosen.**
- **Submenus have never opened.** P10.1 taught `AquaMenu` to draw a submenu's
  ▸, and nothing opens a child popup. That was invisible while no menu here
  had a submenu. A GTK or Qt application's menus can have them (§4.5's lazy
  "Constants"), and there they are drawn and cannot be entered. It is the
  largest thing Phase 10 leaves, and the reason Force Quit is a single item
  and not a list.
- *(My own test, twice: `gdbus` reading `-1` as an option in P10.7, and here a
  shell variable reused by a helper — both harness, both caught by a test
  failing a compositor that was right.)*

**Verified (short checks only):** `live-context.sh` (7 s), on undertow with a
real pointer:
- an item's menu is the Finder's commands, and Duplicate made a copy on disk;
- the background's menu made a New Folder on disk;
- About reached the notification centre, naming this machine;
- Force Quit killed the frontmost application's process, and only that one;
- System Preferences opened a window the compositor made frontmost, **on the
  ordinary display**.

Its two injected faults both failed it:
- the child inheriting the bar's display;
- a `force_quit` that killed nothing, which the compositor still logged as a
  kill and the test caught by asking the process.

Unit tests: the contextual menus are the menu bar's own `Command`s; a Dock
tile's menu is Open or Quit by whether the application runs; the Trash's
order is kept; the desktop's menu. `run-live.sh trash menubar dock` under
sway: green. `swift test` on Linux: 466. All the short menu and session
scripts re-run green.

**Not verified live:** the Dock's and the desktop's menus on undertow (unit
tests plus the Trash under sway), and Log Out (it would end the session
driving the test).

**Phase gates, run at the end as agreed:** `run.sh --live` (Linux, 280 s) and
`run.sh --vm --live --full` (FreeBSD, 1046 s), both green. These are the first
full FreeBSD runs since P10.4, so P10.5–P10.8 are now covered by the whole
guest suite, not only by the short scripts.

---

## 4. The spikes — four, and one of them moved the phase

### 4.1 Does a stock GTK application publish its menus? — **Yes, completely, on both platforms.**

An 80-line `GtkApplication` (`abyss/tests/gtkmenu.c`, dlopen'd like `gtkpick`,
so still no GTK build dependency) with a File and Edit menu, five `app.*`
actions, Paste disabled, and `<Primary>q` bound to Quit. Run on a private bus, under the host compositor on
Linux and under **our own `undertow`** in the FreeBSD guest (GTK 3.24.52 on
both):

```
org.gtk.Menus.Start([0,1,2])  →  (0,0,[File ▸ (1,0), Edit ▸ (2,0)])
                                  (1,0,[New app.new, Open… app.open, Quit app.quit])
                                  (2,0,[Copy app.copy, Paste app.paste])
org.gtk.Actions.DescribeAll   →  {'paste': (false, …), 'open': (true, …), …}
org.gtk.Actions.Activate open →  the application printed "activated=open"
```

Everything the bar needs is there: the tree, enablement, and activation that
works from outside the process. **Two things are not:**

- **Key equivalents.** `set_accels_for_action` binds ⌘Q in the application and
  puts nothing in the exported model — no `accel` attribute. A GTK menu in our
  bar will show equivalents only where the application wrote them into the
  model. Stated rather than papered over: the bar draws what it is told.
- **`win.*` actions** live at `/org/…/window/1`, a path that appears nowhere in
  the menu model. Only the window can say which number it is.

### 4.2 Can the bar find those menus? — **No. Nothing tells it where they are.**

The same application under `undertow`, with `WAYLAND_DEBUG=1`:

- **undertow advertises no `gtk_shell1`**, so GTK never sends
  `gtk_surface1.set_dbus_properties` — the one message that carries the bus name
  and the menu paths — and `gtk-shell-shows-menubar` stays `0`, so the window
  draws its own menubar as well.
- **The `app_id` is `gtkmenu`, not `org.abyss.MenuSpike`.** GTK 3 sets the
  xdg-toplevel app_id from the program name, not the `GApplication` id, so the
  obvious fallback — derive the bus name from what the foreign-toplevel protocol
  already reports — **names a bus peer that does not exist.** And it could not
  find `win.*` even when it guessed right (§4.1).

So the address has to come from the surface, and only the compositor sees
surfaces: **`gtk_shell1` moves into this phase, in undertow.** The host KWin, for
comparison, advertises `org_kde_kwin_appmenu_manager` (version 2) — the Qt/KDE
equivalent, the same idea, and the protocol P10.3's `abyss_menu_v1` is modelled
on. `libQt6WaylandClient` on this box has the client half compiled in
(`QtWayland::org_kde_kwin_appmenu_manager::create`), which is why P10.7 is
plausible — and only plausible, since no Qt application was run (no `qt6-*-devel`
here, no bindings). That is P10.7's gate.

### 4.3 Can undertow host a protocol of its own? — **Nothing in the tree does yet; nothing stops it.**

All fourteen globals undertow advertises today come from wlroots constructors
(`Compositor.swift:349–413`, `Seat.swift`, `Decorations.swift`), and
`generate-protocols.sh` generates only server *headers*, because wlroots links
its own implementations. A protocol of ours needs the server header **and**
`private-code` (the interface tables), `wl_global_create` with a bind callback,
and `wl_resource_set_implementation` with a struct of C function pointers — the
listener shape of §2.2/§2.3 from the other side, and `@convention(c)` closures
are how Swift fills it. The trap to expect is the same one: **a NULL slot in an
implementation struct is a crash the first time a client sends that request**,
so every request of the bound version gets a handler, even a no-op.

`gtk-shell.xml` is not installed by any package on either platform (GTK compiles
it in); it is vendored into `protocols/` from GTK's source, LGPL-2.1+, like the
KDE XML (installed here as `/usr/share/qt6/wayland/protocols/appmenu/appmenu.xml`).

### 4.4 Can `CurrentIPC` carry a menu? — **Yes, with one idiom.**

`Msg` is insertion-ordered flat fields — string, uint64, bool, bytes, fd — and
`maxFrame` is 1 MiB. A tree does not fit flat fields and does fit a `.bytes`
field holding a packed `Msg`, recursively; `Msg.unpack` is already the parser.
The Finder's whole menu set is a few kilobytes at most. `Current.call` is connect–send–
receive–close, which is right for `describe`/`activate` and wrong for `changed`,
so the held connection is new — folded into the bar's run loop the way
`NotifyCenter` folds its server (§2.18), not a thread.

---

### 4.5 P10.7's own spike: does a stock Qt application export its menus? — **Yes, on both platforms, and richer than GTK.**

Run 2026-09-25 against **stock `kcalc`** (KDE Gear, Qt 6.11), on our own
compositor with `QT_QPA_PLATFORM=wayland` and a private bus. Nothing is a
fixture of ours.

- **Qt exports nothing until `com.canonical.AppMenu.Registrar` is owned.**
  With `abyss-dbus --menus` owning it (a stub: on Wayland Qt checks that the
  name exists, then reports through the compositor), kcalc exports
  `com.canonical.dbusmenu` at `/MenuBar/N` on its unique name.
- **It reports the address through `org_kde_kwin_appmenu`** once undertow
  offers the manager: `create(surface)`, then `set_address(":1.1",
  "/MenuBar/1")`. It later rebuilt its menubar and **re-pointed the same
  surface at `/MenuBar/2`**, which undertow tracked. So an address can change
  under a live window, and the bar has to follow it.
- **`GetLayout` carries what GTK's export does not.** It has labels (with `_`
  mnemonics), `enabled`, separators (`type: separator`) and submenus
  (`children-display: submenu`). It also has **real shortcuts** —
  `shortcut: [['Control','Z']]` — and **toggle state** (`toggle-type: radio` /
  `checkmark`, `toggle-state`). Unlike GTK (§4.1), a Qt application's key
  equivalents will reach our bar.
- **One lazy submenu.** kcalc's "Constants" has no children until opened, which
  is dbusmenu's `AboutToShow(id)`. The bridge has to ask before it describes.
- Activation is `com.canonical.dbusmenu.Event(id, "clicked", v, timestamp)`.
  **Not yet exercised.**

**FreeBSD: the same, run the same day.** `kcalc` 26.04.3 on Qt 6.11.1 was
installed in the build VM for this spike (`pkg install kcalc qt6-wayland`; 58
packages). The run matched Linux message for message: `create`, then
`set_address(":1.1", "/MenuBar/1")`, a rebuild re-pointing the surface at
`/MenuBar/2`, and a `GetLayout` with the same top level (File, Edit, Settings,
Help). **P10.7's gate — seen on both platforms — is open.**

## 5. Verification

`abyss/tests/run.sh --vm --live` on both platforms, unit tests for every pure
function, and **no existing live mode may start depending on a menu service
being up** — a desktop whose bar cannot reach an application must still draw a
bar.

**Pure, tested with no compositor:**

- Every key equivalent in the Finder's model reaches the same code as choosing
  the item — walked over the model, not listed by hand, so a command added later
  is covered by construction.
- The wire round-trips a menu tree, including a submenu three deep, an empty
  menu, and a verb whose argument types are non-trivial.
- The undo stack: push, undo, redo, a new action clearing redo, and the derived
  titles (`Undo Move to Trash`, disabled `Undo` on an empty stack).
- GTK's menu groups → our tree: the `Start` reply above, as a fixture, including
  `:section` and `:submenu` links.

**Live, asserting on the thing (§2.43, §2.44, §2.46):**

| Script | What it proves |
|---|---|
| `live-menus.sh` | a real pointer opens the Finder's File menu in the bar and chooses **New Folder**; the folder exists on disk. Then ⌘⇧N does the same. Then Edit ▸ Undo removes it. **Paste is drawn disabled** with an empty clipboard and enabled after a copy — asserted on the menu's own dumped state, with the app publishing its item rects (§2.46) rather than coordinates in the script |
| `live-vocabulary.sh` | `abyssmenu describe` lists the Finder's verbs with descriptions; `abyssmenu run … file.new-folder` returns the name it made; a disabled verb returns `refused` **with its reason** rather than succeeding vacuously (§2.37) |
| `live-menus-gtk.sh` | the GTK fixture's File menu appears in **our** bar (asserted on undertow's `set_dbus_properties` log *and* the bar's dump), **its own menubar is gone** (`gtk-shell-shows-menubar=1`), choosing Open prints `activated=open` in GTK's process, and Paste is disabled because GTK said so — the other end never ours (§2.39) |
| `live-menus-focus.sh` | two applications; focus moves; the bar's application menu changes with it and never shows one application's menus under the other's name |

**And every one of these must be seen to fail once** — with `set_address` not
sent, with the bar ignoring `validate`, with GTK's capability not advertised —
before it is believed. A menu bar is a picture first, so the false pass that
matters most here is the one where the bar draws the right words from the wrong
source.

---

## 6. Risks / open decisions

**6.1 Who may learn what is focused — DECIDED: a privileged socket.**
`abyss_menubar_v1` tells its client which application is frontmost and where its
menus are. Offered to every client, it is a surveillance global. Options:

- **A second, named undertow socket for privileged clients** —
  `undertow --privileged-socket NAME`, 0600 in the runtime dir, and a
  `wl_display_set_global_filter` that admits `abyss_menubar_v1` only to clients
  that connected there. `anchor` points the bar at it. It is §2.42's rule again
  (name your sockets) and the inverse of `security-context-v1`.
- A pid allow-list handed from `anchor` — racy on pid reuse, and it makes the
  compositor trust a number.
- Filter on the layer-surface namespace — impossible: a global is bound before
  any surface exists.

**Decided (2026-09-25): the first.** It also answers the same question for whatever
comes next that the Dock or the switcher (Phase 13) must see and an application
must not.

**6.2 Is a CurrentIPC service name a trustworthy address?**
For the bar, yes: it gets the address from the compositor, bound to the surface
by the process that owns it. For `abyssmenu` and Phase 18, a script names a
service directly, and a service name in the runtime dir is whoever bound it
first. That is the same trust as every other socket in a 0700 directory — the
user's own processes — and it is **not** the answer for a confined application
(Phase 17), which must never be able to impersonate another's vocabulary. Written
down so Phase 17 inherits it as a known edge rather than discovering it.

**6.3 Undo — DECIDED: per window, held rather than owned.**
Jaguar's answer was per document (`NSUndoManager` on the document, the window
asks its document). This desktop has no document model yet, and the Finder has
none at all. **Decided (2026-09-25): per window now, with the stack owned by an object
the window *holds* rather than *is***, so Phase 15's document-based applications
move the stack to the document without changing a single `Command`. The Finder's
operations are file-system operations, and the honest caveat is that their
inverse can fail (the file was moved again since); an undo that cannot run is
`refused` with a reason, through the same result path as any verb.

**6.4 Enablement — DECIDED: pulled.**
Pulled on menu open (§3, P10.2), as Jaguar's `validateMenuItem:` did. Pushed
would keep the bar exactly current and would wake every application on every
clipboard change to recompute a menu nobody has open. The cost of pulling is one
round trip before a menu draws, which is the thing to measure in P10.4 against
the frame budget — a menu that opens a frame late is a visible regression.

**6.5 GTK's menubar must disappear — and only when ours will show it. DECIDED.**
Advertising `GLOBAL_MENU_BAR` makes every GTK application hide its menubar. If
the bar is not running, or `abyss-dbus` is not, those applications have no menus
at all. The capability should therefore be advertised only when the session has
a bar that can serve it — `anchor` knows; undertow is told — and `without menubar`
sessions keep GTK's own. **Decided (2026-09-25).**

**6.6 This phase can quietly become Phase 15.**
Every pass here would be nicer with a second real application. The scope is the
protocol and the Finder; where a test needs another application, it is the GTK
fixture, so no application gets written to make these tests pass (PHASE9 §6.6's
rule, unchanged).

**6.7 `wlr-data-control` stays open** (PHASE9 §6.7). Nothing in this phase asks
for it.
