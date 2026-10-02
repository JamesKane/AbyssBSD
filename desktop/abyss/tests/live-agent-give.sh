#!/bin/sh
# AbyssBSD Swift DE — giving an application to an agent, from its window
# (PHASE18 P18.10b).
#
# As a person does it: the Agent window's Conversation ▸ Give Application…
# lists what is running, a click gives one, and the agent can then drive it.
# Real processes: a compositor, TextEdit, abyss-jaild, the keeper, the Agent
# window, abyss-model (stub), abyss-vocab and abyss-agent. FreeBSD only;
# needs passwordless sudo. Claims:
#
#   1. Give Application… lists the running applications by their own names —
#      TextEdit among them, and not the Agent window itself;
#   2. clicking TextEdit's row gives it: the keeper says so, the window's
#      status names it, and the conversation notes it;
#   3. the agent's first save asks the person in the window (P18.11): Don't
#      Allow writes nothing and the next save asks again; Allow, and TextEdit
#      writes the file;
#   4. Give by name (a script's way) refuses an application that is not
#      running, in words, and the window says so;
#   5. a window opened on a session it was handed (as Crash Reporter opens a
#      debug one) cannot give: its Give is disabled, with why.
#
# Usage: abyss/tests/live-agent-give.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent abyss-vocab AquaDemo undertow abyssmenu; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-ag2.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u)
export XDG_RUNTIME_DIR="$W/xdg" ABYSS_RUNTIME_DIR="$W/xdg" ABYSS_CONFIG_DIR="$W/config" HOME="$W/home"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$ABYSS_CONFIG_DIR" "$HOME"
SW=1024 SH=768

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${ap:-} ${ap2:-} ${te:-} ${vp:-} ${kp:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-model serve --listen $RB" || true) $(pgrep -f "abyss-vocab serve --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in keeper.log app.log te.log; do tail -6 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }

cat > "$W/stub.json" <<'J'
[{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
  {"id":"v1","type":"function","function":{"name":"activate","arguments":"{\"app\":\"TextEdit\",\"verb\":\"file.save\"}"}}]}}],
  "usage":{"total_tokens":100}},
 {"choices":[{"index":0,"message":{"role":"assistant","content":"Saved."}}],"usage":{"total_tokens":100}}]
J
printf '[agent]\nmodel = stub:%s\n' "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"
printf 'a note\n' > "$W/note.txt"

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
env AQUA_SCENE=textedit .build/debug/AquaDemo "$W/note.txt" > "$W/te.log" 2>&1 3>&- & te=$!
await "$W/te.log" 'TextEdit: menus on ' "TextEdit did not publish its menus"
.build/debug/abyss-jail --socket "$SOCK" serve > "$W/keeper.log" 2>&1 3>&- & kp=$!
await "$W/keeper.log" '^jails: ready' "the keeper did not start"
env AQUA_SCENE=agent .build/debug/AquaDemo > "$W/app.log" 2>&1 3>&- & ap=$!
await "$W/app.log" 'Agent: session .* at ' "the Agent window got no session"
await "$W/ut.out" '^window org.abyssbsd.agent' "no Agent window on the screen"
mkfifo "$W/pointer"
"$W/vpointer" $SW $SH < "$W/pointer" > "$W/vp.log" 2>&1 & vp=$!
exec 3> "$W/pointer"
sleep 0.5
pos=$(grep '^window org.abyssbsd.agent' "$W/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)

# ---- 1. Give Application… -------------------------------------------------------
[ "$(.build/debug/abyssmenu validate agent | sed -n 's/^agent\.give-app	//p')" = enabled ] || fail "Give Application… is not enabled"
.build/debug/abyssmenu run agent agent.give-app > /dev/null 2>&1 || fail "Give Application… was refused"
await "$W/app.log" 'Agent: picker rows ' "the picker never drew its rows"
rows=$(grep 'Agent: picker rows ' "$W/app.log" | tail -1)
echo "$rows" | grep -q ' TextEdit=' || fail "the picker does not list TextEdit: $rows"
echo "$rows" | grep -q ' Agent=' && fail "the picker lists the Agent window itself: $rows"
echo "ok: 1. Give Application… listed the running applications by name — TextEdit, and not Agent itself"

# ---- 2. a click gives it ------------------------------------------------------------
at=$(echo "$rows" | tr ' ' '\n' | sed -n 's/^TextEdit=//p')
printf 'm %s %s\np\nr\n' $((${pos%,*} + ${at%,*})) $((${pos#*,} + ${at#*,})) >&3
await "$W/keeper.log" "jails: gave TextEdit (menus.textedit.$te) to agent session" "the click did not give TextEdit"
await "$W/app.log" 'Agent: gave TextEdit' "the window did not hear it was given"
echo "ok: 2. clicking TextEdit's row gave it (menus.textedit.$te), and the window knows"

# ---- 3. the agent drives it -------------------------------------------------------------
.build/debug/abyssmenu run agent agent.question "text=save my note" > /dev/null 2>&1 || fail "the question was refused"
await "$W/app.log" 'Agent: call activate' "the agent did not activate anything"
# Requester 1 (P18.11): the first save asks the person. Don't Allow first:
# nothing is written, and the next save asks again. Then Allow.
await "$W/app.log" 'Agent: requester write: TextEdit file.save' "the window did not ask before the first save"
grep -q 'TextEdit: saved' "$W/te.log" && fail "TextEdit saved before the person answered"
.build/debug/abyssmenu run agent agent.stop > /dev/null 2>&1 || fail "Don't Allow was refused"
await "$W/app.log" 'Agent: did not allow TextEdit to write' "Don't Allow did not reach the keeper"
await "$W/app.log" 'Agent: answered: stop=answered' "the question was not answered after Don't Allow"
sleep 0.3
grep -q 'TextEdit: saved' "$W/te.log" && fail "TextEdit saved after the person did not allow it"
.build/debug/abyssmenu run agent agent.question "text=save my note, please" > /dev/null 2>&1 || fail "the second question was refused"
await "$W/app.log" 'Agent: requester write: TextEdit file.save' "the next save after Don't Allow was not asked about again" 2
.build/debug/abyssmenu run agent agent.allow > /dev/null 2>&1 || fail "Allow was refused"
await "$W/app.log" 'Agent: allowed TextEdit to write' "Allow did not reach the keeper"
await "$W/te.log" "TextEdit: saved $W/note.txt" "TextEdit did not save for the agent"
await "$W/app.log" 'Agent: answered: stop=answered' "the question was not answered" 2
echo "ok: 3. the first save asked the person: Don't Allow wrote nothing and the next save asked again; Allow, and TextEdit saved"

# ---- 4. a give that cannot be -------------------------------------------------------------
.build/debug/abyssmenu run agent agent.give "app=diskutility" > /dev/null 2>&1 || fail "Give was refused outright"
await "$W/app.log" 'Agent: give refused: Not given: no running application diskutility' "the window did not say why"
echo "ok: 4. Give of an application that is not running was refused, and the window says why"

# ---- 5. a handed session cannot give ---------------------------------------------------------
sock=$(sed -n 's/^Agent: session .* at //p' "$W/app.log" | head -1)
env AQUA_SCENE=agent ABYSS_AGENT_SOCKET="$sock" .build/debug/AquaDemo > "$W/app2.log" 2>&1 3>&- & ap2=$!
await "$W/app2.log" 'Agent: session (given) at ' "the second window did not take the handed session"
await "$W/app2.log" 'Agent: menus on ' "the second window published no menus"
svc=$(sed -n 's/^Agent: menus on //p' "$W/app2.log")
st=$(.build/debug/abyssmenu validate "$svc" | sed -n 's/^agent\.give-app	//p')
[ "$st" = "disabled (this session cannot be given applications)" ] || fail "a handed session's Give Application…: $st"
echo "ok: 5. a window on a handed session cannot give: Give is disabled (this session cannot be given applications)"
echo "all green (an application given from the Agent window, and driven by the agent through its own menus)."
