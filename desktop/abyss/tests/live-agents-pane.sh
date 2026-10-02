#!/bin/sh
# AbyssBSD Swift DE — the Agents pane (PHASE18 P18.11b).
#
# Real processes: a compositor, abyss-jaild, the keeper, an agent session
# (abyss-model stub, abyss-vocab, abyss-agent) asked one question, a program
# launched confined with a document (a grant), and System Preferences on the
# Agents pane, driven by a virtual pointer. FreeBSD only; needs sudo. Claims:
#
#   1. the pane lists the session from its transcript on disk, and the grant
#      the keeper reports, by jail and number;
#   2. clicking the session shows it in sentences: what was asked and what the
#      agent answered;
#   3. Revoke (clicked, on the second of two) takes that grant back: the
#      keeper and jaild say so, the file is no longer mounted in the jail, the
#      other grant stays, and the pane re-reads and says it.
#
# Usage: abyss/tests/live-agents-pane.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent abyss-vocab AquaDemo undertow abyssmenu; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-ap.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u)
APP="abyss-$uid-app"
export XDG_RUNTIME_DIR="$W/xdg" ABYSS_RUNTIME_DIR="$W/xdg" ABYSS_CONFIG_DIR="$W/config" HOME="$W/home"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$ABYSS_CONFIG_DIR" "$HOME"
SW=1024 SH=768

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${pp:-} ${vp:-} ${kp:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-model serve --listen $RB" || true) $(pgrep -f "abyss-vocab serve --listen $RB" || true) $(pgrep -f "endpoint --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in keeper.log prefs.log; do tail -6 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
grantmounts() { mount | grep -F " on $RB/$uid/app/run/granted/" | grep -c . || true; }

cat > "$W/stub.json" <<'J'
[{"choices":[{"index":0,"message":{"role":"assistant","content":"The plumber, on Monday."}}],"usage":{"total_tokens":42}}]
J
printf '[agent]\nmodel = stub:%s\n' "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"
printf 'a document\n' > "$W/doc.txt"; printf 'another\n' > "$W/other.txt"

xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$W/vpointer-proto.h"; wayland-scanner private-code "$xml" "$W/vpointer-proto.c"
cc -I"$W" abyss/tests/vpointer.c "$W/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$W/vpointer" || fail "no vpointer"

sudo "$W/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" > "$W/jd.log" 2>&1 3>&- &
await "$W/jd.log" 'answering at' "the daemon did not start"
mkdir -p "$W/cfg"
env -u WAYLAND_DISPLAY .build/debug/undertow run --frames 0 --width $SW --height $SH --config-dir "$W/cfg" \
    > "$W/ut.out" 2> "$W/ut.err" 3>&- & ut=$!
await "$W/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$W/ut.out" | cut -d= -f2-)"
.build/debug/abyss-jail --socket "$SOCK" serve > "$W/keeper.log" 2>&1 3>&- & kp=$!
await "$W/keeper.log" '^jails: ready' "the keeper did not start"

# A session with a transcript, and a grant.
.build/debug/abyss-jail agent agent > "$W/a1" 2>&1 || fail "no agent session: $(cat "$W/a1")"
session=$(sed -n 's/^agent \([^ ]*\) .*/\1/p' "$W/a1"); sock=$(sed -n 's/.* socket=\([^ ]*\) .*/\1/p' "$W/a1")
.build/debug/abyss-agent ask --listen "$sock" what is due on monday > /dev/null 2>&1 || fail "the question failed"
.build/debug/abyss-jail launch app -- /bin/cat "$W/doc.txt" "$W/other.txt" > /dev/null 2>&1 || fail "the launch with documents was refused"
await "$W/keeper.log" "jails: $W/other.txt is /run/granted/2/other.txt in $APP" "the documents were not granted"
[ "$(grantmounts)" = 2 ] || fail "the grants are not mounted: $(grantmounts)"

# System Preferences on the Agents pane.
env ABYSS_PREFS_DUMP=1 AQUA_SCENE=sysprefs .build/debug/AquaDemo > "$W/prefs.log" 2>&1 3>&- & pp=$!
await "$W/ut.out" '^window org.abyssbsd.preferences' "no System Preferences window"
i=0; until .build/debug/abyssmenu run systempreferences view.pane.agents > /dev/null 2>&1 || [ $i -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
await "$W/prefs.log" 'agents layout ' "the Agents pane did not draw"
mkfifo "$W/pointer"
"$W/vpointer" $SW $SH < "$W/pointer" > "$W/vp.log" 2>&1 & vp=$!
exec 3> "$W/pointer"
sleep 0.5
pos=$(grep '^window org.abyssbsd.preferences' "$W/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)
lay=$(grep 'agents layout ' "$W/prefs.log" | tail -1)
at() { p=$(echo "$lay" | tr ' ' '\n' | sed -n "s/^$1=//p"); echo "$((${pos%,*} + ${p%,*})) $((${pos#*,} + ${p#*,}))"; }
click() { printf 'm %s %s\np\nr\n' $1 $2 >&3; sleep 0.5; }

# ---- 1. what is listed ------------------------------------------------------------
grep -q "agents: 1 session(s); grants: $APP.1 $APP.2\$" "$W/prefs.log" || fail "the pane read: $(grep 'agents: ' "$W/prefs.log" | tail -1)"
echo "$lay" | grep -q " session.$session=" || fail "the session is not a row: $lay"
echo "$lay" | grep -q " revoke.$APP.1=" && echo "$lay" | grep -q " revoke.$APP.2=" || fail "the grants have no Revoke: $lay"
echo "ok: 1. the pane lists the session ($session) from disk, and $APP's grants 1 and 2 from the keeper"

# ---- 2. the session, in sentences ----------------------------------------------------
click $(at "session.$session")
await "$W/prefs.log" "agents: showing $session" "clicking the session did not show it"
grep "agents: showing $session" "$W/prefs.log" | tail -1 | grep -q 'You asked: what is due on monday | The agent answered: The plumber, on Monday.' \
    || fail "the digest does not say what was asked and answered: $(grep "agents: showing" "$W/prefs.log" | tail -1)"
echo "ok: 2. clicking the session shows it (its digest: what was asked, what the agent answered)"

# ---- 3. Revoke --------------------------------------------------------------------------
# The second row's Revoke: that grant goes, and the first stays.
click $(at "revoke.$APP.2")
await "$W/keeper.log" "jails: revoked grant 2 in $APP" "Revoke did not reach the keeper, for grant 2"
await "$W/prefs.log" "agents: Revoked: $W/other.txt is no longer in $APP." "the pane did not say it was revoked"
await "$W/prefs.log" "agents: 1 session(s); grants: $APP.1\$" "the pane did not re-read the grants"
left=$(.build/debug/abyss-jail --socket "$SOCK" grants "$APP")
echo "$left" | grep -q 'other.txt' && fail "jaild still lists the revoked grant: $left"
echo "$left" | grep -q 'doc.txt' || fail "the other grant went too: $left"
[ "$(grantmounts)" = 1 ] || fail "mounted after revoking one of two: $(grantmounts)"
echo "ok: 3. Revoke (on grant 2's row) took that grant back — the keeper and jaild say so, it is unmounted — the other stays, and the pane re-read"
echo "all green (the Agents pane: what agents did, and what was given, with Revoke)."
