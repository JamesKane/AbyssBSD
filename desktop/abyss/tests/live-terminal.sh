#!/bin/sh
# AbyssBSD Swift DE — Terminal, a shell in a window (PHASE15 P15.4b).
#
# The application on our compositor, typed into by the virtual keyboard and
# clicked by the virtual pointer. Claims:
#
#   1. the window maps (app_id org.abyssbsd.terminal), 80×24, a shell on it;
#   2. what is typed runs in the shell and its output is DRAWN: the row the
#      screen model holds has dark glyph pixels where the grid says it is,
#      read back through screencopy;
#   3. Ctrl-C interrupts the foreground program — the pty is the shell's
#      controlling terminal, and the key is the tty's interrupt character;
#   4. vi opens a file, the Down arrow moves in it (application cursor keys),
#      and `dd :wq` changes the file ON DISK;
#   5. the zoom button enlarges the window, and `stty size` in the shell says
#      the new rows and columns the grid now has;
#   6. ⌘N opens a second window with its own shell;
#   7. `exit` in each window closes it, and the last one quits Terminal.
#
# Usage: abyss/tests/live-terminal.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
grab="$root/.build/debug/abyssgrab"
for b in "$undertow" "$aqua" "$grab"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

W=1024; H=768
work=$(mktemp -d /tmp/abyss-term.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${vk_pid:-} ${term_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  pkill -f "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM HUP
fail() {
  exec 1>&2
  echo "FAIL: $1"
  [ -s "$work/term.log" ] && grep 'Terminal:' "$work/term.log" | tail -40 | sed 's/^/  term| /'
  exit 1
}
log="$work/term.log"
count() { grep -c -- "$1" "$log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY [TENTHS]
  i=0
  while [ $i -lt "${4:-80}" ]; do [ "$(count "$1")" -gt "$2" ] && return 0; sleep 0.1; i=$((i + 1)); done
  fail "$3"
}

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

# ------------------------------------------------------------ the compositor
# A config directory of its own: no window place remembered from another run.
mkdir -p "$work/cfg" "$work/home"
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width $W --height $H --config-dir "$work/cfg" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""; i=0
while [ $i -lt 80 ] && [ -z "$wd" ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""; sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"

# ------------------------------------------------------------ 1. the window
printf 'first line\nsecond line\nthird line\n' > "$work/home/sample.txt"
# A plain shell with a known prompt and no rc file, the same on both platforms.
env WAYLAND_DISPLAY="$wd" HOME="$work/home" SHELL=/bin/sh PS1='$ ' ENV=/dev/null \
    ABYSS_CONFIG_DIR="$work/cfg" ABYSS_TERMINAL_DUMP=1 AQUA_SCENE=terminal "$aqua" > "$log" 2>&1 &
term_pid=$!
await 'Terminal: chrome ' 0 "Terminal never drew its window"
i=0; until grep -q '^window org.abyssbsd.terminal/' "$work/ut.out"; do
  [ $i -ge 150 ] && fail "no org.abyssbsd.terminal window on undertow"; sleep 0.1; i=$((i + 1)); done
grep -q 'Terminal: window: /bin/sh (pid [0-9]*) 80x24' "$log" || fail "no shell on an 80x24 terminal"
grep -q 'Terminal: size 80x24' "$log" || fail "the window is not 80x24"
# Where undertow put it: `window APP_ID/TITLE X,Y WxH`. Everything below adds
# the window's own coordinates (its log) to this.
wx=$(grep -m1 '^window org.abyssbsd.terminal/' "$work/ut.out" | awk '{print $(NF-1)}' | cut -d, -f1)
wy=$(grep -m1 '^window org.abyssbsd.terminal/' "$work/ut.out" | awk '{print $(NF-1)}' | cut -d, -f2)
echo "ok: 1. Terminal's window mapped ($(grep -m1 '^window org.abyssbsd.terminal/' "$work/ut.out")), 80x24, /bin/sh on it"

mkfifo "$work/pointer" "$work/keys"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" $W $H < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$work/keys" > "$work/vk.log" 2>&1 &
vk_pid=$!
exec 4> "$work/keys"
sleep 1
# Focus: a click in the grid.
printf 'm %s %s\np\nr\n' $((wx + 200)) $((wy + 150)) >&3; sleep 0.4
type_line() { printf 't %s\n' "$1" >&4; sleep 0.2; printf 'k 28\n' >&4; }
row_of() {  # row_of TEXT — the row number where the screen last showed exactly TEXT
  grep -F "|$1|" "$log" | tail -1 | sed -n 's/.*Terminal: row \([0-9]*\) .*/\1/p'
}

# ------------------------------------------------------------ 2. typed, run, drawn
b=$(count '|hello from a terminal|')
type_line 'echo hello from a terminal'
await '|hello from a terminal|' "$b" "the shell's output never reached the screen"
r=$(row_of 'hello from a terminal')
chrome=$(grep 'Terminal: chrome ' "$log" | tail -1)
gx=$(echo "$chrome" | sed -n 's/.*grid=\([0-9.]*\),.*/\1/p'); gy=$(echo "$chrome" | sed -n 's/.*grid=[0-9.]*,\([0-9.]*\) .*/\1/p')
cw=$(echo "$chrome" | sed -n 's/.*cell=\([0-9.]*\)x.*/\1/p'); ch=$(echo "$chrome" | sed -n 's/.*cell=[0-9.]*x\([0-9.]*\).*/\1/p')
sleep 0.5
WAYLAND_DISPLAY="$wd" "$grab" "$work/shot.ppm" 2>/dev/null || fail "could not grab the screen"
# Count dark pixels in the row's first 21 cells ("hello from a terminal"),
# against the same span one row below the prompt that follows it (blank).
dark() {  # dark ROW — dark pixels across 21 cells of ROW (1-based)
  hdr=$(printf 'P6\n%s %s\n255\n' $W $H | wc -c | tr -d ' ')
  y0=$(awk -v wy="$wy" -v gy="$gy" -v ch="$ch" -v r="$1" 'BEGIN { printf "%d", wy + gy + (r - 1) * ch }')
  x0=$(awk -v wx="$wx" -v gx="$gx" 'BEGIN { printf "%d", wx + gx }')
  x1=$(awk -v wx="$wx" -v gx="$gx" -v cw="$cw" 'BEGIN { printf "%d", wx + gx + 21 * cw }')
  h=$(awk -v ch="$ch" 'BEGIN { printf "%d", ch }')
  n=0; y=$y0
  while [ $y -lt $((y0 + h)) ]; do
    c=$(dd if="$work/shot.ppm" bs=1 skip=$((hdr + (y * W + x0) * 3)) count=$(((x1 - x0) * 3)) 2>/dev/null \
        | od -An -v -tu1 | tr -s ' \n' '\n' | grep . | awk 'NR % 3 == 1 { r = $1 } NR % 3 == 2 { g = $1 }
          NR % 3 == 0 { if (r + g + $1 < 200) n++ } END { print n + 0 }')
    n=$((n + c)); y=$((y + 1))
  done
  echo $n
}
ink=$(dark "$r"); blank=$(dark $((r + 2)))
[ "$ink" -gt 50 ] || fail "row $r holds 'hello from a terminal' but only $ink dark pixels are drawn there"
[ "$blank" -lt 5 ] || fail "a blank row below has $blank dark pixels — the grid is not where it was measured"
echo "ok: 2. typed into the shell and run: row $r holds 'hello from a terminal', drawn ($ink dark pixels there, $blank on a blank row)"

# ------------------------------------------------------------ 3. Ctrl-C
type_line 'sleep 30'
sleep 0.8
printf 'c 4 46\n' >&4                                           # Ctrl-C
sleep 0.3
b=$(count '|after the interrupt|')
type_line 'echo after the interrupt'
await '|after the interrupt|' "$b" "sleep 30 was not interrupted by Ctrl-C (the next command did not run)" 40
echo "ok: 3. Ctrl-C interrupted sleep 30 at once — the pty is the shell's controlling terminal"

# ------------------------------------------------------------ 4. vi
b=$(count '|second line|')
type_line 'vi sample.txt'
await '|second line|' "$b" "vi did not draw sample.txt"
sleep 0.5
printf 'k 108\n' >&4; sleep 0.2                                 # Down: application cursor keys
printf 't dd\n' >&4; sleep 0.3
printf 't :wq\n' >&4; sleep 0.2; printf 'k 28\n' >&4
i=0; until [ "$(cat "$work/home/sample.txt")" = "$(printf 'first line\nthird line')" ]; do
  [ $i -ge 50 ] && fail "the file on disk is not the edit: $(tr '\n' '/' < "$work/home/sample.txt")"; sleep 0.1; i=$((i + 1)); done
echo "ok: 4. vi drew the file, Down moved to line two (DECCKM), and dd :wq deleted it on disk"

# ------------------------------------------------------------ 5. zoom
sleep 0.5
zoom=$(grep 'Terminal: chrome ' "$log" | tail -1 | sed -n 's/.* zoom=\([0-9]*,[0-9]*\).*/\1/p')
[ -n "$zoom" ] || fail "no zoom button in the chrome line"
b=$(count 'Terminal: size ')
printf 'm %s %s\np\nr\n' $((wx + ${zoom%,*})) $((wy + ${zoom#*,})) >&3
await 'Terminal: size ' "$b" "the zoom button did not resize the window"
size=$(grep 'Terminal: size ' "$log" | tail -1 | sed -n 's/.*size \([0-9]*\)x\([0-9]*\).*/\2 \1/p')   # "rows cols"
[ "${size#* }" -gt 80 ] || fail "zoomed, and still $size"
sleep 0.3
b=$(count "|$size|")
type_line 'stty size'
await "|$size|" "$b" "stty size does not say the zoomed grid ($size)"
echo "ok: 5. zoom enlarged the window to ${size#* }x${size% *}, and stty size in the shell says '$size'"

# ------------------------------------------------------------ 6. ⌘N
b=$(count 'Terminal: window: /bin/sh')
printf 'c 64 49\n' >&4                                          # ⌘N
await 'Terminal: window: /bin/sh' "$b" "⌘N opened no second window"
i=0; until [ "$(grep -c '^window org.abyssbsd.terminal/' "$work/ut.out")" -ge 2 ]; do
  [ $i -ge 100 ] && fail "the second window never mapped"; sleep 0.1; i=$((i + 1)); done
echo "ok: 6. ⌘N opened a second window with its own shell ($(grep 'Terminal: window: ' "$log" | tail -1 | sed 's/.*(pid \([0-9]*\)).*/pid \1/'))"

# ------------------------------------------------------------ 7. exit
sleep 0.8
b=$(count 'Terminal: the shell exited')
type_line 'exit'
await 'Terminal: the shell exited' "$b" "exit in the second window did not end its shell"
kill -0 "$term_pid" 2>/dev/null || fail "Terminal quit with a window still open"
sleep 0.5
printf 'm %s %s\np\nr\n' $((wx + 200)) $((wy + 150)) >&3; sleep 0.4   # the first window, focused again
type_line 'exit'
i=0; while kill -0 "$term_pid" 2>/dev/null; do
  [ $i -ge 50 ] && fail "the last window's shell exited and Terminal did not quit"; sleep 0.1; i=$((i + 1)); done
grep -q 'Terminal: the last window closed' "$log" || fail "Terminal quit without closing its last window"
term_pid=""
echo "ok: 7. exit closed each window, and the last one quit Terminal"

echo "all green (Terminal: a shell in a window)."
