#!/bin/sh
# AbyssBSD Swift DE — Disk Utility: a snapshot of a scratch dataset is made, a
# file is changed, and a rollback brings it back (PHASE15 P15.8).
#
# On FreeBSD with ZFS and passwordless sudo: a scratch dataset made for the
# test (and destroyed after), the settings helper running as root for real,
# and Disk Utility driven by the virtual pointer. Every claim is checked on the
# dataset and its files, not on the window:
#
#   1. Disk Utility lists the dataset; Take Snapshot makes one (zfs lists it);
#   2. a file is changed and another added; Roll Back (asked first, then
#      confirmed) brings the first back and the second is gone;
#   3. only the latest snapshot can be rolled back to: the window refuses an
#      older one, and so does the helper when asked directly (rollback -r
#      would destroy the later ones);
#   4. Unmount takes the dataset off its mountpoint; Mount puts it back, its
#      files there.
#
# Elsewhere (Linux: no ZFS) the window comes up and says why it has nothing.
#
# Usage: abyss/tests/live-diskutility.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
helper="$root/.build/debug/abyss-settings"
ctl="$root/.build/debug/abyss-settingsctl"
for b in "$undertow" "$aqua" "$helper" "$ctl"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

W=1024; H=768
work=$(mktemp -d /tmp/abyss-du.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-dur.XXXXXX)
sudo=""; ds=""
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${du_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  [ -n "${helper_pid:-}" ] && { $sudo kill "$helper_pid" 2>/dev/null || true; }
  [ -n "$ds" ] && { $sudo zfs destroy -r "$ds" 2>/dev/null || true; }
  pkill -f "$work" 2>/dev/null || true
  $sudo rm -rf "$rundir" "$work" 2>/dev/null || rm -rf "$work" || true
}
trap cleanup EXIT INT TERM HUP
log="$work/du.log"
fail() {
  exec 1>&2
  echo "FAIL: $1"
  [ -n "${ABYSS_TEST_KEEP:-}" ] && { rm -rf "$ABYSS_TEST_KEEP"; cp -r "$work" "$ABYSS_TEST_KEEP"; }
  [ -s "$log" ] && grep 'Disk Utility:' "$log" | tail -8 | sed 's/^/  du| /'
  exit 1
}
count() { grep -c -- "$1" "$log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY [TENTHS]
  i=0
  while [ $i -lt "${4:-80}" ]; do [ "$(count "$1")" -gt "$2" ] && return 0; sleep 0.1; i=$((i + 1)); done
  fail "$3"
}
export ABYSS_RUNTIME_DIR="$rundir"

zfs_here=""
if [ "$(uname -s)" = FreeBSD ] && command -v zfs >/dev/null 2>&1 && sudo -n true 2>/dev/null \
   && [ -n "$(zpool list -H -o name 2>/dev/null | head -1)" ]; then
  zfs_here=1; sudo=sudo
fi

# ------------------------------------------------------------ the scratch dataset
if [ -n "$zfs_here" ]; then
  pool=$(zpool list -H -o name | head -1)
  ds="$pool/abyss-du-$$"
  mnt="$work/scratch"
  sudo zfs create -o mountpoint="$mnt" "$ds" || fail "could not create $ds"
  sudo chown "$(id -u)" "$mnt"
  printf 'original\n' > "$mnt/notes.txt"
  sudo env ABYSS_RUNTIME_DIR="$rundir" "$helper" --uid "$(id -u)" --admin-group "$(id -gn)" \
      --journal "$work/journal" > "$work/helper.log" 2>&1 &
  helper_pid=$!
  i=0; while [ $i -lt 50 ] && [ ! -S "$rundir/settings.sock" ]; do sleep 0.1; i=$((i + 1)); done
  [ -S "$rundir/settings.sock" ] || fail "the settings helper never bound its socket"
fi

# ------------------------------------------------------------ compositor, pointer
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
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "no vpointer"

env ABYSS_DISKUTILITY_DUMP=1 AQUA_SCENE=diskutility "$aqua" > "$log" 2>&1 &
du_pid=$!
await 'Disk Utility: volumes: ' 0 "Disk Utility never read the volumes"
i=0; until grep -q '^window org.abyssbsd.diskutility/' "$work/ut.out"; do
  [ $i -ge 150 ] && fail "no Disk Utility window"; sleep 0.1; i=$((i + 1)); done

if [ -z "$zfs_here" ]; then
  grep -q 'Disk Utility: volumes: unavailable: ' "$log" || fail "with no ZFS here, Disk Utility should say so"
  echo "ok: (no ZFS here, or no passwordless sudo — the window came up and said: $(grep 'volumes: unavailable' "$log" | head -1 | sed 's/.*unavailable: //'); the FreeBSD guest runs the claims)"
  echo "all green (Disk Utility: the window, and why it has nothing)."
  exit 0
fi

pos=$(grep '^window org.abyssbsd.diskutility/' "$work/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)
wx=${pos%,*}; wy=${pos#*,}
mkfifo "$work/pointer"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" $W $H < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
sleep 1
click() { printf 'm %s %s\np\nr\n' "$1" "$2" >&3; sleep 0.4; }
layout() { grep 'Disk Utility: buttons ' "$log" | tail -1; }
button() { p=$(layout | tr ' ;' '\n\n' | sed -n "s/^$1=//p" | head -1); echo "$((wx + ${p%,*})) $((wy + ${p#*,}))"; }
helper_click() {  # helper_click X Y WHAT — click, then wait for a new "WHAT: done"
  before=$(count "Disk Utility: $3: done")
  click "$1" "$2"
  await "Disk Utility: $3: done" "$before" "$3 did not happen: $(grep "Disk Utility: $3" "$log" | tail -1)" 100
}

# ------------------------------------------------------------ 1. a snapshot
y=$(layout | tr ' ' '\n' | sed -n "s|^$ds@||p")
[ -n "$y" ] || fail "the sidebar does not list $ds"
b=$(count "Disk Utility: selected $ds")
click $((wx + 100)) $((wy + y))
await "Disk Utility: selected $ds" "$b" "clicking $ds did not select it"
b=$(count 'Disk Utility: snapshot .*: done')
click $(button snapshot)
await 'Disk Utility: snapshot .*: done' "$b" "Take Snapshot did not make a snapshot: $(grep 'Disk Utility: snapshot' "$log" | tail -1)" 100
snap1=$(zfs list -H -o name -t snapshot -d 1 "$ds" | tail -1)
[ -n "$snap1" ] || fail "zfs lists no snapshot of $ds"
echo "ok: 1. Take Snapshot made $snap1 (zfs lists it)"

# ------------------------------------------------------------ 2. change, roll back
printf 'changed\n' > "$mnt/notes.txt"
printf 'new\n' > "$mnt/added.txt"
sleep 0.5
b=$(count 'Disk Utility: asked to roll back')
click $(button rollback)
await 'Disk Utility: asked to roll back' "$b" "Roll Back asked nothing"
sleep 0.4
sheet=$(grep 'Disk Utility: buttons .*sheet' "$log" | tail -1)
p=$(echo "$sheet" | tr ' ' '\n' | sed -n 's/^rollback=//p' | tail -1)
[ -n "$p" ] || fail "no sheet was drawn"
click $((wx + ${p%,*})) $((wy + ${p#*,}))
await "Disk Utility: roll back to $snap1: done" 0 "the rollback did not happen" 100
[ "$(cat "$mnt/notes.txt")" = original ] || fail "notes.txt holds '$(cat "$mnt/notes.txt")' after the rollback"
[ ! -e "$mnt/added.txt" ] || fail "added.txt survived the rollback"
echo "ok: 2. a file changed and one added, then Roll Back (asked, confirmed): notes.txt says 'original' and added.txt is gone"

# ------------------------------------------------------------ 3. only the latest
b=$(count 'Disk Utility: snapshot .*: done')
click $(button snapshot)
await 'Disk Utility: snapshot .*: done' "$b" "the second snapshot was not made" 100
sleep 0.5
older=${snap1#*@}
yo=$(layout | sed -n 's/.*snapshots of [^:]*://p' | tr ' ' '\n' | sed -n "s/^$older@//p")
[ -n "$yo" ] || fail "the snapshot list does not show $older"
click $((wx + 400)) $((wy + yo))
b=$(count 'Disk Utility: refused: only the latest')
click $(button rollback)
await 'Disk Utility: refused: only the latest' "$b" "the window offered to roll back past a later snapshot"
r=$("$ctl" apply volume --rollback "$snap1" 2>&1 || true)
case "$r" in *"is not $ds's latest snapshot"*) ;; *) fail "the helper did not refuse a rollback past a later snapshot: $r" ;; esac
[ "$(zfs list -H -o name -t snapshot -d 1 "$ds" | wc -l | tr -d ' ')" = 2 ] || fail "a snapshot went missing"
echo "ok: 3. rolling back to the older snapshot was refused by the window and by the helper; both snapshots remain"

# ------------------------------------------------------------ 4. unmount, mount
helper_click $(button mount) "unmount $ds"
mount -p | awk '{print $2}' | grep -qx "$mnt" && fail "$ds is still mounted at $mnt"
sleep 0.5
helper_click $(button mount) "mount $ds"
mount -p | awk '{print $2}' | grep -qx "$mnt" || fail "$ds was not mounted again"
[ "$(cat "$mnt/notes.txt")" = original ] || fail "after mounting again, notes.txt is not there"
echo "ok: 4. Unmount took $ds off $mnt, and Mount put it back with its files"

echo "all green (Disk Utility: a snapshot made, a file changed, and a rollback brought it back)."
