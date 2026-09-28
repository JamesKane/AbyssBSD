#!/bin/sh
# AbyssBSD Swift DE — Energy Saver (PHASE14 P14.8).
#
# System Preferences on our compositor, its Energy Saver pane driven by the
# virtual pointer. Claims:
#
#   1. the page shows the defaults, the battery (or none), and — on Linux —
#      that the helper will not read powerd here, in its words;
#   2. dragging the computer's slider to 5 min pulls the display's down with
#      it (the display never sleeps later than the computer), and energy.ini
#      holds both once the slider is let go;
#   3. dragging the display's slider to Never pushes the computer's to Never;
#   4. FreeBSD: powerd, read from rc.conf through the helper (off), turned on
#      by its checkbox, then its battery mode set to Slowest — rc.conf written
#      for real (scratch), the restart skipped and said (write-only).
#
# Usage: abyss/tests/live-energy-pane.sh
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
work=$(mktemp -d /tmp/abyss-energypane.XXXXXX)
chmod 755 "$work"                       # the root helper writes its scratch files here
rundir=$(mktemp -d /tmp/abyss-energypaner.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  for p in ${vk_pid:-} ${vp_pid:-} ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  [ -n "${svc_pid:-}" ] && { $sudo kill "$svc_pid" 2>/dev/null || true; }
  $sudo rm -rf "$work" "$rundir" 2>/dev/null || rm -rf "$work" "$rundir"
}
trap cleanup EXIT INT TERM HUP
export ABYSS_RUNTIME_DIR="$rundir"
mkdir -p "$work/cfg"
export ABYSS_CONFIG_DIR="$work/cfg"
fail() {
  echo "FAIL: $1"
  [ -s "$work/app.log" ] && grep 'energy' "$work/app.log" | sed 's/^/  app| /' | tail -15
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
# Write-only: the scratch rc.conf is written for real, and `service powerd
# onerestart` is skipped and said to be — this guest's CPU is not the test's.
me=$(id -u); mygroup=$(id -gn)
printf 'hostname="abyss"\npowerd_enable="NO"\n' > "$work/rc.conf"; chmod 644 "$work/rc.conf"
$sudo env ABYSS_RUNTIME_DIR="$rundir" "$helper" --uid "$me" --admin-group "$mygroup" \
    --rc-conf "$work/rc.conf" --resolvconf "$work/resolvconf.conf" --journal "$work/journal" \
    --write-only 2> "$work/svc.err" &
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

wd="abyss-energypane-$$"
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
  p=$(grep 'energy layout' "$work/app.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p")
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

track() {  # track NAME -> "X0 X1 Y" on the output
  p=$(grep 'energy layout' "$work/app.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p")
  [ -n "$p" ] || fail "the pane's layout does not say where $1 is"
  x0=${p%%-*}; r=${p#*-}; x1=${r%%,*}; y=${r#*,}
  echo "$((wx + x0)) $((wx + x1)) $((wy + y))"
}
drag_to() {  # drag_to TRACK STOP_INDEX — press on the thumb's current place is not needed: press anywhere, move, let go
  set -- $(track "$1") "$2"
  n=13
  tx=$(( $1 + ($2 - $1) * $4 / n ))
  printf 'm %s %s\np\n' "$(( ($1 + $2) / 2 ))" "$3" >&3; sleep 0.1
  printf 'm %s %s\n' "$tx" "$3" >&3; sleep 0.1
  printf 'r\n' >&3
}
ini() { sed -n "s/^$1 *= *//p" "$work/cfg/energy.ini" 2>/dev/null; }

# ------------------------------------------------------------ 1. the page
"$menu" run systempreferences view.pane.energySaver > /dev/null || fail "could not open Energy Saver by its verb"
await "energy: status " 0 "the pane did not read anything"
await "energy layout" 0 "the pane did not publish its layout"
status=$(last "energy: status " | sed 's/.*energy: status //')
if [ "$freebsd" = 1 ]; then
  [ "$status" = "computer 30 display 10 powerd off battery none" ] || fail "the page: $status"
  echo "ok: 1. the defaults, powerd off as rc.conf says (through the helper), and no battery: $status"
else
  [ "$status" = "computer 30 display 10 powerd unknown battery none" ] || fail "the page: $status"
  grep -q "energy: cannot read powerd: .*not FreeBSD" "$work/app.log" || fail "the helper's refusal is not on the page"
  echo "ok: 1. the defaults, no battery, and the helper's word that powerd is not readable here"
fi

# ---------------------------------------------------------- 2. the computer
b=$(mark "energy: stored")
drag_to computer 3                                   # the 4th stop: 5 min
await "energy: stored" "$b" "letting go of the computer's slider stored nothing"
[ "$(last 'energy: stored' | sed 's/.*energy: stored //')" = "computer 5 display 5" ] \
  || fail "after the computer's slider: $(last 'energy: stored')"
[ "$(ini system_sleep_minutes)" = 5 ] && [ "$(ini display_sleep_minutes)" = 5 ] \
  || fail "energy.ini: $(cat "$work/cfg/energy.ini" 2>/dev/null)"
echo "ok: 2. the computer to 5 min pulled the display down with it; energy.ini holds both"

# ----------------------------------------------------------- 3. the display
b=$(mark "energy: stored")
drag_to display 13                                   # the far end: Never
await "energy: stored" "$b" "letting go of the display's slider stored nothing"
[ "$(ini display_sleep_minutes)" = 0 ] && [ "$(ini system_sleep_minutes)" = 0 ] \
  || fail "energy.ini after Never: $(cat "$work/cfg/energy.ini")"
echo "ok: 3. the display to Never pushed the computer to Never too"

# -------------------------------------------------------------- 4. powerd
if [ "$freebsd" = 1 ]; then
  b=$(mark "energy: applied"); click powerd
  await "energy: applied" "$b" "the powerd checkbox applied nothing"
  grep -q '^powerd_enable="YES"' "$work/rc.conf" || fail "rc.conf: $(cat "$work/rc.conf")"
  grep -q '^powerd_flags="-a hiadaptive -b adaptive"' "$work/rc.conf" || fail "rc.conf: $(cat "$work/rc.conf")"
  last "energy: applied" | grep -q "Saved, and not put into effect (write-only" || fail "said: $(last 'energy: applied')"
  await "energy: status .*powerd on" 0 "the page did not read powerd back on"
  b=$(mark "energy: applied"); click battery.min
  await "energy: applied" "$b" "choosing Slowest on battery applied nothing"
  grep -q '^powerd_flags="-a hiadaptive -b min"' "$work/rc.conf" || fail "rc.conf: $(cat "$work/rc.conf")"
  echo "ok: 4. powerd turned on and set to Slowest on battery: rc.conf written, the restart skipped and said"
else
  echo "ok: 4. (powerd is rc.conf's; the guest runs this half)"
fi

exec 3>&- 4>&- 2>/dev/null || true
echo "all green (Energy Saver: sleep delays kept, the rule between them held, powerd through the helper)."
