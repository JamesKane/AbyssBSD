#!/bin/sh
# AbyssBSD Swift DE — agent presence (PHASE18 P18.13b).
#
# A session waiting for a yes is visible without hunting for its window: its
# state (working, waiting, idle) on the Dock's Agent tile, the menu bar's
# Agent item, and the island menu. Real processes: a compositor (with its
# privileged socket), abyss-jaild as root, the keeper, abyss-model with a
# slowed stub, abyss-agent in its jail, the menu bar, the Dock and the Agent
# window; a virtual pointer and keyboard. FreeBSD only; needs sudo. Claims:
#
#   1. no session: no Agent item; System ▸ Agent… is there, and enabled;
#   2. chosen, it opens the Agent window, whose session is idle: the item says
#      "Agent";
#   3. a question out: "Agent: Working" in the bar, "…" on the tile;
#   4. the budget's requester up: "Agent: Waiting" with its dot, a count on
#      the tile, and the island menu names that window "Waiting for you"
#      (the compositor says which process owns it); the Agent item's menu
#      lists the session, and choosing it goes to the window;
#   5. Stop: the session ends, and the item and the badge go;
#   6. an Agent window killed outright: its presence goes too;
#   7. agents turned off: no item, whatever a presence file says.
#
# Usage: abyss/tests/live-agent-presence.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent AquaDemo undertow abyssmenu; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-pr.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u) me=$(id -un)
export XDG_RUNTIME_DIR="$W/xdg" ABYSS_RUNTIME_DIR="$W/xdg" ABYSS_CONFIG_DIR="$W/config" HOME="$W/home"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$ABYSS_CONFIG_DIR" "$HOME"
aqua="$root/.build/debug/AquaDemo"
SW=1024 SH=768

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  pkill -f "AQUA_SCENE=agent" 2>/dev/null || true
  for p in ${a2:-} ${bar:-} ${dock:-} ${vp:-} ${vk:-} ${kp:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(pgrep -f "^$aqua" || true); do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-model serve --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in bar.log dock.log keeper.log; do tail -5 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }

# The stub: a tool call, then an answer; 100 tokens a reply and a budget of
# 50, so the first question's second request is stopped by the budget, and
# its requester comes up. Each reply takes 1.5 s: long enough to see working.
cat > "$W/stub.json" <<J
[{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
  {"id":"c1","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\"/home/$me\"}"}}]}}],
  "usage":{"total_tokens":100}},
 {"choices":[{"index":0,"message":{"role":"assistant","content":"Done."}}],"usage":{"total_tokens":100}}]
J
printf '[agent]\nmodel = stub:%s\nbudget = 50\n' "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"
: > "$ABYSS_CONFIG_DIR/agents.ini"   # agents on (P18.13a)
printf '[islands]\nanimate = no\n' > "$ABYSS_CONFIG_DIR/islands.ini"

for t in pointer keyboard; do
  xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
  [ $t = keyboard ] && xml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
  wayland-scanner client-header "$xml" "$W/v$t-proto.h"; wayland-scanner private-code "$xml" "$W/v$t-proto.c"
done
cc -I"$W" abyss/tests/vpointer.c "$W/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$W/vpointer" || fail "no vpointer"
cc -I"$W" abyss/tests/vkeyboard.c "$W/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$W/vkeyboard" || fail "no vkeyboard"

sudo "$W/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" > "$W/jd.log" 2>&1 3>&- 4>&- &
await "$W/jd.log" 'answering at' "the daemon did not start"
priv="abyss-pr-priv-$$"
env -u WAYLAND_DISPLAY .build/debug/undertow run --frames 0 --width $SW --height $SH --config-dir "$ABYSS_CONFIG_DIR" \
    --privileged-socket "$priv" > "$W/ut.out" 2> "$W/ut.err" 3>&- 4>&- & ut=$!
await "$W/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
wd="$(grep -m1 '^WAYLAND_DISPLAY=' "$W/ut.out" | cut -d= -f2-)"
export WAYLAND_DISPLAY="$wd"
env ABYSS_MODEL_STUB_DELAY=1500 .build/debug/abyss-jail --socket "$SOCK" serve > "$W/keeper.log" 2>&1 3>&- 4>&- & kp=$!
await "$W/keeper.log" '^jails: ready' "the keeper did not start"
env WAYLAND_DISPLAY="$priv" AQUA_SCENE=menubar ABYSS_APP_WAYLAND_DISPLAY="$wd" ABYSS_APP_BINARY="$aqua" \
    "$aqua" > "$W/bar.log" 2>&1 3>&- 4>&- & bar=$!
await "$W/bar.log" 'MenuBar: titles ' "the bar never drew"
printf '[dock]\napps = finder agent\n' > "$ABYSS_CONFIG_DIR/dock.ini"
env AQUA_SCENE=dock "$aqua" > "$W/dock.log" 2>&1 3>&- 4>&- & dock=$!
await "$W/dock.log" 'Dock: tiles ' "the Dock never drew"
mkfifo "$W/pointer" "$W/keys"
"$W/vpointer" $SW $SH < "$W/pointer" > "$W/vp.log" 2>&1 & vp=$!
exec 3> "$W/pointer"
"$W/vkeyboard" < "$W/keys" > "$W/vk.log" 2>&1 & vk=$!
exec 4> "$W/keys"
sleep 1

title_at() { grep -F 'MenuBar: titles ' "$W/bar.log" | tail -1 | tr ' ' '\n' | grep "^$1@" | head -1 | cut -d@ -f2 | tr ',' ' '; }
item_line() {  # item_line MENU TITLE — the row TITLE after the last "opened MENU"
  awk -v m="MenuBar: opened $1" 'index($0, m) { buf = ""; on = 1; next }
       on && /MenuBar: item / { buf = buf $0 "\n"; next }
       on { on = 0 } END { printf "%s", buf }' "$W/bar.log" | grep -F "$2" | tail -1
}
xy_of() { printf '%s' "$1" | sed -n "s/.* at \([0-9]*\),\([0-9]*\).*/\1 \2/p"; }
click() { printf 'm %s %s\np\nr\n' $1 $2 >&3; sleep 0.6; }
agent_item() { grep 'MenuBar: agent item ' "$W/bar.log" | tail -1 | sed 's/.*MenuBar: agent item //'; }
await_item() {  # await_item LABEL|none WHY
  i=0; until case "$(agent_item)" in "'$1' at "*|"$1") true ;; *) false ;; esac; do
    [ $i -ge 100 ] && fail "$2 (the item: $(agent_item))"; sleep 0.1; i=$((i + 1)); done
}

# ---- 1. no session ------------------------------------------------------------------
await_item none "with no session, there is an Agent item"
click $(title_at System)
await "$W/bar.log" 'MenuBar: opened System' "the System menu did not open"
r=$(item_line System "'Agent…'")
case "$r" in *" enabled system.agent") ;; *) fail "System ▸ Agent… is not there and enabled: '$r'" ;; esac
echo "ok: 1. no session, no Agent item; System ▸ Agent… is there, enabled"

# ---- 2. chosen: the window, idle ------------------------------------------------------
click $(xy_of "$r")
await "$W/bar.log" 'chose System > Agent… (system.agent) → ok' "choosing Agent… did not open it"
await "$W/ut.out" '^window org.abyssbsd.agent/' "no Agent window on the screen"
await_item "Agent" "the session open and idle, the item does not say Agent"
apid=$(grep 'MenuBar: agents: ' "$W/bar.log" | tail -1 | sed -n 's/.*agents: \([0-9]*\)=idle.*/\1/p')
[ -n "$apid" ] || fail "the bar did not read an idle session: $(grep 'MenuBar: agents: ' "$W/bar.log" | tail -1)"
echo "ok: 2. System ▸ Agent… opened the window (pid $apid); its session idle, the item says Agent"

# ---- 3. working ---------------------------------------------------------------------------
.build/debug/abyssmenu run agent agent.question "text=what is here" > /dev/null 2>&1 || fail "the question was refused"
await_item "Agent: Working" "a question out, the item does not say Working"
await "$W/dock.log" 'Dock: agent badge: working' "a question out, the tile has no working badge"
echo "ok: 3. a question out: 'Agent: Working' in the bar, … on the tile"

# ---- 4. waiting -----------------------------------------------------------------------------
await_item "Agent: Waiting" "the budget's requester up, the item does not say Waiting"
await "$W/dock.log" 'Dock: agent badge: waiting(1)' "the requester up, the tile does not count one waiting"
click $(xy_of "$(grep "MenuBar: island item '1' at " "$W/bar.log" | tail -1)")
await "$W/bar.log" 'MenuBar: opened Islands' "the island item did not open its menu"
row=$(item_line Islands "Agent — ")
case "$row" in *"'        Agent — Waiting for you'"*) ;; *) fail "the island menu does not say the Agent window waits: '$row'" ;; esac
printf 'k 1\n' >&4; sleep 0.5    # Escape
xy=$(agent_item | sed 's/.* at \([0-9]*\),\([0-9]*\)/\1 \2/')
click $xy
await "$W/bar.log" 'MenuBar: opened Agent' "the Agent item did not open its menu"
r=$(item_line Agent "'Waiting for you: Allow more tokens?'")
case "$r" in *" enabled agent.go.$apid") ;; *) fail "the Agent menu does not list the waiting session: '$r'" ;; esac
click $(xy_of "$r")
await "$W/bar.log" "chose Agent > Waiting for you: Allow more tokens? (agent.go.$apid) → ok, window " "choosing the session did not go to its window"
echo "ok: 4. waiting: the item and its dot, a count on the tile; the island menu names the window; the Agent menu goes to it"

# ---- 5. Stop: none -----------------------------------------------------------------------------
.build/debug/abyssmenu run agent agent.stop > /dev/null 2>&1 || fail "Stop was refused"
await_item none "the session ended, the item stays"
await "$W/dock.log" 'Dock: agent badge: none' "the session ended, the badge stays"
[ -z "$(ls "$XDG_RUNTIME_DIR/agents")" ] || fail "a presence file is left: $(ls "$XDG_RUNTIME_DIR/agents")"
echo "ok: 5. Stop: the session ended; the item and the badge are gone, and so is its file"

# ---- 6. killed outright -----------------------------------------------------------------------------
pkill -f "AQUA_SCENE=agent" 2>/dev/null || true
env AQUA_SCENE=agent "$aqua" > "$W/app2.log" 2>&1 3>&- 4>&- & a2=$!
await_item "Agent" "a second window's session, idle, is not shown"
kill -9 "$a2"; a2=
await_item none "a window killed outright: its presence stays"
echo "ok: 6. an Agent window killed outright: its presence went with it"

# ---- 7. off ----------------------------------------------------------------------------------------
printf 'waiting\nAllow?\n' > "$XDG_RUNTIME_DIR/agents/$$"
await_item "Agent: Waiting" "a presence file (this shell's) is not shown with agents on"
rm "$ABYSS_CONFIG_DIR/agents.ini"
await_item none "agents off, the item stays"
rm -f "$XDG_RUNTIME_DIR/agents/$$"
echo "ok: 7. agents off: no item, whatever a presence file says"
echo "all green (presence: working, waiting and idle on the Dock tile, the menu bar and the island menu; gone when the session is)."
