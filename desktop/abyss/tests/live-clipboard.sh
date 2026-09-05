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
  for p in ${copy_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
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

echo "all green (the compositor now judges selections; P9.2 copies one with a serial)."
