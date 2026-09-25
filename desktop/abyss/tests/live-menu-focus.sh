#!/bin/sh
# AbyssBSD Swift DE — the compositor knows whose menus are whose (P10.3).
#
# A global menu bar has to show the focused application's menus, and only the
# compositor knows which surface is focused. So an application tells undertow,
# per surface, where its menus are (`abyss_menu_manager_v1`), and undertow tells
# the menu bar — and nobody else — whenever that changes (`abyss_menubar_v1`).
#
# What this proves, each on the thing rather than the run:
#
#   1. **Only the privileged socket sees the bar's global.** A bar on the
#      ordinary socket is told nothing; the same binary on the privileged one
#      is told who is frontmost on bind. The first is the control (§2.37).
#   2. A Finder window publishes `menus.finder.<pid>` against its surface, and
#      when it is focused the bar is told exactly that address and app_id.
#   3. Focus moving to an application that publishes nothing says so — it must
#      not leave the Finder's menus up under somebody else's window.
#   4. **Closing the focused window gives the bar the next one.** Until this
#      pass closing the focused window left focus on nothing (`Seat.focused` is
#      weak and went quietly nil), which the bar is the first thing to notice.
#   5. The socket is 0600.
#
# Usage: abyss/tests/live-menu-focus.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$aqua" ] || swift build

work=$(mktemp -d /tmp/abyss-mfocus.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-mfocr.XXXXXX)
priv="abyss-priv-$$"
cleanup() {
  for p in ${other_pid:-} ${finder_pid:-} ${bar_pid:-} ${plain_pid:-} ${ut_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" "$rundir"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
export ABYSS_RUNTIME_DIR="$rundir"

# wait_for FILE PATTERN WHAT — poll a log for a fixed string.
wait_for() {
  i=0
  while [ $i -lt 60 ]; do
    grep -qF "$2" "$1" 2>/dev/null && return 0
    sleep 0.25; i=$((i + 1))
  done
  fail "$3 — $(tail -4 "$1" 2>/dev/null)"
}

mkdir -p "$work/cfg" "$work/files"
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" --privileged-socket "$priv" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wait_for "$work/ut.out" "WAYLAND_PRIVILEGED=$priv" "undertow never announced its privileged socket"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)
[ -n "$wd" ] || fail "undertow never announced a socket"
sock="$XDG_RUNTIME_DIR/$priv"
[ -S "$sock" ] || fail "no socket at $sock"
mode=$(stat -c %a "$sock" 2>/dev/null || stat -f %Lp "$sock")
[ "$mode" = 600 ] || fail "the privileged socket is mode $mode, not 600"
echo "ok: undertow is up on $wd, privileged on $priv (mode $mode)"

# ------------------------------------------------------ 1. the control, first
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar \
    "$aqua" > "$work/plain.log" 2>&1 &
plain_pid=$!
wait_for "$work/plain.log" "not on the compositor's privileged socket" \
  "a bar on the ORDINARY socket was offered the bar's global"
env WAYLAND_DISPLAY="$priv" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar \
    "$aqua" > "$work/bar.log" 2>&1 &
bar_pid=$!
wait_for "$work/bar.log" "MenuBar: frontmost: nothing" \
  "the bar on the privileged socket was not told the state on bind"
grep -q "frontmost" "$work/plain.log" && fail "the ordinary-socket bar learned about focus"
echo "ok: only the bar on the privileged socket is told who is frontmost"

# ----------------------------------------------- 2. a Finder, and its address
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" ABYSS_FINDER_DIR="$work/files" \
    AQUA_SCENE=finder "$aqua" > "$work/finder.log" 2>&1 &
finder_pid=$!
addr="menus.finder.$finder_pid"
wait_for "$work/finder.log" "window publishes its menus at $addr" \
  "the Finder window never published its menu address"
wait_for "$work/ut.err" "a surface published its menus at $addr" \
  "undertow never recorded the Finder's address"
wait_for "$work/bar.log" "frontmost: org.abyssbsd.finder at $addr [abyss]" \
  "the bar was not told the focused Finder's menus"
echo "ok: the Finder's window is frontmost and the bar was told $addr"

# ------------------------------------------- 3. somebody who publishes nothing
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=widgets \
    "$aqua" > "$work/other.log" 2>&1 &
other_pid=$!
wait_for "$work/bar.log" "frontmost: org.abyssbsd.aquademo (no menus)" \
  "focus moved to a window with no menus and the bar was not told"
echo "ok: focus on an application with no menus says so"

# -------------------------------------------- 4. close it: the next one is up
before=$(grep -c "frontmost: org.abyssbsd.finder at $addr" "$work/bar.log")
kill "$other_pid"; wait "$other_pid" 2>/dev/null || true; other_pid=""
i=0
while [ $i -lt 40 ]; do
  now=$(grep -c "frontmost: org.abyssbsd.finder at $addr" "$work/bar.log")
  [ "$now" -gt "$before" ] && break
  sleep 0.25; i=$((i + 1))
done
[ "$now" -gt "$before" ] \
  || fail "closing the focused window left the bar (and focus) on nothing: $(tail -3 "$work/bar.log")"
echo "ok: closing the focused window handed focus — and the bar — back to the Finder"

# ------------------------------------------- the Finder goes: the bar goes blank
kill "$finder_pid"; wait "$finder_pid" 2>/dev/null || true; finder_pid=""
# The bar was told "nothing" once already, on bind — so wait for a SECOND one,
# or this passes on the old line before the new event has even arrived.
i=0
while [ $i -lt 40 ]; do
  [ "$(grep -c 'MenuBar: frontmost: nothing' "$work/bar.log")" -ge 2 ] && break
  sleep 0.25; i=$((i + 1))
done
[ "$(grep -c 'MenuBar: frontmost: nothing' "$work/bar.log")" -ge 2 ] \
  || fail "the last window closed and the bar still shows its menus: $(tail -2 "$work/bar.log")"
echo "ok: with no windows left the bar is told nothing is frontmost"

echo "all green (whose menus are whose, and only the bar is told)."
