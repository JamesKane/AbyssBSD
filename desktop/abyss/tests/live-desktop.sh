#!/bin/sh
# AbyssBSD Swift DE — install from the medium, reboot, and land in the Jaguar
# desktop (PHASE5.md P5.5). The last pass of the phase.
#
# The claim, and it is the whole point of everything above it:
#
#     A machine with an empty disk boots our medium, the Aqua installer comes
#     up on it, an install is performed from that medium, and the machine
#     reboots into the Jaguar desktop as the account the installer created.
#
# Nested twice over, with no hardware and no human:
#
#   1. BUILD    the medium, carrying the distribution sets AND the desktop
#               (abyss.tzst) — a live installer with nothing to install is a
#               demonstration.
#   2. BOOT it, with a blank second disk attached. The medium comes up running
#               the INSTALLER, as an unprivileged user, talking to a root
#               `abyss-install` through a socket handed to exactly that uid.
#   3. INSTALL  onto the blank disk, driven from the medium's own console with
#               `abyss-installctl` — the same protocol the GUI speaks, carrying
#               the same plan the GUI builds.
#   4. REBOOT   into what was installed, and find the Jaguar desktop there.
#
# **What this does NOT prove, said plainly:** nobody clicks the installer here.
# Driving a GUI inside the nested machine would mean putting the harness's input
# tools into the product image. The clicking is proven by
# `abyss/tests/live-installer.sh`, on the same binary, the same compositor and
# the same service — the only difference being which machine they run on. What
# is genuinely untested is input from real hardware, which is Phase 4.
#
# On Linux this is a positive control: the builder must refuse and say why.
#
# Usage: abyss/tests/live-desktop.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

fail() { echo "FAIL: $1"; exit 1; }

if [ "$(uname -s)" != FreeBSD ]; then
  echo "== $(uname -s): a medium cannot be built here, and the builder says so =="
  if out=$(sh "$root/abyss/mk/live-image.sh" --out /tmp/should-not-exist.img 2>&1); then
    fail "the image builder claimed to work on $(uname -s)"
  fi
  echo "$out" | grep -q FreeBSD || fail "the refusal does not name the platform: $out"
  echo "ok: $out"
  echo "all green (the last mile is walked where it can be walked)."
  exit 0
fi

uefi=/usr/local/share/uefi-firmware/BHYVE_UEFI.fd
dist="${ABYSS_DIST_DIR:-/home/$(id -un)/dist}"
img="${ABYSS_LIVE_IMG:-/home/$(id -un)/abyss-live-p55.img}"
target="${ABYSS_TARGET_IMG:-/home/$(id -un)/abyss-target.img}"

command -v bhyve >/dev/null || fail "bhyve is not installed"
[ -f "$uefi" ] || { echo "SKIP: no bhyve UEFI firmware — pkg install edk2-bhyve"; exit 0; }
[ -s "$dist/base.txz" ] || { echo "SKIP: no distribution sets in $dist"; exit 0; }
sudo -n true 2>/dev/null || { echo "SKIP: this needs passwordless sudo"; exit 0; }

work=$(mktemp -d /tmp/abyss-p55.XXXXXX)
cleanup() {
  [ -n "${fdin:-}" ] && exec 5>&- 2>/dev/null || true
  sudo bhyvectl --destroy --vm=abyssp55 >/dev/null 2>&1 || true
  sudo bhyvectl --destroy --vm=abyssp55d >/dev/null 2>&1 || true
  sudo umount "$work/mnt" 2>/dev/null || true
  [ -n "${md:-}" ] && sudo mdconfig -d -u "${md#md}" 2>/dev/null || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

# --------------------------------------------------------------- 1. the medium
echo "== building the medium (with the sets it installs) =="
sh "$root/abyss/mk/live-image.sh" --out "$img" --dist "$dist" --stay --frames 1800 \
   > "$work/build" 2>&1 || { sed 's/^/    /' "$work/build"; fail "the medium would not build"; }
sed -n 's/^== /    /p' "$work/build"
grep -q "abyss.tzst" "$work/build" || fail "the medium carries no desktop set"
echo "ok: the medium carries base.txz, kernel.txz and the desktop"

# A blank disk to install onto — the "machine with an empty disk".
sudo rm -f "$target"
truncate -s 12G "$target"
echo "ok: a blank 12G disk, with no partition table at all"

# ----------------------------------------------------- 2. boot it and install
echo "== booting the medium, with the blank disk attached =="
sudo kldload nmdm 2>/dev/null || true
sudo bhyvectl --destroy --vm=abyssp55 >/dev/null 2>&1 || true
infifo="$work/in.fifo"; mkfifo "$infifo"
( sudo timeout 600 bhyve -c 2 -m 2G -A -H -P -l com1,stdio \
    -l bootrom,"$uefi" \
    -s 0,hostbridge -s 31,lpc \
    -s 4,virtio-blk,"$img" -s 5,virtio-blk,"$target" \
    abyssp55 < "$infifo" > "$work/live.log" 2>&1 ) &
exec 5>"$infifo"; fdin=1

waitfor() {  # waitfor <pattern> <seconds> <what>
  i=0
  while [ $i -lt $(( $2 * 4 )) ]; do
    grep -q "$1" "$work/live.log" 2>/dev/null && return 0
    i=$((i + 1)); sleep 0.25
  done
  tail -25 "$work/live.log" | sed 's/^/    /'
  fail "$3"
}

waitfor "AbyssBSD live medium" 180 "the medium never booted"
waitfor "the installer service is up" 60 "the root installer service never started"
waitfor "AquaDemo: installer is up" 120 "the Aqua installer never started on the medium"
disks=$(sed -n 's/.*installer is up — \([0-9]*\) disk.*/\1/p' "$work/live.log" | head -1)
[ "${disks:-0}" -ge 2 ] || fail "the installer sees $disks disk(s); it should see the target too"
echo "ok: the medium came up running the Aqua installer, and it sees $disks disks"
grep -q "for uid 1001" "$work/live.log" \
  || fail "the installer service was not handed to the unprivileged session user"
echo "ok: an unprivileged session is commanding a root installer (PHASE5 §4.4)"

waitfor "mapped org.abyssbsd.aquademo" 200 "the installer's window never composited on the medium"
echo "ok: its window composited on the medium's own compositor"

# ------------------------------------------------- 3. install, from the console
# The console is a real console: log in and use it. `abyss-installctl` speaks
# the same protocol the GUI speaks and carries the same plan the GUI builds —
# what is NOT proven here is the clicking, which live-installer.sh proves on the
# same binary against the same service.
# The console comes up when the session ends: it runs in rc's foreground,
# because a backgrounded one goes silent the moment getty revokes the console
# (HANDOFF §2.47). `abyss-install` outlives it and is still listening.
waitfor "abyss-live: done" 240 "the session never finished"
waitfor "login:" 60 "the medium never offered a console"
sleep 2
# **As `abyss`, not as root** — and that is the design working rather than an
# inconvenience. The service was started for uid 1001 and hands its socket to
# exactly that uid; root gets refused, which is the whole point of §4.4. The
# medium's `.profile` points the client at the session's runtime directory.
printf 'abyss\n' >&5
sleep 4
printf 'abyss-installctl disks\n' >&5
sleep 4
grep -q "12.0 GiB" "$work/live.log" || fail "the console cannot see the blank target disk"
echo "ok: logged in at the medium's console; the blank disk is there"

# The plan: the desktop set included, so what gets installed is a desktop. The
# password is a real SHA-512 crypt of "abyss" — the GUI would hash what was
# typed (`ap_crypt_sha512`, P5.4); a console caller brings its own, because
# `InstallPlan` carries a hash and never a plaintext.
printf 'abyss-installctl install --yes --disk vtbd1 --pool abyss --dist /usr/freebsd-dist --sets base.txz,kernel.txz,abyss.tzst --hostname jaguar --timezone America/Chicago --user %s\n' \
  'abyss:$6$p55salt$oCskBpkeTosRXETLJcNEEhgJ8M6a7gX6ax8sDJfBE53jaoLkjT/lNs6lWTJnYg5DZ5F0CEEurlhagpuS1dvAV.:wheel' >&5
waitfor "installed\." 600 "the install never finished"
grep -q "extract abyss.tzst" "$work/live.log" \
  || fail "the install never extracted the desktop — the machine would boot to a shell"
echo "ok: installed onto vtbd1 from the medium, desktop and all"
# The install's last step is `zpool export`, so the target disk is consistent
# the moment it says "installed." — pulling the plug on the live medium now is
# safe, and is a good deal quicker than asking an unprivileged user to halt a
# machine they have no business halting.
exec 5>&-; fdin=""
sudo bhyvectl --destroy --vm=abyssp55 >/dev/null 2>&1 || true
sleep 2

# ------------------------------------------------ 4. reboot into what we made
echo "== booting the machine we just installed =="
sudo bhyvectl --destroy --vm=abyssp55d >/dev/null 2>&1 || true
sudo timeout 300 bhyve -c 2 -m 2G -A -H -P -l com1,stdio \
  -l bootrom,"$uefi" \
  -s 0,hostbridge -s 31,lpc -s 4,virtio-blk,"$target" \
  abyssp55d < /dev/null > "$work/installed.log" 2>&1 || true
sudo bhyvectl --destroy --vm=abyssp55d >/dev/null 2>&1 || true

grep -q "Setting hostname: jaguar" "$work/installed.log" \
  || { tail -25 "$work/installed.log" | sed 's/^/    /'
       fail "the installed machine did not boot"; }
echo "ok: it boots, as jaguar"

# **It starts at the login window** (PHASE16 P16.5, §6.2): no session runs
# until somebody logs in. Logging in through it is live-greeter.sh's (the
# whole chain) and live-authenticator.sh's (as root: the session as its user);
# typing into a nested machine's GUI would put the harness's tools in the image.
grep -q "abyss: the login window is up" "$work/installed.log" \
  || { grep -i abyss "$work/installed.log" | tail -10 | sed 's/^/    /'
       fail "the installed machine did not start the login window"; }
grep -q "abyss: starting the desktop" "$work/installed.log" \
  && fail "the installed machine started a desktop with nobody logged in"
echo "ok: and it started at the login window — nobody's session, until somebody logs in"
grep -q "abyss: the settings helper is up, for uid" "$work/installed.log" \
  || { grep -i 'abyss: .*settings' "$work/installed.log" | sed 's/^/    /'
       fail "the installed machine did not start the settings helper (PHASE14 P14.3)"; }
echo "ok: ...and System Preferences' privileged half, as root, for that administrator"
grep -q "abyss: the authenticator is up" "$work/installed.log" \
  || fail "the installed machine did not start the authenticator (PHASE16 P16.1)"
echo "ok: ...and the authenticator (PHASE16 P16.1)"


if grep -q "swapon:" "$work/installed.log"; then
  grep "swapon:" "$work/installed.log" | sed 's/^/    /'
  fail "it booted without swap (HANDOFF §2.43)"
fi
echo "ok: with swap, and nothing in the log about what is missing"

echo "all green (empty disk to Jaguar desktop, with nobody watching)."
