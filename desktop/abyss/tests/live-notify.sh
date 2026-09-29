#!/bin/sh
# AbyssBSD Swift DE — notifications, end to end (PHASE7.md P7.4).
#
# `abyssnotify` → the portal → the notification centre → an Aqua toast on an
# OVERLAY layer surface. That is the path a jailed app takes: it never holds the
# notify service's socket, only the portal's.
#
# Also asserts the two properties a toast must have, because both are easy to
# get wrong and invisible in a screenshot:
#   - it does NOT reserve space (no exclusive zone), so the desktop is unchanged;
#   - the surface goes away when the toast expires, rather than lingering as an
#     invisible sheet that swallows clicks.
#
# Usage: abyss/tests/live-notify.sh [out.png]
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

out="${1:-${TMPDIR:-/tmp}/abyss-toast.png}"
bin="$root/.build/debug/AquaDemo"
portal="$root/.build/debug/abyss-portal"
notify="$root/.build/debug/abyssnotify"
[ -x "$bin" ] && [ -x "$portal" ] && [ -x "$notify" ] || swift build
command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }
command -v grim >/dev/null || { echo "FAIL: grim not installed"; exit 1; }

rundir=$(mktemp -d /tmp/abyss-notify.XXXXXX)
cleanup() {
  for p in ${center_pid:-} ${portal_pid:-} ${wall_pid:-} ${sway_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$rundir" "${cfg:-}" "${swaylog:-}" 2>/dev/null || true
}
trap cleanup EXIT
export ABYSS_RUNTIME_DIR="$rundir"

cfg=$(mktemp)
printf 'output HEADLESS-1 resolution 800x600 position 0 0\ndefault_border none\n' > "$cfg"
swaylog=$(mktemp)
env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman \
    WLR_LIBINPUT_NO_DEVICES=1 sway --unsupported-gpu -c "$cfg" > "$swaylog" 2>&1 &
sway_pid=$!

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
swaymsg exec -- sh -c "env > $rundir/sway-env" >/dev/null 2>&1 || true
wd=""
i=0
while [ $i -lt 40 ]; do
  [ -s "$rundir/sway-env" ] && wd=$(grep '^WAYLAND_DISPLAY=' "$rundir/sway-env" | head -1 | cut -d= -f2-)
  [ -n "$wd" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || { echo "FAIL: cannot tell which socket sway opened"; exit 1; }
export WAYLAND_DISPLAY="$wd"

# A desktop underneath, so the toast is visibly *over* something.
AQUA_SCENE=wallpaper "$bin" > "$rundir/wall.log" 2>&1 &
wall_pid=$!

# The notification centre, then the portal that relays to it.
AQUA_SCENE=notify "$bin" > "$rundir/center.log" 2>&1 &
center_pid=$!
i=0
while [ $i -lt 60 ]; do
  [ -S "$rundir/notify.sock" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -S "$rundir/notify.sock" ] \
  || { echo "FAIL: the notification centre never bound"; cat "$rundir/center.log"; exit 1; }

"$portal" > "$rundir/portal.log" 2>&1 &
portal_pid=$!
i=0
while [ $i -lt 50 ]; do
  [ -S "$rundir/portal.sock" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -S "$rundir/portal.sock" ] \
  || { echo "FAIL: the portal never bound"; cat "$rundir/portal.log"; exit 1; }

# The workspace geometry BEFORE any toast: a notification must not reserve space.
ws_before=$(swaymsg -t get_workspaces | tr ',' '\n' | grep -o '"height": [0-9]*' | head -1 | grep -o '[0-9]*$')

# ---------------------------------------------------------------- post

"$notify" -t 6 "Build finished" "all tests green on both platforms" \
  > "$rundir/notify.log" 2>&1 \
  || { echo "FAIL: abyssnotify failed"; cat "$rundir/notify.log" "$rundir/portal.log"; exit 1; }
grep -q "^posted" "$rundir/notify.log" \
  || { echo "FAIL: no confirmation from the portal"; cat "$rundir/notify.log"; exit 1; }
echo "notify: $(cat "$rundir/notify.log")"

# It went through the PORTAL, which is the trust boundary being tested.
grep -q "relayed a notification" "$rundir/portal.log" \
  || { echo "FAIL: the portal didn't relay it"; cat "$rundir/portal.log"; exit 1; }
echo "ok: it reached the toast via the portal, not by touching the shell directly"

i=0
while [ $i -lt 50 ]; do
  grep -q "LayerSurface: mapped" "$rundir/center.log" && break
  sleep 0.1; i=$((i + 1))
done
grep -q "abyss.notify" "$rundir/center.log" \
  || { echo "FAIL: no notification surface mapped"; cat "$rundir/center.log"; exit 1; }
echo "ok: $(grep 'LayerSurface: mapped' "$rundir/center.log" | head -1)"

sleep 0.8
grim "$out" && echo "captured $out"

# The toast is drawn top-right: sample inside the panel, which is light against
# the blue desktop. Scan a strip rather than one pixel (fonts differ per
# platform — HANDOFF §2.34).
vals=$(grim -g "560,40 200x1" -t ppm - | tail -c 600 | od -An -tu1 -v | tr -s ' ' '\n' | grep -v '^$')
light=$(printf '%s\n' "$vals" | awk 'NR%3==1{r=$1} NR%3==2{g=$1}
      NR%3==0 { if (r > 200 && g > 200 && $1 > 200) n++ } END { print n+0 }')
[ "${light:-0}" -ge 20 ] \
  || { echo "FAIL: no toast panel drawn top-right ($light light pixels)"; exit 1; }
echo "ok: the toast panel is on screen ($light light pixels over the desktop)"

# It must NOT reserve space: a notification is not a panel.
ws_after=$(swaymsg -t get_workspaces | tr ',' '\n' | grep -o '"height": [0-9]*' | head -1 | grep -o '[0-9]*$')
[ "$ws_before" = "$ws_after" ] \
  || { echo "FAIL: the toast reserved space (workspace $ws_before -> $ws_after)"; exit 1; }
echo "ok: it reserved no space (workspace height unchanged at $ws_after)"

# ---------------------------------------------------------------- expiry
# The toast must go away on its own, AND the surface must be torn down with it —
# an invisible OVERLAY surface left behind would swallow every click on that
# corner of the desktop. This is also the path that segfaulted before
# LayerSurface had a teardown at all (HANDOFF §2.2), so it is asserted rather
# than assumed.

i=0
while [ $i -lt 120 ]; do
  grep -q "surface released (no toasts)" "$rundir/center.log" && break
  sleep 0.25; i=$((i + 1))
done
grep -q "surface released (no toasts)" "$rundir/center.log" \
  || { echo "FAIL: the toast expired but its surface was never released"
       grep "Notify:" "$rundir/center.log" | sed 's/^/    /'; exit 1; }
echo "ok: the toast expired and its surface was released"

# And the process is still alive — releasing a layer surface from a run-loop
# callback must not take the component down with it.
kill -0 "$center_pid" 2>/dev/null \
  || { echo "FAIL: the notification centre died releasing its surface"
       cat "$rundir/center.log"; exit 1; }
echo "ok: the notification centre survived the teardown"
grep "Notify:" "$rundir/center.log" | tail -3 | sed 's/^/    /'

echo "all green (a notification crossed the portal and became a toast)."
