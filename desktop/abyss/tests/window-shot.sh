#!/bin/sh
# Capture a Rust example's window from a headless compositor (RUST.md R0):
# sway on wlroots' headless backend and pixman renderer, no borders, the
# window floated to the output's corner, grim on exactly its rectangle.
# golden-rust.sh runs it here, or copies it into the riscv64 guest.
#
#   window-shot.sh <window-binary> <list.dl> <scale> <w> <h> <out.png>
set -eu
bin=$1 list=$2 scale=$3 w=$4 h=$5 out=$6

work=$(mktemp -d "${TMPDIR:-/tmp}/abyss-window-shot.XXXXXX")
sp=""
trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; rm -rf "$work"' EXIT INT TERM HUP
rt=${XDG_RUNTIME_DIR:-}
if [ -z "$rt" ] || [ ! -w "$rt" ]; then
  # A runtime dir of our own, short enough for a socket path (108 bytes).
  rt=$(mktemp -d /tmp/abw.XXXXXX)
  chmod 700 "$rt"
fi

cat > "$work/sway.conf" <<EOF
output HEADLESS-1 resolution 1280x720 position 0 0 scale $scale bg #000000 solid_color
default_border none
default_floating_border none
for_window [app_id="org.abyssbsd.drawlist"] floating enable, move position 0 0
EOF
: > "$work/sway.log"
: > "$work/window.log"
env -i HOME="$work" PATH="$PATH" XDG_RUNTIME_DIR="$rt" WLR_BACKENDS=headless \
  WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
  sway -d -c "$work/sway.conf" > "$work/sway.log" 2>&1 &
sp=$!
sock=""
for _ in $(seq 300); do
  sock=$(sed -n "s/.*Running compositor on wayland display '\([^']*\)'.*/\1/p" "$work/sway.log" || true)
  [ -n "$sock" ] && break
  kill -0 "$sp" 2>/dev/null || break
  sleep 0.1
done
[ -n "$sock" ] || { echo "window-shot: sway did not start:"; tail -5 "$work/sway.log"; exit 1; }

env -i HOME="$work" PATH="$PATH" XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY="$sock" \
  LANG=C.UTF-8 TZ=UTC "$bin" "$list" "$scale" 30 > "$work/window.log" 2>&1 &
wp=$!
for _ in $(seq 600); do
  grep -q presented "$work/window.log" && break
  kill -0 "$wp" 2>/dev/null || { echo "window-shot: $(cat "$work/window.log")"; exit 1; }
  sleep 0.1
done
# One more frame's time for sway to map and float it.
sleep 1
env XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY="$sock" grim -g "0,0 ${w}x${h}" "$out"
kill "$wp" 2>/dev/null || true
