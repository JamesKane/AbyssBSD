#!/bin/sh
# AbyssBSD Swift DE — the Agent window (PHASE18 P18.8b).
#
# The chat window, outside the jail, as a person uses it: a real compositor,
# abyss-jaild as root, the session's keeper, abyss-model with a stub backend,
# abyss-agent in its jail, and AquaDemo's Agent window driven by a virtual
# keyboard and pointer. FreeBSD only; needs passwordless sudo. Claims:
#
#   1. the window asks the keeper for a session and says where it runs; Ask
#      with an empty field is refused, and says why;
#   2. a question typed and sent with Return is answered: the window shows
#      each tool call as it starts — while the (slowed) model has not yet
#      answered — then the answer (the agent's log and the transcript agree);
#   3. the Ask button sends the next, and it is answered;
#   4. a script asks through the vocabulary (`abyssmenu run agent
#      agent.question text=…`), as a person does; the budget stops it and
#      asks the person (P18.11) — here they say Stop — and Ask is then
#      disabled ("there is no agent");
#   5. ⌘Q ends the session: bye, the agent exits, the keeper stops its model;
#   6. a class with no model: the window says why there is no agent.
#
# Usage: abyss/tests/live-agent-window.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent AquaDemo undertow abyssmenu; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-aw.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u) me=$(id -un)
N="abyss-$uid-agent"
export XDG_RUNTIME_DIR="$W/xdg" ABYSS_RUNTIME_DIR="$W/xdg" ABYSS_CONFIG_DIR="$W/config" HOME="$W/home"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$ABYSS_CONFIG_DIR" "$HOME"
SW=1024 SH=768

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in ${ap:-} ${vp:-} ${vk:-} ${kp:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-model serve --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in keeper.log app.log; do tail -6 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
validate() { .build/debug/abyssmenu validate agent 2>&1 | sed -n "s/^agent\.ask	//p"; }

# The stub (as live-agent.sh's): two tool calls, then an answer; 100 tokens
# a reply, a budget of 450 — so the third question is stopped by it.
cat > "$W/stub.json" <<J
[{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
  {"id":"c1","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\"/home/$me\"}"}},
  {"id":"c2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"/home/$me/notes.txt\"}"}}]}}],
  "usage":{"total_tokens":100}},
 {"choices":[{"index":0,"message":{"role":"assistant","content":"Call the plumber."}}],"usage":{"total_tokens":100}}]
J
printf '[agent]\nmodel = stub:%s\nbudget = 450\n' "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"

# Tools: the virtual pointer and keyboard.
for t in pointer keyboard; do
  xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
  [ $t = keyboard ] && xml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
  wayland-scanner client-header "$xml" "$W/v$t-proto.h"
  wayland-scanner private-code  "$xml" "$W/v$t-proto.c"
done
cc -I"$W" abyss/tests/vpointer.c "$W/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$W/vpointer" || fail "no vpointer"
cc -I"$W" abyss/tests/vkeyboard.c "$W/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$W/vkeyboard" || fail "no vkeyboard"

sudo "$W/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" > "$W/jd.log" 2>&1 3>&- 4>&- &
await "$W/jd.log" 'answering at' "the daemon did not start"
mkdir -p "$W/cfg"
env -u WAYLAND_DISPLAY .build/debug/undertow run --frames 0 --width $SW --height $SH --config-dir "$W/cfg" \
    > "$W/ut.out" 2> "$W/ut.err" 3>&- 4>&- & ut=$!
await "$W/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$W/ut.out" | cut -d= -f2-)"
# The stub takes 1.5 s a reply (inherited by abyss-model), so a tool call is
# on the screen while the answer does not exist yet.
env ABYSS_MODEL_STUB_DELAY=1500 .build/debug/abyss-jail --socket "$SOCK" serve > "$W/keeper.log" 2>&1 3>&- 4>&- & kp=$!
await "$W/keeper.log" '^jails: ready' "the keeper did not start"

# ---- 1. the window, and its session -------------------------------------------
env AQUA_SCENE=agent .build/debug/AquaDemo > "$W/app.log" 2>&1 3>&- 4>&- & ap=$!
await "$W/app.log" 'Agent: session .* at ' "the window did not get a session"
await "$W/app.log" 'Agent: layout field=' "the window never drew"
await "$W/ut.out" '^window org.abyssbsd.agent/' "no Agent window on the screen"
sock=$(sed -n 's/^Agent: session .* at //p' "$W/app.log")
case "$sock" in "$RB/$uid/agent/run/user/agent-"*.sock) ;; *) fail "the window's agent socket is not in the agent jail: $sock" ;; esac
grep -q "jails: agent session .* in $N" "$W/keeper.log" || fail "the keeper did not start the session in $N"
[ "$(validate)" = enabled ] || fail "Ask, with the agent ready: $(validate)"
.build/debug/abyssmenu run agent agent.ask > "$W/m0" 2>&1 && fail "Ask with an empty field was taken"
grep -q 'the field is empty' "$W/m0" || fail "an empty Ask does not say why: $(cat "$W/m0")"
pos=$(grep '^window org.abyssbsd.agent/' "$W/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)
wx=${pos%,*}; wy=${pos#*,}
lay=$(grep 'Agent: layout ' "$W/app.log" | tail -1)
at() { p=$(echo "$lay" | tr ' ' '\n' | sed -n "s/^$1=//p"); echo "$((wx + ${p%,*})) $((wy + ${p#*,}))"; }
echo "ok: 1. the window got a session in $N; Ask with an empty field is refused (the field is empty)"

# ---- 2. a question, typed, sent with Return ------------------------------------
mkfifo "$W/pointer" "$W/keys"
"$W/vpointer" $SW $SH < "$W/pointer" > "$W/vp.log" 2>&1 & vp=$!
exec 3> "$W/pointer"
"$W/vkeyboard" < "$W/keys" > "$W/vk.log" 2>&1 & vk=$!
exec 4> "$W/keys"
sleep 1
click() { printf 'm %s %s\np\nr\n' "$1" "$2" >&3; sleep 0.4; }
click $(at field)
printf 'mine\n' > "$HB/$me/agent/notes.txt"
printf 't what is due on monday\n' >&4
sleep 0.5
printf 'k 28\n' >&4
await "$W/app.log" 'Agent: asked: what is due on monday' "Return did not send the question"
await "$W/app.log" 'Agent: call list_directory' "the first tool call was not shown as it started"
[ "$(count 'Agent: answered' "$W/app.log")" = 0 ] || fail "the call was shown only with the answer, not while the model worked"
await "$W/app.log" 'Agent: answered: stop=answered calls=2 steps=2' "the question was not answered with the two tool calls"
t=$(ls -d "$HOME"/Library/Logs/Agents/*-agent-*)/transcript.jsonl
grep -q '"content":"what is due on monday"' "$t" || fail "the transcript does not have the question"
grep -q '"content":"mine' "$t" || fail "the tool's read of notes.txt did not go back to the model"
echo "ok: 2. typed and sent with Return: each tool call shown as it started, before the answer; the transcript agrees"

# ---- 3. the button ------------------------------------------------------------------
printf 't and tuesday\n' >&4
sleep 0.3
click $(at ask)
await "$W/app.log" 'Agent: asked: and tuesday' "the Ask button did not send the question"
await "$W/app.log" 'Agent: answered: stop=answered' "the button's question was not answered" 2
echo "ok: 3. the Ask button sent the next question, and it was answered"

# ---- 4. a script, through the vocabulary; and the budget -------------------------------
.build/debug/abyssmenu run agent agent.question "text=and wednesday" > "$W/m1" 2>&1 || fail "abyssmenu's ask was refused: $(cat "$W/m1")"
await "$W/app.log" 'Agent: asked: and wednesday' "the vocabulary's ask did not reach the agent"
await "$W/app.log" 'Agent: answered: stop=budget' "the budget did not stop the third question"
# The budget asks the person now (P18.11); this test's person says Stop.
await "$W/app.log" 'Agent: requester budget: ' "the budget did not ask the person"
.build/debug/abyssmenu run agent agent.stop > /dev/null 2>&1 || fail "Stop was refused"
await "$W/app.log" 'Agent: stopped by the person' "Stop did not end the question"
[ "$(validate)" = "disabled (there is no agent)" ] || fail "Ask after the budget: $(validate)"
.build/debug/abyssmenu run agent agent.question "text=more" > "$W/m2" 2>&1 && fail "an ask after the budget was taken"
grep -q 'there is no agent' "$W/m2" || fail "the refused ask does not say why: $(cat "$W/m2")"
echo "ok: 4. abyssmenu asked as a person does; the budget stopped it, and Ask is refused (there is no agent)"

# ---- 5. ⌘Q --------------------------------------------------------------------------
apid=$(sed -n 's/.*: agent pid \([0-9]*\),.*/\1/p' "$W/keeper.log" | head -1)
printf 'c 64 16\n' >&4
await "$W/app.log" 'Agent: bye' "⌘Q did not end the session"
await "$W/keeper.log" "jails: abyss-agent (pid $apid) in $N exited" "the agent did not exit"
await "$W/keeper.log" "jails: its model stopped" "the keeper did not stop the model"
i=0; while kill -0 "$ap" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill -0 "$ap" 2>/dev/null && fail "the window did not close"
ap=
echo "ok: 5. ⌘Q said bye; the agent exited and the keeper stopped its model"

# ---- 6. no model -----------------------------------------------------------------------
env AQUA_SCENE=agent ABYSS_AGENT_CLASS=debug .build/debug/AquaDemo > "$W/app2.log" 2>&1 3>&- 4>&- & ap=$!
await "$W/app2.log" 'Agent: refused: No agent: no model is set for debug' "the window did not say why there is no agent"
kill "$ap"; ap=
echo "ok: 6. a class with no model: the window says why there is no agent"
echo "all green (the Agent window: a session from the keeper, questions answered with their tool calls, the budget's words, ⌘Q ends it)."
