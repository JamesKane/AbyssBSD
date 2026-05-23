# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phase 5 — the desktop layer (compositor + input), toward M1 — has
begun.** Gate D / Phase 4 is closed (`STATUS.md@bcc2021` and earlier;
`git log`): the broker is built and proven in the VM. Phase 5 brings up
`abyss-compositor` (CPU backend), `abyss-svc-input`, and the first wired
terminal — `rc` → broker → compositor → terminal window = **M1**.

The two pre-code gates are both *closed*:

- **Gate E — `docs/design/window-management.md`**. WM core state and
  entry-point set (§2.1), the §4 `LayoutEngine` trait, tiling-tree
  types and operation set (§5), floating data shape (§6),
  binding-table schema (§8), and the M1/M2/M3 split (§11) all pinned.
  `crates/abyss-wm-layout` declared as a Phase-0-style host crate.
- **Gate F — `docs/interfaces/display.md` + `docs/design/drm-kms-bringup.md`**.
  display.md annotated with the M1 subset (outputs, surfaces toplevel-only,
  frames with `Buffer = Shm`, window management, keyboard + pointer
  re-delivery); `Buffer` split into `Shm` / `Dmabuf` variants; `SyncPoint`
  marked M2 and made optional on M1 wire. Gate-E co-design points settled:
  no configure-serial in M1 (next `Commit` is the ack); no decoration on
  the wire (internal to the compositor); `Configure`'s field set is
  sufficient. New `drm-kms-bringup.md` pins the ten-ioctl M1 surface
  (legacy KMS), the DRM fd as a kqueue `EventSource`, the `card0` fd
  passed in the broker bundle with `cap_rights_limit` + `cap_ioctls_limit`,
  and `sys/drm-sys` as the FreeBSD-gated FFI crate.

## Recent commits

*(≤10 most recent, newest first)*

- `a3d917c` Phase 5: abyss-wm-layout — user-action operations (Gate E §5)
- `3b2591d` Bump STATUS: abyss-wm-layout first increment landed
- `5033fd9` Phase 5: abyss-wm-layout — the layout engine and tiling tree (Gate E §4/§5)
- `7206ee3` Bump STATUS: Gate F closed — display M1 subset + DRM/KMS bring-up
- `051a7e4` Phase 5: Gate F — DRM/KMS bring-up doc, the CPU scanout path
- `50cead0` Phase 5: Gate F — display.md annotated with the M1 subset
- `116f280` Bump STATUS: Phase 5 begins — Gate E closed, Gate F next
- `2f4e041` Phase 5: Gate E closed — window-management pinned for M1
- `07fc336` Refresh ONBOARDING.md for Phase 4 closed
- `bcc2021` Bump STATUS: Phase 4 follow-ups wrapped (§5.7 success-path + restart/delegated-spawn casper)

## Site

`site/` is the project's static web presentation — seven pages: a landing
page, the vision and principles, the architecture, the component map, the
interface contracts, the ecosystem stance, and the five-milestone roadmap,
plus shared styling (`style.css`). It tracks `DESIGN.md` and is updated as
the design moves — last refreshed alongside the window-management,
screen-capture, and capability-coverage design work (`9fb7995`). It is a
presentation layer, deliberately outside the Cargo workspace.

## In flight

**`crates/abyss-wm-layout` — built; Gate E §4/§5 is satisfied
host-side.** Layout engine, tiling tree, and the full closed operation
set: `insert` / `remove` (surface lifecycle), `focused_window`,
`focus_move` (i3-style outward-escape), `split` (transient
single-child container, the i3 model in tree form), `set_layout`,
`move_leaf` (M1 subset: adjacent-sibling swap), `resize` (per-edge
ratio adjust). 35 unit tests, green via `cargo xtask ci` on macOS and
`vm.sh build`. Two small Gate-E doc cleanups the implementation
surfaced (`TabEntry`'s title field dropped; "every visible leaf
appears in Placement").

## Next

The next Phase 5 increment moves to the VM track. In order:

- **`sys/drm-sys`** — the FreeBSD-gated DRM/KMS FFI per Gate F's
  bring-up doc; `bindgen` + the C-shim pattern for the `_IOC*` macros.
- **`abyss-compositor` skeleton** — boots under the broker (manifest,
  bundle, `cap_enter`, looper); opens `card0` from its bundle, performs
  initial modeset, allocates dumb buffers, presents a blank frame.
- **`abyss-compositor` + display protocol M1 subset** — server side of
  `CreateSurface` / `Commit` / `Configure` and friends; CPU compositing
  via `abyss-render` into the dumb buffer.
- **`crates/abyss-svc-input`** — libinput/seatd input service per
  `interfaces/input.md`; wired into the compositor by the broker.
- **Compositor consumes input + WM core wired in** — keyboard-driven
  tiling works the moment the compositor manages more than one window.
- **`crates/abyss-term` minimum** — terminal that opens a `Display`
  capability, paints with `abyss-render`. **= M1.**

**Environment step** before the VM track: `tools/vm/vm.sh` and
`cloud-init/user-data` gain `-device virtio-gpu` and the kernel modules
to load it — the one delta Phase 5 carries before Phase 6's bare-metal
box.

The Phase-4 follow-ups are wrapped (`STATUS.md@bcc2021`): `Cap<I, R>`
associated-type tightening kept deferred against the runtime check.
