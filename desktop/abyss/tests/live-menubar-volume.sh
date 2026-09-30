#!/bin/sh
# AbyssBSD Swift DE — the menu bar's volume item is real (PHASE14 P14.6d).
#
# It said "no mixer" from P3.7 on, because neither the dev box nor the build VM
# had one. The guest's snd_dummy has one. Claims:
#
#   1. the item shows the default device's `vol`, as mixer(8) has it;
#   2. a level set elsewhere (mixer(8)) reaches the bar within a tick, and so
#      does a mute — the speaker drawn dimmed;
#   3. a click on the speaker drops Jaguar's slider; a drag on it sets `vol`
#      (mixer(8) reads it back) and letting go closes it;
#   4. on Linux there is no mixer, and there is no item — nothing to click.
#
# The guest's levels are put back at the end. Coordinates come from the bar's
# own log (§2.46).
#
# Usage: abyss/tests/live-menubar-volume.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$client" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }
freebsd=0; [ "$(uname -s)" = FreeBSD ] && freebsd=1

W=1024; H=768
work=$(mktemp -d /tmp/abyss-mbvol.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-mbvolr.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  [ -s "$work/mixer.state" ] && { mixer -f /dev/mixer0 $(cat "$work/mixer.state") >/dev/null 2>&1 || true; }
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
export ABYSS_RUNTIME_DIR="$rundir"
mkdir -p "$work/cfg"
export ABYSS_CONFIG_DIR="$work/cfg"
fail() { echo "FAIL: $1"; [ -s "$work/app.log" ] && grep -E 'status|volume' "$work/app.log" | sed 's/^/  bar| /' | tail -12; exit 1; }
mark() { grep -c -- "$1" "$work/app.log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY — a line after the mark (§2.61); ticks are 1 s
  i=0
  while [ $i -lt 80 ]; do
    [ "$(mark "$1")" -gt "$2" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  fail "$3 (no new '$1' in the log)"
}
last() { grep -- "$1" "$work/app.log" | tail -1; }

if [ "$freebsd" = 1 ]; then
  sudo kldload -n snd_dummy 2>/dev/null || true
  [ -e /dev/mixer0 ] || fail "no /dev/mixer0 even with snd_dummy loaded"
  mixer -f /dev/mixer0 -o > "$work/mixer.state"
  mixer -f /dev/mixer0 vol=0.75 vol.mute=off >/dev/null
fi

wayland-scanner client-header "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"

wd="abyss-mbvol-$$"
"$undertow" run --frames 0 --width "$W" --height "$H" --socket "$wd" \
   --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/$wd" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/$wd" ] || fail "undertow never bound $wd"
env WAYLAND_DISPLAY="$wd" AQUA_SCENE=menubar "$client" > "$work/app.log" 2>&1 &
app_pid=$!
await "MenuBar: volume item " 0 "the bar never drew its status items"

if [ "$freebsd" = 0 ]; then
  grep -q "MenuBar: status no mixer" "$work/app.log" || fail "the bar found a mixer on Linux"
  grep -q "MenuBar: volume item none" "$work/app.log" || fail "an item was drawn with nothing behind it"
  echo "ok: 4. no mixer here, and no speaker in the bar — nothing to click"
  echo "all green (the volume item: absent where there is no sound)."
  exit 0
fi

# ------------------------------------------------------------ 1. the level
grep -q "MenuBar: status volume 75%," "$work/app.log" || fail "the bar does not show vol at 75%: $(last 'MenuBar: status')"
echo "ok: 1. the bar shows the default device's vol, 75%, as mixer(8) has it"

# ------------------------------------------------- 2. changes from elsewhere
b=$(mark "MenuBar: status volume 40%,")
mixer -f /dev/mixer0 vol=0.4 >/dev/null
await "MenuBar: status volume 40%," "$b" "a level set with mixer(8) did not reach the bar"
b=$(mark "MenuBar: status volume 40% muted")
mixer -f /dev/mixer0 vol.mute=on >/dev/null
await "MenuBar: status volume 40% muted" "$b" "a mute set with mixer(8) did not reach the bar"
b=$(mark "MenuBar: status volume 40%,")
mixer -f /dev/mixer0 vol.mute=off >/dev/null
await "MenuBar: status volume 40%," "$b" "an unmute did not reach the bar"
echo "ok: 2. a level and a mute set with mixer(8) reached the bar within a tick, and the unmute too"

# ---------------------------------------------------------- 3. the slider
at=$(last "MenuBar: volume item at" | sed 's/.*at //')
fifo="$work/vp.fifo"; mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" "$W" "$H" < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!; exec 3>"$fifo"
i=0; while ! grep -q ready "$work/vp.log" 2>/dev/null && [ $i -lt 60 ]; do i=$((i+1)); sleep 0.1; done
grep -q ready "$work/vp.log" || fail "the virtual pointer never bound"
sleep 0.3
b=$(mark "MenuBar: volume slider")
printf 'm %s %s\np\nr\n' "${at%,*}" "${at#*,}" >&3
await "MenuBar: volume slider" "$b" "a click on the speaker opened nothing"
sl=$(last "MenuBar: volume slider")
sx=$(printf '%s' "$sl" | sed 's/.*x=\([0-9]*\).*/\1/'); top=$(printf '%s' "$sl" | sed 's/.*top=\([0-9]*\).*/\1/')
bot=$(printf '%s' "$sl" | sed 's/.*bottom=\([0-9]*\).*/\1/')
[ "$bot" -gt "$top" ] || fail "the slider's track makes no sense: $sl"
y80=$((bot - (bot - top) * 80 / 100)); y30=$((bot - (bot - top) * 30 / 100))
sleep 0.3
b=$(mark "MenuBar: volume set to")
printf 'm %s %s\np\n' "$sx" "$y80" >&3; sleep 0.1
printf 'm %s %s\n' "$sx" "$(( (y80 + y30) / 2 ))" >&3; sleep 0.1
printf 'm %s %s\nr\n' "$sx" "$y30" >&3
await "MenuBar: volume set to" "$b" "a drag on the slider set nothing"
v=$(last "MenuBar: volume set to" | sed 's/.*set to \([0-9]*\)%.*/\1/')
[ "$v" -ge 28 ] && [ "$v" -le 32 ] || fail "a drag to 30% of the track set $v%"
want=$(awk -v n="$v" 'BEGIN{printf "%.2f", n / 100}')
mixer -f /dev/mixer0 -o | grep -qx "vol.volume=$want:$want" || fail "mixer(8) does not read vol $want back: $(mixer -f /dev/mixer0 -o | grep vol)"
grep -q "MenuBar: status volume $v%," "$work/app.log" || fail "the bar did not show the level it set ($v%)"
echo "ok: 3. the speaker drops the slider; a drag set vol to $v% — mixer(8) reads $want back — and the bar shows it"

exec 3>&- 2>/dev/null || true
echo "all green (the menu bar's volume item is real)."
