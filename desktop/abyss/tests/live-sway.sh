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
# Needs: sway (>=1.11), grim. Uses the headless backend + pixman software
# renderer, so no GPU/DRM is touched (hence --unsupported-gpu is harmless here).
#
# INPUT CAVEAT: the headless backend attaches no input devices, so the seat
# advertises capabilities:0 and the client never binds wl_pointer. --click
# drives sway's cursor over IPC, but with no pointer capability those events are
# not delivered to the surface, so the pointer path (clicks, hover) is NOT
# exercised here. Testing it headlessly needs a wlr-virtual-pointer client
# (TODO); for now interaction is verified by hand under a real session.
set -eu

scene="${1:-sysprefs}"
out="${2:-${TMPDIR:-/tmp}/aqua-live-$$.png}"
click="${3:-}"

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }
command -v grim >/dev/null || { echo "FAIL: grim not installed"; exit 1; }

swift build

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
  [ -n "${app_pid:-}" ] && kill "$app_pid" 2>/dev/null || true
  [ -n "${SWAYSOCK:-}" ] && swaymsg exit >/dev/null 2>&1 || true
  kill "$sway_pid" 2>/dev/null || true
  rm -f "$cfg" "$log"
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
  # Best-effort: drive sway's cursor over the default gel button (bottom-right
  # of the .window scene; the window fills the output at 0,0 so window coords ==
  # output coords). See the INPUT CAVEAT above — with no pointer capability this
  # does not currently deliver events to the client.
  swaymsg "seat - cursor set 360 265" >/dev/null 2>&1 || true
  swaymsg "seat - cursor press button1" >/dev/null 2>&1 || true
  swaymsg "seat - cursor release button1" >/dev/null 2>&1 || true
  sleep 0.5
fi

WAYLAND_DISPLAY="$wd" grim "$out"
test -s "$out" || { echo "FAIL: grim produced no image"; exit 1; }
echo "ok: live render -> $out (window mapped, no crash)"
