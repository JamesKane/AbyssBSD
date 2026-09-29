#!/bin/sh
# AbyssBSD Swift DE — our cursors, for the toolkits that draw their own (BACKLOG U.7b).
#
# GTK 3, SDL and X clients do not ask the compositor for a shape (U.7); they
# load an XCursor theme through libwayland-cursor or libXcursor, by the name in
# $XCURSOR_THEME, from $XCURSOR_PATH — and drew Adwaita's arrow over our
# windows. `abyss-theme cursors` writes the theme's own cursors as the XCursor
# theme "Abyss", and the session names it. Claims:
#
#   1. the theme is written: 34 cursors at four sizes and the X11 names
#      (left_ptr, xterm, hand2, watch…) linked to them;
#   2. libwayland-cursor loads it, by CSS name and by X11 name, with the
#      hotspots the draw lists name (left_ptr 5,3; xterm 12,12);
#   3. a client that sets `left_ptr` from it shows, in undertow's capture,
#      exactly the pixels undertow draws for its own arrow — and a client on
#      Adwaita does not (so the comparison can tell);
#   4. the session names it: anchor writes the theme into its runtime
#      directory, and every component it starts has XCURSOR_THEME=Abyss,
#      XCURSOR_SIZE and XCURSOR_PATH.
#
# Usage: abyss/tests/live-xcursor.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
theme="$root/.build/debug/abyss-theme"
[ -x "$undertow" ] && [ -x "$theme" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-xcursor.XXXXXX)
cleanup() {
  exec 3>&- 5>&- 2>/dev/null || true
  for p in ${ap:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"; [ -s "$work/a.log" ] && sed 's/^/  cursortest| /' "$work/a.log" | tail -6; exit 1; }

# ------------------------------------------------------ 1. written
"$theme" cursors "$work/icons" > "$work/gen.out" 2>&1 || fail "abyss-theme cursors failed: $(cat "$work/gen.out")"
grep -q 'wrote .*/Abyss: 34 cursors at sizes 24,32,48,64, [0-9]* X11 names linked' "$work/gen.out" \
  || fail "abyss-theme cursors said: $(tail -1 "$work/gen.out")"
c="$work/icons/Abyss/cursors"
[ -f "$work/icons/Abyss/index.theme" ] || fail "no index.theme"
for n in default text pointer wait ew-resize nwse-resize; do [ -f "$c/$n" ] || fail "no cursor $n"; done
for x in left_ptr xterm hand2 watch sb_h_double_arrow bottom_right_corner; do
  [ -L "$c/$x" ] || fail "no X11 name $x"
done
[ "$(readlink "$c/left_ptr")" = default ] && [ "$(readlink "$c/xterm")" = text ] || fail "the X11 names link to the wrong shapes"
[ "$(head -c 4 "$c/default")" = Xcur ] || fail "cursors/default is not an XCursor file"
echo "ok: 1. $(sed 's/.*wrote [^:]*: //' "$work/gen.out" | tail -1)"

# ------------------------------------------------------ the client
protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
for x in "vpointer:$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" \
         "cursor-shape:$root/protocols/cursor-shape-v1.xml" "tablet:$root/protocols/tablet-unstable-v2.xml" \
         "xdg-decoration:$protos/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$f" "$work/$n-proto.h"
  wayland-scanner private-code  "$f" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/cursortest.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/cursor-shape-proto.c" "$work/tablet-proto.c" \
   "$work/xdg-decoration-proto.c" $(pkg-config --cflags --libs wayland-client wayland-cursor) -o "$work/cursortest" \
   || fail "could not build cursortest"

# run NAME THEME COMMAND: one bounded undertow run with cursortest told
# COMMAND before the pointer enters its window; a capture at its end, and the
# pointer's place in PX PY.
run() {
  rm -f "$work/vp.in" "$work/a.in"; mkfifo "$work/vp.in" "$work/a.in"
  env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 360 --width 800 --height 600 \
      --config-dir "$work" --capture "$work/$1.ppm" > "$work/ut.out" 2> "$work/ut.err" &
  ut_pid=$!
  i=0; wd=""
  while [ $i -lt 60 ]; do
    wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
    [ -n "$wd" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$wd" ] || fail "undertow never announced a socket ($1)"
  WAYLAND_DISPLAY="$wd" "$work/vpointer" 800 600 < "$work/vp.in" > "$work/vp.log" 2>&1 &
  vp=$!; exec 3>"$work/vp.in"
  i=0; while ! grep -q ready "$work/vp.log" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
  env WAYLAND_DISPLAY="$wd" XCURSOR_THEME="$2" XCURSOR_SIZE=24 \
      XCURSOR_PATH="$work/icons:/usr/local/share/icons:/usr/share/icons" \
      "$work/cursortest" < "$work/a.in" > "$work/a.log" 2>&1 &
  ap=$!; exec 5>"$work/a.in"
  i=0; while ! grep -q '^ready' "$work/a.log" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
  printf '%s\n' "$3" >&5; sleep 0.3
  # Its window is centred: 400x300 at (200,150). The pointer goes to
  # (300,250) inside it — away from the middle, where nothing else lands.
  PX=300; PY=250
  printf 'm %s %s\n' $PX $PY >&3
  wait "$ut_pid" 2>/dev/null || true; ut_pid=""
  exec 3>&- 5>&-; kill "$ap" "$vp" 2>/dev/null || true; ap=""; vp=""
}
region() {  # region FILE -> the 24x24 cell of the arrow at (PX,PY), hotspot 5,3
  hdr=$(head -3 "$1" | wc -c | tr -d ' ')
  y=$((PY - 3))
  while [ $y -lt $((PY + 21)) ]; do
    dd if="$1" bs=1 skip=$((hdr + (y * 800 + PX - 5) * 3)) count=72 2>/dev/null | od -An -v -tu1
    y=$((y + 1))
  done
}

# ------------------------------------------------------ 2. loaded
run xcursor Abyss 'x xterm'
grep -q '^xcursor xterm 24x24 hot 12,12$' "$work/a.log" || fail "libwayland-cursor did not load xterm from Abyss as 24x24, hot 12,12: $(grep xcursor "$work/a.log")"
run xcursor Abyss 'x left_ptr'
grep -q '^xcursor left_ptr 24x24 hot 5,3$' "$work/a.log" || fail "libwayland-cursor did not load left_ptr from Abyss as 24x24, hot 5,3: $(grep xcursor "$work/a.log")"
grep -q '^cursor client ' "$work/ut.out" || fail "undertow never showed the client's cursor surface"
echo "ok: 2. libwayland-cursor loads Abyss by X11 name: left_ptr 24x24 hot 5,3, xterm 24x24 hot 12,12"

# ------------------------------------------------------ 3. the same pixels
run shape Abyss 's 1'
grep -q '^cursor shape:default ' "$work/ut.out" || fail "the shape run did not show undertow's own arrow"
region "$work/xcursor.ppm" > "$work/xcursor.txt"; region "$work/shape.ppm" > "$work/shape.txt"
cmp -s "$work/xcursor.txt" "$work/shape.txt" \
  || fail "the XCursor arrow's pixels differ from undertow's own arrow ($(diff "$work/xcursor.txt" "$work/shape.txt" | grep -c '^<') rows)"
adw=""
for d in /usr/share/icons/Adwaita /usr/local/share/icons/Adwaita; do [ -f "$d/cursors/left_ptr" ] && adw=$d; done
if [ -n "$adw" ]; then
  run adwaita Adwaita 'x left_ptr'
  region "$work/adwaita.ppm" > "$work/adwaita.txt"
  cmp -s "$work/adwaita.txt" "$work/shape.txt" && fail "Adwaita's arrow is pixel-identical to ours: the comparison cannot tell them apart"
  echo "ok: 3. the XCursor arrow is undertow's own, pixel for pixel — and Adwaita's is not"
else
  echo "ok: 3. the XCursor arrow is undertow's own, pixel for pixel (no Adwaita here to tell apart)"
fi

# ------------------------------------------------------ 4. the session names it
# anchor supervising one component that writes down its environment. A
# person's own XCURSOR_* would be kept (the unit tests hold that), so none
# is passed here.
mkdir -p "$work/rt"
printf '#!/bin/sh\nenv > %s/env.txt\nexec sleep 30\n' "$work" > "$work/dump.sh"; chmod +x "$work/dump.sh"
env -u XCURSOR_THEME -u XCURSOR_SIZE -u XCURSOR_PATH "$root/.build/debug/anchor" --runtime-dir "$work/rt" \
    --display no-compositor-needed --component "dump=$work/dump.sh" > "$work/anchor.log" 2>&1 &
an=$!
i=0; while [ ! -s "$work/env.txt" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill "$an" 2>/dev/null || true; wait "$an" 2>/dev/null || true
[ -s "$work/env.txt" ] || fail "anchor never started its component: $(tail -3 "$work/anchor.log")"
grep -qx 'XCURSOR_THEME=Abyss' "$work/env.txt" || fail "the session's XCURSOR_THEME is $(grep XCURSOR_THEME "$work/env.txt")"
grep -qx 'XCURSOR_SIZE=24' "$work/env.txt" || fail "the session's XCURSOR_SIZE is $(grep XCURSOR_SIZE "$work/env.txt")"
grep -q "^XCURSOR_PATH=$work/rt/icons:" "$work/env.txt" || fail "the session's XCURSOR_PATH is $(grep XCURSOR_PATH "$work/env.txt")"
[ -f "$work/rt/icons/Abyss/cursors/default" ] && [ -L "$work/rt/icons/Abyss/cursors/left_ptr" ] \
  || fail "anchor did not write the theme into its runtime directory: $(ls "$work/rt/icons/Abyss/cursors" 2>&1 | head -3)"
echo "ok: 4. anchor wrote Abyss into its runtime directory, and its session has XCURSOR_THEME=Abyss, XCURSOR_SIZE=24, XCURSOR_PATH from there"

echo "all green (our cursors, for the toolkits that draw their own)."
