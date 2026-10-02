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
#   5. `abyss-model tier` reads the machine;
#   6. `--local` runs llama-server itself (a stand-in, fake-llama-server.sh):
#      on a unix socket in a 0700 directory, never a TCP port, with tool
#      calling on, and is ready only once the server is healthy;
#   7. a server that dies mid-session is a 502 that says so;
#   8. stopping abyss-model stops the server — and on FreeBSD, so does
#      abyss-model being killed outright (a process descriptor);
#   9. a model that fails to load fails abyss-model, with the server's words;
#  10. with ABYSS_TEST_GGUF set to a real model, the real llama-server answers
#      a tool-calling request with a tool call (the measurement, PHASE18 §6b.1).
#
# Usage: abyss/tests/live-model.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
bin="$root/.build/debug/abyss-model"
[ -x "$bin" ] || swift build --product abyss-model
command -v curl >/dev/null || { echo "FAIL: curl not installed — it is the independent client"; exit 1; }

work=$(mktemp -d /tmp/abyss-model.XXXXXX)
cleanup() {
    for p in ${mp:-} ${np:-}; do kill "$p" 2>/dev/null || true; done
    [ -f "$work/fake.pid" ] && kill "$(cat "$work/fake.pid")" 2>/dev/null || true
    rm -rf "$work"
}
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

# ---- 6. --local: llama-server, run by abyss-model ------------------------------
fake="$root/abyss/tests/fake-llama-server.sh"
export FAKE_LLAMA_REPLY="$work/canned.http" FAKE_LLAMA_STATE="$work/fake"
: > "$work/model.gguf"
start c1 1000 --local "$work/model.gguf" --llama-server "$fake"
argv=$(cat "$work/fake.argv")
case "$argv" in *"-m $work/model.gguf "*) ;; *) fail "llama-server was not given the model: $argv" ;; esac
case "$argv" in *"--host $work/sessions/c1/llama/llama.sock "*) ;; *) fail "llama-server is not on abyss-model's private socket: $argv" ;; esac
case "$argv" in *--port*) fail "llama-server was given a TCP port: $argv" ;; esac
case "$argv" in *--jinja*) ;; *) fail "llama-server was started without its chat template (no tool calls): $argv" ;; esac
case "$(uname)" in FreeBSD) lmode=$(stat -f %Lp "$work/sessions/c1/llama") ;; *) lmode=$(stat -c %a "$work/sessions/c1/llama") ;; esac
[ "$lmode" = 700 ] || fail "llama-server's socket directory is $lmode, not 700"
sleep 0.3   # the stand-in re-arms nc between connections; the real server does not need this
code=$(call)
[ "$code" = 200 ] || fail "through --local: $code $(cat "$work/body") / $(cat "$work/model.log")"
grep -q '"name":"menu.activate"' "$work/body" || fail "the local server's tool call did not come back"
grep -q '"model":"default"' "$work/sessions/c1/transcript.jsonl" || fail "the transcript lost the request"
echo "ok: 6. --local ran llama-server on a private unix socket (no port, 0700, --jinja), and answered through it"

# ---- 7. the server dies mid-session ---------------------------------------------
kill "$(cat "$work/fake.pid")"
sleep 0.3
code=$(call)
[ "$code" = 502 ] || fail "a dead llama-server gave $code, not 502"
grep -q 'llama-server exited 0' "$work/body" || fail "the 502 does not say the server exited: $(cat "$work/body")"
grep -q '"kind":"failed"' "$work/sessions/c1/transcript.jsonl" || fail "the failure is not in the transcript"
stop
echo "ok: 7. a server that died mid-session is a 502 that says it exited, and is in the transcript"

# ---- 8. abyss-model's end is the server's end -------------------------------------
rm -f "$work/fake.stopped" "$work/fake.pid"
start c2 1000 --local "$work/model.gguf" --llama-server "$fake"
fp=$(cat "$work/fake.pid")
kill -TERM "$mp"; wait "$mp" 2>/dev/null || true; mp=
i=0; while kill -0 "$fp" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
kill -0 "$fp" 2>/dev/null && fail "llama-server outlived abyss-model's SIGTERM"
[ -f "$work/fake.stopped" ] || fail "llama-server was killed, not stopped (no SIGTERM reached it)"
how="SIGTERM stopped it"
if [ "$(uname)" = FreeBSD ]; then
    rm -f "$work/fake.pid"
    start c3 1000 --local "$work/model.gguf" --llama-server "$fake"
    fp=$(cat "$work/fake.pid")
    kill -KILL "$mp"; wait "$mp" 2>/dev/null || true; mp=
    i=0; while kill -0 "$fp" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
    kill -0 "$fp" 2>/dev/null && fail "llama-server outlived abyss-model's SIGKILL (the process descriptor did not take it)"
    how="$how, and SIGKILL took it too (process descriptor)"
fi
rm -f "$work/model.sock"
echo "ok: 8. abyss-model's end was llama-server's: $how"

# ---- 9. a model that will not load ----------------------------------------------
# In the background, with a deadline: an abyss-model that wrongly goes on to
# serve must fail this test, not hang it.
FAKE_LLAMA_DIE=1 "$bin" serve --listen "$work/model.sock" --session d1 --budget 10 \
    --transcript "$work/sessions/d1" --local "$work/model.gguf" --llama-server "$fake" > "$work/die.log" 2>&1 3>&- 4>&- 5>&- &
dp=$!
i=0; while kill -0 "$dp" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
if kill -0 "$dp" 2>/dev/null; then kill "$dp"; fail "abyss-model went on serving with a model that did not load"; fi
wait "$dp" && fail "abyss-model exited 0 with a model that did not load"
grep -q 'llama-server exited 3 before it was ready: .*not a GGUF' "$work/die.log" || fail "the failure does not carry the server's words: $(cat "$work/die.log")"
echo "ok: 9. a model that would not load failed abyss-model with llama-server's own words"

# ---- 10. a real model, if one is given -------------------------------------------
if [ -n "${ABYSS_TEST_GGUF:-}" ]; then
    rm -f "$work/model.sock"
    t0=$(date +%s)
    start e1 100000 --local "$ABYSS_TEST_GGUF" ${ABYSS_TEST_CONTEXT:+--context "$ABYSS_TEST_CONTEXT"}
    t1=$(date +%s)
    ask='{"model":"default","messages":[{"role":"system","content":"You operate a desktop through tools. Call a tool when one fits."},{"role":"user","content":"Save the document I am editing."}],"tools":[{"type":"function","function":{"name":"menu_activate","description":"Choose a menu item in the focused application, by its path from the menu bar.","parameters":{"type":"object","properties":{"path":{"type":"array","items":{"type":"string"},"description":"e.g. [\"File\", \"Save\"]"}},"required":["path"]}}}],"temperature":0}'
    code=$(call)
    t2=$(date +%s)
    [ "$code" = 200 ] || fail "the real model: $code $(cat "$work/body")"
    grep -q '"name":"menu_activate"' "$work/body" || fail "the real model did not call the tool: $(cat "$work/body")"
    grep -q 'Save' "$work/body" || fail "the real model called the tool without Save: $(cat "$work/body")"
    used=$(grep '"kind":"reply"' "$work/sessions/e1/transcript.jsonl" | sed 's/.*"used":\([0-9]*\).*/\1/')
    timings=$(grep -o '"predicted_per_second":[0-9.]*' "$work/body" | head -1)
    stop
    echo "ok: 10. $(basename "$ABYSS_TEST_GGUF") called menu_activate([File, Save]): loaded in $((t1-t0))s, answered in $((t2-t1))s, $used tokens${timings:+, $timings}"
else
    echo "skip: 10. no ABYSS_TEST_GGUF — the real model is measured where one is (PHASE18 §6b.1)"
fi
echo "all green (one wire to a model, its budget stops the next call, and its transcript only grows)."
