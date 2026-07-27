#!/bin/sh
# AbyssBSD Swift DE — live on-screen smoke test under a real compositor.
#
# The `run.sh` PNG path renders a scene straight to a cairo image surface; it
# never builds a Surface.Window, so it can't catch bugs in the live Wayland
# path (xdg-shell handshake, shm double-buffering, frame-callback pacing,
# configure/resize, pointer input, listener/object lifetimes). This script runs
# AquaDemo against a headless sway and captures the result with grim.
#
# Usage: abyss/tests/live-sway.sh [window|sysprefs|widgets|finder] [out.png] [--click] [--type] [--keys] [--hidpi] [--wheel] [--repeat] [--finder]
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

scene=""; out=""; click=""; type=""; menu=""; keys=""; hidpi=""; wheel=""; repeat=""; reload=""; menubar=""; dock_mode=""; finder=""; spatial=""; fileops=""; desktop=""; launch=""; trash=""
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
    --finder)                 finder="--finder"; click="--click" ;;  # browse a seeded dir
    --spatial)                spatial="--spatial"; finder="--finder"; click="--click" ;;
    --fileops)                fileops="--fileops"; finder="--finder"; click="--click"; keys="--keys" ;;
    --trash)                  trash="--trash"; click="--click" ;;  # Dock: empty the Trash
    --desktop)                desktop="--desktop"; click="--click" ;;  # desktop icons
    --launch)                 launch="--launch"; finder="--finder"; click="--click" ;;
    window|sysprefs|widgets|scroll|tabs|sheet|wallpaper|menubar|dock|finder)  scene="$a" ;;
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
# --dock drives the Dock (a layer-shell BOTTOM surface); --trash drives its
# Trash tile (right-click menu → Empty Trash), which lives there too.
[ "$dock_mode" = "--dock" ] && scene="dock"
[ "$trash" = "--trash" ] && scene="dock"
# --desktop drives the desktop icons (on the wallpaper's layer surface).
[ "$desktop" = "--desktop" ] && scene="wallpaper"
# --finder drives the file browser (an ordinary xdg toplevel); --spatial also
# switches it into one-window-per-folder mode.
[ "$finder" = "--finder" ] && scene="finder"
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
  finder)   res="520x400" ;;
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
  [ -n "${finderdir:-}" ] && rm -rf "$finderdir" || true
  [ -n "${deskdir:-}" ] && rm -rf "$deskdir" || true
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

# --finder: give the Finder a seeded directory to browse, so the listing (and
# what a click lands on) is identical on every machine. Sorted by the Finder's
# rule that is: Applications, Documents, Pictures, Read Me.txt.
finder_env=""
if [ "$finder" = "--finder" ]; then
  finderdir=$(mktemp -d)
  mkdir -p "$finderdir/Applications" "$finderdir/Documents/Letters" "$finderdir/Pictures"
  printf 'Welcome to AbyssBSD.\n' > "$finderdir/Read Me.txt"
  printf 'notes\n' > "$finderdir/Documents/notes.txt"
  printf '.dotfile\n' > "$finderdir/.hidden"   # must NOT be listed
  # A private config dir: the Finder persists the toolbar (browser/spatial)
  # state, and a test must never write the developer's real finder.ini.
  cfgdir=${cfgdir:-$(mktemp -d)}
  finder_env="ABYSS_FINDER_DIR=$finderdir ABYSS_CONFIG_DIR=$cfgdir"
  # --fileops moves items to ~/.Trash, so HOME points inside the temp tree —
  # a test must never drop things in the developer's real Trash.
  [ "$fileops" = "--fileops" ] && finder_env="$finder_env HOME=$finderdir"
  if [ "$launch" = "--launch" ]; then
    # A real (if tiny) application bundle, laid out the Mac way, plus an opener
    # command for documents. Both just leave a file behind so the test can prove
    # the process actually ran.
    mkdir -p "$finderdir/Marker.app/Contents/MacOS"
    cat > "$finderdir/Marker.app/Contents/MacOS/Marker" <<APP
#!/bin/sh
printf 'app ran\n' > "$finderdir/app-ran.txt"
APP
    chmod +x "$finderdir/Marker.app/Contents/MacOS/Marker"
    cat > "$finderdir/opener.sh" <<OPEN
#!/bin/sh
printf '%s' "\$1" > "$finderdir/opened.txt"
OPEN
    chmod +x "$finderdir/opener.sh"
    finder_env="$finder_env ABYSS_OPEN=$finderdir/opener.sh"
    # Give the bundle its OWN icon: a 4x4 solid magenta PNG, written byte for
    # byte so the harness needs no image tool. Magenta because nothing in the
    # Aqua palette is anywhere near it — a pixel probe over the icon then proves
    # the bundle's artwork was used instead of the procedural glyph.
    mkdir -p "$finderdir/Marker.app/Contents/Resources"
    printf '\211\120\116\107\015\012\032\012\000\000\000\015\111\110\104\122\000\000\000\004\000\000\000\004\010\002\000\000\000\046\223\011\051\000\000\000\021\111\104\101\124\170\332\143\370\317\360\037\216\030\210\343\000\000\075\041\037\341\245\316\071\374\000\000\000\000\111\105\116\104\256\102\140\202' \
      > "$finderdir/Marker.app/Contents/Resources/Marker.png"
  fi
fi

# --desktop: a seeded ~/Desktop for the wallpaper's icons, and a private config
# dir (the desktop reads desktop.ini).
# What the Dock launches inherits our environment, so point it at a temp dir
# rather than the developer's home.
if [ "$scene" = "dock" ]; then
  finderdir=${finderdir:-$(mktemp -d)}
  mkdir -p "$finderdir/Documents"
  finder_env="ABYSS_FINDER_DIR=$finderdir"
  if [ "$trash" = "--trash" ]; then
    # A seeded ~/.Trash — one file and one folder, so emptying has to remove a
    # tree as well as a file. $HOME points inside the temp dir: this test
    # PERMANENTLY DELETES what it finds in the Trash, so it must own it.
    mkdir -p "$finderdir/.Trash/Old Reports"
    printf 'junk\n' > "$finderdir/.Trash/junk.txt"
    printf 'q1\n'   > "$finderdir/.Trash/Old Reports/q1.txt"
    finder_env="$finder_env HOME=$finderdir"
  fi
fi

desktop_env=""
# Any other wallpaper run gets an EMPTY desktop folder, so the backdrop tests
# (and their screenshots) don't depend on what's in the developer's ~/Desktop.
if [ "$scene" = "wallpaper" ] && [ "$desktop" != "--desktop" ]; then
  deskdir=$(mktemp -d)
  desktop_env="ABYSS_DESKTOP_DIR=$deskdir"
fi
if [ "$desktop" = "--desktop" ]; then
  deskdir=$(mktemp -d)
  mkdir -p "$deskdir/Documents"
  printf 'notes\n' > "$deskdir/notes.txt"
  cfgdir=${cfgdir:-$(mktemp -d)}
  desktop_env="ABYSS_DESKTOP_DIR=$deskdir ABYSS_CONFIG_DIR=$cfgdir"
fi

# Capture AquaDemo's stderr (it logs buffer-scale changes there). Unset
# AQUA_SCALE so the window auto-detects scale from wl_output rather than pinning.
app_log=$(mktemp)
env -u AQUA_SCALE $abyss_cfg $finder_env $desktop_env WAYLAND_DISPLAY="$wd" AQUA_SCENE="$scene" \
    .build/debug/AquaDemo >/dev/null 2>"$app_log" &
app_pid=$!

# Wait for the surface to map. A layer-shell surface (wallpaper) isn't a
# toplevel and never appears in sway's get_tree, so we assert on the app's own
# "mapped" log — proof the compositor accepted the layer-shell handshake and
# sent a configure. A normal window we detect by its app_id in the tree.
# The Finder is its own application (its own app_id), not the demo shell.
app_id="org.abyssbsd.aquademo"
[ "$scene" = "finder" ] && app_id="org.abyssbsd.finder"
mapped=0
for _ in $(seq 1 32); do
  if [ -n "$is_layer" ]; then
    grep -q 'LayerSurface: mapped' "$app_log" && { mapped=1; break; }
  else
    if swaymsg -t get_tree 2>/dev/null | grep -q "\"app_id\": \"$app_id\""; then
      mapped=1; break
    fi
  fi
  kill -0 "$app_pid" 2>/dev/null || { echo "FAIL: AquaDemo exited early"; cat "$app_log"; exit 1; }
  sleep 0.25
done
[ "$mapped" = 1 ] || { echo "FAIL: surface never mapped"; cat "$app_log"; exit 1; }
[ -n "$is_layer" ] && echo "layer surface mapped: $(grep 'LayerSurface: mapped' "$app_log" | head -1)"
sleep 1  # let a couple of frames paint

if [ "$desktop" = "--desktop" ]; then
  # The boot volume plus the two seeded items.
  grep -q 'Wallpaper: 3 icons' "$app_log" \
    || { echo "FAIL: the desktop didn't list its icons"; cat "$app_log"; exit 1; }
  echo "desktop: $(grep 'Wallpaper: .* icons' "$app_log" | head -1) (volume + 2 items)"
fi

if [ "$finder" = "--finder" ]; then
  # readdir + sort + the dot-file filter, against a directory we control.
  # (--launch seeds two extra items: the bundle and the opener script.)
  expect_items=4
  [ "$launch" = "--launch" ] && expect_items=6
  grep -q "Finder: listed $finderdir ($expect_items items)" "$app_log" \
    || { echo "FAIL: Finder didn't list the seeded directory"; cat "$app_log"; exit 1; }
  echo "finder: $(grep 'Finder: listed' "$app_log" | head -1)"
fi

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
    wallpaper|menubar|dock) vpw=800; vph=600 ;;
    finder)  vpw=520; vph=400 ;;
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
  elif [ "$launch" = "--launch" ]; then
    # Sorted: Applications, Documents, Marker.app, opener.sh, Pictures,
    # Read Me.txt — 5 columns of 88px under the 22px title bar + 36px toolbar.
    # Cell 2 ("Marker.app") is centred at x=230, y=96.
    # The bundle ships its own icon (a magenta PNG), so that is what the Finder
    # must be drawing there — not the procedural application glyph. grim can cut
    # a 1x1 PPM, whose last three bytes are the pixel.
    icon_px=$(WAYLAND_DISPLAY="$wd" grim -g "230,96 1x1" -t ppm - | tail -c 3 \
              | od -An -tu1 | tr -s ' ' | sed 's/^ //;s/ $//')
    [ "$icon_px" = "255 0 255" ] \
      || { echo "FAIL: the bundle's own icon wasn't drawn (pixel = $icon_px)"; exit 1; }
    echo "finder: Marker.app is drawn with its own icon (Contents/Resources)"
    printf 'm 230 96\np\nr\np\nr\n' >&3
    sleep 1.2
    grep -q "Finder: launched $finderdir/Marker.app/Contents/MacOS/Marker" "$app_log" \
      || { echo "FAIL: double-clicking the bundle didn't launch it"; cat "$app_log"; exit 1; }
    [ -f "$finderdir/app-ran.txt" ] \
      || { echo "FAIL: the launched app never ran"; cat "$app_log"; exit 1; }
    echo "finder: double-clicked Marker.app -> its executable really ran"
    # A document goes to the opener command, which records the path it was given.
    # "Read Me.txt" is item 5 of 6, and the grid is 5 columns wide, so it wraps
    # to the start of row 2: cell x 10..98 (centre 54), icon centred at y=172.
    printf 'm 54 172\np\nr\np\nr\n' >&3
    sleep 1.2
    grep -q 'Finder: opened with' "$app_log" \
      || { echo "FAIL: the document didn't reach the opener"; cat "$app_log"; exit 1; }
    for _ in $(seq 1 25); do [ -s "$finderdir/opened.txt" ] && break; sleep 0.2; done
    got=$(cat "$finderdir/opened.txt" 2>/dev/null || true)
    [ "$got" = "$finderdir/Read Me.txt" ] \
      || { echo "FAIL: opener got '$got', expected '$finderdir/Read Me.txt'"; cat "$app_log"; exit 1; }
    echo "finder: double-clicked a document -> \$ABYSS_OPEN ran with its path"
  elif [ "$desktop" = "--desktop" ]; then
    # Icons stack from the top-right: index 0 is the volume, index 1 ("Documents")
    # sits one cell below it — cell x 692..788, icon centred at (740, 150).
    printf 'm 740 150\n' >&3
    sleep 0.4
    printf 'p\nr\n' >&3
    sleep 0.5
    grep -q 'Wallpaper: selected Documents' "$app_log" \
      || { echo "FAIL: clicking a desktop icon didn't select it"; cat "$app_log"; exit 1; }
    echo "desktop: clicked the second icon -> selected Documents"
    # Capture with the selection showing, before a Finder window covers the desktop.
    WAYLAND_DISPLAY="$wd" grim "$out"; captured=1
    echo "desktop: captured the icons -> $out"
    # Double-click opens it in a Finder window — the desktop hosts the Finder.
    # (A fresh pair, not one click appended to the selection above: the capture
    # in between takes longer than the double-click window.)
    printf 'p\nr\np\nr\n' >&3
    sleep 1.2
    grep -q "Wallpaper: opened $deskdir/Documents" "$app_log" \
      || { echo "FAIL: double-clicking a desktop folder opened nothing"; cat "$app_log"; exit 1; }
    for _ in $(seq 1 20); do
      swaymsg -t get_tree 2>/dev/null | grep -q '"app_id": "org.abyssbsd.finder"' && break
      sleep 0.2
    done
    swaymsg -t get_tree | grep -q '"app_id": "org.abyssbsd.finder"' \
      || { echo "FAIL: no Finder toplevel appeared"; cat "$app_log"; exit 1; }
    echo "desktop: double-click opened a real Finder window from the desktop"
    # The desktop watches its folder: a new file shows up with no polling.
    printf 'hello\n' > "$deskdir/Later.txt"
    seen=0
    for _ in $(seq 1 25); do
      grep -q 'Wallpaper: 4 icons' "$app_log" && { seen=1; break; }
      sleep 0.2
    done
    [ "$seen" = 1 ] \
      || { echo "FAIL: the desktop didn't notice a new file"; cat "$app_log"; exit 1; }
    echo "desktop: a new file in the folder appeared on the desktop (watch fd)"
  elif [ "$fileops" = "--fileops" ]; then
    # Just put the pointer in the item well and click empty space, so the window
    # is focused and nothing is selected; the keyboard block does the work.
    printf 'm 300 300\np\nr\n' >&3
    sleep 0.4
  elif [ "$spatial" = "--spatial" ]; then
    # Spatial mode: the pill at the title bar's right hides the toolbar, which
    # is what makes folders open in their own window (as in 10.2).
    printf 'm 500 11\np\nr\n' >&3
    sleep 0.6
    grep -q 'Finder: toolbar hidden (spatial mode)' "$app_log" \
      || { echo "FAIL: the pill didn't hide the toolbar"; cat "$app_log"; exit 1; }
    echo "finder: pill hid the toolbar (spatial mode)"
    # With no toolbar the grid starts right under the title bar, so "Documents"
    # (cell 1) is at y≈60. Double-click it: a NEW window, not navigation.
    printf 'm 142 60\np\nr\n' >&3
    sleep 0.15
    printf 'p\nr\n' >&3
    sleep 1.0
    grep -q "Finder: new window $finderdir/Documents (2 open)" "$app_log" \
      || { echo "FAIL: spatial open didn't make a second window"; cat "$app_log"; exit 1; }
    n=$(swaymsg -t get_tree | grep -c '"app_id": "org.abyssbsd.finder"')
    [ "$n" = 2 ] \
      || { echo "FAIL: expected 2 Finder toplevels in the tree, got $n"; exit 1; }
    echo "finder: spatial open made a second real toplevel (tree count=$n)"
    # Capture here, with both windows up — that is the evidence for spatial mode
    # (the run closes one below, which would otherwise be all the shot shows).
    WAYLAND_DISPLAY="$wd" grim "$out"; captured=1
    echo "finder: captured both spatial windows -> $out"
    # sway tiles the two side by side, so the first window keeps the left half
    # and the same surface-local coordinates. Opening Documents again must RAISE
    # the existing window rather than open a third.
    printf 'm 142 60\np\nr\n' >&3
    sleep 0.15
    printf 'p\nr\n' >&3
    sleep 0.8
    grep -q "Finder: raised $finderdir/Documents" "$app_log" \
      || { echo "FAIL: re-opening an open folder didn't raise its window"; cat "$app_log"; exit 1; }
    ! grep -q 'Finder: raise unavailable' "$app_log" \
      || { echo "FAIL: xdg-activation missing — the raise was a no-op"; cat "$app_log"; exit 1; }
    n=$(swaymsg -t get_tree | grep -c '"app_id": "org.abyssbsd.finder"')
    [ "$n" = 2 ] || { echo "FAIL: raise opened a duplicate window (count=$n)"; exit 1; }
    echo "finder: re-open raised the existing window (xdg-activation, still $n)"
    # The red traffic light closes just that window (the right-hand tile).
    printf 'm 276 11\np\nr\n' >&3
    sleep 0.8
    grep -q "Finder: closed $finderdir/Documents (1 open)" "$app_log" \
      || { echo "FAIL: the close light didn't close the spatial window"; cat "$app_log"; exit 1; }
    kill -0 "$app_pid" 2>/dev/null \
      || { echo "FAIL: closing one window killed the process"; cat "$app_log"; exit 1; }
    echo "finder: close light closed one window; the app lives on"
  elif [ "$finder" = "--finder" ]; then
    # The icon grid: cell 1 (0-based) is "Documents" — 10px pad + one 88px cell,
    # under the 22px title bar and the 36px toolbar. Click once to select, again
    # (inside the double-click window) to browse into it.
    printf 'm 142 96\np\nr\n' >&3
    sleep 0.15
    printf 'p\nr\n' >&3
    sleep 0.8
    grep -q 'Finder: selected Documents' "$app_log" \
      || { echo "FAIL: click didn't select Documents"; cat "$app_log"; exit 1; }
    grep -q "Finder: opened $finderdir/Documents" "$app_log" \
      || { echo "FAIL: double-click didn't open Documents"; cat "$app_log"; exit 1; }
    grep -q "Finder: listed $finderdir/Documents (2 items)" "$app_log" \
      || { echo "FAIL: Documents listed the wrong contents"; cat "$app_log"; exit 1; }
    echo "finder: double-click browsed into Documents (2 items)"
    # Back returns to the parent (the 10.2 Finder browses in place).
    printf 'm 27 40\np\nr\n' >&3
    sleep 0.6
    grep -q "Finder: back to $finderdir" "$app_log" \
      || { echo "FAIL: Back didn't return to the parent"; cat "$app_log"; exit 1; }
    echo "finder: Back returned to the parent"
    # The toolbar's view switch: the right segment is list view.
    printf 'm 99 40\np\nr\n' >&3
    sleep 0.6
    grep -q 'Finder: view -> list' "$app_log" \
      || { echo "FAIL: the view switch didn't select list view"; cat "$app_log"; exit 1; }
    echo "finder: switched to list view"
  elif [ "$trash" = "--trash" ]; then
    # The Dock started with a seeded Trash, so the tile shows the full glyph.
    grep -q 'Dock: Trash full' "$app_log" \
      || { echo "FAIL: the Dock didn't notice a full Trash"; cat "$app_log"; exit 1; }
    # Right-click the Trash tile. Its position depends on magnification (tiles
    # are re-laid-out around the pointer), so hover first and aim at where the
    # magnified tile then sits: pointer 540 puts the Trash tile across 501..592,
    # and the shelf's icons run to y=588 on an 800x600 output.
    printf 'm 540 550\n' >&3
    sleep 0.5
    printf 'P\nR\n' >&3
    sleep 0.8
    grep -q 'Dock: opened Trash menu' "$app_log" \
      || { echo "FAIL: right-clicking the Trash opened no menu"; cat "$app_log"; exit 1; }
    echo "dock: right-click opened the Trash menu"
    # Capture with the menu open — the evidence shot for this pass.
    WAYLAND_DISPLAY="$wd" grim "$out"; captured=1
    # The menu flips *above* the tile (no room below): 48px tall, its rows are
    # "Open" then "Empty Trash". Click the second row.
    printf 'm 560 483\n' >&3
    sleep 0.3
    printf 'p\nr\n' >&3
    sleep 1.0
    grep -q 'Dock: emptied Trash: 2 removed, 0 failed' "$app_log" \
      || { echo "FAIL: Empty Trash didn't empty it"; cat "$app_log"; exit 1; }
    # Assert on DISK, not the log: the Trash is empty and still exists, and the
    # folder that was in it is gone with everything under it.
    [ -d "$finderdir/.Trash" ] \
      || { echo "FAIL: emptying removed the Trash folder itself"; exit 1; }
    [ -z "$(ls -A "$finderdir/.Trash")" ] \
      || { echo "FAIL: the Trash still holds $(ls -A "$finderdir/.Trash")"; exit 1; }
    [ ! -e "$finderdir/.Trash/Old Reports/q1.txt" ] \
      || { echo "FAIL: a nested file survived the empty"; exit 1; }
    echo "dock: Empty Trash removed both items permanently (checked on disk)"
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
    # Click the Finder tile: it isn't running, so the Dock LAUNCHES it (another
    # copy of this binary in the finder scene) and a real toplevel appears.
    # The window above covered the shelf, so give sway a moment to hand pointer
    # focus back to the layer surface, and move twice so it re-enters.
    sleep 0.6
    printf 'm 320 560\n' >&3
    sleep 0.3
    printf 'm 265 560\n' >&3
    sleep 0.4
    printf 'p\nr\n' >&3
    sleep 1.2
    grep -q 'Dock: launched org.abyssbsd.finder' "$app_log" \
      || { echo "FAIL: the Dock tile didn't launch the Finder"; cat "$app_log"; exit 1; }
    for _ in $(seq 1 25); do
      swaymsg -t get_tree 2>/dev/null | grep -q '"app_id": "org.abyssbsd.finder"' && break
      sleep 0.2
    done
    swaymsg -t get_tree | grep -q '"app_id": "org.abyssbsd.finder"' \
      || { echo "FAIL: the launched Finder never mapped a window"; cat "$app_log"; exit 1; }
    echo "dock: clicking the Finder tile launched a real Finder window"
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
  # Keep the virtual pointer for the Dock (magnification is hover-driven) and
  # for the menu bar's keyboard test (which clicks a title again, after the
  # keyboard block, to check Escape).
  case "$dock_mode$trash$scene$keys" in
    *--dock*|*--trash*|menubar--keys) : ;;
    *) exec 3>&- ;;
  esac
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
      menubar)
        # The click above opened the System menu. Now drive the bar entirely
        # from the keyboard: Right walks to the next title (the app menu),
        # Down highlights its first item and Return chooses it. Raw evdev:
        # Right=106 Down=108 Enter=28.
        printf 'k 106\n' >&4
        sleep 0.5
        grep -q 'MenuBar: opened Finder' "$app_log" \
          || { echo "FAIL: Right didn't walk to the next menu"; cat "$app_log"; exit 1; }
        echo "menu bar: Right walked System -> Finder"
        printf 'k 108\n' >&4     # Down: highlight "About Finder"
        sleep 0.3
        printf 'k 28\n'  >&4     # Return: choose it
        sleep 0.5
        grep -q 'MenuBar: chose Finder > About Finder' "$app_log" \
          || { echo "FAIL: Down+Return didn't choose from the keyboard"; cat "$app_log"; exit 1; }
        echo "menu bar: Down+Return chose 'About Finder' (no pointer)"
        # Escape closes the open menu (and hands the keyboard back).
        printf 'm 21 11\np\nr\n' >&3   # re-open the system menu with the pointer
        sleep 0.5
        printf 'k 1\n' >&4             # Escape (evdev 1)
        sleep 0.6
        grep -q 'MenuBar: closed' "$app_log" \
          || { echo "FAIL: Escape didn't close the menu"; cat "$app_log"; exit 1; }
        echo "menu bar: Escape closed the menu"
        ;;
      finder)
        if [ "$fileops" = "--fileops" ]; then
          # xkb modifier mask: Command (Mod4/Logo) = 64, +Shift = 65.
          # ⌘⇧N makes "untitled folder" and drops into an inline rename; type a
          # name and Return commits it.
          printf 'c 65 49\n' >&4          # N = evdev 49
          sleep 0.6
          grep -q "Finder: new folder $finderdir/untitled folder" "$app_log" \
            || { echo "FAIL: Cmd-Shift-N made no folder"; cat "$app_log"; exit 1; }
          printf 't Reports\n' >&4
          sleep 0.4
          printf 'k 28\n' >&4             # Return commits the rename
          sleep 0.6
          grep -q 'Finder: renamed untitled folder -> untitled folderReports' "$app_log" \
            && { echo "FAIL: the rename field kept the old name"; cat "$app_log"; exit 1; }
          [ -d "$finderdir/Reports" ] \
            || { echo "FAIL: renamed folder missing on disk"; ls -a "$finderdir"; cat "$app_log"; exit 1; }
          echo "finder: new folder + inline rename -> $finderdir/Reports"

          # Type-select "Read Me.txt", then ⌘C / ⌘V: a copy appears beside it.
          printf 't r\n' >&4
          sleep 0.3
          printf 'c 64 46\n' >&4          # C = evdev 46
          sleep 0.3
          printf 'c 64 47\n' >&4          # V = evdev 47
          sleep 0.8
          [ -f "$finderdir/Read Me copy.txt" ] \
            || { echo "FAIL: paste made no copy"; ls "$finderdir"; cat "$app_log"; exit 1; }
          cmp -s "$finderdir/Read Me.txt" "$finderdir/Read Me copy.txt" \
            || { echo "FAIL: the copy's contents differ"; exit 1; }
          echo "finder: copy/paste -> 'Read Me copy.txt' (contents match)"

          # The paste selected the new copy: ⌘Delete moves it to ~/.Trash.
          printf 'c 64 111\n' >&4         # Delete = evdev 111
          sleep 0.8
          [ ! -e "$finderdir/Read Me copy.txt" ] \
            || { echo "FAIL: Cmd-Delete left the file in place"; cat "$app_log"; exit 1; }
          [ -f "$finderdir/.Trash/Read Me copy.txt" ] \
            || { echo "FAIL: the file didn't land in ~/.Trash"; ls -a "$finderdir/.Trash" 2>&1; cat "$app_log"; exit 1; }
          [ -f "$finderdir/Read Me.txt" ] \
            || { echo "FAIL: the ORIGINAL was trashed"; exit 1; }
          echo "finder: Cmd-Delete moved the copy to ~/.Trash (original intact)"

          # Leave an inline rename open for the screenshot.
          printf 't R\n' >&4
          sleep 0.3
          printf 'k 28\n' >&4             # Return starts renaming the selection
          sleep 0.5
        else
        # Keyboard browsing: Home selects the first row, ⌘O opens it, Backspace
        # goes back up to the parent. (Return *renames* in the Finder, which is
        # why opening is ⌘O; and Back left "Documents" selected — the Finder
        # highlights the folder you came out of — so Home, not Down, is what
        # pins the selection to Applications.) Raw evdev: Home=102 O=24
        # Backspace=14; xkb modifier mask 64 = Command (Mod4).
        printf 'k 102\n' >&4
        sleep 0.3
        printf 'c 64 24\n' >&4
        sleep 0.6
        grep -q "Finder: opened $finderdir/Applications" "$app_log" \
          || { echo "FAIL: Enter didn't open the selected folder"; cat "$app_log"; exit 1; }
        printf 'k 14\n'  >&4   # Backspace: up to the parent
        sleep 0.6
        grep -q "Finder: opened $finderdir\$" "$app_log" \
          || { echo "FAIL: Backspace didn't go up to the parent"; cat "$app_log"; exit 1; }
        echo "finder: keyboard opened Applications and went back up"
        fi
        ;;
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
