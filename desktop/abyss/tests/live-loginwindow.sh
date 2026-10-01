#!/bin/sh
# AbyssBSD Swift DE — the Aqua login window (PHASE16 P16.5a).
#
# `AQUA_SCENE=loginwindow` over undertow, asking the daemon's own loop
# (`abyss-loginstub`: the real LoginService, PAM replaced by a password file,
# this test's account standing in for `_loginwindow`). The list it shows is
# this account and one name that is not an account (ABYSS_LOGINWINDOW_ACCOUNTS
# — harmless: the daemon checks the *named* account). Claims:
#
#   1. it lists the accounts; one chosen by a click shows its password view;
#   2. a wrong password is refused and the panel shakes;
#   3. Back returns to the list; the arrow keys and Return choose;
#   4. a name that is not an account is refused like a wrong password — the
#      window cannot be used to learn which names exist;
#   5. the right password is accepted: "Logging in…" (the session switch is
#      P16.5b's);
#   6. Restart, from the login window: the daemon lets its account ask, and
#      the stand-in shutdown ran;
#   7. no typed password in anything written.
#
# Usage: abyss/tests/live-loginwindow.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

bin="$root/.build/debug"
for b in undertow AquaDemo abyss-loginstub abyssgrab; do [ -x "$bin/$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-lgw.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in ${lw:-} ${vk:-} ${vp:-} ${st:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E 'LoginWindow' "$work/lw.log" 2>/dev/null | tail -6 | sed 's/^/  window| /'
         grep -E '^loginwindow' "$work/stub.log" 2>/dev/null | tail -3 | sed 's/^/  daemon| /'
         exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 120 ]; do i=$((i + 1)); sleep 0.05; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
at() { grep 'LoginWindow: layout' "$work/lw.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p" | tr ',' ' '; }
click() { xy=$(at "$1"); [ -n "$xy" ] || fail "the window's layout does not say where $1 is"; printf 'm %s\np\nr\n' "$xy" >&3; }

for x in vpointer:wlr-virtual-pointer-unstable-v1 vkeyboard:virtual-keyboard-unstable-v1; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$root/abyss/tests/$f.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$f.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"

me=$(id -un)
pw="window-sesame-$$"
printf '%s\n' "$pw" > "$work/pw"
printf '#!/bin/sh\necho "shutdown $*" >> "%s/power.log"\n' "$work" > "$work/shutdown"; chmod 755 "$work/shutdown"
: > "$work/power.log"
"$bin/abyss-loginstub" --socket "$work/auth.sock" --password-file "$work/pw" \
    --shutdown "$work/shutdown" --greeter-uid "$(id -u)" > "$work/stub.log" 2>&1 & st=$!
await "$work/stub.log" 'answering at' "the daemon never started"
export ABYSS_LOGIN_SOCKET="$work/auth.sock"

env -u WAYLAND_DISPLAY "$bin/undertow" run --hz 60 --frames 0 --width 800 --height 600 \
    --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; wd=""
while [ $i -lt 60 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break; sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
export WAYLAND_DISPLAY="$wd"
mkfifo "$work/vp" "$work/vk"
"$work/vpointer" 800 600 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"

ghost="nosuch$$"
ABYSS_LOGINWINDOW_ACCOUNTS="$ghost:Not An Account:1999,$me:Test Account:$(id -u)" ABYSS_CONFIG_DIR="$work" \
  AQUA_SCENE=loginwindow "$bin/AquaDemo" > "$work/lw.out" 2> "$work/lw.log" & lw=$!
await "$work/lw.log" 'LoginWindow: layout' "the login window never drew"

# ------------------------------------------------------------ 1. the list
grep -q "LoginWindow: up: $ghost $me" "$work/lw.log" || fail "the list: $(grep 'LoginWindow: up' "$work/lw.log")"
click "$me"
await "$work/lw.log" "LoginWindow: chose $me" "clicking an account did not choose it"
echo "ok: 1. the window listed the accounts, and a click chose one"

# ------------------------------------------------------------ 2. wrong
sleep 0.3; printf 't wrong-1\nk 28\n' >&4
await "$work/lw.log" 'LoginWindow: refused — shake' "a wrong password was not refused"
await "$work/stub.log" "login $me: refused" "the daemon did not refuse it"
echo "ok: 2. a wrong password was refused, and the panel shook"

# ------------------------------------------------------------ 3. Back, then the keys
sleep 0.7; click back
await "$work/lw.log" 'LoginWindow: back to the list' "Back did not return to the list"
printf 'k 103\nk 28\n' >&4                                      # Up (to the first), Return
await "$work/lw.log" "LoginWindow: chose $ghost" "the arrow keys and Return did not choose"
echo "ok: 3. Back returned to the list; Up and Return chose"

# ------------------------------------------------------------ 4. not an account
sleep 0.3; printf 't %s\nk 28\n' "$pw" >&4
await "$work/lw.log" 'LoginWindow: refused — shake' "a name that is not an account was not refused" 2
await "$work/stub.log" "login $ghost: refused (no such account)" "the daemon did not say why, to itself"
grep -q "LoginWindow: accepted $ghost" "$work/lw.log" && fail "a name that is not an account was accepted"
echo "ok: 4. a name that is not an account was refused just like a wrong password"

# ------------------------------------------------------------ 5. right
sleep 0.7; printf 'k 1\n' >&4                                   # Escape: back to the list
await "$work/lw.log" 'LoginWindow: back to the list' "Escape on an empty field did not go back" 2
printf 'k 108\nk 28\n' >&4                                      # Down, Return: this account
await "$work/lw.log" "LoginWindow: chose $me" "Down and Return did not choose this account" 2
sleep 0.3; printf 't %s\nk 28\n' "$pw" >&4
await "$work/lw.log" "LoginWindow: accepted $me — logging in" "the right password was not accepted"
await "$work/stub.log" "login $me: accepted" "the daemon did not accept it"
echo "ok: 5. the right password was accepted: logging in"

# ------------------------------------------------------------ 6. Restart from the window
click restart
await "$work/lw.log" 'LoginWindow: restart → ok' "Restart from the login window was refused"
await "$work/power.log" '^shutdown -r now' "Restart did not run shutdown -r"
echo "ok: 6. Restart from the login window: the daemon let it, and shutdown -r ran"

for f in lw.log lw.out stub.log ut.out ut.err; do
  for p in "$pw" wrong-1; do grep -qF -- "$p" "$work/$f" && fail "$f contains a typed password"; done
done
echo "ok: 7. no typed password in anything written"
echo "all green (the login window lists, asks, shakes, refuses names that are not accounts, and logs in)."
