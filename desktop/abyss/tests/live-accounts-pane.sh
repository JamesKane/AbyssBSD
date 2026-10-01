#!/bin/sh
# AbyssBSD Swift DE — System Preferences' Accounts pane (PHASE16 P16.6a).
#
# System Preferences on our compositor, driven by the virtual pointer and
# keyboard, with the settings helper behind it — on FreeBSD as root, against
# a scratch root (`pw -R`, copies of the password and group files) and a
# scratch rc.conf, so the machine's own accounts are only ever read. Claims:
#
#   1. the pane lists the people in the password file, administrators marked;
#   2. New User… with passwords that do not match says so in the sheet, and
#      nothing is asked of the helper;
#   3. New User… typed in — the short name following the full name — and
#      Create User: on FreeBSD the account is made (an administrator, as
#      ticked) and the list shows it; on Linux the helper's refusal is shown,
#      in its words, and nothing is written;
#   4. (FreeBSD) Log in automatically, ticked for the new user, writes
#      rc.conf; Delete User asks, and deletes it, keeping its home folder.
#
# Usage: abyss/tests/live-accounts-pane.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
menu="$root/.build/debug/abyssmenu"
helper="$root/.build/debug/abyss-settings"
for b in "$undertow" "$client" "$menu" "$helper"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

freebsd=0; [ "$(uname -s)" = FreeBSD ] && freebsd=1
sudo=""
if [ "$freebsd" = 1 ]; then
  sudo -n true 2>/dev/null || { echo "FAIL: on FreeBSD the helper runs as root, and this needs passwordless sudo"; exit 1; }
  sudo=sudo
fi

W=1024; H=768
work=$(mktemp -d /tmp/abyss-acctpane.XXXXXX)
chmod 755 "$work"
rundir=$(mktemp -d /tmp/abyss-acctpaner.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
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
  [ -s "$work/app.log" ] && grep 'accounts' "$work/app.log" | sed 's/^/  app| /' | tail -10
  [ -s "$work/svc.err" ] && sed 's/^/  helper| /' "$work/svc.err" | tail -6
  exit 1
}
mark() { n=$(grep -c -- "$1" "$work/app.log" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await PATTERN BEFORE WHY — a line after the mark
  i=0
  while [ $i -lt 120 ]; do [ "$(mark "$1")" -gt "$2" ] && return 0; sleep 0.05; i=$((i + 1)); done
  fail "$3 (no new '$1' in the log)"
}
last() { grep -- "$1" "$work/app.log" | tail -1; }

# ------------------------------------------------------------- the scratch
pwroot="$work/root"
mkdir -p "$pwroot/etc" "$pwroot/home" "$pwroot/usr/share/skel"
if [ "$freebsd" = 1 ]; then
  sudo cp /etc/master.passwd /etc/group "$pwroot/etc/"
  sudo pwd_mkdb -p -d "$pwroot/etc" "$pwroot/etc/master.passwd"
else
  cp /etc/passwd /etc/group "$pwroot/etc/"
fi
printf 'hostname="abyss"\nabyss_desktop_enable="NO"\nabyss_loginwindow_greeter="YES"\n' > "$work/rc.conf"; chmod 644 "$work/rc.conf"
export ABYSS_ACCOUNTS_ROOT="$pwroot" ABYSS_RC_CONF="$work/rc.conf"

me=$(id -u); mygroup=$(id -gn)
$sudo env ABYSS_RUNTIME_DIR="$rundir" "$helper" --uid "$me" --admin-group "$mygroup" \
    --rc-conf "$work/rc.conf" --pw-root "$pwroot" --journal "$work/journal" 2> "$work/svc.err" &
svc_pid=$!
i=0; while [ ! -S "$rundir/settings.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$rundir/settings.sock" ] || fail "the helper never came up"

for t in vpointer:wlr-virtual-pointer-unstable-v1 vkeyboard:virtual-keyboard-unstable-v1; do
  n=${t%%:*}; x=${t#*:}
  wayland-scanner client-header "$root/abyss/tests/$x.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$x.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"

wd="abyss-acctpane-$$"
"$undertow" run --frames 0 --width "$W" --height "$H" --socket "$wd" --config-dir "$work/cfg" \
   > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/$wd" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/$wd" ] || fail "undertow never bound $wd"
env WAYLAND_DISPLAY="$wd" AQUA_SCENE=sysprefs ABYSS_PREFS_DUMP=1 "$client" > "$work/app.log" 2>&1 &
app_pid=$!
await "System Preferences is up" 0 "the application never started"
geom=""; i=0
while [ -z "$geom" ] && [ $i -lt 100 ]; do
  geom=$(grep '^window org.abyssbsd.preferences/' "$work/ut.out" | head -1 | awk '{print $(NF-1)}')
  sleep 0.05; i=$((i + 1))
done
[ -n "$geom" ] || fail "undertow never reported the window"
wx=${geom%,*}; wy=${geom#*,}
mkfifo "$work/vp" "$work/vk"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" "$W" "$H" < "$work/vp" > "$work/vp.log" 2>&1 & vp_pid=$!; exec 3>"$work/vp"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk_pid=$!; exec 4>"$work/vk"
i=0; while { ! grep -q ready "$work/vp.log" || ! grep -q ready "$work/vk.log"; } 2>/dev/null && [ $i -lt 60 ]; do i=$((i+1)); sleep 0.1; done
sleep 0.5
at() {  # at NAME -> "X Y" on the output, from the pane's latest layout line
  p=$(grep 'accounts layout' "$work/app.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p")
  [ -n "$p" ] || fail "the pane's layout does not say where $1 is"
  echo "$((wx + ${p%,*})) $((wy + ${p#*,}))"
}
click() { printf 'm %s\np\nr\n' "$(at "$1")" >&3; sleep 0.25; }
typ() { printf 't %s\n' "$1" >&4; sleep 0.2; }
key() { printf 'k %s\n' "$1" >&4; sleep 0.15; }

# ------------------------------------------------------------- 1. the list
b=$(mark "accounts: "); "$menu" run systempreferences view.pane.accounts > /dev/null || fail "could not open Accounts"
await "accounts: " "$b" "the pane read nothing"
await "accounts layout" 0 "the pane did not publish its layout"
people=$(last "accounts: " | sed 's/.*accounts: //')
myname=$(id -un)
case "$people" in *"$myname"*) ;; *) fail "the pane does not list $myname: $people" ;; esac
echo "ok: 1. the pane lists the password file's people: $people"

# ------------------------------------------------------------- 2. a mismatch
nu="tst$$"; nu=$(echo "$nu" | cut -c1-12)
b=$(mark "accounts: new user sheet"); click new
await "accounts: new user sheet" "$b" "New User… did not open the sheet"
await "accounts layout .*field3=" 0 "the sheet did not publish its fields"
typ "$nu Person"; key 15; key 15; typ "first-$$"; key 15; typ "second-$$"
a=$(mark "accounts: apply"); key 28
sleep 0.5
[ "$(mark "accounts: apply")" = "$a" ] || fail "mismatched passwords were sent to the helper"
echo "ok: 2. passwords that do not match: the sheet says so, and nothing is asked"

# ------------------------------------------------------------- 3. create
click field3; for k in $(seq 1 30); do key 14; done      # empty Verify
typ "first-$$"; click admin
b=$(mark "accounts: applied\|accounts: not applied"); click confirm
await "accounts: applied\|accounts: not applied" "$b" "Create User came to nothing"
if [ "$freebsd" = 1 ]; then
  last "accounts: applied" | grep -q "Done" || fail "the account was not made: $(last 'accounts: ')"
  line=$(sudo pw -R "$pwroot" usershow -n "$nu" 2>/dev/null || true)
  [ -n "$line" ] || fail "$nu is not in the scratch password file"
  [ "$(echo "$line" | cut -d: -f8)" = "$nu Person" ] || fail "the full name: $line"
  sudo pw -R "$pwroot" groupshow wheel | grep -q "$nu" || fail "$nu, ticked as an administrator, is not in wheel"
  await "accounts: .*$nu(admin)" 0 "the list does not show $nu as an administrator"
  echo "ok: 3. Create User: $nu made, an administrator, and listed"
else
  last "accounts: not applied" | grep -q "not FreeBSD" || fail "on Linux the refusal was not shown: $(last 'accounts: ')"
  grep -q "$nu" "$pwroot/etc/passwd" && fail "something was written"
  echo "ok: 3. Create User on Linux: the helper's refusal, in its words; nothing written"
  echo "all green (Linux half: the list, the sheet, and the refusal)."
  exit 0
fi

# ------------------------------------------------------------- 4. automatic login, delete
click "row.$nu"
b=$(mark "accounts: applied"); click auto
await "accounts: applied" "$b" "Log in automatically did nothing"
grep -q "^abyss_desktop_user=\"$nu\"" "$work/rc.conf" || fail "rc.conf: $(cat "$work/rc.conf")"
b=$(mark "accounts: delete sheet"); click delete
await "accounts: delete sheet for $nu" "$b" "Delete User did not ask"
b=$(mark "accounts: applied"); click confirm
await "accounts: applied" "$b" "the deletion came to nothing"
[ -z "$(sudo pw -R "$pwroot" usershow -n "$nu" 2>/dev/null || true)" ] || fail "$nu is still there"
[ -d "$pwroot/home/$nu" ] || fail "$nu's home folder went, unasked"
echo "ok: 4. automatic login as $nu written to rc.conf; Delete User asked, deleted it, and kept its home"
for s in "first-$$" "second-$$"; do grep -qF -- "$s" "$work/app.log" && fail "the app's log has a typed password"; done
echo "all green (the Accounts pane makes, logs in automatically, and deletes — through the helper)."
