#!/bin/sh
# AbyssBSD Swift DE — from the login window to a session and back (PHASE16
# P16.5b).
#
# The daemon's own loop (`abyss-loginstub --greeter`: the real LoginService
# and SessionManager, PAM replaced by a password file) runs the sessions with
# this test's `abyss-session` — the real anchor, in the mode the daemon asks
# for: `greeter` (undertow and the Aqua login window) or `desktop`. This
# account stands in for `_loginwindow` and for whoever logs in, so it all runs
# unprivileged; that each runs as *its* account is live-authenticator.sh's
# (root, in the guest). Claims:
#
#   1. at start, the daemon runs the login window: anchor in greeter mode,
#      the login window and nothing else of a desktop;
#   2. typed into, the right password ends the greeter and starts the
#      person's session — in their runtime directory, owned by them;
#   3. Log Out (`abyssctl quit` in their session) brings the login window back;
#   4. the login window killed: the daemon starts it again;
#   5. no password in anything written.
#
# Usage: abyss/tests/live-greeter.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

bin="$root/.build/debug"
for b in undertow AquaDemo abyss-loginstub anchor abyssctl abyss-idle; do [ -x "$bin/$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-grt.XXXXXX)
me=$(id -un)
rt="$work/run"; mkdir -p "$rt"
run="$rt/abyss-$me"                     # what the daemon makes for this account
cleanup() {
  exec 4>&- 2>/dev/null || true
  for p in ${vk:-} ${st:-}; do kill "$p" 2>/dev/null || true; done
  # The sessions are the daemon's children; ended with it, or by hand here.
  for f in "$work"/session.*.pid; do [ -s "$f" ] && kill "$(cat "$f")" 2>/dev/null || true; done
  sleep 0.3
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^loginwindow|^sessions' "$work/stub.log" 2>/dev/null | tail -5 | sed 's/^/  daemon| /'
         grep -E 'anchor:|LoginWindow' "$work/abyss-session-$me.log" 2>/dev/null | tail -5 | sed 's/^/  session| /'
         exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES] [TENTHS]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt "${5:-150}" ]; do i=$((i + 1)); sleep 0.1; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}

wayland-scanner client-header "$root/abyss/tests/virtual-keyboard-unstable-v1.xml" "$work/vkeyboard-proto.h"
wayland-scanner private-code  "$root/abyss/tests/virtual-keyboard-unstable-v1.xml" "$work/vkeyboard-proto.c"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"

# This test's abyss-session: what the medium's does (abyss/mk/live-image.sh),
# headless and small — and a line in the record saying who it runs as, where.
cat > "$work/abyss-session" <<EOF
#!/bin/sh
echo \$\$ > "$work/session.\$ABYSS_SESSION_MODE.pid"
echo "\$ABYSS_SESSION_MODE \$(id -un) uid=\$(id -u) run=\$ABYSS_RUNTIME_DIR owner=\$(ls -ld "\$ABYSS_RUNTIME_DIR" | awk '{print \$3}') mode=\$(ls -ld "\$ABYSS_RUNTIME_DIR" | cut -c1-10)" >> "$work/record"
sock=abyss-\$ABYSS_SESSION_MODE-$$
if [ "\$ABYSS_SESSION_MODE" = greeter ]; then without=""; else
  without="--without bus --without portal --without bridge --without menus --without dock --without menubar"; fi
exec "$bin/anchor" --mode "\$ABYSS_SESSION_MODE" --runtime-dir "\$ABYSS_RUNTIME_DIR" --binary "$bin/AquaDemo" \\
  --compositor "$bin/undertow run --hz 60 --frames 0 --width 800 --height 600 --socket \$sock --config-dir $work" \\
  --display "\$sock" \$without
EOF
chmod 755 "$work/abyss-session"

pw="greeter-sesame-$$"
printf '%s\n' "$pw" > "$work/pw"
"$bin/abyss-loginstub" --socket "$work/auth.sock" --password-file "$work/pw" --greeter-uid "$(id -u)" \
    --greeter --greeter-user "$me" --session-command "$work/abyss-session" --session-log-dir "$work" \
    --runtime-root "$rt" --session-path "$bin:/usr/local/bin:/usr/bin:/bin" \
    --session-env "ABYSS_LOGINWINDOW_ACCOUNTS=$me:Test Account:$(id -u)" \
    --session-env "ABYSS_CONFIG_DIR=$work/cfg" > "$work/stub.log" 2>&1 & st=$!

# ------------------------------------------------------------ 1. the login window
await "$work/stub.log" "sessions: the login window is up, as $me" "the daemon did not start the login window"
await "$work/record" "^greeter $me " "the greeter session never ran"
await "$work/abyss-session-$me.log" 'LoginWindow: layout' "the login window never drew"
grep -q 'anchor: loginwindow up' "$work/abyss-session-$me.log" || fail "the greeter session did not run the login window"
for c in menubar dock desktop idle bus; do
  grep -q "anchor: $c up" "$work/abyss-session-$me.log" && fail "the greeter session started a $c"
done
echo "ok: 1. the daemon ran the login window: anchor in greeter mode, the window and nothing else"

# ------------------------------------------------------------ 2. log in
mkfifo "$work/vk"
WAYLAND_DISPLAY="$run/abyss-greeter-$$" "$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound to the login window's compositor"
sleep 0.5
printf 'k 28\n' >&4                                         # Return: the highlighted account
await "$work/abyss-session-$me.log" "LoginWindow: chose $me" "Return did not choose the account"
sleep 0.3; printf 't %s\nk 28\n' "$pw" >&4
await "$work/stub.log" "login $me: accepted" "the right password was not accepted"
exec 4>&-; vk=""
await "$work/stub.log" "sessions: ending the login window — $me logged in" "the greeter was not ended"
await "$work/stub.log" "sessions: $me's session started" "the person's session was not started"
await "$work/record" "^desktop $me " "the person's session never ran"
line=$(grep "^desktop $me " "$work/record" | tail -1)
case "$line" in *"run=$run owner=$me mode=drwx------"*) ;; *) fail "the session's runtime directory: $line" ;; esac
await "$work/abyss-session-$me.log" 'anchor: desktop up' "the person's desktop did not come up"
echo "ok: 2. the right password ended the login window and started the session — $run, $me's, 0700"

# ------------------------------------------------------------ 3. Log Out
await "$work/abyss-session-$me.log" 'anchor: session is live' "the person's session never went live" 2
ABYSS_RUNTIME_DIR="$run" "$bin/abyssctl" quit > /dev/null 2>&1 || fail "abyssctl quit could not reach the session"
await "$work/stub.log" "sessions: $me logged out" "Log Out was not seen"
await "$work/stub.log" "sessions: the login window again" "Log Out did not bring the login window back"
await "$work/record" "^greeter $me " "the login window did not run again" 2
await "$work/abyss-session-$me.log" 'LoginWindow: layout' "the login window did not draw again" 2
echo "ok: 3. Log Out brought the login window back"

# ------------------------------------------------------------ 4. the window dies
await "$work/session.greeter.pid" . "the greeter's pid was not recorded"
kill -KILL "$(cat "$work/session.greeter.pid")"
await "$work/stub.log" "sessions: the login window ended — starting it again" "the daemon did not start the login window again"
await "$work/record" "^greeter $me " "the login window did not run a third time" 3
echo "ok: 4. the login window killed: the daemon started it again"

for f in stub.log "abyss-session-$me.log" record; do grep -qF -- "$pw" "$work/$f" && fail "$f contains the password"; done
echo "ok: 5. the password is in nothing written"
echo "all green (the login window, a session for whoever logs in, and the window again when they log out)."
