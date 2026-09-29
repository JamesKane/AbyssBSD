#!/bin/sh
# AbyssBSD Swift DE — the desktop hears a key before the application does (P9.5).
#
# Until this pass `Seat` forwarded every key straight to
# `wlr_seat_keyboard_notify_key`, so Cmd-Tab did nothing and there was nowhere
# for a shortcut to live. The table decides; this checks that the decision is
# real in both directions, which is the whole contract:
#
#   - a **bound** key is answered by the compositor and **never reaches the
#     focused client**;
#   - an **unbound** key still reaches it, untouched — the failure in the other
#     direction is a desktop where an application can never receive a
#     combination, and it is the one §6.2 is written about;
#   - an application that **keeps** a combination gets it anyway, which is that
#     section's decision made into data.
#
# Usage: abyss/tests/live-keys.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$aqua" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-keys.XXXXXX)
cleanup() {
  exec 4>&- 2>/dev/null || true
  for p in ${vk_pid:-} ${app2_pid:-} ${app_pid:-} ${ut_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

# The table under test. Written before the compositor starts, because the
# defaults are compiled in and this file has to *override* them — which is
# itself the claim that a person can rebind anything.
mkdir -p "$work/cfg"
cat > "$work/cfg/keys.ini" <<INI
[keys]
Cmd+Tab = next-window
Cmd+e = run: /usr/bin/touch $work/keybind-ran
Cmd+w = close-window
Cmd+r = close-window

[passthrough]
org.abyssbsd.aquademo = Cmd+w
INI

env -u WAYLAND_DISPLAY ABYSS_CONFIG_DIR="$work/cfg" "$undertow" run --frames 0 \
    --config-dir "$work/cfg" --width 800 --height 600 \
    > "$work/ut.out" 2> "$work/ut.err" &
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

# A window that reports what it receives. The `--type` scene echoes typed
# characters into its field and logs them, which is exactly the witness this
# test needs: what the client got, in the client's own words.
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=widgets \
    "$aqua" > "$work/app.log" 2>&1 &
app_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q 'AquaWindow' "$work/app.log" 2>/dev/null && break
  kill -0 "$app_pid" 2>/dev/null || fail "the window exited: $(cat "$work/app.log")"
  sleep 0.25; i=$((i + 1))
done
sleep 1

kxml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
wayland-scanner client-header "$kxml" "$work/vkeyboard-proto.h"
wayland-scanner private-code  "$kxml" "$work/vkeyboard-proto.c"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" \
   || fail "could not build the virtual keyboard"
kfifo="$work/keys"
mkfifo "$kfifo"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$kfifo" > "$work/vk.log" 2>&1 &
vk_pid=$!
exec 4> "$kfifo"
sleep 1.5

# ------------------------------------------------- an unbound key gets through
#
# The negative control, and it goes first: if plain typing did not reach the
# client, every "the compositor consumed it" result below would be vacuous.
printf 't a\n' >&4
sleep 0.8
grep -q "AquaWindow: key .* 'a'" "$work/app.log" \
  || fail "an unbound key did not reach the application at all:
    $(tail -3 "$work/app.log")"
echo "ok: an unbound key reaches the application — the control this rests on"

# --------------------------------------------------- a bound key is consumed
#
# `c 64 18` is Logo and the 'e' key — bound above to a command. The compositor
# must answer it, and the application must never see an 'e'.
printf 'c 64 18\n' >&4
sleep 1
i=0
while [ $i -lt 20 ]; do
  grep -q '^keybinds-fired=1' "$work/ut.out" 2>/dev/null && break
  sleep 0.25; i=$((i + 1))
done
grep -q '^keybinds-fired=1' "$work/ut.out" \
  || fail "the compositor did not answer a bound key: $(tail -3 "$work/ut.err")"
echo "ok: the compositor answered Cmd-E (its own table, not the defaults)"

# It ran the command — and the assertion is the file on disk (§2.43), not a log.
i=0
while [ $i -lt 20 ]; do
  [ -f "$work/keybind-ran" ] && break
  sleep 0.25; i=$((i + 1))
done
[ -f "$work/keybind-ran" ] \
  || fail "the bound key fired but its command never ran"
echo "ok: ...and the command it names actually ran"

# ...and the application never saw it. This is the half that makes the first
# half mean anything: a compositor that ran the command *and* passed the key on
# would look identical up to here.
! grep -q "AquaWindow: key .* 'e'" "$work/app.log" \
  || fail "the bound key was answered AND forwarded — the client got an 'e' too:
    $(grep 'AquaWindow: key' "$work/app.log" | tail -3)"
echo "ok: ...and the application never saw the key the desktop took"

# ------------------------------------ an application that keeps a combination
#
# §6.2's decision, live: `Cmd+W` is bound to close-window *and* listed as
# passthrough for this application, so the window must stay open and the key
# must arrive. Get this wrong in the other direction and a terminal can never
# receive a combination the desktop happens to want.
fired_before=$(grep -c '^keybinds-fired=' "$work/ut.out" || true)
printf 'c 64 17\n' >&4
sleep 1
grep -q "AquaWindow: key .* 'w'" "$work/app.log" \
  || fail "a combination this application keeps never reached it:
    $(grep 'AquaWindow: key' "$work/app.log" | tail -3)"
kill -0 "$app_pid" 2>/dev/null \
  || fail "the compositor closed the window anyway — passthrough did nothing"
grep -q '^keybinds-fired=2' "$work/ut.out" \
  && fail "the compositor acted on a binding the application had kept"
echo "ok: an application that keeps Cmd-W gets Cmd-W, and its window stays open"

# ------------------------------------------------ the verbs, not just commands
#
# **Cmd-Tab is what Phase 13 is blocked on**, so it is checked here rather than
# assumed: the switcher's *interface* is that phase's, the binding and the raise
# are this one's. Focus is invisible from outside — the only witness is the
# client being told it is activated — so a second window goes up and the
# question is which of the two says so.
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=widgets \
    "$aqua" > "$work/app2.log" 2>&1 &
app2_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q 'AquaWindow: activated' "$work/app2.log" 2>/dev/null && break
  kill -0 "$app2_pid" 2>/dev/null || fail "the second window exited: $(cat "$work/app2.log")"
  sleep 0.25; i=$((i + 1))
done
# The loop above can only *stop*; this is what makes it an assertion. A wait
# that falls through and prints "ok" is the shape of a test that cannot fail.
grep -q 'AquaWindow: activated' "$work/app2.log" \
  || fail "the second window never reported focus:
    $(tail -3 "$work/app2.log")"
echo "ok: a second window opened and took focus"

# Cmd-Tab goes to the window you were in before this one, so focus must land
# back on the first — which is the one that has to say "activated" again.
first_before=$(grep -c 'AquaWindow: activated' "$work/app.log" || true)
printf 'c 64 15\n' >&4
sleep 1.2
first_after=$(grep -c 'AquaWindow: activated' "$work/app.log" || true)
[ "$first_after" -gt "$first_before" ] \
  || fail "Cmd-Tab did not move focus back to the first window
    first window: $(tail -2 "$work/app.log")
    second: $(tail -2 "$work/app2.log")"
echo "ok: Cmd-Tab moved focus to the other window — the raise Phase 13 needs"

# And a verb that reaches the client as a request: close-window asks, and this
# application obliges by exiting.
printf 'c 64 19\n' >&4
i=0
while [ $i -lt 20 ]; do
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 0.25; i=$((i + 1))
done
kill -0 "$app_pid" 2>/dev/null \
  && fail "close-window did not reach the focused window"
app_pid=""
echo "ok: close-window asked the focused window to close, and it did"

kill "$app2_pid" 2>/dev/null || true
exec 4>&- 2>/dev/null || true
echo "all green (bound keys are the desktop's, kept ones are the application's)."
