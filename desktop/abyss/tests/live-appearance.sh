#!/bin/sh
# AbyssBSD Swift DE — the theme changes while the desktop runs (PHASE14 P14.2).
#
# The choice lives in appearance.ini (`abyss-theme set`, and the General pane,
# write it by atomic rename); every process that draws watches the config
# directory and follows. PHASE14 §6.7 names the traps: a process that misses
# the change, and a cached picture from the old theme that survives it. So each
# section switches Aqua -> Trench -> Aqua and checks the same pixels three
# times: they CHANGE, and then they come back **byte for byte** — a stale cache
# anywhere shows up as a difference on the way back.
#
#   1. undertow's server-side frames
#   2. every toolkit process: the desktop, the menu bar, the Dock, and an
#      ordinary Aqua window — each process says it reloaded (its `Theme:` line),
#      and each one's pixels change and come back
#   3. the portal: abyss-dbus asks the palette again and emits SettingChanged,
#      decoded by `gdbus monitor` — GLib, the D-Bus library a GTK application
#      listens with — and ReadOne agrees (skipped without dbus-daemon/gdbus)
#   4. System Preferences' General pane drives all of it: a click on Trench, a
#      scheme, a setting dragged and released, and Aqua again — each written to
#      appearance.ini by the pane and followed by every process. (The window
#      covers most of the output, so sections 1–3 are where pixels are compared.)
#
# Usage: abyss/tests/live-appearance.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
theme="$root/.build/debug/abyss-theme"
grab="$root/.build/debug/abyssgrab"
[ -x "$undertow" ] && [ -x "$theme" ] && [ -x "$grab" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

W=800
H=600
work=$(mktemp -d /tmp/abyss-appearance.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${prefs_pid:-} ${app_pid:-} ${win_pid:-} ${shell_pids:-} ${mon_pid:-} ${bridge_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  [ -s "$work/buspid" ] && kill "$(cat "$work/buspid")" 2>/dev/null || true
  [ -n "${KEEP:-}" ] && echo "kept $work" || rm -rf "$work"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
mkdir -p "$work/cfg"
export ABYSS_CONFIG_DIR="$work/cfg"
unset ABYSS_THEME ABYSS_THEME_SCHEME

# Wait until `file` has more than `since` lines matching `pattern`.
after() {  # after FILE PATTERN SINCE WHY
  i=0
  while [ $i -lt 60 ]; do
    [ "$(grep -c -- "$2" "$1" 2>/dev/null || true)" -gt "$3" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "$4"
}

# A window that asks undertow to draw its frame.
deco_xml=""
for d in /usr/share/wayland-protocols /usr/local/share/wayland-protocols; do
  [ -f "$d/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" ] \
    && deco_xml="$d/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"
done
[ -n "$deco_xml" ] || { echo "SKIP: no xdg-decoration XML in wayland-protocols"; exit 0; }
wayland-scanner client-header "$deco_xml" "$work/xdg-decoration-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$deco_xml" "$work/xdg-decoration-unstable-v1-protocol.c"
cc -I"$work" -I "$root/de/cwayland/include" "$root/abyss/tests/adversary.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/xdg-decoration-unstable-v1-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/adversary" \
   || fail "could not build the decorated client"

"$theme" set aqua || fail "abyss-theme could not choose aqua"
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width "$W" --height "$H" \
    --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
after "$work/ut.out" '^WAYLAND_DISPLAY=' 0 "undertow never announced a socket"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)
grep -q '^Theme: Aqua from ' "$work/ut.err" || fail "undertow did not start in Aqua: $(grep '^Theme:' "$work/ut.err")"

# The portal, on a bus of its own, and GLib listening to it.
portal=0
if command -v dbus-daemon >/dev/null 2>&1 && command -v gdbus >/dev/null 2>&1; then
  portal=1
  busaddr=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$work/buspid")
  env DBUS_SESSION_BUS_ADDRESS="$busaddr" "$root/.build/debug/abyss-dbus" \
      > "$work/bridge.out" 2> "$work/bridge.err" &
  bridge_pid=$!
  after "$work/bridge.out" '^ready' 0 "abyss-dbus never came up: $(cat "$work/bridge.err")"
  env DBUS_SESSION_BUS_ADDRESS="$busaddr" gdbus monitor --session \
      --dest org.freedesktop.portal.Desktop > "$work/monitor" 2>&1 &
  mon_pid=$!
  sleep 0.5
else
  echo "note: no dbus-daemon or gdbus — section 3 (the portal) is skipped"
fi
ask() {  # ask KEY — org.freedesktop.appearance, as a toolkit reads it
  env DBUS_SESSION_BUS_ADDRESS="$busaddr" gdbus call --session --dest org.freedesktop.portal.Desktop \
    --object-path /org/freedesktop/portal/desktop \
    --method org.freedesktop.portal.Settings.ReadOne org.freedesktop.appearance "$1" 2>&1
}
# The portal told GLib, and ReadOne agrees: color-scheme is now $1.
told() {  # told SCHEME WHY
  [ "$portal" = 1 ] || return 0
  after "$work/monitor" "SettingChanged ('org.freedesktop.appearance', 'color-scheme', <uint32 $1>)" \
    "$(grep -c "SettingChanged ('org.freedesktop.appearance', 'color-scheme', <uint32 $1>)" "$work/monitor.before" 2>/dev/null || true)" \
    "$2: no SettingChanged(color-scheme = $1) reached GLib"
  case "$(ask color-scheme)" in *"uint32 $1"*) ;; *) fail "$2: ReadOne says $(ask color-scheme)" ;; esac
}

# The shell, and an ordinary Aqua window — every one a process of its own,
# each told of the change by nobody but its own watch. The status items are
# pinned as the golden gate pins them; the clock is not, so the bar is compared
# on its left half, where the menus are.
demo="$root/.build/debug/AquaDemo"
mkdir -p "$work/desk"
shell_pids=""
for scene in wallpaper menubar dock window; do
  env WAYLAND_DISPLAY="$wd" ABYSS_DESKTOP_DIR="$work/desk" ABYSS_FINDER_DIR="$work/desk" \
      ABYSS_FAKE_VOLUME=60 ABYSS_FAKE_BATTERY=80 AQUA_SCENE="$scene" "$demo" \
      > "$work/$scene.log" 2>&1 &
  shell_pids="$shell_pids $!"
done
for scene in wallpaper menubar dock window; do
  after "$work/$scene.log" '^Theme: Aqua from ' 0 "the $scene process did not start in Aqua"
done
after "$work/ut.out" '^window org.abyssbsd.aquademo/AbyssBSD ' 0 "the Aqua window never mapped"
wg=$(grep '^window org.abyssbsd.aquademo/AbyssBSD ' "$work/ut.out" | tail -1 | cut -d' ' -f3,4)
wx=${wg%%,*}; wrest=${wg#*,}; wy=${wrest%% *}; wsize=${wg#* }; ww=${wsize%x*}

env WAYLAND_DISPLAY="$wd" "$work/adversary" decorated 300 160 > "$work/app.log" 2>&1 &
app_pid=$!
key="org.abyssbsd.undecorated/Foreign"
after "$work/ut.out" "^window $key " 0 "the decorated window never mapped"
after "$work/ut.out" '^frame-rasterisations=[1-9]' 0 "undertow never drew the window's frame"
g=$(grep "^window $key " "$work/ut.out" | tail -1 | cut -d' ' -f3,4)
sx=${g%%,*}; rest=${g#*,}; sy=${rest%% *}; size=${g#* }; sw=${size%x*}
echo "ok: a window wearing undertow's frame, at $sx,$sy, in Aqua"

hdr_len=$(printf 'P6\n%s %s\n255\n' "$W" "$H" | wc -c | tr -d ' ')
row() {  # row PPM X Y N -> the raw bytes of N pixels of one row
  dd if="$1" bs=1 skip=$((hdr_len + ((($3 * W) + $2) * 3))) count=$(($4 * 3)) 2>/dev/null | od -An -v -tu1
}
# One strip per thing that draws, each a row it and only it owns:
#   frame    undertow's title bar, 5 px above the decorated window's pixels
#   window   an Aqua window's own title bar, 8 px into its surface
#   bar      the menu bar's left half (the clock, on the right, is live)
#   dock     the Dock's shelf, 12 px above the bottom, across the middle
#   desktop  the wallpaper, down the left side, under the bar
STRIPS="frame window bar dock desktop"
shot() {  # shot NAME
  env WAYLAND_DISPLAY="$wd" "$grab" "$work/$1.ppm" > /dev/null 2>&1 || fail "screencopy failed ($1)"
  row "$work/$1.ppm" "$sx" $((sy - 5)) "$sw" > "$work/$1.frame"
  row "$work/$1.ppm" "$wx" $((wy + 8)) "$ww" > "$work/$1.window"
  row "$work/$1.ppm" 0 11 $((W / 2)) > "$work/$1.bar"
  row "$work/$1.ppm" $((W / 4)) $((H - 12)) $((W / 2)) > "$work/$1.dock"
  row "$work/$1.ppm" 0 120 60 > "$work/$1.desktop"
}
# Every one of these must have changed between two shots...
changed() {  # changed A B WHY
  for s in $STRIPS; do
    cmp -s "$work/$1.$s" "$work/$2.$s" && fail "$3: the $s did not change"
  done
  return 0
}
# ...or be byte-for-byte what it was.
same() {  # same A B WHY
  for s in $STRIPS; do
    cmp -s "$work/$1.$s" "$work/$2.$s" || fail "$3: the $s is not what it was"
  done
  return 0
}
switch() {  # switch THEME [SCHEME]
  n=$(grep -c '^theme-reloads=' "$work/ut.out" || true)
  counts=""
  for scene in wallpaper menubar dock window; do
    counts="$counts $(grep -c '^Theme: ' "$work/$scene.log" || true)"
  done
  pn=$(grep -c 'the theme changed' "$work/bridge.err" 2>/dev/null || true)
  cp "$work/monitor" "$work/monitor.before" 2>/dev/null || true
  "$theme" set "$@" || fail "abyss-theme could not choose $*"
  after "$work/ut.out" '^theme-reloads=' "$n" "undertow never noticed the theme change to $*"
  [ "$portal" = 1 ] && after "$work/bridge.err" 'the theme changed' "$pn" "abyss-dbus never noticed the theme change to $*"
  set -- $counts
  for scene in wallpaper menubar dock window; do
    after "$work/$scene.log" '^Theme: ' "$1" "the $scene process never followed the change"
    shift
  done
  sleep 0.4                          # a frame or two, drawn in the new theme
}

sleep 0.3
shot aqua
switch trench
grep -q '^Theme: Trench' "$work/ut.err" || fail "undertow reloaded, but not Trench: $(grep '^Theme:' "$work/ut.err" | tail -1)"
shot trench
changed aqua trench "Aqua -> Trench"
for scene in wallpaper menubar dock window; do
  grep '^Theme: ' "$work/$scene.log" | tail -1 | grep -q '^Theme: Trench' \
    || fail "the $scene process reloaded, but not Trench"
done
echo "ok: 1. undertow followed Aqua -> Trench with no restart, and redrew the frame"
echo "ok: 2. so did the desktop, the menu bar, the Dock and an Aqua window — each its own process"
told 1 "Aqua -> Trench"
[ "$portal" = 1 ] && echo "ok: 3. the portal told GLib: SettingChanged(color-scheme = 1, prefer dark), and ReadOne agrees"

# **A switch that changes only colours.** Aqua -> Trench changes the title
# bar's height too, so the frame's size changes and any cache misses by
# accident; two schemes of one theme keep every metric and change only the
# paint — the case where only the theme's identity in the cache key can tell
# the old frame from the new (§6.7). With it removed, this is where it fails.
switch trench daylight
shot daylight
cmp -s "$work/trench.frame" "$work/daylight.frame" \
  && fail "Trench's daylight scheme drew the same frame as neon — the frame cache does not know the theme changed"
changed trench daylight "neon -> daylight"
told 2 "neon -> daylight"
echo "ok:    ...and neon -> daylight, same metrics, new colours: every one redrawn (and prefer light, said)"

switch aqua
shot aqua-again
same aqua aqua-again "back in Aqua, something from Trench survived"
if [ "$portal" = 1 ]; then
  case "$(ask accent-color)" in *"0.247"*"0.435"*"0.874"*) ;; *) fail "back in Aqua, the portal's accent is $(ask accent-color)" ;; esac
  kill -0 "$bridge_pid" 2>/dev/null || fail "abyss-dbus exited during the switches"
fi
kill -0 "$ut_pid" 2>/dev/null || fail "undertow exited during the switches"
for p in $shell_pids; do kill -0 "$p" 2>/dev/null || fail "a shell process exited during the switches"; done
echo "ok:    ...and back to Aqua, byte for byte, everywhere: nothing from Trench survived"

# --------------------------------------------- 4. the General pane drives it
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build the virtual pointer"

env WAYLAND_DISPLAY="$wd" ABYSS_PREFS_DUMP=1 AQUA_SCENE=sysprefs "$demo" > "$work/prefs.log" 2>&1 &
prefs_pid=$!
after "$work/prefs.log" 'SystemPreferences: layout ' 0 "System Preferences never drew its grid"
after "$work/ut.out" '^window org.abyssbsd.preferences/' 0 "undertow never reported System Preferences"
pg=$(grep '^window org.abyssbsd.preferences/' "$work/ut.out" | head -1 | awk '{print $(NF-1)}')
px=${pg%,*}; py=${pg#*,}
at() {  # at LINE-PREFIX NAME -> "X Y" on the output, from the app's latest line
  p=$(grep "SystemPreferences: $1" "$work/prefs.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$2=//p")
  [ -n "$p" ] || fail "System Preferences does not say where $2 is"
  echo "$((px + ${p%,*})) $((py + ${p#*,}))"
}
mkfifo "$work/vp.fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" "$W" "$H" < "$work/vp.fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/vp.fifo"
after "$work/vp.log" 'ready' 0 "the virtual pointer never bound"
sleep 0.3

printf 'm %s\np\nr\n' "$(at 'layout ' general)" >&3
after "$work/prefs.log" 'SystemPreferences: appearance theme\.' 0 "a click on General did not show the theme's controls"
echo "ok: 4. System Preferences' General pane shows the installed themes"

# A click on a control writes appearance.ini, and everybody follows — the
# same `switch` bookkeeping as above, with the pane doing the writing.
pane() {  # pane CONTROL EXPECT-LOG WHY
  n=$(grep -c '^theme-reloads=' "$work/ut.out" || true)
  w=$(grep -c "SystemPreferences: appearance -> $2" "$work/prefs.log" || true)
  printf 'm %s\np\nr\n' "$(at 'appearance theme\.' "$1")" >&3
  after "$work/prefs.log" "SystemPreferences: appearance -> $2" "$w" "$3: the pane did not write it"
  after "$work/ut.out" '^theme-reloads=' "$n" "$3: undertow never followed"
}

before=""
for scene in wallpaper menubar dock window; do
  before="$before $(grep -c '^Theme: Trench' "$work/$scene.log" || true)"
done
pane theme.trench "trench" "Trench, chosen in the pane"
set -- $before
for scene in wallpaper menubar dock window; do
  after "$work/$scene.log" '^Theme: Trench' "$1" "the $scene process did not follow the pane to Trench"
  shift
done
grep -q '^theme = trench$' "$work/cfg/appearance.ini" || fail "appearance.ini does not say trench: $(cat "$work/cfg/appearance.ini")"
told 1 "Trench, from the pane"
echo "ok:    a click on Trench: written, and the desktop, the bar, the Dock, a window, undertow and the portal followed"

after "$work/prefs.log" 'SystemPreferences: appearance .*scheme\.daylight=' 0 "the pane never offered Trench's schemes"
pane scheme.daylight "trench (daylight)" "the daylight scheme, chosen in the pane"
told 2 "daylight, from the pane"
echo "ok:    a click on Daylight: written, and prefer light told"

# A setting: pressed near the left of its track, dragged, released — written
# once, on release, to two places.
after "$work/prefs.log" 'SystemPreferences: appearance .*param\.gk=' 0 "the pane never offered Trench's settings"
# The layout line, not the write log that also starts "appearance ": an empty
# match here made shell arithmetic press at "68 + + 5" — on the title bar.
track=$(grep 'SystemPreferences: appearance theme\.' "$work/prefs.log" | tail -1 | tr ' ' '\n' | sed -n 's/^param\.gk=//p')
[ -n "$track" ] || fail "the pane's layout does not say where gk's track is"
x0=${track%%-*}; rest=${track#*-}; x1=${rest%%,*}; ty=${rest#*,}
n=$(grep -c '^theme-reloads=' "$work/ut.out" || true)
printf 'm %s %s\np\nm %s %s\nm %s %s\nr\n' $((px + x0 + 5)) $((py + ty)) \
  $((px + x0 + 20)) $((py + ty)) $((px + x0 + (x1 - x0) / 4)) $((py + ty)) >&3
after "$work/prefs.log" 'SystemPreferences: appearance -> trench (daylight) gk=0\.2' 0 \
  "dragging gk to a quarter of its track did not write gk=0.25: $(grep 'appearance ->' "$work/prefs.log" | tail -1)"
after "$work/ut.out" '^theme-reloads=' "$n" "a setting changed and undertow never followed"
grep -q '^gk = 0\.2' "$work/cfg/appearance.ini" || fail "appearance.ini does not carry the setting: $(cat "$work/cfg/appearance.ini")"
echo "ok:    gk dragged to a quarter and released: written once, as $(grep '^gk' "$work/cfg/appearance.ini")"

pane theme.aqua "aqua" "Aqua, chosen in the pane"
for scene in wallpaper menubar dock window; do
  grep '^Theme: ' "$work/$scene.log" | tail -1 | grep -q '^Theme: Aqua' || {
    sleep 1; grep '^Theme: ' "$work/$scene.log" | tail -1 | grep -q '^Theme: Aqua' \
      || fail "the $scene process did not follow the pane back to Aqua"; }
done
grep -q 'scheme\|gk' "$work/cfg/appearance.ini" && fail "back to Aqua, Trench's scheme or setting was kept: $(cat "$work/cfg/appearance.ini")"
echo "ok:    a click on Aqua: everyone back, and Trench's scheme and setting not carried over"

echo "all green (the theme changes while the desktop runs)."
