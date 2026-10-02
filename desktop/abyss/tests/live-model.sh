#!/bin/sh
# AbyssBSD Swift DE — abyss-model, the one way to a model (PHASE18 P18.7).
#
# The claims, each with a client that is not our code:
#   1. an OpenAI client (curl, over the unix socket) gets the backend's
#      completion, tool calls and all;
#   2. the budget stops the next call — 429, the reason in words — and that
#      call reaches no backend;
#   3. the transcript is one JSON line per event, outside the jail's reach,
#      mode 0600, and only ever appended to: a second abyss-model on the same
#      directory adds to it, never truncates it;
#   4. the HTTP backend (llama-server's wire) is called as llama-server is:
#      a POST to /v1/chat/completions carrying the agent's request — here a
#      canned server made of nc(1), so the far end is not ours either;
#   5. `abyss-model tier` reads the machine.
#
# Usage: abyss/tests/live-model.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
bin="$root/.build/debug/abyss-model"
[ -x "$bin" ] || swift build --product abyss-model
command -v curl >/dev/null || { echo "FAIL: curl not installed — it is the independent client"; exit 1; }

work=$(mktemp -d /tmp/abyss-model.XXXXXX)
cleanup() { for p in ${mp:-} ${np:-}; do kill "$p" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

# A canned completion: a tool call, and 300 tokens of usage.
cat > "$work/stub.json" <<'J'
[{"id":"r1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"menu.activate","arguments":"{\"path\":[\"File\",\"Save\"]}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":290,"completion_tokens":10,"total_tokens":300}}]
J
ask='{"model":"default","messages":[{"role":"user","content":"save the document"}],"tools":[{"type":"function","function":{"name":"menu.activate","parameters":{"type":"object"}}}]}'

start() { # SESSION BUDGET BACKEND-ARGS...
    s=$1; b=$2; shift 2
    "$bin" serve --listen "$work/model.sock" --session "$s" --budget "$b" --transcript "$work/sessions/$s" "$@" \
        > "$work/model.log" 2>&1 3>&- 4>&- 5>&- &
    mp=$!
    i=0; while ! grep -q '^ready' "$work/model.log" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done
    grep -q '^ready' "$work/model.log" || fail "abyss-model did not start: $(cat "$work/model.log")"
}
stop() { kill "$mp" 2>/dev/null; wait "$mp" 2>/dev/null || true; mp=; rm -f "$work/model.sock"; }
call() { curl -sS --unix-socket "$work/model.sock" -o "$work/body" -w '%{http_code}' \
         -H 'Content-Type: application/json' -d "$ask" http://localhost/v1/chat/completions; }

# ---- 1. a completion, through an OpenAI client -------------------------------
start a1 500 --stub "$work/stub.json"
code=$(call)
[ "$code" = 200 ] || fail "the first call got $code: $(cat "$work/body")"
grep -q '"name":"menu.activate"' "$work/body" || fail "the tool call did not come through: $(cat "$work/body")"
grep -q '"total_tokens":300' "$work/body" || fail "the usage did not come through: $(cat "$work/body")"
echo "ok: 1. curl, as an OpenAI client over the unix socket, got the completion and its tool call"

# ---- 2. the budget stops the next call ---------------------------------------
[ "$(call)" = 200 ] || fail "the second call (300 of 500 used) was refused"
code=$(call)
[ "$code" = 429 ] || fail "the third call (600 of 500 used) got $code, not 429"
grep -q "the session's budget of 500 tokens is spent (600 used)" "$work/body" || fail "the refusal does not say why: $(cat "$work/body")"
t="$work/sessions/a1/transcript.jsonl"
[ "$(grep -c '"kind":"request"' "$t")" = 2 ] || fail "the refused call was sent on: $(cat "$t")"
grep -q '"kind":"refused","budget":500,"reason":"budget"' "$t" || fail "the transcript has no refusal: $(tail -1 "$t")"
grep -q 'refused: budget (600 of 500)' "$work/model.log" || fail "abyss-model did not say it refused: $(cat "$work/model.log")"
echo "ok: 2. the budget stopped the next call with its reason, and that call was sent nowhere"

# ---- 3. the transcript: lines, mode, append-only -----------------------------
[ "$(wc -l < "$t" | tr -d ' ')" = 5 ] || fail "expected 5 transcript lines: $(cat "$t")"
case "$(uname)" in FreeBSD) mode=$(stat -f %Lp "$t"); dmode=$(stat -f %Lp "$work/sessions/a1") ;;
                   *)       mode=$(stat -c %a "$t");  dmode=$(stat -c %a "$work/sessions/a1") ;; esac
[ "$mode" = 600 ] && [ "$dmode" = 700 ] || fail "the transcript is $mode in a $dmode directory, not 600 in 700"
grep -q '"content":"save the document"' "$t" || fail "the transcript does not keep what was asked"
stop
start a1 500 --stub "$work/stub.json"
[ "$(call)" = 200 ] || fail "a new abyss-model on the session's directory refused (budgets are per process, for now)"
[ "$(wc -l < "$t" | tr -d ' ')" = 7 ] || fail "a restart rewrote the transcript instead of appending: $(wc -l < "$t") lines"
stop
echo "ok: 3. one JSON line per event, 0600 in 0700, and a restart appended rather than truncated"

# ---- 4. the HTTP backend, against a server that is not ours -------------------
port=$((20000 + $$ % 20000))
tr -d '\n' < "$work/stub.json" | sed 's/^\[//; s/\]$//' > "$work/reply.json"
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' \
    "$(wc -c < "$work/reply.json" | tr -d ' ')" | cat - "$work/reply.json" > "$work/canned.http"
# nc half-closes when the reply is sent, and goes on reading the request (or
# the close would reset it): ncat does so by default, FreeBSD's nc with -N.
if nc -h 2>&1 | grep -q Ncat; then ncopt=; else ncopt=-N; fi
nc -l ${ncopt} 127.0.0.1 "$port" < "$work/canned.http" > "$work/llama-got" 2>/dev/null &
np=$!
sleep 0.3
start b1 1000 --backend "http://127.0.0.1:$port"
code=$(call)
[ "$code" = 200 ] || fail "through the HTTP backend: $code $(cat "$work/body") / $(cat "$work/model.log")"
grep -q '"name":"menu.activate"' "$work/body" || fail "the backend's tool call did not come back"
head -1 "$work/llama-got" | grep -q '^POST /v1/chat/completions HTTP/1.1' || fail "the backend was not asked as llama-server is: $(head -1 "$work/llama-got")"
grep -q '"content":"save the document"' "$work/llama-got" || fail "the backend did not get the agent's request"
grep -q '"kind":"reply".*"used":300' "$work/sessions/b1/transcript.jsonl" || fail "the backend's usage was not counted"
stop
echo "ok: 4. the HTTP backend asked a server that is not ours, as llama-server is asked, and counted what it used"

# ---- 5. the tier --------------------------------------------------------------
tier=$("$bin" tier)
echo "$tier" | grep -Eq '^vram=(none|[0-9]+M) ram=[1-9][0-9]*M tier=(cpu|gpu8|gpu12|gpu24) proposed=' || fail "tier: $tier"
echo "ok: 5. $tier"
echo "all green (one wire to a model, its budget stops the next call, and its transcript only grows)."
