# AbyssBSD — Roadmap

How AbyssBSD gets built: the FreeBSD base it pins to, the development
environment, the source layout, and the phased development cycles. The
*what* and *why* live in [`DESIGN.md`](DESIGN.md); this is the *order*.

**The guiding constraint.** The primary development bed is **macOS** (Apple
Silicon) for the foreseeable future, and FreeBSD has no Claude CLI today.
So the work is deliberately ordered to push everything host-buildable and
unit-testable as early as possible: the message primitive, the
looper/service framework, the 2D renderer, and the toolkit core are all
built and tested on macOS *before a single FreeBSD install*. FreeBSD enters
only when kernel mechanisms (Capsicum, jails, process descriptors, DRM/KMS)
genuinely require it — Phase 4 onward.

---

## 1. The FreeBSD base track

AbyssBSD pins to a FreeBSD **release** branch, never `-CURRENT`, and rides
the dot cycle:

- **Pin: FreeBSD 15.0-RELEASE** (`releng/15.0`) — the development and
  curation base from day one.
- **Follow the dot cycle.** As 15.1, 15.2, … ship, the pin advances one dot
  release at a time; each bump is a deliberate, tested step (DESIGN §3.2 —
  depending on a new base revision is a decision).
- **16.0 is the long horizon.** The project rebases onto `releng/16.0` when
  it ships, after 15.x has carried the M1–M5 work.

The sibling checkout at `../freebsd-src` is on `main` (16.0-CURRENT) — a
general working copy, **not** a release pin. Where the project's own pinned
copy lives is an open decision — see §6.

---

## 2. Development environment & toolchain pin

**Host (primary bed).** macOS on Apple Silicon. All of Phases 0–3 build and
test here, natively.

**Rust — pinned to `1.95.0`** (stable, 2026-04-14), the most recent stable
on this machine. Stable only: DESIGN §3.1 forbids waiting on a compiler,
and every feature AbyssBSD needs is stable today. The pin lives in
[`../rust-toolchain.toml`](../rust-toolchain.toml) and rustup honours it on
both macOS and FreeBSD.

**FreeBSD build target.** `x86_64-unknown-freebsd` — a tier-2 Rust target
(prebuilt std), matching the DESIGN §5 reference arch (amd64). FreeBSD
environments build natively; install Rust matching the `1.95.0` pin.

**Build-time tools** (on the dependency allowlist, DESIGN §11.2):
`bindgen` — used as a *build-dependency crate* in `build.rs`, not the CLI —
for FreeBSD header import; it needs `libclang` from FreeBSD's base clang.
`cmake` and `pkg-config` are present on the host for native deps (the font
stack).

**FreeBSD test environments** (Phase 4+):

- *Non-GPU work* (Capsicum, jails, process descriptors, IPC, broker): an
  **amd64 FreeBSD 15.0 VM** under QEMU. Arch-parity with the reference
  target; syscall-bound work tolerates emulation on Apple Silicon.
- *GPU work* (compositor, direct scanout): the **bare-metal reference box**
  — amd64, AMD RX 6750 XT (DESIGN §5). A VM with virtio-gpu covers
  CPU-backend bring-up before bare metal is needed.

---

## 3. Source & build layout

A single Cargo workspace. Host-buildable crates are the workspace
`default-members`; FreeBSD-only crates are `cfg`-gated or built explicitly
on the FreeBSD host — so `cargo test` on macOS never tries to compile a
Capsicum call. Crates are added phase by phase, not scaffolded up front.

```
AbyssBSD-rust/
├── README.md
├── STATUS.md               rolling change context (see §7)
├── rust-toolchain.toml      the Rust pin
├── Cargo.toml               workspace root
├── .cargo/config.toml       cargo aliases — the `xtask` alias
├── xtask/                   build & CI harness — `cargo xtask ci`
├── docs/
│   ├── DESIGN.md
│   ├── ROADMAP.md           this file
│   ├── design/              per-phase elaboration docs — the gates (§5)
│   └── interfaces/          per-interface message schemas
├── crates/                  the AbyssBSD layer
│   ├── abyss-msg/            message primitive — envelope, dict, wire
│   ├── abyss-msg-derive/     proc-macro: typed views over the dict
│   ├── abyss-looper/         looper & service framework (§6.10)
│   ├── abyss-cap/            capability types, phantom-typed rights
│   ├── abyss-render/         2D scene renderer (CPU backend)
│   ├── abyss-toolkit/        the Kits
│   ├── abyss-broker/         broker                       [FreeBSD]
│   ├── abyss-compositor/     compositor / display server  [FreeBSD]
│   ├── abyss-svc-*/          system & session services    [FreeBSD]
│   ├── abyss-shell/          desktop shell
│   └── abyss-term/           terminal app
├── sys/                     FreeBSD FFI binding crates    [FreeBSD]
│   ├── freebsd-capsicum-sys/
│   ├── freebsd-jail-sys/
│   ├── freebsd-procdesc-sys/
│   └── drm-sys/
├── tools/                   VM provisioning, image build scripts
└── third_party/             the pinned FreeBSD source — see §6
```

---

## 4. Development phases

Ordered so each phase **enables** the next, and so the host-testable work
comes first. Phases 0–3 need no FreeBSD; Phase 4 is the first FreeBSD
install. M1 is reached at the end of Phase 5.

| Phase | Deliverable | Runs on | Reaches |
|---|---|---|---|
| 0 | Workspace & CI harness | host | — |
| 1 | Message primitive | host | M1 foundation |
| 2 | Looper & service framework | host | M1 foundation |
| 3 | Rendering & toolkit core | host | M3 core |
| 4 | Broker, IPC transport, FreeBSD FFI | FreeBSD VM | M1 |
| 5 | Compositor (CPU backend) + input | FreeBSD + GPU | **M1** |
| 6 | GPU path — GLES / Mesa | FreeBSD + GPU | **M2** |
| 7 | Toolkit, services, shell, login | FreeBSD + GPU | **M3** |
| 8 | Core apps | FreeBSD + GPU | **M4** |
| 9 | Distribution & hardening | FreeBSD + GPU | **M5** |

### Phase 0 — Workspace & CI harness *(host)*

Cargo workspace, the `rust-toolchain.toml` pin, a CI lane (build + test +
`clippy` + `rustfmt`) on macOS, and the in-process test scaffolding the
later host phases rely on.
*Enables:* every phase.

### Phase 1 — Message primitive *(host)* — `abyss-msg`, `abyss-msg-derive`

The universal envelope (§6.2), the self-describing typed dict (§6.3), the
typed-view derive macro, the copying wire serializer (§6.4), and fallible
`from_dict` validation.
*Host-testable:* fully — round-trip / property tests on serialization,
`trybuild` tests on the derive macro. No transport yet.
*Enables:* every message-based component — i.e. everything.

### Phase 2 — Looper & service framework *(host)* — `abyss-looper`, `abyss-cap`

The §6.10 framework — "the chief structural piece the project builds for
itself": loopers (thread + queue + cooperative async executor, §6.9),
handlers with per-handler serialization, rings and `RingCap`, and the
capability types with phantom-typed rights (§10.5).
*Host-testable:* fully, against an **in-process ring** transport — the ring
API is transport-agnostic by design (§6.10), so the FreeBSD socket
transport is a Phase-4 swap-in, not a blocker here. Capability narrowing is
checked with compile-fail tests.
*Enables:* every component is written on this framework.

### Phase 3 — Rendering & toolkit core *(host)* — `abyss-render`, `abyss-toolkit`

The NanoVG-style 2D scene renderer against a **CPU/dumb-buffer** target
(§7.3), the view arena and generational `ViewId` model (§8), retained-mode
tree and layout, the Kit structure, and the terminal's VT / escape-sequence
parser.
*Host-testable:* fully — the CPU renderer draws into an ordinary memory
buffer, so golden-image comparison works on macOS; the font stack
(freetype/harfbuzz/fontconfig) is linked via Homebrew for parity with the
FreeBSD ports.
*Enables:* the compositor's CPU backend and every UI surface.

### Phase 4 — Broker, IPC transport, FreeBSD FFI *(FreeBSD VM)* — `abyss-broker`, `sys/*`

**First FreeBSD environment.** The `SOCK_SEQPACKET` ring transport with
`SCM_RIGHTS` fd-passing; the FFI binding crates for Capsicum, jails, and
process descriptors; the broker — manifest parsing, jailed spawn, bundle
wiring, `pdfork` supervision (§11.9).
*FreeBSD-required:* `SOCK_SEQPACKET`, `cap_enter`/`cap_rights_limit`,
jails, and `pdfork` exist only here.
*Enables:* a real multi-process, capability-secured system.

### Phase 5 — Compositor (CPU backend) + input → **M1** *(FreeBSD + GPU)* — `abyss-compositor`, `abyss-svc-input`

DRM/KMS via the ioctl uAPI, the CPU/dumb-buffer scanout path, the display
protocol (§7.4) at its M1 subset, and a minimal `libinput`/`seatd` input
service so the terminal is usable. **`rc` → broker → compositor → terminal
window = Milestone M1**, the permanent recovery floor.
*Enables:* the accelerated path and the toolkit/shell.

### Phase 6 — GPU path → **M2** *(FreeBSD + GPU)*

The GLES 3.x render backend via Mesa/EGL behind the render-backend seam,
and dmabuf buffer sharing. The Mesa port. **= M2.**

### Phase 7 — Toolkit, services, shell, login → **M3** *(FreeBSD + GPU)* — `abyss-shell`, `abyss-svc-*`

The full Kits; the GNOME-2 shell (panels, app menu, window list); the
per-user services (settings, notification, device monitor, power,
networking, audio); the session lock; the greeter and the three-role login
lifecycle (§11.15). **= M3.**

### Phase 8 — Core apps → **M4** *(FreeBSD + GPU)*

File manager, settings UI, text editor — the terminal already exists from
M1. Apps reuse the Phase-3/7 toolkit, so this phase is largely free of new
substrate. **= M4.**

### Phase 9 — Distribution & hardening → **M5** *(FreeBSD + GPU)*

ZFS boot-environment install/update (§11.17), the graphical installer, the
curated installable image, the §3.6 performance/memory budget gates wired
into CI on the reference hardware, and broadening curated hardware support.
**= M5.**

---

## 5. Design-elaboration gates

DESIGN.md is the architecture; it is not implementable line by line without
elaboration. Each gate is a focused design pass — landing a document under
`docs/design/` (or finalizing an `interfaces/` schema) — done **before**
the phase it unblocks. Skipping a gate is how a phase discovers, halfway
through, that it is redesigning instead of building.

| Gate | Before | Produces |
|---|---|---|
| A | Phase 1 | `design/wire-format.md` — byte layout, the typed-value vocabulary, the derive-macro contract |
| B | Phase 2 | `design/looper-framework.md` — executor internals, ring API, `RingCap` & supervision, the `Wire` trait |
| C | Phase 3 | `design/toolkit.md` — Interface Kit widget set, layout algorithm, the arena/`ViewId` API, the drawing-API seam (§7.3) |
| D | Phase 4 | `design/broker-and-transport.md` — manifest schema, the spawn/bundle protocol, `SOCK_SEQPACKET` framing, the object-rights → `cap_rights_t` mapping |
| E | Phase 5 | `design/window-management.md` — the WM core, the layout-policy seam, the tiling layout engine, floating, and key-chords (`DESIGN.md` §7.7) |
| F | Phase 5 | `interfaces/display.md` finalized to its M1 subset; DRM/KMS bring-up notes |
| G | Phase 6 | `design/render-backends.md` — the render-backend seam, the GLES backend, the Mesa port plan |
| H | Phase 7 | the remaining `interfaces/*.md` schemas verified M3-complete; the login/session lifecycle elaborated |
| I | Phase 9 | `design/install-update.md` — boot-environment lifecycle, the installer, the image build |

Gates E and F both precede Phase 5 and **co-design**: the `configure`
events and surface roles the window manager needs (Gate E) shape the
display-protocol schema (Gate F).

---

## 6. The FreeBSD source pin

AbyssBSD builds and curates against a release-pinned FreeBSD source tree —
header import (`bindgen`), sysroot, and curation/image builds. **Resolved:**
it lives in-tree as a git submodule — reproducible and self-contained,
decoupled from any working copy outside the repo.

- **Location:** `third_party/freebsd-src` (submodule; setup and pin-bump
  procedure in [`../third_party/README.md`](../third_party/README.md)).
- **Pin:** branch `releng/15.0`, commit `6d536196` — FreeBSD
  **15.0-RELEASE-p9**.
- **Upstream:** `https://git.freebsd.org/src.git`.
- **Populated at Phase 4.** Nothing earlier needs the FreeBSD source and a
  checkout is multi-GB, so the submodule is *committed now but cloned on
  demand*: `git submodule update --init --filter=tree:0` — a treeless
  partial clone, small but with full history so the pin can advance without
  a re-clone.
- **Advancing the pin** follows the dot cycle (§1) — one errata level or
  dot release at a time (`releng/15.0` → `releng/15.1` → …), by retargeting
  the submodule.

The sibling `../freebsd-src` (a 30 GB `main`/16.0-CURRENT checkout) is
unrelated — a general working copy, never the project's pin.

---

## 7. STATUS.md convention

[`../STATUS.md`](../STATUS.md) is the rolling change context — deliberately
short:

- the **current epic** being worked;
- the **≤10 most recent commits**, newest first — older history is `git log`;
- on session wrap-up, the **in-flight work** (uncommitted or partial) and
  the **next directions** to pick up.

It is updated as work lands and, in full, whenever the user asks to wrap
up. It never grows an archive — the roadmap and git history hold the rest.
