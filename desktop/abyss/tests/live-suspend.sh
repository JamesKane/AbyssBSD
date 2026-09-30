#!/bin/sh
# AbyssBSD Swift DE — an Aqua window, told it cannot be seen, stops drawing
# (BACKLOG T.3).
#
# The toolkit bound xdg-shell v2, so an Aqua window never heard v6's
# `suspended` (undertow sends it since U.2), nor v5's `wm_capabilities`, nor
# v4's `configure_bounds`. Minimised, it drew whenever it was asked — for
# nobody. Now it binds v6. Claims, each against undertow's own account:
#
#   1. the window is told what the compositor serves (maximize, fullscreen,
#      minimize — not a window menu);
#   2. on a display smaller than the window, it keeps within the bounds the
#      compositor gives it;
#   3. minimised (as the Dock does it, `ftctl`), it is told it is suspended;
#   4. a theme change while it is hidden asks it to redraw, and it commits
#      nothing — undertow counts no buffers from hidden windows;
#   5. restored, it is told so, and draws once for what it held back.
#
# Usage: abyss/tests/live-suspend.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
theme="$root/.build/debug/abyss-theme"
[ -x "$undertow" ] && [ -x "$client" ] && [ -x "$theme" ] || swift build

work=$(mktemp -d /tmp/abyss-susp.XXXXXX)
cleanup() {
  for p in ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"
         grep -E 'Surface.Window|Theme:' "$work/app.log" 2>/dev/null | sed 's/^/  app| /' | tail -6
         grep -E '^(hidden-commits|window org.abyssbsd.aquademo)' "$work/ut.out" 2>/dev/null | sed 's/^/  undertow| /' | tail -4
         exit 1; }
await() {  # await FILE PATTERN WHY [SECONDS]
  i=0; n=$(( ${4:-4} * 20 ))
  while ! grep -q -- "$2" "$1" 2>/dev/null && [ $i -lt $n ]; do i=$((i + 1)); sleep 0.05; done
  grep -q -- "$2" "$1" 2>/dev/null || fail "$3"
}

cc -I "$root/de/cwayland/include" "$root/abyss/tests/ftctl.c" \
   "$root/de/cwayland/wlr-foreign-toplevel-management-unstable-v1-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/ftctl" || fail "could not build ftctl"

start() {  # start WIDTH HEIGHT: undertow and the Aqua window, WAYLAND_DISPLAY set
  rm -rf "$work/cfg" 2>/dev/null || true; mkdir -p "$work/cfg"
  env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width "$1" --height "$2" \
      --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
  ut_pid=$!
  i=0; wd=""
  while [ $i -lt 60 ]; do
    wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
    [ -n "$wd" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$wd" ] || fail "undertow never announced a socket"
  export WAYLAND_DISPLAY="$wd"
  env ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=window "$client" > "$work/app.log" 2>&1 &
  app_pid=$!
  # Windows are reported after undertow's 4 s warm-up (§2.83).
  await "$work/ut.out" '^window org.abyssbsd.aquademo[^ ]* -\{0,1\}[0-9]*,[0-9]* [0-9]*x[0-9]*' "the window never mapped" 8
}
box() { grep -E '^window org.abyssbsd.aquademo[^ ]* -?[0-9]+,-?[0-9]+ [0-9]+x[0-9]+' "$work/ut.out" | tail -1 | cut -d' ' -f3-; }
stop() { kill "$app_pid" "$ut_pid" 2>/dev/null || true; wait "$ut_pid" 2>/dev/null || true; app_pid=""; ut_pid=""; }

# ------------------------------------------------------ 2. bounds (a small display)
start 320 240
size=$(box | cut -d' ' -f2)
w=${size%x*}; h=${size#*x}
[ "$w" -le 320 ] && [ "$h" -le 240 ] || fail "on a 320x240 display the window is $size — it did not keep within the bounds"
echo "ok: 2. on a 320x240 display the window keeps within the compositor's bounds ($size)"
stop

# ------------------------------------------------------ 1. capabilities
start 800 600
await "$work/app.log" "Surface.Window: the compositor serves: maximize fullscreen minimize$" \
  "the window was not told what undertow serves (xdg-shell v5's wm_capabilities)"
echo "ok: 1. the window was told what undertow serves: maximize fullscreen minimize — no window menu"

# ------------------------------------------------------ 3. suspended
"$work/ftctl" org.abyssbsd.aquademo minimize > "$work/ft.log" 2>&1 || fail "ftctl: $(cat "$work/ft.log")"
await "$work/app.log" "Surface.Window: suspended" "minimised, the window was not told it is suspended (xdg-shell v6)"
await "$work/ut.out" '^window org.abyssbsd.aquademo.* min$' "undertow did not minimise it"
echo "ok: 3. minimised as the Dock does it, the window was told it is suspended"

# ------------------------------------------------------ 4. nothing for nobody
b=$(grep -c '^Theme: ' "$work/app.log" || true)
ABYSS_CONFIG_DIR="$work/cfg" "$theme" set trench > "$work/theme.log" 2>&1 || fail "abyss-theme set: $(cat "$work/theme.log")"
i=0; while [ "$(grep -c '^Theme: ' "$work/app.log" || true)" -le "$b" ] && [ $i -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
[ "$(grep -c '^Theme: ' "$work/app.log" || true)" -gt "$b" ] || fail "the window never heard the theme change"
sleep 1.5                                          # a second of 1 Hz callbacks, too
last=$(grep '^hidden-commits=' "$work/ut.out" | tail -1)
[ "$last" = "hidden-commits=0" ] || fail "the hidden window committed buffers for nobody: $last"
echo "ok: 4. the theme changed while it was hidden, and it drew nothing — undertow counts no buffers from hidden windows"

# ------------------------------------------------------ 5. back, once
"$work/ftctl" org.abyssbsd.aquademo restore > "$work/ft.log" 2>&1 || fail "ftctl: $(cat "$work/ft.log")"
await "$work/app.log" "Surface.Window: resumed after [1-9][0-9]* redraw(s) held; drawing once" \
  "restored, the window did not say it resumed with a redraw held"
i=0; while box | grep -q ' min$' && [ $i -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
box | grep -q ' min$' && fail "undertow never restored it"
kill -0 "$app_pid" 2>/dev/null || fail "the window died"
echo "ok: 5. restored, it was told so and drew once: $(grep 'Surface.Window: resumed' "$work/app.log" | tail -1 | sed 's/Surface.Window: //')"

echo "all green (an Aqua window hears xdg-shell v6: what is served, how much room, and when nobody can see it)."
