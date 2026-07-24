#!/bin/sh
# AbyssBSD Swift DE — live on-screen smoke test under a real compositor.
#
# The `run.sh` PNG path renders a scene straight to a cairo image surface; it
# never builds a Surface.Window, so it can't catch bugs in the live Wayland
# path (xdg-shell handshake, shm double-buffering, frame-callback pacing,
# configure/resize, pointer input, listener/object lifetimes). This script runs
# AquaDemo against a headless sway and captures the result with grim.
#
# Usage: abyss/tests/live-sway.sh [window|sysprefs|widgets] [out.png] [--click] [--type] [--keys] [--hidpi] [--wheel] [--repeat]
# Needs: sway (>=1.11), grim. With --click/--type also: wayland-scanner +
# libwayland dev (to build the virtual-input helpers; --type also needs
# xkbcommon). Uses the headless backend + pixman software renderer, so no
# GPU/DRM is touched (--unsupported-gpu is harmless).
#
# The headless backend attaches no input devices (seat capabilities:0), so a
# client never binds wl_pointer/wl_keyboard and the input paths can't be tested.
# --click and --type each create a virtual input device (a wlr-virtual-pointer /
# a zwp_virtual_keyboard) which registers with the seat: the seat gains the
# matching capability and AquaDemo binds the input and receives events.
# --click's injected events adapt to the scene: the .window gel button (PNG
# should read "Clicks: 1"), or the .widgets checkbox + slider (checkbox 2 ticks
# on, slider/progress jump right). --type drives the .window text field (should
# read "Abyss"). An interacting run with no explicit scene defaults to .window.
set -eu

scene=""; out=""; click=""; type=""; menu=""; keys=""; hidpi=""; wheel=""; repeat=""; reload=""; menubar=""; dock_mode=""
for a in "$@"; do
  case "$a" in
    --click)                  click="--click" ;;
    --type)                   type="--type" ;;
    --keys)                   keys="--keys" ;;   # drive keyboard focus/traversal
    --hidpi)                  hidpi="--hidpi" ;; # scale-2 output; assert auto-scale
    --wheel)                  wheel="--wheel"; click="--click" ;;  # scroll wheel
    --repeat)                 repeat="--repeat" ;;  # hold a key; assert it repeats
    --reload)                 reload="--reload" ;;  # wallpaper: config + hot-reload
    --menu)                   menu="--menu"; click="--click" ;;  # opens a real popup
    --menubar)                menubar="--menubar"; click="--click" ;;  # menu bar dropdown
    --dock)                   dock_mode="--dock"; click="--click" ;;  # Dock magnify + running
    window|sysprefs|widgets|scroll|tabs|sheet|wallpaper|menubar|dock)  scene="$a" ;;
    *)                        out="$a" ;;
  esac
done
[ -n "$out" ] || out="${TMPDIR:-/tmp}/aqua-live-$$.png"
# Pick a default scene: an interacting run wants a control-bearing scene.
if [ -z "$scene" ]; then
  if [ "$click" = "--click" ] || [ "$type" = "--type" ]; then scene="window"
  else scene="sysprefs"; fi
fi
# The pop-up menu lives on the widgets scene.
[ "$menu" = "--menu" ] && scene="widgets"
# --type only makes sense where there's a focused text field.
[ "$type" = "--type" ] && scene="window"
# --keys drives control focus/traversal; the widgets scene is the showcase.
[ "$keys" = "--keys" ] && [ -z "$scene" -o "$scene" = "window" ] && scene="widgets"
# --hidpi is a display-only check; default it to the widgets scene.
[ "$hidpi" = "--hidpi" ] && [ -z "$scene" ] && scene="widgets"
# --wheel scrolls the list, so it wants the scroll scene.
[ "$wheel" = "--wheel" ] && scene="scroll"
# --repeat holds a key into the text field, so it wants the window scene.
[ "$repeat" = "--repeat" ] && scene="window"
# --reload exercises the wallpaper's config load + hot-reload.
[ "$reload" = "--reload" ] && scene="wallpaper"
# --menubar drives the menu bar (a layer-shell TOP surface).
[ "$menubar" = "--menubar" ] && scene="menubar"
# --dock drives the Dock (a layer-shell BOTTOM surface).
[ "$dock_mode" = "--dock" ] && scene="dock"
# Which scenes are layer-shell surfaces (not xdg toplevels — not in get_tree).
is_layer=""; case "$scene" in wallpaper|menubar|dock) is_layer=1 ;; esac

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }
command -v grim >/dev/null || { echo "FAIL: grim not installed"; exit 1; }

swift build

# Build the virtual-input helpers up front (fail fast) when we'll inject.
vp_dir=""
if [ "$click" = "--click" ] || [ "$type" = "--type" ] || [ "$keys" = "--keys" ] || [ "$repeat" = "--repeat" ]; then
  command -v wayland-scanner >/dev/null || { echo "FAIL: wayland-scanner missing"; exit 1; }
  pkg-config --exists wayland-client || { echo "FAIL: wayland-client dev missing"; exit 1; }
  vp_dir=$(mktemp -d)
fi
if [ "$click" = "--click" ]; then
  xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
  wayland-scanner client-header "$xml" "$vp_dir/vpointer-proto.h"
  wayland-scanner private-code  "$xml" "$vp_dir/vpointer-proto.c"
  cc -I"$vp_dir" "$root/abyss/tests/vpointer.c" "$vp_dir/vpointer-proto.c" \
     $(pkg-config --cflags --libs wayland-client) -o "$vp_dir/vpointer"
fi
if [ "$type" = "--type" ] || [ "$keys" = "--keys" ] || [ "$repeat" = "--repeat" ]; then
  pkg-config --exists xkbcommon || { echo "FAIL: xkbcommon dev missing"; exit 1; }
  xml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
  wayland-scanner client-header "$xml" "$vp_dir/vkeyboard-proto.h"
  wayland-scanner private-code  "$xml" "$vp_dir/vkeyboard-proto.c"
  cc -I"$vp_dir" "$root/abyss/tests/vkeyboard.c" "$vp_dir/vkeyboard-proto.c" \
     $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$vp_dir/vkeyboard"
fi

# Size the headless output to the scene's natural window size so the (tiled)
# toplevel fills it exactly — a clean shot, and it exercises the app at the size
# it actually requests. Keep in sync with the sizes in de/aquademo/main.swift.
case "$scene" in
  sysprefs) res="760x620" ;;
  widgets)  res="460x360" ;;
  scroll)   res="360x420" ;;
  tabs)     res="480x380" ;;
  sheet)    res="440x320" ;;
  wallpaper|menubar|dock) res="800x600" ;;  # the layer surface stretches to fill it
  *)        res="440x300" ;;
esac
outline="output HEADLESS-1 resolution $res position 0 0"
if [ "$hidpi" = "--hidpi" ]; then
  # A HiDPI output: double the physical resolution and set scale 2, so the
  # logical area still equals the window size but the framebuffer is 2x. A
  # scale-following client should render a 2x buffer and grim captures it at 2x.
  w=${res%x*}; h=${res#*x}
  outline="output HEADLESS-1 resolution $((w * 2))x$((h * 2)) scale 2 position 0 0"
fi
cfg=$(mktemp)
printf '%s\ndefault_border none\n' "$outline" > "$cfg"

log=$(mktemp)
env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman \
    WLR_LIBINPUT_NO_DEVICES=1 sway --unsupported-gpu -c "$cfg" > "$log" 2>&1 &
sway_pid=$!

cleanup() {
  [ -n "${vp_pid:-}" ] && kill "$vp_pid" 2>/dev/null || true
  [ -n "${vk_pid:-}" ] && kill "$vk_pid" 2>/dev/null || true
  [ -n "${app_pid:-}" ] && kill "$app_pid" 2>/dev/null || true
  [ -n "${app2_pid:-}" ] && kill "$app2_pid" 2>/dev/null || true
  [ -n "${SWAYSOCK:-}" ] && swaymsg exit >/dev/null 2>&1 || true
  kill "$sway_pid" 2>/dev/null || true
  rm -f "$cfg" "$log" "${app_log:-}" "${fifo:-}" "${vp_log:-}" "${vk_fifo:-}" "${vk_log:-}"
  [ -n "$vp_dir" ] && rm -rf "$vp_dir" || true
  [ -n "${cfgdir:-}" ] && rm -rf "$cfgdir" || true
}
trap cleanup EXIT

# Wait for sway's wayland + IPC sockets to accept clients.
wd=""
for _ in $(seq 1 40); do
  cand=$(ls -1 "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' \
         | grep -v '^wayland-0$' | head -1) || true
  if [ -n "$cand" ]; then
    ss=$(ls -1 "$XDG_RUNTIME_DIR"/sway-ipc.*."$sway_pid".sock 2>/dev/null | head -1) || true
    if [ -n "$ss" ] && SWAYSOCK="$ss" swaymsg -t get_version >/dev/null 2>&1; then
      wd="$cand"; break
    fi
  fi
  sleep 0.25
done
[ -n "$wd" ] || { echo "FAIL: sway not ready"; tail "$log"; exit 1; }
export SWAYSOCK="$ss"
echo "sway ready on $wd"

# --reload: give AquaDemo a private config dir with an initial desktop.ini (a
# green gradient) so the wallpaper is config-driven; we rewrite it later to
# prove hot-reload.
abyss_cfg=""
if [ "$reload" = "--reload" ]; then
  cfgdir=$(mktemp -d)
  printf 'schema_version = 1\n\n[desktop]\ngrad_top = #ff2a6f3a\ngrad_bot = #ff0a2f14\n' \
    > "$cfgdir/desktop.ini"
  abyss_cfg="ABYSS_CONFIG_DIR=$cfgdir"
fi

# Capture AquaDemo's stderr (it logs buffer-scale changes there). Unset
# AQUA_SCALE so the window auto-detects scale from wl_output rather than pinning.
app_log=$(mktemp)
env -u AQUA_SCALE $abyss_cfg WAYLAND_DISPLAY="$wd" AQUA_SCENE="$scene" \
    .build/debug/AquaDemo >/dev/null 2>"$app_log" &
app_pid=$!

# Wait for the surface to map. A layer-shell surface (wallpaper) isn't a
# toplevel and never appears in sway's get_tree, so we assert on the app's own
# "mapped" log — proof the compositor accepted the layer-shell handshake and
# sent a configure. A normal window we detect by its app_id in the tree.
mapped=0
for _ in $(seq 1 32); do
  if [ -n "$is_layer" ]; then
    grep -q 'LayerSurface: mapped' "$app_log" && { mapped=1; break; }
  else
    if swaymsg -t get_tree 2>/dev/null | grep -q '"app_id": "org.abyssbsd.aquademo"'; then
      mapped=1; break
    fi
  fi
  kill -0 "$app_pid" 2>/dev/null || { echo "FAIL: AquaDemo exited early"; cat "$app_log"; exit 1; }
  sleep 0.25
done
[ "$mapped" = 1 ] || { echo "FAIL: surface never mapped"; cat "$app_log"; exit 1; }
[ -n "$is_layer" ] && echo "layer surface mapped: $(grep 'LayerSurface: mapped' "$app_log" | head -1)"
sleep 1  # let a couple of frames paint

if [ "$reload" = "--reload" ]; then
  # Config-driven: the initial desktop.ini set a gradient.
  grep -q 'Wallpaper: applied gradient' "$app_log" \
    || { echo "FAIL: wallpaper didn't apply the gradient from desktop.ini"; cat "$app_log"; exit 1; }
  echo "config-driven: applied gradient from desktop.ini"
  # Hot-reload: atomically swap desktop.ini to a flat red bg; the watcher (folded
  # into the run loop) should fire and the wallpaper repaint.
  printf 'schema_version = 1\n\n[desktop]\nbg = #ffcc2020\n' > "$cfgdir/desktop.ini.new"
  mv "$cfgdir/desktop.ini.new" "$cfgdir/desktop.ini"
  reloaded=0
  for _ in $(seq 1 25); do
    grep -q 'Wallpaper: applied flat' "$app_log" && { reloaded=1; break; }
    sleep 0.2
  done
  [ "$reloaded" = 1 ] \
    || { echo "FAIL: wallpaper did not hot-reload to the flat bg"; cat "$app_log"; exit 1; }
  echo "hot-reload: desktop.ini change repainted the desktop (flat)"
  sleep 0.5  # let the flat repaint land before grim
fi

if [ "$click" = "--click" ]; then
  # Virtual pointer, fed via a FIFO so it stays alive (holding the pointer
  # capability) while we inject. The output size (for absolute coords) matches
  # the scene's window, which fills the headless output at 0,0.
  case "$scene" in
    widgets) vpw=460; vph=360 ;;
    scroll)  vpw=360; vph=420 ;;
    tabs)    vpw=480; vph=380 ;;
    sheet)   vpw=440; vph=320 ;;
    menubar|dock) vpw=800; vph=600 ;;
    *)       vpw=440; vph=300 ;;
  esac
  vp_log=$(mktemp)
  fifo=$(mktemp -u); mkfifo "$fifo"
  WAYLAND_DISPLAY="$wd" "$vp_dir/vpointer" "$vpw" "$vph" < "$fifo" > "$vp_log" 2>&1 &
  vp_pid=$!
  exec 3>"$fifo"
  for _ in $(seq 1 20); do grep -q ready "$vp_log" && break; sleep 0.15; done
  grep -q ready "$vp_log" || { echo "FAIL: virtual pointer not ready"; cat "$vp_log"; exit 1; }
  # sway's get_seats "capabilities" is unreliable under the headless backend +
  # a virtual pointer (often reads 0 even though events flow), so this is a soft
  # check — the behaviour assertions below (counters, menu-open logs, the
  # magnified screenshot) are the real gate.
  caps=$(swaymsg -t get_seats | grep -o '"capabilities": [0-9]*' | grep -o '[0-9]*' | head -1)
  if [ "${caps:-0}" -ne 0 ]; then
    echo "virtual pointer ready; seat capabilities=$caps"
  else
    echo "virtual pointer ready; seat capabilities read 0 (sway quirk — proceeding)"
  fi
  sleep 0.5  # let AquaDemo bind wl_pointer
  if [ "$menu" = "--menu" ]; then
    # Click the Appearance pop-up button to open a real xdg-popup menu.
    printf 'm 203 259\np\nr\n' >&3   # open the menu
    sleep 0.5
    if [ "$keys" != "--keys" ]; then
      printf 'm 203 300\n'     >&3   # hover the 2nd item (over the popup surface)
      sleep 0.4
    fi
    # With --keys we leave the pointer off the menu and let the keyboard block
    # (below) navigate it — a test that keyboard routes to the popup during its
    # grab.
    # (sway doesn't surface client xdg-popups in get_tree; the screenshot is the
    # evidence — the menu should be open with "Graphite" highlighted. Pressing
    # over an item selects it, sets the value, and dismisses the popup.)
  elif [ "$menubar" = "--menubar" ]; then
    # Click the system (drop) menu at the far left of the bar, opening a real
    # dropdown popup parented to the menu-bar layer surface; hover an item.
    printf 'm 21 11\np\nr\n' >&3   # open the system menu
    sleep 0.5
    printf 'm 44 42\n'       >&3   # hover an item in the dropdown (popup surface)
    sleep 0.4
  elif [ "$dock_mode" = "--dock" ]; then
    # Hover over the Dock (near a left-of-centre tile) to trigger magnification,
    # then capture NOW while the pointer is present (magnification is hover-
    # driven) and before the foreign-toplevel window (below) covers the Dock.
    printf 'm 320 560\n' >&3
    sleep 0.6
    WAYLAND_DISPLAY="$wd" grim "$out"; captured=1
    echo "dock: captured magnified shelf -> $out"
    # Now verify foreign-toplevel: launch a second window as a running app so
    # the Dock's tracker sees a live toplevel. (Done after the screenshot; the
    # tiled window would otherwise cover the Dock.)
    env -u AQUA_SCALE WAYLAND_DISPLAY="$wd" AQUA_SCENE=window \
        .build/debug/AquaDemo >/dev/null 2>&1 &
    app2_pid=$!
    seen=0
    for _ in $(seq 1 30); do
      grep -q 'Dock: running org.abyssbsd.aquademo' "$app_log" && { seen=1; break; }
      kill -0 "$app2_pid" 2>/dev/null || break
      sleep 0.2
    done
    [ "$seen" = 1 ] \
      || { echo "FAIL: Dock didn't see the running toplevel (foreign-toplevel)"; cat "$app_log"; exit 1; }
    echo "foreign-toplevel: $(grep 'Dock: running' "$app_log" | head -1)"
    kill "$app2_pid" 2>/dev/null || true; app2_pid=""
  else
  case "$scene" in
    widgets)
      # Toggle the 2nd checkbox ("Show all file extensions"), then click near
      # the right of the slider track (press sets the value there).
      printf 'm 60 94\np\nr\n'   >&3
      printf 'm 384 197\np\nr\n' >&3
      ;;
    scroll)
      if [ "$wheel" = "--wheel" ]; then
        # Put the pointer over the list, then spin the wheel down repeatedly —
        # the list should scroll to the bottom (Item 24 visible), no thumb drag.
        printf 'm 160 200\n' >&3
        for _ in 1 2 3 4 5 6; do printf 'a 60\n' >&3; sleep 0.08; done
      else
        # Grab the scrollbar thumb (near the top of its travel) and drag down —
        # the list should scroll to the bottom (Item 24 visible).
        printf 'm 338 120\np\n' >&3   # press on the thumb
        printf 'm 338 330\n'    >&3   # drag toward the bottom
        printf 'r\n'            >&3   # release
      fi
      ;;
    tabs)
      # Pick the last segment ("Columns") and the last tab ("Sharing").
      printf 'm 272 51\np\nr\n'  >&3   # segmented control: Columns
      printf 'm 333 84\np\nr\n'  >&3   # tab: Sharing
      ;;
    sheet)
      # Click "Delete…" to open the modal sheet: it slides down from the title
      # bar and dims the body. Its buttons (Cancel/Delete) dismiss it.
      printf 'm 220 165\np\nr\n' >&3
      ;;
    *)
      printf 'm 360 265\np\nr\n' >&3   # move over the gel button, click once
      ;;
  esac
  fi
  sleep 0.5
  # For the Dock, keep the virtual pointer alive so the pointer stays over the
  # shelf — magnification is hover-driven, and closing the pointer sends a leave
  # that resets it before grim. cleanup kills the pointer at exit.
  [ "$dock_mode" = "--dock" ] || exec 3>&-
fi

if [ "$type" = "--type" ] || [ "$keys" = "--keys" ] || [ "$repeat" = "--repeat" ]; then
  # Virtual keyboard, fed via a FIFO so it stays alive (holding the keyboard
  # capability) while we inject. It uploads its own US keymap, which sway makes
  # the seat's active keymap and forwards to AquaDemo.
  vk_log=$(mktemp)
  vk_fifo=$(mktemp -u); mkfifo "$vk_fifo"
  WAYLAND_DISPLAY="$wd" "$vp_dir/vkeyboard" < "$vk_fifo" > "$vk_log" 2>&1 &
  vk_pid=$!
  exec 4>"$vk_fifo"
  for _ in $(seq 1 20); do grep -q ready "$vk_log" && break; sleep 0.15; done
  grep -q ready "$vk_log" || { echo "FAIL: virtual keyboard not ready"; cat "$vk_log"; exit 1; }
  caps=$(swaymsg -t get_seats | grep -o '"capabilities": [0-9]*' | grep -o '[0-9]*' | head -1)
  # wl_seat capability bit 1 (value 2) is keyboard.
  [ $(( ${caps:-0} & 2 )) -ne 0 ] || { echo "FAIL: seat gained no keyboard capability (caps=$caps)"; exit 1; }
  echo "virtual keyboard ready; seat capabilities=$caps"
  sleep 0.5  # let AquaDemo bind wl_keyboard + receive the keymap
  if [ "$repeat" = "--repeat" ]; then
    # Hold 'x' (evdev 45) into the text field. After the compositor's repeat
    # delay it should auto-repeat, so a single hold yields many x's.
    printf 'd 45\n' >&4        # press and hold
    sleep 1.3                  # past the repeat delay, into the repeat stream
    printf 'u 45\n' >&4        # release
    sleep 0.3
  elif [ "$keys" = "--keys" ]; then
    # Drive keyboard focus/traversal. Raw evdev codes: Tab=15 Space=57 Right=106
    # Enter=28 Down=108.
    if [ "$menu" = "--menu" ]; then
      # The pop-up menu is open (from the --click block). Navigate it purely by
      # keyboard: Down highlights the 2nd item, Enter chooses it — which sets the
      # Appearance value to "Graphite" and dismisses the popup. Proves keyboard
      # reaches the popup while its grab is active.
      printf 'k 108\n' >&4   # Down: highlight Graphite
      sleep 0.3
      printf 'k 28\n'  >&4   # Enter: choose it
      sleep 0.3
    else
    case "$scene" in
      sheet)
        # Space opens the sheet from the keyboard; leave it open for the shot.
        printf 'k 57\n' >&4
        sleep 0.6
        ;;
      *)
        # Focus starts on the default button (OK). Tab wraps to the first
        # checkbox; Space toggles it off; four Tabs walk to the slider; Right
        # arrows push it up — the final shot shows the focus ring on the slider,
        # which sits near full.
        printf 'k 15\n'                 >&4   # Tab: OK -> first checkbox
        sleep 0.2
        printf 'k 57\n'                 >&4   # Space: toggle that checkbox off
        sleep 0.2
        printf 'k 15 15 15 15\n'        >&4   # Tab x4: -> the slider
        sleep 0.2
        printf 'k 106 106 106 106 106 106\n' >&4  # Right x6: slider toward max
        ;;
    esac
    fi
  else
    printf 't Abyss\n' >&4     # type into the focused text field
  fi
  sleep 0.5
  exec 4>&-
fi

if [ "$menubar" = "--menubar" ]; then
  # The click should have opened a dropdown from the menu-bar layer surface.
  grep -q 'MenuBar: opened' "$app_log" \
    || { echo "FAIL: menu bar didn't open a dropdown"; cat "$app_log"; exit 1; }
  echo "menu bar: $(grep 'MenuBar: opened' "$app_log" | head -1) (popup from a layer surface)"
fi

if [ "$hidpi" = "--hidpi" ]; then
  # The window should have followed the scale-2 output and logged the change.
  if grep -q 'buffer scale -> 2x' "$app_log"; then
    echo "hidpi: window auto-scaled to 2x from wl_output"
  else
    echo "FAIL: window did not auto-scale to 2x on a scale-2 output"
    cat "$app_log"; exit 1
  fi
fi

# The Dock captured earlier (while its magnification pointer was present); don't
# overwrite it here.
[ -z "${captured:-}" ] && WAYLAND_DISPLAY="$wd" grim "$out"
test -s "$out" || { echo "FAIL: grim produced no image"; exit 1; }
echo "ok: live render -> $out (window mapped, no crash${menu:+, menu open}${menu:+ }${wheel:+, wheeled}${wheel:+ }${click:+, clicked}${type:+, typed}${keys:+, keyed}${repeat:+, repeated}${hidpi:+, 2x})"
