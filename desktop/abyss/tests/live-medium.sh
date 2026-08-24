#!/bin/sh
# AbyssBSD Swift DE — the live medium boots into the Jaguar desktop
# (PHASE5.md P5.3).
#
# The claim:
#
#     A machine that has never built any of this, booted from an image we
#     assembled out of distribution sets, comes up running our compositor with
#     the Aqua installer composited on it.
#
# (P5.3 asserted the *desktop* here — wallpaper, menu bar and Dock. P5.5 changed
# what the medium runs, which is the point of a medium: a live installer that
# boots to a Dock is a live installer nobody asked for. The desktop is still
# what gets INSTALLED, and `live-desktop.sh` checks that on the far side.)
#
# Three steps, each proving something the one before cannot:
#
#   1. BUILD  — `abyss/mk/live-image.sh` assembles the medium with base tools
#               only: no `make release`, no source tree, no world build.
#   2. BOOT   — nested bhyve, and the medium reports on itself over the console,
#               which is the only channel a headless live system has.
#   3. LOOK   — the medium's root is mounted afterwards and the frame it captured
#               is probed, PIXEL BY PIXEL. "Two surfaces mapped" is a claim about
#               bookkeeping; a pale panel in the middle of the screen with the
#               wallpaper behind it is a claim about the picture.
#
# On Linux this is a positive control, like `live-install.sh`: the builder must
# refuse and say why. `makefs`, `mkimg` and the whole arrangement are FreeBSD.
#
# **What this does NOT yet prove:** the keyboard layouts the medium carries. A
# headless session with no input device never compiles a keymap, so removing
# them leaves every assertion below green — measured, not assumed. P5.4 types
# into the installer, and that is the pass that will exercise them.
#
# Usage: abyss/tests/live-medium.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

W=1024
H=768

fail() { echo "FAIL: $1"; exit 1; }

# --------------------------------------------------------------- not FreeBSD
if [ "$(uname -s)" != FreeBSD ]; then
  echo "== $(uname -s): the medium is built on FreeBSD, and the builder must say so =="
  if out=$(sh "$root/abyss/mk/live-image.sh" --out /tmp/should-not-exist.img 2>&1); then
    fail "the image builder claimed to work on $(uname -s)"
  fi
  echo "$out" | grep -q "FreeBSD" || fail "the refusal does not name the platform: $out"
  echo "$out" | grep -qE "makefs|mkimg" \
    || fail "the refusal does not name the tools it needs: $out"
  [ ! -f /tmp/should-not-exist.img ] || fail "it refused and produced an image anyway"
  echo "ok: refused, and named the tools it would have needed:"
  echo "    $out"
  echo "all green (the medium is built where it can be built)."
  exit 0
fi

# ------------------------------------------------------------------ FreeBSD
uefi=/usr/local/share/uefi-firmware/BHYVE_UEFI.fd
dist="${ABYSS_DIST_DIR:-/home/$(id -un)/dist}"
img="${ABYSS_LIVE_IMG:-/home/$(id -un)/abyss-live.img}"

command -v bhyve >/dev/null || fail "bhyve is not installed"
[ -f "$uefi" ] || { echo "SKIP: no bhyve UEFI firmware ($uefi) — pkg install edk2-bhyve"; exit 0; }
[ -s "$dist/base.txz" ] || { echo "SKIP: no distribution sets in $dist"; exit 0; }
sudo -n true 2>/dev/null || { echo "SKIP: this needs passwordless sudo"; exit 0; }

work=$(mktemp -d /tmp/abyss-medium.XXXXXX)
cleanup() {
  sudo umount "$work/mnt" 2>/dev/null || true
  [ -n "${md:-}" ] && sudo mdconfig -d -u "${md#md}" 2>/dev/null || true
  sudo bhyvectl --destroy --vm=abyssmedium >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# ------------------------------------------------------------------- 1. build
echo "== building the medium =="
sh "$root/abyss/mk/live-image.sh" --out "$img" --dist "$dist" > "$work/build" 2>&1 \
  || { sed 's/^/    /' "$work/build"; fail "the image could not be built"; }
sed -n 's/^== /    /p' "$work/build"
closure=$(sed -n 's/^ *\([0-9]*\) shared objects.*/\1/p' "$work/build")
[ -n "$closure" ] && [ "$closure" -gt 20 ] \
  || fail "the runtime closure came out at '$closure' objects, which cannot be right"
echo "ok: $closure shared objects carried, computed from the binaries that need them"

# The graphics stack is packages, not a closure — nothing we link mentions a
# kernel module, so `ldd` will never find one (PHASE4 P4.3).
mods=$(sed -n 's/^ *[0-9]* package(s), \([0-9]*\) kernel modules.*/\1/p' "$work/build")
[ -n "$mods" ] && [ "$mods" -gt 20 ] \
  || { grep -i warning "$work/build" | sed 's/^/    /'
       fail "the medium carries $mods kernel modules; it needs the drm stack and SI firmware"; }
echo "ok: $mods kernel modules carried — the driver and the firmware for it"

# ------------------------------------------------------------------- 2. boot
echo "== booting it, nested =="
sudo kldload nmdm 2>/dev/null || true
sudo bhyvectl --destroy --vm=abyssmedium >/dev/null 2>&1 || true
sudo timeout 240 bhyve -c 2 -m 2G -A -H -P -l com1,stdio \
  -l bootrom,"$uefi" \
  -s 0,hostbridge -s 31,lpc -s 4,virtio-blk,"$img" \
  abyssmedium < /dev/null > "$work/boot.log" 2>&1 || true
sudo bhyvectl --destroy --vm=abyssmedium >/dev/null 2>&1 || true

grep -q "AbyssBSD live medium" "$work/boot.log" \
  || { tail -20 "$work/boot.log" | sed 's/^/    /'
       fail "this is not our medium — the marker never appeared"; }
grep -q "abyss-live: session exited 0" "$work/boot.log" \
  || { grep "abyss-live" "$work/boot.log" | tail -15 | sed 's/^/    /'
       fail "the desktop did not come up on the medium"; }
echo "ok: it is our medium, and the session came up on it"

# The wallpaper is a layer surface; the installer is an ordinary window. Both
# have to be there — a backdrop with no installer is a very expensive desktop
# picture, and an installer with no backdrop means the wallpaper client died.
grep -q "mapped .*\[abyss.wallpaper\]" "$work/boot.log" \
  || fail "the wallpaper never mapped on the medium"
grep -q "mapped org.abyssbsd.aquademo" "$work/boot.log" \
  || fail "the installer's window never mapped on the medium"
echo "ok: the wallpaper and the Aqua installer both composited — from a build tree"

# ---------------------------------------------------- the graphics stack (P4.3)
#
# What can be checked here is checked; what cannot is PHASE4 §5's checklist.
# Nothing in this VM has an AMD GPU, so "does `si_support` bind" is not a
# question a test can ask — but "does the medium carry the driver, the firmware,
# and the knob" is, and a medium that reaches the Mac Pro without them wastes a
# boot cycle that costs a person's afternoon.
grep -q "amdgpu kernel modesetting enabled" "$work/boot.log" \
  || fail "the medium did not load amdgpu — it would come up blank on real hardware"
grep -q "Starting seatd" "$work/boot.log" \
  || fail "seatd did not start, so an unprivileged session cannot take DRM master"
echo "ok: amdgpu loaded and seatd is running — on a machine with no GPU at all"

# The backend is chosen from what the machine has, not from what somebody
# remembered to pass. Here there is no /dev/dri, so it must choose headless —
# and it must SAY which, because on metal that line is the first thing worth
# reading.
grep -q "abyss-session: headless backend" "$work/boot.log" \
  || { grep -o "abyss-session:.*" "$work/boot.log" | head -1 | sed 's/^/    /'
       fail "the session did not choose the headless backend on a machine with no display"; }
echo "ok: it chose the headless backend, and said so"

# And the privileged half is there, and belongs to the unprivileged session:
# the disk spoke is empty until it answers, and root would be refused (§4.4).
grep -q "the installer service is up, for uid" "$work/boot.log" \
  || fail "the medium has no installer service, so its disk spoke is empty"
grep -q "AquaDemo: installer is up" "$work/boot.log" \
  || fail "the installer never reported what the machine has"
echo "ok: $(sed -n 's/.*\(AquaDemo: installer is up.*\)/\1/p' "$work/boot.log" | head -1)"

# **The medium has its fonts.** This assertion exists because its absence was
# found the hard way: a medium built with no fonts at all passed every other
# check in this file — three layers composited, the menu bar pale at the top,
# the wallpaper underneath, the Dock over it. `Aqua.Text` falls back to toy text
# silently, which is right for a missing italic and wrong for a machine that has
# lost every glyph, and pixels cannot tell the two apart (25 dark pixels in the
# menu bar versus 15 — measured, and far too close to assert on). So the desktop
# now says which it got, and this reads it.
grep -q "Text: NO FONTS" "$work/boot.log" \
  && fail "the medium has no fonts — the desktop came up and you could not read it"
grep -qE "Text: [1-9][0-9]* face" "$work/boot.log" \
  || fail "the desktop never said what its text stack got"
echo "ok: $(grep -o 'Text: .*' "$work/boot.log" | head -1) — it can be read, not just seen"

# No bus on the medium, and the session says so rather than silently lacking a
# file chooser (P8.4's design, exercised here for real).
grep -q "no dbus-daemon" "$work/boot.log" \
  || fail "the medium carries no dbus-daemon but the session did not say so"
echo "ok: no session bus on the medium, and it said so instead of pretending"

# ------------------------------------------------------------------- 3. look
echo "== what it actually drew =="
md=$(sudo mdconfig -a -t vnode -f "$img")
mkdir -p "$work/mnt"
sudo mount "/dev/${md}p3" "$work/mnt"

# The one knob that decides whether a Mac Pro shows a picture, and the one thing
# about it a VM can check: that it is written down. Southern Islands is off by
# default in amdgpu — without this the FirePros are not claimed at all, which
# looks like a missing driver and is a default (PHASE4 §6.2).
sudo grep -q 'amdgpu_si_support="1"' "$work/mnt/boot/loader.conf" \
  || fail "the medium does not ask amdgpu for Southern Islands — the Mac Pro's GPUs"
sudo test -s "$work/mnt/boot/modules/amdgpu.ko" \
  || fail "the medium has no amdgpu.ko"
sudo test -s "$work/mnt/boot/modules/amdgpu_pitcairn_pfp_bin.ko" \
  || fail "the medium has no Pitcairn firmware — that is the FirePro D300"
sudo test -s "$work/mnt/usr/local/bin/seatd" || fail "the medium has no seatd"
echo "ok: amdgpu, Southern Islands firmware, seatd, and si_support asked for"

ppm="$work/frame.ppm"
sudo cp "$work/mnt/var/log/abyss-live.ppm" "$ppm" 2>/dev/null \
  || fail "the medium captured no frame"
sudo chown "$(id -un)" "$ppm"
sudo umount "$work/mnt"
sudo mdconfig -d -u "${md#md}"
md=""

head -c 2 "$ppm" | grep -q P6 || fail "the capture is not a P6 netpbm"
size=$(stat -f %z "$ppm")
[ "$size" -gt 100000 ] || fail "the captured frame is only $size bytes"

hdr_len=$(printf 'P6\n%s %s\n255\n' "$W" "$H" | wc -c | tr -d ' ')
pixel() {
  off=$((hdr_len + ((($2 * W) + $1) * 3)))
  dd if="$ppm" bs=1 skip="$off" count=3 2>/dev/null | od -An -v -tu1 | awk '{print $1, $2, $3}'
}
lightness() { echo "$1" | awk '{print int(($1 + $2 + $3) / 3)}'; }

# The middle of the screen is the installer's panel: pale Aqua chrome, and
# emphatically not undertow's fallback blue, which is what an output with
# nothing composited on it looks like.
panel=$(pixel $((W / 2)) $((H / 2)))
[ "$panel" != "61 102 161" ] \
  || fail "the middle of the frame is bare output — nothing was drawn on it"
[ "$(lightness "$panel")" -gt 150 ] \
  || fail "the installer's panel is not in the middle of the frame ($panel)"
echo "ok: the installer's panel is drawn in the middle ($panel)"

# ...and the wallpaper is behind it, in the corner the window does not cover.
desk=$(pixel 60 60)
[ "$desk" != "61 102 161" ] \
  || fail "the desktop is undertow's fallback blue — the wallpaper never composited"
[ "$desk" != "$panel" ] || fail "the backdrop and the panel are the same colour"
echo "ok: the wallpaper is behind it, not the compositor's fallback ($desk)"

echo "all green (a machine booted from our medium ran our desktop, and drew it)."
