#!/bin/sh
# AbyssBSD Swift DE — the clipboard actually crosses a process boundary (P9.1).
#
# Two of our own processes and our own compositor: one `abyssclip copy` holds a
# selection, another `abyssclip paste` reads it. Against **undertow**, because
# the thing under test is undertow's `request_set_selection` handler — running
# this on sway would prove that sway has a clipboard, which was never in doubt.
#
# **What this can and cannot prove, stated because the difference is the whole
# finding of P9.1.**
#
# `wl_data_device.set_selection` carries the serial of the input event that
# caused it, and wlroots checks it:
#
#     Rejecting set_selection request, serial 0 was never given to client
#
# That is the protocol working. **A client may only take the clipboard in
# response to input it actually received** — which is what stops a background
# process quietly owning your selection. `abyssclip` has no surface, so it
# receives no input, so it has no serial and cannot legitimately copy. A real
# clipboard CLI uses `wlr-data-control` for exactly this reason, and that is a
# decision this pass records rather than makes (PHASE9 §6.7).
#
# So this asserts the two halves that are real today:
#
#   - an empty clipboard reads as **empty**, not as a stale value or an error —
#     the negative case, exercised, because a probe with no negative control
#     measures nothing (§2.37);
#   - a copy with no input behind it is **refused by name**, so the safety
#     property is pinned rather than assumed, and the compositor is demonstrably
#     receiving and judging the request rather than ignoring it as it did before
#     P9.1.
#
# The round trip belongs to P9.2, where the Finder copies from a ⌘C that has a
# serial because a person pressed it.
#
# **What this script cannot cover, said here so nobody assumes otherwise:** it
# uses two processes throughout, so it never exercises copy and paste in the
# *same* one — which is the first thing anybody does with a clipboard, and the
# case that deadlocks if a client reads a selection it owns. `fileops` in
# `run-live.sh` is what covers that, and it is how the deadlock was found.
#
# Usage: abyss/tests/live-clipboard.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
clip="$root/.build/debug/abyssclip"
[ -x "$undertow" ] && [ -x "$clip" ] || swift build

work=$(mktemp -d /tmp/abyss-clip.XXXXXX)
cleanup() {
  for p in ${vk_pid:-} ${finder2_pid:-} ${finder_pid:-} ${copy_pid:-} ${ut_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $1"; [ -f "$work/ut.err" ] && sed 's/^/    /' "$work/ut.err"; exit 1; }

# ------------------------------------------------------------ the compositor
#
# `--frames 0` — until stopped. Before P4.4 this binary could only run a fixed
# count, and a test that has to outlive its own compositor is exactly the shape
# that needed it.
# `--verbose` because the refusal below is wlroots' own DEBUG line, and the
# default is `tw_log_silence()`. A test that asserts on a log has to ask for it.
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --verbose --width 800 --height 600 \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""
i=0
while [ $i -lt 80 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || fail "undertow exited before it announced a socket"
  sleep 0.25; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
echo "ok: undertow is up on $wd"

# ------------------------------------------------- nothing on it to start with
if out=$(env WAYLAND_DISPLAY="$wd" "$clip" paste 2>"$work/empty.err"); then
  fail "an untouched clipboard returned '$out' instead of being empty"
fi
grep -q "clipboard is empty" "$work/empty.err" \
  || fail "an empty clipboard did not say so: $(cat "$work/empty.err")"
echo "ok: an untouched clipboard is empty, and says so rather than guessing"

# ------------------------------------------ a copy nothing asked for is refused
#
# The client offers, the compositor judges, and with no input behind it the
# answer is no. Before P9.1 this request reached a compositor that had no
# handler for it at all — the same silence for a legitimate copy and an
# illegitimate one.
secret="the medium reaches the stick $$"
env WAYLAND_DISPLAY="$wd" "$clip" copy "$secret" > "$work/copy.out" 2>&1 &
copy_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q "offering" "$work/copy.out" 2>/dev/null && break
  kill -0 "$copy_pid" 2>/dev/null || fail "the copier exited: $(cat "$work/copy.out")"
  sleep 0.25; i=$((i + 1))
done
grep -q "offering" "$work/copy.out" || fail "the copier never offered anything"

# Give the compositor a moment to have judged it.
sleep 1
grep -q "Rejecting set_selection request" "$work/ut.err" \
  || fail "a copy with no input behind it was not refused — the serial check is
    what stops a background process taking the clipboard, and nothing said no"
echo "ok: a copy with no input serial is refused, by name — the protocol's own guard"

# ...and the clipboard is still empty, because nothing was accepted.
if out=$(env WAYLAND_DISPLAY="$wd" "$clip" paste 2>/dev/null); then
  fail "the refused copy landed anyway: '$out'"
fi
echo "ok: ...and nothing reached the clipboard, so the refusal was real"

# ============================================================ P9.2: a real copy
#
# **The round trip P9.1 could not reach.** Everything above establishes that a
# copy needs an input serial; this is a copy that has one, because a keystroke
# caused it. The Finder is the client, ⌘C is the event, and the paste is a
# *different process* — which is the whole claim, since ⌘C in one Finder window
# and ⌘V in another has worked since P2.6c against a field that never left the
# process.
kill "$copy_pid" 2>/dev/null || true; copy_pid=""

aqua="$root/.build/debug/AquaDemo"
[ -x "$aqua" ] || fail "no AquaDemo"
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping the Finder half"; exit 0; }

# A seeded directory, so what the Finder lists — and therefore what ⌘C copies —
# is identical on every machine. The Finder sorts folders first, so "Read Me.txt"
# is the last row and the one Down-Down-Down-Down reaches.
finderdir=$(mktemp -d "$work/finder.XXXXXX")
mkdir -p "$finderdir/Applications" "$finderdir/Documents" "$finderdir/Pictures"
printf 'Welcome to AbyssBSD.\n' > "$finderdir/Read Me.txt"

kxml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
wayland-scanner client-header "$kxml" "$work/vkeyboard-proto.h"
wayland-scanner private-code  "$kxml" "$work/vkeyboard-proto.c"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" \
   || fail "could not build the virtual keyboard"

env WAYLAND_DISPLAY="$wd" ABYSS_FINDER_DIR="$finderdir" ABYSS_CONFIG_DIR="$work/cfg" \
    AQUA_SCENE=finder "$aqua" > "$work/finder.log" 2>&1 &
finder_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q "Finder:" "$work/finder.log" 2>/dev/null && break
  kill -0 "$finder_pid" 2>/dev/null || fail "the Finder exited: $(cat "$work/finder.log")"
  sleep 0.25; i=$((i + 1))
done

kfifo="$work/keys"
mkfifo "$kfifo"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$kfifo" > "$work/vk.log" 2>&1 &
vk_pid=$!
exec 4> "$kfifo"
sleep 1.5

# Down to the last row, then ⌘C. `c 64 46` is the Logo modifier and 'c' — the
# same driver the Finder's other shortcut tests use.
printf 'k 108 108 108 108\n' >&4
sleep 0.7
printf 'c 64 46\n' >&4
sleep 1.5

grep -q "copied .*Read Me.txt" "$work/finder.log" \
  || fail "the Finder did not copy anything: $(tail -3 "$work/finder.log")"
grep -q "offered to the desktop" "$work/finder.log" \
  || fail "the Finder copied locally only — the selection never reached the seat:
    $(grep copied "$work/finder.log" | tail -1)"
echo "ok: the Finder copied Read Me.txt with a serial from the ⌘C that caused it"

# ------------------------------------------- a SECOND Finder pastes it
#
# **Not `abyssclip paste`, and the reason is the other half of P9.1's finding.**
# `wl_data_device.selection` is delivered only to the client with keyboard
# focus — so a surfaceless tool cannot *read* the clipboard either, for the same
# reason it cannot write one. Which makes the honest end-to-end test the real
# thing: a second Finder, in a different directory, which takes focus when it
# maps and is handed the selection because of it.
#
# And the assertion is the file on disk, not a log line (§2.43): the claim is
# "⌘C here, ⌘V there, and the file is there", so that is what gets checked.
finderdir2=$(mktemp -d "$work/finder2.XXXXXX")
env WAYLAND_DISPLAY="$wd" ABYSS_FINDER_DIR="$finderdir2" ABYSS_CONFIG_DIR="$work/cfg2" \
    AQUA_SCENE=finder "$aqua" > "$work/finder2.log" 2>&1 &
finder2_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q "Finder: listed" "$work/finder2.log" 2>/dev/null && break
  kill -0 "$finder2_pid" 2>/dev/null || fail "the second Finder exited: $(cat "$work/finder2.log")"
  sleep 0.25; i=$((i + 1))
done
sleep 1.5

# ⌘V. The keyboard follows focus, and focus followed the new window.
printf 'c 64 47\n' >&4
sleep 2

[ -f "$finderdir2/Read Me.txt" ] || fail "nothing was pasted into the second Finder:
    $(ls -a "$finderdir2" | tr '\n' ' ')
    $(tail -3 "$work/finder2.log")"
grep -q "Welcome to AbyssBSD" "$finderdir2/Read Me.txt" \
  || fail "a file arrived but its contents are wrong"
echo "ok: a second Finder pasted the file — copied in one process, written by another"

exec 4>&- 2>/dev/null || true
kill "$vk_pid" "$finder_pid" "$finder2_pid" 2>/dev/null || true
sleep 0.5
accepted=$(grep -c '^selections-accepted=' "$work/ut.out" || true)
[ "${accepted:-0}" -ge 1 ] \
  || fail "undertow never reported accepting a selection, so the paste above
    matched something it should not have"
echo "ok: undertow accepted it — the copy went through our own compositor"

echo "all green (⌘C in one Finder, ⌘V in another, and the file is on disk)."
