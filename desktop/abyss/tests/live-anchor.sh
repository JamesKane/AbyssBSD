#!/bin/sh
# AbyssBSD Swift DE — the session supervisor, supervising real processes (P3.6).
#
# The unit tests cover the decisions; this covers the syscalls. Two parts:
#
#   1. Bare supervision, no compositor needed: start two long-running children,
#      kill one, watch it come back, ask the control plane about it, and quit
#      the session — checking that nothing is left running afterwards.
#   2. The real thing: `anchor` brings the actual shell up against a headless
#      sway and `abyssctl` reports three live components — the same job
#      abyss/session.sh does, done by the Swift supervisor instead.
#
# Usage: abyss/tests/live-anchor.sh [out.png]
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

out="${1:-${TMPDIR:-/tmp}/anchor-session.png}"
anchor="$root/.build/debug/anchor"
ctl="$root/.build/debug/abyssctl"
bin="$root/.build/debug/AquaDemo"
[ -x "$anchor" ] && [ -x "$ctl" ] && [ -x "$bin" ] || swift build

# Short path: a unix socket must fit in sockaddr_un.sun_path (HANDOFF §2.32).
rundir=$(mktemp -d /tmp/abyss-anchor.XXXXXX)
cleanup() {
  [ -n "${anchor_pid:-}" ] && kill "$anchor_pid" 2>/dev/null || true
  [ -n "${sway_pid:-}" ] && kill "$sway_pid" 2>/dev/null || true
  rm -rf "$rundir" "${cfg:-}" "${swaylog:-}"
}
trap cleanup EXIT
export ABYSS_RUNTIME_DIR="$rundir"

# ---------------------------------------------------------------- 1. bare

echo "== supervision =="
"$anchor" --display wayland-none \
          --component a="/bin/sleep 300" \
          --component b="/bin/sleep 300" > "$rundir/anchor.log" 2>&1 &
anchor_pid=$!

i=0
while [ $i -lt 50 ]; do
  [ -S "$rundir/anchor.sock" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -S "$rundir/anchor.sock" ] \
  || { echo "FAIL: anchor never bound its control socket"; cat "$rundir/anchor.log"; exit 1; }

"$ctl" status > "$rundir/status1" 2>&1 \
  || { echo "FAIL: abyssctl status failed"; cat "$rundir/status1" "$rundir/anchor.log"; exit 1; }
grep -q "a=up(0)" "$rundir/status1" && grep -q "b=up(0)" "$rundir/status1" \
  || { echo "FAIL: both components should be up with no restarts"; cat "$rundir/status1"; exit 1; }
echo "ok: two components up, control plane answering"

# Kill one child and watch the supervisor put it back. This is the single thing
# a session supervisor exists to do.
victim=$(pgrep -f "^/bin/sleep 300" | head -1)
[ -n "$victim" ] || { echo "FAIL: no child to kill"; exit 1; }
kill -9 "$victim"

i=0
while [ $i -lt 50 ]; do
  "$ctl" status > "$rundir/status2" 2>&1 || true
  grep -qE "=up\(1\)" "$rundir/status2" && break
  sleep 0.1; i=$((i + 1))
done
grep -qE "=up\(1\)" "$rundir/status2" \
  || { echo "FAIL: the killed component was not restarted"
       cat "$rundir/status2" "$rundir/anchor.log"; exit 1; }
grep -q "restarting (1/5)" "$rundir/anchor.log" \
  || { echo "FAIL: no restart logged"; cat "$rundir/anchor.log"; exit 1; }
echo "ok: a killed component came back, and the restart is counted"

# Quit over the control plane, and check the session really went away.
"$ctl" quit > "$rundir/quit" 2>&1 || { echo "FAIL: quit failed"; cat "$rundir/quit"; exit 1; }
i=0
while [ $i -lt 50 ]; do
  kill -0 "$anchor_pid" 2>/dev/null || break
  sleep 0.1; i=$((i + 1))
done
kill -0 "$anchor_pid" 2>/dev/null \
  && { echo "FAIL: anchor ignored quit"; cat "$rundir/anchor.log"; exit 1; }
anchor_pid=""
pgrep -f "^/bin/sleep 300" >/dev/null 2>&1 \
  && { echo "FAIL: a supervised child outlived the session"; exit 1; }
[ -e "$rundir/anchor.sock" ] \
  && { echo "FAIL: the control socket outlived the session"; exit 1; }
echo "ok: quit tore the whole session down (no orphans, no stale socket)"

# ---------------------------------------------------------------- 2. the shell

command -v sway >/dev/null || { echo "(sway missing — skipping the shell half)"; exit 0; }
command -v grim >/dev/null || { echo "(grim missing — skipping the shell half)"; exit 0; }

echo "== the real session =="
cfg=$(mktemp)
printf 'output HEADLESS-1 resolution 800x600 position 0 0\ndefault_border none\n' > "$cfg"
swaylog=$(mktemp)
env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman \
    WLR_LIBINPUT_NO_DEVICES=1 sway --unsupported-gpu -c "$cfg" > "$swaylog" 2>&1 &
sway_pid=$!

# Find OUR sway's IPC socket by its pid — never just "the first wayland-N in the
# runtime dir", which on a developer's box is their own session. Getting this
# wrong doesn't fail loudly: the shell maps onto the real desktop and the test
# then asserts against the wrong compositor (HANDOFF §2.26).
ss=""
i=0
while [ $i -lt 60 ]; do
  ss=$(ls -1 "$XDG_RUNTIME_DIR"/sway-ipc.*."$sway_pid".sock 2>/dev/null | head -1) || ss=""
  [ -n "$ss" ] && SWAYSOCK="$ss" swaymsg -t get_version >/dev/null 2>&1 && break
  ss=""
  kill -0 "$sway_pid" 2>/dev/null || { echo "FAIL: sway exited"; tail -5 "$swaylog"; exit 1; }
  sleep 0.25; i=$((i + 1))
done
[ -n "$ss" ] || { echo "FAIL: sway not ready"; tail -5 "$swaylog"; exit 1; }
export SWAYSOCK="$ss"

# Then ask sway itself which socket it opened. `swaymsg exec` runs in the
# session's own environment, so this is exact even with another compositor
# running. (Dump the whole environment and grep here: sway lexes the exec string
# itself, so quotes inside it don't survive — HANDOFF §2.26.)
swaymsg exec -- sh -c "env > $rundir/sway-env" >/dev/null 2>&1 || true
wd=""
i=0
while [ $i -lt 40 ]; do
  if [ -s "$rundir/sway-env" ]; then
    wd=$(grep '^WAYLAND_DISPLAY=' "$rundir/sway-env" | head -1 | cut -d= -f2-) || wd=""
    [ -n "$wd" ] && break
  fi
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || { echo "FAIL: cannot tell which Wayland socket sway opened"; exit 1; }
[ "$wd" = "${WAYLAND_DISPLAY:-}" ] \
  && { echo "FAIL: discovered the parent session's socket ($wd), not the test one"; exit 1; }
echo "headless sway on $wd"

# The supervisor starts the whole default session itself — the bus, the portal
# and the D-Bus bridge as well as the three shell components (P8.4). This test
# is about the shell half; `live-session-gtk.sh` is where the services are put
# to work. Waiting on `dock=up` rather than a component count, because the count
# is a number that changes when the session gains a service and the name is what
# this test actually means.
"$anchor" --display "$wd" > "$rundir/session.log" 2>&1 &
anchor_pid=$!

i=0
while [ $i -lt 120 ]; do
  "$ctl" status 2>/dev/null | grep -q "dock=up" && break
  kill -0 "$anchor_pid" 2>/dev/null \
    || { echo "FAIL: anchor exited during bring-up"; cat "$rundir/session.log"; exit 1; }
  sleep 0.25; i=$((i + 1))
done
"$ctl" status > "$rundir/status3" 2>&1 \
  || { echo "FAIL: no status from the real session"; cat "$rundir/session.log"; exit 1; }
for c in desktop menubar dock; do
  grep -q "$c=up" "$rundir/status3" \
    || { echo "FAIL: $c is not up"; cat "$rundir/status3" "$rundir/session.log"; exit 1; }
done
echo "ok: anchor brought up desktop + menubar + dock"

# The menu bar's exclusive zone is the proof the shell really composed, since a
# layer surface never appears in sway's tree (HANDOFF §2.16). Poll for it: the
# control plane says "up" as soon as the process is running, which is earlier
# than its surface being mapped and configured.
ws_y=""
i=0
while [ $i -lt 40 ]; do
  ws=$(swaymsg -t get_workspaces)
  ws_y=$(printf '%s' "$ws" | tr ',' '\n' | grep -o '"y": [0-9-]*' | head -1 | grep -o '[0-9-]*$')
  [ "${ws_y:-0}" = 22 ] && break
  sleep 0.25; i=$((i + 1))
done
[ "${ws_y:-0}" = 22 ] \
  || { echo "FAIL: workspace starts at y=${ws_y:-?}, expected 22 (menu bar exclusive zone)"
       cat "$rundir/session.log"; exit 1; }
echo "ok: the menu bar reserved its 22px (workspace starts at y=22)"

WAYLAND_DISPLAY="$wd" grim "$out" 2>/dev/null && echo "captured $out"

"$ctl" quit >/dev/null 2>&1 || true
i=0
while [ $i -lt 60 ]; do kill -0 "$anchor_pid" 2>/dev/null || break; sleep 0.1; i=$((i + 1)); done
kill -0 "$anchor_pid" 2>/dev/null \
  && { echo "FAIL: anchor ignored quit"; cat "$rundir/session.log"; exit 1; }
anchor_pid=""

# The session's own bus goes with it. `dbus-daemon` is the one child that would
# happily outlive its parent, and a supervisor that leaks one per run is worse
# than one that starts none — the leak is invisible until something runs out.
pgrep -f "address=unix:path=$rundir/bus" >/dev/null 2>&1 \
  && { echo "FAIL: the session's dbus-daemon outlived the session"
       pgrep -af "address=unix:path=$rundir/bus"; exit 1; }
echo "ok: quit took the services down with the shell (no stray bus)"

echo "all green (the Swift supervisor runs the session)."
