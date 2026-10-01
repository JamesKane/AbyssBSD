#!/bin/sh
# AbyssBSD Swift DE — TextEdit: a file opened, edited, saved, and its bytes
# read back (PHASE15 P15.5).
#
# On our compositor, typed into by the virtual keyboard and clicked by the
# virtual pointer, with the portal (P7) and the Finder as the file chooser.
# Every claim is checked on the file, not on the window:
#
#   1. a file opened by path maps a TextEdit window, its lines counted;
#   2. a click lands at the character it was aimed at (the layout's mapping,
#      measured from what the window says it drew), typing goes in there,
#      ⌘↓ goes to the end, and ⌘S writes EXACTLY the expected bytes;
#   3. typing after a save, then ⌘Z, takes back the typing ("Undo Typing"),
#      and saving again leaves the saved bytes as they were;
#   4. ⌘F, "needle", Return finds it, Escape returns to the text, typing
#      replaces the found word — and ⌘S puts that on disk;
#   5. ⌘O asks the portal, the Finder opens as the chooser, and the file
#      double-clicked there opens in a second window;
#   6. an untitled document's ⌘S is Save As: the Finder's save picker (⌘S
#      there) names it, and its bytes are in the file the portal opened;
#   7. closing a document with edits asks: Escape cancels (it stays open),
#      ⌘D is Don't Save (it closes, the file on disk untouched), Return is
#      Save (the edit is on disk, and it closes);
#   8. the Finder opens a .txt in TextEdit — double-clicked, a TextEdit window
#      with it maps (the thing that opens a text file without a terminal).
#
# Usage: abyss/tests/live-textedit.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
portal="$root/.build/debug/abyss-portal"
for b in "$undertow" "$aqua" "$portal"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

W=1024; H=768
work=$(mktemp -d /tmp/abyss-te.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-ter.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${vk_pid:-} ${finder_pid:-} ${te_pid:-} ${portal_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  pkill -f "$work" 2>/dev/null || true
  rm -rf "$work" "$rundir"
}
trap cleanup EXIT INT TERM HUP
log="$work/te.log"
fail() {
  exec 1>&2
  echo "FAIL: $1"
  [ -n "${ABYSS_TEST_KEEP:-}" ] && { rm -rf "$ABYSS_TEST_KEEP"; cp -r "$work" "$ABYSS_TEST_KEEP"; }
  [ -s "$log" ] && grep 'TextEdit:' "$log" | tail -10 | sed 's/^/  te| /'
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

# ------------------------------------------------------------ the files
# "Documents": the Finder window's title, so its place can be seeded.
docs="$work/Documents"; mkdir -p "$docs"
printf 'first line\nsecond needle line\nthird line\n' > "$docs/doc.txt"
printf 'the other file\n' > "$docs/other.txt"

# ------------------------------------------------------------ compositor and portal
mkdir -p "$work/cfg"
cat > "$work/cfg/windows.ini" <<EOF
[windows]
org.abyssbsd.finder = 0,0
org.abyssbsd.finder/Documents = 0,0
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
env HOME="$docs" ABYSS_CONFIG_DIR="$work/cfg" "$portal" > "$work/portal.log" 2>&1 &
portal_pid=$!
i=0; while [ $i -lt 50 ] && [ ! -S "$rundir/portal.sock" ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$rundir/portal.sock" ] || fail "abyss-portal never bound its socket"

# ------------------------------------------------------------ 1. opened
env HOME="$docs" ABYSS_CONFIG_DIR="$work/cfg" ABYSS_TEXTEDIT_DUMP=1 AQUA_SCENE=textedit \
    "$aqua" "$docs/doc.txt" > "$log" 2>&1 &
te_pid=$!
await 'TextEdit: chrome ' 0 "TextEdit never drew its window"
grep -q "TextEdit: opened $docs/doc.txt (4 lines)" "$log" || fail "doc.txt was not opened as 4 lines"
i=0; until grep -q '^window org.abyssbsd.textedit/' "$work/ut.out"; do
  [ $i -ge 150 ] && fail "no org.abyssbsd.textedit window"; sleep 0.1; i=$((i + 1)); done
pos=$(grep '^window org.abyssbsd.textedit/' "$work/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)
wx=${pos%,*}; wy=${pos#*,}
echo "ok: 1. doc.txt opened by path: 4 lines, window at $pos"

mkfifo "$work/pointer" "$work/keys"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" $W $H < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$work/keys" > "$work/vk.log" 2>&1 &
vk_pid=$!
exec 4> "$work/keys"
sleep 1
key() { printf '%s\n' "$1" >&4; sleep 0.25; }
type_() { printf 't %s\n' "$1" >&4; sleep 0.3; }

# Where character (LINE, COL) is on the screen: the text rect and cell the
# window logged, plus its inset (the view draws inset/2 down, inset across).
chrome=$(grep 'TextEdit: chrome ' "$log" | tail -1)
tx=$(echo "$chrome" | sed -n 's/.* text=\([0-9]*\),.*/\1/p'); ty=$(echo "$chrome" | sed -n 's/.* text=[0-9]*,\([0-9]*\),.*/\1/p')
inset=$(echo "$chrome" | sed -n 's/.* inset=\([0-9]*\).*/\1/p')
cw=$(echo "$chrome" | sed -n 's/.* cell=\([0-9.]*\)x.*/\1/p'); ch=$(echo "$chrome" | sed -n 's/.* cell=[0-9.]*x\([0-9.]*\).*/\1/p')
at() {  # at LINE COL — the screen point of the boundary before that character
  awk -v wx="$wx" -v wy="$wy" -v tx="$tx" -v ty="$ty" -v i="$inset" -v cw="$cw" -v ch="$ch" -v l="$1" -v c="$2" \
    'BEGIN { printf "%d %d", wx + tx + i + c * cw + cw * 0.2, wy + ty + i / 2 + l * ch + ch / 2 }'
}

# ------------------------------------------------------------ 2. edited, saved
printf 'm %s\np\nr\n' "$(at 0 5)" >&3; sleep 0.4                # after "first"
type_ ' typed'
key 'c 64 108'                                                    # ⌘↓: the end
type_ 'fourth line'; key 'k 28'
b=$(count 'TextEdit: saved ')
key 'c 64 31'                                                     # ⌘S
await 'TextEdit: saved ' "$b" "⌘S saved nothing"
want=$(printf 'first typed line\nsecond needle line\nthird line\nfourth line\n_'); want=${want%_}
got=$(cat "$docs/doc.txt"; printf _); got=${got%_}
[ "$got" = "$want" ] || fail "the file is not the edit: $(od -c "$docs/doc.txt" | head -3)"
echo "ok: 2. a click at line 1 column 6, typing, ⌘↓ and typing, then ⌘S: the file's bytes are exactly the edit"

# ------------------------------------------------------------ 3. undo
type_ 'XYZ'
b=$(count 'TextEdit: undid ')
key 'c 64 44'                                                     # ⌘Z
await 'TextEdit: undid Typing' "$b" "⌘Z did not undo the typing"
b=$(count 'TextEdit: saved ')
key 'c 64 31'
await 'TextEdit: saved ' "$b" "the second ⌘S saved nothing"
got=$(cat "$docs/doc.txt"; printf _); got=${got%_}
[ "$got" = "$want" ] || fail "after Undo the file changed: $(od -c "$docs/doc.txt" | head -3)"
echo "ok: 3. typing after the save, then ⌘Z (Undo Typing): saved again, the bytes are unchanged"

# ------------------------------------------------------------ 4. find
key 'c 64 33'                                                     # ⌘F
type_ 'needle'
b=$(count 'TextEdit: found ')
key 'k 28'
await 'TextEdit: found 2:8-2:14' "$b" "Find did not find 'needle' at line 2, columns 8–14: $(grep 'TextEdit: found\|not found' "$log" | tail -1)"
key 'k 1'                                                         # Escape: back to the text
type_ 'pin'
b=$(count 'TextEdit: saved ')
key 'c 64 31'
await 'TextEdit: saved ' "$b" "⌘S after the replacement saved nothing"
grep -qx 'second pin line' "$docs/doc.txt" || fail "the found word was not replaced on disk: $(sed -n 2p "$docs/doc.txt")"
echo "ok: 4. ⌘F found 'needle' (line 2, columns 8–14), typing replaced it, and ⌘S put 'second pin line' on disk"

# ------------------------------------------------------------ 5. open through the portal
key 'c 64 24'                                                     # ⌘O
i=0; until grep -q "Finder: listed $docs" "$work/portal.log" 2>/dev/null; do
  [ $i -ge 150 ] && fail "⌘O did not open the Finder on $docs: $(grep 'Finder: listed' "$work/portal.log" | tail -1)"; sleep 0.1; i=$((i + 1)); done
sleep 1.2
# doc.txt, other.txt: other.txt is cell 1 of the seeded Finder (live-gtk's numbers).
b=$(count "TextEdit: opened $docs/other.txt")
printf 'm 142 96\np\nr\np\nr\n' >&3
await "TextEdit: opened $docs/other.txt" "$b" "the file chosen in the Finder did not open in TextEdit" 100
grep -q "handing over $docs/other.txt (read)" "$work/portal.log" || fail "the portal did not hand over other.txt"
echo "ok: 5. ⌘O asked the portal, the Finder chose other.txt, and it opened in a second window"

# ------------------------------------------------------------ 6. Save As through the portal
sleep 0.8
key 'c 64 49'                                                     # ⌘N
await 'TextEdit: opened a new document' 0 "⌘N opened no new document"
sleep 0.8
type_ 'brand new'
n=$(grep -c "Finder: listed $docs" "$work/portal.log" || true)
key 'c 64 31'                                                     # ⌘S on Untitled: Save As
i=0; until [ "$(grep -c "Finder: listed $docs" "$work/portal.log" || true)" -gt "$n" ]; do
  [ $i -ge 150 ] && fail "Save As did not open the Finder's save picker"; sleep 0.1; i=$((i + 1)); done
sleep 1.2
printf 'm 400 300\np\nr\n' >&3; sleep 0.4                         # focus the picker (empty space)
b=$(count "TextEdit: saved $docs/Untitled.txt")
key 'c 64 31'                                                     # ⌘S in the picker: here, as Untitled.txt
await "TextEdit: saved $docs/Untitled.txt" "$b" "Save As did not save to Untitled.txt" 100
[ "$(cat "$docs/Untitled.txt")" = "brand new" ] || fail "Untitled.txt holds: $(od -c "$docs/Untitled.txt" | head -2)"
grep -q "handing over $docs/Untitled.txt (write)" "$work/portal.log" || fail "the portal did not hand over a writable Untitled.txt"
echo "ok: 6. an untitled document's ⌘S went through the Finder's save picker, and Untitled.txt holds 'brand new'"

# ------------------------------------------------------------ 7. closing with edits
sleep 0.8
type_ ' more'                                                     # Untitled.txt, front, now edited
b=$(count 'TextEdit: asked to save changes to Untitled.txt')
key 'c 64 17'                                                     # ⌘W
await 'TextEdit: asked to save changes to Untitled.txt' "$b" "⌘W on an edited document did not ask"
key 'k 1'                                                         # Escape: Cancel
await 'TextEdit: close cancelled' 0 "Escape did not cancel the close"
b=$(count 'TextEdit: asked to save changes to Untitled.txt')
key 'c 64 17'
await 'TextEdit: asked to save changes to Untitled.txt' "$b" "the second ⌘W did not ask"
key 'c 64 32'                                                     # ⌘D: Don't Save
await 'TextEdit: closed Untitled.txt without saving' 0 "⌘D did not close without saving"
[ "$(cat "$docs/Untitled.txt")" = "brand new" ] || fail "Don't Save changed the file: $(cat "$docs/Untitled.txt")"
sleep 0.8
# other.txt's own window: undertow's line for it says where it opened.
opos=$(grep '^window org.abyssbsd.textedit/other.txt' "$work/ut.out" | tail -1 | tr ' ' '\n' | grep -E '^[0-9]+,[0-9]+$' | tail -1)
[ -n "$opos" ] || fail "undertow reported no window for other.txt"
wx=${opos%,*}; wy=${opos#*,}
printf 'm %s\np\nr\n' "$(at 0 0)" >&3; sleep 0.4               # other.txt: its first character
type_ 'edited '
b=$(count 'TextEdit: saved ')
key 'c 64 17'                                                     # ⌘W, then Return: Save
await 'TextEdit: asked to save changes to other.txt' 0 "closing other.txt with edits did not ask"
key 'k 28'
await 'TextEdit: saved ' "$b" "Save in the sheet saved nothing"
[ "$(cat "$docs/other.txt")" = "edited the other file" ] || fail "other.txt holds: $(cat "$docs/other.txt")"
echo "ok: 7. closing with edits asked: Escape kept it open, ⌘D closed it with the file untouched, Return saved the edit and closed"

# ------------------------------------------------------------ 8. the Finder opens a .txt in TextEdit
before=$(grep -c '^window org.abyssbsd.textedit/' "$work/ut.out" || true)
env HOME="$docs" ABYSS_CONFIG_DIR="$work/cfg" ABYSS_FINDER_DIR="$docs" ABYSS_TEXTEDIT_DUMP=1 \
    AQUA_SCENE=finder "$aqua" > "$work/finder.log" 2>&1 &
finder_pid=$!
i=0; until grep -q 'Finder: listed' "$work/finder.log" 2>/dev/null; do
  [ $i -ge 80 ] && fail "the Finder never listed $docs"; sleep 0.25; i=$((i + 1)); done
sleep 1
printf 'm 54 96\np\nr\np\nr\n' >&3                             # doc.txt, cell 0
i=0; until grep -q "opened with TextEdit ($docs/doc.txt)" "$work/finder.log"; do
  [ $i -ge 50 ] && fail "the Finder did not open doc.txt with TextEdit: $(grep -i 'open\|launch' "$work/finder.log" | tail -2)"; sleep 0.1; i=$((i + 1)); done
i=0; until [ "$(grep -c '^window org.abyssbsd.textedit/' "$work/ut.out" || true)" -gt "$before" ]; do
  [ $i -ge 150 ] && fail "no TextEdit window for the Finder's doc.txt"; sleep 0.1; i=$((i + 1)); done
grep -q "TextEdit: opened $docs/doc.txt (" "$work/finder.log" || fail "the launched TextEdit did not open doc.txt"
echo "ok: 8. a double-click in the Finder opened doc.txt in TextEdit"

echo "all green (TextEdit: opened, edited, saved, and its bytes read back)."
