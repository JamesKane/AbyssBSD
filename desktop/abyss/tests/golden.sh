#!/bin/sh
# AbyssBSD Swift DE — the golden-image gate (PHASE11 P11.1).
#
# Every deterministic scene the toolkit can draw, rendered offscreen and
# compared with a committed golden image **pixel for pixel**. This is the gate
# Phase 11 is verified with: every pass after this one re-expresses the look as
# data, and the proof that nothing moved is that nothing here moved.
#
#   abyss/tests/golden.sh             # compare; fail naming every scene that moved
#   abyss/tests/golden.sh --update    # rewrite the goldens — on purpose, never to
#                                     # make a failure go away
#   abyss/tests/golden.sh SCENE ...   # only these
#
# **Goldens are per platform** (abyss/tests/golden/<os>/): the text is rendered
# with whatever fonts the box has — Noto and Adwaita on the dev box, DejaVu in
# the FreeBSD guest — so the same scene is a different picture on each. A
# rendering-stack upgrade (cairo, freetype, a font package) moves pixels too;
# the diff image says where, and `--update` is the deliberate answer.
#
# Every scene runs with an empty config dir, a fixed clock (the scenes already
# use 9:41), and fake status items, so nothing on the machine leaks in.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
aqua="$root/.build/debug/AquaDemo"
[ -x "$aqua" ] || swift build

os=$(uname -s | tr '[:upper:]' '[:lower:]')
dir="$root/abyss/tests/golden/$os"
update=0
only=""
for a in "$@"; do
  case "$a" in
    --update) update=1 ;;
    *) only="$only $a" ;;
  esac
done

work=$(mktemp -d /tmp/abyss-golden.XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM HUP
mkdir -p "$work/cfg" "$work/home" "$dir"

cc -O1 "$root/abyss/tests/pngdiff.c" $(pkg-config --cflags --libs cairo) \
   -o "$work/pngdiff" || { echo "FAIL: could not build pngdiff"; exit 1; }

# name | AQUA_SCENE | extra environment
scenes='window|window|
window@2x|window|AQUA_SCALE=2
sysprefs|sysprefs|
sysprefs-pane|sysprefs|AQUA_PREFS_PANE=network
sysprefs-wifi|sysprefs|AQUA_PREFS_PANE=network-wifi
sysprefs-sound|sysprefs|AQUA_PREFS_PANE=sound
sysprefs-displays|sysprefs|AQUA_PREFS_PANE=displays
sysprefs-energy|sysprefs|AQUA_PREFS_PANE=energySaver
sysprefs-general|sysprefs|AQUA_PREFS_PANE=general
widgets|widgets|
scroll|scroll|
tabs|tabs|
sheet|sheet|
finder|finder|
finder-list|finder|AQUA_FINDER_VIEW=list
finder@2x|finder|AQUA_SCALE=2
finder-rename|finder|AQUA_FINDER_STATE=rename
finder-list-rename@2x|finder|AQUA_FINDER_VIEW=list AQUA_FINDER_STATE=rename AQUA_SCALE=2
finder-back|finder|AQUA_FINDER_STATE=back
finder-list-back|finder|AQUA_FINDER_VIEW=list AQUA_FINDER_STATE=back
installer-hub|installer|
installer-empty|installer|AQUA_INSTALLER_PAGE=empty
installer-disk|installer|AQUA_INSTALLER_PAGE=disk
installer-account|installer|AQUA_INSTALLER_PAGE=account
installer-keyboard|installer|AQUA_INSTALLER_PAGE=keyboard
installer-confirm|installer|AQUA_INSTALLER_PAGE=confirm
installer-installing|installer|AQUA_INSTALLER_PAGE=installing
installer-done|installer|AQUA_INSTALLER_PAGE=done
wallpaper|wallpaper|
menubar|menubar|ABYSS_FAKE_VOLUME=60 ABYSS_FAKE_BATTERY=80
menubar@2x|menubar|ABYSS_FAKE_VOLUME=60 ABYSS_FAKE_BATTERY=80 AQUA_SCALE=2
menubar-system|menubar|ABYSS_FAKE_VOLUME=60 ABYSS_FAKE_BATTERY=80 AQUA_MENUBAR_OPEN=0
menubar-file@2x|menubar|ABYSS_FAKE_VOLUME=60 ABYSS_FAKE_BATTERY=80 AQUA_MENUBAR_OPEN=2 AQUA_SCALE=2
menubar-mute@2x|menubar|ABYSS_FAKE_VOLUME=0 ABYSS_FAKE_BATTERY=0 ABYSS_FAKE_BATTERY_CHARGING=1 AQUA_SCALE=2
menubar-low|menubar|ABYSS_FAKE_VOLUME=20 ABYSS_FAKE_BATTERY=5
menubar-full|menubar|ABYSS_FAKE_VOLUME=100 ABYSS_FAKE_BATTERY=100 ABYSS_FAKE_BATTERY_CHARGING=1
menubar-muted@2x|menubar|ABYSS_FAKE_VOLUME=60 ABYSS_FAKE_MUTED=1 ABYSS_FAKE_BATTERY=80 AQUA_SCALE=2
dock|dock|
dock-running@2x|dock|AQUA_DOCK_RUNNING=1 AQUA_SCALE=2
notify|notify|
menu|menu|
menu@2x|menu|AQUA_SCALE=2
menu-marks|menu|AQUA_MENU_MARKS=1
menu-marks@2x|menu|AQUA_MENU_MARKS=1 AQUA_SCALE=2
frame|frame|
frame-depth|frame|ABYSS_THEME=chrome-test ABYSS_THEME_DIR=abyss/tests/themes
window-depth@2x|window|ABYSS_THEME=chrome-test ABYSS_THEME_DIR=abyss/tests/themes AQUA_SCALE=2
drawlist|drawlist|AQUA_DRAWLIST=abyss/tests/drawlist-sample.dl
drawlist@2x|drawlist|AQUA_DRAWLIST=abyss/tests/drawlist-sample.dl AQUA_SCALE=2
icons|icons|
icons@2x|icons|AQUA_SCALE=2
cursors|cursors|
cursors@2x|cursors|AQUA_SCALE=2
svg-beacon@2x|icons|AQUA_DRAWLIST=abyss/tests/svg/beacon.dl AQUA_SCALE=2
trench-window|window|ABYSS_THEME=trench
trench-window@2x|window|ABYSS_THEME=trench AQUA_SCALE=2
trench-widgets|widgets|ABYSS_THEME=trench
trench-sysprefs|sysprefs|ABYSS_THEME=trench
trench-finder|finder|ABYSS_THEME=trench
trench-finder-list|finder|ABYSS_THEME=trench AQUA_FINDER_VIEW=list
trench-finder-rename|finder|ABYSS_THEME=trench AQUA_FINDER_STATE=rename
trench-menubar|menubar|ABYSS_THEME=trench ABYSS_FAKE_VOLUME=60 ABYSS_FAKE_BATTERY=80 AQUA_MENUBAR_OPEN=2
trench-dock|dock|ABYSS_THEME=trench AQUA_DOCK_RUNNING=1
trench-menu|menu|ABYSS_THEME=trench AQUA_MENU_MARKS=1
trench-frame|frame|ABYSS_THEME=trench
trench-sheet|sheet|ABYSS_THEME=trench
trench-tabs|tabs|ABYSS_THEME=trench
trench-scroll|scroll|ABYSS_THEME=trench
trench-notify|notify|ABYSS_THEME=trench
trench-wallpaper|wallpaper|ABYSS_THEME=trench
trench-installer-disk|installer|ABYSS_THEME=trench AQUA_INSTALLER_PAGE=disk
trench-sysprefs-general|sysprefs|ABYSS_THEME=trench AQUA_PREFS_PANE=general
trench-icons|icons|ABYSS_THEME=trench
trench-hc-widgets|widgets|ABYSS_THEME=trench ABYSS_THEME_SCHEME=neon-hc
trench-hc-finder|finder|ABYSS_THEME=trench ABYSS_THEME_SCHEME=neon-hc
trench-day-widgets|widgets|ABYSS_THEME=trench ABYSS_THEME_SCHEME=daylight
trench-day-window|window|ABYSS_THEME=trench ABYSS_THEME_SCHEME=daylight
trench-day-finder|finder|ABYSS_THEME=trench ABYSS_THEME_SCHEME=daylight
drawlist-roles@2x|drawlist|AQUA_DRAWLIST=abyss/tests/drawlist-sample.dl ABYSS_THEME=chrome-test ABYSS_THEME_DIR=abyss/tests/themes AQUA_SCALE=2'

render() {  # render NAME SCENE EXTRA OUT
  # EXTRA is split on spaces HERE, not by the caller's IFS — the scene loop
  # sets IFS to a newline, and with it a two-variable EXTRA reached `env` as ONE
  # word: the menu bar's fake status items were never applied (P11.3 found it).
  # shellcheck disable=SC2086
  (IFS=' '; env -i PATH="$PATH" HOME="$work/home" ABYSS_CONFIG_DIR="$work/cfg" \
      LANG=C.UTF-8 TZ=UTC AQUA_SCENE="$2" AQUA_RENDER_PNG="$4" $3 \
      "$aqua") > "$work/$1.log" 2>&1 \
    || { echo "FAIL: $1 did not render: $(tail -2 "$work/$1.log")"; return 1; }
}

# **No Swift knows a theme's name** but the default's (PHASE11 P11.9, PRODUCT
# §8.3): a second look that the code names is a back door, not a theme.
if git -C "$root" grep -qi trench -- 'de/*.swift' 'de/*.c' 'de/*.h' 2>/dev/null \
   || grep -rqi trench "$root/de" 2>/dev/null; then
  echo "FAIL: code under de/ names the trench theme: $(grep -rli trench "$root/de" | head -3)"
  exit 1
fi

# How many lists themes/aqua/draw/ defines — what every scene must say it read.
lists=$(cat "$root"/themes/aqua/draw/*.dl "$root"/themes/aqua/icons/*.dl 2>/dev/null | grep -c '^list ' || true)
[ "$lists" -gt 0 ] || { echo "FAIL: themes/aqua/draw/ has no draw lists"; exit 1; }
moved=""; missing=""; checked=0
IFS='
'
for line in $scenes; do
  IFS='|' read -r name scene extra <<EOF
$line
EOF
  if [ -n "$only" ]; then
    case " $only " in *" $name "*) ;; *) continue ;; esac
  fi
  out="$work/$name.png"
  render "$name" "$scene" "$extra" "$out" || exit 1
  # The goldens prove the theme FILE draws Jaguar — so a render that fell back
  # to the compiled defaults proves nothing about it, and is refused (§2.45).
  # So do the draw lists (P11.4): the compiled copy is the same text, so a
  # theme whose draw/ went missing would still be green without this.
  # A scene may ask for a test theme (ABYSS_THEME=x ABYSS_THEME_DIR=abyss/tests/
  # themes, P11.6): then it must have drawn from THAT file — which ships no
  # lists, so every one is Jaguar's.
  case "$extra" in
    *ABYSS_THEME_DIR=*)
      t=$(printf '%s\n' "$extra" | tr ' ' '\n' | sed -n 's/^ABYSS_THEME=//p')
      grep -q "^Theme: .* from .*abyss/tests/themes/$t/theme.ini, 0 draw lists from draw/ and icons/" "$work/$name.log" \
        || { echo "FAIL: $name was not drawn from abyss/tests/themes/$t: $(grep '^Theme:' "$work/$name.log")"; exit 1; } ;;
    *ABYSS_THEME=*)
      # A theme in the repository's themes/ (Trench, P11.9): drawn from its own
      # file and every list it ships.
      t=$(printf '%s\n' "$extra" | tr ' ' '\n' | sed -n 's/^ABYSS_THEME=//p')
      n=$(cat "$root/themes/$t"/draw/*.dl "$root/themes/$t"/icons/*.dl 2>/dev/null | grep -c '^list ' || true)
      grep -q "^Theme: .* from .*/themes/$t/theme.ini, $n draw lists from draw/ and icons/" "$work/$name.log" \
        || { echo "FAIL: $name was not drawn from themes/$t ($n lists): $(grep '^Theme:' "$work/$name.log")"; exit 1; } ;;
    *)
      grep -q "^Theme: Aqua from .*/themes/aqua/theme.ini, $lists draw lists from draw/ and icons/" "$work/$name.log" \
        || { echo "FAIL: $name was not drawn from themes/aqua/ (theme.ini and $lists lists in draw/): $(grep '^Theme:' "$work/$name.log")"; exit 1; } ;;
  esac
  # A scene must render the same twice, or it cannot be a golden at all.
  render "$name" "$scene" "$extra" "$work/$name.again.png" || exit 1
  "$work/pngdiff" "$out" "$work/$name.again.png" > /dev/null \
    || { echo "FAIL: $name is not deterministic — two renders differ"; exit 1; }
  checked=$((checked + 1))
  if [ "$update" = 1 ]; then
    cp "$out" "$dir/$name.png"
    echo "updated: $name"
    continue
  fi
  if [ ! -f "$dir/$name.png" ]; then
    missing="$missing $name"
    continue
  fi
  if ! verdict=$("$work/pngdiff" "$dir/$name.png" "$out" "$work/$name.diff.png"); then
    mkdir -p "$root/.build/golden-diff"
    cp "$out" "$root/.build/golden-diff/$name.actual.png"
    cp "$work/$name.diff.png" "$root/.build/golden-diff/$name.diff.png" 2>/dev/null || true
    echo "moved: $name — $verdict"
    moved="$moved $name"
  fi
done
unset IFS

[ "$update" = 1 ] && { echo "wrote $checked goldens to $dir"; exit 0; }
[ -z "$missing" ] || { echo "FAIL: no golden for:$missing (run with --update, on purpose)"; exit 1; }
if [ -n "$moved" ]; then
  echo "FAIL: pixels moved in:$moved"
  echo "      actual and diff images are in .build/golden-diff/"
  exit 1
fi
echo "all green ($checked scenes, pixel for pixel, on $os)."
