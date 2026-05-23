# AbyssBSD — session handoff

A handoff for picking up AbyssBSD development. The rolling status is
`STATUS.md`; the plan is `docs/ROADMAP.md`; the Phase 4 design is
`docs/design/broker-and-transport.md` (Gate D). This file orients a fresh
session — read `STATUS.md` next for the increment-level detail.

## What AbyssBSD is

An opinionated desktop OS layer, written in Rust, on a FreeBSD base. It is
capability-based: every authority a component holds is an explicit,
attenuable capability; components run jailed and Capsicum-confined. See
`DESIGN.md` and `docs/ROADMAP.md`. The design proceeds in gates A–I.

## The workspace

One Cargo workspace. `crates/` is the AbyssBSD layer; `sys/` the FreeBSD
FFI crates; `xtask` the build/CI harness.

- `abyss-msg` / `abyss-msg-derive` — the wire message: `Value`,
  `Envelope`, the `Wire` typed-view layer, the fd-carrying handle table,
  and `Method` / `Request` (a message's routing identity and reply type).
  `#[derive(Wire/Method/Request)]`.
- `abyss-looper` — the cooperative executor: `Looper`, `Handler`, the
  typed ring (`channel` / `Sender` / `Receiver`), `Spawner`, the
  `EventSource` seam, `Responder` / `Delivery` (the framework-mediated
  reply path).
- `abyss-cap` — the capability layer: `Cap<I, R>`, a typed,
  rights-bearing send capability over an in-process or an IPC backend;
  `Interface`, `Rights` (with `const MASK: u32`), `CapBody`,
  `DurableCap` / `Repointer`, `Service` + `bind_service`.
- `abyss-transport` — the FreeBSD IPC substrate: `Channel`
  (`SOCK_SEQPACKET` + `SCM_RIGHTS`), `MessageChannel`, `FramedChannel`,
  the `kqueue` `Reactor`/`ReactorSource`, `AsyncChannel` /
  `AsyncMessageChannel`, `Connection` (the request/reply protocol).
- `abyss-bundle` — the bootstrap-bundle schema: `Bundle`, `Grant`,
  `CasperChannel`, `PeerRestarted`, `SpawnChild` / `SpawnReply`. The
  contract the broker and every startup shim share. Host-testable.
- `abyss-broker` — the broker: manifest parser + directory loader, the
  authority graph, the interface catalogue (in-code and on-disk forms),
  the spawnable manifest set, `Session` (wires + spawns + supervises +
  re-wires on restart + honours `kind = spawn` delegated spawn + opens
  `kind = casper` channels), `boot` (the disk-to-running-session path),
  plus the `broker` binary itself — the desktop's root process.
- `abyss-bootstrap` — the component startup shim: `enter` receives the
  bundle and calls `cap_enter`; `Startup` claims grants and Casper
  channels; `Control` watches the control connection for `PeerRestarted`
  and drives the durable capability's `Repointer`. Ships the
  `component-probe` fixture component.
- `abyss-log` — the first-party logging crate.
- `abyss-font` / `abyss-render` / `abyss-toolkit` / `abyss-test-support`
  — earlier-phase crates (font handling, the renderer, the toolkit, and
  the test helpers).
- `sys/freebsd-{capsicum,jail,procdesc,libcasper,libcap-dns}-sys` — the
  FFI crates, each gated on `target_os = "freebsd"`, empty libraries
  elsewhere. Capsicum and procdesc carry C shims (Capsicum's rights API
  is C macros; `pdfork`-then-`exec` must run in C); jail, libcasper, and
  libcap-dns are direct `extern` blocks.

## Current state — Phase 4 closed

Phase 4 (Gate D — the broker and the FreeBSD IPC transport) is **done**:
the broker reads its manifests, builds the authority graph, launches
each component into its jail in Capsicum capability mode, supervises
them, re-wires on restart, honours delegated spawn, and composes with
Casper. Every piece is proven in the VM with multi-process end-to-end
tests across jailed, capability-mode components. See `STATUS.md` for the
increment-by-increment detail and recent commits.

Branch: `main`. Every increment is `cargo xtask ci`-green on macOS *and*
in the FreeBSD VM.

## What's next

**Phase 5** (`docs/ROADMAP.md`): the desktop layer — `abyss-compositor`
(CPU backend) and `abyss-svc-input`, the first wired system components
on the broker, toward **M1**. From the AbyssBSD layer's point of view
this is "the first apps the broker spawns into real wired interfaces."
Per the roadmap it needs FreeBSD plus GPU/display surface — the next
environment step the project hasn't taken yet.

Open Phase-4 follow-ups, all explicitly closed in `STATUS.md`'s Next
section (read there for the position). One was kept deferred: the
`Cap<I, R>` associated-type tightening (`R::Interface = I`), traded
against the runtime check that already catches the same misuse.

## How to work

- **Two environments.** The macOS dev bed builds and tests everything
  FreeBSD-independent. FreeBSD-gated code (`#[cfg(target_os = "freebsd")]`
  — the transport, the spawn, Capsicum, libcasper) compiles and runs
  only in the VM.
- **The VM.** `tools/vm/vm.sh` drives a QEMU + HVF FreeBSD 15 aarch64
  VM. `vm.sh build` syncs the source and runs `cargo xtask ci` inside
  it; `vm.sh boot` / `ssh` / `status` / `provision` are the rest. The
  VM's `abyssroot` password is deliberately committed in
  `tools/vm/cloud-init/user-data` — the VM is local, NAT'd, reachable
  only via a localhost port-forward.
- **The gate.** `cargo xtask ci` — fmt-check, clippy (`-D warnings`),
  build, test. An increment is done when it is green on macOS *and* via
  `vm.sh build`.
- **The rhythm.** Small increments. Each: code, green on both, commit to
  `main`, then a follow-up commit bumping `STATUS.md`. STATUS keeps ≤10
  recent commits with hashes.
- **Toolchain.** Dev toolchain pinned 1.95.0 (`rust-toolchain.toml`);
  MSRV `1.94.0`, what FreeBSD packages — the workspace must build with
  it. On macOS, `cargo` isn't on `$PATH`; use the rustup toolchain bin
  directly (`$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin`).

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
  `<sys/capsicum.h>`, `<sys/procdesc.h>`, `<libcasper.h>`) and their
  symbols as errors. False positives — that code compiles only in the
  VM; trust `vm.sh build`, not the IDE.
- `cargo test` builds every bin as a test by default. The `broker` and
  `component-probe` bins have no `#[test]` functions, and their test
  builds lose libcasper as DT_NEEDED (an `--as-needed` quirk specific to
  the test-build variant — the prod bins are fine). Both bins opt out
  via `test = false` in their `[[bin]]`; integration tests still spawn
  the prod bins through `CARGO_BIN_EXE_*`.
- libcap_dns.so calls `service_register` from libcasper at load but
  doesn't declare libcasper.so as DT_NEEDED — `freebsd-libcap-dns-sys`
  holds `#[used]` statics that keep both `-lcap_dns` and `-lcasper` on
  the link line.
- Gate D's design was extended through implementation: §2.8, §2.9,
  §2.10, §3.3, §3.5, §5.5, §5.6, §5.7 each pinned material as it was
  built. Keep the design doc and the code in step.
