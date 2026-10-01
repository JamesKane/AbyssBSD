#!/bin/sh
# AbyssBSD Swift DE — the session's idle policy (PHASE16 P16.3).
#
# A real-shaped session — undertow with a privileged socket, anchor running
# the bar and `abyss-idle` — with a minute made a second (ABYSS_IDLE_MINUTE)
# and energy.ini saying: the display sleeps after 1, the computer after 4, a
# password required. The machine's half of sleep is the root daemon's
# (P16.4); here a stand-in (`abyss-loginstub`) records the request. Claims:
#
#   1. left alone, the session locks when the display's time comes, and when
#      the computer's comes the machine is asked to sleep — the session
#      already locked;
#   2. an idle inhibitor (a video, `idletest i`) holds both off;
#   3. dropped, idleness counts again: it locks, and asks to sleep;
#   4. input holds it off: a pointer moving now and then, no lock;
#   5. "require a password" off (energy.ini rewritten while running): no lock
#      — but the computer is still asked to sleep;
#   6. the display never sleeps, the computer does, a password required: the
#      session is locked *by the sleep* before the machine is asked — so it
#      wakes locked whatever the display's delay.
#
# Usage: abyss/tests/live-idlepolicy.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

bin="$root/.build/debug"
for b in undertow AquaDemo abyss-loginstub anchor abyssctl abyss-idle; do
  [ -x "$bin/$b" ] || { swift build; break; }
done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-idp.XXXXXX)
priv="abyss-idp-priv-$$"
cleanup() {
  exec 3>&- 4>&- 5>&- 2>/dev/null || true
  for p in ${an:-} ${it:-} ${vk:-} ${vp:-} ${st:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^anchor:|^abyss-idle|^LockScreen' "$work/session.log" 2>/dev/null | tail -8 | sed 's/^/  session| /'
         grep -E '^session-lock' "$work/ut.out" 2>/dev/null | tail -2 | sed 's/^/  undertow| /'
         grep -E 'power' "$work/stub.log" 2>/dev/null | tail -2 | sed 's/^/  stub| /'
         exit 1; }
# 0, not nothing, when the file is not there yet: an empty count made the
# wait's test an error, which ended the wait at once (HANDOFF §2.106).
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES] [TENTHS]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt "${5:-120}" ]; do i=$((i + 1)); sleep 0.1; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
state() { grep '^session-lock' "$work/ut.out" | tail -1 | cut -d' ' -f2; }
locks() { grep '^session-lock' "$work/ut.out" | tail -1 | sed -n 's/.* locks=\([0-9]*\) .*/\1/p'; }
sleeps() { count 'loginwindow: uid [0-9]*: sleep — ' "$work/stub.log"; }

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
for x in "vpointer:$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" \
         "vkeyboard:$root/abyss/tests/virtual-keyboard-unstable-v1.xml" \
         "idle-inhibit:$protos/unstable/idle-inhibit/idle-inhibit-unstable-v1.xml" \
         "ext-idle-notify:$protos/staging/ext-idle-notify/ext-idle-notify-v1.xml" \
         "primary-selection:$protos/unstable/primary-selection/primary-selection-unstable-v1.xml"; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$f" "$work/$n-proto.h"
  wayland-scanner private-code  "$f" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/idletest.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/idle-inhibit-proto.c" "$work/ext-idle-notify-proto.c" \
   "$work/primary-selection-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/idletest" || fail "idletest"

rt="$work/rt"; mkdir -p "$rt" "$work/cfg"; chmod 700 "$rt"
export ABYSS_RUNTIME_DIR="$rt" ABYSS_CONFIG_DIR="$work/cfg" PATH="$bin:$PATH" ABYSS_IDLE_MINUTE=1
printf '[energy]\ndisplay_sleep_minutes = 1\nsystem_sleep_minutes = 4\nrequire_password = true\n' > "$work/cfg/energy.ini"
pw="idle-sesame-$$"
printf '%s\n' "$pw" > "$work/pw"
"$bin/abyss-loginstub" --socket "$work/auth.sock" --password-file "$work/pw" 2> "$work/stub.log" & st=$!
export ABYSS_LOGIN_SOCKET="$work/auth.sock"

# undertow's own display sleep reads the same energy.ini — a real minute
# here, so the displays stay lit while this test watches them.
env -u WAYLAND_DISPLAY "$bin/undertow" run --hz 60 --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" --privileged-socket "$priv" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
await "$work/ut.out" "WAYLAND_PRIVILEGED=$priv" "undertow never came up"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)
export WAYLAND_DISPLAY="$wd"

mkfifo "$work/vp" "$work/vk" "$work/it"
"$work/vpointer" 800 600 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"
"$work/idletest" org.abyssbsd.idlepolicy < "$work/it" > "$work/it.log" 2>&1 & it=$!; exec 5>"$work/it"
await "$work/it.log" ready "idletest never mapped"

"$bin/anchor" --display "$wd" --menubar-display "$priv" --runtime-dir "$rt" --binary "$bin/AquaDemo" \
    --without bus --without portal --without bridge --without menus --without desktop --without dock --without setup \
    > "$work/session.log" 2>&1 &
an=$!
await "$work/session.log" 'abyss-idle: armed: lock after 1 s, sleep after 4 s' "abyss-idle never armed its timers"
await "$work/session.log" "MenuBar: frontmost" "the bar never came up"

# energy DISPLAY COMPUTER PASSWORD: rewrite energy.ini as the Energy pane does —
# a new file renamed over the old (Config.store). An edit in place changes no
# directory entry, and FreeBSD's kqueue watch on the directory never sees it.
energy() {
  printf '[energy]\ndisplay_sleep_minutes = %s\nsystem_sleep_minutes = %s\nrequire_password = %s\n' "$1" "$2" "$3" \
    > "$work/cfg/.energy.ini.new"
  mv "$work/cfg/.energy.ini.new" "$work/cfg/energy.ini"
}

unlock() {
  n=$(count 'the lock screen unlocked the session' "$work/session.log")
  await "$work/session.log" 'LockScreen: locked$' "the lock screen never said it had locked" "$1"
  sleep 0.3
  printf 't %s\nk 28\n' "$pw" >&4
  await "$work/session.log" 'the lock screen unlocked the session' "the right password did not unlock" $((n + 1))
  sleep 0.3
  [ "$(state)" = unlocked ] || fail "after unlocking, the session is $(state)"
}

# ------------------------------------------------------------ 1. idle: lock, then sleep
await "$work/session.log" 'abyss-idle: idle (the display sleeps): locking' "a second of idleness did not lock"
await "$work/ut.out" '^session-lock locked locks=1 ' "undertow was not locked"
await "$work/stub.log" 'loginwindow: uid [0-9]*: sleep — ' "four seconds of idleness did not ask the machine to sleep" 1 80
[ "$(state)" = locked ] || fail "when the machine was asked to sleep, the session was $(state)"
[ "$(locks)" = 1 ] || fail "the sleep locked a second time ($(locks)) instead of finding it locked"
echo "ok: 1. idle: locked when the display's time came, and the machine was asked to sleep — already locked"
unlock 1

# ------------------------------------------------------------ 2. an inhibitor holds both
printf 'i\n' >&5; sleep 0.2
before=$(sleeps)
sleep 5.5
[ "$(locks)" = 1 ] || fail "with an idle inhibitor held, the session locked"
[ "$(sleeps)" = "$before" ] || fail "with an idle inhibitor held, the machine was asked to sleep"
echo "ok: 2. an idle inhibitor held both off (5.5 s)"

# ------------------------------------------------------------ 3. dropped: it counts again
printf 'I\n' >&5
await "$work/ut.out" '^session-lock locked locks=2 ' "with the inhibitor dropped, the session did not lock" 1 40
await "$work/stub.log" 'loginwindow: uid [0-9]*: sleep — ' "with the inhibitor dropped, the machine was not asked to sleep" $((before + 1)) 80
echo "ok: 3. the inhibitor dropped: it locked, and asked to sleep"
unlock 2

# ------------------------------------------------------------ 4. input holds it off
n=0; x=300
while [ $n -lt 8 ]; do printf 'm %s 300\n' $x >&3; x=$((x + 7)); sleep 0.4; n=$((n + 1)); done
[ "$(locks)" = 2 ] || fail "with the pointer moving every 0.4 s, the session locked"
echo "ok: 4. input every 0.4 s held it off (3.2 s)"

# ------------------------------------------------------------ 5. no password required
energy 1 4 false
await "$work/session.log" 'abyss-idle: armed: lock after never, sleep after 4 s (no password required: no lock)' \
  "abyss-idle did not take the change to energy.ini"
before=$(sleeps)
await "$work/stub.log" 'loginwindow: uid [0-9]*: sleep — ' "with no password required, the machine was not asked to sleep" $((before + 1)) 80
[ "$(locks)" = 2 ] && [ "$(state)" = unlocked ] || fail "with no password required, the session locked ($(state), locks=$(locks))"
echo "ok: 5. no password required: no lock, and the machine was still asked to sleep"

# ------------------------------------------------------------ 6. locked by the sleep itself
energy 0 2 true
await "$work/session.log" 'abyss-idle: armed: lock after never, sleep after 2 s$' "abyss-idle did not take the second change"
printf 'm 420 300\n' >&3                                 # start the count from now
before=$(sleeps)
await "$work/stub.log" 'loginwindow: uid [0-9]*: sleep — ' "with the display never sleeping, the machine was not asked to sleep" $((before + 1)) 80
[ "$(locks)" = 3 ] && [ "$(state)" = locked ] \
  || fail "the machine was asked to sleep and the session was not locked first ($(state), locks=$(locks))"
grep -q 'abyss-idle: the machine is about to sleep: locking' "$work/session.log" || fail "the sleep did not say it locked"
echo "ok: 6. the display never sleeps: the sleep itself locked the session before asking"
unlock 3

for f in session.log ut.out stub.log; do grep -qF -- "$pw" "$work/$f" && fail "$f contains the password"; done
echo "all green (idleness locks and sleeps as energy.ini says, an inhibitor or a hand on the mouse holds it off)."
