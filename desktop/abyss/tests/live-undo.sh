#!/bin/sh
# AbyssBSD Swift DE — undo, decided (P10.5).
#
# Undo is per window and a command like any other (PHASE10 §6.3): `edit.undo`
# and `edit.redo` are verbs, and the Edit menu's two rows are derived from the
# window's stack — their titles and whether they can run. This drives a real
# Finder with `abyssmenu`, with the menu bar on the privileged socket as the
# witness that a changed title is *pushed* to it, and checks every undo on disk:
#
#   1. Nothing to undo: Undo is called "Undo" and is disabled, with a reason.
#   2. File ▸ New Folder → Undo is now "Undo New Folder", and the bar was told
#      the vocabulary changed (the first real customer of `subscribe`).
#   3. Undo puts the folder in the Trash — never deletes it — and Redo takes it
#      back out.
#   4. Move to Trash, undone, is back where it was.
#   5. **An undo the world has moved under is refused with the reason and stays
#      on the stack**: something now occupies the old name; clear it, and the
#      same undo succeeds.
#
# Usage: abyss/tests/live-undo.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
menu="$root/.build/debug/abyssmenu"
[ -x "$undertow" ] && [ -x "$aqua" ] && [ -x "$menu" ] || swift build

work=$(mktemp -d /tmp/abyss-undo.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-undor.XXXXXX)
priv="abyss-ubar-$$"
cleanup() {
  for p in ${finder_pid:-} ${bar_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
export ABYSS_RUNTIME_DIR="$rundir"

count() { grep -cF "$2" "$1" 2>/dev/null || true; }
after() {  # after FILE STRING N WHAT
  i=0
  while [ $i -lt 50 ]; do
    [ "$(count "$1" "$2")" -gt "$3" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  fail "$4 — $(tail -3 "$1")"
}
# undo_row — the Undo row as describe reports it: "title<TAB>key<TAB>state".
undo_row() { "$menu" describe finder | grep "^  edit.undo	" | cut -f2-; }

dir="$work/files"
trash="$work/home/.Trash"
mkdir -p "$dir" "$trash" "$work/cfg"
printf 'hello\n' > "$dir/Read Me.txt"

env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" --privileged-socket "$priv" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
after "$work/ut.out" "WAYLAND_PRIVILEGED=$priv" 0 "undertow never came up"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)

env WAYLAND_DISPLAY="$priv" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar \
    "$aqua" > "$work/bar.log" 2>&1 &
bar_pid=$!
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" HOME="$work/home" \
    ABYSS_FINDER_DIR="$dir" AQUA_SCENE=finder "$aqua" > "$work/finder.log" 2>&1 &
finder_pid=$!
after "$work/bar.log" "showing Finder's menus from menus.finder.$finder_pid" 0 \
  "the bar never showed the Finder's menus"
echo "ok: a Finder, and a bar subscribed to it"

# ------------------------------------------------------------ 1. nothing yet
[ "$(undo_row)" = "Undo	⌘Z	disabled (there is nothing to undo)" ] \
  || fail "with nothing done, Undo is '$(undo_row)'"
echo "ok: Undo is disabled — there is nothing to undo"

# --------------------------------------------------- 2. a change, and its name
changed=$(count "$work/bar.log" "vocabulary changed; redescribed")
out=$("$menu" run finder file.new-folder) || fail "new-folder refused: $out"
folder="$dir/untitled folder"
[ -d "$folder" ] || fail "no folder on disk"
[ "$(undo_row)" = "Undo New Folder	⌘Z	enabled" ] \
  || fail "after New Folder, Undo is '$(undo_row)'"
after "$work/bar.log" "vocabulary changed; redescribed" "$changed" \
  "the bar was never told Undo's title changed"
echo "ok: Undo is now 'Undo New Folder', and the bar was told"

# ----------------------------------------------- 3. undo is the Trash, not rm
out=$("$menu" run finder edit.undo) || fail "undo refused: $out"
[ ! -e "$folder" ] || fail "undo said '$out' and the folder is still there"
[ -d "$trash/untitled folder" ] || fail "undo deleted the folder instead of trashing it"
echo "ok: Undo New Folder put it in the Trash ($out)"
out=$("$menu" run finder edit.redo) || fail "redo refused: $out"
[ -d "$folder" ] && [ ! -e "$trash/untitled folder" ] || fail "redo did not bring it back"
echo "ok: Redo took it back out"

# --------------------------------------------------- 4. move to trash, undone
out=$("$menu" run finder file.move-to-trash) || fail "move-to-trash refused: $out"
[ ! -e "$folder" ] || fail "move-to-trash left the folder"
[ "$(undo_row)" = "Undo Move to Trash	⌘Z	enabled" ] || fail "Undo is '$(undo_row)'"
out=$("$menu" run finder edit.undo) || fail "undo refused: $out"
[ -d "$folder" ] || fail "undoing Move to Trash did not bring it back"
echo "ok: Move to Trash, undone, is back where it was"

# ------------------------------------------- 5. the world moved: refused, kept
"$menu" run finder file.move-to-trash > /dev/null || fail "move-to-trash refused"
mkdir "$folder"   # someone else takes the name
set +e
"$menu" run finder edit.undo > "$work/u.out" 2> "$work/u.err"; rc=$?
set -e
[ "$rc" = 1 ] || fail "undo into an occupied name exited $rc: $(cat "$work/u.out")"
grep -q 'something called untitled folder is in the way' "$work/u.err" \
  || fail "refused for the wrong reason: $(cat "$work/u.err")"
[ "$(undo_row)" = "Undo Move to Trash	⌘Z	enabled" ] \
  || fail "a refused undo fell off the stack: '$(undo_row)'"
rmdir "$folder"
out=$("$menu" run finder edit.undo) || fail "the same undo, with the way clear, was refused: $out"
[ -d "$folder" ] || fail "the retried undo did not bring it back"
echo "ok: an undo the world moved under is refused with the reason, kept, and works once clear"

echo "all green (undo is a command, per window, and never deletes)."
