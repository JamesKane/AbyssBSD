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
   the both-platforms rule. The qemu riscv64 guest joins the gate as soon as
   R0 makes it possible, as a third platform. It runs unit tests and the
   headless (pixman) live scripts. It never runs `--full`, because under TCG
   that would take hours.
5. **RV64 runs ADE when the last Swift binary in the session is gone.** Until
   then, amd64 and aarch64 run mixed sessions, and nothing ships worse than
   it does today.

## 4. Ordered passes

Sizes follow the PHASE docs (S/M/L). Each pass ends with its crates' unit
tests ported and passing, plus the live scripts that touch it.

**R0. The spike: Rust, our C libraries, and a window on FreeBSD/riscv64 (S).**
In a qemu riscv64 FreeBSD 16 guest (`qemu-system-riscv64 -machine virt`,
OpenSBI + u-boot, virtio disk and net). The boards come in at R8 (§6.1):
- Is `pkg install rust` available on riscv64, at what version? If not, can we
  build `lang/rust` ourselves?
- Are `wlroots 0.20`, `cairo`, `freetype2`, `harfbuzz`, `xkbcommon`, `pixman`,
  `gtk3` and `seatd` in the riscv64 package set? This blocks any language.
- Build a Rust binary that links `cwayland` + `cdraw` + `ctext` and draws one
  Aqua button into a headless compositor. Compare it against the Swift
  golden.
- Measure a debug and release build of a ~10k-line crate in the guest. TCG
  emulation is far slower than either board, so this number only decides
  whether the guest builds for itself or we cross-build into it (§6.9). It
  says nothing about the boards.

The answer goes in §5 the way SWIFT-ON-FREEBSD.md recorded P3.2's.
**If any package in the second bullet is missing, porting it comes before
R1.**

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

*(R0 fills this in.)*

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

**6.8 Risk: Rust on FreeBSD/riscv64 is Tier 3.** No upstream CI. A rustc
regression can break us with no warning. The mitigation is the one Swift got:
pin the toolchain version in `vm/config.sh`, keep R0's build as a CI job on
the board or in qemu, and treat a toolchain bump as its own pass.

**6.9 Risk: compile time under emulation.** TCG will be slow. If R0 shows a
release build of `aqua` in the guest is unworkable, we cross-build from
amd64 (`--target riscv64gc-unknown-freebsd` with a sysroot taken from the
guest), copy the binaries in, and test there. That is also the likely
workflow for the boards. Decide this from R0's numbers, not before.

**6.10 The qemu guest is a new VM to keep.** It is a third VM next to the
amd64 build guest. Its disk lives outside the monorepo with the others
(`$ABYSS_VM_HOME`), and it gets its own `vm/config.sh` stanza (host, port,
toolchain path).

## 7. Verification

Per pass: that crate's ported unit tests, its cross-language fixtures, the
live scripts that exercise its binary, on Linux and in the FreeBSD guest. R4
adds metal. R5 and R6 add the goldens. R7 runs `--full` twice. R8 runs it on
the board.
