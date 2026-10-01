#!/bin/sh
# AbyssBSD Swift DE — fast user switching (PHASE16 P16.6b).
#
# The daemon's own loop (`abyss-loginstub --greeter`) running real sessions —
# anchor, undertow, the login window, each person's lock screen and agent —
# with two names, ada and bob, both played by this test's account
# (`--sessions-as-self`: each in its own runtime directory, under its own
# name; that each runs as *their own* uid is live-authenticator.sh's, as
# root). The console's VT switch is a stand-in that records. Claims:
#
#   1. ada logs in at the window: her session starts on VT 10;
#   2. "Login Window…" (switch-user) from ada's session **locks it first**,
#      then the window comes forward (VT 9) — and her session keeps running;
#   3. bob logs in: his session starts on VT 11, beside hers — two sessions,
#      two runtime directories, both running;
#   4. bob switches too; at the window ada is shown as logged in, and
#      choosing her goes straight back to her session (VT 10) — no password
#      at the window — still locked: her own lock screen asks, and her
#      password opens it;
#   5. bob logs out from behind: his session ends, ada's stays in front, and
#      no login window is started over her;
#   6. a switch from a session whose agent cannot lock it is refused, and
#      nothing moves.
#
# Usage: abyss/tests/live-switchuser.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

bin="$root/.build/debug"
for b in undertow AquaDemo abyss-loginstub abyss-loginctl anchor abyssctl abyss-idle; do [ -x "$bin/$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-fus.XXXXXX)
rt="$work/run"; mkdir -p "$rt"
cleanup() {
  exec 4>&- 2>/dev/null || true
  for p in ${vk:-} ${st:-}; do kill "$p" 2>/dev/null || true; done
  for f in "$work"/session.*.pid; do [ -s "$f" ] && kill "$(cat "$f")" 2>/dev/null || true; done
  sleep 0.3; rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^sessions|^loginwindow' "$work/stub.log" 2>/dev/null | tail -6 | sed 's/^/  daemon| /'
         sed 's/^/  vt| /' "$work/vt.log" 2>/dev/null | tail -3
         exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES] [TENTHS]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt "${5:-150}" ]; do i=$((i + 1)); sleep 0.1; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
vts() { tr '\n' ' ' < "$work/vt.log" | sed 's/ $//'; }
lockof() { ABYSS_RUNTIME_DIR="$rt/abyss-$1" "$bin/abyssctl" status 2>/dev/null | sed -n 's/^lock: //p'; }

wayland-scanner client-header "$root/abyss/tests/virtual-keyboard-unstable-v1.xml" "$work/vkeyboard-proto.h"
wayland-scanner private-code  "$root/abyss/tests/virtual-keyboard-unstable-v1.xml" "$work/vkeyboard-proto.c"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"

# The test's abyss-session: the real anchor, a socket per person, and a record.
cat > "$work/abyss-session" <<EOF
#!/bin/sh
who=\$USER; [ "\$ABYSS_SESSION_MODE" = greeter ] && who=greeter
echo \$\$ > "$work/session.\$who.pid"
echo "\$ABYSS_SESSION_MODE \$USER run=\$ABYSS_RUNTIME_DIR" >> "$work/record"
sock=abyss-\$who-$$
if [ "\$ABYSS_SESSION_MODE" = greeter ]; then without=""; else
  without="--without bus --without portal --without bridge --without menus --without dock --without menubar"; fi
exec "$bin/anchor" --mode "\$ABYSS_SESSION_MODE" --runtime-dir "\$ABYSS_RUNTIME_DIR" --binary "$bin/AquaDemo" \\
  --compositor "$bin/undertow run --hz 60 --frames 0 --width 800 --height 600 --socket \$sock --config-dir $work/cfg" \\
  --display "\$sock" \$without
EOF
chmod 755 "$work/abyss-session"
printf '#!/bin/sh\necho "$1" >> "%s/vt.log"\n' "$work" > "$work/vt"; chmod 755 "$work/vt"; : > "$work/vt.log"
mkdir -p "$work/cfg"; printf '[energy]\ndisplay_sleep_minutes = 0\nsystem_sleep_minutes = 0\nrequire_password = true\n' > "$work/cfg/energy.ini"

pw="fus-sesame-$$"
printf '%s\n' "$pw" > "$work/pw"
"$bin/abyss-loginstub" --socket "$work/auth.sock" --password-file "$work/pw" --greeter-uid "$(id -u)" \
    --greeter --greeter-user "$(id -un)" --sessions-as-self --vt-command "$work/vt" --lock-timeout 2 \
    --session-command "$work/abyss-session" --session-log-dir "$work" --runtime-root "$rt" \
    --session-path "$bin:/usr/local/bin:/usr/bin:/bin" \
    --session-env "ABYSS_LOGINWINDOW_ACCOUNTS=ada:Ada Lovelace:2001,bob:Bob Smith:2002" \
    --session-env "ABYSS_CONFIG_DIR=$work/cfg" > "$work/stub.log" 2>&1 & st=$!
ctl() { "$bin/abyss-loginctl" --socket "$work/auth.sock" "$@" 2>&1 || true; }

# Type into whichever compositor is in front: SOCKET, then lines on stdin.
kbd() {
  exec 4>&- 2>/dev/null || true; [ -n "${vk:-}" ] && kill "$vk" 2>/dev/null; vk=""
  rm -f "$work/vk"; mkfifo "$work/vk"; : > "$work/vk.log"
  WAYLAND_DISPLAY="$1" "$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
  await "$work/vk.log" ready "vkeyboard never bound to $1"; sleep 0.4
}
greeterlog() { echo "$work/abyss-session-$(id -un).log"; }

# ------------------------------------------------------------ 1. ada logs in
await "$work/stub.log" "sessions: the login window is up" "the daemon did not start the login window"
await "$(greeterlog)" 'LoginWindow: layout' "the login window never drew"
kbd "$rt/abyss-$(id -un)/abyss-greeter-$$"
printf 'k 28\n' >&4                                            # Return: ada, the first
await "$(greeterlog)" "LoginWindow: chose ada" "Return did not choose ada"
sleep 0.3; printf 't %s\nk 28\n' "$pw" >&4
await "$work/stub.log" "sessions: ada's session started on VT 10" "ada's session did not start on VT 10"
await "$work/abyss-session-ada.log" 'abyss-idle: watching for the machine' "ada's agent never watched"
echo "ok: 1. ada logged in: her session on VT 10 (VTs so far: $(vts))"

# ------------------------------------------------------------ 2. Login Window… from ada
[ "$(ctl switch-user)" = ok ] || fail "ada's switch: $(ctl switch-user)"
[ "$(lockof ada)" = locked ] || fail "ada's session is '$(lockof ada)' with the login window showing"
await "$work/stub.log" "the login window, to the front\|the login window is up, as" "the login window did not come forward" 2
grep -q "^desktop ada " "$work/record" && kill -0 "$(cat "$work/session.ada.pid")" || fail "ada's session stopped"
echo "ok: 2. Login Window…: ada's session locked first, then the window (VTs: $(vts)) — hers still running"

# ------------------------------------------------------------ 3. bob, beside her
await "$(greeterlog)" 'LoginWindow: logged in: ada' "the window does not know ada is logged in"
kbd "$rt/abyss-$(id -un)/abyss-greeter-$$"
printf 'k 108\nk 28\n' >&4                                      # Down, Return: bob
await "$(greeterlog)" "LoginWindow: chose bob" "Down and Return did not choose bob"
sleep 0.3; printf 't %s\nk 28\n' "$pw" >&4
await "$work/stub.log" "sessions: bob's session started on VT 11 — 2 sessions" "bob's session did not start beside ada's"
kill -0 "$(cat "$work/session.ada.pid")" && kill -0 "$(cat "$work/session.bob.pid")" || fail "both sessions should be running"
[ -d "$rt/abyss-ada" ] && [ -d "$rt/abyss-bob" ] || fail "two sessions, but not two runtime directories"
echo "ok: 3. bob logged in: VT 11, beside ada's — two sessions, two runtime directories"

# ------------------------------------------------------------ 4. back to ada, no password here
await "$work/abyss-session-bob.log" 'abyss-idle: watching for the machine' "bob's agent never watched"
[ "$(ctl switch-user)" = ok ] || fail "bob's switch: $(ctl switch-user)"
[ "$(lockof bob)" = locked ] || fail "bob's session is '$(lockof bob)' behind the window"
await "$(greeterlog)" 'LoginWindow: logged in: ada bob' "the window does not show both logged in"
kbd "$rt/abyss-$(id -un)/abyss-greeter-$$"
asked=$(count "loginwindow: login " "$work/stub.log")
printf 'k 28\n' >&4                                            # ada, the first
await "$(greeterlog)" "LoginWindow: back to ada's session" "choosing ada did not go back to her session"
await "$work/stub.log" "back to ada's session (VT 10)" "the daemon did not bring ada's VT forward"
[ "$(count "loginwindow: login " "$work/stub.log")" = "$asked" ] || fail "the window asked for a password to go back"
[ "$(lockof ada)" = locked ] || fail "back in ada's session, it is '$(lockof ada)' — it should still be locked"
kbd "$rt/abyss-ada/abyss-ada-$$"
printf 't %s\nk 28\n' "$pw" >&4
await "$work/abyss-session-ada.log" 'the lock screen unlocked the session' "ada's password did not open her session"
echo "ok: 4. ada chosen at the window: back to her session with no password there; her own lock screen asked, and opened"

# ------------------------------------------------------------ 5. bob logs out from behind
ABYSS_RUNTIME_DIR="$rt/abyss-bob" "$bin/abyssctl" quit > /dev/null 2>&1 || fail "bob's session could not be quit"
await "$work/stub.log" "sessions: bob logged out — 1 session(s) still running" "bob's log out was not seen"
sleep 0.5
[ "$(grep -c '^greeter ' "$work/record")" = 3 ] || fail "a login window was started over ada after bob left ($(grep -c '^greeter ' "$work/record"))"
kill -0 "$(cat "$work/session.ada.pid")" || fail "ada's session went when bob's did"
echo "ok: 5. bob logged out from behind: ada's session stays in front, no login window over her"

# ------------------------------------------------------------ 6. nobody to lock it
# Killing the agent is no test: anchor starts another at once. Stopped, it is
# there and cannot answer — the case that must not become "nobody objected".
agent=$(pgrep -P "$(cat "$work/session.ada.pid")" -f abyss-idle | head -1 || true)
[ -n "$agent" ] || fail "cannot find ada's agent"
kill -STOP "$agent"
before=$(wc -l < "$work/vt.log")
got=$(ctl switch-user)
case "$got" in "refused: not switched"*) ;; *) fail "a switch with no agent to lock: $got" ;; esac
[ "$(wc -l < "$work/vt.log")" = "$before" ] || fail "the VT moved although the switch was refused"
kill -CONT "$agent"
echo "ok: 6. with the session's agent unable to lock it, the switch is refused and nothing moves"

[ "$(vts)" = "9 10 9 11 9 10" ] || fail "the VT switches: $(vts)"
for f in stub.log record "$(basename "$(greeterlog)")" abyss-session-ada.log abyss-session-bob.log; do
  grep -qF -- "$pw" "$work/$f" 2>/dev/null && fail "$f contains the password"
done
echo "all green (two people's sessions side by side; each locked behind the window, and only their own lock screen opens it)."
