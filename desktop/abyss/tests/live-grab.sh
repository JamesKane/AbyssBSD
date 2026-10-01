#!/bin/sh
# AbyssBSD Swift DE — Grab: a region's pixels in the saved file match the
# screen (PHASE15 P15.6).
#
# A still scene — the wallpaper and a System Preferences window, nothing that
# blinks or ticks — so any difference is Grab's, not the screen's. Driven by
# the virtual pointer and keyboard; saved through the portal and the Finder's
# save picker; compared byte for byte with a screencopy of the same region.
#
#   1. Grab's window maps;
#   2. Selection: a rectangle dragged on the overlay is captured — the overlay
#      not in it — saved as a PNG through the portal, and **its pixels are the
#      screen's**, region for region (abyssgrab --convert, then cmp);
#   3. Window: a click on the System Preferences window captures exactly the
#      box undertow says that window has (`window_at`), and those pixels are
#      the screen's too — but for the pointer, which a click has to put on the
#      window and which the build VM draws into the frame in software: every
#      pixel that differs is inside the pointer's box at the click;
#   4. Screen (⌘Z) takes the whole output, 1024×768;
#   5. Escape cancels a selection: nothing captured;
#   6. Timed Screen counts down (shortened here) and then captures.
#
# Usage: abyss/tests/live-grab.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
portal="$root/.build/debug/abyss-portal"
grab="$root/.build/debug/abyssgrab"
for b in "$undertow" "$aqua" "$portal" "$grab"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

W=1024; H=768
work=$(mktemp -d /tmp/abyss-grab.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-grabr.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${vk_pid:-} ${grab_pid:-} ${prefs_pid:-} ${wall_pid:-} ${portal_pid:-} ${ut_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  pkill -f "$work" 2>/dev/null || true
  rm -rf "$work" "$rundir"
}
trap cleanup EXIT INT TERM HUP
log="$work/grab.log"
fail() {
  exec 1>&2
  echo "FAIL: $1"
  [ -n "${ABYSS_TEST_KEEP:-}" ] && { rm -rf "$ABYSS_TEST_KEEP"; cp -r "$work" "$ABYSS_TEST_KEEP"; }
  [ -s "$log" ] && grep 'Grab:' "$log" | tail -8 | sed 's/^/  grab| /'
  exit 1
}
count() { grep -c -- "$1" "$log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY [TENTHS]
  i=0
  while [ $i -lt "${4:-80}" ]; do [ "$(count "$1")" -gt "$2" ] && return 0; sleep 0.1; i=$((i + 1)); done
  fail "$3"
}
export ABYSS_RUNTIME_DIR="$rundir"

# ------------------------------------------------------------ tools
for t in pointer keyboard; do
  xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
  [ $t = keyboard ] && xml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
  wayland-scanner client-header "$xml" "$work/v$t-proto.h"
  wayland-scanner private-code  "$xml" "$work/v$t-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "no vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "no vkeyboard"

# ------------------------------------------------------------ a still scene
# Places seeded — by `app_id/title`, undertow's key: Grab top left, System
# Preferences to the right, the save picker (a Finder on "Pictures", the
# portal's start) top left. New pictures open at the centre. The selection is
# taken bottom right, across System Preferences' right edge, where none of
# those ever is.
pics="$work/Pictures"; mkdir -p "$pics" "$work/cfg"
cat > "$work/cfg/windows.ini" <<EOF
[windows]
org.abyssbsd.grab/Grab = 10,10
org.abyssbsd.preferences/System Preferences = 250,130
org.abyssbsd.finder = 0,0
org.abyssbsd.finder/Pictures = 0,0
EOF
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width $W --height $H --config-dir "$work/cfg" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""; i=0
while [ $i -lt 80 ] && [ -z "$wd" ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""; sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
export WAYLAND_DISPLAY="$wd"
env HOME="$pics" ABYSS_CONFIG_DIR="$work/cfg" "$portal" > "$work/portal.log" 2>&1 &
portal_pid=$!
i=0; while [ $i -lt 50 ] && [ ! -S "$rundir/portal.sock" ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$rundir/portal.sock" ] || fail "abyss-portal never bound its socket"
env HOME="$pics" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=wallpaper "$aqua" > "$work/wall.log" 2>&1 &
wall_pid=$!
env HOME="$pics" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=sysprefs "$aqua" > "$work/prefs.log" 2>&1 &
prefs_pid=$!
i=0; until grep -q '^window org.abyssbsd.preferences/' "$work/ut.out"; do
  [ $i -ge 150 ] && fail "System Preferences never mapped"; sleep 0.1; i=$((i + 1)); done

# ------------------------------------------------------------ 1. Grab
env HOME="$pics" ABYSS_CONFIG_DIR="$work/cfg" ABYSS_GRAB_DUMP=1 ABYSS_GRAB_TIMER=1 AQUA_SCENE=grab \
    "$aqua" > "$log" 2>&1 &
grab_pid=$!
await 'Grab: panel ' 0 "Grab never drew its window"
i=0; until grep -q '^window org.abyssbsd.grab/' "$work/ut.out"; do
  [ $i -ge 150 ] && fail "no org.abyssbsd.grab window"; sleep 0.1; i=$((i + 1)); done
gpos=$(grep '^window org.abyssbsd.grab/' "$work/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)
gx=${gpos%,*}; gy=${gpos#*,}
panel=$(grep 'Grab: panel ' "$log" | tail -1)
button() {  # button NAME — its centre on the screen
  p=$(echo "$panel" | tr ' ' '\n' | sed -n "s/^$1=//p"); echo "$((gx + ${p%,*})) $((gy + ${p#*,}))"
}
echo "ok: 1. Grab's window mapped at $gpos"

mkfifo "$work/pointer" "$work/keys"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" $W $H < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$work/keys" > "$work/vk.log" 2>&1 &
vk_pid=$!
exec 4> "$work/keys"
sleep 1
click() { printf 'm %s %s\np\nr\n' "$1" "$2" >&3; sleep 0.4; }

# Save the front picture through the portal: ⌘S in Grab, then ⌘S in the
# Finder's save picker (it names Pictures/Untitled.png). Waits for Grab's line.
save_front() {
  n=$(grep -c "Finder: listed $pics" "$work/portal.log" 2>/dev/null || true)
  b=$(count 'Grab: saved ')
  printf 'c 64 31\n' >&4                                         # ⌘S in Grab
  i=0; until [ "$(grep -c "Finder: listed $pics" "$work/portal.log" 2>/dev/null || true)" -gt "$n" ]; do
    [ $i -ge 150 ] && fail "⌘S did not open the save picker"; sleep 0.1; i=$((i + 1)); done
  sleep 1.2
  click 450 330                                                  # focus the picker
  printf 'c 64 31\n' >&4                                         # ⌘S in the picker
  await 'Grab: saved ' "$b" "the picture was not saved" 100
}

# The region (X, Y, W, H) of a screencopy taken now, as PPM rows — what the
# saved picture must equal.
screen_region() {  # screen_region X Y W H OUT
  WAYLAND_DISPLAY="$wd" "$grab" "$work/now.ppm" 2>/dev/null || fail "abyssgrab could not capture the screen"
  hdr=$(printf 'P6\n%s %s\n255\n' $W $H | wc -c | tr -d ' ')
  printf 'P6\n%s %s\n255\n' "$3" "$4" > "$5"
  y=$2
  while [ "$y" -lt $(($2 + $4)) ]; do
    dd if="$work/now.ppm" bs=1 skip=$((hdr + (y * W + $1) * 3)) count=$(($3 * 3)) 2>/dev/null >> "$5"
    y=$((y + 1))
  done
}
# The screen is taken once the capture mode is up and before the pointer acts:
# the overlay has drawn nothing yet, and clicking a button has already moved
# focus (which redraws other windows' title bars). That is the screen the
# capture sees, the overlay apart.
# Equal, or differing only under the pointer: the build VM draws the pointer
# into the frame in software, so a capture taken where it rests (the end of a
# drag, a click) has it. Every differing pixel must be within its box — the
# arrow is drawn down and right of its tip, inside 32 px, with a pixel or two
# of outline up and left. CX, CY is where it rested, in the picture's pixels.
check_saved() {  # check_saved WHAT CX CY
  "$grab" --convert "$pics/Untitled.png" "$work/saved.ppm" 2>/dev/null || fail "the saved $1 is not a PNG"
  d=$("$grab" --diff "$work/saved.ppm" "$work/expect.ppm")
  case "$d" in
    same) return 0 ;;
    *" pixels differ, within "*)
      set -- "$1" "$2" "$3" $(echo "$d" | sed -n 's/.* within \([0-9]*\),\([0-9]*\) \([0-9]*\)x\([0-9]*\)/\1 \2 \3 \4/p')
      [ "$4" -ge $(($2 - 3)) ] && [ "$5" -ge $(($3 - 3)) ] && [ $(($4 + $6)) -le $(($2 + 34)) ] && [ $(($5 + $7)) -le $(($3 + 34)) ] \
        || fail "the saved $1's pixels differ from the screen's beyond the pointer: $d (pointer at $2,$3)"
      ;;
    *) fail "could not compare the saved $1: $d" ;;
  esac
  diffnote=$d
}

# ------------------------------------------------------------ 2. Selection
b=$(count 'Grab: capturing a selection')
click $(button selection)
await 'Grab: capturing a selection' "$b" "the Selection button did not start a capture"
sleep 0.6
screen_region 880 600 140 160 "$work/expect.ppm"
b=$(count 'Grab: captured selection ')
# From the top-right corner to the bottom-left: the pointer then rests just
# outside the rectangle, its arrow pointing away from it. (The pointer is
# drawn into the frame in software here, so where it ends up matters.)
printf 'm 1020 600\np\n' >&3; sleep 0.2
printf 'm 950 680\n' >&3; sleep 0.1
printf 'm 880 760\n' >&3; sleep 0.3
printf 'r\n' >&3
await 'Grab: captured selection ' "$b" "dragging on the overlay captured nothing"
grep 'Grab: captured selection ' "$log" | tail -1 | grep -q 'selection 880,600 140x160' \
  || fail "the selection is not 880,600 140x160: $(grep 'Grab: captured selection' "$log" | tail -1)"
sleep 0.8
save_front
diffnote=same
check_saved selection 0 160                                      # released at 880,760: the picture's 0,160
echo "ok: 2. a 140x160 selection at 880,600 (across System Preferences' edge), saved through the portal as a PNG: its pixels are the screen's ($diffnote — the pointer, where the drag ended)"

# ------------------------------------------------------------ 3. Window
ppos=$(grep '^window org.abyssbsd.preferences/' "$work/ut.out" | tail -1)
pxy=$(echo "$ppos" | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)
pwh=$(echo "$ppos" | tr ' ' '\n' | grep -E '^[0-9]+x[0-9]+$' | tail -1)
b=$(count 'Grab: capturing a window')
click $(button window)
await 'Grab: capturing a window' "$b" "the Window button did not start a capture"
sleep 0.6
screen_region "${pxy%,*}" "${pxy#*,}" "${pwh%x*}" "${pwh#*x}" "$work/expect.ppm"
b=$(count 'Grab: captured window ')
# Where nothing covers it: the pictures open at the centre, over its middle.
printf 'm %s %s\n' $((${pxy%,*} + 650)) $((${pxy#*,} + 450)) >&3; sleep 0.4
printf 'p\nr\n' >&3
await 'Grab: captured window ' "$b" "clicking the window captured nothing"
got=$(grep 'Grab: captured window ' "$log" | tail -1 | sed 's/.*captured window //')
[ "$got" = "org.abyssbsd.preferences $pxy $pwh" ] \
  || fail "the window captured is '$got', not System Preferences' box '$pxy $pwh'"
sleep 0.8
save_front
diffnote=same
check_saved window 650 450                                       # the click, in the window's picture
echo "ok: 3. a click captured System Preferences' whole box ($pxy $pwh, as undertow has it): its pixels are the screen's ($diffnote — the pointer, where it clicked)"

# ------------------------------------------------------------ 4. Screen
# From here by Capture's keys: the window capture's picture now covers Grab's
# own window, and a key reaches Grab from whichever of its windows has focus.
b=$(count 'Grab: captured screen ')
printf 'c 64 44\n' >&4                                           # ⌘Z: Screen
await 'Grab: captured screen ' "$b" "⌘Z (Screen) captured nothing"
grep 'Grab: captured screen ' "$log" | tail -1 | grep -q "captured screen ${W}x${H}" || fail "the screen capture is not ${W}x${H}"
echo "ok: 4. Screen took the whole output, ${W}x${H}"

# ------------------------------------------------------------ 5. Escape
sleep 0.6
b=$(count 'Grab: capture cancelled'); c=$(count 'Grab: captured ')
printf 'c 65 30\n' >&4                                           # ⇧⌘A: Selection
sleep 0.6
printf 'k 1\n' >&4
await 'Grab: capture cancelled' "$b" "Escape did not cancel the selection"
[ "$(count 'Grab: captured ')" = "$c" ] || fail "a cancelled selection captured something"
echo "ok: 5. Escape cancelled a selection, and nothing was captured"

# ------------------------------------------------------------ 6. Timed
sleep 0.6                                                        # the keyboard back from the overlay
b=$(count 'Grab: captured screen ')
printf 'c 65 44\n' >&4                                           # ⇧⌘Z: Timed Screen
await 'Grab: timed capture in 1 s' 0 "Timed did not start its countdown"
await 'Grab: captured screen ' "$b" "Timed Screen captured nothing after its countdown" 50
echo "ok: 6. Timed Screen counted down and captured the screen"

echo "all green (Grab: a region's pixels in the saved file match the screen)."
