# Phase 13 — Islands, Shoals and Ebb (scope)

How thesis 3 beats tiling: workspaces (**Islands**), explicit window sets
recalled together (**Shoals**), and an Exposé (**Ebb**), none of which ever
moves a window you placed. [PRODUCT.md §7](PRODUCT.md) is the argument and the
names; [PLAN.md](PLAN.md) puts it after 9 (the keybind table) and 4 (a real
vblank, for C6). Both are met: Phase 9 is done, and the 12700KF has measured
C1 against a real vblank (PHASE4 §5.12) and is on the desk.

Last updated: 2026-10-01. **Scoped, from a survey of `undertow` as it stands,**
and **§6's recommendations adopted, all seven** (2026-10-01). What changed from PLAN before a line was written:

- **PRODUCT §7.4's costs hold, with names.**
  - One predicate decides what is drawn, hit and clocked:
    `Compositor.mappedToplevels` (`mapped && !minimized && has_buffer`).
  - The scene already draws at any `dst_box`, so thumbnails are free.
  - The minimised window's slow clock and xdg `suspended` (U.2, T.3) are the
    off-island window's treatment, already written.
  - The Dock's click already ends in one compositor handler (foreign-toplevel
    `request_activate`).
- **Alpha is there in wlroots 0.20** (`wlr_render_texture_options.alpha`,
  both platforms): the scene gains one array and sets it.
- **Nothing measures input-to-commit today.** `FrameRecord` has no input
  stamp. C6 needs one, and it is the phase's instrument, so it comes second,
  before anything animates.
- **"C6 measured on the Mac Pro"** becomes the 12700KF (the bring-up
  retarget, 2026-09-05).

---

## 1. What this phase is

**Goal (PLAN):**
- Islands per display, with a switch committed within two frames (C6);
- Ebb in three scopes;
- Shoals, explicit and recalled to remembered places;
- the Dock reaching across islands.

**Verify:** `bench-islands` in the gating lane; C6 on metal under load; an Ebb
drawn over the eleven adversary clients C2 already survives.

**What it is not:**
- tiling, snapping layouts or automatic placement of any kind (thesis 3);
- Mission Control's single combined view of spaces and windows (Ebb's
  archipelago scope is the nearest thing);
- per-island Dock contents;
- hot corners (§6.6 asks);
- touchpad gestures (pointer-gestures is BACKLOG §2's "later").

---

## 2. What we have vs. what's new

| Need | Have | New |
|---|---|---|
| Which windows are drawn | `mappedToplevels`, one predicate (Compositor.swift:1192) | an island tag on `Toplevel`; a per-display active island; `visible` = on its display's active island and not minimised |
| Clocks for unseen windows | 1 Hz + `suspended` for minimised (`sendFrameDone`, `setMinimized`) | the same for off-island windows: the loop widens from `minimized` to `!visible` |
| Focus when a window goes | `Seat.focusTopmost` over `mappedToplevels` | follows for free once the predicate does |
| Thumbnails | `SurfaceScene.render` takes any `dst_box` | — |
| Fades, dimming | — | an alpha array in the scene's SoA, set on `wlr_render_texture_options` |
| A slide | the latch | an x-offset per scene, from a transition clock |
| Keys | `KeyBindings`, `keys.ini`, five actions | island, Ebb and Shoal actions |
| Remembered places | `WindowPlaces` (`windows.ini`: x,y by app/title) | the island too, and shoal membership |
| Dock activation | foreign-toplevel `activate` → `request_activate` | go to the window's island first |
| Shell → compositor commands | `abyss_menubar_v1` (privileged: `force_quit`) | island requests on it, for the switcher and the menu bar |
| Latency instruments | `FlightRecorder` (cadence, cost, misses) | an input stamp, and frames-to-commit |

---

## 3. Ordered passes

**P13.1 — Islands, in the compositor (M).**
- **Model.** `Toplevel.island` (a number) and `DisplayLayout`'s active island
  per display. A window's island belongs to the display it is on: dragged
  across, it takes that display's active island.
- **One predicate.** `visible` replaces `!minimized` in the three places that
  decide (draw and hit, frame clock, hidden commits). An off-island window gets
  the slow clock and `suspended`, as a minimised one does.
- **A switch.** Change the active island; focus the topmost visible window
  there (or nothing). That is the whole commit, applied before the next latch.
- **Moving a window.** To another island, and following it or not (§6.2).
- **New windows** open on their display's active island.
- **Controls.**
  - Key actions `island N`, `island next/previous`, `move-to-island N`.
  - `islands.ini`: the count and the names (§6.1).
  - Requests on `abyss_menubar_v1` (switch, move), so the shell can ask.
  - A line on stdout for tests: `island DISPLAY N`.
- **Verified by** `live-islands.sh`:
  - windows on islands 1 and 2, and a switch shows only the right ones
    (screencopy);
  - the hidden ones get the 1 Hz clock and `suspended` (`hidden.c`);
  - focus goes to island 2's topmost window, and keys reach it;
  - a moved window goes;
  - two displays switch independently;
  - Cmd-Tab per §6.3.

✅ **P13.1 done 2026-10-01.**
- **The model.** `Islands.swift` holds `IslandsConfig` (`islands.ini`: count
  1–9, default 4; names; wrapping) and the compositor's operations:
  `switchIsland`, `stepIsland`, `moveFocusedWindow(toIsland:follow:)` and
  `bringToFront`.
- **The predicate.** `Toplevel.island` and `islandDisplay` are settled when a
  window maps, when a drag ends, and when a layout change brings an orphaned
  window home. `mappedToplevels`, the slow-clock loop and the hidden-commit
  count all ask `isOnActiveIsland`.
- **`suspended`** is said once per change (`refreshSuspended`), for minimised
  and off-island windows alike.
- **The keys** are §6.4's. A window being dragged goes with a switch.
- **§6.3 now.** Cmd-Tab and the Dock's `request_activate` go through
  `bringToFront`, so the Dock half of P13.4 is already in.
- **Moved to P13.4:** the shell's requests on `abyss_menubar_v1`. Their first
  user is the menu-bar item.
- **Tests:** `live-islands.sh` (7 claims), 2 unit tests, and four faults
  injected and caught (the predicate ignoring islands, no `suspended` on a
  switch, Cmd-Tab not going there, Shift not following).

**P13.2 — C6, measured (S–M).** Before anything animates, so the animation is
judged against a number that already exists.
- **The stamp.** `FrameRecord` gains the input that asked: its arrival time
  and the frame seq it reached. "Committed" means the first frame latched
  after the switch was applied.
- **`undertow bench-islands`.** Headless:
  - N windows on four islands;
  - a scripted switch every few frames, including mid-transition re-targets
    once P13.3 exists;
  - asserts C6's p99 ≤ 2 frames and C1's misses.
- It joins `bench-metronome.sh` in the default (C5) lane, and C6 is added to
  PHASE6's contract table.
- A fault that defers the commit by one frame must fail it.

✅ **P13.2 done 2026-10-01.**
- **Measured to the display, not the latch** (`SwitchLatency.swift`).
  `switchIsland` stamps the request. The scene that first latches the display
  carries the stamp out (`FrameStats.inputAt`), and the metronome follows it
  to that frame's flip. A sample is the number of frame periods from input to
  that vblank. Counting latches would always say 1.
- **A refused flip is not "shown":** the next frame carries the stamp.
- **`undertow run`** prints `island-commit …` per switch and a `c6` summary,
  with `--assert-c6-frames` and `--assert-c6-switches`.
- **`bench-islands.sh`** gates the default lane beside C2:
  - twelve windows on four islands and C2's eleven adversaries;
  - 45 switches by the keyboard at jittered phases;
  - p99 ≤ 2 frames, at least 40 switches measured, and C1's miss budget.
- **Measured:** Linux and the guest (three runs) both give p99 = 2, median
  8.5–10 ms, max 17–18 ms at 60 Hz. The worst, an input just after a latch,
  waits one more frame, which is structurally the limit for a frame that is
  not missed.
- **Faults caught:** a 40 ms commit (3 frames; C1 failed too), and a refused
  flip counted as shown (unit test).

**P13.3 — the transition (S–M).**
- **Alpha array** in `SurfaceScene`.
- **The slide** is an x-offset over ≤ 150 ms. The outgoing island draws
  until it leaves; input already belongs to the new one.
- **Re-targeting.** Asked for island 3 mid-slide to 2, it re-targets from
  where it is; it never queues.
- **Off** in `islands.ini` (§6.5).
- **Verified by:**
  - `bench-islands` with transitions on (C6 unchanged);
  - re-target and skip claims in `live-islands.sh`;
  - a golden of a mid-slide frame at a fixed clock.

✅ **P13.3 done 2026-10-01.**
- **The view.** Each display has a continuous view, an island position.
  `switchIsland` moves only its target, from wherever it is now, so a
  re-target mid-slide continues from there and never queues.
- **The scene,** while a display's view moves, draws that display's islands
  within one width of the view, each shifted by its distance from it.
  Otherwise it draws exactly as before; the slide costs one emptiness test a
  frame when nothing slides.
- **Ease-out cubic, 150 ms.** `islands.ini` has `animate` and `slide_ms`
  (clamped to 2 s, for tests and for watching it).
- **Changed from the plan:**
  - The alpha array moves to P13.5, its first user (dimming behind Ebb); a
    slide needs none.
  - The mid-slide golden became `live-islandslide.sh`'s captures, which
    assert the same thing without a fixed clock.
- **C6 unchanged with the slide on:** p99 2 frames on both. Medians of 9–10
  ms with it, against 10.6–11 ms for the code before it, the same within
  noise.
- **Tests:** `live-islandslide.sh` (5 claims) and 2 unit tests. Four faults
  injected and caught:
  - a re-target queued;
  - the keys waiting for the slide;
  - `animate = no` ignored (claim 5 configures a 2 s slide beside it, so a
    default 150 ms slide cannot hide the fault);
  - the scene drawing no slide.

**P13.4 — the Dock and the menu bar across islands (S–M).**
- **The Dock.** `request_activate` on a window on another island switches
  that display to it first. A Dock click on a running application whose
  windows are elsewhere goes there. That is PRODUCT's fourth member.
- **The menu bar** gets an island status item: the island's name or number,
  and a menu of them, with the windows on each.
- **Verified by** `live-islands-dock.sh`:
  - click the Dock tile of an application on island 3 and island 3 is shown,
    with that window focused;
  - the menu bar's item switches islands.

✅ **P13.4 done 2026-10-01.**
- **`abyss_menubar_v1` v3**, privileged only:
  - `island` events (on bind and on every switch);
  - `list_islands`, answered with `window` events and `islands_done`, which
    carries every island's name;
  - `switch_island` and `activate_window`, by an id undertow gives every
    window.
- **The bar's island item** sits left of the status items. It shows the main
  display's island and appears only with more than one island. Its menu
  (`IslandMenu`) lists the islands, ticks the one shown, and puts each
  island's windows under it. Choosing an island shows it; choosing a window
  goes to it, wherever it is.
- **The Dock half** came in P13.1 (`bringToFront`) and is now tested live,
  through `ftctl`.
- **Found:** the client capped the global at v2 (HANDOFF §2.117).
- **Tests:** `live-islands-bar.sh` (6 claims) and 2 unit tests. Five faults
  injected and caught: the bar ignoring island events, the list without
  windows, choosing a window not switching, the Dock not switching, and an
  item shown with one island.

**P13.5 — Ebb (M–L).**
- **The layout** is a pure function, unit-tested:
  - every window on the scope, scaled down, none overlapping;
  - aspect kept;
  - **stable** (a window's slot does not jump when another opens);
  - near its real position, so the eye can follow it.
- **The view.**
  - Drawn by the scene with the existing `dst_box`, so thumbnails stay live
    (the windows keep their clocks).
  - Behind it the desktop is dimmed (the alpha array).
  - Titles appear on hover, in Aqua.
  - Click picks: that window is raised and focused, and everything goes back.
  - Escape or the key again puts everything back. Nothing is moved: it is a
    view.
- **Three scopes:** this island, every island on this display (the
  archipelago), and this application.
- **The keys and the corner** are §6.4 and §6.6.
- **Verified by:**
  - `live-ebb.sh`: no overlap in the captured thumbnails' rectangles, a click
    picks the right window, Escape restores every position exactly;
  - an Ebb over C2's eleven adversary clients, with C1 held (the bench);
  - goldens of the three scopes.

✅ **P13.5 done 2026-10-01.**
- **The layout** (`EbbLayout`) is a grid of the column count that shows the
  windows largest. Ties go to the grid whose cells are most the windows'
  shape, and a short last row is centred. It keeps aspect, never enlarges,
  and orders windows by island and then window id, so a new window does
  not reorder the others.
- **The view.** The scene draws the scope's windows (frames too) scaled
  from home to slot, with the desktop dimmed behind. It eases in and out
  over the slide's time, and Escape mid-way reverses from where it is.
  - The window under the pointer gets an Aqua-blue mark and its title on a
    dark plate (`EbbLabel`).
  - The scene gained solid fills and the alpha array. The alpha array's
    first use: in the archipelago, windows of islands not shown fade in
    where their slot is, because they have no home on screen to fly from.
- **Input.** While Ebb is open it has the pointer and the keyboard. Escape
  closes it; an Ebb key changes or closes it; an island key switches; no
  window hears anything.
- **Scopes:** F3 for the island, Ctrl-↑ for the archipelago, Ctrl-↓ for the
  focused application (§6.4).
- **Changed from the plan:**
  - Goldens of the scopes became pixel claims in `live-ebb.sh`: each slot's
    centre is its window's colour, and the screen after Escape equals the
    one before.
  - The frozen-thumbnail fallback was not needed: Ebb under C2's load held
    C1.
  - Arrow-key navigation is not in.
- **Known:** in the archipelago, windows of other islands show their last
  frame. They are suspended and on the 1 Hz clock, as an unseen window is.
- **Tests:**
  - `live-ebb.sh` (6 claims) and 2 unit tests;
  - `bench-islands.sh` gained ten Ebbs over the adversaries, counted, inside
    C1's budget;
  - six faults injected and caught: Ebb moving windows, the scene ignoring
    Ebb, keys leaking, a pick not going to the window, the archipelago
    without other islands, and the app scope showing other apps.

**P13.6 — Shoals (M–L).**
- **A shoal is a named set of windows on one island.** Membership is explicit:
  add the focused window, remove it, from the menu bar's item and by keys.
- **Recall** raises the set together, at the places `WindowPlaces` remembers,
  and **never moves or resizes anything else**. Others stay where they are.
- **The strip** is an Aqua layer surface along the left edge, with live
  thumbnails of the island's shoals. It is summoned by a key, or pinned
  (remembered); §6.7 decides the default.
- **Membership persists** by window key, like `windows.ini`, and is re-joined
  when the windows come back.
- **Verified by** `live-shoals.sh`:
  - make a shoal of three of five windows, scatter, recall, and the three are
    on top at their remembered places while the other two have not moved;
  - the strip shows it;
  - after a restart of the windows, the shoal re-forms.

**P13.7 — Islands in System Preferences (S–M).** An "Islands" pane:
- the count and names;
- the animation on or off;
- a picture per island (Wallpaper is already config-driven: per-island is a
  key);
- the keys shown, read from `keys.ini`.

Verified by `live-islands-pane.sh`, as the other panes are.

**P13.8 — the gate.**
- Both lanes, `--full`.
- **C6 on the 12700KF under load:**
  - `bench-islands` on DRM;
  - switches by keyboard with the adversary clients running, from the flight
    recorder;
  - an Ebb opened and dismissed under the same load, with C1 held.

---

## 4. The spikes

### 4.1 Alpha per texture in wlroots 0.20 — **there, on both platforms.**
`wlr_render_texture_options` has `const float *alpha` (`render/pass.h`), on
Linux and in the 16-CURRENT guest. No custom shader and no second pass.

### 4.2 Measuring C6 — **nothing exists; the design is P13.2's.**
The flight recorder has cadence, cost and misses, but no input stamp
(`FrameRecord`, `FlightRecorder.swift:16`). The C3 notion of input-to-photon
was never instrumented. P13.2 adds the stamp at the key handler and compares
seqs, which needs no clock on the input event beyond `Mono.now()` at arrival.

---

## 5. Verification

- **Each pass:**
  - its live test, green on Linux and in the 16 guest, fault-injected;
  - unit tests for every pure piece (the island predicate, the Ebb layout,
    shoal membership and recall).
- **C6 gates the build** from P13.2 on (`bench-islands` in the default lane).
  A number in a doc is not a contract; a failing build is.
- **Goldens** for the switcher, the menu-bar item, Ebb's three scopes, the
  strip and the pane, on both platforms.
- **Metal (P13.8)**, the one thing the harness cannot do: C6 against DP-1's
  real vblank with real input under load.

---

## 6. Risks and decisions

*All seven recommendations were adopted on 2026-10-01: (a) everywhere, with
6.2's Shift variant.*

**6.1 How many islands: fixed, or made on demand?**
- (a) A fixed count per display, default 4, set in the pane, so "Ctrl-3" always
  means the same place.
- (b) Made by asking and gone when empty, like Mission Control's "+", which
  makes the keys mean different things on different days.
- *Recommend (a).*

**6.2 Moving a window to another island: does the view follow it?**
- (a) Stay, and the window leaves.
- (b) Follow it there.
- *Recommend (a) for the key, which says where the window goes, not where you
  go, with Shift for (b).*

**6.3 Cmd-Tab across islands.**
- (a) Every window, and choosing one on another island goes there, the Dock's
  rule.
- (b) This island's windows only.
- *Recommend (a): "a window is never lost" is the point.*

**6.4 The keys.**
- Islands:
  - (a) Mac's: Ctrl-1…9 and Ctrl-←/→;
  - (b) Cmd-1…9, which applications already use.
- Ebb:
  - (a) F3 for this island, Ctrl-↑ for the archipelago and Ctrl-↓ for this
    application (Mission Control and App Exposé);
  - (b) 10.3's F9/F10/F11, which PC keyboards' media layers often take.
- *Recommend (a) for both.* Every key is a `keys.ini` row; this only sets
  defaults.

**6.5 The transition by default.**
- (a) A 150 ms slide, skippable.
- (b) An instant switch, with the slide offered in the pane.
- *Recommend (a).* C6 makes it free to the hand, and it tells the eye where
  it went.

**6.6 Hot corners.** 10.3 shipped Exposé on screen corners.
- (a) None in this phase.
- (b) One, bottom-left, Ebb (configurable in the pane).
- *Recommend (a)*: a corner fires by accident, and corners are a
  preference to add when somebody asks.

**6.7 The Shoals strip by default.**
- (a) Summoned (a key, or the menu bar's item).
- (b) Pinned along the left edge.
- *Recommend (a).* A pinned strip takes space on every display from every
  window, which is Stage Manager's first complaint. Pinning is a choice,
  remembered.

**Risk: hidden windows and GTK.** A GTK window told `suspended` behaves (U.2
was checked with GTK), but some applications draw anyway. They are counted
(`hiddenCommits`), not drawn, and cost only their own CPU.

**Risk: Ebb under adversaries.** A live thumbnail of a client that commits huge
buffers every frame scales a large texture. The scene already uploads per
commit; the bench in P13.5 is where this shows. A frozen thumbnail (the last
frame before Ebb opened) is the fallback.
