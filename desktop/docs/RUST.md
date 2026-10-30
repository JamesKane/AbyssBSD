# ADE in Rust: the rewrite (scope)

**Status: scoped 2026-10-30; §6 adopted as recommended the same day.** This replaces "the product is Swift, top
to bottom" (PLAN.md, *Decisions locked in*). The reason is one fact: **Swift has
no RV64 port**, and ADE has to run on RV64 boards. Rust's
`riscv64gc-unknown-freebsd` exists, but it is Tier 3 (std builds, no host
tools from upstream), and `lang/rust` carries the riscv64 support. That
leaves Rust where Swift-on-FreeBSD was in July: the #1 risk, closed by a
spike before anything else (R0).

## 1. What this is

A rewrite of `desktop/de/` from Swift to Rust that keeps **every wire format,
on-disk format, protocol, binary name and behaviour**. The Swift tree is the
specification. Its tests, live scripts and goldens are the acceptance criteria.
This is not a redesign. Anything we want to change waits until the port is
done, so that a failing live script always means a porting bug.

It is also not the old Rust DE coming back. `AbyssBSD-old` (tide, current,
pool, vents, anchor, 28.6k lines, frozen 2026-06-27) predates four months of
behaviour that only the Swift tree has: Phases 5 to 18, the §2 HANDOFF
lessons, the login/lock/jail work. §6.2 decides how much of it we lift.

## 2. What we have

| Layer | Swift today | Lines | Carries over as |
|---|---|---|---|
| C shims (`cwayland`, `cwlroots`, `ctext`, `cdraw`, `cvents`, `cproc`, `cpam`, `cjail`, `cplatform`, `ccap`, `ctls`, `cpoolwatch`, `cabyssprotocols`) | C | ~19k (much of it generated protocol code) | **unchanged**. These are BSD-licensed C with narrow headers. Rust calls them through `extern "C"` |
| Wire and data (`currentipc`, `poolconfig`, `menuwire`, `settingswire`, `installwire`, `dbus`, `menumodel`, `textmodel`, `jails`, `systemfacts`, `vocab`) | Swift | ~6k | pure crates, the first to go |
| Daemons (`anchor`, `vents`, `portal`, `dbusbridge`, `dbusportal`, `login`, `jaild`, `jailkeeper`, `settingsrun`, `installrun`, `fathom`, `agent`, `model`, `fetch`) | Swift | ~12k | one binary at a time |
| Small tools (`*ctl`, `*bin`, `abyss-open/grab/clip/notify/menu/theme`) | Swift | ~4k | alongside their daemons |
| Compositor (`undertow` + `undertowbin`) | Swift over `cwlroots` | ~10k | over the same `cwlroots` |
| Toolkit (`aquadraw`, `surface`, `aqua`) | Swift over cairo, libwayland | ~29k | last, held to the 92 goldens |
| Tests | XCTest | ~16k, ~780 tests | ported with each crate |
| Live scripts, goldens | sh + C probes | 156 files in `abyss/tests` | **unchanged**: language-neutral |

Three facts make this cheaper than its size:

- **No Foundation.** The tree imports `Glibc`/`Darwin` and our own C targets,
  never Foundation. It maps to Rust + `libc` without a runtime gap.
- **Almost no async.** Six files touch `async`/`actor`; the rest is poll and
  kqueue run loops. That maps to plain Rust loops. **No tokio.**
- **Process boundaries are wire boundaries.** Every component talks to the
  others over CurrentIPC, the pool files, or our Wayland protocols. A Rust
  `vents` can serve a Swift Dock. So the port can be done one binary at a
  time, with a mixed session green at every step (§3).

## 3. The strategy: one binary at a time, never a dark period

1. **The harness learns where binaries are.** 120 files under `abyss/`
   hard-code `.build/debug/…`. R1 puts one `ABYSS_BIN_DIR` lookup in
   `common.sh` and `session.sh`, and the scripts use it. After that, a
   component switches language by changing the directory its binary is found
   in, and nothing else.
2. **Leaves first, the toolkit last.** Port wire crates, then daemons and
   their ctl tools, then the compositor, then the toolkit and the apps.
   Each step leaves a session with some binaries in Rust and the rest in
   Swift.
3. **Cross-language conformance for every wire format.** Each wire crate gets
   fixtures (bytes on disk) that both the Swift and Rust tests decode and
   encode. That is how we know two halves of a mixed session agree, and it
   is the only new kind of test this plan adds.
4. **Same gate as every phase.** Linux and the FreeBSD guest on every pass,
   the both-platforms rule. riscv64 joins as a **cross-build**, from amd64,
   as soon as R0 makes it possible: every pass must still compile and link
   for `riscv64gc-unknown-freebsd`. The qemu riscv64 guest is not on the
   per-pass gate. It runs only when RV64 itself is the question (R0's one
   render, R8's bring-up, a riscv64-only bug), because under TCG it is ~38x
   slower than the host (§5).
5. **RV64 runs ADE when the last Swift binary in the session is gone.** Until
   then, amd64 and aarch64 run mixed sessions, and nothing ships worse than
   it does today.

## 4. Ordered passes

Sizes follow the PHASE docs (S/M/L). Each pass ends with its crates' unit
tests ported and passing, plus the live scripts that touch it.

**R0. The spike: Rust, our C libraries, and a window on FreeBSD/riscv64 (S).**
Everything is **built on amd64 and cross-compiled**; the qemu riscv64 guest
(`qemu-system-riscv64 -machine virt`, EDK2, virtio disk and net, the `rv64`
role in `abyss/vm`) only runs the result. §5 has why:
- **The C libraries.** FreeBSD builds no ports packages for riscv64, so
  `wlroots 0.20`, `cairo`, `freetype2`, `harfbuzz`, `xkbcommon`, `pixman`,
  `gtk3` and `seatd` (and `pkg` itself) are ours to build. Poudriere on the
  amd64 builder VM, a `riscv.riscv64` jail made with `-x` (native-xtools:
  the compiler runs on amd64, qemu-user-static only for what a configure
  script executes). This blocks any language, and it is the long pole.
- **Rust.** `riscv64gc-unknown-freebsd` is Tier 3: no prebuilt `std`. A
  pinned nightly with `-Zbuild-std`, or a stage-2 rustc of our own with the
  target, cross-linking with `clang --target=riscv64-unknown-freebsd` against
  a **sysroot**: the snapshot's base plus the packages above.
- **One window.** Cross-build a Rust binary that links `cwayland` + `cdraw` +
  `ctext` (built by `cc` with the same clang and sysroot), copy it into the
  guest, draw one Aqua button into a headless compositor there and compare
  it with the Swift golden. This is the only step that needs the guest.
- **Cross-build time** of a ~10k-line crate, debug and release, on amd64:
  the number the per-pass riscv64 check costs.

The answer goes in §5 the way SWIFT-ON-FREEBSD.md recorded P3.2's.
**The package build comes before R1.**

**R1. The workspace and the harness (S).** `desktop/Cargo.toml` (workspace),
`de/<name>/` keeps its directory and gains a `Cargo.toml` beside the Swift
sources until the Swift is deleted. Add `abyss-sys`, one crate of `extern "C"`
blocks over the C shims' headers (§6.4), built by `cc` from the same `.c`
files SwiftPM compiles. `ABYSS_BIN_DIR` in the harness. `vm/build.sh` builds
both trees. Rust policy: `unsafe` lives only in `*-sys` crates, deps are
vendored (`cargo vendor`, offline builds for ports, §6.5).

**R2. Wire and data crates (M).** `current-ipc`, `pool-config`, `menu-wire`,
`settings-wire`, `install-wire`, `dbus` (the wire half), `menu-model`,
`text-model`, `jails`, `system-facts`, `vocab`. Pure Rust, no I/O beyond the
socket and the file. Cross-language fixtures (§3.3) go in here.

**R3. Daemons and tools (L), in this order, each a swap of one binary:**
`vents` + `ventsctl`; `anchor` + `abyssctl`; `portal`; `dbus`, `dbusbridge`,
`dbusportal`, `dbusmenus`; `login` daemon (`abyss-loginwindow`) +
`loginctl`; `settingsrun` + `settingsctl`; `installrun` + `installctl`;
`jaild`, `jailkeeper`, `jailctl`; `fathom`; `idle`; `agent`, `model`,
`fetch`. The root daemons (`loginwindow`, `settingsrun`, `installrun`,
`jaild`) get the most care because their bugs are privilege bugs. Their Swift
tests are mostly refusal tests, and those all port.

**R4. `undertow` (L).** It runs over the same `cwlroots` shim and wlroots
0.20 (§6.3). The HANDOFF §2 lessons that undertow encodes become comments at
the code that encodes them, as in Swift. Gate: every live script that starts
a session passes with a Rust undertow and a Swift toolkit. Then the metal
check on the 12700KF: VT switch, session lock, output hotplug.

**R5. The toolkit (L).** `aquadraw` (cairo through `cdraw`), `surface`
(Wayland client), then `aqua`. Pass bar: **all 92 goldens match.** Cairo,
FreeType and HarfBuzz are the same C libraries making the same calls, so an
exact match is the expected result. A mismatch is a bug, not a tolerance.

**R6. Scenes and applications (L).** In this order: the desktop, menu bar
and Dock; Finder; the lock screen, login window and Setup Assistant; System
Preferences (all panes); the installer; Terminal, TextEdit, Grab, Activity
Monitor, Disk Utility, System Profiler. One `AQUA_SCENE` at a time, each
with its goldens and live script.

**R7. Swift leaves (S).** Delete `Package.swift`, the Swift sources and
`Tests/`. Drop `swift6` from the build VM, the image and `ports/lang/`.
Retire SWIFT-ON-FREEBSD.md and SWIFT-6.4.md. Rewrite PLAN.md's decisions,
CLAUDE.md and the agent memory's Swift-not-Rust policy. Run the `--full` gate
on the last mixed build and the first pure-Rust build.

**R8. RV64 bring-up (M, plus whatever the boards need).** First the medium,
the installer and the desktop in the qemu guest, end to end: the R7 `--full`
gate on riscv64. Then the boards, the Orange Pi RV2 (SpacemiT K1) and then
the SpacemiT K3. Board work (kernel, GPU, "nothing special") follows the Q8B
pattern, with its own `docs/boards/<board>/` survey written before anything
is flashed.

## 5. Spike results

**2026-10-30: the guest, and two facts that turned R0 into a cross-build.**

- **The guest works.** FreeBSD 16.0-CURRENT riscv64 snapshot
  20261027-61c70dc16a79 (UFS image), `qemu-system-riscv64 -machine virt
  -cpu rva22s64`, 8 harts, 8G, EDK2 from the host's `edk2-riscv64` (padded
  to the 32M flash banks), MTTCG. Boot to `login:` takes about 3 minutes
  (the snapshot kernel has WITNESS). There is no CLOUDINIT image for
  riscv64, so `vm/provision-rv64.sh` sets the guest up over its serial
  console: the build user, the key, sshd on port 2224. Base has clang 21.1.8
  and ld.lld.
- **TCG is ~38x slower than the host.** The same `cc -O2 -c` of a generated
  1500-function file: 1.84 s on the host, 70.5 s in the guest. Building
  `lang/rust` or the desktop's dependency tree in the guest would take days.
  So the guest only runs binaries (§3.4, §6.9).
- **FreeBSD builds no ports packages for riscv64.** `pkg.freebsd.org` has
  `FreeBSD:{14,15,16}:riscv64` with only `base_*` and `kmods_*`
  repositories, no `latest` or `quarterly`. `pkg bootstrap` fails in the
  guest. Every port ADE needs is ours to build (R0, first bullet).

## 6. Risks and open decisions

**6.1 The targets. — DECIDED 2026-10-30.** The qemu `virt` riscv64 guest
carries R0 to R8. The **Orange Pi RV2** (SpacemiT K1) and the **SpacemiT
Key Stone K3** don't come in until late in the qemu work. A guest only shows
that the code is portable. Real-silicon facts wait for each board's survey:
FreeBSD SoC support, the GPU and whether it has any FreeBSD driver, and
which ISA profile and vector extensions it has. Until a board has a GPU
driver, ADE runs there on pixman, which undertow already supports. Neither
board blocks R1 to R7.

**6.2 What we take from `AbyssBSD-old`.** *Adopted: read it, lift
nothing wholesale.* Its crates encode the June design, and the Swift tree has
since diverged from it in behaviour (PoolConfig shares the on-disk format,
not the semantics). Copy a function only when it passes the ported Swift
tests unchanged. Its `wlsys` is worth reading for R1, since it is the same
problem.

**6.3 The compositor library.** *Adopted: wlroots 0.20 through our
`cwlroots`, not Smithay.* `cwlroots` is already a language-neutral shim, a
dozen HANDOFF lessons are wlroots behaviour (VT pause destroying outputs,
session lock, the security-context filter), and Smithay would make R4 a
second compositor design rather than a port. Smithay's advantage (no C) is
not something this project values over a proven wlroots.

**6.4 Bindings.** *Adopted: hand-written `extern "C"` over our shim
headers, no `bindgen`.* The headers are ours and narrow, and this keeps
libclang off the RV64 build. Generated protocol code stays C, from
`wayland-scanner`, as it is now. We don't adopt `wayland-rs`: it would
replace libwayland semantics that HANDOFF §2.57 (`wl_proxy_destroy` sends
nothing) and others pin down.

**6.5 Dependencies.** *Adopted: `libc`, `cc` (build) and nothing else
without a reason recorded here.* The Swift tree has no third-party
dependencies, so we keep it that way. Vendored for offline builds and the
ports tree.

**6.6 Mixed sessions or a branch.** *Adopted: mixed sessions on `main`
(§3).* A long-lived rewrite branch would mean months with no working desktop
on `main` and a merge at the end. Mixed sessions mean every pass ships.

**6.7 Feature freeze.** *Adopted: no new Swift features from R1 on.*
Bugs found on metal still get fixed in whichever language owns the binary at
that point. BACKLOG items wait for the port, or are done in Rust.

**6.8 Risk: Rust on FreeBSD/riscv64 is Tier 3.** No upstream CI, no
prebuilt `std`. A rustc regression can break us with no warning. The
mitigation is the one Swift got: pin the toolchain version in `vm/config.sh`,
keep R0's cross-build as the per-pass riscv64 check, and treat a toolchain
bump as its own pass.

**6.9 Cross-build, always. — DECIDED 2026-10-30.** Nothing is compiled in
the qemu guest: `--target riscv64gc-unknown-freebsd` on amd64 against a
sysroot of the snapshot's base plus our riscv64 packages, then copy the
binaries in. The guest runs only when RV64 itself is under test. The boards
get the same workflow. (R0 measured why: §5.)

**6.10 The qemu guest is a new VM to keep.** It is a third VM next to the
amd64 build guest. Its disk lives outside the monorepo with the others
(`$ABYSS_VM_HOME`), and it gets its own `vm/config.sh` stanza: the `rv64`
role (port 2224, its own disk, firmware and console socket). Booted only
when needed.

## 7. Verification

Per pass: that crate's ported unit tests, its cross-language fixtures, the
live scripts that exercise its binary, on Linux and in the FreeBSD guest. R4
adds metal. R5 and R6 add the goldens. R7 runs `--full` twice. R8 runs it on
the board.
