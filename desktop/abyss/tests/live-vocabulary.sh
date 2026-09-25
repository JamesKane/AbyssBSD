#!/bin/sh
# AbyssBSD Swift DE — ask the Finder what it can do, and have it do it (P10.2).
#
# The first consumer of an application's vocabulary is `abyssmenu`, which cannot
# draw a menu at all. If a verb only works from the menu bar, the surface is a
# drawing routine and not a vocabulary (PLAN.md, Phase 10) — so this test drives
# a real Finder, on our own compositor, with no pointer and no keyboard.
#
# Every claim is checked on the thing, not on the reply (§2.44):
#
#   - `describe` lists the Finder's verbs, each with its sentence, its key and
#     whether it can run now — and Paste is disabled *with its reason* while the
#     clipboard is empty;
#   - a disabled or impossible verb is `refused` with the reason, exits 1, and
#     does nothing (§2.37: the refusal is the control);
#   - `file.new-folder` returns the path it made, and **the folder is on disk**;
#   - `go.to-folder` checks its typed argument — a relative path, a missing one
#     and a misspelt one are each refused by name — and a good one moves the
#     window, which the Finder's own log confirms;
#   - a Finder running as a portal's **picker publishes nothing**: a vocabulary
#     there would let any process choose a file for the person.
#
# Usage: abyss/tests/live-vocabulary.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
menu="$root/.build/debug/abyssmenu"
[ -x "$undertow" ] && [ -x "$aqua" ] && [ -x "$menu" ] || swift build

work=$(mktemp -d /tmp/abyss-vocab.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-vocr.XXXXXX)
cleanup() {
  for p in ${pick_pid:-} ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" "$rundir"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
export ABYSS_RUNTIME_DIR="$rundir"

# The folder the Finder shows, and a subfolder to go to.
dir="$work/files"
mkdir -p "$dir/Sub" "$work/cfg" "$work/home/.Trash"
printf 'hello\n' > "$dir/Read Me.txt"

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

env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" HOME="$work/home" \
    ABYSS_FINDER_DIR="$dir" AQUA_SCENE=finder "$aqua" > "$work/finder.log" 2>&1 &
app_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q 'Finder: menus on menus.finder.' "$work/finder.log" 2>/dev/null \
    && grep -q "Finder: listed $dir " "$work/finder.log" && break
  kill -0 "$app_pid" 2>/dev/null || fail "the Finder exited: $(cat "$work/finder.log")"
  sleep 0.25; i=$((i + 1))
done
grep -q 'Finder: menus on menus.finder.' "$work/finder.log" \
  || fail "the Finder never published its menus: $(tail -5 "$work/finder.log")"
echo "ok: the Finder is up and publishing its vocabulary"

# ------------------------------------------------------------------ list
"$menu" list > "$work/list.out" || fail "abyssmenu list failed"
grep -q "^Finder	menus.finder.$app_pid\$" "$work/list.out" \
  || fail "list does not show this Finder: $(cat "$work/list.out")"
echo "ok: list names it — $(cat "$work/list.out")"

# -------------------------------------------------------------- describe
"$menu" describe finder > "$work/describe.out" || fail "describe failed"
grep -q '^app Finder$' "$work/describe.out" || fail "describe named no app"
for verb in file.new-folder file.duplicate edit.paste go.to-folder finder.empty-trash; do
  grep -q "^  $verb	" "$work/describe.out" || fail "describe is missing $verb"
done
grep -q '^  file.new-folder	New Folder	⇧⌘N	enabled$' "$work/describe.out" \
  || fail "New Folder is not enabled with its key: $(grep new-folder "$work/describe.out")"
grep -q '^    Make an untitled folder here and name it.$' "$work/describe.out" \
  || fail "a verb arrived without its sentence"
grep -q '^  edit.paste	Paste	⌘V	disabled (the clipboard is empty)$' "$work/describe.out" \
  || fail "Paste is not disabled-with-a-reason: $(grep edit.paste "$work/describe.out")"
grep -q '^    arg path: path — The folder to go to.$' "$work/describe.out" \
  || fail "go.to-folder does not declare its typed argument"
n=$(grep -c '^  [a-z]*\.[a-z-]*	' "$work/describe.out")
[ "$n" -ge 30 ] || fail "describe listed only $n verbs"
echo "ok: describe lists $n verbs, each with a sentence, a key and its state"

# --------------------------------------------------------------- refusals
# Each must exit 1, say why, and change nothing. These are the control: a
# vocabulary that said "ok" to everything would pass every check below them.
refuse() {  # refuse "<reason>" args...
  want=$1; shift
  set +e
  "$menu" run finder "$@" > "$work/run.out" 2> "$work/run.err"
  rc=$?
  set -e
  [ "$rc" = 1 ] || fail "run $* exited $rc, expected 1 (refused): $(cat "$work/run.out" "$work/run.err")"
  grep -qF "$want" "$work/run.err" || fail "run $* refused for the wrong reason: $(cat "$work/run.err")"
  echo "ok: run $* — refused: $want"
}
before=$(ls "$dir" | sort | tr '\n' ,)
refuse "the clipboard is empty" edit.paste
refuse "nothing is selected" file.duplicate
refuse "the Finder cannot do this yet" finder.about
refuse "Finder has no verb file.dance" file.dance
refuse "go.to-folder needs path (path)" go.to-folder
refuse "path must be an absolute path, not Sub" go.to-folder path=Sub
refuse "go.to-folder takes no argument pth" go.to-folder pth=/tmp path=/tmp
# Everything above was refused by the SERVICE — the verb, its arguments or its
# enablement — so the Finder's perform never saw it.
grep -q 'Finder: command ' "$work/finder.log" \
  && fail "a refused command reached the Finder's perform: $(grep 'Finder: command' "$work/finder.log")"
echo "ok: seven refusals by the service, and none reached the Finder's perform"
# This one is the Finder's own: well-formed, enabled, and impossible, which
# only the application can know.
refuse "is not a folder" go.to-folder "path=$dir/Read Me.txt"
[ "$(ls "$dir" | sort | tr '\n' ,)" = "$before" ] || fail "a refused command changed the folder"
echo "ok: and one by the Finder itself; the folder is untouched"

# ------------------------------------------------------------- a real verb
out=$("$menu" run finder file.new-folder) || fail "file.new-folder was refused: $out"
[ "$out" = "ok $dir/untitled folder" ] || fail "file.new-folder returned '$out'"
[ -d "$dir/untitled folder" ] || fail "file.new-folder said ok and made nothing"
echo "ok: file.new-folder returned '$out' — and the folder is on disk"

out=$("$menu" run finder go.to-folder "path=$dir/Sub") || fail "go.to-folder was refused: $out"
[ "$out" = "ok $dir/Sub" ] || fail "go.to-folder returned '$out'"
i=0
while [ $i -lt 20 ]; do
  grep -q "Finder: opened $dir/Sub" "$work/finder.log" && break
  sleep 0.1; i=$((i + 1))
done
grep -q "Finder: opened $dir/Sub" "$work/finder.log" \
  || fail "go.to-folder said ok and the window did not move: $(tail -3 "$work/finder.log")"
echo "ok: go.to-folder moved the window, by the Finder's own account"

# -------------------------------------------------- unreachable is not refused
set +e
"$menu" describe nosuchapp > /dev/null 2>&1; rc=$?
set -e
[ "$rc" = 2 ] || fail "an application that is not running exited $rc, expected 2"
echo "ok: an application that is not there exits 2, not 1"

# ---------------------------------------------------------------- a picker
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" HOME="$work/home" \
    ABYSS_FINDER_DIR="$dir" ABYSS_FINDER_PICK="$work/picked" AQUA_SCENE=finder \
    "$aqua" > "$work/picker.log" 2>&1 &
pick_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q "Finder: listed $dir " "$work/picker.log" 2>/dev/null && break
  kill -0 "$pick_pid" 2>/dev/null || fail "the picker exited: $(cat "$work/picker.log")"
  sleep 0.25; i=$((i + 1))
done
grep -q "Finder: listed $dir " "$work/picker.log" || fail "the picker never came up"
grep -q 'menus on' "$work/picker.log" && fail "a picker published its vocabulary"
"$menu" list | grep -q "menus.finder.$pick_pid" && fail "a picker is on the list"
[ "$("$menu" run finder file.new-window 2>&1 >/dev/null; echo $?)" != 2 ] \
  || fail "the picker made 'finder' ambiguous or unreachable"
echo "ok: a Finder that is a picker publishes nothing"

echo "all green (a vocabulary, not a drawing)."
