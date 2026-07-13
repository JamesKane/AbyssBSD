#!/bin/sh
# AbyssBSD Swift DE — build + test loop.
#
# Linux (primary, Phase 1–2): run from the repo root. Builds the SwiftPM
# package, runs unit tests, and renders one headless Aqua frame as a smoke test
# (no compositor required). Exits non-zero on any failure (CI-friendly).
#
# FreeBSD (Phase 3): same command in the VM once the Swift toolchain is up
# (see docs/SWIFT-ON-FREEBSD.md), then additionally runs the borrowed Rust
# engine's suite via kyua.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

echo "== swift build =="
swift build

echo "== swift test =="
swift test

echo "== headless Aqua render (smoke) =="
out="${TMPDIR:-/tmp}/aqua-smoke-$$.png"
AQUA_RENDER_PNG="$out" AQUA_SCALE=2 .build/debug/AquaDemo
test -s "$out" && echo "ok: $out" || { echo "FAIL: no PNG produced"; exit 1; }

echo "all green."
