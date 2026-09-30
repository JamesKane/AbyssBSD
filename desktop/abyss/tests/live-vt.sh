#!/bin/sh
# AbyssBSD Swift DE — real programs on a pseudo-terminal, through Terminal's
# screen model (PHASE15 P15.4a).
#
# `abyss-vt` runs a program on a real pty, feeds what it writes through the VT
# parser and `Screen`, types on a script, and prints the screen. No display:
# this is the model, asserted on before there is a window to draw it in.
#
#   1. a shell: what is typed is echoed and run; the pty's size is the size
#      asked for (`stty size`), and a resize reaches the program (SIGWINCH);
#   2. vi on a known file draws it — its lines, `~` past the end, a status line
#      — and editing through the terminal changes the file ON DISK (`j`, `dd`,
#      `:wq` deletes line two);
#   3. top draws its header and its process table, and `q` quits it.
#
# The same assertions on both platforms, against different programs: Linux's
# vim and procps top, FreeBSD's nvi and top.
#
# Usage: abyss/tests/live-vt.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
vt="$root/.build/debug/abyss-vt"
[ -x "$vt" ] || swift build --product abyss-vt
work=$(mktemp -d /tmp/abyss-vt.XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM HUP
fail() { echo "FAIL: $1"; [ -s "$work/out" ] && sed 's/^/  screen| /' "$work/out"; exit 1; }
row() { sed -n "$(( $1 + 1 ))p" "$work/out"; }          # row N of the screen, framed in |…|

# ------------------------------------------------------------ 1. a shell
"$vt" --rows 8 --cols 40 --step 'echo hello from a pty\r@300' --step 'stty size\r@300' \
      --step 'exit\r@300' -- /bin/sh > "$work/out"
grep -qx '|hello from a pty|' "$work/out" || fail "the shell did not echo what was typed"
grep -qx '|8 40|' "$work/out" || fail "the pty is not 8x40"
head -1 "$work/out" | grep -q 'exited: 0' || fail "the shell did not exit 0: $(head -1 "$work/out")"
# A resize on its own run: the smaller screen scrolls the earlier lines away.
"$vt" --rows 8 --cols 40 --resize 6x30@300 --step 'stty size\r@300' -- /bin/sh > "$work/out"
grep -qx '|6 30|' "$work/out" || fail "a resize did not reach the program"
echo "ok: 1. a shell on the pty: typed, echoed, sized 8x40 and resized to 6x30 (stty says so), exit 0"

# ------------------------------------------------------------ 2. vi
printf 'first line\nsecond line\nthird line\n' > "$work/sample.txt"
"$vt" --rows 10 --cols 60 --settle 600 -- vi "$work/sample.txt" > "$work/out"
[ "$(row 1)" = '|first line|' ] && [ "$(row 2)" = '|second line|' ] && [ "$(row 3)" = '|third line|' ] \
  || fail "vi did not draw the file's lines"
[ "$(row 4)" = '|~|' ] && [ "$(row 9)" = '|~|' ] || fail "vi did not draw ~ past the end of the file"
row 10 | grep -q 'sample.txt' || fail "vi's status line does not name the file: $(row 10)"
cursor=$(head -1 "$work/out" | sed -n 's/.*cursor: \([0-9]*,[0-9]*\).*/\1/p')
[ "$cursor" = "1,1" ] || fail "vi's cursor is at $cursor, not the start of the file"
"$vt" --rows 10 --cols 60 --step 'j@600' --step 'dd@200' --step ':wq\r@200' --settle 500 \
      -- vi "$work/sample.txt" > "$work/out"
head -1 "$work/out" | grep -q 'exited: 0' || fail "vi did not exit 0 after :wq"
[ "$(cat "$work/sample.txt")" = "$(printf 'first line\nthird line')" ] \
  || fail "the file on disk is not the edit: $(cat "$work/sample.txt")"
echo "ok: 2. vi drew the file (3 lines, ~ to the status line, cursor 1,1), and j dd :wq deleted line two on disk"

# ------------------------------------------------------------ 3. top
# Looked at while it runs (closing the terminal hangs it up): on `q`, procps
# top leaves its screen and moves to a new line, scrolling its header away.
"$vt" --rows 24 --cols 100 --settle 1500 -- top > "$work/out"
case "$(row 1)" in
  '|top - '*|'|last pid: '*) ;;
  *) fail "top's first line is not its header: $(row 1)" ;;
esac
grep -Eq '^\| *PID +(USER|USERNAME) ' "$work/out" || fail "top drew no process table heading"
[ "$(grep -Ec '^\| *[0-9]+ ' "$work/out")" -ge 3 ] || fail "top listed fewer than three processes"
header=$(row 1 | cut -c2-30)
"$vt" --rows 24 --cols 100 --step 'q@1500' --settle 500 -- top > "$work/out"
head -1 "$work/out" | grep -q 'exited: 0' || fail "q did not quit top: $(head -1 "$work/out")"
echo "ok: 3. top drew its header ($header…) and its process table, and q quit it"

echo "all green (real programs on a pseudo-terminal, through the screen model)."
