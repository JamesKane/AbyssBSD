#!/bin/sh
# AbyssBSD Swift DE — the installer's keyboard choice applies on the medium
# (BACKLOG T.2).
#
# The installer wrote the chosen layout to the installed system's rc.conf and
# nowhere else, so on the live medium the account's password was typed in the
# US layout whatever the Keyboard page said — and the person could not log in
# to what they had installed. Now the choice is also the session's
# (keyboard.ini), and undertow gives it to every keyboard with no keymap of its
# own, at once.
#
# The keyboard is undertow's stand-in for a hardware one (`--stand-in-keyboard`):
# a keyboard with no keymap of its own, which is what libinput hands a
# compositor on metal — a virtual keyboard brings its own layout, and keeps it.
# German swaps Y and Z, so the same keys spell different names:
#
#   1. before a layout is chosen, the keys y-e-b-r-a type "yebra" (U.S.);
#   2. choosing German on the Keyboard page makes it this session's, and
#      undertow puts it on the keyboard, saying so;
#   3. the same keys now type "zebra" into the account's short name;
#   4. the installed system still gets the file: the plan's keymap is de.kbd.
#
# Usage: abyss/tests/live-installer-keyboard.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
svc="$root/.build/debug/abyss-install"
[ -x "$undertow" ] && [ -x "$client" ] && [ -x "$svc" ] || swift build

W=1024
H=768
work=$(mktemp -d /tmp/abyss-instk.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-instkr.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${app_pid:-} ${svc_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
export ABYSS_RUNTIME_DIR="$rundir"
export ABYSS_INSTALL_SERVICE=installtest
mkdir -p "$work/cfg"
export ABYSS_CONFIG_DIR="$work/cfg"

fail() { echo "FAIL: $1"
         [ -s "$work/aqua.log" ] && sed 's/^/  app| /' "$work/aqua.log" | grep -v 'layout ' | tail -8
         grep -E 'keyboard|keymap' "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /' | tail -5
         exit 1; }
await() {  # await FILE PATTERN WHY
  i=0; while ! grep -q -- "$2" "$1" 2>/dev/null && [ $i -lt 80 ]; do i=$((i + 1)); sleep 0.05; done
  grep -q -- "$2" "$1" 2>/dev/null || fail "$3"
}

xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"

# ------------------------------------------------------------ the compositor
# XKB_DEFAULT_LAYOUT would override everything (it does on the dev box).
mkfifo "$work/kbd"
wd="abyss-instk-$$"
env -u XKB_DEFAULT_LAYOUT -u XKB_DEFAULT_VARIANT "$undertow" run --hz 60 --frames 0 --width "$W" --height "$H" \
   --socket "$wd" --config-dir "$work/cfg" --stand-in-keyboard "$work/kbd" \
   > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/$wd" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/$wd" ] || fail "undertow never bound $wd"
grep -q 'stand-in keyboard had no keymap; gave it' "$work/ut.err" || fail "the stand-in keyboard was not given a keymap"
exec 3<>"$work/kbd"
keys() { for k in "$@"; do printf 'k %s\n' "$k" >&3; sleep 0.06; done; sleep 0.3; }

"$svc" --uid "$(id -u)" --dry-run --service installtest > /dev/null 2> "$work/svc.err" &
svc_pid=$!
i=0; while [ ! -S "$rundir/installtest.sock" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done

env WAYLAND_DISPLAY="$wd" AQUA_SCENE=installer ABYSS_INSTALLER_DUMP=1 \
    "$client" > "$work/aqua.log" 2>&1 &
app_pid=$!
await "$work/aqua.log" "Installer: layout" "the installer never drew a frame"
wingeom=$(grep -o "Installer: layout size=[0-9]*x[0-9]*" "$work/aqua.log" | head -1 | sed 's/.*size=//')
winw=${wingeom%x*}; winh=${wingeom#*x}
ox=$(( (W - winw) / 2 )); oy=$(( (H - winh) / 2 ))

mkfifo "$work/vp.fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" "$W" "$H" < "$work/vp.fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 4>"$work/vp.fifo"
await "$work/vp.log" ready "the virtual pointer never bound"
sleep 0.5
rect() {
  line=$(grep -o "Installer: layout .*" "$work/aqua.log" | tail -1)
  v=$(echo "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" | tail -1)
  [ -n "$v" ] || return 1
  echo "$(( ox + ${v%,*} )) $(( oy + ${v#*,} ))"
}
click() {
  xy=$(rect "$1") || fail "the installer drew nothing called '$1'"
  set -- $xy
  printf 'm %s %s\np\nr\n' "$1" "$2" >&4
  sleep 0.45
}
account() {  # account: open the account spoke, clear the short name, type y-e-b-r-a, Done
  click spoke3
  click field1
  keys 14 14 14 14 14 14                          # ⌫ — whatever was there
  keys 21 18 48 19 30                             # the keys marked Y E B R A on a US board
  click primary
}

# ------------------------------------------------------------ 1. U.S.
await "$work/ut.out" "keyboard-layout " "undertow never reported its keyboard layout"
grep '^keyboard-layout ' "$work/ut.out" | tail -1 | grep -q 'changes=0' || fail "the layout changed before anyone chose one"
account
await "$work/aqua.log" "Installer: account is yebra" "before a layout was chosen, y-e-b-r-a did not type yebra: $(grep 'account is' "$work/aqua.log" | tail -1)"
echo "ok: 1. before a layout is chosen, the keys y-e-b-r-a type 'yebra' ($(grep '^keyboard-layout ' "$work/ut.out" | tail -1 | sed 's/ changes=.*//; s/keyboard-layout //'))"

# ------------------------------------------------------------ 2. German
click spoke0
grep -q "entered Keyboard" "$work/aqua.log" || fail "the Keyboard spoke did not open"
click row2                                        # German
click primary
await "$work/aqua.log" "Installer: keyboard is de.kbd" "choosing German did not choose de.kbd"
await "$work/aqua.log" "Installer: this session types German now" "the installer did not make German this session's"
grep -q '^kbdmap *= *de.kbd' "$work/cfg/keyboard.ini" || fail "keyboard.ini does not say de.kbd: $(cat "$work/cfg/keyboard.ini" 2>&1)"
await "$work/ut.err" "keyboard layout is now German (keyboard.ini), on 1 keyboard(s)" \
  "undertow did not put German on the keyboard"
echo "ok: 2. choosing German made it this session's (keyboard.ini), and undertow put it on the keyboard"

# ------------------------------------------------------------ 3. zebra
n=$(grep -c "Installer: account is" "$work/aqua.log")
account
i=0; while [ "$(grep -c "Installer: account is" "$work/aqua.log")" -le "$n" ] && [ $i -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
got=$(grep "Installer: account is" "$work/aqua.log" | tail -1)
case "$got" in
  *"account is zebra"*) ;;
  *) fail "with German chosen, y-e-b-r-a should type zebra: $got" ;;
esac
echo "ok: 3. the same keys now type 'zebra' — the short name is typed in the layout the person chose"

# ------------------------------------------------------------ 4. the plan
case "$(grep -o 'Installer: keyboard is [^ ]*' "$work/aqua.log" | tail -1)" in
  *de.kbd) echo "ok: 4. the installed system still gets the file: keymap de.kbd for rc.conf" ;;
  *) fail "the plan's keymap is not de.kbd" ;;
esac

echo "all green (the keyboard chosen in the installer is the one the medium types with)."
