#!/bin/sh
# AbyssBSD Swift DE — measure a local model behind abyss-model (PHASE18 §6b.1).
#
# A candidate is a default only once it has run here: loaded by ports'
# llama-server under abyss-model, on this machine's GPU (or CPU), answering
# tool-calling requests in the desktop's own vocabulary. This runs five, one of
# which must be answered *without* a tool, and reports what it measured:
# whether each was right, how long the load and each answer took, tokens per
# second, and the device memory it took. The system prompt says which
# application is focused, as the agent runtime's will (it knows, from the menu
# bar); without it a careful model rightly asks.
#
# Thinking is off (the chat template's enable_thinking): an agent's tool call
# should be quick, and a reasoning model can spend its whole reply thinking.
# MEASURE_THINKING=1 measures it with thinking on, and a larger reply.
#
# Usage: abyss/tests/measure-model.sh MODEL.gguf [ABYSS_MODEL [LLAMA_SERVER]]
# The client is curl if present, else nc(1) on the unix socket — never ours.
set -eu

model=$1
here=$(cd "$(dirname "$0")/../.." && pwd)
bin=${2:-$here/.build/debug/abyss-model}
server=${3:-}
work=$(mktemp -d /tmp/abyss-measure.XXXXXX)
cleanup() { [ -n "${mp:-}" ] && kill "$mp" 2>/dev/null; wait 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT INT TERM HUP

srv=${server:-$(command -v llama-server || echo /usr/local/bin/llama-server)}
# Free device memory, as Vulkan reports it — before the load and during it.
devfree() { "$srv" --list-devices 2>&1 | sed -n 's/.*Vulkan0: \(.*\) (\([0-9]*\) MiB, \([0-9]*\) MiB free).*/\3/p' | head -1; }
free0=$(devfree)
t0=$(date +%s)
"$bin" serve --listen "$work/m.sock" --session measure --budget 1000000 --transcript "$work/t" \
    --local "$model" ${server:+--llama-server "$server"} > "$work/log" 2>&1 3>&- 4>&- 5>&- &
mp=$!
while ! grep -q '^ready' "$work/log" 2>/dev/null; do
    kill -0 "$mp" 2>/dev/null || { echo "FAIL: abyss-model: $(cat "$work/log")"; exit 1; }
    sleep 0.5
done
t1=$(date +%s)

post() { # BODY-FILE -> response body on stdout
    if command -v curl >/dev/null; then
        curl -sS --unix-socket "$work/m.sock" -H 'Content-Type: application/json' --data-binary @"$1" \
            http://localhost/v1/chat/completions
    else
        { printf 'POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' \
              "$(wc -c < "$1" | tr -d ' ')"; cat "$1"; } | nc -N -U "$work/m.sock" | sed '1,/^\r$/d'
    fi
}

tools='[{"type":"function","function":{"name":"menu_activate","description":"Choose a menu item in the focused application, by its path from the menu bar.","parameters":{"type":"object","properties":{"path":{"type":"array","items":{"type":"string"}}},"required":["path"]}}},{"type":"function","function":{"name":"open_path","description":"Open a file or folder in the Finder or its application.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},{"type":"function","function":{"name":"set_appearance","description":"Change a System Preferences appearance setting.","parameters":{"type":"object","properties":{"setting":{"type":"string","enum":["dark_mode","accent","font_size"]},"value":{"type":"string"}},"required":["setting","value"]}}},{"type":"function","function":{"name":"launch_app","description":"Start an application by name.","parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}]'

# prompt | expected tool ("none" for no tool) | a string the call must carry
cat > "$work/cases" <<'C'
Save the document I am editing.|menu_activate|Save
Open my Downloads folder.|open_path|Downloads
Turn on dark mode.|set_appearance|dark_mode
Start Firefox.|launch_app|Firefox
What is 12 times 12? Just tell me.|none|144
C

if [ -n "${MEASURE_THINKING:-}" ]; then think=true; max=2048; else think=false; max=256; fi
right=0; n=0; detail=
while IFS='|' read -r prompt want carry; do
    n=$((n + 1))
    printf '{"model":"default","temperature":0,"max_tokens":%s,"chat_template_kwargs":{"enable_thinking":%s},"messages":[{"role":"system","content":"You operate the AbyssBSD desktop through tools. The focused application is TextEdit. Call a tool when one fits; otherwise answer briefly."},{"role":"user","content":"%s"}],"tools":%s}' \
        "$max" "$think" "$prompt" "$tools" > "$work/req"
    a=$(date +%s)
    post "$work/req" > "$work/resp" || true
    f=$(devfree); [ -n "$f" ] && { [ -z "${low:-}" ] || [ "$f" -lt "$low" ]; } && low=$f
    b=$(date +%s)
    got=$(grep -o '"tool_calls":\[{[^]]*"name":"[a-z_]*"' "$work/resp" | sed 's/.*"name":"//; s/"$//' | head -1)
    [ -n "$got" ] || got=none
    tps=$(grep -o '"predicted_per_second":[0-9.]*' "$work/resp" | head -1 | cut -d: -f2 | cut -d. -f1)
    if [ "$got" = "$want" ] && grep -q "$carry" "$work/resp"; then ok=ok; right=$((right + 1)); else ok=WRONG; fi
    detail="$detail
  $ok  $prompt -> $got ($((b - a))s${tps:+, ${tps} tok/s})"
    [ $ok = ok ] || detail="$detail
       $(head -c 400 "$work/resp")"
done < "$work/cases"

free1=${low:-}   # the least free while it answered: what it really took
lp=$(pgrep -P "$mp" | head -1)
rss=$(ps -o rss= -p "$lp" 2>/dev/null | awk '{printf "%d", $1/1024}')
dev=$("$srv" --list-devices 2>&1 | sed -n 's/.*Vulkan0: \([^(]*\) (.*/\1/p' | head -1 | sed 's/ *$//')
if [ -n "$free0" ] && [ -n "$free1" ] && [ $((free0 - free1)) -gt 64 ]; then where="$((free0 - free1)) MiB of VRAM on $dev"; else where="CPU only"; fi
echo "$(basename "$model") (thinking $think): $right/$n right, loaded in $((t1 - t0))s, $where, llama-server resident ${rss:-?} MiB$detail"
[ "$right" = "$n" ]
