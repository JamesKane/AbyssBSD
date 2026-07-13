# Swift 6 on FreeBSD 15 — the Phase-0 spike

**Status: OPEN — the #1 project risk.** Swift's officially supported platforms
are macOS, Linux, Windows, and (experimental) Android. **FreeBSD is not an
official toolchain target.** The whole product depends on closing this. Until
then, all DE work happens on Linux (Swift 6.3.1 is installed and working here),
where the Aqua toolkit + shell are built against a stock wlroots compositor.

This doc tracks the evaluation. Update it with findings as the spike progresses.

## Why it's plausible

- Swift's runtime sits on **libdispatch** (GCD), which originated on Darwin/BSD
  and is portable; and on an LLVM/clang backend that already targets FreeBSD.
- `swift-corelibs-foundation` / `-libdispatch` / `-xctest` are the portable
  layer that needs to build and pass on FreeBSD.
- Community FreeBSD ports of Swift have existed historically; the question is a
  *current 6.x* that is reliable enough to build on.

## Options, in the order to try them

1. **`pkg`/ports `lang/swift`.** Cheapest if a current 6.x exists and works.
   Check `pkg search swift` in the VM; the cloud-init already attempts
   `pkg install -y swift` and drops a `~/.swift-todo` marker if it fails.
   Validate with `swift --version` + a hello-world + `swift test`.

2. **Cross-compile from Linux with a Swift SDK (preferred if #1 is stale).**
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
- `AquaDemo` runs against `sway` (stock) in the VM, then against the borrowed
  Rust `tide` compositor (Phase 3).

## Notes / findings

- _(append dated findings here as the spike runs)_
