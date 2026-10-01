#!/bin/sh
# AbyssBSD Swift DE — locking the session, three ways (PHASE16 P16.2c).
#
# undertow with a privileged socket, anchor supervising the menu bar there,
# and a window (blue) on the ordinary socket — the shape of a real session.
# The lock screen asks a stand-in authenticator (`abyss-loginstub`, as in
# live-lockscreen.sh). Claims:
#
#   1. an application — anything on the ordinary socket — is not offered the
#      session lock: it cannot lock, and cannot take over a lock whose screen
#      died; the privileged socket is;
#   2. `abyssctl lock` asks anchor, which starts the lock screen: the session
#      locks, and asking again says it already is;
#   3. the lock screen killed (SIGKILL) while locked: the session stays
#      locked, anchor restarts the lock screen, and it takes the lock over;
#   4. the right password unlocks; anchor sees an unlock, not a crash, and
#      starts nothing — the session stays unlocked;
#   5. ⌃⌘Q locks (undertow's binding runs `abyssctl lock`);
#   6. System > Lock Screen locks (the bar asks anchor);
#   7. no typed password in anything the session wrote.
#
# Usage: abyss/tests/live-locksession.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

bin="$root/.build/debug"
for b in undertow abyssgrab AquaDemo abyss-loginstub anchor abyssctl; do
  [ -x "$bin/$b" ] || { swift build; break; }
done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-lss.XXXXXX)
priv="abyss-lss-priv-$$"
cleanup() {
  exec 3>&- 4>&- 5>&- 2>/dev/null || true
  for p in ${an:-} ${wa:-} ${vk:-} ${vp:-} ${st:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^anchor:|^LockScreen' "$work/session.log" 2>/dev/null | tail -6 | sed 's/^/  session| /'
         grep -E '^session-lock' "$work/ut.out" 2>/dev/null | tail -2 | sed 's/^/  undertow| /'
         exit 1; }
await() {  # await FILE PATTERN WHY [TIMES]
  i=0; while [ "$(grep -c -- "$2" "$1" 2>/dev/null || true)" -lt "${4:-1}" ] && [ $i -lt 120 ]; do i=$((i + 1)); sleep 0.05; done
  [ "$(grep -c -- "$2" "$1" 2>/dev/null || true)" -ge "${4:-1}" ] || fail "$3"
}
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }
state() { grep '^session-lock' "$work/ut.out" | tail -1 | cut -d' ' -f2; }
shot() { "$bin/abyssgrab" "$work/$1.ppm" > "$work/grab.log" 2>&1 || fail "abyssgrab: $(cat "$work/grab.log")"; }
has() {
  hdr=$(head -3 "$work/$1.ppm" | wc -c | tr -d ' ')
  tail -c +$((hdr + 1)) "$work/$1.ppm" | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
    | awk -v r="$2" -v g="$3" -v b="$4" '{ v[NR % 3] = $1 } NR % 3 == 0 && v[1] == r && v[2] == g && v[0] == b { n++ } END { print n + 0 }'
}

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
wayland-scanner client-header "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.h"
wayland-scanner private-code  "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.c"
for x in vpointer:wlr-virtual-pointer-unstable-v1 vkeyboard:virtual-keyboard-unstable-v1; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$root/abyss/tests/$f.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$f.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/lockclient.c" "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   "$work/ext-session-lock-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/lockclient" || fail "lockclient"

# One runtime directory for anchor's socket, the bar and undertow's `run:`
# children (`abyssctl lock` has to find anchor); `abyssctl` on the PATH.
rt="$work/rt"; mkdir -p "$rt" "$work/cfg"; chmod 700 "$rt"
export ABYSS_RUNTIME_DIR="$rt" ABYSS_CONFIG_DIR="$work/cfg" PATH="$bin:$PATH"
pw="opensesame-$$"
printf '%s\n' "$pw" > "$work/pw"
"$bin/abyss-loginstub" --socket "$work/auth.sock" --password-file "$work/pw" 2> "$work/stub.log" & st=$!
export ABYSS_LOGIN_SOCKET="$work/auth.sock"

env -u WAYLAND_DISPLAY "$bin/undertow" run --hz 60 --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" --privileged-socket "$priv" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
await "$work/ut.out" "WAYLAND_PRIVILEGED=$priv" "undertow never came up"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)
export WAYLAND_DISPLAY="$wd"

mkfifo "$work/vp" "$work/vk" "$work/a"
"$work/vpointer" 800 600 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"
"$work/lockclient" window ff336699 org.abyssbsd.lockwindow-a < "$work/a" > "$work/a.log" 2>&1 & wa=$!; exec 5>"$work/a"
await "$work/a.log" ready "the window never started"

"$bin/anchor" --display "$wd" --menubar-display "$priv" --runtime-dir "$rt" --binary "$bin/AquaDemo" \
    --without bus --without portal --without bridge --without menus --without desktop --without dock \
    > "$work/session.log" 2>&1 &
an=$!
await "$work/session.log" "MenuBar: frontmost" "the bar never came up under anchor"
sleep 0.5; shot desk
[ "$(has desk 51 102 153)" -gt 1000 ] || fail "before locking, the window is not on screen"

# unlock: type the password into the lock screen and wait for anchor to see it.
unlock() {
  n=$(count 'the lock screen unlocked the session' "$work/session.log")
  await "$work/session.log" 'LockScreen: locked$' "the lock screen never said it had locked" "$1"
  sleep 0.4
  printf 't %s\nk 28\n' "$pw" >&4
  await "$work/session.log" 'the lock screen unlocked the session' "the right password did not unlock" $((n + 1))
  await "$work/ut.out" '^session-lock unlocked ' "undertow does not say it is unlocked" "$2"
}

# ------------------------------------------------------------ 1. not for applications
set +e; "$work/lockclient" lock ff2a5a2a < /dev/null > "$work/app-lock.log" 2>&1; rc=$?; set -e
[ "$rc" = 2 ] && grep -q 'ext_session_lock_manager_v1: no' "$work/app-lock.log" \
  || fail "an application on the ordinary socket was offered the session lock (rc=$rc: $(cat "$work/app-lock.log"))"
WAYLAND_DISPLAY="$priv" "$work/lockclient" lock ff2a5a2a < /dev/null > "$work/priv-lock.log" 2>&1 || true
grep -q '^ready' "$work/priv-lock.log" || fail "the privileged socket was not offered the session lock: $(cat "$work/priv-lock.log")"
echo "ok: 1. the session lock is offered on the privileged socket and to no application"

# ------------------------------------------------------------ 2. abyssctl lock
out=$("$bin/abyssctl" lock 2>&1) || fail "abyssctl lock failed: $out"
[ "$out" = "session: locking" ] || fail "abyssctl lock said '$out'"
await "$work/ut.out" '^session-lock locked ' "abyssctl lock did not lock the session"
again=$("$bin/abyssctl" lock 2>&1) || fail "abyssctl lock, asked again, failed: $again"
[ "$again" = "session: already locked" ] || fail "asked again, abyssctl lock said '$again'"
sleep 0.4; shot locked
[ "$(has locked 51 102 153)" = 0 ] || fail "locked, the window shows"
echo "ok: 2. abyssctl lock: anchor started the lock screen and the session locked; asked again, it already is"

# ------------------------------------------------------------ 3. the lock screen killed
await "$work/session.log" 'LockScreen: locked$' "the lock screen never said it had locked"
pid=$(grep 'lock screen up (pid' "$work/session.log" | tail -1 | sed -n 's/.*(pid \([0-9][0-9]*\)).*/\1/p')
[ -n "$pid" ] || fail "anchor did not say which process the lock screen is: $(grep 'lock screen up' "$work/session.log" | tail -1)"
kill -KILL "$pid"
await "$work/session.log" 'the lock screen died while the session was locked — restarting it' \
  "anchor did not restart a lock screen that died"
await "$work/ut.out" 'locks=2 ' "the restarted lock screen did not take the abandoned lock over"
[ "$(state)" = locked ] || fail "after the lock screen died, the session is $(state)"
sleep 0.4; shot relocked
[ "$(has relocked 51 102 153)" = 0 ] || fail "after the lock screen died, the window shows"
echo "ok: 3. the lock screen killed: still locked, anchor restarted it, and it took the lock over"

# ------------------------------------------------------------ 4. unlock, and stay unlocked
unlock 2 1
sleep 1
[ "$(state)" = unlocked ] || fail "a second after unlocking, the session is $(state) — anchor restarted the lock screen?"
[ "$(count 'restarting it' "$work/session.log")" = 1 ] || fail "anchor took an unlock for a crash"
shot back
[ "$(has back 51 102 153)" -gt 1000 ] || fail "unlocked, the window is not back"
echo "ok: 4. the right password unlocked it; anchor saw an unlock, restarted nothing, and it stays unlocked"

# ------------------------------------------------------------ 5. ⌃⌘Q
printf 'c 68 16\n' >&4                                  # Ctrl (4) + Logo (64), Q
await "$work/ut.out" '^session-lock locked locks=3 ' "⌃⌘Q did not lock the session"
echo "ok: 5. ⌃⌘Q locked the session"
unlock 3 2

# ------------------------------------------------------------ 6. System > Lock Screen
title_at() {
  grep -F 'MenuBar: titles ' "$work/session.log" | tail -1 | tr ' ' '\n' \
    | grep "^$1@" | head -1 | cut -d@ -f2 | tr ',' ' '
}
item_line() {
  awk -v m="MenuBar: opened $1" 'index($0, m) { buf = ""; on = 1; next }
       on && /MenuBar: item / { buf = buf $0 "\n"; next }
       on { on = 0 } END { printf "%s", buf }' "$work/session.log" | grep -F "'$2" | tail -1
}
xy=$(title_at System); [ -n "$xy" ] || fail "the bar did not say where its System menu is"
n=$(count 'MenuBar: opened System' "$work/session.log")
printf 'm %s %s\np\nr\n' $xy >&3
await "$work/session.log" 'MenuBar: opened System' "the System menu did not open" $((n + 1))
line=$(item_line System "Lock Screen")
case "$line" in *" enabled "*) ;; *) fail "System > Lock Screen is missing or disabled: $line" ;; esac
printf 'm %s %s\np\nr\n' $(echo "$line" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p") >&3
await "$work/session.log" 'chose System > Lock Screen (system.lock) → ok' "choosing Lock Screen did not say ok"
await "$work/ut.out" '^session-lock locked locks=4 ' "System > Lock Screen did not lock the session"
echo "ok: 6. System > Lock Screen locked the session"
unlock 4 3

# ------------------------------------------------------------ 7. never written
for f in session.log ut.out ut.err stub.log; do
  grep -qF -- "$pw" "$work/$f" && fail "$f contains the password"
done
echo "ok: 7. the password is in nothing the session wrote ($(count 'the lock screen unlocked the session' "$work/session.log") unlocks)"

echo "all green (the session locks from the command line, the keyboard and the menu, survives its lock screen dying, and only applications are left out)."
