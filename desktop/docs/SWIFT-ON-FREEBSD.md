# Swift 6 on FreeBSD 15 — the Phase-0 spike

**Status: a toolchain exists and installs (2026-07-28). Acceptance not yet met.**
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

**This is option (1) below, and it lands the risk far better than expected.**
It is *not* closed: acceptance is `swift build` **and** `swift test` succeeding
on **this repo**, and neither has been run yet. That is P3.2. What P3.1
established is that the toolchain installs and reports itself correctly.

This doc tracks the evaluation. Update it with findings as the spike progresses.

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

- `swift --version` reports 6.x in the FreeBSD VM (or a working cross-SDK).
- `swift build` + `swift test` succeed on this repo in/for FreeBSD.
- `Surface`/`Aqua` link against FreeBSD `wayland-client`, `cairo`,
  `freetype2`, `harfbuzz` (the cloud-init installs these).
- `AquaDemo` runs against stock `sway` in the VM (a Swift compositor of our own
  is Phase 6 — nothing here waits on it).

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
- _(append dated findings here as the spike runs)_
