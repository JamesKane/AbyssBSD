#!/bin/sh
# AbyssBSD Swift DE — a minimized window keeps a clock, and is told why (U.2).
#
# undertow withheld every frame callback from a minimized window, and a client
# presenting in FIFO mode — Mesa's default: SDL, Blender, zed — blocks in its
# swap until the callback comes, which was never (docs/API-STUDY.md §1.4).
# `abyss/tests/hidden.c` behaves like those: it draws on frame callbacks and on
# nothing else, minimizes itself, and asks for its window back through
# foreign-toplevel as the Dock would. Claims, each separately:
#
#   1. the window is told what this compositor does (wm_capabilities, v5) —
#      and not the window menu, which it does not draw;
#   2. minimized, it is told it is suspended (v6), and told again when it
#      comes back;
#   3. minimized, its clock is SLOW BUT ALIVE — a few callbacks in 3.5 s, not
#      none (withheld: the old bug) and not ~200 (unthrottled);
#   4. restored, its clock is the display's again.
#
# Usage: abyss/tests/live-hidden.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build

work=$(mktemp -d /tmp/abyss-hidden.XXXXXX)
cleanup() {
  for p in ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; echo "--- client"; cat "$work/app.log" 2>/dev/null; exit 1; }

cc -I "$root/de/cwayland/include" "$root/abyss/tests/hidden.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   "$root/de/cwayland/wlr-foreign-toplevel-management-unstable-v1-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/hidden" \
   || fail "could not build the client"

env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 \
    --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""; i=0
while [ $i -lt 80 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || { cat "$work/ut.err"; fail "undertow exited before it announced a socket"; }
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"

env WAYLAND_DISPLAY="$wd" "$work/hidden" > "$work/app.log" 2>&1 &
app_pid=$!

# The whole run is about six seconds: one drawing, 3.5 hidden, one restored.
wait_for() {  # wait_for PATTERN SECONDS WHY
  i=0
  while [ $i -lt $(($2 * 10)) ]; do
    grep -q "$1" "$work/app.log" 2>/dev/null && return 0
    kill -0 "$app_pid" 2>/dev/null || fail "the client exited while waiting: $3"
    sleep 0.1; i=$((i + 1))
  done
  fail "$3"
}

grep -q '^hidden: xdg_wm_base v6$' "$work/app.log" 2>/dev/null \
  || wait_for '^hidden: xdg_wm_base v6$' 5 "undertow does not offer xdg_wm_base v6: $(grep 'xdg_wm_base' "$work/app.log")"
echo "ok: undertow offers xdg-shell v6"

# 1. What the compositor does, and only that.
wait_for '^hidden: capabilities' 5 "no wm_capabilities event"
caps=$(grep -m1 '^hidden: capabilities' "$work/app.log" | cut -d' ' -f3-)
for c in maximize fullscreen minimize; do
  case " $caps " in *" $c "*) ;; *) fail "wm_capabilities lacks $c: '$caps'" ;; esac
done
case " $caps " in *" window_menu "*) fail "wm_capabilities claims a window menu undertow does not draw: '$caps'" ;; esac
echo "ok: the window is told what undertow does ($caps)"

# 2. Suspended on the way down...
wait_for '^hidden: minimized$' 5 "the client never drew its sixty frames — the display clock is not running"
wait_for '^hidden: suspended 1$' 3 "minimized, the window was never told it is suspended"
echo "ok: minimized, it is told it is suspended"

# 3. ...a slow clock while hidden...
wait_for '^hidden: hidden frames' 8 \
  "minimized, the window's frame clock stopped — it would hang in a FIFO swap (the U.2 bug)"
line=$(grep -m1 '^hidden: hidden frames' "$work/app.log")
n=$(echo "$line" | cut -d' ' -f4)
ms=$(echo "$line" | cut -d' ' -f6)
# At one a second, 3.5 s hidden is about five callbacks, counting the one owed
# as it went. Two to seven allows for scheduling; ~200 would be the display's
# rate, i.e. no throttle at all.
[ "$n" -ge 2 ] && [ "$n" -le 7 ] \
  || fail "minimized, the window got $n frame callbacks in $ms ms — wanted about one a second"
echo "ok: minimized, its clock ran slow but alive ($n callbacks in $ms ms)"

# ...and back.
wait_for '^hidden: suspended 0$' 5 "restored, the window was never told it is no longer suspended"
wait_for '^hidden: frames after restore' 5 "restored, the window's clock never came back"
after=$(grep -m1 '^hidden: frames after restore' "$work/app.log" | cut -d' ' -f5)
[ "$after" -ge 40 ] || fail "restored, only $after frames in a second — the clock did not return to the display's"
echo "ok: restored through its foreign-toplevel handle, told it is not suspended, $after frames in the next second"

grep -q 'minimizes=1' "$work/ut.out" || fail "undertow did not count the minimize: $(grep minimizes= "$work/ut.out" | tail -1)"
kill -0 "$ut_pid" 2>/dev/null || fail "undertow exited: $(tail -5 "$work/ut.err")"

echo "all green (a minimized window keeps a slow clock, and is told why)."
