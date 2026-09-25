#!/bin/sh
# AbyssBSD Swift DE — what only a compositor can do (PHASE6.md P6.7).
#
# The debt HANDOFF §2.22 recorded in Phase 2, when the spatial Finder was built:
#
#   "A Wayland client cannot position its own windows. Real spatial Finder
#    remembers each folder's window position; xdg-shell has no set-position, so
#    placement is the compositor's. What we can persist is size, view and mode —
#    position waits for Phase 6."
#
# It waited. This test pays it, end to end and in one session:
#
#   1. a window maps and the compositor places it;
#   2. the client asks to be MOVED (xdg_toplevel.move) and a real pointer drags
#      it somewhere else;
#   3. the window closes — the position is written to ~/.config/abyss/windows.ini;
#   4. an identical window opens again and lands where it was DROPPED, not where
#      a fresh window would be placed.
#
# Step 4 is the assertion. Steps 1–3 only set it up.
#
# Usage: abyss/tests/live-undertow-places.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build

W=800
H=600
APP=org.abyssbsd.test
TITLE=Documents
WIN_W=200
WIN_H=150
DRAG_X=560
DRAG_Y=420

work=$(mktemp -d /tmp/abyss-places.XXXXXX)
cfg="$work/config"
mkdir -p "$cfg"
cleanup() {
  [ -s "${pidfile:-}" ] && while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$pidfile"
  kill -9 "${ut_pid:-}" 2>/dev/null || true
  rm -rf "$work" "${bin_dir:-}"
}
trap cleanup EXIT
pidfile="$work/pids"
: > "$pidfile"

# Build the move oracle and the virtual pointer the way the harness always does.
bin_dir=$(mktemp -d)
cc -I "$root/de/cwayland/include" "$root/abyss/tests/adversary.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$bin_dir/adversary" \
  || { echo "FAIL: could not build the move oracle"; exit 1; }
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$bin_dir/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$bin_dir/vpointer-proto.c"
cc -I"$bin_dir" "$root/abyss/tests/vpointer.c" "$bin_dir/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$bin_dir/vpointer"

start_compositor() {   # start_compositor <outfile>
  env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames "$1" \
      --width "$W" --height "$H" --config-dir "$cfg" \
      > "$2" 2> "$work/ut.err" &
  ut_pid=$!
  wd=""
  i=0
  while [ $i -lt 60 ]; do
    wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$2" 2>/dev/null | cut -d= -f2-) || wd=""
    [ -n "$wd" ] && break
    kill -0 "$ut_pid" 2>/dev/null || { echo "FAIL: undertow exited early"
                                       cat "$work/ut.err"; exit 1; }
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$wd" ] || { echo "FAIL: undertow never announced a socket"; exit 1; }
}

spawn() { ( env WAYLAND_DISPLAY="$wd" "$@" >/dev/null 2>&1 & echo $! >> "$pidfile" ); }

# ============================================================ session one
start_compositor 700 "$work/run1.out"
( env WAYLAND_DISPLAY="$wd" "$bin_dir/adversary" move "$APP" "$TITLE" "$WIN_W" "$WIN_H" \
    > "$work/adv.log" 2>&1 & echo $! >> "$pidfile" )

# Wait for it to map, then drive the drag.
i=0
while [ $i -lt 100 ]; do grep -q 'mapped' "$work/adv.log" 2>/dev/null && break; sleep 0.1; i=$((i+1)); done
grep -q 'mapped' "$work/adv.log" \
  || { echo "FAIL: the test window never mapped"; cat "$work/adv.log" "$work/ut.err"; exit 1; }
echo "ok: a window mapped and the compositor placed it"

fifo="$work/vp.fifo"; mkfifo "$fifo"
( env WAYLAND_DISPLAY="$wd" "$bin_dir/vpointer" "$W" "$H" < "$fifo" > "$work/vp.log" 2>&1 &
  echo $! >> "$pidfile" )
exec 3>"$fifo"
i=0
while [ $i -lt 30 ]; do grep -q ready "$work/vp.log" && break; sleep 0.15; i=$((i+1)); done
grep -q ready "$work/vp.log" || { echo "FAIL: virtual pointer not ready"; exit 1; }
sleep 0.5

# The window is centred, so the pointer starts inside it. Press (which makes the
# client ask for a move), drag, release.
printf 'm %s %s\n' $((W / 2)) $((H / 2)) >&3 ; sleep 0.4
printf 'p\n'                             >&3 ; sleep 0.4
printf 'm %s %s\n' "$DRAG_X" "$DRAG_Y"   >&3 ; sleep 0.4
printf 'r\n'                             >&3 ; sleep 0.4

grep -q 'asked the compositor to move me' "$work/adv.log" \
  || { echo "FAIL: the client never issued xdg_toplevel.move"
       cat "$work/adv.log"; exit 1; }
echo "ok: the client asked to be moved, and a real pointer dragged it"

wait "$ut_pid" 2>/dev/null || true
ut_pid=""
while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$pidfile"
: > "$pidfile"
exec 3>&-

dropped=$(grep "^window $APP/$TITLE at " "$work/run1.out" | tail -1 | sed 's/.* at //')
[ -n "$dropped" ] || { echo "FAIL: the compositor never reported the window's position"
                       cat "$work/run1.out"; exit 1; }
echo "ok: it came to rest at $dropped"

# It must actually have MOVED — a test where the drag did nothing would sail
# through the reopen check below, because the window would simply be placed in
# the same default spot twice.
centre="$(( (W - WIN_W) / 2 )),$(( 22 + (H - 22 - WIN_H) / 2 ))"
[ "$dropped" != "$centre" ] \
  || { echo "FAIL: the window is still where it was first placed ($dropped)"
       echo "      the drag did nothing, so the reopen check would prove nothing"; exit 1; }

# The position must be on disk, in the same ini format everything else uses.
[ -f "$cfg/windows.ini" ] \
  || { echo "FAIL: no windows.ini was written"; ls -la "$cfg"; exit 1; }
echo "ok: persisted to windows.ini —" "$(grep -v '^\[' "$cfg/windows.ini" | tr -d ' ')"

# ============================================================ session two
# A brand-new compositor process, reading the config the first one wrote.
start_compositor 400 "$work/run2.out"
( env WAYLAND_DISPLAY="$wd" "$bin_dir/adversary" move "$APP" "$TITLE" "$WIN_W" "$WIN_H" \
    > "$work/adv2.log" 2>&1 & echo $! >> "$pidfile" )
wait "$ut_pid" 2>/dev/null || true
ut_pid=""
while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$pidfile"

reopened=$(grep "^window $APP/$TITLE at " "$work/run2.out" | tail -1 | sed 's/.* at //')
[ -n "$reopened" ] || { echo "FAIL: the window did not reopen"; cat "$work/run2.out"; exit 1; }

[ "$reopened" = "$dropped" ] \
  || { echo "FAIL: it reopened at $reopened, but was left at $dropped"
       cat "$work/run2.out"; exit 1; }
grep -q '^restored=1' "$work/run2.out" \
  || { echo "FAIL: the compositor placed it fresh rather than restoring it"
       cat "$work/run2.out"; exit 1; }

echo "ok: a NEW compositor process reopened it at $reopened — where it was left"
echo "all green (the window position debt from §2.22 is paid)."
