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
# Each scene is drawn twice: to a PNG, and in a Wayland window that
# window-shot.sh captures from a headless sway (needs sway and grim), both
# held to the scene's one golden. The theme's scenes (`frame`, `cursors`)
# are drawn to a PNG, with the theme chosen as golden.sh chooses it, and
# only here: the guest has no themes/ yet. Each ported scene joins the list
# as it is ported, and the Swift gate keeps every one.
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

# name | golden | how (png, window, an example drawn to a PNG, or aquademo:SCENE,
# the Rust AquaDemo rendering AQUA_SCENE as golden.sh renders it) | scale | env
scenes='drawlist|drawlist|png|1|
drawlist@2x|drawlist@2x|png|2|
drawlist-window|drawlist|window|1|
drawlist-window@2x|drawlist@2x|window|2|
frame|frame|frame|1|
frame-depth|frame-depth|frame|1|ABYSS_THEME=chrome-test ABYSS_THEME_DIR=abyss/tests/themes
trench-frame|trench-frame|frame|1|ABYSS_THEME=trench
cursors|cursors|cursors|1|
cursors@2x|cursors@2x|cursors|2|
window|window|aquademo:window|1|
window@2x|window@2x|aquademo:window|2|
widgets|widgets|aquademo:widgets|1|
scroll|scroll|aquademo:scroll|1|
tabs|tabs|aquademo:tabs|1|
sheet|sheet|aquademo:sheet|1|
window-depth@2x|window-depth@2x|aquademo:window|2|ABYSS_THEME=chrome-test ABYSS_THEME_DIR=abyss/tests/themes
trench-window|trench-window|aquademo:window|1|ABYSS_THEME=trench
trench-window@2x|trench-window@2x|aquademo:window|2|ABYSS_THEME=trench
trench-widgets|trench-widgets|aquademo:widgets|1|ABYSS_THEME=trench
trench-sheet|trench-sheet|aquademo:sheet|1|ABYSS_THEME=trench
trench-tabs|trench-tabs|aquademo:tabs|1|ABYSS_THEME=trench
trench-scroll|trench-scroll|aquademo:scroll|1|ABYSS_THEME=trench
trench-hc-widgets|trench-hc-widgets|aquademo:widgets|1|ABYSS_THEME=trench ABYSS_THEME_SCHEME=neon-hc
trench-day-widgets|trench-day-widgets|aquademo:widgets|1|ABYSS_THEME=trench ABYSS_THEME_SCHEME=daylight
trench-day-window|trench-day-window|aquademo:window|1|ABYSS_THEME=trench ABYSS_THEME_SCHEME=daylight
menu|menu|aquademo:menu|1|
menu@2x|menu@2x|aquademo:menu|2|
menu-marks|menu-marks|aquademo:menu|1|AQUA_MENU_MARKS=1
menu-marks@2x|menu-marks@2x|aquademo:menu|2|AQUA_MENU_MARKS=1
trench-menu|trench-menu|aquademo:menu|1|ABYSS_THEME=trench AQUA_MENU_MARKS=1
icons|icons|aquademo:icons|1|
icons@2x|icons@2x|aquademo:icons|2|
trench-icons|trench-icons|aquademo:icons|1|ABYSS_THEME=trench
svg-beacon@2x|svg-beacon@2x|aquademo:icons|2|AQUA_DRAWLIST=abyss/tests/svg/beacon.dl
wallpaper|wallpaper|aquademo:wallpaper|1|
drawlist-roles@2x|drawlist-roles@2x|aquademo:drawlist|2|AQUA_DRAWLIST=abyss/tests/drawlist-sample.dl ABYSS_THEME=chrome-test ABYSS_THEME_DIR=abyss/tests/themes'

if [ "$rv64" = 1 ]; then
  vm="$root/abyss/vm"
  . "$vm/config.sh"
  target=riscv64gc-unknown-freebsd
  "$vm/rv64-cross.sh" cargo "+$ABYSS_RUST_NIGHTLY" build -q --release \
    -Zbuild-std=std,panic_abort --target "$target" --example drawlist --example window
  bin="$root/target/$target/release/examples"
  dir="$root/abyss/tests/golden/freebsd"
  rssh() { ABYSS_VM_ROLE=rv64 "$vm/ssh.sh" "$@"; }
  rssh 'rm -rf ~/golden-rust && mkdir -p ~/golden-rust/home ~/golden-rust/cfg' </dev/null
  tar -C "$bin" -cf - drawlist window | rssh 'tar -xf - -C ~/golden-rust'
  rssh 'cat > ~/golden-rust/drawlist-sample.dl' < abyss/tests/drawlist-sample.dl
  rssh 'cat > ~/golden-rust/window-shot.sh' < abyss/tests/window-shot.sh
else
  cargo build -q --release --example drawlist --example window --example frame --example cursors
  cargo build -q --release -p aquademo
  bin="$root/target/release/examples"
  dir="$root/abyss/tests/golden/$(uname -s | tr '[:upper:]' '[:lower:]')"
fi

echo "$scenes" | while IFS='|' read -r name golden how scale env; do
  out="$work/$name.png"
  # The scene's size in points, for the window's rectangle.
  size="520 200"
  if [ "$rv64" = 1 ] && [ "$how" != png ] && [ "$how" != window ]; then
    echo "  skip: $name (no themes/ in the guest yet)"
    continue
  fi
  if [ "$rv64" = 1 ]; then
    if [ "$how" = png ]; then
      rssh "cd ~/golden-rust && env -i HOME=\$PWD/home ABYSS_CONFIG_DIR=\$PWD/cfg LANG=C.UTF-8 TZ=UTC \
        ./drawlist drawlist-sample.dl out.png $scale >/dev/null && cat out.png" </dev/null > "$out"
    else
      rssh "cd ~/golden-rust && sh window-shot.sh ./window drawlist-sample.dl $scale $size out.png >&2 && cat out.png" </dev/null > "$out" || true
    fi
  elif [ "$how" = png ]; then
    env -i PATH="$PATH" HOME="$work/home" ABYSS_CONFIG_DIR="$work/cfg" LANG=C.UTF-8 TZ=UTC \
      "$bin/drawlist" abyss/tests/drawlist-sample.dl "$out" "$scale" >/dev/null
  elif [ "${how#aquademo:}" != "$how" ]; then
    # shellcheck disable=SC2086 # env is words
    env -i PATH="$PATH" HOME="$work/home" ABYSS_CONFIG_DIR="$work/cfg" LANG=C.UTF-8 TZ=UTC \
      AQUA_SCENE="${how#aquademo:}" AQUA_SCALE="$scale" AQUA_RENDER_PNG="$out" $env \
      "${bin%/examples}/AquaDemo" > "$work/$name.aqua.log" 2>&1
  elif [ "$how" != window ]; then
    # shellcheck disable=SC2086 # env is words
    env -i PATH="$PATH" HOME="$work/home" ABYSS_CONFIG_DIR="$work/cfg" LANG=C.UTF-8 TZ=UTC $env \
      "$bin/$how" "$out" "$scale" 2>/dev/null
  else
    sh abyss/tests/window-shot.sh "$bin/window" abyss/tests/drawlist-sample.dl "$scale" $size "$out" || true
  fi
  if "$work/pngdiff" "$out" "$dir/$golden.png" "$work/$name.diff.png" >"$work/$name.log"; then
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
