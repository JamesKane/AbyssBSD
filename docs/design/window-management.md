# Window management — tiling & floating

> Design elaboration for the **window-management gate** (`../ROADMAP.md`
> §5). It makes `../DESIGN.md` §7.7 implementable: the window-management
> core, the layout-policy seam, the tiling layout engine, the floating
> policy, key-chords, and the two coexisting policies.
>
> The WM core and the tiling engine come up with the compositor
> (Phase 5 / M1–M2); the floating GNOME-2 desktop follows at M3 (Phase 7).
>
> Status: closed for M1; M3 additions noted in §11.

---

## 1. Scope & principles

Window management is the **compositor's** (`DESIGN.md` §7.4, §11.1) — it
owns placement, focus, and stacking. §7.7 fixes the shape: AbyssBSD ships
**two first-class policies**, tiling and floating, over **one shared
window-management core**, from early on.

- **Tiling is the first face.** It needs only the compositor and a
  keyboard — no toolkit, no pointer-driven furniture — so it is usable the
  moment the compositor manages more than one window, at the minimal-UI
  stage (§9). It comes up with the compositor across M1–M2.
- **Floating is the shipped default.** Overlapping, pointer-placed windows
  are what the GNOME-2 desktop presents (§11.10) — the experience most
  users get. It and its furniture land at M3.

Principles, each load-bearing:

- **Mechanism, then policy.** The core is mechanism — the window model,
  focus, workspaces, input routing, the `configure` protocol. *How* windows
  are placed is policy, behind a defined internal seam (§4). The core never
  computes a tiled geometry itself.
- **The core is permanent.** The tiling WM is not throwaway scaffolding —
  it is the first consumer of the same core the GNOME-2 desktop then reuses
  (§7.7, §3.5: build the concrete thing, reuse it when the reuse is real).
- **Restraint.** Sway/i3 in spirit — fast, legible, keyboard-first, a
  small and well-specified feature set — and deliberately *not*
  Hyprland-style maximalism (§7.7, §3.5). Animation is not the product;
  the configuration surface is curated, not infinite.
- **One core, both policies coexist.** Tiling and floating are not session
  modes you reboot between — both are live in every workspace at once
  (§7).

---

## 2. The window-management core

The core is the compositor's policy-agnostic window logic. It owns:

- **the window model** (§3) — which windows exist, and where each sits;
- **focus** — exactly one focused window per seat;
- **workspaces** — a set per output (§10);
- **input routing** — matching key events against the binding table (§8),
  and routing pointer/keyboard to the focused surface otherwise;
- **the protocol** — it drives the §7.4 `configure` events (size, state,
  focus, output) and tells the compositor each window's **decoration
  mode**.

The core does **not** compute tiled geometry. It hands a workspace's
tiling tree and the output's work area to the **tiling layout engine**
(§4, §5) and emits the geometries the engine returns.

### 2.1 The core's state and entry points

The core's state, named — the data that §3 describes laid out:

```text
Wm {
  outputs   : Vec<Output>           // one per connected display
  focus     : Map<SeatId, WindowId> // exactly one focused window per seat
  bindings  : BindingTable          // §8
}
Output {
  id, geometry : Rect, work_area : Rect, scale : f64
  workspaces  : Vec<Workspace>      // per §10
  active_ws   : usize
}
Workspace {
  id
  tiling     : TilingTree           // §5
  floating   : Vec<FloatingWindow>  // §6
}
```

`WindowId` names a top-level surface — the §3 windows the WM model
manages. It corresponds to a display-protocol `SurfaceId` whose role is
`toplevel` (`interfaces/display.md`); popups, dialogs, and the other
non-toplevel roles do not appear in this model — see §3.

The compositor drives the core through a small entry-point set. Each call
returns the **events** the compositor should then emit on the display
protocol (`Configure`, `CloseRequested`) and an internal **decoration
hint** for each placed window:

```text
on_surface_added(WindowId, role, output_hint)         → Vec<WmEvent>
on_surface_destroyed(WindowId)                        → Vec<WmEvent>
on_role_set(WindowId, Role)                           → Vec<WmEvent>
on_input_event(SeatId, InputEvent)                    → Vec<WmEvent>
on_output_added(Output)  /  on_output_removed(id)     → Vec<WmEvent>
on_commit(WindowId, buffer_size)                      → ()    // client caught up to a Configure

enum WmEvent {
  Configure  { window, size, focused, output, scale, state }
  CloseRequested { window }
  Decorate   { window, mode: DecorationMode }    // internal — drives the compositor's chrome pass
}

enum DecorationMode {
  LeafBorder,                                    // a tiled or floating leaf
  ContainerHeader(HeaderKind),                   // a tabbed/stacked container header
  TitleBar,                                      // M3 — full GNOME-2 chrome on a floating window
}
enum HeaderKind { Tabs, Stack }
```

The `Configure` fields mirror `interfaces/display.md`'s `Configure`
message verbatim — this is the wire mapping. `Decorate` is internal: it
tells the compositor's chrome pass what to draw around the window and is
not part of the display protocol. The decoration *mode* is set by the
core (which container the window lives in, whether it is floating or
tiled); the compositor draws it.

The core is a **pure function** over `Wm` and its inputs: every entry
point is a `&mut self` method that mutates state and returns events. No
I/O, no FFI. That is what makes it host-testable alongside the §4
engine — see §11.

---

## 3. The window model

A **window** is a top-level surface (a §7.4 role). The model nests:
output → workspace → `{ a tiling tree, a floating list }`.

- A window is either a **leaf of the workspace's tiling tree** (tiled) or
  an **entry in its floating list** (floating). Never both; a WM command
  toggles it between the two (§7).
- **Popups, dialogs, and utility surfaces float regardless** — their role
  (§7.4) fixes it; the tiling tree holds only ordinary top-levels.
- A window in the **fullscreen** role (§7.4) takes its whole output; the
  layout for that output is suspended until it exits — and on multi-monitor
  this is per-output (§7.6, §10), so a game scans out fullscreen on one
  monitor while the others keep their layouts.

Focus is a single window per seat. Focus follows WM navigation (§5, §8)
and, in the floating policy, the pointer and clicks (§6).

---

## 4. The layout-policy seam

§7.7's "bounded module behind a defined internal seam" is the **tiling
layout engine**. The seam is one trait — the contract the §11
`crates/abyss-wm-layout` crate satisfies and the WM core invokes per
workspace per relayout:

```text
trait LayoutEngine {
    fn layout(&self, tree: &TilingTree, work_area: Rect) -> LayoutResult;
}

struct LayoutResult {
    placements : Vec<Placement>,   // one per leaf in `tree`
    headers    : Vec<Header>,      // one per Tabbed/Stacked container
}
struct Placement { window : WindowId, rect : Rect, decoration : DecorationMode }
struct Header    { container : ContainerId, rect : Rect, kind : HeaderKind, tabs : Vec<TabEntry> }
struct TabEntry  { window : WindowId }   // title looked up by the compositor — see §5
```

`work_area` is the output's rectangle minus reserved struts (§10). Every
**visible** leaf in `tree` appears in exactly one `Placement` — the hidden
children of a `Tabbed` / `Stacked` container appear only in that
container's `Header.tabs`, with no geometry until they become focused.
Every `Tabbed` or `Stacked` container appears in exactly one `Header`. The WM core takes the
result, emits a `Configure` per `Placement.window` (`size = rect`,
`focused = (window == focus)`) and a `Decorate` per placement and header
(§2.1).

The engine is **pure geometry**: a tree and a rectangle in, a set of rects
out. No surfaces, no I/O, no compositor state. That has two payoffs:

- It is a **bounded, replaceable module** — the §7.7 seam — small enough to
  hold in one's head and to swap.
- It is **host-testable**. Although the compositor that hosts it is Phase 5
  (FreeBSD, DRM/KMS), the engine's logic — tree → rects — is ordinary Rust
  and is unit-tested on the host, like every Phase 0–3 crate.

**Floating needs no engine.** A floating window has free geometry the core
stores directly; placement and move/resize are §6. The seam exists for the
one genuinely non-trivial layout — tiling.

---

## 5. The tiling layout engine

Sway/i3-grade. A workspace's tiling layout is a **tree** of leaves and
containers:

```text
enum TilingNode {
    Leaf(WindowId),
    Container(Container),
}
struct Container {
    id       : ContainerId,
    layout   : ContainerLayout,
    children : Vec<Child>,        // declaration order = visual order
    focused  : usize,              // index into `children`
}
struct Child { node : TilingNode, ratio : f32 }   // ratio used iff layout ∈ {SplitH, SplitV}
enum ContainerLayout { SplitH, SplitV, Tabbed, Stacked }

struct TilingTree { root : Option<TilingNode> }
```

- A **split** container (`SplitH` / `SplitV`) lays its children side by
  side — left-to-right or top-to-bottom — dividing its rectangle by the
  per-child `ratio`. Ratios within a container sum to 1.
- A **tabbed** / **stacked** container overlays its children: one is
  visible (the `focused` child) and the rest are reachable by a header
  strip — tabs across the top for `Tabbed`, a title stack for `Stacked`.
  Recursion down the tree yields every leaf's rect. Windows fill the
  output without overlap.

**The operation set** — closed, the only mutations the core invokes:

```text
fn focus_move (&mut TilingTree, Direction) -> Option<WindowId>
fn split      (&mut TilingTree, Orientation)               // wraps the focused leaf
fn set_layout (&mut TilingTree, ContainerLayout)           // on the focused leaf's container
fn move_leaf  (&mut TilingTree, Direction)                 // within the tree
fn resize     (&mut TilingTree, Edge, delta: f32)          // at the focused container's edge
fn insert     (&mut TilingTree, WindowId)                  // see "New windows" below
fn remove     (&mut TilingTree, WindowId)
```

`Direction = Left | Right | Up | Down`; `Orientation = Horizontal |
Vertical`; `Edge = Left | Right | Top | Bottom`. Cross-workspace `move`
(to an adjacent workspace) is core-level, not engine-level — the engine
mutates one tree.

**New windows** are inserted by the core via `insert`, which places them
as a **sibling of the focused leaf in its container** — so opening a
window is predictable and keyboard-reachable (the i3 model). If the
workspace is empty, the new window becomes the root leaf.

**Decoration** is server-side (`DESIGN.md` §7.4) and follows the layout:
each `Placement` carries `DecorationMode::LeafBorder` (a thin border);
each `Tabbed` or `Stacked` container yields a `Header` of the matching
`HeaderKind`. The header rect is reserved out of the container's rectangle
before its children are laid out. Header title text comes from the WM
core's per-window `SetTitle` state (`interfaces/display.md`) — the engine
records which `WindowId`s the header refers to and the compositor draws
the titles.

---

## 6. The floating policy

Conventional overlapping windows — the GNOME-2 placement (§11.10) and the
shipped default (§3.3).

- **Placement.** A new floating window is placed by the core on the
  **active output** (§10) — centered, and cascaded to avoid landing exactly
  on another.
- **Stacking.** A per-workspace z-order; focusing a window raises it.
- **Move & resize** are compositor-side (§7.4): a title-bar drag moves, a
  border drag resizes — handled with no client round-trip, so window
  manipulation is frame-perfect (§3.6).
- **Decoration** is the full GNOME-2 title bar with the min/max/close
  buttons (§7.4).

Floating geometry is free; the core stores each floating window's rect
directly. There is no layout engine to consult (§4):

```text
struct FloatingWindow {
    window : WindowId,
    rect   : Rect,        // free geometry, stored directly on the core
    z      : u32,         // per-workspace stacking order; focus raises
}
```

A workspace's `floating: Vec<FloatingWindow>` is sorted by `z`. Focus
raises by setting the focused window's `z` above every other in the
workspace (§7's `float-toggle` moves a window between this list and the
tiling tree).

---

## 7. Coexistence & the two experiences

Tiling and floating are **not** session modes. Every workspace holds a
tiling tree *and* a floating list at once: a workspace may have tiled
windows filling it with floating windows on top, exactly as i3/Sway do. A
`float-toggle` command moves the focused window between the tree and the
floating list. Popups and dialogs always float (§3).

What makes the **tiling experience** and the **desktop experience** feel
distinct is therefore not a mode but two pieces of §11.5 configuration:

1. **the default placement** for a new top-level — tiled, or floating;
2. **which shell furniture is shown** — the minimal bar, or the full
   GNOME-2 panels (§9).

The **tiling experience** (tiled default, minimal bar) is the first to
exist and is usable from the minimal-UI stage — keyboard-only, no toolkit.
The **desktop experience** (floating default, full panels) is the M3
shipped default. One core, one shell component (§9), two configurations.

---

## 8. Key-chords & WM commands

Bindings are **configuration** (§11.5), never compiled in.

**Matching.** The input service interprets the keymap and emits keysym +
modifiers (§7.5). The compositor matches each key event against the
**binding table**; on a match it performs the action and consumes the
event — otherwise the event passes to the focused surface. This is the same
chord-matching the compositor uses for global shortcuts (§13); a WM binding
is the case where the matched action is internal.

**Chords, sequences, modes.** A chord is a modifier set plus a key.
*Sequences* — a chord, then another — and *modes* — a named prefix state
that re-scopes the keys that follow, i3's "mode" (a `resize` mode where the
arrow keys resize) — are both supported.

**The action vocabulary** is a **closed, curated set** (restraint, §7.7) —
the engine operations of §5, plus the core-level commands:

```text
enum Action {
    // engine (§5)
    FocusMove(Direction)  | Split(Orientation) | SetLayout(ContainerLayout)
    MoveLeaf(Direction)   | Resize(Edge, f32)
    // core
    Workspace(WorkspaceSelect)   // switch to N, or move focused window to N
    FloatToggle                   // §7
    FullscreenToggle
    Close                         // sends CloseRequested to the focused window
    EnterMode(ModeName)           // §8 modes
    ExitMode
    Spawn(AppId)                  // delegated to the broker (§5.6, broker-and-transport)
}
```

The set is small and fixed. "Power-user-first" is the *input model* — it is
not licence for a thousand knobs (§7.7).

**The binding-table schema.** The settings tree (`interfaces/settings.md`)
holds:

```text
wm.bindings.<name>       : string    // a chord-string, e.g. "mod+shift+Return"
                                      //   value names the Action it triggers
wm.modes.<mode>.bindings.<name> : string   // bindings active inside a named mode
```

Chord-string grammar: a `+`-separated modifier list (`mod`, `shift`,
`ctrl`, `alt`) ending in a keysym (`Return`, `q`, `Left`). A sequence is
a chord-string with a space between chords (`mod+a space`). The settings
service holds the table; the compositor reads `wm.*` at startup and
subscribes to it (§11.5 retained-sink subscription).

**M1 ships chords only.** Sequences and modes are part of the design but
not part of M1's implementation — the M1 compositor matches chords
against the **default binding table** compiled in (§11). Sequences,
modes, and settings-backed override land with the settings service in
Phase 7 / M3.

---

## 9. The bar

The tiling experience's **bar** — the workspace list, the focused-window
title, the status indicators — *is the desktop shell* (§11.10) in a minimal
configuration. The GNOME-2 panels are that same component, fuller: one
furniture component, scaled to the experience (§11.10).

The compositor exposes the WM state the bar renders — the per-output
workspace list and which is active, the focused window's title, the layout
mode — over the display protocol, through the shell-scoped capability
(§11.10).

The bar is **not a dependency** of the tiling WM: the tiling experience
functions with only the compositor and a keyboard (§7.7). The bar is the
at-a-glance surface, added when the shell exists — not a prerequisite.

---

## 10. Multi-monitor

Per §7.6, the outputs form one coordinate space, but window management is
**per-output**:

- **Workspaces belong to outputs** (the i3 model) — each output has its own
  set; switching a workspace affects one output.
- The rectangle the tiling engine fills (§4) is that output's **work area**
  — the output minus any bar/panel struts.
- **Moving a window to a workspace on another output** carries it across.
- On output hotplug-disconnect (§7.6) a workspace and its windows
  **migrate** to a surviving output.
- A new window opens on the **active output** — the one with the focused
  window, else the pointer's.

---

## 11. Milestones & what each phase builds

| Milestone | Phase | Window management |
|---|---|---|
| **M1** | 5 | The WM core (§2), the tiling layout engine (§4–§5), and the chord matcher (§8 on the default binding table) come up with the CPU-backend compositor. Per-output workspaces (§10), focus, input routing (§2.1) all work. Keyboard-driven tiling works the moment the compositor manages more than one window — over the minimal-UI stage (§9), with no toolkit and no bar. |
| **M2** | 6 | The same WM, unchanged, on the GPU compositor. |
| **M3** | 7 | The floating policy's pointer-driven move/resize furniture (§6 — title-bar drag, min/max/close, cascaded placement); the GNOME-2 desktop (floating default plus the shell's full panels, §9); settings-backed bindings (§8) and the sequences/modes the chord matcher gains then; global shortcuts (`DESIGN.md` §13). The floating *model* exists from M1 (dialogs float, §3); the pointer *experience*, panels, and settings-backed bindings are M3. |

**The engine is a host-buildable crate.** The tiling layout engine
(§4–§5) is pure geometry — a tree and a rectangle in, rects out — and
the §4 `LayoutEngine` trait is its public contract. It lives in
**`crates/abyss-wm-layout`**, a Phase-0-style host crate: built and
unit-tested on macOS, alongside the existing `abyss-msg`, `abyss-render`,
and `abyss-toolkit`. It is the first piece of Phase 5 code, landing
before the FreeBSD `abyss-compositor` crate exists.

The WM **core** (§2.1) is also pure-logic — `&mut Wm` in, `Vec<WmEvent>`
out, no I/O — and is unit-tested host-side in the same crate
arrangement: either alongside the engine in `abyss-wm-layout`, or as a
sibling host crate `abyss-wm-core`. The compositor links both and adds
only the I/O (display protocol, input service, DRM/KMS) on top.

---

## 12. Deferred

- **The display protocol details** — surface roles, the `configure`
  events, server-side decoration drawing — are `interfaces/display.md`,
  the Phase-5 display gate. The WM design and the display protocol
  co-design: the `configure` set here shapes that schema.
- **The binding-table schema** is pinned in §8 — the `wm.bindings.*` and
  `wm.modes.*` subtree, and the chord-string grammar. Formalized into
  `interfaces/settings.md` when the settings service lands (Phase 7);
  M1's compositor reads from a compiled-in default table.
- **The bar / panel rendering** is the shell (§11.10, `interfaces/shell.md`)
  — the Phase-7 shell gate.
- **Global shortcuts** (§13) share this chord matcher; their non-WM action
  set is designed with the shell.
- **Animation** is deliberately minimal (§7.7 restraint) and is not
  designed here.
