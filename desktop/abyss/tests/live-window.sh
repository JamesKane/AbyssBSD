#!/bin/sh
# AbyssBSD Swift DE — a window can be moved, resized, zoomed and put away (P9.4).
#
# Against undertow, because both halves are new and neither existed anywhere:
# `Surface.Window` sent exactly two toplevel requests before this pass
# (`set_title`, `set_app_id`), and undertow answered exactly one
# (`request_move`). **No Aqua window in this tree could be dragged by its title
# bar**, resized at all, zoomed, or minimized.
#
# The menu bar is up for the whole run, and that is deliberate: it reserves an
# exclusive zone, so "maximize" has an answer that is *not* the output
# rectangle. The zone has been computed since P6.4 and nothing had ever consumed
# it — a maximized window sliding under the menu bar is what that looks like.
#
# What makes any of this assertable is that undertow now says where its windows
# are (`window <key> <x>,<y> <w>x<h> [max|min]`). A Wayland client is never told
# its own position and learns its size a frame late, so the compositor is the
# only witness: without it a test can prove a request was made and never that
# anything happened.
#
# Usage: abyss/tests/live-window.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$aqua" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-window.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${dock_pid:-} ${app_pid:-} ${bar_pid:-} ${ut_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" 2>/dev/null || true
}
# INT/TERM as well as EXIT — see live-dnd.sh: a timeout that kills this shell
# without running the trap leaves a compositor squatting on a wayland-N socket.
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

# The last geometry undertow reported for a window key.
geom() { grep "^window $1 " "$work/ut.out" | tail -1 | cut -d' ' -f3-; }
# Wait for a window to reach an expected geometry, then assert it.
expect() { # key expected what
  i=0
  while [ $i -lt 24 ]; do
    [ "$(geom "$1")" = "$2" ] && break
    sleep 0.25; i=$((i + 1))
  done
  [ "$(geom "$1")" = "$2" ] \
    || fail "$3: expected '$2', got '$(geom "$1")'
    $(grep "^window $1 " "$work/ut.out" | tail -4)"
}

env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 \
    --config-dir "$work/ut-cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""; i=0
while [ $i -lt 80 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || fail "undertow exited before it announced a socket"
  sleep 0.25; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
echo "ok: undertow is up on $wd"

# ------------------------------------------------------- the menu bar's zone
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar \
    "$aqua" > "$work/bar.log" 2>&1 &
bar_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q 'LayerSurface: mapped' "$work/bar.log" 2>/dev/null && break
  kill -0 "$bar_pid" 2>/dev/null || fail "the menu bar exited: $(cat "$work/bar.log")"
  sleep 0.25; i=$((i + 1))
done
echo "ok: the menu bar is up, and its exclusive zone is now part of the answer"

# ------------------------------------------------------------- the window
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=window \
    "$aqua" > "$work/app.log" 2>&1 &
app_pid=$!
key="org.abyssbsd.aquademo/AbyssBSD"
i=0
while [ $i -lt 80 ]; do
  [ -n "$(geom "$key")" ] && break
  kill -0 "$app_pid" 2>/dev/null || fail "the window exited: $(cat "$work/app.log")"
  sleep 0.25; i=$((i + 1))
done
start=$(geom "$key")
[ -n "$start" ] || fail "undertow never reported the window: $(tail -3 "$work/app.log")"
# 440x300 centred in the usable area (800x578 below a 22px menu bar).
[ "$start" = "180,161 440x300" ] \
  || fail "the window did not open where this test expects: '$start'"
echo "ok: the window opened at $start — centred in the USABLE area, not the output"

# --------------------------------------------------------------- the Dock
#
# **This is where a minimized window goes, so it has to be running.** It is also
# the first time the Dock has ever seen anything under our own compositor:
# undertow created the foreign-toplevel *manager* and never made a handle, so
# its tiles had no running dots and a click on one could raise nothing. Every
# test that proved otherwise ran on sway.
env WAYLAND_DISPLAY="$wd" HOME="$work/home" ABYSS_CONFIG_DIR="$work/cfg" \
    AQUA_SCENE=dock "$aqua" > "$work/dock.log" 2>&1 &
dock_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q 'Dock: Trash' "$work/dock.log" 2>/dev/null && break
  kill -0 "$dock_pid" 2>/dev/null || fail "the Dock exited: $(cat "$work/dock.log")"
  sleep 0.25; i=$((i + 1))
done
echo "ok: the Dock is up"

# ---------------------------------------------------------------- the pointer
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" \
   || fail "could not build the virtual pointer"
fifo="$work/pointer"
mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 800 600 < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$fifo"
sleep 1.5

# ------------------------------------------------- drag it by the title bar
#
# The title bar is the strip above y=22 in the window, minus the lights and the
# pill. Press at its middle and move: the client sends `xdg_toplevel.move` once,
# on the press, and the compositor does the rest — which is the whole shape of
# window management on Wayland.
printf 'm 380 172\np\n' >&3
sleep 0.4
printf 'm 480 222\n' >&3
sleep 0.4
printf 'r\n' >&3
expect "$key" "280,211 440x300" "the title-bar drag did not move the window"
echo "ok: dragging the title bar moved the window (the client asked; undertow moved it)"

# --------------------------------------------------------------- zoom
#
# The green light. **To the usable area, not the output** — 800x578 at y=22,
# which is the first thing in this project to consume the menu bar's exclusive
# zone rather than merely compute it.
printf 'm 336 222\np\nr\n' >&3
expect "$key" "0,22 800x578 max" "the zoom light did not maximize to the usable area"
echo "ok: zoom filled the usable area — under the menu bar is not part of it"

# ...and again puts it back where it was, not where the compositor felt like.
# The light moved with the window: it is at (56, 33) now, not (336, 222).
printf 'm 56 33\np\nr\n' >&3
expect "$key" "280,211 440x300" "un-zooming did not restore the old box"
echo "ok: zooming again restored the window to where it was"

# --------------------------------------------------- resize from the corner
#
# The bottom-right corner. The anchored corner is the top-left, and it must not
# move by so much as a pixel while the size changes.
printf 'm 717 508\np\n' >&3
sleep 0.4
printf 'm 777 548\n' >&3
sleep 0.6
printf 'r\n' >&3
expect "$key" "280,211 500x340" "the corner drag did not resize the window"
echo "ok: dragging the corner resized it, and the anchored corner stayed put"

# ------------------------------------------------------- snap to an edge
#
# Drag the title bar to the left edge and let go: the left half of the usable
# area. Snapping happens on release, because a window that resizes while you
# are still moving it fights the pointer.
printf 'm 400 222\np\n' >&3
sleep 0.4
printf 'm 2 300\n' >&3
sleep 0.4
printf 'r\n' >&3
expect "$key" "0,22 400x578" "dragging to the left edge did not snap"
echo "ok: a drag to the left edge took the left half of the usable area"

# --------------------------------------------- minimize, and come back
#
# The yellow light. There is no `unset_minimized` request in the protocol — a
# window cannot un-minimize itself, and a client that could would — so the way
# back is the Dock tile, through `wlr-foreign-toplevel-management`. That makes
# this one gesture the test for both halves.
printf 'm 36 33\np\nr\n' >&3
expect "$key" "0,22 400x578 min" "the yellow light did not minimize the window"
echo "ok: the yellow light put the window away"

# It is off the screen in every sense that matters: the pointer goes through to
# what is behind it. The Dock is behind it — a bottom-layer surface the window
# was covering a moment ago — so a tile that responds is the proof.
#
# Seven tiles now (five pinned, this application, the Trash): 7x48 with 6px gaps
# centres a 372px shelf at x=214, so the application's tile is around x=508.
printf 'm 508 550\np\nr\n' >&3
expect "$key" "0,22 400x578" "clicking the Dock tile did not bring the window back"
echo "ok: its Dock tile brought it back — the tile exists, and it activates"

exec 3>&- 2>/dev/null || true
kill "$vp_pid" 2>/dev/null || true; vp_pid=""
kill "$app_pid" "$bar_pid" "$dock_pid" 2>/dev/null || true
sleep 0.5
# One of each. The counters count the *doing*, not the undoing — one zoom and
# one minimize, though each was also reversed — and the assertion is the whole
# line so a count that grows for the wrong reason cannot hide in it.
last=$(grep '^resizes-started=' "$work/ut.out" | tail -1)
[ "$last" = "resizes-started=1 maximizes=1 minimizes=1 snaps=1 lowers=0" ] \
  || fail "undertow's counters disagree with what this test just did: '$last'"
echo "ok: undertow's own counters agree — the requests were answered, not ignored"

echo "all green (moved, zoomed, resized, snapped, minimized — and brought back)."
