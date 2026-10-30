#!/bin/sh
# Make the directory the harness runs every binary from (RUST.md §3.1):
# .build/abyss-bin, a symlink per binary, to SwiftPM's debug build, or to
# Cargo's for each name abyss/rust-bins lists. A component changes language
# by a line in that file; nothing in the tests changes.
#
#   abyss/mk/bin-dir.sh            # then ABYSS_BIN_DIR=.build/abyss-bin
#
# Symlinks, so a rebuild on either side is seen without running this again;
# run it again when abyss/rust-bins changes. common.sh uses the directory
# when it exists.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
swift=$root/.build/debug
rust=${CARGO_TARGET_DIR:-$root/target}/debug
out=$root/.build/abyss-bin

[ -d "$swift" ] || { echo "bin-dir: no $swift (swift build first)" >&2; exit 1; }
rm -rf "$out"
mkdir -p "$out"
n=0
for f in "$swift"/*; do
  # Executables only: SwiftPM's directory also holds objects, modules and
  # test bundles (directories).
  [ -f "$f" ] && [ -x "$f" ] || continue
  case $f in *.so|*.dylib|*.o|*.a|*.xctest) continue ;; esac
  ln -s "$f" "$out/$(basename "$f")"
  n=$((n + 1))
done
r=0
grep -v '^\s*#' "$root/abyss/rust-bins" | while read -r b; do
  [ -n "$b" ] || continue
  [ -x "$rust/$b" ] || { echo "bin-dir: abyss/rust-bins names $b, but there is no $rust/$b (cargo build)" >&2; exit 1; }
  ln -sf "$rust/$b" "$out/$b"
  echo "bin-dir: $b from Cargo"
done
echo "bin-dir: $out ($n binaries)"
