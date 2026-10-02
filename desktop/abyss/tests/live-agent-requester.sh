#!/bin/sh
# AbyssBSD Swift DE — the budget requester, and taking a give back (PHASE18 P18.11a).
#
# Real processes: a compositor, TextEdit, abyss-jaild, the keeper, the Agent
# window, abyss-model (stub; 100 tokens a reply, a budget of 250), abyss-vocab
# and abyss-agent. The stub's tool call is TextEdit's file.save. FreeBSD only;
# needs passwordless sudo. Claims:
#
#   1. given TextEdit, the agent saves through it, once the person allowed
#      the first write (requester 1);
#   2. Take Back: TextEdit is taken back — the transcript says so — and the
#      agent's next save is refused by name; TextEdit does not save again;
#   3. that question crosses the budget: the window puts up the requester, in
#      abyss-model's words, and the agent waits;
#   4. Allow More (clicked) raises the budget through the keeper — the
#      transcript says "raised" — and the agent carries on with the same
#      question, not asked again, to its answer;
#   5. the next question crosses the raised budget, and Stop ends it: the
#      window says why, and Ask is refused (there is no agent).
#
# Usage: abyss/tests/live-agent-requester.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent abyss-vocab AquaDemo undertow abyssmenu; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-rq.XXXXXX); chmod 755 "$W"
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
  for p in ${ap:-} ${te:-} ${vp:-} ${kp:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-model serve --listen $RB" || true) $(pgrep -f "abyss-vocab serve --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in keeper.log app.log; do tail -6 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
menu() { .build/debug/abyssmenu run agent "$@" > /dev/null 2>&1; }
state() { .build/debug/abyssmenu validate agent | sed -n "s/^$1	//p"; }

cat > "$W/stub.json" <<'J'
[{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
  {"id":"v1","type":"function","function":{"name":"activate","arguments":"{\"app\":\"TextEdit\",\"verb\":\"file.save\"}"}}]}}],
  "usage":{"total_tokens":100}},
 {"choices":[{"index":0,"message":{"role":"assistant","content":"Done."}}],"usage":{"total_tokens":100}}]
J
printf '[agent]\nmodel = stub:%s\nbudget = 250\n' "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"
: > "$ABYSS_CONFIG_DIR/agents.ini"   # agents on (P18.13): off is this file, absent
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
t=$(ls -d "$HOME"/Library/Logs/Agents/*-agent-*)/transcript.jsonl

# ---- 1. given, it saves -------------------------------------------------------------
menu agent.give "app=textedit" || fail "Give was refused"
await "$W/app.log" 'Agent: gave TextEdit' "TextEdit was not given"
menu agent.question "text=save it" || fail "the first question was refused"
await "$W/app.log" 'Agent: requester write: TextEdit file.save' "the first save was not asked about"
menu agent.allow || fail "Allow (write) was refused"
await "$W/app.log" 'Agent: answered: stop=answered' "the first question was not answered"
[ "$(count "TextEdit: saved $W/note.txt" "$W/te.log")" = 1 ] || fail "TextEdit did not save once for the agent"
echo "ok: 1. given TextEdit, the agent saved through it"

# ---- 2. Take Back ----------------------------------------------------------------------
[ "$(state agent.take-app)" = enabled ] || fail "Take Back Application… with TextEdit given: $(state agent.take-app)"
menu agent.take "app=TextEdit" || fail "Take Back was refused"
await "$W/app.log" 'Agent: took TextEdit back' "TextEdit was not taken back"
grep -q '"event":"taken","app":"TextEdit"' "$t" || fail "the transcript does not say TextEdit was taken back"
[ "$(state agent.take-app)" = "disabled (nothing was given)" ] || fail "Take Back with nothing given: $(state agent.take-app)"

# ---- 3. the next question: refused by name, then the budget -----------------------------
menu agent.question "text=save it again" || fail "the second question was refused"
await "$W/app.log" 'Agent: requester budget: the session.s budget of 250 tokens is spent (300 used)' "the window did not put up the budget requester"
grep -q '"event":"refused","app":"TextEdit","reason":"not given"' "$t" || fail "the taken-back save was not refused by name"
[ "$(count "TextEdit: saved" "$W/te.log")" = 1 ] || fail "TextEdit saved again after it was taken back"
echo "ok: 2. Take Back: TextEdit taken back (in the transcript); the agent's next save was refused by name, and TextEdit did not save"
[ "$(state agent.allow)" = enabled ] && [ "$(state agent.ask)" = "disabled (the agent is answering)" ] \
    || fail "while asking: allow=$(state agent.allow) ask=$(state agent.ask)"
echo "ok: 3. the question crossed the budget: the requester is up, in abyss-model's words, and the agent waits"

# ---- 4. Allow More, clicked -----------------------------------------------------------------
await "$W/app.log" 'Agent: requester stop=.* allow=' "the requester never drew its buttons"
b=$(grep 'Agent: requester stop=' "$W/app.log" | tail -1 | tr ' ' '\n' | sed -n 's/^allow=//p')
printf 'm %s %s\np\nr\n' $((${pos%,*} + ${b%,*})) $((${pos#*,} + ${b#*,})) >&3
await "$W/keeper.log" 'jails: agent session .* may use 250 more tokens (budget 500)' "Allow More did not raise the budget"
await "$W/app.log" 'Agent: continued' "the agent did not carry on"
await "$W/app.log" 'Agent: answered: stop=answered' "the question was not finished" 2
grep -q '"kind":"raised","budget":500,"by":250' "$t" || fail "the transcript does not say the budget was raised"
last=$(grep '"kind":"request"' "$t" | tail -1)
[ "$(echo "$last" | grep -o '"role":"user"' | wc -l | tr -d ' ')" = 2 ] || fail "the question was asked again on carrying on: $(echo "$last" | grep -o '"role":"user","content":"[^"]*"')"
echo "ok: 4. Allow More (clicked) raised the budget to 500 — in the transcript — and the agent finished the same question"

# ---- 5. Stop ------------------------------------------------------------------------------------
menu agent.question "text=once more" || fail "the third question was refused"
await "$W/app.log" 'Agent: requester budget: the session.s budget of 500 tokens is spent' "the raised budget did not stop the third question"
menu agent.stop || fail "Stop was refused"
await "$W/app.log" 'Agent: stopped by the person' "Stop did not end the question"
.build/debug/abyssmenu run agent agent.question "text=again" > "$W/m" 2>&1 && fail "a question after Stop was taken"
grep -q 'there is no agent' "$W/m" || fail "Ask after Stop: $(cat "$W/m")"
echo "ok: 5. the raised budget stopped the next question; Stop ended it, and Ask is refused (there is no agent)"
echo "all green (the budget asks the person, Allow carries on, Stop stops; a give taken back is refused)."
