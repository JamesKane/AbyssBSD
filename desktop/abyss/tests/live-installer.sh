#!/bin/sh
# AbyssBSD Swift DE — the Aqua installer, driven by a real pointer and a real
# keyboard, on our own compositor (PHASE5.md P5.4).
#
# The claim:
#
#     Someone clicking and typing at the Aqua installer produces exactly the
#     plan they described — and cannot start an install until they have
#     described one.
#
# Four processes, and none of them is a mock:
#
#   undertow        our compositor (P6.3)
#   abyss-install   the real installer service, in --dry-run so nothing is
#                   written; it still probes the real machine and applies the
#                   real refusals
#   AquaDemo        AQUA_SCENE=installer — the app under test
#   vpointer/vkeyboard  the harness's own input, unmodified since Phase 1
#
# **Clicks come from the app's own layout, not from constants in this file.**
# `ABYSS_INSTALLER_DUMP` makes the installer publish the centre of every rect it
# drew, and this script clicks those. A test that hardcodes coordinates is
# testing a screenshot from the day it was written.
#
# On Linux the disk half cannot work — `abyss-install` says so, in as many words
# — so this drives the account spoke and asserts the hub stays disarmed. That is
# a positive control, not a skip.
#
# Usage: abyss/tests/live-installer.sh
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
FRAMES=900

work=$(mktemp -d /tmp/abyss-inst4.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-inst4r.XXXXXX)
vp_dir="$work/vp"
mkdir -p "$vp_dir"
cleanup() {
  [ -n "${fd3:-}" ] && exec 3>&- 2>/dev/null || true
  [ -n "${fd4:-}" ] && exec 4>&- 2>/dev/null || true
  for p in ${vk_pid:-} ${vp_pid:-} ${app_pid:-} ${svc_pid:-} ${ut_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT
export ABYSS_RUNTIME_DIR="$rundir"
export ABYSS_INSTALL_SERVICE=installtest

fail() { echo "FAIL: $1"
         [ -s "$work/aqua.log" ] && sed 's/^/  app| /' "$work/aqua.log" | tail -25
         exit 1; }

# ------------------------------------------------------------- the input tools
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$vp_dir/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$vp_dir/vpointer-proto.c"
cc -I"$vp_dir" "$root/abyss/tests/vpointer.c" "$vp_dir/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$vp_dir/vpointer" \
   || fail "could not build vpointer"
kxml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
wayland-scanner client-header "$kxml" "$vp_dir/vkeyboard-proto.h"
wayland-scanner private-code  "$kxml" "$vp_dir/vkeyboard-proto.c"
cc -I"$vp_dir" "$root/abyss/tests/vkeyboard.c" "$vp_dir/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$vp_dir/vkeyboard" \
   || fail "could not build vkeyboard"

# ------------------------------------------------------------ the compositor
wd="abyss-inst4-$$"
"$undertow" run --hz 60 --frames "$FRAMES" --width "$W" --height "$H" \
   --socket "$wd" --capture "$work/frame.ppm" \
   > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/$wd" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/$wd" ] || fail "undertow never bound $wd"

# ------------------------------------------------------------ the installer service
# --dry-run: it probes the real machine and applies the real refusals, and runs
# no command. The GUI cannot tell the difference, which is the point.
"$svc" --uid "$(id -u)" --dry-run --service installtest \
   > /dev/null 2> "$work/svc.err" &
svc_pid=$!
i=0; while [ ! -S "$rundir/installtest.sock" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$rundir/installtest.sock" ] || fail "abyss-install never bound its socket"

# ------------------------------------------------------------------- the app
env WAYLAND_DISPLAY="$wd" AQUA_SCENE=installer ABYSS_INSTALLER_DUMP=1 \
    "$client" > "$work/aqua.log" 2>&1 &
app_pid=$!
i=0; while ! grep -q "installer is up" "$work/aqua.log" 2>/dev/null && [ $i -lt 120 ]; do
  i=$((i+1)); sleep 0.05
done
grep -q "installer is up" "$work/aqua.log" || fail "the installer never started"
i=0; while ! grep -q "Installer: layout" "$work/aqua.log" 2>/dev/null && [ $i -lt 200 ]; do
  i=$((i+1)); sleep 0.05
done
grep -q "Installer: layout" "$work/aqua.log" \
  || fail "the installer never drew a frame"
echo "ok: the installer is up and drawing"
sed -n 's/^AquaDemo: installer is up — /    /p' "$work/aqua.log"

# Where the window sits: undertow centres a toplevel on the output, so surface
# (0,0) is at ((W-w)/2, (H-h)/2). The size comes from the window itself — the
# only thing that knows it — rather than from a constant here.
wingeom=$(grep -o "Installer: layout size=[0-9]*x[0-9]*" "$work/aqua.log" | head -1 | sed 's/.*size=//')
winw=${wingeom%x*}; winh=${wingeom#*x}
[ -n "$winw" ] && [ -n "$winh" ] || fail "the installer did not publish its size"
ox=$(( (W - winw) / 2 )); oy=$(( (H - winh) / 2 ))

# ------------------------------------------------------------------- input
fifo="$work/vp.fifo"; mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$vp_dir/vpointer" "$W" "$H" < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3>"$fifo"; fd3=1
i=0; while ! grep -q ready "$work/vp.log" 2>/dev/null && [ $i -lt 60 ]; do i=$((i+1)); sleep 0.1; done
grep -q ready "$work/vp.log" || fail "the virtual pointer never bound"

kfifo="$work/vk.fifo"; mkfifo "$kfifo"
env WAYLAND_DISPLAY="$wd" "$vp_dir/vkeyboard" < "$kfifo" > "$work/vk.log" 2>&1 &
vk_pid=$!
exec 4>"$kfifo"; fd4=1
i=0; while ! grep -q ready "$work/vk.log" 2>/dev/null && [ $i -lt 60 ]; do i=$((i+1)); sleep 0.1; done
grep -q ready "$work/vk.log" || fail "the virtual keyboard never bound"
sleep 0.6
echo "ok: a real pointer and a real keyboard are attached"

# The app publishes the centre of every rect it drew; click those.
rect() {  # rect <name> -> prints "X Y" in output coordinates, or nothing
  line=$(grep -o "Installer: layout .*" "$work/aqua.log" | tail -1)
  v=$(echo "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" | tail -1)
  [ -n "$v" ] || return 1
  echo "$(( ox + ${v%,*} )) $(( oy + ${v#*,} ))"
}
click() {
  # `rect` runs in a subshell, so its exit cannot end this script — check the
  # result here or a missing rect becomes an unbound-variable error three lines
  # later, which says nothing about what went wrong.
  xy=$(rect "$1") || fail "the installer never drew anything called '$1' —" \
                          "what is clickable has drifted from what is drawn"
  # shellcheck disable=SC2086
  set -- $xy
  printf 'm %s %s\np\nr\n' "$1" "$2" >&3
  sleep 0.45
}
type_text() { printf 't %s\n' "$1" >&4; sleep 0.35; }

# ------------------------------------------- 1. the button is dead, and says so
click primary
grep -q "install is not armed" "$work/aqua.log" \
  || fail "the Install button did something with nothing filled in"
grep -q "Installer: install is not armed: Still to do" "$work/aqua.log" \
  || fail "it refused, but did not say what was missing"
echo "ok: Install did nothing, and said what was still to do"

# ------------------------------------------------- 2. the account spoke, typed
click spoke3
grep -q "entered User Account" "$work/aqua.log" || fail "the account spoke did not open"
click field1                      # Short Name
type_text "abyss"
click field2                      # Password
type_text "hunter2"
click field3                      # Verify
type_text "hunter2"
click primary                     # Done
grep -q "Installer: account is abyss$" "$work/aqua.log" \
  || fail "typing did not reach the account fields"
echo "ok: typed an account in, through a real keyboard and xkbcommon"

# ------------------------------------------------------------ 3. the disk spoke
if [ "$(uname -s)" = FreeBSD ]; then
  click spoke1
  grep -q "entered Installation Disk" "$work/aqua.log" || fail "the disk spoke did not open"
  # Row 0 is the first disk the machine reported. The build VM boots from vtbd0,
  # so it must be refused — live, by the same predicate the unit tests exercise.
  click row0
  click primary
  grep -q "Installer: refused that disk" "$work/aqua.log" \
    || fail "the installer accepted the disk it is running from"
  echo "ok: the disk it boots from was offered, explained, and refused"

  # A refused choice must leave you ON the list, next to the reason — being
  # returned to the hub with nothing chosen looks exactly like success. (This is
  # what the test found the first time it ran: the disk list was gone, and the
  # clicks after it landed on the hub.)
  grep -q "Installer: layout .*row0=" "$work/aqua.log" \
    || fail "a refused disk closed the list; the reason is no longer on screen"
  echo "ok: ...and it stayed on the list, where the reason is written"

  # Now a disk it can have. Try each row until one takes: which disk that is
  # depends on the machine, and the point is that exactly one of them is
  # installable — not that it is the third.
  #
  # **A disk with something on it asks first**, and this is where that gets
  # exercised with a real pointer rather than in a model test. The scratch disk
  # in the build VM carries the previous run's install, so the ordinary path
  # through this installer now goes through the sheet — which is the point: the
  # question is not an edge case, it is what most machines will do.
  rows=$(grep -o "Installer: layout .*" "$work/aqua.log" | tail -1 | tr ' ' '\n' | grep -c '^row')
  n=0
  asked=0
  while [ $n -lt "$rows" ]; do
    grep -q "Installer: disk is " "$work/aqua.log" && break
    click "row$n"; click primary
    # If it asked, answer. `primary` on the sheet is the destructive button and
    # is deliberately NOT the default — clicking it is a decision, here as on
    # the screen.
    if grep -q "Installer: asking before erasing " "$work/aqua.log"; then
      asked=1
      click primary
    fi
    n=$((n + 1))
  done
  grep -q "Installer: disk is " "$work/aqua.log" || fail "no disk could be chosen at all"
  chosen=$(grep -o "Installer: disk is .*" "$work/aqua.log" | tail -1 | awk '{print $4}')
  if [ "$asked" = 1 ]; then
    grep -q "Installer: erasing $chosen was confirmed" "$work/aqua.log" \
      || fail "the sheet was answered but the confirmation was never recorded for $chosen"
    echo "ok: $chosen had something on it, the installer asked, and a click answered"
  else
    echo "ok: chose $chosen — it had room, so nothing was asked"
  fi

  grep -q "Installer: ready to install" "$work/aqua.log" \
    || fail "a complete hub did not arm the Install button"
  echo "ok: with a disk and an account, the hub armed"

  # ------------------------------------------------- 4. the point of no return
  click primary
  grep -q "Installer: confirming: erase $chosen" "$work/aqua.log" \
    || fail "the confirmation did not name the disk"
  echo "ok: the confirmation names $chosen in the sentence, and nothing has run"
else
  # No geom(8) here, so the service cannot look — and the hub must carry ITS
  # words rather than inventing "no disks found".
  grep -q "AquaDemo: installer is up — 0 disk(s), and:" "$work/aqua.log" \
    || fail "on $(uname -s) the installer did not report why it has no disks"
  grep -q "geom" "$work/aqua.log" || fail "the reason does not name what was missing"
  click primary
  grep -q "install is not armed" "$work/aqua.log" \
    || fail "the hub armed on a machine with no installable disk"
  echo "ok: no disks, the reason is the service's own words, and Install stayed dead"
fi

# --------------------------------------------------------------- 5. the picture
exec 3>&-; fd3=""
exec 4>&-; fd4=""
# Let the compositor run out its frames with the installer STILL UP: the capture
# is written on the last frame, and killing the client first leaves a picture of
# an empty desktop — which is what the first version of this test produced, and
# it looked like a compositor bug rather than a test one.
wait "$ut_pid" 2>/dev/null || true; ut_pid=""
kill "$app_pid" 2>/dev/null || true; app_pid=""
# And it really was OUR compositor doing the compositing, not a window that
# happened to exist: undertow's own summary counts what it drew.
# `mapped` and not `surfaces-composited`: the app is closed by the time undertow
# writes its summary, so the live scene count is zero by then. `mapped` is the
# record of every window that ever appeared — which is exactly the distinction
# P8.3 added it for, when a test asserted on survivors and could never pass.
grep -q "^mapped org.abyssbsd.aquademo" "$work/ut.out" \
  || { sed 's/^/    /' "$work/ut.out"; fail "undertow never composited our window"; }
echo "ok: undertow composited it — $(grep '^mapped ' "$work/ut.out" | head -1)"

[ -s "$work/frame.ppm" ] || fail "the compositor captured no frame"
head -c 2 "$work/frame.ppm" | grep -q P6 || fail "the capture is not a P6 netpbm"
cp "$work/frame.ppm" "${ABYSS_INSTALLER_SHOT:-$work/keep.ppm}" 2>/dev/null || true

# And the window is really IN that frame. undertow's fallback blue is 61,102,161
# — the colour of an output with nothing composited on it — so the middle of the
# frame being pale Aqua chrome is the difference between "a window mapped" and
# "a window was drawn".
hdr_len=$(printf 'P6\n%s %s\n255\n' "$W" "$H" | wc -c | tr -d ' ')
# 40 px left of the exact middle: the pointer may rest there, drawn as the
# theme's arrow since U.7 (HANDOFF §2.85).
off=$(( hdr_len + (((H / 2) * W) + (W / 2 - 40)) * 3 ))
mid=$(dd if="$work/frame.ppm" bs=1 skip="$off" count=3 2>/dev/null | od -An -v -tu1 | awk '{print $1, $2, $3}')
[ "$mid" != "61 102 161" ] \
  || fail "the captured frame is bare output — the installer was not drawn on it"
light=$(echo "$mid" | awk '{print int(($1 + $2 + $3) / 3)}')
[ "$light" -gt 150 ] || fail "the middle of the frame is not the installer's panel ($mid)"
echo "ok: the installer is in the captured frame, not just in the log ($mid)"

echo "all green (the installer builds the plan you described, and nothing else)."
