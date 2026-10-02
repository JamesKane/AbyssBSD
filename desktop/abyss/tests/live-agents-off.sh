#!/bin/sh
# AbyssBSD Swift DE — off is one file, absent (PHASE18 P18.13a).
#
# A new account has no agents.ini, so no agents: the keeper starts none, the
# chord is the application's, and a crash is reported without Ask the Agent.
# System Preferences ▸ Agents turns them on (writes the file) and off
# (removes it). Real processes: a compositor, abyss-jaild, the keeper,
# System Preferences, the Agent window, Crash Reporter; driven by a virtual
# keyboard and pointer. FreeBSD only; needs sudo. Claims:
#
#   1. off: an agent session is refused in words, ⌥⌘A opens nothing (the
#      compositor lets the key through), and a crash offers only OK;
#   2. the Agents pane's "Let agents run on this computer", clicked, writes
#      agents.ini;
#   3. on: ⌥⌘A opens the Agent window, which gets a session; a crash offers
#      Ask the Agent;
#   4. clicked again, it removes the file, and a new session is refused.
#
# Usage: abyss/tests/live-agents-off.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for b in abyss-jaild abyss-jail abyss-model abyss-agent abyss-vocab abyss-fetch AquaDemo undertow abyssmenu abyss-dbus; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-off.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u) me=$(id -un)
export XDG_RUNTIME_DIR="$W/xdg" ABYSS_RUNTIME_DIR="$W/xdg" ABYSS_CONFIG_DIR="$W/config" HOME="$W/home"
export PATH="$root/.build/debug:$PATH"   # the compositor opens Agent as AquaDemo, from PATH
mkdir -m 700 "$XDG_RUNTIME_DIR" "$ABYSS_CONFIG_DIR" "$HOME"
SW=1024 SH=768

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  pkill -x AquaDemo 2>/dev/null || true
  for p in ${pp:-} ${vp:-} ${vk:-} ${kp:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E "^abyss-$uid-" || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  for p in $(pgrep -f "abyss-(model|vocab|fetch) serve --listen $RB" || true) $(pgrep -f "endpoint --listen $RB" || true); do kill "$p" 2>/dev/null || true; done
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in keeper.log prefs.log ut.out; do tail -5 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }

cat > "$W/stub.json" <<'J'
[{"choices":[{"index":0,"message":{"role":"assistant","content":"Hello."}}],"usage":{"total_tokens":10}}]
J
printf '[agent]\nmodel = stub:%s\n[debug]\nmodel = stub:%s\n' "$W/stub.json" "$W/stub.json" > "$ABYSS_CONFIG_DIR/jails.ini"
cc -g -O0 abyss/tests/crasher.c -o "$W/crasher" || fail "cannot build the crasher"

for t in pointer keyboard; do
  xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
  [ $t = keyboard ] && xml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
  wayland-scanner client-header "$xml" "$W/v$t-proto.h"; wayland-scanner private-code "$xml" "$W/v$t-proto.c"
done
cc -I"$W" abyss/tests/vpointer.c "$W/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$W/vpointer" || fail "no vpointer"
cc -I"$W" abyss/tests/vkeyboard.c "$W/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$W/vkeyboard" || fail "no vkeyboard"

sudo "$W/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" > "$W/jd.log" 2>&1 3>&- 4>&- &
await "$W/jd.log" 'answering at' "the daemon did not start"
mkdir -p "$W/cfg"
env -u WAYLAND_DISPLAY .build/debug/undertow run --frames 0 --width $SW --height $SH --config-dir "$ABYSS_CONFIG_DIR" \
    > "$W/ut.out" 2> "$W/ut.err" 3>&- 4>&- & ut=$!
await "$W/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$W/ut.out" | cut -d= -f2-)"
.build/debug/abyss-jail --socket "$SOCK" serve > "$W/keeper.log" 2>&1 3>&- 4>&- & kp=$!
await "$W/keeper.log" '^jails: ready' "the keeper did not start"
env ABYSS_PREFS_DUMP=1 ABYSS_PREFS_PANE=agents AQUA_SCENE=sysprefs .build/debug/AquaDemo > "$W/prefs.log" 2>&1 3>&- 4>&- & pp=$!
await "$W/prefs.log" 'agents layout ' "the Agents pane did not draw"
mkfifo "$W/pointer" "$W/keys"
"$W/vpointer" $SW $SH < "$W/pointer" > "$W/vp.log" 2>&1 & vp=$!
exec 3> "$W/pointer"
"$W/vkeyboard" < "$W/keys" > "$W/vk.log" 2>&1 & vk=$!
exec 4> "$W/keys"
sleep 1
pos=$(grep '^window org.abyssbsd.preferences' "$W/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)
onoff=$(grep 'agents layout ' "$W/prefs.log" | tail -1 | tr ' ' '\n' | sed -n 's/^onoff=//p')
# The switch's row, at the centre the pane reported (window coordinates).
click_onoff() { printf 'm %s %s\np\nr\n' $((${pos%,*} + ${onoff%,*})) $((${pos#*,} + ${onoff#*,})) >&3; sleep 0.6; }
chord() { printf 'c 72 30\n' >&4; sleep 1; }   # Cmd (64) + Alt (8), and A
crash() {
  .build/debug/abyss-jail launch app -- "/home/$me/crasher" > /dev/null 2>&1 || fail "the crasher did not launch"
}

# ---- 1. off ------------------------------------------------------------------------
grep -q 'agents: off;' "$W/prefs.log" || fail "the pane does not say agents are off"
.build/debug/abyss-jail agent agent > "$W/a0" 2>&1 && fail "an agent session started with agents off"
grep -q 'agents are off: there is no agents.ini' "$W/a0" || fail "the refusal does not say why: $(cat "$W/a0")"
chord
grep -q '^window org.abyssbsd.agent' "$W/ut.out" && fail "⌥⌘A opened Agent with agents off"
grep -q 'keybind: Agent' "$W/ut.err" "$W/ut.out" && fail "the compositor took ⌥⌘A with agents off"
.build/debug/abyss-jail launch app -- /bin/true > /dev/null 2>&1 || fail "the app jail did not open"
cp "$W/crasher" "$HB/$me/app/"
crash
await "$W/keeper.log" 'CrashReport: buttons ' "the crash was not reported"
grep 'CrashReport: buttons ' "$W/keeper.log" | tail -1 | grep -q 'ask=' && fail "with agents off, the report offers Ask the Agent"
echo "ok: 1. off: a session is refused in words, ⌥⌘A is the application's, a crash offers only OK"
pkill -f 'AQUA_SCENE=crashreport' 2>/dev/null || true

# ---- 2. on, from the pane --------------------------------------------------------------
click_onoff
await "$W/prefs.log" 'agents: Agents are on.' "the checkbox did not turn agents on"
[ -f "$ABYSS_CONFIG_DIR/agents.ini" ] || fail "no agents.ini after turning them on"
echo "ok: 2. \"Let agents run on this computer\", clicked, wrote agents.ini"

# ---- 3. on: the chord, a session, Ask the Agent ------------------------------------------
chord
i=0; until grep -q '^window org.abyssbsd.agent' "$W/ut.out" || [ $i -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
grep -q '^window org.abyssbsd.agent' "$W/ut.out" || fail "⌥⌘A did not open Agent with agents on"
await "$W/keeper.log" 'jails: agent session .* in abyss-[0-9]*-agent' "the Agent window got no session"
crash
await "$W/keeper.log" 'CrashReport: buttons .*ask=' "with agents on, the report does not offer Ask the Agent"
echo "ok: 3. on: ⌥⌘A opened Agent, which got a session; a crash offers Ask the Agent"

# ---- 4. off again --------------------------------------------------------------------------
click_onoff
await "$W/prefs.log" 'agents: Agents are off.' "the checkbox did not turn agents off"
[ -f "$ABYSS_CONFIG_DIR/agents.ini" ] && fail "agents.ini is still there"
.build/debug/abyss-jail agent agent > "$W/a1" 2>&1 && fail "a session started after agents were turned off"
grep -q 'agents are off' "$W/a1" || fail "the refusal does not say why: $(cat "$W/a1")"
echo "ok: 4. clicked again: agents.ini is gone, and a new session is refused"
echo "all green (off is one file, absent: no session, no chord, no Ask; on and off from the pane)."
