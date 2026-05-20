# Display protocol — interface schema

> Concrete message schema for the **display protocol**. Shape: `DESIGN.md`
> §7.4. Conventions: `interfaces/README.md`. Status: draft.

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

## Data types

- **`SurfaceId`** — a surface, scoped to the client's `Cap<Display>`
  connection. (Surfaces are ids within the connection, not separate
  capabilities.)
- **`OutputId`** — a display output.
- **`Rect`**, **`Region`** — geometry, in output-logical pixels.
- **`Role`** — `enum { toplevel } | popup{ parent : SurfaceId, at : Rect }
  | fullscreen{ output : OutputId }`.
- **`Buffer`** — `{ dmabuf : handle, format : u32, modifier : u64,
  width : i32, height : i32 }`.
- **`SyncPoint`** — `{ semaphore : handle, value : u64 }` — a timeline-
  semaphore point (`DESIGN.md` §7.4, explicit synchronization).
- **`Output`** — `{ id, width, height, refresh : i32, scale : f64,
  scanout-formats : list<{format,modifier}>, vrr : {min,max}? }`.
- Input event types — `Key`, `PointerMotion`, … — are **as defined in
  `input.md`**; the display protocol re-delivers them to the focused
  surface (see *Input*).

## Messages — outputs (compositor → client)

```
OutputAdded   — event   output : Output
OutputChanged — event   output : Output
OutputRemoved — event   id : OutputId
```
On connect the compositor sends `OutputAdded` for each current output, then
hotplug events thereafter.

## Messages — surfaces (client → compositor)

```
CreateSurface  — request                        → SurfaceId | Error
SetRole        — command   surface : SurfaceId   role : Role
SetTitle       — command   surface : SurfaceId   title : string
DestroySurface — command   surface : SurfaceId
```
`SetTitle` text is drawn by the compositor in the server-side title bar.

## Messages — frames

```
Commit    — command (client → compositor)
  surface : SurfaceId   buffer : Buffer   damage : Region   acquire : SyncPoint
Released  — event (compositor → client)   surface : SurfaceId   buffer : Buffer   release : SyncPoint
Presented — event (compositor → client)   surface : SurfaceId   time : Time
FrameDone — event (compositor → client)   surface : SurfaceId
```
One `Commit` per frame: the surface's new `buffer` is ready when `acquire`
signals. The compositor returns `Released` (the buffer may be reused once
`release` signals), `Presented` (the frame reached the display, with timing
— for pacing), and `FrameDone` (a good moment to render the next frame).
Buffers are dmabuf handles, format/modifier-tagged, API-agnostic — GLES,
Vulkan, or CPU (`DESIGN.md` §7.4).

## Messages — window management (server-side decorations)

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

## Messages — input (to the focused surface)

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

## Messages — clipboard & drag-and-drop

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

## Messages — full-screen direct scanout

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

## Messages — shell-scoped (the shell's capability only)

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

**A window's first frame:**
```
→ CreateSurface                                   ← SurfaceId 7
→ SetRole     surface=7  role=toplevel
→ SetTitle    surface=7  title="Text Editor"
← Configure   surface=7  size=800×600  focused=true  output=0  scale=1.0  state=normal
→ Commit      surface=7  buffer=<dmabuf 800×600>  damage=full  acquire=<sync>
← Presented   surface=7  time=…
← FrameDone   surface=7
```

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
