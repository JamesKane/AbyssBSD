#!/bin/sh
# AbyssBSD Swift DE — the Setup Assistant at an account's first login
# (PHASE16 P16.7).
#
# A real session under anchor, with a fresh config directory for each
# "account". Claims:
#
#   1. a first login: anchor starts the assistant, once, after the session;
#   2. walked through — Return, Return, Trench chosen with a click, Return,
#      Return — the theme is written where the General pane reads it
#      (appearance.ini), setup.ini says finished, and the assistant closes;
#   3. the second login goes straight to the desktop: no assistant;
#   4. another first login, skipped: setup.ini says skipped, appearance.ini
#      untouched;
#   5. closed without either: nothing is written, and the next login asks again.
#
# Usage: abyss/tests/live-setup.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

bin="$root/.build/debug"
for b in undertow AquaDemo anchor abyssctl; do [ -x "$bin/$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-setup.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in ${an:-} ${vk:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  sleep 0.3; rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; grep -E 'anchor:|Setup Assistant' "$work/session.log" 2>/dev/null | tail -6 | sed 's/^/  session| /'; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 150 ]; do i=$((i + 1)); sleep 0.1; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }

for x in vpointer:wlr-virtual-pointer-unstable-v1 vkeyboard:virtual-keyboard-unstable-v1; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$root/abyss/tests/$f.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$f.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"

env -u WAYLAND_DISPLAY "$bin/undertow" run --hz 60 --frames 0 --width 1024 --height 768 \
    --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never came up"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)
export WAYLAND_DISPLAY="$wd"
mkfifo "$work/vp" "$work/vk"
"$work/vpointer" 1024 768 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"

# login CFG: a session for the "account" whose config directory is CFG.
login() {
  [ -n "${an:-}" ] && { ABYSS_RUNTIME_DIR="$work/rt" "$bin/abyssctl" quit > /dev/null 2>&1 || true; wait "$an" 2>/dev/null || true; }
  mkdir -p "$work/rt" "$1"; chmod 700 "$work/rt"; : > "$work/session.log"
  ABYSS_CONFIG_DIR="$1" "$bin/anchor" --display "$wd" --runtime-dir "$work/rt" --binary "$bin/AquaDemo" \
      --without bus --without portal --without bridge --without menus --without dock --without menubar \
      > "$work/session.log" 2>&1 &
  an=$!
  await "$work/session.log" "anchor: session is live" "the session never came up"
}
page() { await "$work/session.log" "Setup Assistant: page $1" "the assistant did not show $1" "${2:-1}"; }
at() { grep "Setup Assistant: page " "$work/session.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p"; }
click() {
  # Windows are reported after undertow's warm-up (§2.83): wait for this one's line.
  await "$work/ut.out" '^window org.abyssbsd.setupassistant' "undertow never reported the assistant's window"
  geom=$(grep '^window org.abyssbsd.setupassistant' "$work/ut.out" | tail -1 | awk '{print $(NF-1)}')
  p=$(at "$1"); [ -n "$geom" ] && [ -n "$p" ] || fail "cannot find $1 on the assistant"
  printf 'm %s %s\np\nr\n' $(( ${geom%,*} + ${p%,*} )) $(( ${geom#*,} + ${p#*,} )) >&3; sleep 0.3
}

# ------------------------------------------------------------ 1. first login
cfg1="$work/cfg-ada"
login "$cfg1"
await "$work/session.log" "anchor: the Setup Assistant is up (first login)" "anchor did not start the assistant at a first login"
page Welcome
echo "ok: 1. a first login: anchor started the Setup Assistant"

# ------------------------------------------------------------ 2. walked through
sleep 0.5; printf 'k 28\n' >&4; page Network
printf 'k 28\n' >&4; page Appearance
sleep 0.3; click theme.trench
await "$work/session.log" "Setup Assistant: theme trench chosen" "choosing Trench did nothing"
grep -q '^theme *= *trench' "$cfg1/appearance.ini" || fail "appearance.ini: $(cat "$cfg1/appearance.ini" 2>/dev/null)"
printf 'k 28\n' >&4; page "All Set"
printf 'k 28\n' >&4
await "$work/session.log" "Setup Assistant: done (finished)" "Start Using AbyssBSD did not finish"
await "$work/session.log" "anchor: the Setup Assistant has closed" "the assistant did not close"
grep -q '^how *= *finished' "$cfg1/setup.ini" || fail "setup.ini: $(cat "$cfg1/setup.ini" 2>/dev/null)"
echo "ok: 2. walked through: Trench written to appearance.ini, setup.ini finished, and it closed"

# ------------------------------------------------------------ 3. the next login
login "$cfg1"
sleep 2
grep -q "Setup Assistant" "$work/session.log" && fail "the assistant came back at the second login"
echo "ok: 3. the second login: straight to the desktop"

# ------------------------------------------------------------ 4. skipped
cfg2="$work/cfg-bob"
login "$cfg2"
page Welcome
sleep 0.5; click skip
await "$work/session.log" "Setup Assistant: done (skipped)" "Skip Setup did not say so"
grep -q '^how *= *skipped' "$cfg2/setup.ini" || fail "setup.ini: $(cat "$cfg2/setup.ini" 2>/dev/null)"
[ ! -e "$cfg2/appearance.ini" ] || fail "skipping wrote appearance.ini"
echo "ok: 4. skipped: setup.ini says so, and nothing else was written"

# ------------------------------------------------------------ 5. closed
cfg3="$work/cfg-cy"
login "$cfg3"
page Welcome
sleep 0.5
await "$work/ut.out" '^window org.abyssbsd.setupassistant' "undertow never reported the assistant's window"
geom=$(grep '^window org.abyssbsd.setupassistant' "$work/ut.out" | tail -1 | awk '{print $(NF-1)}')
printf 'm %s %s\np\nr\n' $(( ${geom%,*} + 16 )) $(( ${geom#*,} + 11 )) >&3      # the close light
await "$work/session.log" "Setup Assistant: closed — it asks again next time" "closing did not say it would ask again"
[ ! -e "$cfg3/setup.ini" ] || fail "closing wrote setup.ini"
login "$cfg3"
await "$work/session.log" "anchor: the Setup Assistant is up (first login)" "after a close, the next login did not ask again"
echo "ok: 5. closed without finishing: nothing written, and the next login asked again"
echo "all green (the Setup Assistant: once at a first login, its choices where the panes read them, then never again)."
