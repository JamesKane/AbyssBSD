#!/bin/sh
# AbyssBSD Swift DE — the Sound pane (PHASE14 P14.6c).
#
# System Preferences on our compositor, its Sound pane driven by the virtual
# pointer, against the guest's snd_dummy — a real pcm device with a real mixer
# (PHASE14 §4.3). Claims:
#
#   1. the page is the machine's: its status line agrees with `ventsctl sound`
#      (itself checked against mixer(8) and /dev/sndstat); on Linux, no devices,
#      and the page says so;
#   2. FreeBSD: the configured default is read through the helper;
#   3. dragging Output volume sets `vol` on the mixer — mixer(8) reads the new
#      level back — and moves nothing else;
#   4. Mute mutes it, and again unmutes it, as mixer(8) sees;
#   5. a process that starts playing appears on the page within a tick, at
#      the level it set for itself — read-only, as §4.3 decided;
#   6. a level changed from outside (mixer(8)) is on the page within a tick.
#
# The guest's levels are put back at the end. Coordinates come from the
# application's published layout (§2.46).
#
# Usage: abyss/tests/live-sound-pane.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
menu="$root/.build/debug/abyssmenu"
helper="$root/.build/debug/abyss-settings"
vents="$root/.build/debug/ventsctl"
for b in "$undertow" "$client" "$menu" "$helper" "$vents"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

freebsd=0; [ "$(uname -s)" = FreeBSD ] && freebsd=1
sudo=""
if [ "$freebsd" = 1 ]; then
  sudo -n true 2>/dev/null || { echo "FAIL: on FreeBSD the helper runs as root, and this needs passwordless sudo"; exit 1; }
  sudo=sudo
fi

W=1024; H=768
work=$(mktemp -d /tmp/abyss-soundpane.XXXXXX)
chmod 755 "$work"                       # the root helper writes its scratch files here
rundir=$(mktemp -d /tmp/abyss-soundpaner.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  [ -n "${pp:-}" ] && { kill "$pp" 2>/dev/null || true; }
  # The guest's levels as they were: this test moves real mixer controls.
  [ -s "$work/mixer.state" ] && { mixer -f /dev/mixer0 $(cat "$work/mixer.state") >/dev/null 2>&1 || true; }
  for p in ${vk_pid:-} ${vp_pid:-} ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  [ -n "${svc_pid:-}" ] && { $sudo kill "$svc_pid" 2>/dev/null || true; }
  $sudo rm -rf "$work" "$rundir" 2>/dev/null || rm -rf "$work" "$rundir" || true
}
trap cleanup EXIT INT TERM HUP
export ABYSS_RUNTIME_DIR="$rundir"
mkdir -p "$work/cfg"
export ABYSS_CONFIG_DIR="$work/cfg"
fail() {
  echo "FAIL: $1"
  [ -s "$work/app.log" ] && grep 'sound' "$work/app.log" | sed 's/^/  app| /' | tail -15
  [ -s "$work/svc.err" ] && sed 's/^/  helper| /' "$work/svc.err" | tail -8
  exit 1
}

mark() { grep -c -- "$1" "$work/app.log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY — a line AFTER the mark (§2.61)
  i=0
  while [ $i -lt 100 ]; do
    [ "$(mark "$1")" -gt "$2" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  fail "$3 (no new '$1' in the log)"
}
last() { grep -- "$1" "$work/app.log" | tail -1; }

# ------------------------------------------------------------- the helper
me=$(id -u); mygroup=$(id -gn)
if [ "$freebsd" = 1 ]; then
  sudo kldload -n snd_dummy 2>/dev/null || true
  [ -e /dev/mixer0 ] || fail "no /dev/mixer0 even with snd_dummy loaded"
  mixer -f /dev/mixer0 -o > "$work/mixer.state"
fi
printf '# scratch\n' > "$work/sysctl.conf"; chmod 644 "$work/sysctl.conf"
$sudo env ABYSS_RUNTIME_DIR="$rundir" "$helper" --uid "$me" --admin-group "$mygroup" \
    --rc-conf "$work/rc.conf" --resolvconf "$work/resolvconf.conf" --sysctl-conf "$work/sysctl.conf" \
    --journal "$work/journal" 2> "$work/svc.err" &
svc_pid=$!
i=0; while [ ! -S "$rundir/settings.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$rundir/settings.sock" ] || fail "the helper never came up"

# --------------------------------------------------- compositor, app, input
for t in vpointer:wlr-virtual-pointer-unstable-v1 vkeyboard:virtual-keyboard-unstable-v1; do
  n=${t%%:*}; x=${t#*:}
  wayland-scanner client-header "$root/abyss/tests/$x.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$x.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "could not build vkeyboard"

wd="abyss-soundpane-$$"
"$undertow" run --frames 0 --width "$W" --height "$H" --socket "$wd" \
   --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/$wd" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/$wd" ] || fail "undertow never bound $wd"

env WAYLAND_DISPLAY="$wd" AQUA_SCENE=sysprefs ABYSS_PREFS_DUMP=1 "$client" > "$work/app.log" 2>&1 &
app_pid=$!
await "System Preferences is up" 0 "the application never started"
await "SystemPreferences: layout " 0 "it never drew its grid"

i=0; geom=""
while [ -z "$geom" ] && [ $i -lt 60 ]; do
  geom=$(grep '^window org.abyssbsd.preferences/' "$work/ut.out" | head -1 | awk '{print $(NF-1)}')
  sleep 0.05; i=$((i + 1))
done
[ -n "$geom" ] || fail "undertow never reported the window"
wx=${geom%,*}; wy=${geom#*,}
at() {  # at NAME -> "X Y" on the output, from the pane's latest layout line
  p=$(grep 'sound layout' "$work/app.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p")
  [ -n "$p" ] || fail "the pane's layout does not say where $1 is"
  echo "$((wx + ${p%,*})) $((wy + ${p#*,}))"
}
click() { printf 'm %s\np\nr\n' "$(at "$1")" >&3; }

fifo="$work/vp.fifo"; mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" "$W" "$H" < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!; exec 3>"$fifo"
kfifo="$work/vk.fifo"; mkfifo "$kfifo"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$kfifo" > "$work/vk.log" 2>&1 &
vk_pid=$!; exec 4>"$kfifo"
i=0; while { ! grep -q ready "$work/vp.log" || ! grep -q ready "$work/vk.log"; } 2>/dev/null && [ $i -lt 60 ]; do
  i=$((i+1)); sleep 0.1; done
grep -q ready "$work/vp.log" && grep -q ready "$work/vk.log" || fail "the virtual pointer or keyboard never bound"
sleep 0.5

# ------------------------------------------------------ 1. the machine's page
"$menu" run systempreferences view.pane.sound > /dev/null || fail "could not open the Sound pane by its verb"
await "sound: status " 0 "the pane did not read the machine"
status=$(last "sound: status " | sed 's/.*sound: status //')
v=$("$vents" sound) || fail "ventsctl sound failed"
if [ "$v" = "no sound devices" ]; then
  [ "$status" = "no devices" ] || fail "ventsctl sees no devices, the pane says: $status"
  [ "$freebsd" = 0 ] || fail "no sound devices in the guest even with snd_dummy"
  echo "ok: 1. no sound devices here, and the page says so rather than reaching for ALSA"
  echo "all green (the Sound pane: nothing to show, and it shows nothing)."
  exit 0
fi
want="default $(printf '%s\n' "$v" | sed -n 's/^default //p')"
dflt=${want#default }
want="$want$(printf '%s\n' "$v" | awk -v d="$dflt" '$1 == "device" {on = ($2 == d)} on && $1 == "control" {
        printf "; %s %s%s", $2, $3, ($4 == "muted" ? " muted" : "")}')"
players=$(printf '%s\n' "$v" | awk '$1 == "playing" {printf "%s%s %s %s", (n++ ? ", " : ""), $2, $3, $4}')
want="$want; playing ${players:-none}"
[ "$status" = "$want" ] || fail "the page is not the machine:
  pane:     $status
  ventsctl: $want"
echo "ok: 1. the page is the machine's: $status"

# ------------------------------------------------ 2. the configured default
await "sound: read default pcm" 0 "the pane did not read the configured default through the helper"
echo "ok: 2. the configured default, through the helper: $(last 'sound: read default' | sed 's/.*sound: //')"

# ------------------------------------------------------------- 3. a drag
await "sound layout" 0 "the pane did not publish its layout"
track=$(grep 'sound layout' "$work/app.log" | tail -1 | tr ' ' '\n' | sed -n 's/^level\.vol=//p')
[ -n "$track" ] || fail "the layout has no Output volume track"
x0=${track%%-*}; rest=${track#*-}; x1=${rest%%,*}; ty=${rest#*,}
from=$((wx + x0 + (x1 - x0) * 3 / 4)); to=$((wx + x0 + (x1 - x0) / 4)); yy=$((wy + ty))
pcm_before=$(mixer -f /dev/mixer0 -o | sed -n 's/^pcm\.volume=//p')
b=$(mark "sound: vol set to")
printf 'm %s %s\np\n' "$from" "$yy" >&3; sleep 0.1
printf 'm %s %s\n' "$(( (from + to) / 2 ))" "$yy" >&3; sleep 0.1
printf 'm %s %s\nr\n' "$to" "$yy" >&3
await "sound: vol set to" "$b" "the drag did not set Output volume"
set_to=$(last "sound: vol set to" | sed 's/.*set to //')
[ "$set_to" -ge 23 ] && [ "$set_to" -le 27 ] || fail "a drag to a quarter of the track set vol to $set_to"
m=$(mixer -f /dev/mixer0 -o)
want_v=$(awk -v n="$set_to" 'BEGIN{printf "%.2f", n / 100}')
printf '%s\n' "$m" | grep -qx "vol.volume=$want_v:$want_v" || fail "mixer(8) does not read vol $want_v back:
$m"
printf '%s\n' "$m" | grep -qx "pcm.volume=$pcm_before" || fail "the drag moved pcm too: $m"
echo "ok: 3. a drag set Output volume to $set_to%, and mixer(8) reads vol=$want_v back; pcm unmoved"

# -------------------------------------------------------------- 4. mute
b=$(mark "sound: vol muted"); click mute.vol
await "sound: vol muted" "$b" "Mute did nothing"
mixer -f /dev/mixer0 -o | grep -qx 'vol.mute=on' || fail "mixer(8) does not see vol muted"
b=$(mark "sound: vol unmuted"); click mute.vol
await "sound: vol unmuted" "$b" "Mute again did not unmute"
mixer -f /dev/mixer0 -o | grep -qx 'vol.mute=off' || fail "mixer(8) still sees vol muted"
echo "ok: 4. Mute muted vol and unmuted it again, as mixer(8) sees"

# ------------------------------------------------ 5. a player appears
cat > "$work/p.c" <<'C'
#include <sys/soundcard.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
int main(void) {
    int fd = open("/dev/dsp", O_WRONLY), v = 37 | (37 << 8);
    if (fd < 0) return 1;
    ioctl(fd, SNDCTL_DSP_SETPLAYVOL, &v);
    char buf[4096] = {0};
    for (;;) write(fd, buf, sizeof buf);
}
C
cc -o "$work/tuneplayer" "$work/p.c" || fail "could not build the player"
b=$(mark "sound: changed .*tuneplayer 37:37")
"$work/tuneplayer" & pp=$!
await "sound: changed .*playing .*$pp tuneplayer 37:37" "$b" "a player ($pp) did not appear on the page"
kill "$pp"; wait "$pp" 2>/dev/null || true; pp=""
echo "ok: 5. a process playing appeared on the page within a tick, at the 37% it set for itself"

# ------------------------------------------ 6. a change from outside
b=$(mark "sound: changed .*pcm 41:41")
mixer -f /dev/mixer0 pcm=0.41 >/dev/null
await "sound: changed .*pcm 41:41" "$b" "a level set with mixer(8) did not reach the page"
echo "ok: 6. pcm set with mixer(8) was on the page within a tick"

exec 3>&- 4>&- 2>/dev/null || true
echo "all green (the Sound pane: the machine's levels, set and seen; who is playing, shown)."
