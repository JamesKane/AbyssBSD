# AbyssBSD — session handoff

A handoff for picking up AbyssBSD development. The rolling status is
`STATUS.md`; the plan is `docs/ROADMAP.md`; the Phase 4 design is
`docs/design/broker-and-transport.md` (Gate D). This file orients a fresh
session — read `STATUS.md` next for the increment-level detail.

## What AbyssBSD is

An opinionated desktop OS layer, written in Rust, on a FreeBSD base. It is
capability-based: every authority a component holds is an explicit,
attenuable capability; components run jailed and Capsicum-confined. See
`DESIGN.md` and `docs/ROADMAP.md`. The design proceeds in gates A–I; Gate
D, the broker and transport, is the Phase 4 design.

## The workspace

One Cargo workspace. `crates/` is the AbyssBSD layer; `sys/` the FreeBSD
FFI crates; `xtask` the build/CI harness.

- `abyss-msg` / `abyss-msg-derive` — the wire message: `Value`,
  `Envelope`, the `Wire` typed-view layer, the fd-carrying handle table,
  and `Method` / `Request` (a message's routing identity and reply type).
  `#[derive(Wire/Method/Request)]`.
- `abyss-looper` — the cooperative executor: `Looper`, `Handler`, the
  typed ring (`channel` / `Sender` / `Receiver`), the `EventSource` seam,
  and `Responder` / `Delivery` (the framework-mediated reply path).
- `abyss-cap` — the capability layer: `Cap<I, R>`, a typed, rights-bearing
  send capability over an in-process or an IPC backend; `Interface`,
  `Rights`, `CapBody`.
- `abyss-transport` — the FreeBSD IPC substrate: `Channel`
  (`SOCK_SEQPACKET` + `SCM_RIGHTS`), `FramedChannel`, the `kqueue`
  `Reactor`, `AsyncChannel`, `Connection` (the request/reply protocol).
- `abyss-broker` — the broker: the manifest parser, the authority graph,
  and (FreeBSD) component spawn plus the restart `Supervisor`.
- `abyss-bootstrap` — the component startup shim: receive the bundle,
  `cap_enter`. Ships the `component-probe` fixture component.
- `abyss-log` — the first-party logging crate.
- `abyss-font` — font handling (an earlier phase).
- `sys/freebsd-{capsicum,jail,procdesc}-sys` — the FFI crates, each gated
  on `target_os = "freebsd"`, an empty library elsewhere; all verified.

## Current state — Phase 4

Phase 4 is well advanced. Built and green: the whole IPC / capability /
broker stack — the transport; the broker's jailed `pdfork`+`exec` spawn
with the bootstrap bundle and the `cap_enter` startup shim; the
restart-on-death `Supervisor`; and the capability layer's `Cap`
two-backend rework, with typed `send` and `call` dispatching over both
the in-process and the IPC backend. `STATUS.md` has the
increment-by-increment detail and recent commits.

Branch: `main`. Every increment is `cargo xtask ci`-green on macOS *and*
in the FreeBSD VM.

## What's next

In order, per `broker-and-transport.md`:

1. **`Cap: Wire`** (§3.4–§3.5) — `impl Wire for Cap`: `to_wire` dups the
   ring fd and pushes the `CapBody`; `from_wire` yields an *unbound*
   `Cap`; `Cap::bind` attaches it to a looper. Best done as one increment
   — it does not sub-slice cleanly (`bind` is untestable until `from_wire`
   produces an unbound cap). Note: §3.5 says `Cap::bind(reactor)`, but
   `bind` also needs the looper, to spawn the connection's `serve` loop so
   `call` replies route — settle that signature when implementing.
   `Cap::try_send`'s IPC arm is a `todo!` — wire or retire it here.
2. **The broker wiring an authority graph** (§5.2–§5.3) — spawn a manifest
   set, mint and deliver the IPC rings that connect the components.
3. **`PeerRestarted`** (§5.5) — when the supervisor restarts a component,
   re-wire the components that held rings to it.

## How to work

- **Two environments.** The macOS dev bed builds and tests everything
  FreeBSD-independent. FreeBSD-gated code (`#[cfg(target_os = "freebsd")]`
  — the transport, the spawn, Capsicum) compiles and runs only in the VM.
- **The VM.** `tools/vm/vm.sh` drives a QEMU + HVF FreeBSD 15 aarch64 VM.
  `vm.sh build` syncs the source and runs `cargo xtask ci` inside it;
  `vm.sh boot` / `ssh` / `status` / `provision` are the rest. The VM's
  `abyssroot` password is deliberately committed in
  `tools/vm/cloud-init/user-data` — the VM is local, NAT'd, reachable
  only via a localhost port-forward.
- **The gate.** `cargo xtask ci` — fmt-check, clippy (`-D warnings`),
  build, test. An increment is done when it is green on macOS *and* via
  `vm.sh build`.
- **The rhythm.** Small increments. Each: code, green on both, commit to
  `main`, then a follow-up commit bumping `STATUS.md`.
- **Toolchain.** Dev toolchain pinned 1.95.0 (`rust-toolchain.toml`); MSRV
  `1.94.0`, what FreeBSD packages — the workspace must build with it.

## Conventions

- Commit to `main` directly; branch only for long-lived or breaking work.
- Keep `STATUS.md`, `docs/acceleration.md`, `docs/TECH-DEBT.md` current.
- No em-dashes in `site/` copy or the repo-root `README.md`; source and
  internal design docs are exempt.
- All logging through `abyss-log` — never ad-hoc `eprintln` / `log` /
  `tracing`.
- End commit messages with the project `Co-Authored-By` trailer.
- The C-shim FFI pattern — a `build.rs` compiling a C shim with system
  `cc` / `ar`, FreeBSD-gated, no build-dependency crates — is used
  wherever a kernel API is built from C macros.

## Gotchas

- A macOS editor's clang flags FreeBSD-only headers (`<sys/jail.h>`,
  `<sys/capsicum.h>`, `<sys/procdesc.h>`) and their symbols as errors.
  Those are false positives — that code compiles only in the VM; trust
  `vm.sh build`, not the IDE.
- The Gate D design was extended through implementation: §2.8, §2.9,
  §2.10, and §3.5 pin the `Cap` two-backend, the interface contract,
  typed request/reply, and `Cap: Wire`. The late §3 material was sketched
  and pinned as it was built — keep the design doc and the code in step.
