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

Gates E and F precede Phase 5 code and co-design — the WM core's
`Configure` set shapes the display protocol schema:

- **Gate E — `docs/design/window-management.md`** is *closed for M1*.
  The WM core's state and entry-point set (§2.1), the §4 `LayoutEngine`
  trait, the tiling-tree types and operation set (§5), the floating
  data shape (§6), the binding-table schema (§8), and the
  M1/M2/M3 split (§11) are all pinned. `crates/abyss-wm-layout` is
  declared as a Phase-0-style host crate — the first piece of Phase 5
  code, before the FreeBSD `abyss-compositor` crate exists.
- **Gate F — `docs/interfaces/display.md` finalized to its M1 subset,
  plus `docs/design/drm-kms-bringup.md`** is *next*.

## Recent commits

*(≤10 most recent, newest first)*

- `2f4e041` Phase 5: Gate E closed — window-management pinned for M1
- `07fc336` Refresh ONBOARDING.md for Phase 4 closed
- `bcc2021` Bump STATUS: Phase 4 follow-ups wrapped (§5.7 success-path + restart/delegated-spawn casper)
- `1a772df` Phase 4: §5.7 success-path — broker wires a working Casper DNS channel
- `b4e95a2` Phase 4: abyss-broker — restart-casper and delegated-spawn casper (§5.7)
- `1ff5761` Bump STATUS: Phase 4 closed — Casper wired at the broker (§5.7)
- `745f3ff` Phase 4: abyss-broker — open Casper channels at wire time (§5.7)
- `770a2d4` Bump STATUS: Phase 4 — freebsd-libcasper-sys, the broker's Casper FFI (§5.7)
- `cf0520c` Phase 4: sys/freebsd-libcasper-sys — the broker's Casper FFI (§5.7)
- `4537581` Bump STATUS: Phase 4 — claim Casper channels from the bundle (§5.7)

## Site

`site/` is the project's static web presentation — seven pages: a landing
page, the vision and principles, the architecture, the component map, the
interface contracts, the ecosystem stance, and the five-milestone roadmap,
plus shared styling (`style.css`). It tracks `DESIGN.md` and is updated as
the design moves — last refreshed alongside the window-management,
screen-capture, and capability-coverage design work (`9fb7995`). It is a
presentation layer, deliberately outside the Cargo workspace.

## Next

**Gate F close** — `interfaces/display.md` annotated with its M1 subset
(surfaces; frames `Commit` / `Released` / `Presented` / `FrameDone`;
`Configure` / `CloseRequested` / `RequestState`; `Key` re-delivery;
outputs), with dmabuf-sync, clipboard/DnD, direct scanout, shell-scoped
messages, and `LockPointer` deferred. Co-designed with Gate E — the
`Configure` set, the absence of a configure-serial, and the
internal-only decoration mode are the three points to confirm or revise.

**Then `docs/design/drm-kms-bringup.md`** — the DRM/KMS uAPI surface the
CPU/dumb-buffer scanout path needs (modeset, primary plane, dumb-buffer
ioctls, page-flip & VBlank, hotplug), and how that presents through the
kqueue reactor as `EventSource`s.

**Then Phase 5 code begins**, host-buildable first:
**`crates/abyss-wm-layout`** (and possibly a sibling `abyss-wm-core`),
satisfying the Gate-E §4 trait — pure geometry / pure logic, unit-tested
on macOS before the FreeBSD compositor crate exists. After that, the
VM-only work: `sys/drm-sys`, the `abyss-compositor` skeleton on the
broker, the display protocol's server side, `abyss-svc-input`, and
finally `abyss-term` — reaching M1.

The Phase-4 follow-ups are wrapped (`STATUS.md@bcc2021`): `Cap<I, R>`
associated-type tightening kept deferred against the runtime check.
