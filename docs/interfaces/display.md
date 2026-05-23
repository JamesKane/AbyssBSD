# Display protocol — interface schema

> Concrete message schema for the **display protocol**. Shape: `DESIGN.md`
> §7.4. Conventions: `interfaces/README.md`. Status: M1 subset pinned; full
> schema ships through M3. See *Milestone subsets* below.

## Interface

- **Exported by** — the compositor (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §7.4.
- **Consumed by** — every GUI app, and the desktop shell (with a
  shell-scoped capability — see *Capabilities*).
- **Interface id** — `display`.

The largest interface. It is native, not Wayland (`DESIGN.md` §7.2), and is
designed around two first-class cases: ordinary composited windows, and
full-screen games that scan out directly. Window decorations are
**server-side** — the compositor draws every title bar and frame; a client
never draws chrome.

## Milestone subsets

The full schema is what Phase 5 / 6 / 7 / 8 add up to; the M1 compositor
implements a strict subset. Each message group below carries an inline
milestone tag — **M1**, **M2**, **M3** — naming the milestone that brings
it. The line below ties the cuts together.

- **M1** (Phase 5, CPU compositor) — *outputs* (lifecycle), *surfaces*
  (toplevel only), *frames* (with `Buffer = Shm`), *window management*
  (`Configure` / `CloseRequested` / `RequestState`), *input* re-delivery
  (keyboard, pointer; `PointerEnter` / `PointerLeave`).
- **M2** (Phase 6, GPU compositor) — `Buffer = Dmabuf` and the
  `SyncPoint`-bearing acquire/release path; direct scanout
  (`ScanoutActive` / `ScanoutInactive` / `SetPresentMode`).
- **M3** (Phase 7, toolkit + shell) — clipboard & drag-and-drop, the
  shell-scoped messages (`ListWindows` / `ActivateWindow` /
  `ReserveStrut`), `LockPointer` / `UnlockPointer`. Touch / Gesture /
  Tablet input land when hardware is on the reference box.

**Gate E co-design**, settled here:

- **No configure-serial in M1.** `Configure` carries no serial; the
  client's next `Commit` *is* the ack. The window-management core learns
  a client has caught up via its `on_commit(buffer_size)` entry point
  (`docs/design/window-management.md` §2.1). M3 may add `ConfigureAcked`
  if interactive resize needs precise rejection of stale `Commit`s;
  cheap to retrofit.
- **No decoration on the wire.** Decoration is internal to the compositor
  — the `Configure`'d `size` is the client's drawable area, and the
  compositor draws every border, header, and title-bar around it
  (`DecorationMode` in `window-management.md` §2.1). The wire never
  carries a decoration mode.
- **The `Configure` field set** — `surface`, `size`, `focused`, `output`,
  `scale`, `state` — is sufficient for the window-management core; no
  M1 additions.

## Data types

- **`SurfaceId`** — a surface, scoped to the client's `Cap<Display>`
  connection. (Surfaces are ids within the connection, not separate
  capabilities.)
- **`OutputId`** — a display output.
- **`Rect`**, **`Region`** — geometry, in output-logical pixels.
- **`Role`** — `enum { toplevel } | popup{ parent : SurfaceId, at : Rect }
  | fullscreen{ output : OutputId }`.
- **`Buffer`** — a tagged union, one variant per backend:
  - `Shm    { fd : handle, format : u32, stride : i32, width : i32, height : i32 }` — **M1**. A CPU buffer (a `memfd` / `SHM_ANON` shared with the compositor). The compositor `mmap`s it for read.
  - `Dmabuf { fd : handle, format : u32, modifier : u64, width : i32, height : i32 }` — **M2**. A GPU-allocated buffer with a DRM format modifier.
  `format` is a 32-bit FOURCC (`XRGB8888`, `ARGB8888`, …) — common to both variants. The M1 compositor accepts `Shm`; an `Shm`-only compositor rejects a `Dmabuf` with `invalid-buffer`.
- **`SyncPoint`** — `{ semaphore : handle, value : u64 }` — a timeline-
  semaphore point (`DESIGN.md` §7.4, explicit synchronization). **M2** —
  only `Dmabuf` buffers carry sync; `Shm` is `mmap`-coherent and rides
  the request/reply ordering.
- **`Output`** — `{ id, width, height, refresh : i32, scale : f64,
  scanout-formats : list<{format,modifier}>, vrr : {min,max}? }`.
- Input event types — `Key`, `PointerMotion`, … — are **as defined in
  `input.md`**; the display protocol re-delivers them to the focused
  surface (see *Input*).

## Messages — outputs (compositor → client) — **M1**

```
OutputAdded   — event   output : Output
OutputChanged — event   output : Output
OutputRemoved — event   id : OutputId
```
On connect the compositor sends `OutputAdded` for each current output, then
hotplug events thereafter.

## Messages — surfaces (client → compositor) — **M1**

```
CreateSurface  — request                        → SurfaceId | Error
SetRole        — command   surface : SurfaceId   role : Role
SetTitle       — command   surface : SurfaceId   title : string
DestroySurface — command   surface : SurfaceId
```
`SetTitle` text is drawn by the compositor in the server-side title bar.
M1 accepts only `Role::toplevel`; `popup` and `fullscreen` are M2 / M3
(popups land with the toolkit; `fullscreen` rides the direct-scanout
work).

## Messages — frames — **M1** (with `Shm` buffers; `SyncPoint` is M2)

```
Commit    — command (client → compositor)
  surface : SurfaceId   buffer : Buffer   damage : Region   acquire : SyncPoint?
Released  — event (compositor → client)   surface : SurfaceId   buffer : Buffer   release : SyncPoint?
Presented — event (compositor → client)   surface : SurfaceId   time : Time
FrameDone — event (compositor → client)   surface : SurfaceId
```
One `Commit` per frame: the surface's new `buffer` is ready when `acquire`
signals. The compositor returns `Released` (the buffer may be reused once
`release` signals), `Presented` (the frame reached the display, with timing
— for pacing), and `FrameDone` (a good moment to render the next frame).

`SyncPoint` is omitted on M1 `Commit`/`Released` (the `?` above) — `Shm`
buffers are `mmap`-coherent: the `Commit` envelope's arrival order is the
ordering, and the compositor's `Released` event is when the client may
reuse the buffer. The field becomes required on M2 `Dmabuf` `Commit`s.

`Buffer`'s `Shm` variant lands at M1 (CPU compositor), the `Dmabuf`
variant at M2 (GPU path) — see *Data types*.

## Messages — window management (server-side decorations) — **M1**

```
Configure      — event (compositor → client)
  surface : SurfaceId   size : Rect   focused : bool   output : OutputId   scale : f64
  state : enum { normal, maximized, fullscreen, minimized }
CloseRequested — event (compositor → client)   surface : SurfaceId
RequestState   — command (client → compositor)
  surface : SurfaceId   state : enum { normal, minimize, maximize, fullscreen }
```
The client renders to the `Configure`d `size` and `Commit`s. `CloseRequested`
fires when the user clicks the compositor-drawn close button — the client
should shut the window down. Title-bar drags and the min/max/close buttons
are handled compositor-side with no client round-trip; the client only sees
the resulting `Configure` / `CloseRequested`.

The M1 compositor sends `Configure` and `CloseRequested` from its WM core
(`docs/design/window-management.md` §2.1); the M1 compositor accepts
`RequestState` (used by `Action::FullscreenToggle`). The min/max title-bar
furniture that emits client-driven `RequestState`s is M3 — at M1 these
states change via WM key-chords (§8 of `window-management.md`).

## Messages — input (to the focused surface) — **M1** (Key, Pointer*; Touch / Gesture / Tablet later; LockPointer M3)

The compositor delivers `Key`, `PointerMotion`, `PointerButton`,
`PointerScroll`, `Touch`, and `Gesture` events — the shapes defined in
`input.md` (including `Key`'s raw `keycode` alongside the cooked
interpretation) — to the surface that holds focus. Additionally:

```
PointerEnter — event (compositor → client)   surface : SurfaceId   at : Rect
PointerLeave — event (compositor → client)   surface : SurfaceId
LockPointer  — request (client → compositor) surface : SurfaceId   → Ack | Error
UnlockPointer— command (client → compositor) surface : SurfaceId
```
`LockPointer` confines the pointer to the surface and switches it to
relative-only motion — for FPS games and similar. Keyboard focus is the
`focused` field of `Configure`.

**M1** carries `Key`, `PointerMotion`, `PointerButton`, `PointerScroll`,
`PointerEnter`, `PointerLeave` — the minimum a terminal in a tiling WM
needs. `Touch`, `Gesture`, `Tablet` await hardware on the reference box.
`LockPointer` / `UnlockPointer` are **M3** (games-adjacent — no consumer
on M1).

## Messages — clipboard & drag-and-drop — **M3**

Compositor-mediated and **authorized by the user's gesture** (`DESIGN.md`
§7.4); no client reads a selection ambiently.

```
OfferSelection — command (client → compositor)
  surface : SurfaceId   types : list<string>   source : Cap
Paste          — request (client → compositor)
  surface : SurfaceId   type : string          → bytes | Error
StartDrag      — command (client → compositor)
  surface : SurfaceId   types : list<string>   source : Cap   icon : Buffer?
DragEnter / DragMotion / DragLeave — event (compositor → client)
  surface : SurfaceId   at : Rect   types : list<string>
Drop           — event (compositor → client)   surface : SurfaceId
```
A client `OfferSelection`s only after the user copies in it; `source` is the
capability the compositor calls to fetch the bytes. A client's `Paste`
succeeds only because the user pasted into it — the compositor then fetches
from the current selection's `source`. Drag-and-drop mirrors this: after a
`Drop`, the target issues `Paste` against the drag's offer.

## Messages — full-screen direct scanout — **M2 / M3**

```
ScanoutActive   — event (compositor → client)
  surface : SurfaceId   formats : list<{format,modifier}>
ScanoutInactive — event (compositor → client)   surface : SurfaceId
SetPresentMode  — command (client → compositor)
  surface : SurfaceId   mode : enum { vsync, immediate }
```
When a `fullscreen`-role surface is eligible, the compositor page-flips its
buffer straight to KMS and sends `ScanoutActive` with the scanout-capable
`formats` (the client should render in one of them). `ScanoutInactive` fires
when an overlay forces a return to composition. `SetPresentMode immediate`
opts into tearing for lowest latency; VRR is driven by the compositor within
the output's range. Direct scanout bypasses the compositor's renderer
entirely (`DESIGN.md` §7.4).

## Messages — shell-scoped (the shell's capability only) — **M3**

```
ListWindows    — request (shell → compositor)
  → list<{ window : SurfaceId, title : string, app : string, state }> | Error
ActivateWindow — command (shell → compositor)   window : SurfaceId
ReserveStrut   — command (shell → compositor)   surface : SurfaceId   edge   size : i32
```
`ListWindows` feeds the window list; `ActivateWindow` raises and focuses one;
`ReserveStrut` lets a panel reserve screen-edge space.

## Capabilities

`Cap<Display>` carries the client's grant:

- An **app's** capability grants the surface, frame, window-management,
  input, clipboard, and direct-scanout messages — for its own surfaces.
- The **shell's** capability additionally grants the shell-scoped messages
  (`ListWindows`, `ActivateWindow`, `ReserveStrut`). This is the §10 rights
  model distinguishing the shell from an app (`DESIGN.md` §11.10).

## Errors

`ErrorCode`: `unknown-surface`; `invalid-role` (e.g. a `popup` with no
parent); `invalid-buffer` (a format/modifier the display cannot use);
`no-selection` (`Paste` with nothing offered); `type-unavailable` (the
offered selection lacks the requested type); `not-permitted` (a shell-scoped
message on an app capability).

## Examples

**A window's first frame (M1, `Shm`):**
```
→ CreateSurface                                   ← SurfaceId 7
→ SetRole     surface=7  role=toplevel
→ SetTitle    surface=7  title="Text Editor"
← Configure   surface=7  size=800×600  focused=true  output=0  scale=1.0  state=normal
→ Commit      surface=7  buffer=Shm{ fd=<memfd>, XRGB8888, stride=3200, 800×600 }  damage=full
← Released    surface=7  buffer=…
← Presented   surface=7  time=…
← FrameDone   surface=7
```
M2 replaces the `Shm` buffer with `Dmabuf{ fd, format, modifier, w, h }`
and reinstates `acquire=<sync>` / `release=<sync>` on the wire.

**A full-screen game:**
```
→ SetRole       surface=7  role=fullscreen{output:0}
← Configure     surface=7  size=2560×1440  state=fullscreen  …
← ScanoutActive surface=7  formats=[ {XRGB8888, linear}, … ]
→ SetPresentMode surface=7  mode=immediate
→ Commit …          (buffers now page-flip straight to the display)
```

**Rejected — a shell-scoped message on an app capability:**
```
→ ListWindows
← Error  code=not-permitted  detail="ListWindows requires a shell capability"
```
