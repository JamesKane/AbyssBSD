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
# Run a test quietly — and when it fails, say which and show what it said.
# Tests used to run `>/dev/null`, which kept a green run short and threw away
# the one line that mattered on a red one: the P14.9 gate stopped at "== drag
# and drop ==" with no reason, from a test that passed three times alone.
quiet() {
  _log=$(mktemp /tmp/abyss-run.XXXXXX)
  if sh "$@" > "$_log" 2>&1; then rm -f "$_log"; return 0; fi
  echo "FAIL: $(basename "$1") — its last words:"
  tail -25 "$_log" | sed 's/^/   | /'
  rm -f "$_log"
  return 1
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

# C6 — an island switch reaches the screen within two frames of the key that
# asked for it, under C2's load (PHASE13 P13.2). Measured to the vblank that
# showed it, by undertow; it gates the build as C1 does.
phase "C6: an island switch within two frames"
sh "$root/abyss/tests/bench-islands.sh"

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
  quiet "$root/abyss/tests/live-notify.sh"
  # The clipboard: an empty one says so, and a copy with no input behind it is
  # refused by name (PHASE9 P9.1). Against undertow, because undertow's own
  # handling is the thing under test.
  phase "the clipboard"
  quiet "$root/abyss/tests/live-clipboard.sh"
  # And the same protocol with a grab on it: a file pressed in one process and
  # released on the Trash in another, plus the two other targets the shell
  # draws (PHASE9 P9.3). Every claim is checked on disk.
  phase "drag and drop"
  quiet "$root/abyss/tests/live-dnd.sh"
  # What a window may ask about itself: moved by its title bar, zoomed to the
  # usable area (not the output), resized from a corner that stays anchored,
  # snapped to an edge, and put in the Dock and taken back out (P9.4).
  phase "window management"
  quiet "$root/abyss/tests/live-window.sh"
  # Islands (PHASE13 P13.1): a display shows one island; the others' windows
  # are not drawn and are suspended; the keys of §6.4; Cmd-Tab goes there.
  echo "== islands =="
  quiet "$root/abyss/tests/live-islands.sh"
  # The slide (P13.3): decoration after the commit — keys at once, re-targeted,
  # never queued, skippable.
  echo "== the island slide =="
  quiet "$root/abyss/tests/live-islandslide.sh"
  # Islands in the menu bar and the Dock (P13.4): where you are, every
  # island's windows, and a Dock click that goes to a window's island.
  echo "== islands in the bar and the Dock =="
  quiet "$root/abyss/tests/live-islands-bar.sh"
  # Ebb (P13.5): every window of a scope in its own slot, one click to pick,
  # and Escape leaves the screen exactly as it was.
  echo "== Ebb =="
  quiet "$root/abyss/tests/live-ebb.sh"
  # Shoals (P13.6): explicit working sets, recalled where they were left,
  # nothing else moved; the strip; the bar; kept across a restart.
  echo "== Shoals =="
  quiet "$root/abyss/tests/live-shoals.sh"
  # And the keys the desktop hears first: a bound one never reaches the focused
  # client, an unbound one always does, and an application may keep a
  # combination for itself (P9.5, and §6.2's decision made into data).
  echo "== keybinds =="
  quiet "$root/abyss/tests/live-keys.sh"
  # The installer's keyboard choice is the medium's at once (T.2): chosen
  # German, the same keys type "zebra" where they typed "yebra".
  echo "== the installer's keyboard, on the medium =="
  quiet "$root/abyss/tests/live-installer-keyboard.sh"
  # And a window that never heard of this desktop, wearing its frame: the
  # compositor answers xdg-decoration server-side and paints an Aqua title bar
  # around somebody else's surface (P9.6).
  echo "== server-side decorations =="
  quiet "$root/abyss/tests/live-decorations.sh"
  # The depth gadget, the one window operation Phase 11 adds: lowered from a
  # frame undertow drew, and from an Aqua window's own chrome over
  # abyss_window_manager_v1 — both laid out by one function (P11.6).
  echo "== depth =="
  quiet "$root/abyss/tests/live-depth.sh"
  # A window made of subsurfaces — one over its parent and desynchronised,
  # one outside it, one placed below it — drawn, framed and routed to the
  # leaf under the pointer. undertow advertised the global from Phase 6 and
  # did none of it (U.1; API-STUDY §1.3).
  echo "== subsurfaces =="
  quiet "$root/abyss/tests/live-subsurface.sh"
  # A minimized window keeps a slow frame clock instead of none — a FIFO
  # client hangs without one — and is told it is suspended, and what this
  # compositor can do (U.2; xdg-shell v6).
  echo "== a hidden window's clock =="
  quiet "$root/abyss/tests/live-hidden.sh"
  # The client half (T.3): an Aqua window binds xdg-shell v6 — told what is
  # served, kept within bounds, and drawing nothing while suspended.
  echo "== an Aqua window, suspended =="
  quiet "$root/abyss/tests/live-suspend.sh"
  # GPU clients through linux-dmabuf: pixman says plainly it offers none;
  # on a render node a GL and a Vulkan client run on it and are seen
  # moving, and a screenshot on every renderer here is the right colour.
  # The GPU half skips, loudly, where there is no render node (U.3).
  echo "== GPU clients =="
  quiet "$root/abyss/tests/live-gpu.sh"
  # presentation-time: every frame a client commits is reported shown, on
  # CLOCK_MONOTONIC, at the display's period — 60 Hz and 144 Hz (U.4).
  echo "== presentation time =="
  quiet "$root/abyss/tests/live-present.sh"
  # System Preferences as an application (PHASE14 P14.1): pointer, keyboard
  # and its menu vocabulary, on our own compositor.
  # The theme changes while the desktop runs (PHASE14 P14.2): every process
  # that draws follows appearance.ini, and back again byte for byte.
  echo "== appearance, live =="
  quiet "$root/abyss/tests/live-appearance.sh"
  # System Preferences' privileged half (PHASE14 P14.3): who may change the
  # machine, check, dry run, the Linux refusal — and on FreeBSD, as root, a
  # real sysrc write to a scratch rc.conf.
  echo "== the settings helper =="
  quiet "$root/abyss/tests/live-settings.sh"
  # The session's authenticator (PHASE16 P16.1): as root, against the PAM
  # stack the medium ships, each account asking about itself (Linux: refuses).
  echo "== the authenticator =="
  quiet "$root/abyss/tests/live-authenticator.sh"
  # The daemon's VT switch on real vt(4), to VTs nobody holds (found on the
  # 12700KF): the session tests record their switches; this makes them.
  echo "== switching to a VT nobody holds =="
  quiet "$root/abyss/tests/live-vtactivate.sh"
  # The session lock in undertow (PHASE16 P16.2a): nothing of the desktop
  # shown or reachable, no grab survives it, and a dead lock client keeps it.
  echo "== the session lock =="
  quiet "$root/abyss/tests/live-sessionlock.sh"
  # A VT switched away and back (found on the 12700KF): wlroots destroys every
  # output and announces them again; undertow keeps the session and the lock.
  echo "== a VT switched away and back =="
  quiet "$root/abyss/tests/live-vtswitch.sh"
  # The Aqua lock screen (P16.2b), against a stand-in authenticator: it
  # shakes, waits, unlocks only on a yes, and fails closed.
  echo "== the lock screen =="
  quiet "$root/abyss/tests/live-lockscreen.sh"
  # Locking a real session (P16.2c): abyssctl, ⌃⌘Q and the menu, anchor
  # restarting a lock screen that died, and no application offered the lock.
  echo "== locking the session =="
  quiet "$root/abyss/tests/live-locksession.sh"
  # The idle policy (P16.3): idleness locks and asks the machine to sleep,
  # as energy.ini says; an inhibitor or input holds it off.
  echo "== the idle policy =="
  quiet "$root/abyss/tests/live-idlepolicy.sh"
  # Sleep, restart and shut down through the daemon (P16.4a): the machine
  # sleeps only with every session locked, whoever asks.
  echo "== power =="
  quiet "$root/abyss/tests/live-power.sh"
  # The login window (P16.5a): it lists, asks about the named account, and
  # cannot be used to learn which names are accounts.
  echo "== the login window =="
  quiet "$root/abyss/tests/live-loginwindow.sh"
  # Sessions (P16.5b): the login window, a session for whoever logs in, the
  # window again on Log Out (unprivileged; the root half is live-authenticator's).
  echo "== sessions =="
  quiet "$root/abyss/tests/live-greeter.sh"
  # Fast user switching (P16.6b): two sessions side by side, each locked
  # behind the window, back to one with no password at the window.
  echo "== fast user switching =="
  quiet "$root/abyss/tests/live-switchuser.sh"
  # The Setup Assistant (P16.7): once at a first login, then never.
  echo "== the Setup Assistant =="
  quiet "$root/abyss/tests/live-setup.sh"
  # Accounts (P16.6a): through the settings helper, against a scratch root,
  # and through the Accounts pane, clicked and typed.
  echo "== accounts =="
  quiet "$root/abyss/tests/live-accounts.sh"
  # System Profiler: fastfetch's report, read against the machine.
  echo "== System Profiler =="
  quiet "$root/abyss/tests/live-systemprofiler.sh"
  echo "== the Accounts pane =="
  quiet "$root/abyss/tests/live-accounts-pane.sh"
  echo "== System Preferences =="
  quiet "$root/abyss/tests/live-prefs.sh"
  # The Network pane (P14.4c): the kernel's status, rc.conf's configuration
  # through the helper, typed and applied — write-only in the guest, whose
  # network is how the test reaches it.
  echo "== the Network pane =="
  quiet "$root/abyss/tests/live-network-pane.sh"
  # The Sound pane (P14.6c): levels and mute set on the guest's snd_dummy and
  # read back by mixer(8), players shown, outside changes followed.
  echo "== the Sound pane =="
  quiet "$root/abyss/tests/live-sound-pane.sh"
  # The menu bar's volume item (P14.6d): real on the guest's snd_dummy —
  # follows mixer(8), shows mute, and its slider sets vol; absent on Linux.
  echo "== the volume item =="
  quiet "$root/abyss/tests/live-menubar-volume.sh"
  # Several outputs (P14.7a): three headless displays with gaps and negative
  # coordinates; a window dragged across and drawn there; every contract kept.
  echo "== several displays =="
  quiet "$root/abyss/tests/live-displays.sh"
  # And rearranged by protocol (P14.7b): wlr-output-management-v1, tested,
  # refused, applied at a new mode and scale 2, kept in displays.ini.
  echo "== displays, rearranged =="
  quiet "$root/abyss/tests/live-displays-config.sh"
  # And the pane (P14.7c): dragged, scaled, and following the compositor.
  echo "== the Displays pane =="
  quiet "$root/abyss/tests/live-displays-pane.sh"
  # Which outputs a surface is on (U.10): a window dragged onto a scale-2
  # display is told so, redraws at 2x, and returns to 1x when it leaves.
  echo "== a surface's outputs =="
  quiet "$root/abyss/tests/live-surface-enter.sh"
  # An input method (U.5): text-input-v3 and input-method-v2 relayed, so an
  # IME composes 日本語 into another toolkit's field (zenity's GTK entry).
  echo "== an input method =="
  quiet "$root/abyss/tests/live-ime.sh"
  # The pointer locked and confined (U.6): relative-pointer deltas, a lock
  # that holds only for the focused window, its cursor hint, a confinement.
  echo "== the pointer, locked and confined =="
  quiet "$root/abyss/tests/live-lock.sh"
  # The pointer's picture (U.7): the theme's arrow in a capture, sizing arrows
  # on the frame, a client's shape, surface or none — only with the pointer.
  echo "== the pointer's picture =="
  quiet "$root/abyss/tests/live-cursor.sh"
  # Our cursors as an XCursor theme (U.7b): written, loaded by
  # libwayland-cursor, the same pixels as undertow's, named by the session.
  echo "== our cursors, as an XCursor theme =="
  quiet "$root/abyss/tests/live-xcursor.sh"
  # A buffer cropped, turned and scaled (U.8): viewporter's source crop and
  # destination, a buffer transform, fractional-scale drawn pixel for pixel.
  echo "== a buffer, cropped, turned and scaled =="
  quiet "$root/abyss/tests/live-viewport.sh"
  # Idle (U.9): the displays sleep after energy.ini's delay and wake on input,
  # an idle inhibitor on a visible window holds them, ext-idle-notify agrees;
  # and the primary selection pastes into the next window focused.
  echo "== idle, and the primary selection =="
  quiet "$root/abyss/tests/live-idle.sh"
  # Explicit sync (U.3b): not offered on pixman, and why; on every GPU,
  # offered, used by vkcube, and kept — acquire waits, releases armed.
  echo "== explicit sync =="
  quiet "$root/abyss/tests/live-syncobj.sh"
  # Energy Saver (P14.8): sleep delays kept in energy.ini, the display never
  # later than the computer; powerd through a write-only helper in the guest.
  echo "== Energy Saver =="
  quiet "$root/abyss/tests/live-energy-pane.sh"
  # Every installed port as an application (PHASE15 P15.1): desktop entries to
  # bundles, the ones that are not applications skipped with why, only our own
  # bundles replaced or removed, and a generated launcher mapping its window —
  # galculator's real one too, where it is installed.
  echo "== the installed ports, as applications =="
  quiet "$root/abyss/tests/live-appgen.sh"
  # The Dock carries them (P15.2): dock.ini pins a bundle by name, its tile
  # launches it, and the running window is matched back to the tile through the
  # bundle's app-ids — pinned or not; Keep, Remove and a bundle dragged out of
  # the Finder edit dock.ini, and a document dropped on a tile opens with it.
  echo "== the Dock carries installed applications =="
  quiet "$root/abyss/tests/live-dock-apps.sh"
  # The browser (P15.3): Firefox through its generated bundle, on undertow, its
  # page on screen, and its file chooser the Finder through our portal. Skips
  # where there is no Firefox.
  echo "== the browser =="
  quiet "$root/abyss/tests/live-firefox.sh"
  # And on the medium (P15.3b): in a chroot of `live-image.sh --keep`'s staging
  # root, Firefox renders from the medium's own tree, with what it dlopens
  # loaded. Skips without a staged medium.
  echo "== the browser, on the medium =="
  quiet "$root/abyss/tests/live-medium-browser.sh"
  # Terminal's model (P15.4a): a shell, vi and top on a real pty, through the
  # VT parser and the screen, asserted on with no display — and vi's edit on disk.
  echo "== programs on a pty =="
  quiet "$root/abyss/tests/live-vt.sh"
  # Terminal (P15.4b–c): a shell in a window on undertow — typed and drawn,
  # Ctrl-C, vi with arrow keys, zoom resizing the shell, the scrollback, a
  # wrapped line copied and pasted into another Terminal process intact,
  # Clear Scrollback, ⌘N, exit.
  echo "== Terminal =="
  quiet "$root/abyss/tests/live-terminal.sh"
  # TextEdit (P15.5): a file opened, edited with the virtual keyboard, saved,
  # its bytes read back; undo, find, Open and Save As through the portal and
  # the Finder, the save sheet on close, and the Finder opening a .txt in it.
  echo "== TextEdit =="
  quiet "$root/abyss/tests/live-textedit.sh"
  # Grab (P15.6): a selection and a window (undertow's window_at) captured,
  # saved through the portal, their pixels compared with the screen's; Screen,
  # Escape (an exclusive overlay's keyboard), Timed Screen.
  echo "== Grab =="
  quiet "$root/abyss/tests/live-grab.sh"
  # Activity Monitor (P15.7): processes started by the test, filtered, quit
  # and force quit from the window, and gone; another user's through the
  # root helper (dry run, FreeBSD).
  echo "== Activity Monitor =="
  quiet "$root/abyss/tests/live-activity.sh"
  # Disk Utility (P15.8): a scratch dataset snapshotted, changed, rolled back,
  # unmounted and mounted through the root helper (FreeBSD with ZFS).
  echo "== Disk Utility =="
  quiet "$root/abyss/tests/live-diskutility.sh"
  # The Wi-Fi lab (P14.5): wtap with station/AP modes and our teardown fixes;
  # three WPA2 joins, and the kernel still on the same boot. FreeBSD only.
  echo "== the Wi-Fi lab =="
  quiet "$root/abyss/tests/live-wifi-lab.sh"
  # Joining through the helper (P14.5b): scan, a wrong key, the right one by
  # rc's own netif path, kept without the passphrase, forgotten. The guest's
  # real rc.conf and wpa_supplicant.conf, backed up and restored.
  echo "== Wi-Fi, joined =="
  quiet "$root/abyss/tests/live-wifi.sh"
  # And on the Network pane (P14.5c): scan, choose, type, join, forget — and
  # the passphrase in nothing anyone wrote down.
  echo "== Wi-Fi on the Network pane =="
  quiet "$root/abyss/tests/live-wifi-pane.sh"
  # An application's vocabulary, asked by something that cannot draw a menu:
  # abyssmenu describes the Finder, is refused with reasons, and invokes verbs
  # whose results are checked on disk; a picker publishes nothing (P10.2).
  echo "== the vocabulary =="
  quiet "$root/abyss/tests/live-vocabulary.sh"
  # And the compositor's half: a window publishes where its menus are, and
  # only a client on the privileged socket is told who is frontmost (P10.3).
  echo "== whose menus are whose =="
  quiet "$root/abyss/tests/live-menu-focus.sh"
  # And the bar made real: the frontmost application's menus, drawn by our
  # own compositor (popups, at last), enabled as the app says as each menu
  # opens, chosen by pointer and by keyboard, checked on disk (P10.4).
  echo "== the menu bar =="
  quiet "$root/abyss/tests/live-menus.sh"
  # Undo, decided: per window, a verb like any other, titled from the stack,
  # pushed to the bar, and never a delete (P10.5).
  echo "== undo =="
  quiet "$root/abyss/tests/live-undo.sh"
  # A GTK application's menus in our bar: gtk_shell1 in undertow, the bridge
  # in abyss-dbus --menus, and the other end a stock GtkApplication (P10.6).
  echo "== GTK's menus in our bar =="
  quiet "$root/abyss/tests/live-menus-gtk.sh"
  # Submenus open (P10.8): a GTK app's File ▸ Export ▸ More ▸, by pointer and
  # keyboard, through undertow; the chain closed children first.
  echo "== submenus =="
  quiet "$root/abyss/tests/live-submenus.sh"
  # The menus the desktop owns: right-click menus built from the menu bar's
  # commands, and a system menu whose items do what they say (P10.8).
  echo "== the desktop's own menus =="
  quiet "$root/abyss/tests/live-context.sh"
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

  # And on the machine it installed: a manual address, set as its
  # administrator through the settings helper, held across a reboot (PHASE14
  # P14.4's gate). Needs the disk live-desktop.sh just installed.
    phase "a manual address survives a reboot"
    sh "$root/abyss/tests/live-network-reboot.sh"
  else
    # **Named, timed, and told how to run.** These two are the only tests in the
    # tree that put an operating system on a disk and boot it; skipping them
    # quietly would leave the suite green about a claim it never checked.
    phase "the nested installs — SKIPPED (--full runs them)"
    echo "   the installer, and what it installed   (~190s)"
    echo "   empty disk to Jaguar desktop           (~490s)"
    echo "   a manual address survives a reboot     (~150s)"
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
