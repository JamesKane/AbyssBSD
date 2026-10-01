#!/bin/sh
# AbyssBSD Swift DE — sleep, restart and shut down through the daemon
# (PHASE16 P16.4a).
#
# A real-shaped session (undertow with a privileged socket, anchor running the
# bar and `abyss-idle`, the session's power agent) and the daemon's own loop,
# `LoginService`, in `abyss-loginstub` — its PAM replaced, its `acpiconf` and
# `shutdown` stand-ins that record what they were asked **and whether the
# session was locked at that moment** (`abyssctl status`), as PHASE16 §6.3
# decided. Claims:
#
#   1. System > Sleep: the session locks first — the stand-in ran with the
#      compositor locked — and the session hears the machine wake;
#   2. a sleep asked from a shell (`abyss-loginctl power sleep`) locks it
#      just the same: the lock is the daemon's rule, not the menu's;
#   3. "require a password" off: the machine sleeps with nothing locked;
#   4. a session that cannot answer (its agent stopped) calls the sleep off:
#      no stand-in run, and the asker told why;
#   5. restart and shut down: run for an administrator (wheel or operator),
#      refused in words for anyone else — whichever this account is;
#   6. the daemon restarted: the agent watches again, and a sleep still locks;
#   7. System > Restart… and Shut Down… ask first (P16.4b): Escape cancels
#      with nothing run; Return chooses — run for an administrator, the
#      refusal shown in the dialog for anyone else;
#   8. the power key (devd's `power power-key`): the session asks — Restart,
#      Sleep, Cancel, Shut Down — and Sleep, clicked, sleeps it locked;
#   9. the lid (`power lid`) sleeps it, locked first;
#  10. the power key with no session to ask: the machine shuts down, as the
#      kernel's own default would have.
#
# The stand-in daemon takes this test's uid as devd's (`--system-uid`); that
# anyone else's word about the buttons is refused is LoginTests', and the
# real daemon's in live-authenticator.sh.
#
# Usage: abyss/tests/live-power.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

bin="$root/.build/debug"
for b in undertow AquaDemo abyss-loginstub abyss-loginctl anchor abyssctl abyss-idle; do
  [ -x "$bin/$b" ] || { swift build; break; }
done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-pwr.XXXXXX)
priv="abyss-pwr-priv-$$"
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  [ -n "${agent:-}" ] && kill -CONT "$agent" 2>/dev/null || true
  for p in ${an:-} ${vk:-} ${vp:-} ${st:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^anchor:|^abyss-idle|^LockScreen|MenuBar: chose' "$work/session.log" 2>/dev/null | tail -8 | sed 's/^/  session| /'
         grep -E '^loginwindow' "$work/stub.log" 2>/dev/null | tail -4 | sed 's/^/  daemon| /'
         sed 's/^/  stand-in| /' "$work/power.log" 2>/dev/null | tail -3
         exit 1; }
# 0, not nothing, when the file is not there yet: an empty count made the
# wait's test an error, which ended the wait at once (HANDOFF §2.106).
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES] [TENTHS]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt "${5:-120}" ]; do i=$((i + 1)); sleep 0.1; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
# The session's lock as anchor knows it — "locked" only once the compositor
# said so (P16.3) — the same word the stand-ins record.
state() { "$bin/abyssctl" status 2>/dev/null | sed -n 's/^lock: //p'; }
runs() { count "$1" "$work/power.log"; }

for x in vpointer:wlr-virtual-pointer-unstable-v1 vkeyboard:virtual-keyboard-unstable-v1; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$root/abyss/tests/$f.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$f.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"

rt="$work/rt"; mkdir -p "$rt" "$work/cfg"; chmod 700 "$rt"
export ABYSS_RUNTIME_DIR="$rt" ABYSS_CONFIG_DIR="$work/cfg" PATH="$bin:$PATH"
# energy DISPLAY COMPUTER PASSWORD, written as the Energy pane writes it.
energy() {
  printf '[energy]\ndisplay_sleep_minutes = %s\nsystem_sleep_minutes = %s\nrequire_password = %s\n' "$1" "$2" "$3" \
    > "$work/cfg/.energy.ini.new"
  mv "$work/cfg/.energy.ini.new" "$work/cfg/energy.ini"
}
energy 0 0 true                       # idleness does nothing here: every sleep is asked for

# The stand-ins: what they were asked, and the session's lock at that moment.
for c in acpiconf shutdown; do
  printf '#!/bin/sh\necho "%s $* lock=$(abyssctl status 2>/dev/null | sed -n "s/^lock: //p")" >> "%s/power.log"\n' \
    "$c" "$work" > "$work/$c"
  chmod 755 "$work/$c"
done
: > "$work/power.log"
pw="power-sesame-$$"
printf '%s\n' "$pw" > "$work/pw"
start_daemon() {
  "$bin/abyss-loginstub" --socket "$work/auth.sock" --password-file "$work/pw" \
      --acpiconf "$work/acpiconf" --shutdown "$work/shutdown" --lock-timeout 2 --system-uid "$(id -u)" \
      >> "$work/stub.log" 2>&1 &
  st=$!
  await "$work/stub.log" 'answering at' "the daemon never started" "$1"
}
start_daemon 1
export ABYSS_LOGIN_SOCKET="$work/auth.sock"
ctl() { "$bin/abyss-loginctl" --socket "$work/auth.sock" power "$1" 2>&1 || true; }

env -u WAYLAND_DISPLAY "$bin/undertow" run --hz 60 --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" --privileged-socket "$priv" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
await "$work/ut.out" "WAYLAND_PRIVILEGED=$priv" "undertow never came up"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)
export WAYLAND_DISPLAY="$wd"
mkfifo "$work/vp" "$work/vk"
"$work/vpointer" 800 600 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"

"$bin/anchor" --display "$wd" --menubar-display "$priv" --runtime-dir "$rt" --binary "$bin/AquaDemo" \
    --without bus --without portal --without bridge --without menus --without desktop --without dock \
    > "$work/session.log" 2>&1 &
an=$!
await "$work/session.log" 'abyss-idle: watching for the machine' "the session's agent never watched the daemon"
await "$work/stub.log" "session is watching (1 watching)" "the daemon never saw the session watch"
await "$work/session.log" "MenuBar: frontmost" "the bar never came up"

unlock() {
  n=$(count 'the lock screen unlocked the session' "$work/session.log")
  await "$work/session.log" 'LockScreen: locked$' "the lock screen never said it had locked" "$1"
  sleep 0.3
  printf 't %s\nk 28\n' "$pw" >&4
  await "$work/session.log" 'the lock screen unlocked the session' "the right password did not unlock" $((n + 1))
  sleep 0.3
}

# ------------------------------------------------------------ 1. System > Sleep
title_at() {
  grep -F 'MenuBar: titles ' "$work/session.log" | tail -1 | tr ' ' '\n' \
    | grep "^$1@" | head -1 | cut -d@ -f2 | tr ',' ' '
}
item_line() {
  awk -v m="MenuBar: opened $1" 'index($0, m) { buf = ""; on = 1; next }
       on && /MenuBar: item / { buf = buf $0 "\n"; next }
       on { on = 0 } END { printf "%s", buf }' "$work/session.log" | grep -F "'$2" | tail -1
}
n=$(count 'MenuBar: opened System' "$work/session.log")
printf 'm %s %s\np\nr\n' $(title_at System) >&3
await "$work/session.log" 'MenuBar: opened System' "the System menu did not open" $((n + 1))
line=$(item_line System "Sleep")
case "$line" in *" enabled "*) ;; *) fail "System > Sleep is missing or disabled: $line" ;; esac
printf 'm %s %s\np\nr\n' $(echo "$line" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p") >&3
await "$work/power.log" '^acpiconf -s 3 ' "System > Sleep did not reach acpiconf"
[ "$(grep '^acpiconf' "$work/power.log" | tail -1)" = "acpiconf -s 3 lock=locked" ] \
  || fail "acpiconf ran with the session not locked: $(tail -1 "$work/power.log")"
await "$work/session.log" 'chose System > Sleep (system.sleep) → ok going to sleep' "the menu did not say the machine was going to sleep"
await "$work/session.log" 'abyss-idle: the machine is awake' "the session never heard the machine wake"
echo "ok: 1. System > Sleep: acpiconf -s 3 ran with the session locked, and the session heard it wake"
unlock 1

# ------------------------------------------------------------ 2. from a shell
[ "$(ctl sleep)" = ok ] || fail "abyss-loginctl power sleep: $(ctl sleep)"
# The daemon answers before it runs acpiconf (the asker is not held while the
# machine sleeps), so the record is awaited, not counted at once.
await "$work/power.log" '^acpiconf -s 3 lock=locked$' "a shell's sleep: $(tail -1 "$work/power.log")" 2
echo "ok: 2. a sleep asked from a shell locked the session first too"
unlock 2

# ------------------------------------------------------------ 3. no password required
energy 0 0 false
await "$work/session.log" 'abyss-idle: energy.ini changed' "the agent did not take the change"
[ "$(ctl sleep)" = ok ] || fail "with no password required, sleep was refused"
await "$work/power.log" '^acpiconf' "with no password required, acpiconf never ran" 3
[ "$(grep '^acpiconf' "$work/power.log" | tail -1)" = "acpiconf -s 3 lock=no" ] \
  || fail "with no password required: $(tail -1 "$work/power.log")"
[ "$(state)" = no ] || fail "with no password required, the session is $(state)"
echo "ok: 3. no password required: the machine slept with nothing locked"
energy 0 0 true
await "$work/session.log" 'abyss-idle: energy.ini changed' "the agent did not take the change back" 2

# ------------------------------------------------------------ 4. a session that cannot answer
agent=$(pgrep -P "$an" -f abyss-idle | head -1)
[ -n "$agent" ] || fail "cannot find the session's agent"
kill -STOP "$agent"
before=$(runs '^acpiconf')
got=$(ctl sleep)
case "$got" in "refused: the computer did not sleep: uid "*" did not lock in 2 s") ;; *) fail "a stopped agent: $got" ;; esac
[ "$(runs '^acpiconf')" = "$before" ] || fail "acpiconf ran although a session did not lock"
kill -CONT "$agent"; agent=""
await "$work/stub.log" 'a late answer from a session' "the agent's late answer was not set aside"
[ "$(count 'stopped watching' "$work/stub.log")" = 0 ] || fail "the daemon dropped a session for answering late"
echo "ok: 4. a session that could not answer called the sleep off — no acpiconf, and the asker told why"
unlock 3          # the agent, continued, locked the session as it had been asked

# ------------------------------------------------------------ 5. restart and shut down
if id -Gn | tr ' ' '\n' | grep -qx -e wheel -e operator; then
  [ "$(ctl restart)" = ok ] && [ "$(ctl shut-down)" = ok ] || fail "an administrator could not restart or shut down"
  await "$work/power.log" '^shutdown -r now ' "restart did not run shutdown -r now"
  await "$work/power.log" '^shutdown -p now ' "shut down did not run shutdown -p now"
  echo "ok: 5. an administrator ($(id -un), $(id -Gn | tr ' ' '\n' | grep -x -e wheel -e operator | head -1)): restart and shut down ran shutdown -r / -p"
else
  [ "$(ctl restart)" = "refused: only an administrator can restart this computer" ] || fail "restart: $(ctl restart)"
  [ "$(ctl shut-down)" = "refused: only an administrator can shut down this computer" ] || fail "shut down: $(ctl shut-down)"
  [ "$(runs '^shutdown')" = 0 ] || fail "shutdown ran for a non-administrator"
  echo "ok: 5. not an administrator ($(id -un)): restart and shut down refused in words, nothing run"
fi

# ------------------------------------------------------------ 6. the daemon restarted
kill "$st"; wait "$st" 2>/dev/null || true
await "$work/session.log" 'abyss-idle: the daemon went away' "the agent did not notice the daemon go"
start_daemon 2
await "$work/session.log" 'abyss-idle: watching for the machine' "the agent did not watch the new daemon" 2 60
[ "$(ctl sleep)" = ok ] || fail "after the daemon restarted, sleep: $(ctl sleep)"
await "$work/power.log" '^acpiconf' "after the daemon restarted, acpiconf never ran" 4
[ "$(grep '^acpiconf' "$work/power.log" | tail -1)" = "acpiconf -s 3 lock=locked" ] \
  || fail "after the daemon restarted: $(tail -1 "$work/power.log")"
echo "ok: 6. the daemon restarted: the agent watched again, and a sleep still locked first"
unlock 4

# ------------------------------------------------------------ 7. Restart… and Shut Down… ask
admin=0; id -Gn | tr ' ' '\n' | grep -qx -e wheel -e operator && admin=1
system_item() {  # system_item TITLE: open System, choose the row
  n=$(count 'MenuBar: opened System' "$work/session.log")
  printf 'm %s %s\np\nr\n' $(title_at System) >&3
  await "$work/session.log" 'MenuBar: opened System' "the System menu did not open" $((n + 1))
  line=$(item_line System "$1")
  case "$line" in *" enabled "*) ;; *) fail "System > $1 is missing or disabled: $line" ;; esac
  printf 'm %s %s\np\nr\n' $(echo "$line" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p") >&3
}
shutdowns=$(runs '^shutdown')
system_item "Restart"
await "$work/session.log" 'PowerDialog: up (restart)' "System > Restart… did not ask"
sleep 0.5; printf 'k 1\n' >&4                                 # Escape
await "$work/session.log" 'PowerDialog: chose Cancel' "Escape did not cancel the restart"
sleep 0.3
[ "$(runs '^shutdown')" = "$shutdowns" ] || fail "a cancelled restart ran shutdown"
offs=$(runs '^shutdown -p')
system_item "Shut Down"
await "$work/session.log" 'PowerDialog: up (shut-down)' "System > Shut Down… did not ask"
sleep 0.5; printf 'k 28\n' >&4                                # Return: the default
if [ $admin = 1 ]; then
  await "$work/session.log" 'PowerDialog: chose Shut Down → ok' "Return did not shut down"
  await "$work/power.log" '^shutdown -p now' "Shut Down did not run shutdown -p" $((offs + 1))
  echo "ok: 7. Restart… asked, and Escape ran nothing; Shut Down… asked, and Return shut down (an administrator)"
else
  await "$work/session.log" 'PowerDialog: chose Shut Down → refused: only an administrator' "the refusal was not shown"
  echo "ok: 7. Restart… asked, and Escape ran nothing; Shut Down… asked, and the refusal is in the dialog"
  printf 'k 1\n' >&4
fi

# ------------------------------------------------------------ 8. the power key
before=$(runs '^acpiconf')
# Dialogs cascade, so this one's window is a new line in undertow's report:
# count them first, or the click lands where the last dialog was.
wins=$(count '^window org.abyssbsd.power' "$work/ut.out")
[ "$(ctl power-key)" = ok ] || fail "the power key: $(ctl power-key)"
await "$work/session.log" 'abyss-idle: the power key: asking what to do' "the session did not hear the power key"
await "$work/session.log" 'PowerDialog: up (power-key)' "the power key's dialog did not open"
await "$work/session.log" 'PowerDialog: buttons .*Sleep=' "the dialog did not say where its buttons are"
await "$work/ut.out" '^window org.abyssbsd.power' "undertow never reported the dialog's window" $((wins + 1))
geom=$(grep '^window org.abyssbsd.power' "$work/ut.out" | tail -1 | awk '{print $(NF-1)}')
at=$(grep 'PowerDialog: buttons ' "$work/session.log" | tail -1 | tr ' ' '\n' | sed -n 's/^Sleep=//p')
printf 'm %s %s\np\nr\n' $(( ${geom%,*} + ${at%,*} )) $(( ${geom#*,} + ${at#*,} )) >&3
await "$work/session.log" 'PowerDialog: chose Sleep → ok' "clicking Sleep in the power key's dialog did nothing"
await "$work/power.log" '^acpiconf' "the power key's Sleep did not run acpiconf" $((before + 1))
[ "$(grep '^acpiconf' "$work/power.log" | tail -1)" = "acpiconf -s 3 lock=locked" ] \
  || fail "the power key's Sleep: $(tail -1 "$work/power.log")"
echo "ok: 8. the power key asked (Restart, Sleep, Cancel, Shut Down); Sleep, clicked, slept the machine locked"
unlock 5

# ------------------------------------------------------------ 9. the lid
before=$(runs '^acpiconf')
[ "$(ctl lid)" = ok ] || fail "the lid: $(ctl lid)"
await "$work/power.log" '^acpiconf' "the lid did not run acpiconf" $((before + 1))
[ "$(grep '^acpiconf' "$work/power.log" | tail -1)" = "acpiconf -s 3 lock=locked" ] \
  || fail "the lid: $(tail -1 "$work/power.log")"
echo "ok: 9. the lid closed: the machine slept, the session locked first"
unlock 6

# ------------------------------------------------------------ 10. nobody to ask
"$bin/abyssctl" quit > /dev/null 2>&1 || true
await "$work/stub.log" 'stopped watching' "the session's agent did not stop watching when the session ended"
shutdowns=$(runs '^shutdown -p')
[ "$(ctl power-key)" = ok ] || fail "the power key with no session: $(ctl power-key)"
await "$work/power.log" '^shutdown -p now' "with no session to ask, the power key did not shut down" $((shutdowns + 1))
echo "ok: 10. the power key with no session to ask: shutdown -p, as the kernel would have"

grep -qF -- "$pw" "$work/session.log" "$work/stub.log" && fail "the password was written down"
echo "all green (the machine sleeps only with every session locked, whoever asks; restart and shut down are an administrator's)."
