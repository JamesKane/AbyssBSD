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
`menu-model`, `text-model`, `jails`, `system-facts`, `model` (its JSON), `vocabulary`. Pure Rust, no I/O beyond the
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

*textmodel, 2026-10-30:* `de/textmodel` (crate `text-model`) is
TextModel.swift and TextLayout.swift: editing, motion, undo, find and
wrapping. Swift's text is lines of Characters, so a caret never lands
inside an é written as e + accent, and Rust's std has no grapheme
clusters. Rather than a dependency (§6.5), `gen-graphemes.py` generates the
UAX #29 properties from the Unicode Character Database (Fedora's
`unicode-ucd`, 18.0) into `src/grapheme_tables.rs`, which is committed, and
`grapheme.rs` is the rules; every case of the UCD's own GraphemeBreakTest.txt
passes. Swift 6.3's tables are older, so the two could differ on a
character added since, and Unicode 18's conjunct rule (a virama joins the
next consonant with no consonant before it) is newer than Swift's. A line is
its text and its cluster ends, and an edit joins clusters without
re-segmenting, as Swift's arrays do: an accent typed after its letter is a
column of its own until the text is read again, which keeps Undo exact.
Fixtures in `abyss/tests/wire/text`: 14 editing scripts Swift runs and
records, command by command, and Rust replays (clusters of every kind,
motion, ranges, undo runs, find, layout). Two are pinned as `.rust.txt`: a
composed é does not find a decomposed one (Swift compares by canonical
equivalence), and a backward find from the end of the text finds the last
match, where Swift's finds nothing (BACKLOG §5).

*jails, 2026-10-30:* `de/jails` (crate `jails`) is JailClass.swift and
JailPlan.swift: the classes as `jails.ini` rows over the shipped five, and a
class plus a person made into the plan `jaild` performs (mounts, devices,
the generated `/etc`, parameters, environment), with the violations a root
daemon checks first. `jaild` and the keeper, and their tests, are R3. The
paths are compared by bytes, where Swift's `hasPrefix` and `contains` are by
Character: a component beginning with a combining mark joins the `/` before
it, so to Swift a class mounting `/home/abyss/◌́docs` does not reach the
person's home (BACKLOG §5). Fixtures in `abyss/tests/wire/jails`: seven
`jails.ini` files, each made into its classes, every class's plan for a
person and that plan's violations; six match Swift to the line, and
`combining-home` is pinned as `.rust.txt`.

*systemfacts, 2026-10-30:* `de/systemfacts` (crate `system-facts`) is
SystemFacts.swift: the facts and their report, fastfetch's formatting, and
the parsers over what the gatherer captured (`pciconf -lv`, `kldstat`,
`ofwdump`, `swapinfo`, the page counts, `kern.boottime`). Sizes saturate or
read as nothing where Swift's arithmetic traps. Fixtures in
`abyss/tests/wire/facts`: 26 captures and number lists through every parser
and formatter, the sample report among them; 25 match Swift to the line,
and `pci-crlf` is pinned as `.rust.txt` (Swift's CRLF capture is one line).

*vocab, and the JSON half of model, 2026-10-30:* the bridge writes its
transcript lines in Model's JSON, and JSON is a wire format and pure, so
`de/model` (crate `model`) begins with JSON.swift alone; HTTP, the session,
the transcript and the backends join it with `abyss-model` in R3. Numbers
are written as Swift writes them: whole ones below 9e15 as integers, others
by Swift's `Double.description` (decimal from 1e-4 to 2^53 inclusive,
exponential with a signed two-digit exponent outside it), so the two
transcripts are the same bytes. Parsing is RFC 8259's: Swift's `Double` and
`UInt32` parsers also take `+1`, `01`, `.5`, `1.` and `\u+abc`.
`de/vocab` (crate `vocabulary`) is Bridge.swift: what the agent may drive,
refusals in words, requester 1, and every step a transcript line; the
`abyss-vocab` binary is R3's. One change: when the application will not say
whether a verb writes, the verb is not run. Swift's check is a `try?` that,
failing, runs it unasked (BACKLOG §5); Rust refuses with the words and the
transcript line Swift gives when the activation itself fails. Fixtures:
`abyss/tests/wire/json`, 32 texts and 49 doubles by bit pattern (27 and 49
match; the five Swift-only number and escape forms are pinned), and
`abyss/tests/wire/vocab`, five scripts against the same fake applications in
both languages, every reply and every transcript line matching to the byte.

*R2 is done, 2026-10-30.* Fifteen crates beside their Swift targets, each
with Swift's tests ported and a corpus Swift writes and both read, in
`abyss/tests/wire/` (current, pool, menu, settings, install, fathom, dbus,
text, jails, facts, json, vocab). Where Rust reads differently, the case is
pinned as `<case>.rust.txt` with its reason; where the difference is a Swift
bug, it is in BACKLOG §5, to fix once the port is done.

**R3. Daemons and tools (L), in this order, each a swap of one binary:**
`vents` + `ventsctl`; `anchor` + `abyssctl`; `portal`; `dbus`, `dbusbridge`,
`dbusportal`, `dbusmenus`; `login` daemon (`abyss-loginwindow`) +
`loginctl`; `settingsrun` + `settingsctl`; `installrun` + `installctl`;
`jaild`, `jailkeeper`, `jailctl`; `fathom`; `idle`; `agent`, `model`,
`fetch`. The root daemons (`loginwindow`, `settingsrun`, `installrun`,
`jaild`) get the most care because their bugs are privilege bugs. Their Swift
tests are mostly refusal tests, and those all port.

*vents and ventsctl, 2026-10-30: the first swap.* `abyss/rust-bins` names
`ventsctl`, so the harness and the media run Cargo's. Under it: `de/spawn`
(crate `spawn`; Spawn.swift), `de/vents` (crate `vents`; the six Vents
files) and `de/ventsctl`, with `abyss-sys` gaining `vents` (cvents.c built
as SwiftPM builds it, libnv and libmixer on FreeBSD, and the getifaddrs,
poll and getpwuid calls) and `spawn` (the double fork behind `detached`,
built before it as Swift does; `run` is std's `Command`, a thread a stream,
so neither pipe can block the other). Swift's tests ported, and the
`waitpid(-1)` checks are a test binary of their own, since Rust's tests run
in parallel. `ventsctl`'s output and exit codes are Swift's, command for
command, on Linux and in the FreeBSD guest; `live-vents.sh` is green there
against real sysctls, `snd_dummy`'s mixer, devd events from an md(4) disk
and the routing socket. It was also flaky, for both languages: the player
it watches for had half a second to open `/dev/dsp`, which under bhyve is
one run in two; it now waits up to five. A devd line is now held as bytes
until its newline (Swift decoded each read, so a character split across two
reads was lost). `live-image.sh` installs from `.build/abyss-bin` where it
exists, so a medium carries what the harness tested. Fixtures in
`abyss/tests/wire/vents`: 16 captures through every parser, 15 matching
Swift and `devd-odd` (a CRLF line) pinned.

*anchor and abyssctl, 2026-10-30.* `de/anchor` (crate `anchor`) is
Policy.swift, Session.swift and Supervisor.swift: the restart policy, the
session as a plan, and the one poll loop over process descriptors, the
control socket, the lock screen's pipe and the signal pipe, with Swift's
journal lines. `de/anchorbin` is the `anchor` binary, `de/abyssctl` the
client; `abyss-sys` gains `proc` (cproc.c, libutil on FreeBSD, poll(2)).
Two changes, both from the swap itself. **The environment is a value**:
Swift `setenv`s what the session exports, and `set_var` is unsafe in Rust
2024, so the supervisor holds the session's environment and gives it to
every child (and `status` reports the bus from it, which is what a child
sees). **The siblings are found beside the path anchor was run as**, not
beside the resolved executable: the harness's bin directory links into
both builds, and `/proc/self/exe` pointed at `target/debug`, where no
AquaDemo or abyss-portal is. Swift's 31 tests ported. `live-anchor.sh` and
the scripts that run a session under it (`live-session`, `-session-gtk`,
`-locksession`, `-xcursor`, `-setup`, `-idlepolicy`, `-power`, `-greeter`,
`-switchuser`) are green against the Rust binaries on Linux. In the FreeBSD
guest `live-anchor`, `-xcursor`, `-setup`, `-idlepolicy`, `-greeter` and
`-switchuser` are green; the menu-bar ones (`-session-gtk`, `-locksession`,
`-power`, `-islands-bar`) failed there for both languages alike, run after
run, once the guest had been up a while (Swift passed each just after a
reboot, and the two anchors give their children the same environment and
write the same journal), so they are to be rerun on a quiet guest.

*portal, 2026-10-30.* `de/portal` (crate `portal`) is Portal.swift and
Service.swift: the request type with nowhere to put a path to open, the
outcome rules (exit status and result file read together), the PNG check,
and the service that runs the picker or `abyssgrab`, opens what was chosen
and hands back the descriptor. `de/portalbin` is `abyss-portal`.
`ap_run_and_wait` became std's `Command::status`, and the picker and the
grabber are found beside the path the portal was run as, for anchor's
reason. Swift's tests ported, with one more: a picker that does choose gets
its descriptor back, the file's own bytes. `live-portal`, `-sandbox`,
`-notify`, `-screenshot`, `-grab`, `-gtk`, `-session-gtk` and `-firefox`
are green against it on Linux, and all but `-session-gtk` (not run there,
for the guest's menu-bar trouble above) in the FreeBSD guest, where
`live-sandbox` proves
the capability itself: a Capsicum client reads the file it was handed and
cannot open its path.

*abyss-dbus, 2026-10-30.* `dbus` gains the connection (Connection.swift):
SASL, Hello, calls and what arrives. `de/dbusbridge` is Router.swift and
Endpoint.swift, the bridge that is not a bus; `de/dbusportal` the
FileChooser and Settings (Portal, Settings and Service.swift);
`de/dbusmenus` GTK's menus as MenuWire (GtkMenus and Bridge.swift);
`de/dbusbin` is `abyss-dbus` in its three modes, and `de/dbusprobe` the
probe the live scripts drive against GLib's `gdbus`. **Nothing is
dispatched inside a call**: Swift runs handlers and signal callbacks while
a caller waits for its own reply; here what arrives meanwhile is queued,
and the next `receive` hands it to the connection's owner, which answers in
order, on its own stack. A message comes with the descriptors it declared,
owned, so they close with it. The bridge's fan-out is in connection order
(Swift's came from a dictionary), and **a message carrying descriptors now
gets through it**: Swift took `ap_sendmsg_fds`'s byte count for an error
and dropped or stalled the receiver (BACKLOG §5). jaild's `grant` is one
call, kept in `abyss-dbus` until jaild's turn; `abyss-theme` is found
beside the path it was run as, for anchor's reason; and the accent's drift
test reads `Theme.swift`'s `menuHighlight` until the theme is in Rust.
Swift's 50 tests ported, with two more (a quote inside a match rule, and a
refused call that expected no reply gets none). On Linux `live-dbus`,
`-portal-dbus`, `-gtk`, `-palette`, `-appearance`, `-menus-gtk`,
`-submenus`, `-session-gtk` and `-firefox` are green against it. In the
FreeBSD guest `live-dbus`, `-portal-dbus`, `-gtk`, `-palette`,
`-appearance`, `-firefox`, `-jail-files` and `-jail-launch` are green; the
menu-bar ones (`-menus-gtk`, `-submenus`, `-session-gtk`) and the crash
reporter's (`-crash-dialog`, `-agents-off`, `-agent-gate`) failed there
for Swift as well, the menu-bar ones each at a different step, so they join
the rerun on a quiet guest.

*login, 2026-10-30.* `de/login` (crate `login`) is Login.swift,
Service.swift and Sessions.swift: the authenticator and its limiter, the
wire, the accounts the window offers, the clients, and the root daemon's
loop with its power policy and the greeter's sessions. `de/loginwindowbin`
is `abyss-loginwindow`, `de/loginctl` `abyss-loginctl`, and
`de/loginstub` `abyss-loginstub`, the test stand-in that serves the same
service with PAM replaced by a password file; it swaps with the other two,
because it is what puts the real service under test without root.
`abyss-sys` gains `pam` (cpam.c, OpenPAM on FreeBSD), `users` (the
password and group databases) and `Child::spawn_as` and `vt_activate`.
**The password is taken out of the request**, by `Msg::take_bytes`, and
that copy wiped when the answer is known: Swift wiped a copy of the bytes
and left the message's own. A name that is no account is keyed by a
stable hash, and passwd and group files are read by line, CR or not.
Swift's 16 tests ported, with three more (the password leaves the
request, every power action's wire name, accounts and auto-login from
their files). `live-authenticator`, `-lockscreen`, `-locksession`,
`-power`, `-idlepolicy`, `-greeter`, `-loginwindow` and `-switchuser` are
green against it on Linux. In the FreeBSD guest all but `-locksession`
and `-power` are, `live-authenticator` among them: root, OpenPAM, two
throwaway accounts each asking as itself, and sessions started as their
own uids. The two failed there for Swift as well, at different steps:
the menu-bar trouble again.

*settings, 2026-10-30.* `de/settingsrun` (crate `settings-run`) is
Service.swift: the authority (the uid it was started for, and only while
it is in the admin group, asked at each connection), the service's five
methods and the machine's own refusals, and the runner that stages every
file and replaces them all only when every write succeeded.
`de/settingsbin` is `abyss-settings` and `de/settingsctl`
`abyss-settingsctl`. Volumes.swift's `zfs list` parsing moves into
`settings::zfs`, since the helper's volume refusals read it (Disk Utility
reads it from there at R6). `abyss-sys` gains `crypt_sha512`,
`interface_index` and `local_timestamp`. Swift's pw root was a global;
here the runner is told it (`How`). **A staged copy's mode is set, not
only asked for**: Swift's `open(O_CREAT)` kept whatever mode a copy left
by a crash had, so a wpa_supplicant.conf could be put in place 0644. The
Swift runner tests ported (the dry run, whole-or-nothing, the half-way
failure, two files together, sysctl.conf's mode, wpa_supplicant.conf's),
with two over a socket: the wrong uid and a non-administrator refused in
words, and an unknown method named. `live-settings`, `-energy-pane`,
`-network-pane`, `-sound-pane`, `-wifi-pane`, `-activity`,
`-accounts-pane`, `-diskutility` and `-accounts` are green against it on
Linux, and all but `-sound-pane` in the FreeBSD guest, as root: accounts
made, logged in automatically and deleted with `pw`, a ZFS snapshot rolled
back, rc.conf and resolvconf.conf written whole. `-sound-pane` fails there
for Swift too, opening the pane by its verb (the menu bar's `recvmsg`).
`-wifi-pane` and `-wifi` were not run to the end: the guest's kernel
deadlocked under the wtap lab (a `wtap1_com_lock` → `ifnet_sx` lock-order
reversal, then every `ifconfig wlanN destroy` stuck in D state), and they
wait for a restarted guest. `-network-reboot` is `--full`'s.

*install, 2026-10-30.* `de/installrun` (crate `install-run`) is
Service.swift, Peer.swift, Runner.swift and Probe.swift: the authority
(one uid, asked of the kernel), the three methods, the runner that stops
at the first real failure, and the probe with its parsers over `geom`,
`mount -p`, `glabel`, `gpart show` and `zpool`. `de/installbin` is
`abyss-install` and `de/installctl` `abyss-installctl`; both swap. The
service takes the machine as a closure, as Swift did, so every refusal
is tested on a machine with no disks. A probe that cannot run is said to
the caller for `disks` and `check` alike, and a sizes-from-the-wire
overflow (BACKLOG §5) cannot trap the client either: `--swap` saturates
and a size prints through u128. Swift's 40 tests: 32 ported, 7 are wire
round trips `installwire` already has, and one (a closed descriptor
says no) cannot be written, since the service takes a `UnixStream`;
one more is new (a probe's refusal reaches the caller). `live-installer`
and `-installer-keyboard` are green against it on Linux; the guest and
`--full`'s `live-install` and `-desktop` are not run yet.

*jails, 2026-10-30.* `de/jaild` (crate `jaild`) is Steps.swift,
Performer.swift and Service.swift: the order a root is built and torn
down in, the performer that carries it out as root, the daemon's loop
(open, spawn, grant, revoke, grants; the kqueue that says a jail is gone;
SIGCHLD reaped), and `jaild::client`, which `abyss-dbus --jail` now uses
in place of its own copy of the grant call. `de/jailkeeper` (crate
`jailkeeper`) is Keeper.swift: a jail per class held for the session,
its Wayland security context, bridge, portal and menu bridge, launches
with the person's files granted in, agent sessions, crashes and the
`[apps]` watch. `de/jaildbin` is `abyss-jaild` and `de/jailctl`
`abyss-jail`; both swap. `abyss-sys` gains `jail` (cjail.c: jail(2),
jail and process descriptors, the removal kqueue, the login class's
limits, getmntinfo) and `wl::Display` with `jail_listen`
(cwayland_jail.c and the security-context protocol, in the Wayland build
it already had). **A grant refused by jaild refuses the launch**, as in
Swift; a file that cannot be opened is passed as it is. Swift's 16 jaild
tests and 7 keeper tests are ported, with three more: a point mounted
twice is unmounted twice, a regular file resolves and a directory does
not, and off FreeBSD the jail calls say ENOSYS. **Found by running it:**
the first `Display::connect` used `bool::then_some`, which builds its
value eagerly, so with no compositor a `Display(null)` was dropped and
`wl_display_disconnect(NULL)` crashed the keeper; `then` builds it only
when there is one. On Linux every jail and agent script skips, since
there are no jails there, and the keeper was run by hand without a
compositor: it binds, and refuses each method in words. **Nothing of this
group has run against a real jail yet**; that is the guest's, with
`live-jaild`, `-jail-gate`, `-jail-files`, `-jail-launch`, `-crash*` and
the `-agent*` scripts.

*fathom and idle, 2026-10-30.* `de/fathombin` is `fathom`: the half that
looks (sysctl, kenv, `kldstat`, `ifconfig -l`, /dev/dri, /dev/sndstat,
`--measure`, `--save` to the stick's ESP) over the probes `fathom` has
had since R2. One difference: a /dev/dri that exists and cannot be read
is `unknown`, where Swift read every failure to list it as no GPU. On
Linux its report is byte for byte Swift's, exit status included.
`de/idlebin` is `abyss-idle`: the idle policy (lock when the display
sleeps, ask the machine to sleep after the computer's delay) and the
session's power agent on the daemon's `watch` connection. Its
ext-idle-notify comes from `abyss-sys::wl::Idle`, over a small C shim
(`idle.c`: the notifier, a seat and two slots), since the toolkit that
carries it in Swift is R5's. `live-idlepolicy`, `-idle`, `-power`,
`-greeter` and `-switchuser` are green against it on Linux, the first
with undertow's real idle notifications. `live-medium`, fathom's, builds
a medium and is not run.

*agent, model, fetch and vocab, 2026-10-30.* The rest of the agent
runtime. `model` gains HTTP (the parser, and a client over a unix
socket, TCP or TLS), the session (the budget, refused before anything
leaves; the append-only transcript), the backends (canned replies, a
server, llama-server run as a supervised child) and the transcript read
back as sentences. `de/agent` (crate `agent`) is the loop and its tools,
`de/fetch` (crate `fetch`) the fetch bridge. `de/modelbin` is
`abyss-model`, `de/agentbin` `abyss-agent`, `de/fetchbin` `abyss-fetch`
and `de/vocabbin` `abyss-vocab`, over R2's `vocabulary`; all four swap.
`abyss-sys` gains `tls` (ctls.c, OpenSSL, behind a `tls` feature so only
what fetches links libssl) and a signal guard (guard.c) that stops
llama-server from a handler, as Swift's did, so a SIGTERM during a long
completion is not held up behind it. Two differences, both stricter: a
URL's host is ASCII only (an international name travels as punycode; a
lookalike letter is a homograph), and an IPv4-mapped IPv6 address is
judged as the IPv4 address it carries, so every private range is
refused through it, where Swift's prefixes caught three. Swift's model,
agent, fetch, transcript and URL tests are ported (JSON's were R2's),
with a unix-socket round trip and two more refusals. The agent scripts
skip on Linux (no jails), so the runtime was run by hand there: a stub
model and the agent answer, call a tool and stop at the budget the same
in every pairing of Rust and Swift `abyss-model` and `abyss-agent`, and
the two models' transcripts are the same bytes but for the time; the
fetch bridge asks, fetches once permitted, gives words without markup,
and refuses a private address; and TLS, against a local `s_server`,
takes a trusted certificate and refuses a self-signed one and a name
that does not match, in OpenSSL's words, as Swift does.

*the small tools, 2026-10-30.* `abyssmenu`, `abyssnotify`, `abyssopen`
and `abyss-appgen` swap. `abyss-sys` gains `sandbox` (ccap.c, Capsicum)
for `abyssopen`, and `de/appbundles` (crate `app-bundles`) is
AppBundles.swift, its tests ported. One change in `abyss-appgen`:
Terminal (`AquaDemo`) is looked for beside argv[0] as invoked, links not
followed, where Swift took its realpath; through the harness's
directory that names `.build/abyss-bin/AquaDemo`, which follows
`abyss/rust-bins`, and `live-appgen` now takes either path. Over the
desktop entries of this Linux box it makes the same 308 decisions and
the same bundles as Swift, those launcher paths aside. `live-appgen`,
`-vocabulary`, `-notify`, `-sandbox`, `-screenshot`, `-prefs`,
`-dock-apps`, `-firefox` and `-undo` are green on Linux. Left for later:
`abyss-theme` needs the theme loader and the cursors, R5's with the
theme; `abyss-vt` needs Terminal and the pty; `abyssgrab`,
`abyss-displays` and `abyssclip` are Wayland clients on `surface`, R5's.

**R4. `undertow` (L).** It runs over the same `cwlroots` shim and wlroots
0.20 (§6.3). The HANDOFF §2 lessons that undertow encodes become comments at
the code that encodes them, as in Swift. Gate: every live script that starts
a session passes with a Rust undertow and a Swift toolkit. Then the metal
check on the 12700KF: VT switch, session lock, output hotplug.

*R4's first finding, 2026-10-30: `cwlroots` is not narrow.* §6.3 and
§6.4 took it for a language-neutral shim with narrow headers. It is the
listener trampoline and little else, because **Swift's C importer reads
wlroots' own headers**: undertow calls 231 distinct `wlr_*` functions,
reads about 300 struct fields through `.pointee`, and uses the
headers' `static inline`s. Rust can do none of that without declaring the
structs, and mirroring wlroots' layouts by hand would break at every
wlroots release. So, keeping §6.4 (hand-written `extern "C"` over our own
headers, no bindgen), **`cwlroots` grows**: a C accessor or call for each
struct field and inline undertow touches, the wlroots types opaque to
Rust. C stays thin and decides nothing; the compositor's logic is Rust's.
R4 runs in passes: R4a the pure core (no wlroots at all), R4b the grown
shim, R4c the backend, scene and outputs, R4d the seat and its protocols,
R4e the shell protocols, then `undertowbin` and the gate.

*R4a, the pure core.* `de/undertow` (crate `undertow`): the metronome
(the vblank predictor, the measured latch margin, `Metronome` and the
multi-output `Conductor`), the flight recorder, C6's switch latencies,
the synthetic display and scene, and the placement rules (layer shell,
snapping, Ebb's grid, the island slide, hit-testing, remembered places).
`abyss-sys` gains `mono` (CLOCK_MONOTONIC and an absolute sleep, the
clock wlroots stamps presents with). The recorder is the present
thread's by `&mut` rather than shared through an atomic, there being no
second reader yet.
Then the key table (and the VT chord), shoals, the display layout and
displays.ini, the idle clock, frame arithmetic and cursor names, and
popup placement: 80 tests in all, the Conductor's real-time ones among
them (60 and 144 Hz synthetic displays each served at their own rate).

*R4's second finding: undertow is not toolkit-free.* It imports
`AquaDraw`: the theme (the title bar's height, the border, colours), the
window-chrome layout and hit-test its server-side frames share with Aqua
windows (`windowChrome`, `chromeHit`), the frames' and Ebb labels'
drawing, and the cursors' draw lists. So the gate as written ("a Rust
undertow and a Swift toolkit") cannot be met without part of R5 first:
the theme and the chrome layout, in Rust, before R4c draws a frame.
`FrameMetrics` takes its two sizes as arguments until then.

*The theme, pulled forward from R5 (2026-10-30).* `aquadraw` gains the
theme engine: `tokens` (`ThemeTokens`, generated from Theme.swift's
table: 121 colours, 62 metrics, 5 fonts, the chrome's gadgets),
`theme` (ThemeLoader: the strict parse with Swift's wording, OKLCH
mixes, schemes, bounded parameters, the search path, appearance.ini,
draw/ and icons/, the compiled Jaguar lists), `legibility` (the floor,
and the portal's palette), `chrome` (`window_chrome`, `chrome_hit`),
`draw` (`paint`, `clip`, `paint_window_chrome`) and `cursor` (resolve,
hotspot, draw, rasterise). Draw lists now resolve colour tokens and
`@metrics`, and a `text` op without `color=`/`size=` takes the theme's.
Two divergences: **the loaded theme is a value** (`Theme`, held by
whoever draws and handed to its `Runner`) rather than Swift's global,
and **the compiled Jaguar lists are the shipped files**, `include_str!`ed,
so there is no generated JaguarLists to keep in step (the test checks
that the list of files is the directory's). Held to five more goldens,
pixel for pixel: `frame`, `frame-depth`, `trench-frame`, `cursors`,
`cursors@2x`, now in `golden-rust.sh`; ThemeTests, ChromeTests and
LegibilityTests ported. The XCursor writer stays for `abyss-theme` (R5).

*R4b, the grown shim.* `de/cwlroots/tw-access.h` and `access.c` (not in
SwiftPM's sources; Swift needs none of it): an accessor per field undertow
reads, `tw_<type>_on_<signal>` so Rust never takes a member's address, and
structs of our own (`tw_rect`, `tw_texture_draw`, `tw_present`) where
wlroots wants one filled or read. Plain wlroots functions over opaque
pointers Rust declares itself. `abyss-sys` gains `wlr` behind a `wlroots`
feature: Copy handles (valid until wlroots destroys the object, which a
handle cannot enforce: holders let go in its destroy signal, as in Swift),
and owners for what Rust holds (`Display`, `OutputState`, `Listener`,
`Source`). **A listener may drop itself from inside its own callback**, as
Swift's output-destroy handler frees its own listener; the closure is
freed once it returns. The shim grows with its callers, a pass at a
time: this one carries the backend, outputs, the render pass, textures
and surfaces' drawing half, proved by a headless test (an output
announced, given a mode, drawn into with rects and a texture, read back,
committed and presented). *Finding: FreeBSD/riscv64's wlroots has no X11
backend and no Xwayland* (`wlr/config.h`). `cwlroots.h` now includes
x11.h only `#if WLR_HAS_X11_BACKEND`, and the backend's name comes from
C, which can ask.

*R4c, first: the bridge* (`de/undertow/src/backend.rs`, Backend.swift).
`WlrootsSession` (display, backend, renderer, allocator; outputs that come
and go; the stand-in VT) and `WlrootsOutput`, which wears R4a's `Output`
trait: submit, the present ring, the refused-commit ring, the snapped
grid, `wait_until`'s reserve and slop, the PPM capture. Swift's classes
become an `Rc<RefCell<…>>` the listeners hold weakly, with the hooks kept
apart so one may call back into the session from inside wlroots' signal.
What draws an output is a `Painter` (the scene and the cursor, R4c's
next), and **`needs_frame` sets the painter's dirty flag** instead of
calling it: wlroots raises it from inside commits and dispatches, where
the painter may be borrowed. Five headless tests, the metronome driving a
wlroots output among them.

*R4c, second: the scene and the cursor's pictures* (`scene.rs`, `ebb.rs`,
`cursor_images.rs`). The structure-of-arrays scene, its paint order, the
lock, Ebb, island slides, the Shoals strip, subsurface trees, crops and
transforms, explicit sync's waits, present-on-damage's signature, the
cull, and the draw. Swift's scene reads the compositor; this one latches
from a **`World` trait** the compositor will implement (R4d/e): windows,
layers and popups as plain values, and calls for what only the compositor
makes (a frame's texture, labels, Ebb, a slide). Ebb's slots name their
window by id. The tests drive what needs no client (the lock colour, Ebb's
dimming, the strip's plate and label, the cull across two displays at
scale 2, the unchanged frame and the four things that redraw it) through a
headless output, pixels read back; windows wait for clients (R4e). The
cursor's textures are aquadraw's rasteriser, cached per shape, scale and
theme; drawing the cursor is the Seat's (R4d).

*R4d and R4e swap.* Seat.swift routes to the compositor's toplevels,
layer surfaces, popups, lock, drags, Ebb and shoals at every turn, so the
compositor comes first (R4d) and the seat after (R4e).

*R4d, first: the compositor core* (`compositor.rs`; Compositor.swift,
LayerShell.swift's surfaces, Popups.swift). The globals and the socket;
toplevels (the first commit's configure and capabilities, placement,
cascade, remembered places, focus as the window sees it, stacking,
maximize, minimize, fullscreen, the Dock's foreign-toplevel handles,
`suspended`), layer surfaces and their arrangement, popups and their
unconstraining, outputs lost and returned, the frame callbacks (the
hidden clock included), and the scene's `World`. Swift's back-pointing
classes are `Rc`s with `Cell`/`RefCell` fields, each borrowed only for a
moment and never across a call into wlroots, so they are reentrant as
Swift's are and destroy signals stay synchronous. Focus moves the
window's state and calls a hook the seat will take. Tested with **real
clients** (an shm xdg_toplevel per thread, on `ShmWindow::open_on`'s named
socket): mapping, centring, cascading, focus, the Dock handle, close,
remembered places, minimize and maximize and their keyboard rules,
stacking, Cmd-Q, and the scene drawing a client's pixels where it was put.
Two findings: **a destroyed toplevel has no title left** to remember its
place under (BACKLOG §5: Swift loses it; Rust keeps the last key), and
**setting `WLR_RENDERER` races with other threads' `getenv`** (the
tests' clients segfaulted): a headless backend now asks for pixman
directly, `$WLR_RENDERER` still winning.

*R4d, then: frames, islands, Ebb and shoals* (`decorations.rs`,
`tide.rs`). xdg-decoration answered server-side, held until the first
commit, each frame aquadraw's chrome cached until its size, focus, title
or theme changes; the compositor takes the theme and a runner, and its
frame metrics are the theme's. Island switches (the commit, the slide,
the C6 stamp, `suspended`, focus), moving a window between islands,
islands.ini reloaded; Ebb opened, hovered, picked and dismissed, with its
labels; shoals made, joined, left, recalled from the keyboard and the
strip, and saved. All tested with real clients. Finding: **CText is one
thread's** (its FreeType library and face table are globals, as Swift's
`Text` is static), and two tests drawing text at once crashed in
FreeType. aquadraw's `Text` now claims CText for its thread, reentrantly,
and is `!Send`; a program draws on one thread and never waits.

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
