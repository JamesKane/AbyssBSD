# Swift 6 on FreeBSD 15 — the Phase-0 spike

**Status: CLOSED, 2026-07-28. Acceptance met in full.** `swift build` and
`swift test` both succeed on this repo in the FreeBSD 15.0 VM: **62/62 tests
pass**, with no source changes — one `Package.swift` fix was the whole cost
(P3.2). The project's standing #1 risk is retired.

Swift's officially supported platforms are macOS, Linux, Windows, and
(experimental) Android — **FreeBSD is not an official swift.org target** — but
**FreeBSD ports carries one**, and it is current:

```
$ pkg install -y swift6          # NOT "swift" — that name matches nothing
$ /usr/local/swift6/bin/swift --version
Swift version 6.3.2 (swift-6.3.2-RELEASE)
Target: x86_64-unknown-freebsd15.0
```

That is **newer than the 6.3.1 we develop against on Linux**, and the package
ships `swift-build`, `swift-test`, `swiftc`, plus Foundation *and* `XCTest`
(`/usr/local/swift6/lib/swift/freebsd/XCTest.swiftmodule`) — so the test lane
looks available too, which was a separate worry (PHASE3.md §6.5).

**This is option (1) below, and it landed far better than expected** — not just
present, but able to build and test the real thing.

This doc tracked the evaluation. It is kept as the record of how the risk was
closed, and of the FreeBSD-specific facts that came out of it.

## Why it's plausible

- Swift's runtime sits on **libdispatch** (GCD), which originated on Darwin/BSD
  and is portable; and on an LLVM/clang backend that already targets FreeBSD.
- `swift-corelibs-foundation` / `-libdispatch` / `-xctest` are the portable
  layer that needs to build and pass on FreeBSD.
- Community FreeBSD ports of Swift have existed historically; the question is a
  *current 6.x* that is reliable enough to build on.

## Options, in the order to try them

1. **`pkg`/ports Swift. ✅ this is the one.** `pkg search -q swift` in the guest
   returns `swift510-5.10.1_2` and **`swift6-6.3.2`** (2026-07-28). The port
   installs to **`/usr/local/swift6/bin`**, deliberately *off* PATH so 5.10 and
   6.x can coexist — which is why `abyss/vm/config.sh` exports
   `ABYSS_GUEST_SWIFT_BIN` rather than assuming `swift` resolves (a
   non-interactive `ssh host 'cmd'` reads neither `.profile` nor
   `/etc/profile`). The seed's old `pkg install -y swift` reported a **false
   negative** for exactly one reason: the package is named `swift6`.
   Still to validate (P3.2): `swift build` + `swift test` on this repo.

2. **Cross-compile from Linux with a Swift SDK** *(not needed unless #1 fails to
   build the repo — kept for the record, and still attractive later if in-guest
   builds prove slow).*
   Swift 6 supports **Swift SDKs** for cross-compilation (the model used by the
   Static Linux SDK). Build/obtain a FreeBSD-amd64 Swift SDK, then from this
   Linux box:
   `swift build --swift-sdk x86_64-unknown-freebsd ...`
   Keeps the fast Linux edit/build loop; only the artifact is FreeBSD-native.
   This pairs naturally with our **Linux-first** decision.

3. **Build the toolchain from source in the VM.** Last resort: clone
   `swiftlang/swift` + the corelibs, build with the bundled `build-script` on
   FreeBSD 15. Multi-hour, fragile, but fully self-hosted. Capture the exact
   recipe here if we go this route.

## What "done" means (acceptance)

- ✅ `swift --version` reports 6.x in the FreeBSD VM — 6.3.2 (P3.1).
- ✅ `swift build` + `swift test` succeed on this repo in FreeBSD — **62/62**
  tests pass (P3.2).
- ✅ `Surface`/`Aqua` link against FreeBSD `wayland-client`, `cairo`,
  `freetype2`, `harfbuzz` — `AquaDemo` links and all 48 shared libraries
  resolve (P3.2).
- ⏳ `AquaDemo` runs against stock `sway` in the VM — that's P3.3, and it is
  a *runtime* question now, not a toolchain one. (A Swift compositor of our own
  is Phase 6; nothing here waits on it.)

## Notes / findings

- **2026-07-28 (P3.1).** Ports has **`swift6-6.3.2`** — `Swift version 6.3.2
  (swift-6.3.2-RELEASE)`, `Target: x86_64-unknown-freebsd15.0` — installed and
  reporting itself in the FreeBSD 15.0-RELEASE-p11 build VM. 600 MiB download,
  ~3 GiB installed, one extra dependency (`libuuid`). The toolchain includes
  `swift-build`/`swift-test`/`swiftc`/`lldb`/`clangd`, its own clang 21, and
  both Foundation and XCTest for `freebsd`. Two facts that cost time and are
  worth keeping:
  - the package is **`swift6`**, not `swift` (the old seed line looked like "no
    Swift on FreeBSD" when it was really "no package by that name"), and
  - it installs to **`/usr/local/swift6/bin`**, off PATH by design.
  Guest details for reference: sway **1.12** (Linux dev box has 1.11 — the
  version-drift risk of PHASE3.md §6.6 is real but small), wlroots019 0.19.3,
  wayland 1.25.0, xkbcommon 1.13.2, cairo 1.18.2, freetype2 26.6.20, harfbuzz
  14.2.1, libpng 1.6.58, base clang 19.1.7.
- **2026-07-28 (P3.2) — the repo builds and tests, and the risk is closed.**
  `swift build` succeeded and **all 62 tests passed** in the guest. What it took,
  and what it did *not*:
  - **One `Package.swift` change, no source changes.** `CWayland` was a plain C
    target carrying `.linkedLibrary("wayland-client")` and no include flags,
    which worked only because Linux keeps the headers in `/usr/include`. On
    FreeBSD they are under `/usr/local/include` and the build died on
    `'wayland-util.h' file not found`. Fix: a `CWaylandClient` **systemLibrary**
    target with `pkgConfig: "wayland-client"` that `CWayland` depends on — a C
    target cannot carry a `pkgConfig:` itself, but it inherits one from a
    systemLibrary dependency. Same pattern as `CFreeType`/`CHarfBuzz` feeding
    `CText`.
  - **`canImport(Glibc)` is TRUE on FreeBSD.** Swift names the platform libc
    module `Glibc` there, so all ~20 `#if canImport(Glibc)` guards took the
    right branch untouched. The feared twenty-file edit (PHASE3.md §6.4) cost
    nothing.
  - **The never-compiled branches work.** `CPoolWatch`'s kqueue/`EVFILT_VNODE`
    watch and `aw_create_shm`'s `SHM_ANON` had never been compiled anywhere;
    both built, and `testWatcherWakesOnStore` — the kqueue path's first
    execution in the project's life — passed.
  - **`timerfd` is real on FreeBSD 15.** `aw_create_interval_timer` compiled
    against `<sys/timerfd.h>` with no fallback needed.
  - **Two FreeBSD-specific facts worth carrying into runtime work:**
    `wayland-client.pc` adds `-I/usr/local/include/libepoll-shim` — libwayland
    there runs on an **epoll-over-kqueue shim**, so `wl_display_get_fd()` hands
    back a shim fd and our poll-based run loop (HANDOFF §2.14) is the thing to
    watch when the client first runs. And FreeBSD's `cairo.pc` carries
    `-D_THREAD_SAFE`, which SwiftPM refuses to forward: every build prints
    `warning: prohibited flag(s): -D_THREAD_SAFE`. It is dropped, it is benign
    for our single-threaded painting, and `abyss/vm/build.sh` filters it.
- **2026-09-30 (S.0) — 6.3.3 on both sides.** The guest follows the
  *quarterly* branch (still 6.3.2, since 2026Q4 has not opened); *latest* has
  `swift6-6.3.3`. To take one package from *latest* without switching the
  guest's branch, give pkg a second repo directory:
  `pkg -R /tmp/latest-repo update -r latest` over a `latest.conf` naming
  `pkg+https://pkg.FreeBSD.org/${ABI}/latest`, then `pkg -R /tmp/latest-repo
  install -r latest swift6`. The dry run moved `swift6` and nothing else. A
  guest provisioned fresh from `make-seed.sh` gets whatever quarterly carries,
  so until 2026Q4 opens it lands on 6.3.2 and needs the same step. Still no
  6.4 anywhere for FreeBSD amd64, and `swiftly list-available` on the Linux
  box stops at 6.3.3 too. *latest* also carries `wlroots020` 0.20.2 beside
  `wlroots019` 0.19.3 (MIGRATION §5).
- _(append dated findings here as the spike runs)_
