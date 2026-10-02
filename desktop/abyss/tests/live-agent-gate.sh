#!/bin/sh
# AbyssBSD Swift DE — the gate for agents (PHASE18 P18.14).
#
# 18b end to end, as a person meets it, against PLAN's verify list. Real
# everything: abyss-jaild as root, undertow, the session's keeper, abyss-model
# outside the jail (the stub, or llama-server with a real model), abyss-agent
# and its bridges, the Agent window, TextEdit, Crash Reporter, the crasher.
# What a real model chooses to do varies, so every claim about confinement is
# checked on the system itself — the descriptors, the jail, the bridges asked
# directly from inside it — and not on what the model said. FreeBSD only;
# needs passwordless sudo and lldb (base). Claims:
#
#   1. an agent in a jail whose only ways out are the sockets it was given:
#      the jail has no address and cannot reach the network; its runtime
#      directory holds the session's four sockets (agent, model, vocabulary,
#      fetch) and nothing else; the agent process holds no network socket
#      and no file outside its jail; and the model answers it;
#   2. the transcript shows what it was granted: an application given from
#      the Agent window is in the transcript, and the vocabulary bridge,
#      asked from inside the jail, lists it;
#   3. a revocation takes effect: taken back, it is in the transcript, the
#      bridge no longer lists it, and a command for it, asked from inside the
#      jail, is refused;
#   4. a budget stop with its reason on screen: the next call over the
#      budget stops the question, and the Agent window puts up its requester
#      with abyss-model's words;
#   5. the crash notice starts a debug session that sees one crash and not a
#      second: two crashes; Ask the Agent… on the second starts a debug
#      session whose jail holds that crash's core and binary, read-only, and
#      nothing of the first; and lldb is its tool, which the agent class lacks.
#
# Usage: abyss/tests/live-agent-gate.sh [--model local:/path/to/model.gguf]
#   With no --model, the stub; with one, that model (on the CPU in the guest,
#   the GPU on the box), and longer waits.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
[ -x /usr/bin/lldb ] || { echo "FAIL: no /usr/bin/lldb (it is in base)"; exit 1; }
model=""; [ "${1:-}" = --model ] && model=$2
for b in abyss-jaild abyss-jail abyss-model abyss-agent abyss-vocab abyss-fetch AquaDemo undertow abyssmenu abyss-dbus; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-gate.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u) me=$(id -un)
AG="abyss-$uid-agent" DBG="abyss-$uid-debug"
export XDG_RUNTIME_DIR="$W/xdg" ABYSS_RUNTIME_DIR="$W/xdg" ABYSS_CONFIG_DIR="$W/config" HOME="$W/home"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$ABYSS_CONFIG_DIR" "$HOME"
SW=1024 SH=768
# A real model takes its time: a question may take minutes on a CPU.
long=300; [ -n "$model" ] && long=6000

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  exec 3>&- 2>/dev/null || true
  pkill -x AquaDemo 2>/dev/null || true
  for p in ${vp:-} ${kp:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-(model|vocab|fetch) serve --listen $RB" || true) $(pgrep -f "endpoint --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  [ -n "${GATE_KEEP:-}" ] && cp "$W"/*.log "$W"/procstat.txt "$GATE_KEEP"/ 2>/dev/null || true
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
K="$W/keeper.log" A="$W/app.log"
fail() { echo "FAIL: $1"; for f in keeper.log app.log te.log; do tail -6 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { c=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${c:-0}"; }
await() { lim=${5:-300}; i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt "$lim" ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
inside() { jail=$1; shift; sudo jexec -U "$me" "$jail" "$@"; }   # run as the person, in a jail

cc -g -O0 abyss/tests/crasher.c -o "$W/crasher" || fail "cannot build the crasher"
cp "$W/crasher" "$W/crasher2"
if [ -n "$model" ]; then
  printf '[agent]\nmodel = %s\nbudget = 1\n[debug]\nmodel = %s\n' "$model" "$model" > "$ABYSS_CONFIG_DIR/jails.ini"
else
  cat > "$W/stub.json" <<'J'
[{"choices":[{"index":0,"message":{"role":"assistant","content":"Hello."}}],"usage":{"total_tokens":10}}]
J
  printf '[agent]\nmodel = stub:%s\nbudget = 1\n[debug]\nmodel = stub:%s\n' "$W/stub.json" "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"
fi
: > "$ABYSS_CONFIG_DIR/agents.ini"   # agents on (P18.13a)

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
winat() { grep "^window $1" "$W/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1; }
echo "the model: ${model:-the stub}"

# ---- 1. a jail whose only ways out are its sockets ----------------------------------------
env AQUA_SCENE=textedit .build/debug/AquaDemo "$W/note.txt" > "$W/te.log" 2>&1 3>&- &
await "$W/te.log" 'TextEdit: menus on ' "TextEdit did not publish its menus"
env AQUA_SCENE=agent .build/debug/AquaDemo > "$A" 2>&1 3>&- &
await "$A" 'Agent: session .* at ' "the Agent window did not get a session" 1 $long
apid=$(sed -n 's/.*: agent pid \([0-9]*\),.*/\1/p' "$K" | head -1)
n=$(sed -n 's/^Agent: session .* at .*\/agent-\([0-9]*\)\.sock$/\1/p' "$A" | head -1)
jid=$(jls -j "$AG" jid) || fail "no jail $AG"
[ "$(ps -o jid= -p "$apid" | tr -d ' ')" = "$jid" ] || fail "the agent (pid $apid) is not in $AG"
[ "$(jls -j "$AG" ip4)" = disable ] && [ "$(jls -j "$AG" ip6)" = disable ] || fail "the agent's jail has an address"
inside "$AG" /usr/bin/nc -z -w 2 1.1.1.1 443 > "$W/nc" 2>&1 && fail "from inside the agent's jail, the network was reached"
ls "$RB/$uid/agent/run/user" | tr '\n' ' ' > "$W/runuser"
[ "$(cat "$W/runuser")" = "agent-$n.sock fetch-$n.sock model-$n.sock vocab-$n.sock " ] || fail "the runtime directory holds more than the session's sockets: $(cat "$W/runuser")"
sudo procstat -f "$apid" > "$W/procstat.txt" 2>&1
# What the agent holds: its standard streams on /dev/null, ONE socket — its
# own, at agent-N.sock, where the window asks it — and vnodes inside its jail.
# It opens the model's and the bridges' sockets per call and closes them. An
# unknown-typed descriptor is allowed only while it waits in accept(2), which
# reserves the next connection's descriptor before it blocks.
awk -v root="$RB/$uid/agent" -v sock="/run/user/agent-$n.sock" '
  NR == 1 { next }
  $3 ~ /^[0-9]+$/ && $3 <= 2 { if ($NF != "/dev/null") bad = bad " fd" $3 "=" $NF; next }
  $4 == "s" { sockets++; if ($(NF) != sock || $(NF-3) != "UDS") bad = bad " socket:" $0; next }
  $4 == "v" { if (index($NF, root) != 1) bad = bad " vnode:" $NF; next }
  $4 == "?" { unknown++; next }
  { bad = bad " " $4 ":" $0 }
  END { if (sockets != 1) bad = bad " sockets=" sockets; printf "%s|%d", bad, unknown }' "$W/procstat.txt" > "$W/fdcheck"
[ -z "$(cut -d'|' -f1 "$W/fdcheck")" ] || fail "the agent holds more than its socket and its jail:$(cut -d'|' -f1 "$W/fdcheck")"
if [ "$(cut -d'|' -f2 "$W/fdcheck")" != 0 ]; then
  sudo procstat -k "$apid" | grep -q kern_accept4 || fail "the agent holds a descriptor of no known type, and is not waiting in accept: $(cat "$W/procstat.txt")"
fi
bin=$(ps -o command= -p "$apid" | cut -d' ' -f1)
echo "ok: 1. the agent in $AG: no address, the network unreachable from inside; four sockets in its runtime directory, and the agent holds one (its own), nothing outside its jail"

# ---- the model answers -------------------------------------------------------------------
.build/debug/abyssmenu run agent agent.question "text=Say hello in one word." > /dev/null 2>&1 || fail "the question was refused"
await "$A" 'Agent: answered: stop=' "the model did not answer" 1 $long
t=$(ls -d "$HOME"/Library/Logs/Agents/*-agent-*)/transcript.jsonl
grep -q '"kind":"reply"' "$t" || fail "the transcript has no reply from the model"
echo "ok: the model answered ($(grep -m1 'Agent: answered: ' "$A" | sed 's/.*answered: //'))"

# ---- 2. what it was granted, in the transcript ----------------------------------------------
vs="/run/user/vocab-$n.sock"
.build/debug/abyssmenu run agent agent.give "app=textedit" > /dev/null 2>&1 || fail "Give was refused"
await "$A" 'Agent: gave TextEdit' "TextEdit was not given"
grep -q '"kind":"vocabulary","event":"given".*"app":"TextEdit"' "$t" || grep -q '"event":"given".*"TextEdit"' "$t" || fail "the transcript does not say TextEdit was given"
inside "$AG" "$bin" tool apps '{}' --vocab "$vs" > "$W/t1" 2>&1
grep -q TextEdit "$W/t1" || fail "from inside the jail, the bridge does not list TextEdit: $(cat "$W/t1")"
echo "ok: 2. TextEdit given: the transcript says so, and the bridge, asked from inside the jail, lists it"

# ---- 3. a revocation takes effect -------------------------------------------------------------
.build/debug/abyssmenu run agent agent.take "app=TextEdit" > "$W/tk" 2>&1 || fail "Take Back was refused: $(cat "$W/tk")"
await "$A" 'Agent: took TextEdit back' "TextEdit was not taken back"
grep -q '"event":"taken".*"TextEdit"' "$t" || fail "the transcript does not say TextEdit was taken back"
inside "$AG" "$bin" tool apps '{}' --vocab "$vs" > "$W/t2" 2>&1
grep -q TextEdit "$W/t2" && fail "taken back, the bridge still lists TextEdit: $(cat "$W/t2")"
inside "$AG" "$bin" tool activate '{"app":"TextEdit","verb":"file.save"}' --vocab "$vs" > "$W/t3" 2>&1
grep -q 'not given' "$W/t3" || fail "taken back, a command for TextEdit was not refused: $(cat "$W/t3")"
grep -q 'TextEdit: saved' "$W/te.log" && fail "TextEdit saved for an agent it was taken from"
echo "ok: 3. taken back: in the transcript; the bridge no longer lists it, and refuses a command for it ($(head -1 "$W/t3" | cut -c1-60))"

# ---- 4. a budget stop, its reason on screen ---------------------------------------------------
# The budget is 1 token: the first reply crossed it, so the next call is refused.
grep -q 'Agent: answered: stop=budget' "$A" || {
  .build/debug/abyssmenu run agent agent.question "text=And goodbye?" > /dev/null 2>&1 || fail "the second question was refused"
  await "$A" 'Agent: answered: stop=budget' "the budget did not stop the next call" 1 $long
}
await "$A" 'Agent: requester budget: ' "the window did not put the budget's reason up"
# On screen: the window drew the requester, its two buttons where it says.
await "$A" 'Agent: requester stop=[0-9]*,[0-9]* allow=' "the window did not draw the budget's requester"
why=$(grep 'Agent: requester budget: ' "$A" | tail -1 | sed 's/.*requester budget: //')
echo "$why" | grep -q 'budget' || fail "the requester does not give abyss-model's reason: $why"
grep -q '"kind":"refused"' "$t" || fail "the transcript does not have the refusal"
.build/debug/abyssmenu run agent agent.stop > /dev/null 2>&1 || fail "Stop was refused"
echo "ok: 4. the budget stopped the next call; the window's requester says why: $(echo "$why" | cut -c1-70)"

# ---- 5. the crash notice: one crash, not a second ---------------------------------------------
.build/debug/abyss-jail launch app -- /bin/true > /dev/null 2>&1 || fail "the app jail did not open"
cp "$W/crasher" "$W/crasher2" "$HB/$me/app/"
.build/debug/abyss-jail launch app -- "/home/$me/crasher" > /dev/null 2>&1 || fail "the crasher did not launch"
await "$K" 'CrashReport: up: crash 1, crasher, SIGSEGV, core yes' "the first crash was not reported"
.build/debug/abyss-jail launch app -- "/home/$me/crasher2" > /dev/null 2>&1 || fail "the second crasher did not launch"
await "$K" 'CrashReport: up: crash 2, crasher2, SIGSEGV, core yes' "the second crash was not reported"
i=0; until [ "$(grep -c '^window org.abyssbsd.crashreport' "$W/ut.out")" -ge 2 ] || [ $i -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
pos=$(winat org.abyssbsd.crashreport); [ -n "$pos" ] || fail "no Crash Reporter window"
b=$(grep 'CrashReport: buttons ' "$K" | tail -1 | tr ' ' '\n' | sed -n 's/^ask=//p')
click $((${pos%,*} + ${b%,*})) $((${pos#*,} + ${b#*,}))
await "$K" "CrashReport: debug session .* at $RB/$uid/debug/run/user/agent-" "Ask the Agent… did not start a debug session"
dpid=$(sed -n 's/.*session .*-debug-.* in .*: agent pid \([0-9]*\),.*/\1/p' "$K" | tail -1)
[ -n "$dpid" ] || dpid=$(pgrep -f "abyss-agent serve .*--class debug" | head -1)
grants=$(.build/debug/abyss-jail --socket "$SOCK" grants "$DBG" | grep -v '/abyss-agent$' || true)
echo "$grants" | grep -q 'crasher2' || fail "the debug jail was not given the second crash: $grants"
echo "$grants" | grep -v crasher2 | grep -q crasher && fail "the debug jail was given the first crash too: $grants"
[ "$(echo "$grants" | wc -l | tr -d ' ')" = 2 ] || fail "the debug jail holds more than one crash's core and binary: $grants"
mount | grep -F " on $RB/$uid/debug/" | grep crasher | grep -vq 'read-only' && fail "a crash's grant into the debug jail is writable"
dbin=$(ps -o command= -p "$dpid" | cut -d' ' -f1)
inside "$DBG" ls -R /run/granted 2>/dev/null | grep -E '^crasher(\.core)?$' && fail "the first crash's files are visible in the debug jail"
# The tools each session's agent offers its model, as the model was sent them.
grep '"kind":"request"' "$t" | grep -q '"name":"lldb"' && fail "the agent session offered its model lldb"
dt=$(ls -d "$HOME"/Library/Logs/Agents/*-debug-* | tail -1)/transcript.jsonl
await "$dt" '"kind":"request"' "the debug session asked its model nothing" 1 $long
grep '"kind":"request"' "$dt" | grep -q '"name":"lldb"' || fail "the debug session did not offer its model lldb"
echo "ok: 5. Ask the Agent… on the second crash: a debug session with its core and binary, read-only, and nothing of the first; lldb is debug's alone"
echo "all green (PLAN's verify list, end to end, with ${model:-the stub})."
