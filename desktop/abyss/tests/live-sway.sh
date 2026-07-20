#!/bin/sh
# AbyssBSD Swift DE — live on-screen smoke test under a real compositor.
#
# The `run.sh` PNG path renders a scene straight to a cairo image surface; it
# never builds a Surface.Window, so it can't catch bugs in the live Wayland
# path (xdg-shell handshake, shm double-buffering, frame-callback pacing,
# configure/resize, pointer input, listener/object lifetimes). This script runs
# AquaDemo against a headless sway and captures the result with grim.
#
# Usage: abyss/tests/live-sway.sh [window|sysprefs|widgets] [out.png] [--click] [--type]
# Needs: sway (>=1.11), grim. With --click/--type also: wayland-scanner +
# libwayland dev (to build the virtual-input helpers; --type also needs
# xkbcommon). Uses the headless backend + pixman software renderer, so no
# GPU/DRM is touched (--unsupported-gpu is harmless).
#
# The headless backend attaches no input devices (seat capabilities:0), so a
# client never binds wl_pointer/wl_keyboard and the input paths can't be tested.
# --click and --type each create a virtual input device (a wlr-virtual-pointer /
# a zwp_virtual_keyboard) which registers with the seat: the seat gains the
# matching capability and AquaDemo binds the input and receives events.
# --click's injected events adapt to the scene: the .window gel button (PNG
# should read "Clicks: 1"), or the .widgets checkbox + slider (checkbox 2 ticks
# on, slider/progress jump right). --type drives the .window text field (should
# read "Abyss"). An interacting run with no explicit scene defaults to .window.
set -eu

scene=""; out=""; click=""; type=""
for a in "$@"; do
  case "$a" in
    --click)                  click="--click" ;;
    --type)                   type="--type" ;;
    window|sysprefs|widgets)  scene="$a" ;;
    *)                        out="$a" ;;
  esac
done
[ -n "$out" ] || out="${TMPDIR:-/tmp}/aqua-live-$$.png"
# Pick a default scene: an interacting run wants a control-bearing scene.
if [ -z "$scene" ]; then
  if [ "$click" = "--click" ] || [ "$type" = "--type" ]; then scene="window"
  else scene="sysprefs"; fi
fi
# --type only makes sense where there's a focused text field.
[ "$type" = "--type" ] && scene="window"

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }
command -v grim >/dev/null || { echo "FAIL: grim not installed"; exit 1; }

swift build

# Build the virtual-input helpers up front (fail fast) when we'll inject.
vp_dir=""
if [ "$click" = "--click" ] || [ "$type" = "--type" ]; then
  command -v wayland-scanner >/dev/null || { echo "FAIL: wayland-scanner missing"; exit 1; }
  pkg-config --exists wayland-client || { echo "FAIL: wayland-client dev missing"; exit 1; }
  vp_dir=$(mktemp -d)
fi
if [ "$click" = "--click" ]; then
  xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
  wayland-scanner client-header "$xml" "$vp_dir/vpointer-proto.h"
  wayland-scanner private-code  "$xml" "$vp_dir/vpointer-proto.c"
  cc -I"$vp_dir" "$root/abyss/tests/vpointer.c" "$vp_dir/vpointer-proto.c" \
     $(pkg-config --cflags --libs wayland-client) -o "$vp_dir/vpointer"
fi
if [ "$type" = "--type" ]; then
  pkg-config --exists xkbcommon || { echo "FAIL: xkbcommon dev missing"; exit 1; }
  xml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
  wayland-scanner client-header "$xml" "$vp_dir/vkeyboard-proto.h"
  wayland-scanner private-code  "$xml" "$vp_dir/vkeyboard-proto.c"
  cc -I"$vp_dir" "$root/abyss/tests/vkeyboard.c" "$vp_dir/vkeyboard-proto.c" \
     $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$vp_dir/vkeyboard"
fi

# Size the headless output to the scene's natural window size so the (tiled)
# toplevel fills it exactly — a clean shot, and it exercises the app at the size
# it actually requests. Keep in sync with the sizes in de/aquademo/main.swift.
case "$scene" in
  sysprefs) res="760x620" ;;
  widgets)  res="460x360" ;;
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
  [ -n "${vk_pid:-}" ] && kill "$vk_pid" 2>/dev/null || true
  [ -n "${app_pid:-}" ] && kill "$app_pid" 2>/dev/null || true
  [ -n "${SWAYSOCK:-}" ] && swaymsg exit >/dev/null 2>&1 || true
  kill "$sway_pid" 2>/dev/null || true
  rm -f "$cfg" "$log" "${fifo:-}" "${vp_log:-}" "${vk_fifo:-}" "${vk_log:-}"
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
  # capability) while we inject. The output size (for absolute coords) matches
  # the scene's window, which fills the headless output at 0,0.
  case "$scene" in widgets) vpw=460; vph=360 ;; *) vpw=440; vph=300 ;; esac
  vp_log=$(mktemp)
  fifo=$(mktemp -u); mkfifo "$fifo"
  WAYLAND_DISPLAY="$wd" "$vp_dir/vpointer" "$vpw" "$vph" < "$fifo" > "$vp_log" 2>&1 &
  vp_pid=$!
  exec 3>"$fifo"
  for _ in $(seq 1 20); do grep -q ready "$vp_log" && break; sleep 0.15; done
  grep -q ready "$vp_log" || { echo "FAIL: virtual pointer not ready"; cat "$vp_log"; exit 1; }
  caps=$(swaymsg -t get_seats | grep -o '"capabilities": [0-9]*' | grep -o '[0-9]*' | head -1)
  [ "${caps:-0}" -ne 0 ] || { echo "FAIL: seat gained no pointer capability"; exit 1; }
  echo "virtual pointer ready; seat capabilities=$caps"
  sleep 0.5  # let AquaDemo bind wl_pointer
  case "$scene" in
    widgets)
      # Toggle the 2nd checkbox ("Show all file extensions"), then click near
      # the right of the slider track (press sets the value there).
      printf 'm 60 94\np\nr\n'   >&3
      printf 'm 384 197\np\nr\n' >&3
      ;;
    *)
      printf 'm 360 265\np\nr\n' >&3   # move over the gel button, click once
      ;;
  esac
  sleep 0.5
  exec 3>&-
fi

if [ "$type" = "--type" ]; then
  # Virtual keyboard, fed via a FIFO so it stays alive (holding the keyboard
  # capability) while we inject. It uploads its own US keymap, which sway makes
  # the seat's active keymap and forwards to AquaDemo.
  vk_log=$(mktemp)
  vk_fifo=$(mktemp -u); mkfifo "$vk_fifo"
  WAYLAND_DISPLAY="$wd" "$vp_dir/vkeyboard" < "$vk_fifo" > "$vk_log" 2>&1 &
  vk_pid=$!
  exec 4>"$vk_fifo"
  for _ in $(seq 1 20); do grep -q ready "$vk_log" && break; sleep 0.15; done
  grep -q ready "$vk_log" || { echo "FAIL: virtual keyboard not ready"; cat "$vk_log"; exit 1; }
  caps=$(swaymsg -t get_seats | grep -o '"capabilities": [0-9]*' | grep -o '[0-9]*' | head -1)
  # wl_seat capability bit 1 (value 2) is keyboard.
  [ $(( ${caps:-0} & 2 )) -ne 0 ] || { echo "FAIL: seat gained no keyboard capability (caps=$caps)"; exit 1; }
  echo "virtual keyboard ready; seat capabilities=$caps"
  sleep 0.5  # let AquaDemo bind wl_keyboard + receive the keymap
  printf 't Abyss\n' >&4     # type into the focused text field
  sleep 0.5
  exec 4>&-
fi

WAYLAND_DISPLAY="$wd" grim "$out"
test -s "$out" || { echo "FAIL: grim produced no image"; exit 1; }
echo "ok: live render -> $out (window mapped, no crash${click:+, clicked}${type:+, typed})"
