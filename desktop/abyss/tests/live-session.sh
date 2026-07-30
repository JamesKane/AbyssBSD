#!/bin/sh
# AbyssBSD Swift DE — the dev session, live under a headless compositor (P2.10).
#
# live-sway.sh proves one component at a time. This proves they compose into a
# *desktop*: `abyss/session.sh` starts a compositor and brings the desktop, the
# menu bar and the Dock up together, they map as three layer surfaces on the
# same output, the menu bar's exclusive zone really reserves space, the pixels
# stack in the right order, and a component that dies is restarted — which is
# the one thing a session supervisor exists to do.
#
# Usage: abyss/tests/live-session.sh [out.png]
# Needs: sway (>=1.11), grim. No GPU (headless backend + pixman).
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir      # FreeBSD sets none; sway refuses without it
out="${1:-${TMPDIR:-/tmp}/aqua-session-$$.png}"

command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }
command -v grim >/dev/null || { echo "FAIL: grim not installed"; exit 1; }

swift build

W=800; H=600

# A scratch home for the session: the desktop reads ~/Desktop and the shell
# persists config, and a test must never touch the developer's real files.
scratch=$(mktemp -d)
rundir="$scratch/run"
mkdir -p "$scratch/desk" "$scratch/cfg"
# A flat, known wallpaper colour, so a pixel probe is an exact assertion rather
# than "some blue". Same desktop.ini the hot-reload test drives (§2.18).
bg_r=32; bg_g=64; bg_b=128
printf 'schema_version = 1\n\n[desktop]\nbg = #ff204080\n' > "$scratch/cfg/desktop.ini"

sess_pid=""
cleanup() {
  [ -n "$sess_pid" ] && kill -TERM "$sess_pid" 2>/dev/null || true
  [ -n "$sess_pid" ] && wait "$sess_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup EXIT

log="$scratch/session.log"
HOME="$scratch" ABYSS_CONFIG_DIR="$scratch/cfg" ABYSS_DESKTOP_DIR="$scratch/desk" \
  sh abyss/session.sh --headless --resolution "${W}x${H}" --rundir "$rundir" \
     --no-build --no-follow > "$log" 2>&1 &
sess_pid=$!

up=0
for _ in $(seq 1 60); do
  grep -q '^session: up' "$log" && { up=1; break; }
  kill -0 "$sess_pid" 2>/dev/null || { echo "FAIL: the session exited early"; cat "$log"; exit 1; }
  sleep 0.5
done
[ "$up" = 1 ] || { echo "FAIL: the session never came up"; cat "$log"; exit 1; }

wd=$(cat "$rundir/wayland-display")
SWAYSOCK=$(cat "$rundir/swaysock"); export SWAYSOCK
echo "session up on $wd: $(grep '^session: up' "$log")"

# 1. Three layer surfaces, each in its own namespace, on the one output.
for pair in 'desktop:abyss.wallpaper' 'menubar:abyss.menubar' 'dock:abyss.dock'; do
  c=${pair%%:*}; ns=${pair#*:}
  line=$(grep 'LayerSurface: mapped' "$rundir/$c.log" | head -1) || line=""
  [ -n "$line" ] || { echo "FAIL: $c never mapped"; cat "$rundir/$c.log"; exit 1; }
  case "$line" in
    *"[$ns]"*) echo "  $c: $line" ;;
    *) echo "FAIL: $c mapped in the wrong namespace: $line"; exit 1 ;;
  esac
done

# 2. The menu bar's exclusive zone really reserved space. A layer surface is not
# in sway's tree, so we assert on the *effect*: the usable workspace area starts
# below the 22px bar. This is the only check that proves the components compose
# rather than merely coexist.
ws=$(swaymsg -t get_workspaces)
ws_y=$(printf '%s' "$ws" | tr ',' '\n' | grep -o '"y": [0-9-]*' | head -1 | grep -o '[0-9-]*$')
[ "${ws_y:-0}" = 22 ] \
  || { echo "FAIL: workspace starts at y=$ws_y, expected 22 (menu bar exclusive zone)"; \
       printf '%s\n' "$ws"; exit 1; }
echo "  menu bar reserved its exclusive zone (workspace y=$ws_y)"

# 3. The pixels stack in the right order. grim can capture a 1x1 region as a
# binary PPM, whose last three bytes are that pixel — no image library needed.
pixel() {
  # awk normalises the field spacing on purpose: FreeBSD's od(1) prints a
  # TRAILING space after the last value and GNU's does not, so a `tr -s`/`sed`
  # pipeline compares equal on Linux and unequal on FreeBSD for identical
  # pixels — which is exactly how this failed in the VM.
  WAYLAND_DISPLAY="$wd" grim -g "$1,$2 1x1" -t ppm - | tail -c 3 \
    | od -An -tu1 | awk '{ print $1, $2, $3 }'
}
mid=$(pixel $((W / 2)) $((H / 2)))
top=$(pixel $((W / 2)) 6)
bot=$(pixel $((W / 2)) $((H - 40)))
[ "$mid" = "$bg_r $bg_g $bg_b" ] \
  || { echo "FAIL: the desktop didn't paint its configured bg (mid pixel = $mid)"; exit 1; }
[ "$top" != "$mid" ] || { echo "FAIL: nothing is drawn over the desktop at the top"; exit 1; }
[ "$bot" != "$mid" ] || { echo "FAIL: nothing is drawn over the desktop at the bottom"; exit 1; }
echo "  stacked: menu bar ($top) / desktop ($mid) / Dock ($bot)"

# 4. Supervision: kill a component and it comes back. (`anchor`'s actual job.)
dock_pid=$(cat "$rundir/dock.child")
kill "$dock_pid" 2>/dev/null || { echo "FAIL: the Dock wasn't running to kill"; exit 1; }
back=0
for _ in $(seq 1 40); do
  n=$(grep -c 'LayerSurface: mapped' "$rundir/dock.log" || true)
  new_pid=$(cat "$rundir/dock.child" 2>/dev/null) || new_pid=""
  if [ "${n:-0}" -ge 2 ] && [ -n "$new_pid" ] && [ "$new_pid" != "$dock_pid" ]; then back=1; break; fi
  sleep 0.5
done
[ "$back" = 1 ] \
  || { echo "FAIL: the Dock was not restarted after it died"; cat "$rundir/dock.log"; \
       grep '^session:' "$log"; exit 1; }
echo "  supervision: killed the Dock ($dock_pid), it came back as $new_pid"

sleep 1  # let the restarted Dock paint before the capture
WAYLAND_DISPLAY="$wd" grim "$out"
test -s "$out" || { echo "FAIL: grim produced no image"; exit 1; }
echo "ok: the session renders -> $out (desktop + menu bar + Dock, one compositor)"
