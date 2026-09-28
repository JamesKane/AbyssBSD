#!/bin/sh
# AbyssBSD Swift DE — a client is told when its frames were shown (U.4).
#
# undertow offered no wp_presentation, so a toolkit could only estimate when a
# frame reached the display (F-101; docs/API-STUDY.md §2) — while the
# compositor held the answer for its own frame contract. `abyss/tests/present.c`
# asks for feedback on every commit and summarises 120 presented frames; this
# runs it at two display rates, because a time that only matched 60 Hz could
# be an assumption rather than a measurement.
#
# Claims:
#   - every commit paced by frame callbacks is PRESENTED, none discarded — the
#     scene tells wlroots which surfaces each frame contained;
#   - on the clock the compositor named, which is CLOCK_MONOTONIC;
#   - strictly increasing, never ahead of the client's own reading of that
#     clock, and arriving within a few frames;
#   - spaced at the display's period — 60 Hz and 144 Hz each — not at a
#     constant;
#   - `refresh` is the period, or 0: headless has no hardware clock, and 0 is
#     the protocol's word for "unknown". On DRM wlroots fills it from the mode.
#
# Usage: abyss/tests/live-present.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-present.XXXXXX)
cleanup() {
  [ -n "${ut_pid:-}" ] && kill "$ut_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

xml=""
for d in /usr/share/wayland-protocols /usr/local/share/wayland-protocols; do
  [ -f "$d/stable/presentation-time/presentation-time.xml" ] \
    && xml="$d/stable/presentation-time/presentation-time.xml"
done
[ -n "$xml" ] || { echo "SKIP: no presentation-time XML in wayland-protocols"; exit 0; }
wayland-scanner client-header "$xml" "$work/presentation-time-client-protocol.h"
wayland-scanner private-code  "$xml" "$work/presentation-time-protocol.c"
cc -I"$work" -I "$root/de/cwayland/include" "$root/abyss/tests/present.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/presentation-time-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/present" \
   || fail "could not build the client"

field() { echo "$line" | awk -v k="$1" '{ for (i = 1; i < NF; i++) if ($i == k) { print $(i + 1); exit } }'; }

for hz in 60 144; do
  env -u WAYLAND_DISPLAY "$undertow" run --hz "$hz" --frames 0 --width 800 --height 600 \
      --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
  ut_pid=$!
  wd=""; i=0
  while [ $i -lt 80 ]; do
    wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
    [ -n "$wd" ] && break
    kill -0 "$ut_pid" 2>/dev/null || { cat "$work/ut.err"; fail "undertow exited before it announced a socket"; }
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$wd" ] || fail "undertow never announced a socket"

  line=$(env WAYLAND_DISPLAY="$wd" timeout 20 "$work/present" 2>&1 | grep '^present:' | tail -1) || true
  kill "$ut_pid"; wait "$ut_pid" 2>/dev/null || true; ut_pid=""
  [ -n "$line" ] || fail "at $hz Hz the client printed nothing"
  case "$line" in *"no wp_presentation"*) fail "undertow offers no wp_presentation" ;; esac

  period=$((1000000000 / hz))
  [ "$(field mono)" = 1 ] || fail "at $hz Hz the presentation clock is $(field clock), not CLOCK_MONOTONIC: $line"
  [ "$(field presented)" = 120 ] && [ "$(field discarded)" = 0 ] \
    || fail "at $hz Hz $(field presented) presented and $(field discarded) discarded — frames were not said to be shown: $line"
  [ "$(field monotonic)" = 1 ] || fail "at $hz Hz presentation times went backwards: $line"
  [ "$(field seq)" = 1 ] || fail "at $hz Hz the sequence counter went backwards: $line"
  [ "$(field future)" = 0 ] || fail "at $hz Hz a frame was said to be shown in the future: $line"
  oldest=$(field oldest)
  [ "$oldest" -lt $((period * 4)) ] || fail "at $hz Hz feedback trailed its frame by ${oldest} ns — more than four periods: $line"
  median=$(field median)
  lo=$((period * 85 / 100)); hi=$((period * 115 / 100))
  [ "$median" -ge "$lo" ] && [ "$median" -le "$hi" ] \
    || fail "at $hz Hz frames were ${median} ns apart, not the display's ${period} ns: $line"
  refresh=$(field refresh)
  if [ "$refresh" != 0 ]; then
    [ "$refresh" -ge $((period * 98 / 100)) ] && [ "$refresh" -le $((period * 102 / 100)) ] \
      || fail "at $hz Hz refresh is ${refresh} ns, neither the period nor 0 (unknown): $line"
  fi
  echo "ok: at $hz Hz, 120 frames presented, ${median} ns apart (period ${period}), arriving within ${oldest} ns, refresh ${refresh}, flags $(field flags)"
done

echo "all green (a client is told when its frames were shown, at the display's rate)."
