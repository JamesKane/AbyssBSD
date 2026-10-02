#!/bin/sh
# AbyssBSD Swift DE — an agent drives what it was given (PHASE18 P18.10).
#
# Real processes: a compositor, TextEdit and Grab (each publishing its menus
# as a vocabulary, Phase 10), abyss-jaild, the keeper, and an agent session:
# abyss-model (stub) and abyss-vocab outside the jail, abyss-agent inside.
# FreeBSD only; needs passwordless sudo. Claims:
#
#   1. the session has a vocabulary bridge: a socket in the jail beside the
#      model's, and its control socket outside, where the jail cannot reach;
#      the jail holds no application's own menu socket;
#   2. `abyss-jail give SESSION TextEdit` gives that running TextEdit, and the
#      transcript says so;
#   3. the agent's apps lists TextEdit; describe_app reads TextEdit's own
#      menus; activate file.save asks the person first (P18.11, requester 1):
#      a script is not the person, so it is refused and nothing is written;
#      once the person allows TextEdit (abyss-jail permit), it saves;
#   4. Grab, running but not given, is refused by name, and nothing reaches
#      it: Grab captures nothing;
#   5. giving to a session that does not exist, or an application that is not
#      running, is refused in words;
#   6. bye ends the agent, and its model and vocabulary with it.
#
# Usage: abyss/tests/live-agent-vocab.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent abyss-vocab AquaDemo undertow; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-av.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u)
N="abyss-$uid-agent"
export XDG_RUNTIME_DIR="$W/xdg" ABYSS_RUNTIME_DIR="$W/xdg" ABYSS_CONFIG_DIR="$W/config" HOME="$W/home"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$ABYSS_CONFIG_DIR" "$HOME"

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  for p in ${te:-} ${gr:-} ${kp:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-model serve --listen $RB" || true) $(pgrep -f "abyss-vocab serve --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in keeper.log te.log; do tail -6 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
toolsaid() {  # toolsaid FILE ID — a tool's result, as the model was given it
  awk -v id="$2" '{ k = "\"tool_call_id\":\"" id "\",\"content\":\""; i = index($0, k); if (i) { r = substr($0, i + length(k)); j = index(r, "\"}"); print (j ? substr(r, 1, j - 1) : substr(r, 1, 2000)) } }' "$1"
}

# The stub: everything the agent can do with the vocabulary, in one turn —
# and one thing it may not.
cat > "$W/stub.json" <<'J'
[{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
  {"id":"v1","type":"function","function":{"name":"apps","arguments":"{}"}},
  {"id":"v2","type":"function","function":{"name":"describe_app","arguments":"{\"app\":\"TextEdit\"}"}},
  {"id":"v3","type":"function","function":{"name":"activate","arguments":"{\"app\":\"TextEdit\",\"verb\":\"file.save\"}"}},
  {"id":"v4","type":"function","function":{"name":"activate","arguments":"{\"app\":\"Grab\",\"verb\":\"capture.screen\"}"}}]}}],
  "usage":{"total_tokens":100}},
 {"choices":[{"index":0,"message":{"role":"assistant","content":"Saved it."}}],"usage":{"total_tokens":100}}]
J
printf '[agent]\nmodel = stub:%s\n' "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"
printf 'a note\n' > "$W/note.txt"

sudo "$W/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" > "$W/jd.log" 2>&1 &
await "$W/jd.log" 'answering at' "the daemon did not start"
mkdir -p "$W/cfg"
env -u WAYLAND_DISPLAY .build/debug/undertow run --frames 0 --width 1024 --height 768 --config-dir "$W/cfg" \
    > "$W/ut.out" 2> "$W/ut.err" & ut=$!
await "$W/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$W/ut.out" | cut -d= -f2-)"
env ABYSS_GRAB_DUMP=1 AQUA_SCENE=grab .build/debug/AquaDemo > "$W/grab.log" 2>&1 & gr=$!
env AQUA_SCENE=textedit .build/debug/AquaDemo "$W/note.txt" > "$W/te.log" 2>&1 & te=$!
await "$W/te.log" 'TextEdit: menus on ' "TextEdit did not publish its menus"
await "$W/grab.log" 'Grab: menus on ' "Grab did not publish its menus"
.build/debug/abyss-jail --socket "$SOCK" serve > "$W/keeper.log" 2>&1 & kp=$!
await "$W/keeper.log" '^jails: ready' "the keeper did not start"

# ---- 1. a bridge, inside and out ------------------------------------------------
.build/debug/abyss-jail agent agent > "$W/a1" 2>&1 || fail "the agent session was refused: $(cat "$W/a1")"
session=$(sed -n 's/^agent \([^ ]*\) .*/\1/p' "$W/a1")
sock=$(sed -n 's/.* socket=\([^ ]*\) .*/\1/p' "$W/a1")
transcript=$(sed -n 's/.* transcript=\([^ ]*\) .*/\1/p' "$W/a1")
inside=$(ls "$RB/$uid/agent/run/user" | tr '\n' ' ')
[ "$inside" = "agent-1.sock model-1.sock vocab-1.sock " ] || fail "the agent's runtime directory: $inside"
[ -S "$transcript/vocabulary.sock" ] || fail "no control socket beside the transcript"
case "$transcript" in "$RB"*) fail "the control socket is inside the jail" ;; esac
echo "ok: 1. the session's bridge answers in the jail (vocab-1.sock); its control socket is outside; no application's menu socket is inside"

# ---- 2. give TextEdit -------------------------------------------------------------
.build/debug/abyss-jail give "$session" textedit > "$W/g1" 2>&1 || fail "give was refused: $(cat "$W/g1")"
grep -q "^gave TextEdit to $session" "$W/g1" || fail "give said: $(cat "$W/g1")"
t="$transcript/transcript.jsonl"
grep -q '"event":"given","app":"TextEdit","service":"menus.textedit.'"$te"'"' "$t" || fail "the transcript does not say TextEdit ($te) was given: $(grep vocabulary "$t")"
echo "ok: 2. TextEdit (pid $te) was given to the session, and the transcript says so"

# ---- 3 and 4. the agent drives TextEdit, and not Grab ---------------------------------
.build/debug/abyss-agent ask --listen "$sock" save my note > "$W/q1" 2>&1 || fail "the question failed: $(cat "$W/q1")"
grep '"kind":"request"' "$t" | sed -n 2p > "$W/second"
[ "$(toolsaid "$W/second" v1)" = "TextEdit" ] || fail "apps did not list TextEdit alone: $(toolsaid "$W/second" v1)"
toolsaid "$W/second" v2 | grep -q 'file.save — \\"Save\\" in File \[enabled\]' || fail "describe_app did not read TextEdit's menus: $(toolsaid "$W/second" v2 | head -c 400)"
grep -q '^permission=TextEdit file.save$' "$W/q1" || fail "the save was not asked about: $(cat "$W/q1")"
[ "$(toolsaid "$W/second" v3)" = "refused: the person did not allow TextEdit to write for you (Save)" ] || fail "activate file.save, unasked: $(toolsaid "$W/second" v3)"
sleep 0.3
grep -q 'TextEdit: saved' "$W/te.log" && fail "TextEdit saved before the person allowed it"
grep -q '"event":"asked","app":"TextEdit","verb":"file.save","title":"Save"' "$t" || fail "the transcript does not say the person was asked"
.build/debug/abyss-jail permit "$session" TextEdit yes > /dev/null || fail "permit was refused"
grep -q '"event":"permitted","app":"TextEdit"' "$t" || fail "the transcript does not say TextEdit was allowed"
.build/debug/abyss-agent ask --listen "$sock" save it now > "$W/q2" 2>&1 || fail "the second question failed: $(cat "$W/q2")"
grep -q '^permission=' "$W/q2" && fail "an allowed application was asked about again"
await "$W/te.log" "TextEdit: saved $W/note.txt" "TextEdit did not save once allowed"
echo "ok: 3. apps listed TextEdit; describe_app read its menus; file.save asked the person — refused unasked, nothing written — and saved once allowed"
[ "$(toolsaid "$W/second" v4)" = "error: Grab was not given to this session" ] || fail "Grab was not refused by name: $(toolsaid "$W/second" v4)"
sleep 0.5
grep -q 'Grab: captured' "$W/grab.log" && fail "Grab captured: the refusal reached it"
grep -q '"event":"refused","app":"Grab","reason":"not given"' "$t" || fail "the refusal is not in the transcript"
echo "ok: 4. Grab, running but not given, was refused by name; it captured nothing, and the transcript says so"

# ---- 5. gives that cannot be ------------------------------------------------------------
.build/debug/abyss-jail give no-such-session textedit > "$W/g2" 2>&1 && fail "a give to no session was taken"
grep -q 'there is no agent session no-such-session with a vocabulary' "$W/g2" || fail "the refusal does not say why: $(cat "$W/g2")"
.build/debug/abyss-jail give "$session" diskutility > "$W/g3" 2>&1 && fail "a give of an application that is not running was taken"
grep -q 'no running application diskutility' "$W/g3" || fail "the refusal does not say why: $(cat "$W/g3")"
echo "ok: 5. a give to no session, or of an application not running, is refused in words"

# ---- 6. bye --------------------------------------------------------------------------------
.build/debug/abyss-agent bye --listen "$sock" > /dev/null
await "$W/keeper.log" 'jails: its model stopped' "the model did not stop"
await "$W/keeper.log" 'jails: its vocabulary stopped' "the vocabulary bridge did not stop"
pgrep -f "abyss-vocab serve --listen $RB" > /dev/null && fail "abyss-vocab outlived the agent"
echo "ok: 6. bye ended the agent, and its model and vocabulary with it"
echo "all green (an agent drives what it was given, by its menus, and nothing else)."
