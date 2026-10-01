#!/bin/sh
# AbyssBSD Swift DE — Activity Monitor: a process started by the test appears,
# is quit from the window, and is gone (PHASE15 P15.7).
#
# Real processes with names nothing else has (copies of sleep), the virtual
# keyboard and pointer, and the window's own account of where it drew each row.
#
#   1. Activity Monitor maps, and typing narrows the table to the test's two
#      processes (the filter field);
#   2. one selected and quit — Quit Process, then Quit in the sheet — is gone:
#      from the system (kill -0), and from the table;
#   3. one that ignores SIGTERM survives Quit, and Force Quit ends it;
#   4. FreeBSD, where the helper can run as root (dry run): another user's
#      process — a root daemon, in All Processes — is quit through the helper,
#      which checks it is still that process and says what it would run; the
#      daemon is left alone.
#
# Usage: abyss/tests/live-activity.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
helper="$root/.build/debug/abyss-settings"
for b in "$undertow" "$aqua" "$helper"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

W=1024; H=768
work=$(mktemp -d /tmp/abyss-am.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-amr.XXXXXX)
sudo=""
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${vk_pid:-} ${am_pid:-} ${sleeper:-} ${stubborn:-} ${ut_pid:-}; do kill -9 "$p" 2>/dev/null || true; done
  [ -n "${helper_pid:-}" ] && { $sudo kill "$helper_pid" 2>/dev/null || true; }
  pkill -f "$work" 2>/dev/null || true
  $sudo rm -rf "$rundir" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM HUP
log="$work/am.log"
fail() {
  exec 1>&2
  echo "FAIL: $1"
  [ -n "${ABYSS_TEST_KEEP:-}" ] && { rm -rf "$ABYSS_TEST_KEEP"; cp -r "$work" "$ABYSS_TEST_KEEP"; }
  [ -s "$log" ] && grep 'Activity Monitor:' "$log" | tail -8 | sed 's/^/  am| /'
  exit 1
}
count() { grep -c -- "$1" "$log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY [TENTHS]
  i=0
  while [ $i -lt "${4:-80}" ]; do [ "$(count "$1")" -gt "$2" ] && return 0; sleep 0.1; i=$((i + 1)); done
  fail "$3"
}
export ABYSS_RUNTIME_DIR="$rundir"

# ------------------------------------------------------------ tools
for t in pointer keyboard; do
  xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
  [ $t = keyboard ] && xml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
  wayland-scanner client-header "$xml" "$work/v$t-proto.h"
  wayland-scanner private-code  "$xml" "$work/v$t-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "no vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "no vkeyboard"

# ------------------------------------------------------------ the processes
# Copies of sleep, so their names are the test's alone. The stubborn one
# ignores SIGTERM: an ignored signal survives exec, so `sleep` inherits it.
cp "$(command -v sleep)" "$work/abyss-sleeper"
cp "$(command -v sleep)" "$work/abyss-stubborn"
"$work/abyss-sleeper" 600 &
sleeper=$!
sh -c "trap '' TERM; exec \"$work/abyss-stubborn\" 600" &
stubborn=$!
sleep 0.3
kill -0 "$sleeper" && kill -0 "$stubborn" || fail "the test's processes did not start"

# ------------------------------------------------------------ compositor
mkdir -p "$work/cfg"
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width $W --height $H --config-dir "$work/cfg" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""; i=0
while [ $i -lt 80 ] && [ -z "$wd" ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""; sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
export WAYLAND_DISPLAY="$wd"

# FreeBSD with passwordless sudo: the settings helper as root, in dry run —
# it decides and says, and runs nothing. Admitted: this user's own group.
helper_ok=""
if [ "$(uname -s)" = FreeBSD ] && sudo -n true 2>/dev/null; then
  sudo=sudo
  sudo env ABYSS_RUNTIME_DIR="$rundir" "$helper" --uid "$(id -u)" --dry-run --admin-group "$(id -gn)" \
      --journal "$work/journal" > "$work/helper.log" 2>&1 &
  helper_pid=$!
  i=0; while [ $i -lt 50 ] && [ ! -S "$rundir/settings.sock" ]; do sleep 0.1; i=$((i + 1)); done
  [ -S "$rundir/settings.sock" ] && helper_ok=1
fi

# ------------------------------------------------------------ 1. the window
env ABYSS_ACTIVITY_DUMP=1 AQUA_SCENE=activity "$aqua" > "$log" 2>&1 &
am_pid=$!
await 'Activity Monitor: toolbar ' 0 "Activity Monitor never drew its window"
i=0; until grep -q '^window org.abyssbsd.activitymonitor/' "$work/ut.out"; do
  [ $i -ge 150 ] && fail "no Activity Monitor window"; sleep 0.1; i=$((i + 1)); done
pos=$(grep '^window org.abyssbsd.activitymonitor/' "$work/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)
wx=${pos%,*}; wy=${pos#*,}
toolbar=$(grep 'Activity Monitor: toolbar ' "$log" | tail -1)
at() {  # at NAME — a toolbar button's centre on the screen
  p=$(echo "$toolbar" | tr ' ' '\n' | sed -n "s/^$1=//p"); echo "$((wx + ${p%,*})) $((wy + ${p#*,}))"
}

mkfifo "$work/pointer" "$work/keys"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" $W $H < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$work/keys" > "$work/vk.log" 2>&1 &
vk_pid=$!
exec 4> "$work/keys"
sleep 1
click() { printf 'm %s %s\np\nr\n' "$1" "$2" >&3; sleep 0.4; }
row_y() {  # row_y PID — where the window last drew that process's row
  grep 'Activity Monitor: rows ' "$log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1@//p"
}

printf 't abyss-\n' >&4
# Each typed letter narrows it further: wait for where it ends — exactly the two.
i=0; until grep 'Activity Monitor: rows ' "$log" | tail -1 | grep -q 'rows 2:' \
           && [ -n "$(row_y $sleeper)" ] && [ -n "$(row_y $stubborn)" ]; do
  [ $i -ge 60 ] && fail "'abyss-' should leave exactly the test's two: $(grep 'Activity Monitor: rows' "$log" | tail -1)"; sleep 0.1; i=$((i + 1)); done
echo "ok: 1. Activity Monitor mapped, and typing 'abyss-' narrowed it to the test's two processes ($sleeper, $stubborn)"

# ------------------------------------------------------------ 2. Quit
quit_row() {  # quit_row PID NAME BUTTON — select it, Quit Process, then BUTTON in the sheet
  s=$(count "Activity Monitor: selected $2 (pid $1)")
  click $((wx + 150)) $((wy + $(row_y "$1")))
  await "Activity Monitor: selected $2 (pid $1)" "$s" "the click did not select $2"
  b=$(count 'Activity Monitor: sheet ')
  click $(at quit)
  await 'Activity Monitor: sheet ' "$b" "Quit Process put up no sheet"
  sheet=$(grep 'Activity Monitor: sheet ' "$log" | tail -1)
  p=$(echo "$sheet" | tr ' ' '\n' | sed -n "s/^$3=//p")
  click $((wx + ${p%,*})) $((wy + ${p#*,}))
}
b=$(count "Activity Monitor: quit abyss-sleeper (pid $sleeper): sent SIGTERM")
quit_row "$sleeper" abyss-sleeper quit
await "Activity Monitor: quit abyss-sleeper (pid $sleeper): sent SIGTERM" "$b" "Quit sent nothing to abyss-sleeper"
i=0; while kill -0 "$sleeper" 2>/dev/null; do
  [ $i -ge 30 ] && fail "abyss-sleeper is still running after Quit"; sleep 0.1; i=$((i + 1)); done
{ wait "$sleeper"; } 2>/dev/null || true; sleeper=""
i=0; until grep 'Activity Monitor: rows ' "$log" | tail -1 | grep -q 'rows 1:'; do
  [ $i -ge 40 ] && fail "the table still lists the quit process: $(grep 'Activity Monitor: rows' "$log" | tail -1)"; sleep 0.1; i=$((i + 1)); done
echo "ok: 2. abyss-sleeper selected and quit from the window: gone from the system and from the table"

# ------------------------------------------------------------ 3. Force Quit
quit_row "$stubborn" abyss-stubborn quit
await "Activity Monitor: quit abyss-stubborn (pid $stubborn): sent SIGTERM" 0 "Quit sent nothing to abyss-stubborn"
sleep 1
kill -0 "$stubborn" 2>/dev/null || fail "abyss-stubborn should have ignored SIGTERM"
quit_row "$stubborn" abyss-stubborn force
await "Activity Monitor: force quit abyss-stubborn (pid $stubborn): sent SIGKILL" 0 "Force Quit sent nothing"
i=0; while kill -0 "$stubborn" 2>/dev/null; do
  [ $i -ge 30 ] && fail "abyss-stubborn survived Force Quit"; sleep 0.1; i=$((i + 1)); done
{ wait "$stubborn"; } 2>/dev/null || true; stubborn=""
echo "ok: 3. abyss-stubborn ignored Quit (SIGTERM) and Force Quit (SIGKILL) ended it"

# ------------------------------------------------------------ 4. another user's, through the helper
if [ -z "$helper_ok" ]; then
  echo "ok: 4. (no root helper here — FreeBSD with passwordless sudo runs this half)"
else
  daemon=""; dpid=""
  for d in cron syslogd devd; do
    dpid=$(ps -axo pid,user,comm | awk -v d="$d" 'NR > 1 && $2 == "root" && $3 == d { print $1; exit }')
    [ -n "$dpid" ] && { daemon=$d; break; }
  done
  [ -n "$daemon" ] || fail "no root daemon to choose"
  click $(at all); sleep 0.4
  printf 'k 1\n' >&4; sleep 0.3                                  # Escape: clear the filter
  printf 't %s\n' "$daemon" >&4
  i=0; until [ -n "$(row_y "$dpid")" ]; do
    [ $i -ge 60 ] && fail "$daemon (pid $dpid) is not in All Processes"; sleep 0.1; i=$((i + 1)); done
  quit_row "$dpid" "$daemon" quit
  await "Activity Monitor: quit $daemon (pid $dpid, uid 0): asked the helper" 0 "the quit did not go to the helper"
  await 'Activity Monitor: helper: done' 0 "the helper did not accept the plan: $(grep 'helper:' "$log" | tail -1)" 50
  grep -q "kill -s TERM $dpid" "$work/helper.log" "$work/journal" 2>/dev/null \
    || fail "the helper did not say it would run kill -s TERM $dpid: $(tail -3 "$work/helper.log")"
  kill -0 "$dpid" 2>/dev/null || $sudo kill -0 "$dpid" || fail "a dry run quit $daemon"
  echo "ok: 4. $daemon (root's, pid $dpid) quit through the helper: it checked the process and said 'kill -s TERM $dpid' (dry run; $daemon left running)"
fi

echo "all green (Activity Monitor: a process appears, is quit from the window, and is gone)."
