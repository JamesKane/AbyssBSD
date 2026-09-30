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
#   6. the scrollback: after `seq 1 300`, the wheel scrolls the view back into
#      history, and typing returns it to the live screen;
#   7. a selection pasted elsewhere arrives intact: a 200-character line,
#      wrapped over two rows, dragged across and copied with ⌘C, pasted with
#      ⌘V into a SECOND Terminal process (across the Wayland clipboard) running
#      `cat > pasted.txt` — the file holds the 200 characters, one line;
#   8. ⌘K clears the scrollback: the wheel then has nowhere to go;
#   9. ⌘N opens a second window with its own shell;
#  10. `exit` in each window closes it, and the last one quits Terminal.
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
  for p in ${vp_pid:-} ${vk_pid:-} ${term2_pid:-} ${term_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  pkill -f "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM HUP
fail() {
  exec 1>&2
  echo "FAIL: $1"
  # ABYSS_TEST_KEEP=DIR keeps the logs of a failed run for reading.
  [ -n "${ABYSS_TEST_KEEP:-}" ] && { rm -rf "$ABYSS_TEST_KEEP"; cp -r "$work" "$ABYSS_TEST_KEEP"; }
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
# Zoomed, the window fills the output from its corner (undertow reports that
# only in its exit summary: `window … 0,0 1024x768 max`).
wx=0; wy=0
echo "ok: 5. zoom enlarged the window to ${size#* }x${size% *}, and stty size in the shell says '$size'"

# ------------------------------------------------------------ 6. scrollback
b=$(count '|300|')
type_line 'seq 1 300'
await '|300|' "$b" "seq 1 300 did not finish"
sleep 0.3
cx=$((wx + 200)); cy=$((wy + 150))
b=$(count 'Terminal: view back ')
printf 'm %s %s\na -30\n' $cx $cy >&3
await 'Terminal: view back ' "$b" "the wheel did not scroll the view back"
back=$(grep 'Terminal: view back ' "$log" | tail -1)
n=$(echo "$back" | sed -n 's/.*view back \([0-9]*\) .*/\1/p'); top=$(echo "$back" | sed -n 's/.*top |\([0-9]*\)|.*/\1/p')
[ -n "$top" ] && [ "$top" -lt 262 ] || fail "scrolled back $n lines, and the top line is '$top', not earlier history"
b=$(count 'Terminal: view back 0 ')
printf 't x\n' >&4
await 'Terminal: view back 0 ' "$b" "typing did not return the view to the live screen"
printf 'k 14\n' >&4                                              # Backspace the x
echo "ok: 6. the wheel scrolled $n lines back into history (top line: $top), and typing came back to the live screen"

# ------------------------------------------------------------ 7. copy, and paste elsewhere
long=$(awk 'BEGIN { for (i = 0; i < 20; i++) printf "%d-abcdefgh", i % 10 }')          # 200 characters
b=$(count 'Terminal: row ')
type_line clear; sleep 0.4                                      # (vkeyboard cannot type ';')
type_line "echo $long"
i=0; until grep -q "|${long%"${long#?????????????????????????????????????????}"}" "$log" 2>/dev/null && grep -q 'Terminal: row 3 |\$|' "$log"; do
  [ $i -ge 80 ] && fail "the long line was not echoed"; sleep 0.1; i=$((i + 1)); done
sleep 0.4
cols=$(grep 'Terminal: size ' "$log" | tail -1 | sed -n 's/.*size \([0-9]*\)x.*/\1/p')
# The output's first row is exactly the line's first `cols` characters (the
# command's own echo starts with "$ echo "); the next row holds the rest.
orow=$(row_of "$(printf '%s' "$long" | cut -c1-"$cols")")
[ -n "$orow" ] || fail "no row holds the first $cols characters of the line"
rest=$((200 - cols))
x0=$(awk -v wx="$wx" -v gx="$gx" -v cw="$cw" 'BEGIN { printf "%d", wx + gx + cw / 2 }')
y0=$(awk -v wy="$wy" -v gy="$gy" -v ch="$ch" -v r="$orow" 'BEGIN { printf "%d", wy + gy + (r - 1) * ch + ch / 2 }')
x1=$(awk -v wx="$wx" -v gx="$gx" -v cw="$cw" -v c="$rest" 'BEGIN { printf "%d", wx + gx + (c - 1) * cw + cw / 2 }')
y1=$(awk -v wy="$wy" -v gy="$gy" -v ch="$ch" -v r="$orow" 'BEGIN { printf "%d", wy + gy + r * ch + ch / 2 }')
printf 'm %s %s\np\n' "$x0" "$y0" >&3; sleep 0.2
printf 'm %s %s\n' "$x1" "$y1" >&3; sleep 0.2
printf 'r\n' >&3; sleep 0.3
b=$(count 'Terminal: copied ')
printf 'c 64 46\n' >&4                                           # ⌘C
await 'Terminal: copied ' "$b" "⌘C copied nothing"
grep 'Terminal: copied ' "$log" | tail -1 | grep -q 'copied 200 characters' \
  || fail "the copy was not the 200 characters: $(grep 'Terminal: copied ' "$log" | tail -1)"
# A second Terminal process: the paste crosses the Wayland clipboard.
wbefore=$(grep -c '^window org.abyssbsd.terminal/' "$work/ut.out" || true)
env WAYLAND_DISPLAY="$wd" HOME="$work/home" SHELL=/bin/sh ABYSS_TERMINAL_DUMP=1 AQUA_SCENE=terminal \
    "$aqua" -e sh -c 'cat > "$HOME/pasted.txt"' > "$work/term2.log" 2>&1 &
term2_pid=$!
i=0; until [ "$(grep -c '^window org.abyssbsd.terminal/' "$work/ut.out" || true)" -gt "$wbefore" ]; do
  [ $i -ge 150 ] && fail "the second Terminal never mapped"; sleep 0.1; i=$((i + 1)); done
# Its `window … X,Y WxH [max]` line: the position is the field shaped X,Y.
w2=$(grep '^window org.abyssbsd.terminal/' "$work/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)
sleep 0.8
printf 'm %s %s\np\nr\n' $((${w2%,*} + 200)) $((${w2#*,} + 120)) >&3; sleep 0.5   # focus it
printf 'c 64 47\n' >&4                                           # ⌘V
i=0; until grep -q 'Terminal: pasted 200 characters' "$work/term2.log"; do
  [ $i -ge 50 ] && fail "⌘V in the second Terminal pasted nothing: $(grep 'Terminal:' "$work/term2.log" | tail -3)"; sleep 0.1; i=$((i + 1)); done
printf 'k 28\n' >&4; sleep 0.2; printf 'c 4 32\n' >&4            # Return, then Ctrl-D: cat ends
i=0; while kill -0 "$term2_pid" 2>/dev/null; do
  [ $i -ge 50 ] && fail "cat did not end, so the second Terminal did not close"; sleep 0.1; i=$((i + 1)); done
term2_pid=""
[ "$(cat "$work/home/pasted.txt")" = "$long" ] \
  || fail "what arrived is not what was selected: $(head -c 80 "$work/home/pasted.txt")…"
[ "$(wc -l < "$work/home/pasted.txt" | tr -d ' ')" = 1 ] || fail "the wrapped line arrived as more than one line"
echo "ok: 7. a 200-character line wrapped over two rows, dragged and ⌘C'd, arrived intact in another Terminal process's cat via ⌘V — one line"
printf 'm %s %s\np\nr\n' $((wx + 200)) $((wy + 150)) >&3; sleep 0.4   # back to the first window

# ------------------------------------------------------------ 8. clear scrollback
b=$(count 'Terminal: scrollback cleared')
printf 'c 64 37\n' >&4                                           # ⌘K
await 'Terminal: scrollback cleared' "$b" "⌘K did not clear the scrollback"
b=$(count 'Terminal: view back ')
printf 'm %s %s\na -30\n' $cx $cy >&3; sleep 0.6
[ "$(count 'Terminal: view back ')" = "$b" ] || fail "after ⌘K the wheel still scrolled into history"
echo "ok: 8. ⌘K cleared the scrollback, and the wheel had nowhere to go"

# ------------------------------------------------------------ 9. ⌘N
b=$(count 'Terminal: window: /bin/sh')
wbefore=$(grep -c '^window org.abyssbsd.terminal/' "$work/ut.out" || true)
printf 'c 64 49\n' >&4                                          # ⌘N
await 'Terminal: window: /bin/sh' "$b" "⌘N opened no second window"
i=0; until [ "$(grep -c '^window org.abyssbsd.terminal/' "$work/ut.out" || true)" -gt "$wbefore" ]; do
  [ $i -ge 100 ] && fail "the second window never mapped"; sleep 0.1; i=$((i + 1)); done
echo "ok: 9. ⌘N opened a second window with its own shell ($(grep 'Terminal: window: ' "$log" | tail -1 | sed 's/.*(pid \([0-9]*\)).*/pid \1/'))"

# ------------------------------------------------------------ 10. exit
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
echo "ok: 10. exit closed each window, and the last one quit Terminal"

echo "all green (Terminal: a shell in a window)."
