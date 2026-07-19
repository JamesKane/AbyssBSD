#!/bin/sh
# AbyssBSD Swift DE — live on-screen smoke test under a real compositor.
#
# The `run.sh` PNG path renders a scene straight to a cairo image surface; it
# never builds a Surface.Window, so it can't catch bugs in the live Wayland
# path (xdg-shell handshake, shm double-buffering, frame-callback pacing,
# configure/resize, pointer input, listener/object lifetimes). This script runs
# AquaDemo against a headless sway and captures the result with grim.
#
# Usage: abyss/tests/live-sway.sh [window|sysprefs] [out.png] [--click]
# Needs: sway (>=1.11), grim. With --click also: wayland-scanner + libwayland
# dev (to build the virtual-pointer helper). Uses the headless backend + pixman
# software renderer, so no GPU/DRM is touched (--unsupported-gpu is harmless).
#
# --click drives a real pointer click. The headless backend attaches no input
# devices (seat capabilities:0), so we create a wlr-virtual-pointer via the
# vpointer helper: it registers as an input device, the seat gains the pointer
# capability, and AquaDemo binds wl_pointer and receives events. --click forces
# the .window scene (it has the gel button + a Clicks counter); the output PNG
# should read "Clicks: 1".
set -eu

scene="sysprefs"; out=""; click=""
for a in "$@"; do
  case "$a" in
    --click)          click="--click" ;;
    window|sysprefs)  scene="$a" ;;
    *)                out="$a" ;;
  esac
done
[ -n "$out" ] || out="${TMPDIR:-/tmp}/aqua-live-$$.png"
[ "$click" = "--click" ] && scene="window"   # only the window scene is clickable

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }
command -v grim >/dev/null || { echo "FAIL: grim not installed"; exit 1; }

swift build

# Build the virtual-pointer helper up front (fail fast) when we'll click.
vp_dir=""
if [ "$click" = "--click" ]; then
  command -v wayland-scanner >/dev/null || { echo "FAIL: wayland-scanner missing"; exit 1; }
  pkg-config --exists wayland-client || { echo "FAIL: wayland-client dev missing"; exit 1; }
  vp_dir=$(mktemp -d)
  xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
  wayland-scanner client-header "$xml" "$vp_dir/vpointer-proto.h"
  wayland-scanner private-code  "$xml" "$vp_dir/vpointer-proto.c"
  cc -I"$vp_dir" "$root/abyss/tests/vpointer.c" "$vp_dir/vpointer-proto.c" \
     $(pkg-config --cflags --libs wayland-client) -o "$vp_dir/vpointer"
fi

# Size the headless output to the scene's natural window size so the (tiled)
# toplevel fills it exactly — a clean shot, and it exercises the app at the size
# it actually requests. Keep in sync with the sizes in de/aquademo/main.swift.
case "$scene" in
  sysprefs) res="760x620" ;;
  *)        res="440x300" ;;
esac
cfg=$(mktemp)
printf 'output HEADLESS-1 resolution %s position 0 0\ndefault_border none\n' "$res" > "$cfg"

log=$(mktemp)
env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman \
    WLR_LIBINPUT_NO_DEVICES=1 sway --unsupported-gpu -c "$cfg" > "$log" 2>&1 &
sway_pid=$!

cleanup() {
  [ -n "${vp_pid:-}" ] && kill "$vp_pid" 2>/dev/null || true
  [ -n "${app_pid:-}" ] && kill "$app_pid" 2>/dev/null || true
  [ -n "${SWAYSOCK:-}" ] && swaymsg exit >/dev/null 2>&1 || true
  kill "$sway_pid" 2>/dev/null || true
  rm -f "$cfg" "$log" "${fifo:-}" "${vp_log:-}"
  [ -n "$vp_dir" ] && rm -rf "$vp_dir" || true
}
trap cleanup EXIT

# Wait for sway's wayland + IPC sockets to accept clients.
wd=""
for _ in $(seq 1 40); do
  cand=$(ls -1 "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' \
         | grep -v '^wayland-0$' | head -1) || true
  if [ -n "$cand" ]; then
    ss=$(ls -1 "$XDG_RUNTIME_DIR"/sway-ipc.*."$sway_pid".sock 2>/dev/null | head -1) || true
    if [ -n "$ss" ] && SWAYSOCK="$ss" swaymsg -t get_version >/dev/null 2>&1; then
      wd="$cand"; break
    fi
  fi
  sleep 0.25
done
[ -n "$wd" ] || { echo "FAIL: sway not ready"; tail "$log"; exit 1; }
export SWAYSOCK="$ss"
echo "sway ready on $wd"

WAYLAND_DISPLAY="$wd" AQUA_SCENE="$scene" .build/debug/AquaDemo >/dev/null 2>&1 &
app_pid=$!

# Wait for the toplevel to map into sway's tree.
mapped=0
for _ in $(seq 1 32); do
  if swaymsg -t get_tree 2>/dev/null | grep -q '"app_id": "org.abyssbsd.aquademo"'; then
    mapped=1; break
  fi
  kill -0 "$app_pid" 2>/dev/null || { echo "FAIL: AquaDemo exited early"; exit 1; }
  sleep 0.25
done
[ "$mapped" = 1 ] || { echo "FAIL: window never mapped"; exit 1; }
sleep 1  # let a couple of frames paint

if [ "$click" = "--click" ]; then
  # Virtual pointer, fed via a FIFO so it stays alive (holding the pointer
  # capability) while we inject. Targets the default gel button — center
  # (360,265) of the 440x300 window scene, which fills the output at 0,0.
  vp_log=$(mktemp)
  fifo=$(mktemp -u); mkfifo "$fifo"
  WAYLAND_DISPLAY="$wd" "$vp_dir/vpointer" 440 300 < "$fifo" > "$vp_log" 2>&1 &
  vp_pid=$!
  exec 3>"$fifo"
  for _ in $(seq 1 20); do grep -q ready "$vp_log" && break; sleep 0.15; done
  grep -q ready "$vp_log" || { echo "FAIL: virtual pointer not ready"; cat "$vp_log"; exit 1; }
  caps=$(swaymsg -t get_seats | grep -o '"capabilities": [0-9]*' | grep -o '[0-9]*' | head -1)
  [ "${caps:-0}" -ne 0 ] || { echo "FAIL: seat gained no pointer capability"; exit 1; }
  echo "virtual pointer ready; seat capabilities=$caps"
  sleep 0.5  # let AquaDemo bind wl_pointer
  printf 'm 360 265\n' >&3   # move over the button
  printf 'p\n' >&3           # press
  printf 'r\n' >&3           # release -> one click
  sleep 0.5
  exec 3>&-
fi

WAYLAND_DISPLAY="$wd" grim "$out"
test -s "$out" || { echo "FAIL: grim produced no image"; exit 1; }
echo "ok: live render -> $out (window mapped, no crash${click:+, clicked})"
