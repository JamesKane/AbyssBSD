#!/bin/sh
# AbyssBSD Swift DE — a confined crash, read by a debug agent (PHASE18 P18.9a).
#
# Real processes: abyss-jaild as root — started with a core size of 0, as some
# rc setups leave it — the session's keeper, programs in the app jail, and a
# `debug` session: abyss-model (stub) outside, abyss-agent with lldb inside.
# FreeBSD only; needs passwordless sudo and lldb (base). Claims:
#
#   1. a confined program has the person's login-class limits, not jaild's:
#      jaild's core size is 0, the program's is the class's;
#   2. a program killed by SIGSEGV is a crash the keeper keeps, with its core
#      in the jail's home; a program that exits 3 is not a crash;
#   3. `debug N` starts a session in the debug jail with that crash's core and
#      binary granted read-only — and nothing of a second crash;
#   4. the agent's lldb ran on the core: the model was given the backtrace,
#      with the signal, kaboom() and its line in crasher.c;
#   5. a crash with no core (SIGKILL) is kept, and `debug` refuses it in words.
#
# Usage: abyss/tests/live-crash.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
[ -x /usr/bin/lldb ] || { echo "FAIL: no /usr/bin/lldb (it is in base)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-cr.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u) me=$(id -un)
APP="abyss-$uid-app" DBG="abyss-$uid-debug"
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
  for p in $(pgrep -f "endpoint --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in jd.log keeper.log; do tail -6 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 300 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
JL() { .build/debug/abyss-jail launch "$@" > "$W/l" 2>&1 || fail "launch $*: $(cat "$W/l")"; }

cc -g -O0 abyss/tests/crasher.c -o "$W/crasher" || fail "cannot build the crasher"
cp "$W/crasher" "$W/crasher2"
# The debug agent's stub: lldb's backtrace, then a report.
cat > "$W/stub.json" <<'J'
[{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
  {"id":"c1","type":"function","function":{"name":"lldb","arguments":"{\"command\":\"bt\"}"}},
  {"id":"c2","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\"/run/granted\"}"}}]}}],
  "usage":{"total_tokens":100}},
 {"choices":[{"index":0,"message":{"role":"assistant","content":"It read a null pointer in kaboom()."}}],"usage":{"total_tokens":100}}]
J
printf '[debug]\nmodel = stub:%s\n' "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"

# jaild with a core size of 0: what the jailed program must not inherit.
sudo sh -c "ulimit -c 0; exec '$W/bin/abyss-jaild' --socket '$SOCK' --root-base '$RB' --home-base '$HB'" > "$W/jd.log" 2>&1 &
await "$W/jd.log" 'answering at' "the daemon did not start"
jdpid=$(daemon | head -1)
[ "$(procstat -l "$jdpid" | awk '$2=="abyss-jaild" && $3=="coredumpsize" {print $4}')" = 0 ] || fail "jaild's core size is not 0: the test proves nothing"
env -u WAYLAND_DISPLAY .build/debug/abyss-jail --socket "$SOCK" serve > "$W/keeper.log" 2>&1 & kp=$!
await "$W/keeper.log" '^jails: ready' "the keeper did not start"

# ---- 1. the person's limits ------------------------------------------------------
JL app -- /bin/sh -c "ulimit -c > /home/$me/limit.txt"
await "$W/keeper.log" "jails: /bin/sh (pid [0-9]*) in $APP exited" "the probe did not run"
want=$(sh -c 'ulimit -c' 2>/dev/null)   # this account's own, from its class at login
got=$(cat "$HB/$me/app/limit.txt")
[ "$got" != 0 ] || fail "the confined program's core size is jaild's (0), not the person's"
[ "$got" = "$want" ] || fail "the confined program's core size is $got, the person's is $want"
echo "ok: 1. jaild's core size is 0; the confined program's is the person's ($got)"

# ---- 2. a crash, and an exit that is not one ----------------------------------------
cp "$W/crasher" "$W/crasher2" "$HB/$me/app/"
JL app -- "/home/$me/crasher"
await "$W/keeper.log" "jails: crash 1: /home/$me/crasher was killed by SIGSEGV and left a core in $APP" "the keeper did not keep the crash"
[ -s "$HB/$me/app/crasher.core" ] || fail "no core in the jail's home"
JL app -- /bin/sh -c 'exit 3'
await "$W/keeper.log" "jails: /bin/sh (pid [0-9]*) in $APP exited" "the exit-3 probe did not run" 2
[ "$(.build/debug/abyss-jail crashes | wc -l | tr -d ' ')" = 1 ] || fail "an exit 3 was kept as a crash: $(.build/debug/abyss-jail crashes)"
echo "ok: 2. SIGSEGV is crash 1, its core in the jail's home; an exit of 3 is not a crash"

# ---- 3. debug 1: that crash, read-only, and no other ----------------------------------
JL app -- "/home/$me/crasher2"
await "$W/keeper.log" "jails: crash 2: /home/$me/crasher2 was killed by SIGSEGV" "the second crash was not kept"
.build/debug/abyss-jail debug 1 > "$W/d1" 2>&1 || fail "debug 1 was refused: $(cat "$W/d1")"
sock=$(sed -n 's/.* socket=\([^ ]*\) .*/\1/p' "$W/d1")
transcript=$(sed -n 's/.* transcript=\([^ ]*\) .*/\1/p' "$W/d1")
case "$sock" in "$RB/$uid/debug/"*) ;; *) fail "the session is not in the debug jail: $sock" ;; esac
# A developer's abyss-agent is granted in too (P18.8); the crash's grants are the rest.
grants=$(.build/debug/abyss-jail --socket "$SOCK" grants "$DBG" | grep -v '/abyss-agent$' || true)
echo "$grants" | grep -q 'crasher.core' && echo "$grants" | grep -q '/crasher ' || echo "$grants" | grep -q '/crasher$' || fail "the debug jail was not given crash 1's core and binary: $grants"
echo "$grants" | grep -q crasher2 && fail "the debug jail was given the second crash too: $grants"
[ "$(echo "$grants" | wc -l | tr -d ' ')" = 2 ] || fail "the debug jail holds more than one crash: $grants"
mount | grep -F " on $RB/$uid/debug/" | grep crasher | grep -vq 'read-only' && fail "a grant into the debug jail is writable: $(mount | grep -F "$RB/$uid/debug/" | grep crasher)"
echo "ok: 3. debug 1 runs in $DBG with crash 1's core and binary, read-only, and nothing of crash 2"

# ---- 4. lldb on the core ------------------------------------------------------------
.build/debug/abyss-agent ask --listen "$sock" why did it crash > "$W/q1" 2>&1 || fail "the debug question failed: $(cat "$W/q1")"
grep -q '^call=lldb' "$W/q1" || fail "the agent did not run lldb: $(cat "$W/q1")"
t="$transcript/transcript.jsonl"
grep '"kind":"request"' "$t" | sed -n 2p > "$W/second"
# lldb's own words, as the model was given them: the tool result for call c1
# (never the system prompt, which names the signal too).
lldbsaid=$(awk '{ i = index($0, "\"tool_call_id\":\"c1\",\"content\":\""); if (i) { r = substr($0, i + 30); j = index(r, "\"},{"); print (j ? substr(r, 1, j - 1) : substr(r, 1, 2000)) } }' "$W/second")
[ -n "$lldbsaid" ] || fail "no lldb result went back to the model: $(head -c 800 "$W/second")"
echo "$lldbsaid" | grep -q 'stop reason = signal SIGSEGV' || fail "lldb did not report the SIGSEGV: $lldbsaid"
echo "$lldbsaid" | grep -q 'kaboom' || fail "lldb's backtrace has no kaboom(): $lldbsaid"
echo "$lldbsaid" | grep -q 'crasher.c:6' || fail "lldb's backtrace has no crasher.c:6: $lldbsaid"
grep -o '"role":"tool","tool_call_id":"c2","content":"[^"]*' "$W/second" | grep -q crasher2 && fail "the debug agent saw the second crash"
grep -q '"content":"It read a null pointer in kaboom().' "$t" || fail "the report is not in the transcript"
.build/debug/abyss-agent bye --listen "$sock" > /dev/null
echo "ok: 4. lldb ran on the core in the jail: the model got SIGSEGV, kaboom() at crasher.c:6; the report is in the transcript"

# ---- 5. no core -------------------------------------------------------------------------
JL app -- /bin/sh -c 'kill -9 $$'
await "$W/keeper.log" "jails: crash 3: /bin/sh was killed by SIGKILL, leaving no core" "a SIGKILL was not kept as a crash"
.build/debug/abyss-jail debug 3 > "$W/d3" 2>&1 && fail "debug ran on a crash with no core"
grep -q 'there is nothing to read' "$W/d3" || fail "the refusal does not say why: $(cat "$W/d3")"
echo "ok: 5. a SIGKILL is a crash with no core, and debug refuses it in words"
echo "all green (a confined crash: the person's limits, the core kept, one crash granted to a debug agent, lldb on it)."
