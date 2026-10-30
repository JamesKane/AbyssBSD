# ADE in Rust: the rewrite (scope)

**Status: scoped 2026-10-30; §6 adopted as recommended the same day; R0 done
the same day (§5).** This replaces "the product is Swift, top
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
done, so that a failing live script always means a porting bug. *But not
Swift's quirks* (decided 2026-10-30): where Swift's answer on odd input comes
from the language (Characters, canonical equivalence, `UInt64("-0")`) rather
than from ADE's design, Rust does the plain thing, and the fixture pins
Rust's answer beside Swift's as `<case>.rust.txt`. Everything ADE itself
writes reads the same in both.

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
pinned by `Cargo.lock` (§6.5).

*Done 2026-10-30.* The workspace, `abyss-sys` and `aquadraw`'s Rust half
came with R0. The harness runs every binary from `$ABYSS_BIN_DIR`
(`common.sh`; 379 paths rewritten in 117 scripts): `abyss/mk/bin-dir.sh`
makes `.build/abyss-bin`, a symlink per binary to SwiftPM's build or, for
each name in `abyss/rust-bins`, to Cargo's, so a binary changes language by
one line there. `run.sh` builds and tests both trees, makes that directory,
cross-builds the workspace for riscv64 where the sysroot is, and runs
`golden-rust.sh` beside `golden.sh`; `vm/build.sh` builds both in the
guest, which now has `rust` 1.99.

**R2. Wire and data crates (M).** `current-ipc`, `pool-config`, `menu-wire`,
`settings`, `settings-wire`, `fathom`, `install`, `install-wire`, `dbus` (the wire half),
`menu-model`, `text-model`, `jails`, `system-facts`, `vocab`. Pure Rust, no I/O beyond the
socket and the file. Cross-language fixtures (§3.3) go in here.

*currentipc, 2026-10-30:* `de/currentipc` (crate `current-ipc`) is
Msg.swift and Current.swift: the same wire format and framing, received
descriptors held as `OwnedFd` (closed on drop unless taken), no `unsafe`
of its own (the SCM_RIGHTS calls are `abyss-sys::platform`, over
`cplatform.c`). The first cross-language fixtures,
`abyss/tests/wire/current`: 21 cases Swift writes and both halves check
(11 decoded and re-encoded, lenient UTF-8 and a duplicate name among them;
10 malformed frames both refuse). Swift's 17 tests ported. `de/ipcprobe`
in Rust too, and `live-ipc-mixed.sh` runs Swift and Rust as server and
client all four ways, a descriptor crossing each time: green on Linux and
FreeBSD.

*poolconfig, 2026-10-30:* `de/poolconfig` (crate `pool-config`) is the nine
Swift files beside it: the same INI text in and out, the same coercions, the
same lock, temp file, fsync and rename. The watch is `abyss-sys::poolwatch`
over `cpoolwatch.c`, its kqueue table behind a mutex (Swift never had two
threads in it; Rust's tests do). Fixtures in `abyss/tests/wire/pool`: 29
`.ini` files Swift reads and both check. Rust reads plain text where Swift
reads Characters (§1, its quirks): lines end at `\n` and CR is trimmed, so a
CRLF file reads (Swift's is one long key, BACKLOG §5); a combining mark does
not hide a delimiter; U+037E is not `;`; `"-0"` is no `UInt64`; and names
compare and sort by bytes, not canonical equivalence. Ten cases differ from
Swift for these reasons. Each is listed in the test and pinned as
`<case>.rust.txt`; the other 19 match.

*menumodel and menuwire, 2026-10-30:* taken together, since the wire is
made of the model's types. `de/menumodel` (crate `menu-model`) is
Command.swift: commands, key equivalents, menus, enablement, results and the
GTK menu address, with no dependencies. `de/menuwire` (crate `menu-wire`) is
Wire.swift, Service.swift and Client.swift: the same four methods, nested
`Msg`s and the same checks before `perform`. Swift holds its provider
weakly; here the application lends itself to each `service_readable` call,
so "the application has gone" cannot happen. A subscriber gets a send
timeout, so one that stops reading is dropped rather than blocking the
application (Swift blocks, BACKLOG §5). Fixtures in `abyss/tests/wire/menu`:
30 replies and requests (13 re-encoded to the byte, 4 decoded only, 13 that
both refuse with the same words), plus `service-names.txt`. A key is one
`char` where Swift's is one Character, and names are slugged a `char` at a
time. Because of that, a letter with a combining accent is not a key, and
the service names differ for decomposed accents, İ, a final ς and emoji
sequences. Those two cases are pinned as `.rust.txt`. Swift's tests ported,
as well as GtkMenuAddress's round trip (the rest of GtkMenusTests is
`dbusmenus`, R3).

*settings and settingswire, 2026-10-30:* together, as the menus were: the
wire is made of the plan's types, and `settings` has no I/O (it decides and
compiles; `settingsrun` executes, R3), so it joins R2. `de/settings` (crate
`settings`) is Settings.swift, Wifi.swift and WifiKey.swift: the plans, their
refusals word for word, the steps and their rendering, the sysctl.conf and
wpa_supplicant.conf editors, the scan parser, and PBKDF2-SHA1 for the PSK.
Swift's one-field wrappers (`VolumePlan`, `AccountPlan`, `PowerProfilePlan`)
are the enum's payloads here, and `pw`'s root is an argument rather than
Swift's global. `de/settingswire` (crate `settings-wire`) is Wire.swift. A
list's count is not trusted: Swift traps on a count or an index past
`Int.max` and counts up to whatever it is told, while Rust reads the indexed
fields the message holds. Fixtures in `abyss/tests/wire/settings`: 87
messages and 17 texts. A plan's text is the plan, its refusals and the steps
`check` renders, so both languages are held to the same commands from the
same request. 41 re-encode to the byte; the rest are decode-only or refused,
the same way. Four are pinned as `.rust.txt`: hex is digits only (Swift's
takes a sign, so `+a:…` was a BSSID and `ssid=+f` a name), and CR is a blank
in both editors (Swift's CRLF file is one line: BACKLOG §5). The Swift
tests ported, except the runner's, which are `settingsrun`'s.

*fathom, install and installwire, 2026-10-30:* together again, for the
same reason: the wire is made of `install`'s types, `install` has no I/O
beyond reading rc.conf for the keymap (`installrun` executes, R3), and its
loader.conf asks `fathom` whether the machine is a Mac Pro, so the probes
came too (pure functions over captured text; the `fathom` binary that gathers
is R3). `de/fathom` (crate `fathom`) is Probe.swift and Report.swift;
`de/install` (crate `install`) is the plan, the inventory, the refusals word
for word, the step list and its rendering (the golden list is Swift's, to
the byte) and the keymap tables; `de/installwire` (crate `install-wire`) is
Wire.swift. Settings' indexed-list reader moved into `current-ipc` as
`Msg::indexed`, which both wires use. Rust saturates where Swift traps on a
size from the wire (an ESP near `UInt64.max` crashed `problems`), and pool
names are ASCII as ZFS's are. Fixtures in `abyss/tests/wire/install`: 52
messages and 12 texts. A `check` message is a plan and the machine together,
and its text is the plan, the machine, the refusals and the steps, so both
languages are held to the same commands at the same disk. 38 re-encode to
the byte. Three are pinned as `.rust.txt`: a Unicode pool name (Swift passes
`école`, which `zpool create` refuses after `gpart` has run), a decomposed
letter in a full name (quoted in the rendering), and CRLF rc.conf. And
`abyss/tests/wire/fathom`: 66 captured texts through every probe, two
pinned (CRLF kldstat, and folding a decomposed accent). The Swift tests
ported, except `installrun`'s parsers and runner (R3).

*dbus, the wire half, 2026-10-30:* `de/dbus` (crate `dbus`) is
Value.swift, Marshal.swift and Message.swift, and the bus address from
Connection.swift; the connection itself (SASL, dispatch, descriptors over
the socket) is R3's, with `dbusbridge`. The bytes are Swift's, alignment
origins and all. What Swift reads that is not a value, Rust refuses: a
signature is parsed, not split (an unbalanced one, `()`, a dict entry not of
two types, a variant of more than one type), and values nest at most 64
deep, as the specification says. Swift's array of `()` loops for ever and
its nested variants run the stack out; both are unit tests here, since the
Swift writer cannot survive them. Marshalling returns errors where Swift
traps (a signature past 255 bytes) or writes a lie (an array whose items
are not its element type). A decoded message's `fds` is empty, its
descriptors being in its body, so it re-encodes to itself (the bridge clears
Swift's by hand). Fixtures in `abyss/tests/wire/dbus`: 43 messages, 8
addresses. The 10 valid messages re-encode to the byte, descriptors
included; a big-endian peer's message, a bool of 2 and ignored header
fields are decode-only and read the same; six are pinned as `.rust.txt`.

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

**2026-10-30: the cross-build works end to end, and Rust matches the goldens
on riscv64.**

- **The riscv64 world.** Poudriere jail `rv64` on the builder VM:
  `poudriere jail -c -j rv64 -a riscv.riscv64 -m src=…/src -b -x`, our
  `src/` fork cross-built with native-xtools, 1h25m on 12 cores (1600032).
  qemu-user-static is 3.1.0, the only one packaged, and it is enough.
- **The packages.** 117 of R0's tree built in about 25 minutes, nothing
  failing in its own right. What the riscv64 set needs is
  `vm/rv64-make.conf` (`vm/rv64-build.sh` installs it, makes the jail if
  missing and runs the bulk of `vm/rv64-ports.list`):
  - `lang/rust` IGNOREs under qemu-user-static, and three things pulled it
    in: librsvg2 (gtk3's icons: `DEFAULT_VERSIONS+= librsvg2=legacy`, the C
    one), and xwayland and libdecor (wlroots020's X11 option: off; ADE has
    no XWayland, PRODUCT §5.2).
  - sqlite3's post-install runs `ldd -a` on its binary, which ld-elf cannot
    do under qemu-user ("mmap of entire address space failed"). Only colord
    wanted it: gtk30's COLORD option is off.
  - llvm19 (mesa needs it unconditionally) runs its tablegens under
    emulation, and twelve at once ran the 14G VM out of memory (code 137):
    `MAKE_JOBS_NUMBER=4` for it.
  - gtk30's DOCS run gtkdoc-mkhtml emulated, and it fails: off.
  - With those, the whole of R0's list and sway 1.12 and grim built: 250
    packages, mesa 26.2 and llvm19 among them.
- **Rust's std** cross-builds for `riscv64gc-unknown-freebsd` with
  `nightly-2026-10-04` and `-Zbuild-std=std,panic_abort`, linked by the
  host's clang 22 and lld against the sysroot, in about 12 s. Threads, fs
  and libc run in the guest.
- **The window, as a scene.** There is no golden of a lone button, and every
  scene goes through the draw-list interpreter, so the spike ported that:
  `DrawList.swift` and what `renderDrawListPNG` reaches of Text and Draw,
  2.8k lines of Rust, `libc` and `cc` only, `unsafe` only in its ffi module,
  over our unchanged `cdraw` and `ctext` and cairo. Its `drawlist` scene is
  **identical** to the Swift goldens at 1x and 2x: on Linux against
  `golden/linux/`, and cross-built and run in the riscv64 guest against
  `golden/freebsd/` (DejaVu, our packages). 0.55 s a render under TCG.
- **A latent C bug it found.** `cd_noise_a8` multiplied signed ints past
  overflow, undefined behaviour that GCC -O2 turned into a different noise
  tile (18,454 pixels of the anodized panel). SwiftPM's debug builds
  happened to wrap. Fixed with unsigned arithmetic in `c23ca19`; the goldens
  stand.
- **The tooling.** `vm/rv64-sysroot.sh` pulls the jail's world and the
  repository from the builder and unpacks the packages into
  `$ABYSS_RV64_SYSROOT`. `vm/rv64-cross.sh` runs a command with cargo, cc
  and pkg-config aimed at it. `vm/provision-rv64.sh` gives the guest pkg
  from our repository (`IGNORE_OSVERSION`: the image's world is the stock
  1600029, ours is 1600032). The guest's build user is in `operator`, so
  `ssh.sh shutdown -p now` stops it.
- **The scene in a compositor.** `abyss-sys` has a Wayland client:
  libwayland-client, and `wl.c` exporting the requests wayland-scanner emits
  as `static inline`s (§6.4). The `window` example shows the drawlist scene
  in an `xdg_toplevel`; `abyss/tests/window-shot.sh` captures it from a
  headless sway (pixman renderer, no borders) with grim, and
  `golden-rust.sh` holds it to the same golden as the PNG.
- **R0 is done (2026-10-30):** `golden-rust.sh --rv64` is green in the
  guest, PNG and window at 1x and 2x, against `golden/freebsd/`: Rust
  cross-built on the host, run on FreeBSD/riscv64 under sway 1.12 and
  wlroots 0.20 that we built, identical to what Swift draws on amd64. 26 s
  for the run, cross-build included.
- **Found on the way, in our `src`:** two LinuxKPI DMA changes that only x86
  and arm64 compile (`bus_dma_id_mapped`), so riscv's GENERIC did not build
  (fixed); and the fork predated `main`'s riscv TLB shootdown fix
  (f627ff51b), so on SMP riscv64 a fork corrupted memory whenever OpenSBI
  booted from a hart other than 0 (sshd failed with "string is too large").
  The fork is now merged with `main` (1600033); the guest runs it on 8
  harts.

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
`wayland-scanner`, as it is now. Its requests are `static inline`s, which
Swift calls and Rust cannot: `abyss-sys/wl.c` exports one function per
request Rust uses, from the same generated headers (R0). We don't adopt `wayland-rs`: it would
replace libwayland semantics that HANDOFF §2.57 (`wl_proxy_destroy` sends
nothing) and others pin down.

**6.5 Dependencies.** *Adopted: `libc`, `cc` (build) and nothing else
without a reason recorded here.* The Swift tree has no third-party
dependencies, so we keep it that way. Pinned by `Cargo.lock`, not vendored (decided
2026-10-30): a vendor directory would be 6.6 MB, nearly all `libc`, and
FreeBSD ports already build Cargo projects offline, `USES=cargo` fetching
each crate the lock names as a checksummed distfile (`make cargo-crates`).

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
