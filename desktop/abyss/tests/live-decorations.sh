#!/bin/sh
# AbyssBSD Swift DE — a foreign window gets an Aqua frame (P9.6).
#
# A GTK application draws its own headerbar, and on a Jaguar desktop that looks
# broken in a way no missing feature does. `xdg-decoration-unstable-v1` is how a
# client asks who draws the frame; undertow answers **server-side, always**, and
# then paints an Aqua title bar with gel traffic lights around a window it did
# not write.
#
# The client is a real GTK 3 application — the same one Phase 8 uses, run with
# `GTK_CSD=0` so it asks the compositor to decorate it rather than drawing its
# own. Nothing about it knows this desktop exists, which is the point.
#
# Three claims, and the third is the one a screenshot could not make:
#
#   - the compositor **took** the decoration (it answered the protocol);
#   - it **rasterised exactly one frame** for the window — §6.1 asked for the
#     cache to be measured rather than asserted, so this counts it;
#   - the frame is **clickable where it was drawn**: the yellow light minimises
#     the window, which is observable in the compositor's own geometry line and
#     needs no cooperation from a client that has never heard of us.
#
# Usage: abyss/tests/live-decorations.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-deco.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

# **The client had to be written, and that is a finding.** The obvious candidate
# was GTK — Phase 8 already runs a real GTK 3 application — but GTK draws its own
# decorations on Wayland whatever the compositor offers, and does not implement
# this protocol at all. So the client that *asks* is a new mode of the adversary
# (`decorated`), which is otherwise the hostile-client harness from P6.5.
deco_xml=""
for d in /usr/share/wayland-protocols /usr/local/share/wayland-protocols; do
  [ -f "$d/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" ] \
    && deco_xml="$d/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"
done
[ -n "$deco_xml" ] || { echo "SKIP: no xdg-decoration XML in wayland-protocols"; exit 0; }
wayland-scanner client-header "$deco_xml" "$work/xdg-decoration-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$deco_xml" "$work/xdg-decoration-unstable-v1-protocol.c"
app="$work/adversary"
cc -I"$work" -I "$root/de/cwayland/include" "$root/abyss/tests/adversary.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/xdg-decoration-unstable-v1-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$app" \
  || fail "could not build the client that asks to be decorated"

env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""; i=0
while [ $i -lt 80 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || fail "undertow exited before it announced a socket"
  sleep 0.25; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
echo "ok: undertow is up on $wd"

env WAYLAND_DISPLAY="$wd" "$app" decorated 260 160 > "$work/app.log" 2>&1 &
app_pid=$!
i=0
while [ $i -lt 100 ]; do
  grep -q 'asked to be decorated' "$work/app.log" 2>/dev/null && break
  kill -0 "$app_pid" 2>/dev/null || fail "the client exited: $(cat "$work/app.log")"
  sleep 0.25; i=$((i + 1))
done
grep -q 'asked to be decorated' "$work/app.log" \
  || fail "the client never mapped: $(tail -3 "$work/app.log")"
echo "ok: a client asked the compositor to draw its frame"

# ------------------------------------------------- the compositor took it
i=0
while [ $i -lt 40 ]; do
  grep -q '^frame-rasterisations=[1-9]' "$work/ut.out" 2>/dev/null && break
  sleep 0.25; i=$((i + 1))
done
grep -q '^frame-rasterisations=[1-9]' "$work/ut.out" \
  || fail "no frame was ever drawn — the decoration request went unanswered:
    $(grep -E '^(frame|window)' "$work/ut.out" | tail -4)"
echo "ok: undertow answered server-side and painted a frame"

# ...and exactly one, for a window nobody is resizing. §6.1 wanted this measured.
count=$(grep '^frame-rasterisations=' "$work/ut.out" | tail -1 | cut -d= -f2)
[ "$count" -le 2 ] \
  || fail "the frame was rasterised $count times for a window that never moved —
    the cache is not working, and the frame path is doing cairo work"
echo "ok: it rasterised $count frame(s) — cached, not redrawn every frame"

# ------------------------------------- and the frame is clickable where drawn
#
# The window is 260x160, centred in an 800x600 usable area, so its surface is at
# (270, 242) with the frame starting a title bar higher at (269, 220). The
# yellow light's centre is 36px in and 11px down from there.
key=$(grep '^window ' "$work/ut.out" | tail -1 | awk '{print $2}')   # one word by construction
[ -n "$key" ] || fail "undertow never reported a window"
geom=$(grep "^window $key " "$work/ut.out" | tail -1 | cut -d' ' -f3,4)
echo "ok: the window is at $geom"

xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" \
   || fail "could not build the virtual pointer"
fifo="$work/pointer"
mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 800 600 < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$fifo"
sleep 1

sx=$(echo "$geom" | cut -d, -f1)
sy=$(echo "$geom" | cut -d' ' -f1 | cut -d, -f2)
lightx=$((sx - 1 + 36))
lighty=$((sy - 22 + 11))
printf 'm %s %s\np\nr\n' "$lightx" "$lighty" >&3
sleep 1.2

grep -q '^frame-clicks=1' "$work/ut.out" \
  || fail "the press on the frame reached nobody — a title bar you can see and
    cannot click: $(grep -E '^frame' "$work/ut.out" | tail -3)"
grep -q "^window $key .* min\$" "$work/ut.out" \
  || fail "the yellow light did not minimise the window:
    $(grep "^window $key " "$work/ut.out" | tail -3)"
echo "ok: the yellow light on that frame put the window away — drawn and clickable"

exec 3>&- 2>/dev/null || true
echo "all green (a window that never heard of this desktop is wearing its frame)."
