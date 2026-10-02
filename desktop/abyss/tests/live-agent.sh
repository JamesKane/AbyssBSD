#!/bin/sh
# AbyssBSD Swift DE — an agent in its jail (PHASE18 P18.8).
#
# Real processes: abyss-jaild as root, the session's keeper, abyss-model
# outside the jail with a stub backend, abyss-agent inside. FreeBSD only;
# needs passwordless sudo. Claims:
#
#   1. `abyss-jail agent agent` starts a session: the agent runs in the
#      agent class's jail, which has no address, and whose runtime directory
#      holds the session's two sockets and nothing else (no display, no bus);
#   2. a question runs the loop — the stub's tool calls are carried out in
#      the jail, and their results go back to the model: the jail's home is
#      listed, and a host file is not there to read;
#   3. the transcript is outside the jail, 0600 in 0700, under
#      ~/Library/Logs/Agents, and holds what the tools returned;
#   4. the budget stops the next call: the agent says why, and exits 3;
#   5. `bye` ends the agent, and the keeper stops its model with it;
#   6. a class with no model, and a class that is not an agent's, are refused
#      in words.
#
# Usage: abyss/tests/live-agent.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-ag.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u) me=$(id -un)
N="abyss-$uid-agent"
export XDG_RUNTIME_DIR="$W/xdg" ABYSS_CONFIG_DIR="$W/config" HOME="$W/home"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$ABYSS_CONFIG_DIR" "$HOME"

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  for p in ${kp:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-model serve --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in jd.log keeper.log; do tail -5 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }

# The stub: two tool calls (the jail's home, and a file that is only on the
# host), then an answer. 100 tokens each; the budget is 250.
printf 'TOPSECRET\n' > "$W/secret.txt"
cat > "$W/stub.json" <<J
[{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
  {"id":"c1","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\"/home/$me\"}"}},
  {"id":"c2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"$W/secret.txt\"}"}}]}}],
  "usage":{"total_tokens":100}},
 {"choices":[{"index":0,"message":{"role":"assistant","content":"done looking"}}],"usage":{"total_tokens":100}}]
J
printf '[agent]\nmodel = stub:%s\nbudget = 250\n' "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"

sudo "$W/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" > "$W/jd.log" 2>&1 &
await "$W/jd.log" 'answering at' "the daemon did not start"
env -u WAYLAND_DISPLAY .build/debug/abyss-jail --socket "$SOCK" serve > "$W/keeper.log" 2>&1 & kp=$!
await "$W/keeper.log" '^jails: ready' "the keeper did not start"

# ---- 1. a session, in the agent's jail --------------------------------------
.build/debug/abyss-jail agent agent > "$W/a1" 2>&1 || fail "the agent session was refused: $(cat "$W/a1")"
sock=$(sed -n 's/.* socket=\([^ ]*\) .*/\1/p' "$W/a1")
transcript=$(sed -n 's/.* transcript=\([^ ]*\) .*/\1/p' "$W/a1")
apid=$(sed -n 's/.* pid=\([0-9]*\)$/\1/p' "$W/a1")
[ -S "$sock" ] || fail "no agent socket at $sock: $(cat "$W/a1")"
jid=$(jls -j "$N" jid 2>/dev/null) || fail "no jail $N"
[ "$(ps -o jid= -p "$apid" | tr -d ' ')" = "$jid" ] || fail "abyss-agent (pid $apid) is not in $N (jid $jid)"
[ "$(jls -j "$N" ip4)" = disable ] && [ "$(jls -j "$N" ip6)" = disable ] || fail "the agent's jail has an address: ip4=$(jls -j "$N" ip4)"
inside=$(ls "$RB/$uid/agent/run/user" | tr '\n' ' ')
[ "$inside" = "agent-1.sock model-1.sock " ] || fail "the agent's runtime directory holds more than its sockets: $inside"
grep -q "jails: $N is jail $jid; no display, so no socket or bus" "$W/keeper.log" || fail "the keeper brought up a display or bus for an agent"
echo "ok: 1. the agent runs in $N (jid $jid): no address, and only its two sockets — no display, no bus"

# ---- 2. the loop, in the jail -------------------------------------------------
printf 'mine\n' > "$HB/$me/agent/marker.txt"
.build/debug/abyss-agent ask --listen "$sock" look around > "$W/q1" 2>&1 || fail "the question failed: $(cat "$W/q1")"
[ "$(grep -v '^call=' "$W/q1" | head -1)" = "done looking" ] || fail "the agent's answer: $(cat "$W/q1")"
[ "$(head -1 "$W/q1" | cut -c1-20)" = "call=list_directory(" ] || fail "the calls did not come first, as they happened: $(cat "$W/q1")"
grep -q '^stop=answered$' "$W/q1" && grep -q '^steps=2$' "$W/q1" || fail "not answered in 2 steps: $(cat "$W/q1")"
grep -q "^call=list_directory" "$W/q1" && grep -q "^call=read_file" "$W/q1" || fail "the tool calls were not made: $(cat "$W/q1")"
t="$transcript/transcript.jsonl"
grep '"kind":"request"' "$t" | sed -n 2p > "$W/second"
grep -q 'marker.txt' "$W/second" || fail "the jail's home was not listed back to the model: $(head -c 600 "$W/second")"
grep -q "error: $W/secret.txt: No such file or directory" "$W/second" || fail "a host file was readable from the jail: $(head -c 600 "$W/second")"
grep -q TOPSECRET "$t" && fail "the host file's contents reached the transcript"
echo "ok: 2. the stub's tool calls ran in the jail: its home listed, a host file not there; the results went back to the model"

# ---- 3. the transcript ---------------------------------------------------------
case "$transcript" in "$HOME/Library/Logs/Agents/"*) ;; *) fail "the transcript is not under ~/Library/Logs/Agents: $transcript" ;; esac
[ "$(stat -f %Lp "$t")" = 600 ] && [ "$(stat -f %Lp "$transcript")" = 700 ] || fail "transcript modes: $(stat -f %Lp "$t") in $(stat -f %Lp "$transcript")"
case "$transcript" in "$RB"*) fail "the transcript is inside the jail" ;; esac
[ -f "$transcript/abyss-model.log" ] || fail "abyss-model's log is not with the transcript"
ls "$RB/$uid/agent/run" | grep -q log && fail "a log is inside the jail: $(ls "$RB/$uid/agent/run")"
echo "ok: 3. the transcript is ~/Library/Logs/Agents/$(basename "$transcript"), 0600 in 0700, outside the jail"

# ---- 4. the budget --------------------------------------------------------------
st=0; .build/debug/abyss-agent ask --listen "$sock" again > "$W/q2" 2>&1 || st=$?
[ $st = 3 ] || fail "the second question exited $st, not 3 (budget): $(cat "$W/q2")"
grep -q "the session's budget of 250 tokens is spent (300 used)" "$W/q2" || fail "the agent does not say why it stopped: $(cat "$W/q2")"
grep -q '"kind":"refused"' "$t" || fail "the refusal is not in the transcript"
echo "ok: 4. the budget stopped the next call; the agent said why and exited 3"

# ---- 5. bye ------------------------------------------------------------------------
mpid=$(pgrep -f "abyss-model serve --listen $RB/$uid/agent/run/user/model-1.sock") || fail "no abyss-model for the session"
.build/debug/abyss-agent bye --listen "$sock" > /dev/null || fail "bye failed"
await "$W/keeper.log" "jails: abyss-agent (pid $apid) in $N exited" "the keeper did not see the agent end"
await "$W/keeper.log" "jails: its model stopped" "the keeper did not stop the session's model"
kill -0 "$mpid" 2>/dev/null && fail "abyss-model (pid $mpid) outlived its agent"
echo "ok: 5. bye ended the agent, and the keeper stopped its model"

# ---- 6. refusals ---------------------------------------------------------------------
.build/debug/abyss-jail agent debug > "$W/r1" 2>&1 && fail "an agent class with no model started a session"
grep -q 'no model is set for debug: set model= in jails.ini \[debug\]' "$W/r1" || fail "the refusal does not say why: $(cat "$W/r1")"
.build/debug/abyss-jail agent app > "$W/r2" 2>&1 && fail "an application class started an agent"
grep -q 'app is not an agent class' "$W/r2" || fail "the refusal does not say why: $(cat "$W/r2")"
echo "ok: 6. no model, and not an agent's class: both refused in words"
echo "all green (an agent in its jail: the model through abyss-model, the tools within the jail, the budget stops it)."
