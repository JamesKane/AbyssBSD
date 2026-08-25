#!/bin/sh
# AbyssBSD Swift DE — put the live medium on a USB stick (PHASE4 §1).
#
# `abyss/mk/live-image.sh` produces a **whole-disk** image: a GPT carrying an
# ESP, a `freebsd-boot` partition, and the UFS root. UEFI firmware reads the
# partition table at LBA 1 of the **disk**, enumerates *that* table's EFI System
# partitions, and loads \EFI\BOOT\BOOTX64.EFI out of one. It never descends into
# a partition looking for a second partition table.
#
# So the image goes to `/dev/sdX`, never to `/dev/sdX4`. Written to a partition
# it buries its ESP some gigabytes inside a filesystem nothing will ever parse,
# and the machine boots whatever it booted before — a silent failure that looks
# like a driver problem, and cost a round to diagnose. **This script exists so
# that mistake is not available**: it refuses anything that is not a whole
# removable disk, and it refuses an image that is not one it built.
#
#   usage: abyss/mk/write-stick.sh DEVICE [--image PATH] [--yes] [--dry-run]
#                                  [--no-verify] [--allow-fixed]
#
#   DEVICE          the whole disk — /dev/sdb, not /dev/sdb4
#   --image PATH    default: $ABYSS_VM_HOME/abyss-live-metal.img
#   --yes           skip the confirmation (there is no tty under `!`)
#   --dry-run       run every check, write nothing, and say what it would do.
#                   Needs no root, which is what makes the guards testable.
#   --no-verify     skip the read-back
#   --allow-fixed   permit a non-removable disk (a USB SSD reports removable=0)
#
# Linux only, and it says so: `wipefs`, `sfdisk`, `lsblk` and `/sys/block` are
# how it decides a device is safe to destroy, and none of that is portable. The
# medium is BUILT on FreeBSD and WRITTEN from the dev box — two machines, two
# scripts, and this is the second one.
set -eu

# --help before anything else, so asking how it works never asks for a password.
case "${1:-}" in -h|--help) sed -n '2,30p' "$0"; exit 0 ;; esac

die()  { echo "write-stick: $1" >&2; exit 1; }
note() { echo "== $*"; }

[ "$(uname -s)" = Linux ] || die "this runs on the Linux dev box (wipefs, sfdisk, /sys/block)"

# --- dry run, decided before anything else ------------------------------
# Read out of "$@" here rather than in the parser below, because it has to be
# known before the escalation: a dry run touches nothing, so it must not ask for
# a password to prove it — and a guard you cannot exercise cheaply is a guard
# nobody exercises before the run that would have needed it.
dry=0
for a in "$@"; do [ "$a" = --dry-run ] && dry=1; done

# --- root, without needing a terminal -----------------------------------
# Everything past the checks writes to a raw disk, so it needs root. Under
# Claude Code's `!` prefix — and any other non-interactive shell — sudo has no
# tty to prompt on and fails with "a terminal is required", which is a confusing
# way to learn you are not root. So: escalate once, up front, through an askpass
# helper when there is no tty and one can be found.
if [ "$dry" != 1 ] && [ "$(id -u)" != 0 ]; then
  if [ -t 0 ]; then
    exec sudo -- "$0" "$@"
  fi
  for a in "${SUDO_ASKPASS:-}" /usr/bin/ksshaskpass /usr/bin/ssh-askpass \
           /usr/libexec/openssh/ssh-askpass /usr/bin/lxqt-openssh-askpass; do
    if [ -n "$a" ] && [ -x "$a" ]; then
      SUDO_ASKPASS=$a; export SUDO_ASKPASS
      exec sudo -A -- "$0" "$@"
    fi
  done
  die "not root, no tty, and no askpass helper — run it from a terminal"
fi

root=$(cd "$(dirname "$0")/../.." && pwd)

# Where the VM scripts keep large artifacts. Sourced rather than repeated, so
# "where did the image go" has one answer (abyss/vm/config.sh) instead of two
# that drift.
ABYSS_VM_DIR="$root/abyss/vm"; export ABYSS_VM_DIR
. "$root/abyss/vm/config.sh"

image="${ABYSS_STICK_IMAGE:-$ABYSS_VM_HOME/abyss-live-metal.img}"
dev=
assume_yes=0
verify=1
allow_fixed=0

while [ $# -gt 0 ]; do
  case "$1" in
    --image)       image=$2; shift 2 ;;
    --yes|-y)      assume_yes=1; shift ;;
    --dry-run)     dry=1; shift ;;
    --no-verify)   verify=0; shift ;;
    --allow-fixed) allow_fixed=1; shift ;;
    -*)            die "unknown option $1" ;;
    *)             [ -z "$dev" ] || die "one device, not two ($dev and $1)"
                   dev=$1; shift ;;
  esac
done

[ -n "$dev" ] || die "no device given — abyss/mk/write-stick.sh /dev/sdX"

for t in wipefs sfdisk lsblk findmnt dd blockdev udevadm; do
  command -v "$t" > /dev/null 2>&1 || die "$t is not installed (util-linux)"
done

# --- is the image one of ours? ------------------------------------------
# Checked before the disk is touched, because the other half of the failure
# this script prevents is writing something that was never bootable to begin
# with. A whole-disk image has a GPT with an EFI System partition in it; a bare
# filesystem image does not, and neither does a truncated download.
[ -f "$image" ] || die "no image at $image"
[ -s "$image" ] || die "$image is empty"
img_size=$(stat -c %s "$image")

img_table=$(sfdisk -l "$image" 2>/dev/null) \
  || die "$image has no partition table sfdisk can read — is it a whole-disk image?"
echo "$img_table" | grep -q 'Disklabel type: gpt' \
  || die "$image is not GPT — UEFI needs a GPT with an EFI System partition"
echo "$img_table" | grep -qi 'EFI System' \
  || die "$image has no EFI System partition, so no firmware can boot it"

note "image: $image"
echo "$img_table" | sed -n '/^Device/,$p' | sed 's/^/   /'

# --- is the target a whole, removable disk? -----------------------------
# `readlink -f` first, so /dev/disk/by-id/... and other symlinks are judged by
# what they point at rather than by how they were spelled.
dev=$(readlink -f "$dev") || die "cannot resolve $dev"
[ -b "$dev" ] || die "$dev is not a block device"
name=$(basename "$dev")

# **The check this script is for.** sysfs gives every partition a `partition`
# file and every whole disk none — so this is the difference between /dev/sdb
# and /dev/sdb4, asked of the kernel rather than parsed out of the name.
if [ -e "/sys/class/block/$name/partition" ]; then
  whole=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
  die "$dev is a PARTITION. The image is a whole-disk image, and UEFI reads the
             partition table at the start of the DISK — written here, its ESP would
             be buried inside $name and no firmware would ever find it.${whole:+
             You want /dev/$whole.}"
fi

[ -d "/sys/block/$name" ] || die "$dev is not a whole disk the kernel knows about"

removable=$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)
if [ "$removable" != 1 ] && [ "$allow_fixed" != 1 ]; then
  die "$dev is not removable (removable=$removable). If it really is the stick —
             a USB SSD often reports 0 — pass --allow-fixed and read the summary
             below twice."
fi

# --- is it holding anything this machine needs? -------------------------
# The removable flag is not enough on its own: an external disk can hold /home,
# and a stick can be the thing you booted. So ask what actually backs the
# mountpoints that would end the session, and refuse if any of them lives here.
parent_of() {
  p=$(lsblk -no PKNAME "$1" 2>/dev/null | head -1)
  [ -n "$p" ] || p=$(basename "$1")
  printf '%s' "$p"
}
for m in / /boot /boot/efi /home /usr /var; do
  [ -d "$m" ] || continue
  src=$(findmnt -no SOURCE --target "$m" 2>/dev/null | head -1) || continue
  [ -n "$src" ] || continue
  src=$(printf '%s' "$src" | sed 's/\[.*//')   # btrfs reports /dev/xxx[/subvol]
  case "$src" in /dev/*) ;; *) continue ;; esac
  [ "$(parent_of "$src")" = "$name" ] \
    && die "$dev holds $m ($src). Refusing — this is the machine you are on."
done

# From sysfs (512-byte units) rather than `blockdev --getsize64`, which needs
# root — and a --dry-run that has to be root is one nobody runs before the real
# thing, which is the only moment it would have helped.
sz=$(( $(cat "/sys/block/$name/size") * 512 ))
[ "$img_size" -le "$sz" ] \
  || die "$image is $img_size bytes and $dev holds $sz — it does not fit"

# --- say what is about to be destroyed ----------------------------------
model=$(cat "/sys/block/$name/device/model" 2>/dev/null | sed 's/ *$//' || true)
note "target: $dev  ${model:+$model, }$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz bytes")"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev" | sed 's/^/   /'

if [ "$assume_yes" != 1 ] && [ "$dry" != 1 ]; then
  [ -r /dev/tty ] || die "no tty to confirm on — re-run with --yes if you mean it"
  printf 'write-stick: this ERASES all of %s. Type the device name to confirm: ' "$dev"
  read -r reply < /dev/tty
  [ "$reply" = "$dev" ] || [ "$reply" = "$name" ] || die "not confirmed ($reply)"
fi

if [ "$dry" = 1 ]; then
  note "dry run — every check passed, nothing written"
  echo "   would: umount every mounted partition of $dev"
  echo "   would: wipefs -a $dev"
  echo "   would: dd if=$image of=$dev bs=4M conv=fsync"
  echo "   would: sfdisk --relocate gpt-bak-std $dev"
  exit 0
fi

# --- unmount everything on it -------------------------------------------
# Checked afterwards rather than trusted: `umount` failing on one of several
# partitions must not leave the rest to be wiped underneath a live filesystem.
note "unmounting"
for part in $(lsblk -lno NAME "$dev" | tail -n +2); do
  while findmnt -no TARGET "/dev/$part" > /dev/null 2>&1; do
    umount "/dev/$part" 2>/dev/null || break
  done
  findmnt -no TARGET "/dev/$part" > /dev/null 2>&1 \
    && die "/dev/$part is still mounted at $(findmnt -no TARGET "/dev/$part")"
done
swapoff "$dev"* 2>/dev/null || true

# --- write ---------------------------------------------------------------
# **wipefs first, and it is not cosmetic.** A GPT has a backup header in the
# LAST sector of the disk. The image's backup lands at the image's end — around
# 3 GB in — so without this the stick keeps a stale backup table from whatever
# it was before, at the far end, contradicting the primary. Firmware that reads
# the primary boots; firmware that cross-checks does not, and the difference
# looks like luck.
note "wiping existing signatures"
wipefs -a "$dev" > /dev/null

note "writing $(numfmt --to=iec "$img_size" 2>/dev/null || echo "$img_size bytes")"
dd if="$image" of="$dev" bs=4M conv=fsync status=progress
sync

# **And put the backup header where the spec says it goes.** `sgdisk -e` is the
# familiar spelling and needs gdisk, which is not installed on a stock Fedora;
# `sfdisk --relocate` is util-linux, which is already a hard dependency above.
# Without it the primary header's AlternateLBA points into the middle of the
# stick — bootable in practice, invalid on paper, and every partition tool that
# touches it afterwards offers to "repair" it.
note "relocating the backup GPT header to the end of the disk"
if ! sfdisk --relocate gpt-bak-std "$dev" > /dev/null 2>&1; then
  echo "   WARNING: could not relocate the backup header. The stick should still"
  echo "            boot, but its GPT is inconsistent on paper."
fi

blockdev --rereadpt "$dev" 2>/dev/null || true
udevadm settle 2>/dev/null || true

# --- read it back --------------------------------------------------------
# An install that says "ok" is not one that worked (HANDOFF §2.44). What was
# asserted here is what firmware will actually look for: a GPT on the disk, an
# EFI System partition in it, and BOOTX64.EFI inside that.
if [ "$verify" = 1 ]; then
  note "verifying"
  lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev" | sed 's/^/   /'

  sfdisk -l "$dev" 2>/dev/null | grep -qi 'EFI System' \
    || die "no EFI System partition on $dev after writing"
  lsblk -lno FSTYPE,LABEL "$dev" | grep -q 'ufs *ABYSSLIVE' \
    || die "no UFS partition labelled ABYSSLIVE on $dev — the root did not land"

  esp=$(lsblk -lno NAME,PARTTYPENAME "$dev" \
        | awk '/EFI System/ {print "/dev/"$1; exit}')
  [ -n "$esp" ] || die "cannot identify the ESP on $dev"
  if command -v mdir > /dev/null 2>&1; then
    mdir -i "$esp" ::/EFI/BOOT 2>/dev/null | grep -qi 'BOOTX64' \
      || die "$esp has no /EFI/BOOT/BOOTX64.EFI — firmware would find nothing to load"
    echo "   $esp carries /EFI/BOOT/BOOTX64.EFI"
  else
    echo "   (mtools absent — could not read $esp; install mtools to check BOOTX64.EFI)"
  fi
fi

note "$dev is ready — boot it holding Option and choose \"EFI Boot\""
