#!/bin/sh
# The golden gate for ADE's Rust half (RUST.md §3.2): the scenes Rust can
# draw so far, against the same committed goldens golden.sh holds Swift to,
# pixel for pixel.
#
#   abyss/tests/golden-rust.sh          # here: golden/<this os>/
#   abyss/tests/golden-rust.sh --rv64   # cross-built (vm/rv64-cross.sh), drawn in
#                                       # the running riscv64 guest, against
#                                       # golden/freebsd/ (RUST.md R0)
#
# Only `drawlist` so far: the scene needs no theme. Each ported scene joins
# the list as it is ported, and the Swift gate keeps every one.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
rv64=0
[ "${1:-}" = --rv64 ] && rv64=1

work=$(mktemp -d /tmp/abyss-golden-rust.XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM HUP
mkdir -p "$work/home" "$work/cfg"
cc -O1 "$root/abyss/tests/pngdiff.c" $(pkg-config --cflags --libs cairo) \
   -o "$work/pngdiff" || { echo "FAIL: could not build pngdiff"; exit 1; }

# name | example | arguments after the output file
scenes='drawlist|drawlist|1
drawlist@2x|drawlist|2'

if [ "$rv64" = 1 ]; then
  vm="$root/abyss/vm"
  . "$vm/config.sh"
  target=riscv64gc-unknown-freebsd
  "$vm/rv64-cross.sh" cargo "+$ABYSS_RUST_NIGHTLY" build -q --release \
    -Zbuild-std=std,panic_abort --target "$target" --example drawlist
  bin="$root/target/$target/release/examples"
  dir="$root/abyss/tests/golden/freebsd"
  rssh() { ABYSS_VM_ROLE=rv64 "$vm/ssh.sh" "$@"; }
  rssh 'rm -rf ~/golden-rust && mkdir -p ~/golden-rust/home ~/golden-rust/cfg' </dev/null
  tar -C "$bin" -cf - drawlist | rssh 'tar -xf - -C ~/golden-rust'
  rssh 'cat > ~/golden-rust/drawlist-sample.dl' < abyss/tests/drawlist-sample.dl
else
  cargo build -q --release --example drawlist
  bin="$root/target/release/examples"
  dir="$root/abyss/tests/golden/$(uname -s | tr '[:upper:]' '[:lower:]')"
fi

echo "$scenes" | while IFS='|' read -r name example args; do
  out="$work/$name.png"
  if [ "$rv64" = 1 ]; then
    rssh "cd ~/golden-rust && env -i HOME=\$PWD/home ABYSS_CONFIG_DIR=\$PWD/cfg LANG=C.UTF-8 TZ=UTC \
      ./$example drawlist-sample.dl out.png $args >/dev/null && cat out.png" </dev/null > "$out"
  else
    env -i PATH="$PATH" HOME="$work/home" ABYSS_CONFIG_DIR="$work/cfg" LANG=C.UTF-8 TZ=UTC \
      "$bin/$example" abyss/tests/drawlist-sample.dl "$out" $args >/dev/null
  fi
  if "$work/pngdiff" "$out" "$dir/$name.png" "$work/$name.diff.png" >"$work/$name.log"; then
    echo "  ok: $name"
  else
    echo "moved: $name — $(cat "$work/$name.log")"
    echo "$name" >> "$work/failed"
  fi
done
if [ -s "$work/failed" ]; then
  echo "FAIL: pixels moved in: $(tr '\n' ' ' < "$work/failed")"
  exit 1
fi
echo "all green (Rust, pixel for pixel, $( [ "$rv64" = 1 ] && echo "riscv64 guest" || uname -s))."
