#!/bin/sh
# AbyssBSD Swift DE — an agent reaches the web only as the person allows
# (PHASE18 P18.12b).
#
# Real processes: a compositor, abyss-jaild, the keeper, the Agent window, an
# agent session (abyss-model stub, abyss-vocab, abyss-fetch, abyss-agent), and
# a web server that is not ours (nc, with a canned page). The bridge is let
# reach this computer's own address (ABYSS_FETCH_ALLOW_LOCAL): the server is
# local; FetchTests show it is refused otherwise. FreeBSD only; needs sudo.
# Claims:
#
#   1. the agent's jail has no network: a fetch run in it cannot connect;
#   2. the agent's first fetch from a host puts up the window's requester, and
#      the server hears nothing;
#   3. Don't Allow: the agent is told so, the server still hears nothing, and
#      the transcript says "denied";
#   4. asked again, the requester is back; Allow (after a person's pause): the
#      bridge fetches as HTTP/1.0, the page's words reach the model, and the
#      transcript says "permitted" and "fetched".
#
# Usage: abyss/tests/live-agent-fetch.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent abyss-vocab abyss-fetch AquaDemo undertow abyssmenu; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-af.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u)
export XDG_RUNTIME_DIR="$W/xdg" ABYSS_RUNTIME_DIR="$W/xdg" ABYSS_CONFIG_DIR="$W/config" HOME="$W/home"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$ABYSS_CONFIG_DIR" "$HOME"
SW=1024 SH=768
port=$((30000 + $$ % 10000))

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  for p in ${ap:-} ${np:-} ${kp:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-(model|vocab|fetch) serve --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in keeper.log app.log; do tail -6 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
menu() { .build/debug/abyssmenu run agent "$@" > /dev/null 2>&1; }

cat > "$W/stub.json" <<J
[{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
  {"id":"f1","type":"function","function":{"name":"fetch","arguments":"{\"url\":\"http://127.0.0.1:$port/plumbers\"}"}}]}}],
  "usage":{"total_tokens":100}},
 {"choices":[{"index":0,"message":{"role":"assistant","content":"Read it."}}],"usage":{"total_tokens":100}}]
J
printf '[agent]\nmodel = stub:%s\n' "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"
: > "$ABYSS_CONFIG_DIR/agents.ini"   # agents on (P18.13): off is this file, absent
printf 'HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h1>Plumbers</h1><p>Open on Monday &amp; Tuesday.</p><script>x()</script></body></html>\n' > "$W/page.http"

sudo "$W/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" > "$W/jd.log" 2>&1 3>&- &
await "$W/jd.log" 'answering at' "the daemon did not start"
mkdir -p "$W/cfg"
env -u WAYLAND_DISPLAY .build/debug/undertow run --frames 0 --width $SW --height $SH --config-dir "$W/cfg" \
    > "$W/ut.out" 2> "$W/ut.err" 3>&- & ut=$!
await "$W/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$W/ut.out" | cut -d= -f2-)"
env ABYSS_FETCH_ALLOW_LOCAL=1 .build/debug/abyss-jail --socket "$SOCK" serve > "$W/keeper.log" 2>&1 3>&- & kp=$!
await "$W/keeper.log" '^jails: ready' "the keeper did not start"
env AQUA_SCENE=agent .build/debug/AquaDemo > "$W/app.log" 2>&1 3>&- & ap=$!
await "$W/app.log" 'Agent: session .* at ' "the Agent window got no session"
t=$(ls -d "$HOME"/Library/Logs/Agents/*-agent-*)/transcript.jsonl
# nc ends the reply by closing: ncat does by default, FreeBSD's nc with -N.
if nc -h 2>&1 | grep -q Ncat; then o=; else o=-N; fi
nc -l $o 127.0.0.1 "$port" < "$W/page.http" > "$W/server.req" 2>/dev/null & np=$!
sleep 0.3

# ---- 1. no network in the jail --------------------------------------------------------
if .build/debug/abyss-jail --socket "$SOCK" run agent -- /usr/bin/fetch -q -T 3 -o /dev/null "http://127.0.0.1:$port/" > "$W/inside" 2>&1; then
  fail "a fetch inside the agent's jail connected"
fi
[ -s "$W/server.req" ] && fail "the server heard from inside the jail"
echo "ok: 1. the agent's jail has no network: a fetch run in it could not connect ($(head -1 "$W/inside" | cut -c1-60))"

# ---- 2. the first fetch asks ---------------------------------------------------------------
menu agent.question "text=which plumbers are open on monday?" || fail "the question was refused"
await "$W/app.log" 'Agent: requester host: 127.0.0.1' "the first fetch did not ask the person"
[ -s "$W/server.req" ] && fail "the server heard before the person answered"
echo "ok: 2. the agent's first fetch from 127.0.0.1 put up the requester; the server heard nothing"

# ---- 3. Don't Allow -----------------------------------------------------------------------------
menu agent.stop || fail "Don't Allow was refused"
await "$W/app.log" 'Agent: did not allow 127.0.0.1' "Don't Allow did not reach the keeper"
await "$W/app.log" 'Agent: answered: stop=answered' "the question did not finish after Don't Allow"
grep '"kind":"request"' "$t" | sed -n 2p | grep -q 'refused: the person did not allow you to reach 127.0.0.1' || fail "the agent was not told it was refused"
sleep 0.3; [ -s "$W/server.req" ] && fail "the server heard after Don't Allow"
grep -q '"kind":"fetch","event":"denied","host":"127.0.0.1"' "$t" || fail "the transcript does not say denied"
echo "ok: 3. Don't Allow: the agent was told, the server heard nothing, the transcript says denied"

# ---- 4. asked again; Allow ----------------------------------------------------------------------
menu agent.question "text=please look again" || fail "the second question was refused"
await "$W/app.log" 'Agent: requester host: 127.0.0.1' "the next fetch did not ask again" 2
sleep 3   # a person reads before they answer
menu agent.allow || fail "Allow was refused"
await "$W/app.log" 'Agent: allowed 127.0.0.1' "Allow did not reach the keeper"
await "$W/app.log" 'Agent: answered: stop=answered' "the second question did not finish" 2
head -1 "$W/server.req" | grep -q "^GET /plumbers HTTP/1.0" || fail "the server did not get the request: $(head -1 "$W/server.req")"
grep '"kind":"request"' "$t" | tail -1 | grep -q 'Plumbers\\nOpen on Monday & Tuesday.' || fail "the page's words did not reach the model"
grep '"kind":"request"' "$t" | tail -1 | grep -q 'x()' && fail "the page's script reached the model"
grep -q '"kind":"fetch","event":"permitted","host":"127.0.0.1"' "$t" && grep -q '"kind":"fetch","event":"fetched"' "$t" || fail "the transcript does not say permitted and fetched"
echo "ok: 4. asked again; Allow: the bridge fetched (HTTP/1.0), the page's words reached the model, the transcript says so"
echo "all green (an agent reaches the web only through the bridge, and only where the person allows)."
