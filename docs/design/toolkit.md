# The toolkit & 2D renderer

> Design elaboration for **Gate C** (`../ROADMAP.md` §5). It makes
> `../DESIGN.md` §7.3 and §8 implementable: the 2D renderer and its
> backend seam, the view arena and `ViewId` model, the retained view tree,
> the layout algorithm, the widget set, and the no-callbacks event model.
> The foundation for **Phase 3** — the `abyss-render` and `abyss-toolkit`
> crates.
>
> Status: draft.

---

## 1. Scope & principles

The toolkit is a **library** linked into every UI process (§11.1), not a
service. It draws the *widgets* — the controls inside a window — to the
GNOME-2 appearance; window decorations are the compositor's (§7.4) and the
panel/menu/window-list are the shell's (§11.10).

Principles, each load-bearing:

- **Retained mode.** The view tree persists across frames; only the *dirty*
  set is re-laid-out and repainted (§3.6, §8). The desktop stays bounded by
  the refresh rate, not by busywork.
- **An arena of views, addressed by handle.** No pointer tree, no
  reference-counted nodes. One arena per window owns every view; every
  cross-reference is a generational `ViewId` (§4). No `Rc`/`Arc` in the
  resident set, no dangling, no leaks (§8).
- **No stored callbacks.** A widget interaction is not an `on_click`
  closure in the tree — it is a `ViewId` that emits a *message* (§8).
- **The CPU/GLES seam is at the drawing API** (§7.3). The minimal-UI
  terminal and the §9 recovery floor must draw *before*, and independently
  of, Mesa.
- **One curated widget set, one shared theme.** Closed and deliberate
  (§3.3); GNOME 2 (§7, §9).
- **Hold it in your head** (§3.5). A box layout, not a constraint solver;
  an immediate canvas, not a retained scene graph below the toolkit.

Phase 3 builds this entirely **host-testable on macOS**: the CPU backend
renders into an ordinary memory buffer, so golden-image comparison works
with no FreeBSD and no GPU.

---

## 2. The crate split

- **`abyss-render`** — the 2D renderer: the `Canvas` drawing API, the
  `RenderBackend` seam, the CPU backend, and text rendering (§3).
- **`abyss-font`** — the font-stack binding: shaping and glyph
  rasterization over freetype + harfbuzz, through a C shim (§3.3). Split
  out so `abyss-render` keeps `#![forbid(unsafe_code)]`.
- **`abyss-toolkit`** — the Interface Kit: the view arena and `ViewId`, the
  retained tree, the layout algorithm, the widget set, theming, and damage
  tracking (§4–§10). Depends on `abyss-render` (drawing) and `abyss-msg`
  (UI events as messages).

The BeOS **Kits** (§8) map on as follows: the **Interface Kit** is
`abyss-toolkit`; the **Application Kit** — app lifecycle, the looper/handler
model, messaging — is the already-built `abyss-looper` and `abyss-msg`; the
**Storage Kit** and **Media Kit** are later crates (§13).

---

## 3. The 2D renderer & the drawing-API seam

### 3.1 The `Canvas`

`abyss-render` exposes a **NanoVG-style immediate-mode 2D vector API** — the
`Canvas`:

- a **path** builder — move/line/bezier/arc, and rounded-rect;
- **paints** — solid color, and linear / radial gradient;
- **`fill`** and **`stroke`**;
- a **transform** stack and a **clip** (scissor) stack, with `save`/`restore`;
- **text** (§3.3).

The `Canvas` is *immediate*: it retains no scene. Retention is the
toolkit's job — the view tree (§5). Each paint pass, the dirty views issue
`Canvas` calls; nothing below the toolkit is retained. One place holds the
persistent state, and it is the place that tracks what changed.

### 3.2 The backend seam

The `Canvas` drives a **`RenderBackend`** — the seam §7.3 places "up at the
toolkit's drawing API". Two backends, one API:

- **CPU** — a software rasterizer (scanline coverage, analytic
  anti-aliasing) producing an ARGB pixel buffer. It needs **zero GPU
  stack**: the §9 recovery floor and the minimal-UI terminal render on it.
- **GLES** — tessellates paths to triangles and submits them through Mesa;
  the accelerated path. Phase 6 (Gate G).

Phase 3 builds the **CPU backend only**; the seam is designed now so the
GLES backend drops in behind an unchanged `Canvas`. The CPU backend's
output is an ordinary `Vec<u32>` — which is exactly what makes Phase 3
host-testable: render a scene, hash the buffer, diff against a golden
image, all on macOS.

### 3.3 Text

The font stack is **freetype + harfbuzz** — FreeBSD ports (§11.2), not
reimplemented. The pipeline: *harfbuzz* shapes a string into positioned
glyphs, *freetype* rasterizes a glyph into a coverage bitmap. Rasterized
glyphs are cached in a **glyph atlas**; `Canvas::text` shapes the run,
ensures its glyphs are in the atlas, and blits them. (*fontconfig* —
selecting a face by name — is deferred; `abyss-font` loads a font by file
path, and name resolution comes with the `Theme` work, §9.)

**As built.** The stack is bound through a small **C shim**
(`crates/abyss-font/c/font_shim.c`), *not* `bindgen`: the C compiler owns
freetype's struct layouts, so none is transcribed into Rust, and there is
no `libclang` build requirement. `abyss-font`'s `build.rs` compiles the
shim by invoking the system toolchain — `cc` (clang on macOS and the BSDs)
and `ar` — directly, with no build-dependency crate; `abyss-font` has no
dependencies at all. The binding lives in its own crate so `abyss-render`
stays `#![forbid(unsafe_code)]`. Host testing links the system stack
(Homebrew on macOS), for parity with the FreeBSD ports.

---

## 4. The view arena & `ViewId`

A window's view hierarchy is **an arena of views addressed by handle**
(§8) — never a tree of pointers or reference-counted nodes.

- **`ViewId(u32)`** — a generational handle: an *index* and a *generation*,
  16 bits each (65 536 views per window, 65 536 generations before a slot's
  generation wraps; the split is an `abyss-toolkit` constant).
- **One `Arena` per window** owns every view — the slotmap pattern: a
  `Vec<Slot>`, each `Slot { generation, Option<View> }`. `insert` returns a
  `ViewId`; `remove` empties the slot and bumps its generation.
- **`arena.get(id)` generation-checks.** A `ViewId` that has outlived its
  view — the slot reused, or emptied — resolves to `None`: safe and
  observable, never a dangling pointer, never a leak (§8).

Every cross-reference is a `ViewId`: a view's parent and children, the
input focus, an event's target, a layout relation, an app's handle to a
widget it created. The tree is **single-ownership** — the arena owns;
walks take transient borrows that do not outlive the walk — so there are no
ownership cycles and **no `Rc`/`Arc`** in the resident set (§8, §3.6). The
`ViewId` is also the internal handle behind a scripting `SpecifierPath`
(§6.6, `interfaces/toolkit.md`).

---

## 5. The retained view tree

A **`View`** in the arena holds:

- its **widget** — the behavior and state (§7);
- its **children** (a list of `ViewId`) and its **parent** (`ViewId`);
- its **layout box** — the rect it was arranged into, and its measured
  sizes (§6);
- **dirty flags** — `needs-measure` and `needs-paint`.

The tree is **retained** — it persists across frames. A change marks the
minimal dirty set; an untouched subtree is neither re-measured nor
repainted (§3.6). That is the whole point of retained mode, and §10 is it
made concrete.

---

## 6. The layout algorithm — two-pass box layout

Layout is a **box model**, run in two passes:

- **Measure** (bottom-up) — each view computes its *preferred* and
  *minimum* size from its children and its own content.
- **Arrange** (top-down) — each container assigns each child a rectangle
  within its own, distributing any slack.

A view's **sizing policy**: `(min, preferred)` per axis, an **`expand`**
flag (whether it consumes slack), and an **alignment** (where it sits in
extra space when it does not expand). The container widgets are the box
primitives — `Row`, `Column`, `Grid`, and a single-child `Padding`/`Align`
(§7).

**Dirty propagation.** A content change marks `needs-measure`, which
propagates *up* — an ancestor's preferred size may change — until it
reaches a view whose size is unaffected. `arrange` then runs *down* over
that affected subtree only. An unaffected subtree runs neither pass.

No constraint solver (Cassowary and its kin). A box model is predictable,
fast, retained-friendly, and small enough to hold in one's head (§3.5) —
and it is what GNOME 2 itself used.

---

## 7. Widgets — the Interface Kit set

A **widget** is the behavior and state behind a `View`. Each widget
defines three things, and no more:

- how it **measures** — its content's preferred size (§6);
- how it **paints** — `Canvas` calls within its rect (§3);
- how it **handles input** — and what UI event that yields (§8).

A widget stores **no callbacks** (§8).

The v1 widget set is **curated and closed** (§3.3) — adding a widget is a
deliberate decision, not drift:

- **Containers** — `Row`, `Column`, `Grid`, `Padding`/`Align`, `ScrollView`.
- **Display** — `Label`, `Image`/`Icon`.
- **Controls** — `Button`, `Checkbox`, `RadioButton`, `Slider`, `TextField`.
- **Collections & structure** — `ListView`, `TabView`, `Menu` (per-window
  menus — GNOME 2 and BeOS both, §11.10).
- **`Custom`** — a view whose `paint` and input handling are app-supplied:
  the escape hatch for the terminal's VT grid and any app-specific drawing.

The set covers the M3 GNOME-2 desktop and the M4 core apps. It grows by
decision, never by accretion (§3.5).

---

## 8. Input, events, and the no-callbacks rule

A window-looper receives input as messages from the compositor (§7.4). The
toolkit **routes** each event to a view — pointer events by hit-testing the
tree, keyboard events to the focused `ViewId` — and the view's widget
handles it.

A widget interaction does **not** invoke a stored closure. It produces a
**UI event** — a value: `Clicked(ViewId)`, `Toggled(ViewId, bool)`,
`TextChanged(ViewId, String)`, and so on — which the toolkit surfaces to
the window's handler **as a message** (§8, §6.9). The application logic is
an ordinary looper `Handler` (Phase 2) that matches on those messages.

This is §8's rule, and it earns its place. A button is not an `on_click`
closure buried in the tree; it is a `ViewId` that, when clicked, *emits a
message*. There is no hidden control flow to trace (§3.5); the interaction
is an inspectable value; and the per-window arena stays genuinely
share-nothing (§6.10), because it holds no closure that could reach
outside it.

---

## 9. Theming

Widgets paint by reading a **`Theme`** — a value: a *palette* (background,
foreground, accent, selection, …), *metrics* (padding, border widths,
control sizes), and *font selections*. The default theme is the **GNOME 2**
appearance (§8, §3.3).

The theme is **shared**. The compositor's server-side decorations (§7.4),
the toolkit's widgets, and the shell's furniture (§11.10) all draw from one
theme, so the desktop is visually coherent — that is §8's "one shared
theme." It is a serializable value carried through the settings service
(§11.5); its concrete schema is settled with the settings and shell work
(§13).

---

## 10. Damage & repaint

The toolkit tracks a `needs-paint` flag per view. A paint pass repaints
exactly the dirty views, each clipped to its rect; the **union of those
rects is the damage region**, committed to the compositor alongside the
buffer (the §7.4 protocol stages buffer + damage together).

An idle window — no dirty views — paints nothing and commits nothing
(§3.6: the idle desktop does no work). Damage tracking is the retained-mode
payoff (§5) made concrete: work is proportional to what changed, never to
the size of the tree.

---

## 11. The looper integration — a window is a looper

A **window is a looper** (`abyss-looper`, Phase 2; §6.10, §8). Its handler
owns that window's `Arena` — per-window, single-threaded, share-nothing
state (§6.10). The flow:

1. Input events and frame callbacks arrive as **messages** to the window
   looper.
2. On an input message, the handler runs the toolkit's input routing (§8);
   the resulting **UI events** reach the application's handler logic as
   messages.
3. The application logic mutates widget state through the arena, marking
   the dirty set.
4. On a frame callback (§7.4), the handler runs layout over the dirty
   subtrees (§6) and paint over the dirty views (§10) into a `Canvas`, then
   commits the buffer and damage to the compositor.

The toolkit itself is mostly **looper-agnostic**: the arena, layout,
widgets, and painting are ordinary functions over an `Arena` and a
`Canvas`. That is deliberate — it is what makes them host-testable. A thin
integration layer binds them to a looper `Handler`.

---

## 12. What Phase 3 builds

This document is complete enough to build Phase 3 with no further design.

**`crates/abyss-render`** — the `Canvas` API and the `RenderBackend` seam
(§3); the **CPU backend** (software rasterizer + glyph atlas); the
font-stack FFI. *Host-testable:* golden-image tests — render a scene into a
`Vec<u32>`, diff against a checked-in image.

**`crates/abyss-toolkit`** — the `Arena` and `ViewId` (§4), the retained
`View` tree (§5), the two-pass box layout (§6), the curated widget set
(§7), input routing and UI events (§8), the `Theme` (§9), and damage
tracking (§10). *Host-testable:* the arena (generational handles, stale →
`None`), layout (a tree in, rects out), measure, input dispatch, and damage
are pure and unit-tested; widget painting is golden-image tested.

Also Phase 3, but **app-level and outside this toolkit doc**: the
**terminal's VT / escape-sequence parser** — the M1 terminal grows, drawing
through a `Custom` view (§7).

`cargo xtask ci` runs all of it.

---

## 13. Deferred

- **The GLES backend** — Phase 6, Gate G.
- **The Storage Kit and Media Kit** (§8) — later crates; typed attributes
  and live queries are post-v1 (§11.16).
- **The concrete `Theme` schema** — settled with the settings and shell
  work (§9, §11.5).
- **Scripting** — the `SpecifierPath` → `ViewId` resolution surface is
  `interfaces/toolkit.md` (Gate H).
- **Rich text & IME** — complex text input (CJK composition) is a separate
  later design (§7.5); §3.3's `TextField` is plain text in v1.
- **`fontconfig`** — selecting a font face by name. `abyss-font` loads a
  font by file path; name resolution comes with the `Theme` work (§9).
