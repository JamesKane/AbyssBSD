#!/bin/sh
# AbyssBSD Swift DE — a file is dragged out of the Finder and onto the Trash (P9.3).
#
# Two of our own processes, our own compositor, and a real pointer: the Finder
# holds a file, the Dock holds the Trash, and the file crosses between them
# through `wl_data_device` — press, move, release, and the file is in ~/.Trash.
#
# **Against undertow, because undertow is what is under test.** A drag is three
# compositor mechanisms, none of which existed before this pass:
#
#   - `request_start_drag`, which checks that the serial belongs to a press the
#     client actually received (`wlr_seat_validate_pointer_grab_serial`) — the
#     same guard that made P9.1's surfaceless copy impossible;
#   - the drag grab, which turns pointer motion into `data_device` enter/motion
#     on whatever surface the pointer crosses;
#   - **pointer routing to layer surfaces**, which undertow did not have. The
#     Dock is a layer surface; every test that ever clicked it ran on sway. A
#     drop target the pointer cannot reach is not a drop target, and this is the
#     test that says so.
#
# The assertion is the file on disk (§2.43), in both directions: it is in the
# Trash, and it is gone from where it was.
#
# Usage: abyss/tests/live-dnd.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$aqua" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-dnd.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${finder_pid:-} ${dock_pid:-} ${ut_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" 2>/dev/null || true
}
# INT/TERM as well as EXIT: a `timeout` on this script kills the shell with a
# signal, and a shell that dies on an untrapped signal never runs its EXIT trap —
# which leaves an undertow squatting on a `wayland-N` that the *next* test's
# clients then connect to instead of their own compositor.
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

# A HOME of our own: `finderMoveToTrash` puts things in $HOME/.Trash, and this
# test must never be able to reach the person's real one.
home="$work/home"
finderdir="$home/Files"
mkdir -p "$finderdir/Applications" "$finderdir/Documents" "$finderdir/Pictures"
printf 'Welcome to AbyssBSD.\n' > "$finderdir/Read Me.txt"
printf 'Dear Aqua,\n' > "$finderdir/Letter.txt"

# ------------------------------------------------------------ the compositor
# 800x600 so the Dock's tiles land where the sway Dock tests already measured
# them, and `--frames 0` because this run has to outlive its own frame count.
# **Where the spatial window will open, decided in advance.** undertow restores
# a remembered position before it cascades (P6.7), and the key is app_id/title —
# so writing one here puts the Documents window low on the screen, clear of the
# first Finder's icon row. A test that needs two windows in known places has no
# other way to ask for one, and this exercises the restore path as a bonus.
mkdir -p "$work/ut-cfg"
cat > "$work/ut-cfg/windows.ini" <<INI
[windows]
org.abyssbsd.finder/Documents = 164,300
INI

# `--config-dir` so the remembered window positions this run writes are its own:
# a place remembered from a previous run would move a window out from under the
# coordinates below, and the failure would look like a mis-aimed click.
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --verbose --width 800 --height 600 \
    --config-dir "$work/ut-cfg" \
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

# ------------------------------------------------------------------- the Dock
env WAYLAND_DISPLAY="$wd" HOME="$home" ABYSS_CONFIG_DIR="$work/cfg" \
    AQUA_SCENE=dock "$aqua" > "$work/dock.log" 2>&1 &
dock_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q 'Dock: Trash' "$work/dock.log" 2>/dev/null && break
  kill -0 "$dock_pid" 2>/dev/null || fail "the Dock exited: $(cat "$work/dock.log")"
  sleep 0.25; i=$((i + 1))
done
grep -q 'Dock: Trash empty' "$work/dock.log" || fail "the Trash did not start empty"
! grep -q 'drops are off' "$work/dock.log" \
  || fail "the Dock got no data device, so it can take no drops"
echo "ok: the Dock is up, its Trash is empty, and it is listening for drops"

# ----------------------------------------------------------------- the Finder
env WAYLAND_DISPLAY="$wd" HOME="$home" ABYSS_FINDER_DIR="$finderdir" \
    ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=finder "$aqua" > "$work/finder.log" 2>&1 &
finder_pid=$!
i=0
while [ $i -lt 80 ]; do
  grep -q 'Finder: listed' "$work/finder.log" 2>/dev/null && break
  kill -0 "$finder_pid" 2>/dev/null || fail "the Finder exited: $(cat "$work/finder.log")"
  sleep 0.25; i=$((i + 1))
done
echo "ok: the Finder is up on $finderdir"

# ---------------------------------------------------------------- the pointer
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" \
   || fail "could not build the virtual pointer"
fifo="$work/pointer"
mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 800 600 < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$fifo"
sleep 1.5

# ------------------------------------------------------------------- the drag
#
# undertow centres a new window in the usable area, so the Finder's 520x400
# sits at (140, 100). Inside it the icon grid is 10px of padding and 88px
# cells under the 22px title bar and the 36px toolbar — the same numbers the
# sway Finder tests aim at. The five entries sort by name — folders are not
# hoisted — so "Read Me.txt" is cell 4: local (406, 96), screen (546, 196).
printf 'm 546 196\np\n' >&3
sleep 0.6
grep -q 'Finder: selected Read Me.txt' "$work/finder.log" \
  || fail "the press did not land on Read Me.txt — the window is not where this
    test thinks it is: $(tail -3 "$work/finder.log")"
echo "ok: pressed on Read Me.txt"

# Past the 4px threshold that separates a click from a drag.
printf 'm 546 212\n' >&3
sleep 0.6
grep -q "Finder: dragging $finderdir/Read Me.txt" "$work/finder.log" \
  || fail "moving with the button down started no drag: $(tail -3 "$work/finder.log")"
i=0
while [ $i -lt 20 ]; do
  grep -q '^drags-started=1' "$work/ut.out" 2>/dev/null && break
  sleep 0.25; i=$((i + 1))
done
grep -q '^drags-started=1' "$work/ut.out" \
  || fail "the client asked for a drag and undertow did not start one — the
    serial check refused it: $(grep -i drag "$work/ut.err" | tail -2)"
echo "ok: undertow started the drag (the serial came from the press that caused it)"

# Onto the Trash: the last tile, where the Dock says it is (P15.2). The drag
# drives magnification the same way a hover does — the tile the person watched
# grow is the tile that takes the drop.
tx=$(grep 'Dock: tiles ' "$work/dock.log" | tail -1 | tr ' ' '\n' | sed -n 's/^Trash=\([0-9]*\),.*/\1/p')
ty=$(grep 'Dock: tiles ' "$work/dock.log" | tail -1 | tr ' ' '\n' | sed -n 's/^Trash=[0-9]*,\([0-9]*\)/\1/p')
[ -n "$tx" ] || fail "the Dock did not say where the Trash is: $(cat "$work/dock.log")"
printf 'm %s %s\n' "$tx" "$((600 - ty))" >&3
sleep 0.8
printf 'r\n' >&3
sleep 1.5

grep -q "Dock: threw away $finderdir/Read Me.txt" "$work/dock.log" \
  || fail "the Trash did not take the drop: $(tail -5 "$work/dock.log")"

# ------------------------------------------------------- and on disk (§2.43)
[ -f "$home/.Trash/Read Me.txt" ] \
  || fail "nothing reached the Trash: $(ls -a "$home/.Trash" 2>/dev/null | tr '\n' ' ')"
grep -q 'Welcome to AbyssBSD' "$home/.Trash/Read Me.txt" \
  || fail "a file reached the Trash but its contents are wrong"
[ ! -e "$finderdir/Read Me.txt" ] \
  || fail "the file was copied to the Trash instead of moved — it is still in $finderdir"
echo "ok: the file is in ~/.Trash and gone from the folder it was dragged out of"

grep -q 'Dock: Trash is now full' "$work/dock.log" \
  || fail "the tile did not notice — the Trash glyph still says empty"
echo "ok: the Dock's tile noticed and switched to the full glyph"

# ------------------------------- the second target: another window, same process
#
# **Two windows in one process, because that is the case that discriminates.**
# A drop arrives on the seat with no window attached; the client has to work out
# which of its windows was under it, and every earlier arrangement here had one
# window per process — where "the first window" is also the right answer, and a
# broken lookup passes. So: spatial mode, a second window of the *same* Finder,
# and a drop that lands where both windows overlap. Only the `wl_surface` the
# drag entered can tell them apart.
#
# The pill at the title bar's right hides the toolbar, which is what makes a
# folder open in its own window (10.2's spatial Finder). The window is 520 wide
# at (140, 100), so the pill is at (640, 111).
printf 'm 640 111\np\nr\n' >&3
sleep 0.8
grep -q 'Finder: toolbar hidden (spatial mode)' "$work/finder.log" \
  || fail "the pill did not hide the toolbar: $(tail -3 "$work/finder.log")"

# With no toolbar the grid starts under the 22px title bar, so cell 1
# ("Documents" — the entries are Applications, Documents, Letter.txt, Pictures
# now that Read Me.txt is in the Trash) is at local (142, 60), screen (282,
# 160). Double-click it.
printf 'm 282 160\np\nr\n' >&3
sleep 0.2
printf 'p\nr\n' >&3
sleep 1.2
grep -q "Finder: new window $finderdir/Documents (2 open)" "$work/finder.log" \
  || fail "spatial open made no second window: $(tail -3 "$work/finder.log")"
# If the place had not been restored the window would have cascaded to (164,
# 124), covering the icon row the next press aims at — so the press below is
# itself the check that the restore happened.
echo "ok: one Finder now has two windows, the second at its remembered place"

# Drag "Letter.txt" (cell 2, local (230, 60) — screen (370, 160)) out of the
# first window and drop it at (400, 550) — inside the Documents window, which
# runs from y=300 down, and below the first window, which ends at y=500. The
# drop still arrives on the seat with no window attached, and "the window this
# application happens to list first" is still the wrong answer to which window
# took it: that is the window the file came *out* of.
#
# (The gap has to be a real one. Pressing to start a drag raises and focuses the
# source window, so anywhere the two overlap belongs to the source by then —
# which is itself the reason the naive lookup looks right for so long.)
printf 'm 370 160\np\n' >&3
sleep 0.6
grep -q 'Finder: selected Letter.txt' "$work/finder.log" \
  || fail "the press did not land on Letter.txt: $(tail -3 "$work/finder.log")"
printf 'm 370 176\n' >&3
sleep 0.6
grep -q "Finder: dragging $finderdir/Letter.txt" "$work/finder.log" \
  || fail "no drag started from the first window: $(tail -3 "$work/finder.log")"
printf 'm 400 550\n' >&3
sleep 0.8
printf 'r\n' >&3
sleep 1.5

[ -f "$finderdir/Documents/Letter.txt" ] \
  || fail "the drop did not land in the window it was released over:
    Documents holds $(ls -a "$finderdir/Documents" | tr '\n' ' ')
    $(tail -3 "$work/finder.log")"
grep -q 'Dear Aqua' "$finderdir/Documents/Letter.txt" \
  || fail "a file arrived in Documents but its contents are wrong"
[ -f "$finderdir/Letter.txt" ] \
  || fail "dropping between windows moved the original instead of copying it"
echo "ok: the drop went to the window under it, not the window it came from"

# The Documents window sits over the shelf, and a toplevel beats a bottom-layer
# surface for the pointer — so close it before aiming at the Dock. Its title bar
# is underneath the first window, so raise it first by clicking the part of it
# that shows below (400, 550); then its red light, at local (16, 11), is on top
# at screen (180, 311).
printf 'm 400 550\np\nr\n' >&3
sleep 0.5
printf 'm 180 311\np\nr\n' >&3
sleep 0.8
grep -q "Finder: closed $finderdir/Documents (1 open)" "$work/finder.log" \
  || fail "the close light did not close the Documents window:
    $(tail -3 "$work/finder.log")"

# ------------------------------------- the third target: a tile that opens it
#
# The Trash is the target that destroys; this is the one that *does* something
# with what it is given. A folder dropped on the Finder tile opens that folder —
# the Mac's rule, and the reason a Dock tile is a drop target at all.
#
# The tile is the first on the shelf: six tiles of 48 with 6px gaps centre a
# 318px panel at x=241, so tile 0 sits around x=265, and the shelf's icons run
# to y=588 on a 600-tall output. "Pictures" is cell 3, at screen (458, 160).
#
# **That tile is also underneath where the Documents window just was**, which
# makes this the regression test for §2.57: a client that destroys its proxies
# without sending the destructor requests leaves that surface mapped in the
# compositor for ever, and this drop lands in a rectangle of dead screen.
printf 'm 458 160\np\n' >&3
sleep 0.6
grep -q 'Finder: selected Pictures' "$work/finder.log" \
  || fail "the press did not land on Pictures: $(tail -3 "$work/finder.log")"
printf 'm 458 176\n' >&3
sleep 0.6
fx=$(grep 'Dock: tiles ' "$work/dock.log" | tail -1 | tr ' ' '\n' | sed -n 's/^Finder=\([0-9]*\),.*/\1/p')
[ -n "$fx" ] || fail "the Dock did not say where the Finder tile is"
printf 'm %s %s\n' "$fx" "$((600 - ty))" >&3
sleep 0.8
printf 'r\n' >&3
sleep 2

grep -q "Dock: opened $finderdir/Pictures" "$work/dock.log" \
  || fail "the Finder tile did not open what was dropped on it:
    $(tail -5 "$work/dock.log")"
# And it really launched: the new Finder is the Dock's child, so it says so on
# the Dock's stderr. A log line from the tile without one from the window would
# mean the Dock decided to open something and then did not.
i=0
while [ $i -lt 40 ]; do
  grep -q "Finder: listed $finderdir/Pictures" "$work/dock.log" 2>/dev/null && break
  sleep 0.25; i=$((i + 1))
done
grep -q "Finder: listed $finderdir/Pictures" "$work/dock.log" \
  || fail "the tile said it opened Pictures but no Finder ever listed it:
    $(tail -5 "$work/dock.log")"
echo "ok: a folder dropped on the Finder tile opened it in a new window"

exec 3>&- 2>/dev/null || true
echo "all green (the Trash, an application's tile, and another Finder's window)."
