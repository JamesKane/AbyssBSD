#!/bin/sh
# AbyssBSD Swift DE — present on damage (BACKLOG M.1).
#
# undertow composed and committed a frame every vblank whatever had changed —
# sixty a second of identical frames on a static screen, every one a GPU pass
# and a flip it could miss. Now a frame is drawn only when what it would show
# differs from the last one presented (Scene.signature). The danger is the
# opposite mistake — a change that is not seen — so every kind is claimed:
#
#   1. a static screen presents nothing (a couple of frames in two seconds);
#   2. a client that repaints its SAME buffer (one shm buffer, as a toolkit
#      may keep) is drawn: the texture's pointer is unchanged, only its commit;
#   3. the pointer moving, and nothing else, is drawn;
#   4. a screenshot of a static screen completes (screencopy asks for a frame
#      through wlroots' needs_frame, and gets one).
#
# Usage: abyss/tests/live-damage.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
grab="$root/.build/debug/abyssgrab"
[ -x "$undertow" ] && [ -x "$grab" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-dmg.XXXXXX)
cleanup() {
  exec 3>&- 5>&- 2>/dev/null || true
  for p in ${wa:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"; grep '^presented' "$work/ut.out" 2>/dev/null | tail -3 | sed 's/^/  undertow| /'; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
presented() { grep '^presented ' "$work/ut.out" | tail -1 | awk '{print $2}'; }
# settle: wait until a "presented" report comes in, and return it.
tick() { n=$(count '^presented ' "$work/ut.out"); await "$work/ut.out" '^presented ' "undertow stopped reporting" $((n + 1)); presented; }
shot() { "$grab" "$work/$1.ppm" > "$work/grab.log" 2>&1 || fail "abyssgrab ($1): $(cat "$work/grab.log")"; }
has() {
  hdr=$(head -3 "$work/$1.ppm" | wc -c | tr -d ' ')
  tail -c +$((hdr + 1)) "$work/$1.ppm" | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
    | awk -v r="$2" -v g="$3" -v b="$4" '{ v[NR % 3] = $1 } NR % 3 == 0 && v[1] == r && v[2] == g && v[0] == b { n++ } END { print n + 0 }'
}

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
wayland-scanner client-header "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.h"
wayland-scanner private-code  "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.c"
wayland-scanner client-header "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "vpointer"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/lockclient.c" "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   "$work/ext-session-lock-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/lockclient" || fail "lockclient"

env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 \
    --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"
mkfifo "$work/vp" "$work/a"
"$work/vpointer" 800 600 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/lockclient" window ff336699 org.abyssbsd.dmg < "$work/a" > "$work/a.log" 2>&1 & wa=$!; exec 5>"$work/a"
await "$work/ut.out" '^window org.abyssbsd.dmg ' "the window never mapped"
printf 'm 700 500\n' >&3
tick > /dev/null; tick > /dev/null

# ----------------------------------------------------------- 1. static
a=$(tick); b=$(tick); c=$(tick)
[ $((c - a)) -le 2 ] || fail "a static screen presented $((c - a)) frames in two seconds"
echo "ok: 1. a static screen presented $((c - a)) frame(s) in two seconds"

# -------------------------------------------- 2. the same buffer, repainted
# Counted BEFORE any screenshot: screencopy asks for a frame of its own, which
# would draw the repaint whether the repaint itself was seen or not.
before=$(tick)
printf 'r ff22aa22\n' >&5
await "$work/a.log" '^repainted' "the client did not repaint"
after=$(tick)
[ "$after" -gt "$before" ] || fail "a repaint into the same buffer presented no frame (texture unchanged, commit missed)"
shot repainted
[ "$(has repainted 34 170 34)" -gt 1000 ] || fail "a repaint into the same buffer is not on screen ($(has repainted 34 170 34) green pixels)"
[ "$(has repainted 51 102 153)" = 0 ] || fail "the old colour is still on screen after a repaint"
echo "ok: 2. a repaint into the same buffer was drawn"

# ----------------------------------------------------------- 3. pointer
p0=$(tick)
for x in 100 200 300 400; do printf 'm %s 100\n' "$x" >&3; sleep 0.1; done
p1=$(tick)
[ $((p1 - p0)) -ge 3 ] || fail "the pointer moved four times and $((p1 - p0)) frame(s) were presented"
echo "ok: 3. the pointer moving alone was drawn ($((p1 - p0)) frames)"

# ------------------------------------------------- 4. screenshot, static
tick > /dev/null; tick > /dev/null
s0=$(date +%s)
timeout 5 "$grab" "$work/static.ppm" > "$work/grab.log" 2>&1 || fail "a screenshot of a static screen did not complete: $(cat "$work/grab.log")"
[ "$(has static 34 170 34)" -gt 1000 ] || fail "the static screenshot does not show the window"
echo "ok: 4. a screenshot of a static screen completed in $(( $(date +%s) - s0 ))s, and shows the screen"
echo "all green (present on damage: nothing drawn for nothing, and every change drawn)."
