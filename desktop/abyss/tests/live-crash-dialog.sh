#!/bin/sh
# AbyssBSD Swift DE — "… has unexpectedly quit", and Ask the Agent (PHASE18 P18.9b).
#
# As a person meets it: a confined program crashes, the keeper puts up Crash
# Reporter, the person clicks Ask the Agent…, and the Agent window opens on a
# debug session for that crash, already asking why. Real processes: a
# compositor, abyss-jaild, the keeper, the crasher in the app jail, Crash
# Reporter and the Agent window (both started by the desktop, not the test),
# abyss-model (stub) and abyss-agent with lldb. FreeBSD only; needs sudo.
# Claims:
#
#   1. the crash puts up Crash Reporter, naming the program and the signal,
#      with Ask the Agent… as its default;
#   2. clicking it starts a debug session in the debug jail, closes the
#      report, and opens the Agent window on that session, asking why;
#   3. the agent ran lldb on the core — its backtrace (SIGSEGV, kaboom(),
#      crasher.c:6) went to the model — and the window shows the answer;
#   4. a crash that left no core gets an OK and no Ask, and says why;
#   5. Quit in the Agent window (its menu verb, as the bar sends it) ends the
#      session and its model.
#
# Usage: abyss/tests/live-crash-dialog.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
[ -x /usr/bin/lldb ] || { echo "FAIL: no /usr/bin/lldb (it is in base)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent AquaDemo undertow abyss-dbus; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-cd.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u) me=$(id -un)
export XDG_RUNTIME_DIR="$W/xdg" ABYSS_RUNTIME_DIR="$W/xdg" ABYSS_CONFIG_DIR="$W/config" HOME="$W/home"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$ABYSS_CONFIG_DIR" "$HOME"
SW=1024 SH=768

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  exec 3>&- 2>/dev/null || true
  pkill -x AquaDemo 2>/dev/null || true
  for p in ${vp:-} ${kp:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-model serve --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  for p in $(pgrep -f "endpoint --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; tail -12 "$W/keeper.log" 2>/dev/null | sed "s/^/  keeper.log| /"; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 300 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
K="$W/keeper.log"

cc -g -O0 abyss/tests/crasher.c -o "$W/crasher" || fail "cannot build the crasher"
cat > "$W/stub.json" <<'J'
[{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
  {"id":"c1","type":"function","function":{"name":"lldb","arguments":"{\"command\":\"bt\"}"}}]}}],
  "usage":{"total_tokens":100}},
 {"choices":[{"index":0,"message":{"role":"assistant","content":"It read a null pointer in kaboom(), crasher.c line 6."}}],"usage":{"total_tokens":100}}]
J
printf '[debug]\nmodel = stub:%s\n' "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"

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
.build/debug/abyss-jail --socket "$SOCK" serve > "$K" 2>&1 3>&- & kp=$!
await "$K" '^jails: ready' "the keeper did not start"
mkfifo "$W/pointer"
"$W/vpointer" $SW $SH < "$W/pointer" > "$W/vp.log" 2>&1 & vp=$!
exec 3> "$W/pointer"
click() { printf 'm %s %s\np\nr\n' "$1" "$2" >&3; sleep 0.4; }
winat() {  # winat APPID — the window's origin on the screen
  grep "^window $1" "$W/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1
}

# ---- 1. the crash, and the report ---------------------------------------------------
.build/debug/abyss-jail launch app -- /bin/true > /dev/null 2>&1 || fail "the app jail did not open"
cp "$W/crasher" "$HB/$me/app/"
.build/debug/abyss-jail launch app -- "/home/$me/crasher" > /dev/null 2>&1 || fail "the crasher did not launch"
await "$K" 'jails: crash 1 shown' "the keeper did not put up a report for the crash"
await "$K" 'CrashReport: up: crash 1, crasher, SIGSEGV, core yes' "Crash Reporter did not say what crashed"
await "$K" 'CrashReport: buttons close=.* ask=' "Crash Reporter did not offer Ask the Agent…"
i=0; until [ -n "$(winat org.abyssbsd.crashreport)" ] || [ $i -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
pos=$(winat org.abyssbsd.crashreport); [ -n "$pos" ] || fail "no Crash Reporter window on the screen"
echo "ok: 1. the crash put up Crash Reporter: crasher, SIGSEGV, with Ask the Agent…"

# ---- 2. Ask the Agent… ------------------------------------------------------------------
b=$(grep 'CrashReport: buttons ' "$K" | tail -1 | tr ' ' '\n' | sed -n 's/^ask=//p')
click $((${pos%,*} + ${b%,*})) $((${pos#*,} + ${b#*,}))
await "$K" "CrashReport: debug session .* at $RB/$uid/debug/run/user/agent-1.sock" "Ask the Agent… did not start a debug session in the debug jail"
await "$K" 'CrashReport: closed' "the report did not close"
await "$K" "Agent: session (given) at $RB/$uid/debug/run/user/agent-1.sock" "the Agent window did not open on the debug session"
await "$K" 'Agent: asked: Why did crasher crash?' "the Agent window did not ask why"
echo "ok: 2. Ask the Agent… started a debug session, closed the report, and opened the Agent window asking why"

# ---- 3. lldb, and the answer ----------------------------------------------------------------
await "$K" 'Agent: call lldb' "the agent did not run lldb"
await "$K" 'Agent: answered: stop=answered' "the question was not answered"
t=$(ls -d "$HOME"/Library/Logs/Agents/*-debug-*)/transcript.jsonl
lldbsaid=$(grep '"kind":"request"' "$t" | sed -n 2p | awk '{ i = index($0, "\"tool_call_id\":\"c1\",\"content\":\""); if (i) { r = substr($0, i + 30); j = index(r, "\"},{"); print (j ? substr(r, 1, j - 1) : substr(r, 1, 2000)) } }')
echo "$lldbsaid" | grep -q 'stop reason = signal SIGSEGV' || fail "lldb's backtrace has no SIGSEGV: $lldbsaid"
echo "$lldbsaid" | grep -q 'kaboom' && echo "$lldbsaid" | grep -q 'crasher.c:6' || fail "lldb's backtrace has no kaboom() at crasher.c:6: $lldbsaid"
echo "ok: 3. lldb ran on the core (SIGSEGV, kaboom() at crasher.c:6), and the window has the answer"

# ---- 4. no core: OK, no Ask ---------------------------------------------------------------------
.build/debug/abyss-jail launch app -- /bin/sh -c 'kill -9 $$' > /dev/null 2>&1 || fail "the SIGKILL probe did not launch"
await "$K" 'CrashReport: up: crash 2, sh, SIGKILL, core no' "a crash with no core was not reported"
await "$K" 'CrashReport: buttons ok=' "the no-core report offers more than OK"
grep 'CrashReport: buttons ok=' "$K" | grep -q 'ask=' && fail "the no-core report offers Ask the Agent…"
echo "ok: 4. a crash that left no core: reported with OK only (it left nothing to read)"

# ---- 5. Quit in the Agent window --------------------------------------------------------------------
apos=$(winat org.abyssbsd.agent); [ -n "$apos" ] || fail "no Agent window on the screen"
# The window's own Quit, through its menu service, as the bar would.
.build/debug/abyssmenu run agent app.quit > /dev/null 2>&1 || fail "Agent's Quit was refused"
await "$K" 'Agent: bye' "Quit did not end the session"
await "$K" 'jails: its model stopped' "the keeper did not stop the debug session's model"
echo "ok: 5. Quit in the Agent window ended the debug session, and the keeper stopped its model"
echo "all green (a confined crash, reported; Ask the Agent… opened a debug session that read the core and said why)."
