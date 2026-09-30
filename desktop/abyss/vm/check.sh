#!/bin/sh
# Assert the build VM is actually usable — run it after first boot.
#
# Every `pkg install` in the cloud-init seed is best-effort (`|| true`) so one
# missing port can't wedge provisioning; the cost is that a silent miss looks
# exactly like success. This script is the check that closes that gap: it waits
# for provisioning to finish, then asserts SSH, the package set, the C libraries
# the Swift targets FFI into (via pkg-config, the way SwiftPM will find them),
# and reports the Swift toolchain's status without failing on it — Swift on
# FreeBSD is the P3.2 spike, not a P3.1 precondition.
#
# Exit 0 = the VM is ready to build in. Anything else prints what's wrong.
set -eu
. "$(dirname "$0")/config.sh"

fail=0
note() { printf '[check] %s\n' "$*"; }
bad()  { printf '[check] FAIL: %s\n' "$*" >&2; fail=1; }

# --- reachable? ---------------------------------------------------------
# shellcheck disable=SC2046
ssh_run() { ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@127.0.0.1" "$@"; }

# First boot is the slow case this script exists for, and it is slow: the cloud
# image runs freebsd-update, then cloud-init pulls ~100 packages (llvm19 alone
# is huge), and sshd only comes up after that. Measured at ~15 minutes on a
# fresh box. The loop exits the moment ssh answers, so a generous default costs
# nothing on a warm VM.
: "${ABYSS_CHECK_WAIT:=1200}"
note "waiting up to ${ABYSS_CHECK_WAIT}s for ssh on port $ABYSS_SSH_PORT"
waited=0
until ssh_run true 2>/dev/null; do
  waited=$((waited + 5))
  if [ "$waited" -ge "$ABYSS_CHECK_WAIT" ]; then
    bad "no ssh after ${ABYSS_CHECK_WAIT}s (is the VM booted? see $ABYSS_VM_HOME/serial.log)"
    exit 1
  fi
  sleep 5
done
note "ssh ok after ${waited}s — $(ssh_run 'uname -sr')"

# --- provisioning finished? --------------------------------------------
note "waiting for cloud-init (pkg installs run on first boot)"
waited=0
until ssh_run 'test -f ~/.cloud-init-done' 2>/dev/null; do
  waited=$((waited + 10))
  if [ "$waited" -ge 900 ]; then
    bad "cloud-init never finished (~/.cloud-init-done absent after 15min)"
    exit 1
  fi
  sleep 10
done
note "cloud-init done"

# --- the package set actually landed? -----------------------------------
missing=$(ssh_run 'cat ~/.pkg-missing 2>/dev/null | tr "\n" " "' || true)
if [ -n "$(printf '%s' "$missing" | tr -d ' ')" ]; then
  bad "packages missing from the guest: $missing"
else
  note "all seeded packages present"
fi

# --- the base is the pinned snapshot ------------------------------------
# A pkgbase guest can upgrade its own world and kernel (first boot does, unless
# the seed stops it), and then it no longer matches the sets the medium is
# built from. Assert on the installed packages, not on uname: a kernel upgrade
# does not show in uname until the next reboot.
if [ -n "$ABYSS_BASE_PKG_PREFIX" ]; then
  got=$(ssh_run 'pkg query %v FreeBSD-runtime FreeBSD-kernel-generic 2>/dev/null | tr "\n" " "' || true)
  case " $got" in
    *" $ABYSS_BASE_PKG_PREFIX"*" $ABYSS_BASE_PKG_PREFIX"*) note "base is the pinned snapshot ($ABYSS_BASE_PKG_PREFIX): $got" ;;
    *) bad "base has moved off the pinned snapshot $ABYSS_BASE_PKG_PREFIX: FreeBSD-runtime/kernel are $got" ;;
  esac
fi

# --- the C substrate SwiftPM will look for ------------------------------
# These are the pkg-config names in Package.swift's systemLibrary targets
# (plus wayland-client, which CWayland links directly).
# Phase 6 adds wayland-server + wlroots for `undertow` (PHASE6.md §4.3).
# The version is PINNED, to 0.20 since 2026-09-30: a compositor that builds
# against different wlroots on each platform is a failure mode this project
# has not had (PHASE6.md §7.3), so it must match Package.swift's.
for pc in wayland-client wayland-scanner xkbcommon cairo freetype2 harfbuzz libpng \
          wayland-server wlroots-0.20; do
  if ssh_run "pkg-config --exists $pc" 2>/dev/null; then
    note "pkg-config $pc: $(ssh_run "pkg-config --modversion $pc" 2>/dev/null)"
  else
    bad "pkg-config cannot find '$pc' (Package.swift needs it)"
  fi
done

# --- tools the live harness shells out to -------------------------------
for tool in sway swaymsg grim cc; do
  if ssh_run "command -v $tool >/dev/null" 2>/dev/null; then
    note "tool $tool: ok"
  else
    bad "missing tool: $tool (abyss/tests needs it)"
  fi
done

# --- Swift: report, do not gate -----------------------------------------
# Ports installs the toolchain off PATH (see config.sh), so look where it lives.
# This is a report, not a gate: proving Swift builds *this repo* is P3.2, and a
# VM is still useful for C-substrate work without it.
if ssh_run "test -x $ABYSS_GUEST_SWIFT_BIN/swift" 2>/dev/null; then
  note "SWIFT PRESENT: $(ssh_run "$ABYSS_GUEST_SWIFT_BIN/swift --version 2>&1 | head -1")"
  note "  target: $(ssh_run "$ABYSS_GUEST_SWIFT_BIN/swift --version 2>&1 | sed -n 2p")"
  for t in swift-build swift-test swiftc; do
    ssh_run "test -x $ABYSS_GUEST_SWIFT_BIN/$t" 2>/dev/null \
      && note "  $t: ok" || bad "toolchain incomplete: no $t"
  done
else
  note "swift absent at $ABYSS_GUEST_SWIFT_BIN — see docs/SWIFT-ON-FREEBSD.md (P3.2)"
fi

if [ "$fail" -eq 0 ]; then
  note "VM is ready."
else
  note "VM is NOT ready — see the FAIL lines above."
fi
exit "$fail"
