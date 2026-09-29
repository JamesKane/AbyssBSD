#!/bin/sh
# AbyssBSD Swift DE — the installer installs, and what it installed boots
# (PHASE5.md P5.2).
#
# This is the pass where the phase's claim becomes true, and the claim is not
# "the script exited 0" or "the pool imported". It is:
#
#     login:
#
# on a machine we partitioned, from a kernel we extracted, booted by a loader we
# copied — with no human, no hardware, and nothing outside the build VM.
#
# Four real processes and one nested machine:
#
#   abyss-install     the privileged half, running as ROOT
#   abyss-installctl  an UNPRIVILEGED caller — the split PHASE5 §1 argues for
#   bhyve             the installed system, booted nested (PHASE5 §4.2)
#
# What it proves, in order:
#
#   1. The machine probe finds real disks and knows which one holds the running
#      root. Everything after this depends on it being right.
#   2. An unprivileged process can command a root installer — and only the uid
#      it was started for can (PHASE5 §4.4).
#   3. The disk we are running from is REFUSED, live, by the same predicate the
#      unit tests exercise. The most important assertion in this file.
#   4. A real install onto a real (scratch) disk, driven end to end over
#      CurrentIPC, with progress arriving step by step.
#   5. And the result BOOTS, nested, to a login prompt.
#
# On Linux this is a positive control rather than a skip: the probe must fail
# and say what it could not find. A test that quietly does nothing on the
# machine you develop on is how an installer ships broken (PHASE5 §5).
#
# Usage: abyss/tests/live-install.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

svc="$root/.build/debug/abyss-install"
ctl="$root/.build/debug/abyss-installctl"
[ -x "$svc" ] && [ -x "$ctl" ] || swift build

work=$(mktemp -d /tmp/abyss-inst.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-instr.XXXXXX)
cleanup() {
  [ -n "${svc_pid:-}" ] && kill "$svc_pid" 2>/dev/null || true
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT
export ABYSS_RUNTIME_DIR="$rundir"

fail() { echo "FAIL: $1"; [ -s "$work/svc.err" ] && sed 's/^/  | /' "$work/svc.err"; exit 1; }

# --------------------------------------------------------------- not FreeBSD
if [ "$(uname -s)" != "FreeBSD" ]; then
  echo "== $(uname -s): the installer must refuse, and say why =="
  "$svc" --uid "$(id -u)" --once >/dev/null 2>"$work/svc.err" &
  svc_pid=$!
  i=0; while [ ! -S "$rundir/install.sock" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
  [ -S "$rundir/install.sock" ] || fail "the installer never bound its socket"

  if out=$("$ctl" disks 2>&1); then
    fail "disk discovery claimed to work on $(uname -s): $out"
  fi
  echo "$out" | grep -q "geom" || fail "the refusal does not name what is missing: $out"
  echo "$out" | grep -qi "$(uname -s)" || fail "the refusal does not name this system: $out"
  echo "ok: refused, and named both the system and the tool it wanted:"
  echo "    $out"
  wait "$svc_pid" 2>/dev/null || true
  unset svc_pid
  echo "all green (the installer knows where it cannot work)."
  exit 0
fi

# ------------------------------------------------------------------ FreeBSD
command -v bhyve >/dev/null || fail "bhyve is not installed"
uefi=/usr/local/share/uefi-firmware/BHYVE_UEFI.fd
dist="${ABYSS_DIST_DIR:-/home/$(id -un)/dist}"

if [ ! -f "$uefi" ]; then
  echo "SKIP: no bhyve UEFI firmware ($uefi) — pkg install edk2-bhyve"
  exit 0
fi
if [ ! -s "$dist/base.txz" ] || [ ! -s "$dist/kernel.txz" ]; then
  echo "SKIP: no distribution sets in $dist (base.txz + kernel.txz)."
  echo "      fetch them once: mkdir -p $dist && cd $dist &&"
  echo "      fetch https://download.freebsd.org/ftp/releases/amd64/15.0-RELEASE/base.txz kernel.txz"
  exit 0
fi

# ------------------------------------------------------- 1. look at the disks
# The service runs as root; the caller does not. That is the arrangement under
# test, not an inconvenience to work around.
echo "== the installer, as root, commanded by uid $(id -u) =="
sudo -n true 2>/dev/null || fail "this test needs passwordless sudo to run the installer as root"
# `sudo env …` rather than `sudo -E`: sudoers resets the environment by default,
# and the runtime directory is the one thing the root service and the
# unprivileged caller have to agree about.
sudo env ABYSS_RUNTIME_DIR="$rundir" "$svc" --uid "$(id -u)" >/dev/null 2>"$work/svc.err" &
svc_pid=$!
i=0; while [ ! -S "$rundir/install.sock" ] && [ $i -lt 200 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$rundir/install.sock" ] || fail "the installer never bound its socket"

"$ctl" disks > "$work/disks" 2>&1 || fail "could not list disks: $(cat "$work/disks")"
cat "$work/disks" | sed 's/^/    /'
grep -q "holds the running root" "$work/disks" \
  || fail "no disk claims to hold the running root, so nothing would ever be refused"
echo "ok: an unprivileged caller commanded a root installer, and it found the machine"

# ----------------------------------------- 2. only that uid may command it
# Belt: the socket is handed to one uid. Braces: the service asks the kernel.
owner=$(stat -f '%Su' "$rundir/install.sock")
[ "$owner" = "$(id -un)" ] \
  || fail "the socket belongs to $owner, so the caller it was started for cannot open it"
echo "ok: the socket was handed to exactly the uid the installer was started for"

# ------------------------------------------- 3. the disk we booted from: NO
rootdisk=$(awk -F'\t' '/holds the running root/ { print $1 }' "$work/disks" | head -1)
[ -n "$rootdisk" ] || fail "could not tell which disk holds the running root"
if out=$("$ctl" check --disk "$rootdisk" --root-hash '$6$live' 2>&1); then
  fail "the installer agreed to install onto $rootdisk, which is the disk it is running from"
fi
echo "$out" | grep -q "running from" || fail "refused $rootdisk for the wrong reason: $out"
echo "ok: refused the disk it is running from — live, not just in a unit test"
echo "    $out"

# --------------------------------------------- 4. find the scratch disk
# Chosen by the product's own signals rather than by a hardcoded name: not the
# root disk, nothing mounted from it, and big enough to be a target. If that is
# not exactly one disk, stop — this test writes a GPT over whatever it picks.
target=$(awk -F'\t' '
  /holds the running root/ { next }
  /mounted at/             { next }
  { gsub(/ GiB/, "", $2); if ($2 + 0 >= 8 && $2 + 0 <= 64) print $1 }
' "$work/disks")
count=$(echo "$target" | grep -c . || true)
[ "$count" = 1 ] || fail "expected exactly one installable disk, found $count: $(echo $target)"
echo "ok: exactly one installable disk on this machine: $target"

# The SAME plan `install` is about to be given, so that "check said yes" is a
# promise about the install that follows rather than about a similar one.
#
# **`--erase-this-disk` is here because the harness genuinely is erasing one.**
# The scratch disk carries the previous run's install, and a disk with something
# on it and no room is now refused until somebody says so. This test says so, in
# the same words a person would have to — which is the point: the harness does
# not get a quieter path to destruction than the human does.
plan="--disk $target --pool abyssp52 --dist $dist --hostname jaguar
      --timezone America/Chicago --root-hash \$6\$rootp52
      --user abyss:\$6\$userp52:wheel --erase-this-disk"

# shellcheck disable=SC2086
"$ctl" check $plan > "$work/check" 2>&1 \
  || fail "the installer refused a good plan: $(cat "$work/check")"
steps=$(head -1 "$work/check" | awk '{print $1}')
[ "$steps" -gt 30 ] || fail "a whole install compiled to only $steps steps"
echo "ok: the plan compiled to $steps steps without anything being written"

# ------------------------------------------------------- 5. install, for real
echo "== installing onto $target (this rewrites it) =="
# shellcheck disable=SC2086
"$ctl" install --yes $plan > "$work/install" 2>&1 \
  || { sed 's/^/    /' "$work/install"; fail "the install failed"; }
tail -4 "$work/install" | sed 's/^/    /'
grep -q "^installed\." "$work/install" || fail "the install never said it finished"
grep -q "create the GPT" "$work/install" || fail "no step-by-step progress arrived"
grep -q "extract base.txz" "$work/install" || fail "the base system was never extracted"
ran=$(grep -c '^\[' "$work/install")
# `check` and `install` compile the same plan with the same code, so a
# disagreement here means one of them answered about something else — which
# would make "check said yes" worthless as a promise about the install.
[ "$ran" = "$steps" ] \
  || fail "check compiled $steps steps and the install ran $ran — they disagree"
echo "ok: $ran steps ran, one message at a time over CurrentIPC —"
echo "    exactly the $steps that check promised, and not one more"

kill "$svc_pid" 2>/dev/null || true
unset svc_pid

# ------------------------------------------------------------- 6. does it boot
echo "== booting what we just installed, nested =="
sudo kldload nmdm 2>/dev/null || true
sudo bhyvectl --destroy --vm=abyssp52 >/dev/null 2>&1 || true
sudo timeout 180 bhyve -c 2 -m 1G -A -H -P -l com1,stdio \
  -l bootrom,"$uefi" \
  -s 0,hostbridge -s 31,lpc -s 4,virtio-blk,/dev/"$target" \
  abyssp52 < /dev/null > "$work/boot.log" 2>&1 || true
sudo bhyvectl --destroy --vm=abyssp52 >/dev/null 2>&1 || true

grep -q "login:" "$work/boot.log" || {
  tail -25 "$work/boot.log" | sed 's/^/    /'
  fail "the installed system did not reach a login prompt"
}
grep -q "Setting hostname: jaguar" "$work/boot.log" \
  || fail "it booted, but not into the machine we described"
if grep -q "swapon:" "$work/boot.log"; then
  grep "swapon:" "$work/boot.log" | sed 's/^/    /'
  fail "it booted without swap — the GPT labels we wrote were not there (HANDOFF §2.43)"
fi
echo "ok: it boots — hostname jaguar, swap on, no human involved"
grep -B2 "login:" "$work/boot.log" | head -4 | sed 's/^/    /'

echo "all green (the installer installs, and what it installed boots)."
