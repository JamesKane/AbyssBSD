#!/bin/sh
# AbyssBSD Swift DE — build + test loop.
#
# Default lane (fast, no compositor): build the SwiftPM package, run the unit
# tests, and render one headless Aqua frame as a smoke test. Exits non-zero on
# any failure (CI-friendly).
#
# Usage:
#   abyss/tests/run.sh              # build + unit tests + headless render
#   abyss/tests/run.sh --live       # ... and every live mode under headless sway
#   abyss/tests/run.sh --vm         # run this same script inside the FreeBSD VM
#   abyss/tests/run.sh --vm --live  # ... including the live modes, there
#   abyss/tests/run.sh --vm --live --full   # ... and the nested installs
#
# **`--full` is the lane that puts an operating system on a disk.** Two tests
# install AbyssBSD under nested bhyve and boot what they installed, and together
# they are 681 of the 1111 seconds a `--vm --live` run used to take — more than
# everything else in the suite combined. They are off by default because most
# changes cannot break them, and *on* is the rule for anything that touches the
# installer, the medium, the distribution sets or the boot path. The run says
# out loud which tests it did not run, because a skip nobody sees is a claim
# nobody checks.
#
# The --vm lane is the Phase-3 addition: it syncs the tree into the build VM
# (abyss/vm/*) and runs the identical script there, because the target is
# FreeBSD and only FreeBSD can tell us the truth about kqueue, sysctl and the
# fonts. Swift lives off PATH in the guest, so the lane spells out where it is.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

# **Say where the minutes go.** This suite is the thing a person waits on, and
# until it reported per-section time the only honest answer to "why is it slow"
# was a guess. Each `phase` prints how long the *previous* one took, and the
# total is the last line — so a run that got slower says which part did.
_phase_start=$(date +%s)
_phase_name=""
_run_start=$_phase_start
phase() {
  _now=$(date +%s)
  if [ -n "$_phase_name" ]; then
    printf '   (%s: %ss)\n' "$_phase_name" "$((_now - _phase_start))"
  fi
  _phase_name=$1
  _phase_start=$_now
  echo "== $1 =="
}
phase_end() {
  _now=$(date +%s)
  [ -n "$_phase_name" ] && printf '   (%s: %ss)\n' "$_phase_name" "$((_now - _phase_start))"
  _phase_name=""
  printf 'total: %ss\n' "$((_now - _run_start))"
}

live=0
vm=0
full=0
for arg in "$@"; do
  case "$arg" in
    --live) live=1 ;;
    --vm)   vm=1 ;;
    --full) full=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "usage: run.sh [--live] [--vm] [--full]" >&2; exit 2 ;;
  esac
done

if [ "$vm" -eq 1 ]; then
  # Sourced from outside abyss/vm, so tell config.sh where it lives ($0 is us).
  ABYSS_VM_DIR="$root/abyss/vm"
  export ABYSS_VM_DIR
  . "$root/abyss/vm/config.sh"
  phase "syncing to the FreeBSD VM"
  "$root/abyss/vm/sync.sh"
  phase "abyss/tests/run.sh, in the guest"
  remote="export PATH=$ABYSS_GUEST_SWIFT_BIN:\$PATH; cd $ABYSS_GUEST_SRC && sh abyss/tests/run.sh"
  [ "$live" -eq 1 ] && remote="$remote --live"
  [ "$full" -eq 1 ] && remote="$remote --full"
  # **Not `exec`.** Replacing this shell with ssh would take the timing with it:
  # the guest prints its own phases, but the sync — the one cost that is purely
  # the VM's — would never be reported, which is exactly the number a person
  # waiting fifteen minutes wants.
  # shellcheck disable=SC2046
  ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@127.0.0.1" "$remote"
  rc=$?
  phase_end
  exit $rc
fi

# FreeBSD has no pam_xdg, so nothing sets XDG_RUNTIME_DIR (HANDOFF §2.31) — and
# from Phase 6 the *unit tests* need one too, because `undertow` binds a Wayland
# socket and `wl_display_add_socket_auto` has nowhere to put it without one. The
# live scripts have sourced this helper since Phase 3; it belongs here as well
# now that `swift test` can care.
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

phase "swift build"
swift build

phase "swift test"
swift test

phase "headless Aqua render (smoke)"
out="${TMPDIR:-/tmp}/aqua-smoke-$$.png"
AQUA_RENDER_PNG="$out" AQUA_SCALE=2 .build/debug/AquaDemo
test -s "$out" && echo "ok: $out" || { echo "FAIL: no PNG produced"; exit 1; }
rm -f "$out"

# Every deterministic scene, pixel for pixel against the committed goldens for
# this platform (PHASE11 P11.1). About a second; the gate Phase 11 is proved by.
phase "golden images"
sh "$root/abyss/tests/golden.sh"

# Two real processes handing a descriptor over the control plane. In the default
# lane because it needs no compositor and takes about a second.
phase "control plane, two processes"
sh "$root/abyss/tests/live-ipc.sh"

# The compositor's frame contract (C1 + the allocation-free present path). In
# the default lane on purpose: it needs no compositor, no GPU and no display,
# which is exactly why the contract is built before the pixels (PHASE6.md P6.1).
phase "the frame contract"
sh "$root/abyss/tests/bench-metronome.sh"

# A real client on our own compositor. Also in the default lane, and notable for
# being the first test here that starts no sway at all — undertow IS the
# compositor (PHASE6.md P6.3).
phase "a real client on undertow"
sh "$root/abyss/tests/live-undertow.sh"

# ...and input reaching that client through our own seat, driven by the same
# unmodified vpointer the harness points at sway (PHASE6.md P6.4).
phase "input through undertow"
sh "$root/abyss/tests/live-undertow-input.sh"

# C2 — the claim the architecture exists to make good: eleven hostile processes
# cannot make the compositor drop a frame, and the healthy client keeps working
# throughout (PHASE6.md P6.5).
phase "C2: no client can make us miss a frame"
sh "$root/abyss/tests/live-undertow-c2.sh"

# The destination of Phase 6: the Aqua shell — wallpaper, menu bar and Dock,
# three layer-shell clients from Phase 2 — composing on undertow (P6.6).
phase "the Aqua shell on undertow"
sh "$root/abyss/tests/live-undertow-shell.sh"

# What only a compositor can do: a window remembers where it was dragged to, and
# reopens there in a NEW session (HANDOFF §2.22's debt, paid in P6.7).
phase "remembered window positions"
sh "$root/abyss/tests/live-undertow-places.sh"

# The file-chooser portal, end to end: a client, a picker, and a descriptor for
# a file the client never named. Needs a compositor, so it sits in --live.
if [ "$live" -eq 1 ]; then
  phase "the portal, end to end"
  sh "$root/abyss/tests/live-portal.sh"
  # And the claim that makes it worth having: a client with no filesystem.
  phase "the sandboxed client"
  sh "$root/abyss/tests/live-sandbox.sh"
  phase "notifications"
  sh "$root/abyss/tests/live-notify.sh" >/dev/null
  # The clipboard: an empty one says so, and a copy with no input behind it is
  # refused by name (PHASE9 P9.1). Against undertow, because undertow's own
  # handling is the thing under test.
  phase "the clipboard"
  sh "$root/abyss/tests/live-clipboard.sh" >/dev/null
  # And the same protocol with a grab on it: a file pressed in one process and
  # released on the Trash in another, plus the two other targets the shell
  # draws (PHASE9 P9.3). Every claim is checked on disk.
  phase "drag and drop"
  sh "$root/abyss/tests/live-dnd.sh" >/dev/null
  # What a window may ask about itself: moved by its title bar, zoomed to the
  # usable area (not the output), resized from a corner that stays anchored,
  # snapped to an edge, and put in the Dock and taken back out (P9.4).
  phase "window management"
  sh "$root/abyss/tests/live-window.sh" >/dev/null
  # And the keys the desktop hears first: a bound one never reaches the focused
  # client, an unbound one always does, and an application may keep a
  # combination for itself (P9.5, and §6.2's decision made into data).
  echo "== keybinds =="
  sh "$root/abyss/tests/live-keys.sh" >/dev/null
  # And a window that never heard of this desktop, wearing its frame: the
  # compositor answers xdg-decoration server-side and paints an Aqua title bar
  # around somebody else's surface (P9.6).
  echo "== server-side decorations =="
  sh "$root/abyss/tests/live-decorations.sh" >/dev/null
  # The depth gadget, the one window operation Phase 11 adds: lowered from a
  # frame undertow drew, and from an Aqua window's own chrome over
  # abyss_window_manager_v1 — both laid out by one function (P11.6).
  echo "== depth =="
  sh "$root/abyss/tests/live-depth.sh" >/dev/null
  # System Preferences as an application (PHASE14 P14.1): pointer, keyboard
  # and its menu vocabulary, on our own compositor.
  echo "== System Preferences =="
  sh "$root/abyss/tests/live-prefs.sh" >/dev/null
  # An application's vocabulary, asked by something that cannot draw a menu:
  # abyssmenu describes the Finder, is refused with reasons, and invokes verbs
  # whose results are checked on disk; a picker publishes nothing (P10.2).
  echo "== the vocabulary =="
  sh "$root/abyss/tests/live-vocabulary.sh" >/dev/null
  # And the compositor's half: a window publishes where its menus are, and
  # only a client on the privileged socket is told who is frontmost (P10.3).
  echo "== whose menus are whose =="
  sh "$root/abyss/tests/live-menu-focus.sh" >/dev/null
  # And the bar made real: the frontmost application's menus, drawn by our
  # own compositor (popups, at last), enabled as the app says as each menu
  # opens, chosen by pointer and by keyboard, checked on disk (P10.4).
  echo "== the menu bar =="
  sh "$root/abyss/tests/live-menus.sh" >/dev/null
  # Undo, decided: per window, a verb like any other, titled from the stack,
  # pushed to the bar, and never a delete (P10.5).
  echo "== undo =="
  sh "$root/abyss/tests/live-undo.sh" >/dev/null
  # A GTK application's menus in our bar: gtk_shell1 in undertow, the bridge
  # in abyss-dbus --menus, and the other end a stock GtkApplication (P10.6).
  echo "== GTK's menus in our bar =="
  sh "$root/abyss/tests/live-menus-gtk.sh" >/dev/null
  # And a Qt/KDE application's: stock kcalc, org_kde_kwin_appmenu in
  # undertow, com.canonical.dbusmenu through the same bridge (P10.7). Skips,
  # loudly, on a box without kcalc.
  echo "== Qt's menus in our bar =="
  sh "$root/abyss/tests/live-menus-qt.sh"
  # The menus the desktop owns: right-click menus built from the menu bar's
  # commands, and a system menu whose items do what they say (P10.8).
  echo "== the desktop's own menus =="
  sh "$root/abyss/tests/live-context.sh" >/dev/null
  # The same claim with a sharper control: a client that cannot call socket(2),
  # and therefore cannot reach the compositor, holding a picture of the screen.
  phase "the screenshot portal"
  sh "$root/abyss/tests/live-screenshot.sh"
  # The same portal, reached the way the rest of the world reaches one: a
  # session bus, org.freedesktop.portal.Desktop, and gdbus as an independent
  # witness that our Response decodes (PHASE8.md P8.2).
  phase "the portal on the session bus"
  sh "$root/abyss/tests/live-portal-dbus.sh"
  # ...and what it tells a foreign toolkit is the theme that is loaded — its
  # color-scheme, accent and contrast, with its palette beside (PHASE11 P11.10).
  phase "the portal's palette"
  sh "$root/abyss/tests/live-palette.sh"
  # And the caller the whole phase is for: a stock GTK 3 application, which has
  # never heard of us, getting the Finder as its file chooser (PHASE8.md P8.3).
  # Skips itself, loudly, on a box with no GTK runtime.
  phase "a real GTK application"
  sh "$root/abyss/tests/live-gtk.sh"
  # ...and the same claim with nobody assembling the session by hand: one
  # `anchor` command brings up compositor, bus, portal, bridge and shell
  # (PHASE8.md P8.4). Skips itself, loudly, on a box with no GTK runtime.
  phase "one command, a whole desktop"
  sh "$root/abyss/tests/live-session-gtk.sh"

  # And the pass where an operating system gets onto a disk: a root
  # `abyss-install` commanded by an unprivileged caller, installing onto a
  # scratch disk, and the result BOOTED under nested bhyve (PHASE5.md P5.2).
  # On Linux it is a positive control — the probe must refuse and say why — and
  # on FreeBSD it skips loudly without the dist sets or bhyve's UEFI firmware.
  if [ "$full" -eq 1 ]; then
    phase "the installer, and what it installed"
    sh "$root/abyss/tests/live-install.sh"

  # ...and the medium it all arrives on: an image assembled from distribution
  # sets with base tools only, booted nested, running our compositor with the
  # wallpaper, menu bar and Dock composited on it — checked pixel by pixel
  # (PHASE5.md P5.3). On Linux, a positive control: the builder must refuse.
  phase "the live medium"
  sh "$root/abyss/tests/live-medium.sh"

  # And the face on the front of it: the Aqua installer, driven by a real
  # pointer and a real keyboard on our own compositor, against the real
  # `abyss-install` in dry-run (PHASE5.md P5.4). On Linux it drives the account
  # spoke and asserts the hub stays disarmed — a positive control, not a skip.
  phase "the Aqua installer"
  sh "$root/abyss/tests/live-installer.sh"

  # And the whole thing, end to end: an empty disk, our medium, an install from
  # it, and a reboot into the Jaguar desktop (PHASE5.md P5.5). Nested twice
  # over, with nobody watching. On Linux, a positive control.
    phase "empty disk to Jaguar desktop"
    sh "$root/abyss/tests/live-desktop.sh"
  else
    # **Named, timed, and told how to run.** These two are the only tests in the
    # tree that put an operating system on a disk and boot it; skipping them
    # quietly would leave the suite green about a claim it never checked.
    phase "the nested installs — SKIPPED (--full runs them)"
    echo "   the installer, and what it installed   (~190s)"
    echo "   empty disk to Jaguar desktop           (~490s)"
    echo "   Run --full before shipping anything that touches the installer,"
    echo "   the medium, the distribution sets, or the boot path."
  fi
fi

# D-Bus against a real dbus-daemon, with dbus-send/gdbus as the callers — never
# our own encoder on both ends (PHASE8.md P8.1). Needs no compositor.
phase "D-Bus, against a real bus"
sh "$root/abyss/tests/live-dbus.sh"

# The hardware bridges against the real kernel (sysctl + devd on FreeBSD; on
# Linux it asserts the stubs report themselves absent). No compositor needed.
phase "hardware bridges"
sh "$root/abyss/tests/live-vents.sh"

if [ "$live" -eq 1 ]; then
  phase "live modes (headless sway + grim)"
  sh "$root/abyss/tests/run-live.sh"
fi

echo "all green."

phase_end
