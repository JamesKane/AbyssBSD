#!/bin/sh
# Assert the build VM is actually usable — run it after first boot.
#
# Every `pkg install` in the cloud-init seed is best-effort (`|| true`) so one
# missing port can't wedge provisioning; the cost is that a silent miss looks
# exactly like success. This script is the check that closes that gap: it waits
# for provisioning to finish, then asserts SSH, the package set, the C libraries
# the desktop links (via pkg-config, the way abyss-sys/build.rs finds them),
# and cargo.
#
# Exit 0 = the VM is ready to build in. Anything else prints what's wrong.
set -eu
. "$(dirname "$0")/config.sh"

fail=0
note() { printf '[check] %s\n' "$*"; }
bad()  { printf '[check] FAIL: %s\n' "$*" >&2; fail=1; }

# --- reachable? ---------------------------------------------------------
# shellcheck disable=SC2046
ssh_run() { ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@$ABYSS_SSH_HOST" "$@"; }

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
    bad "no ssh after ${ABYSS_CHECK_WAIT}s (is the VM booted? see $ABYSS_SERIAL_LOG)"
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

# --- the builder (PHASE17 P17.0): poudriere on ZFS, and that is all -----
if [ "$ABYSS_VM_ROLE" = builder ]; then
  ssh_run 'command -v poudriere >/dev/null' && note "poudriere: $(ssh_run 'pkg query %v poudriere')" || bad "no poudriere"
  ssh_run 'zpool list -H -o name,free' | while read -r p f; do note "pool $p: $f free"; done
  note "cores: $(ssh_run 'sysctl -n hw.ncpu'), memory: $(( $(ssh_run 'sysctl -n hw.physmem') / 1073741824 )) GB"
  [ "$fail" -eq 0 ] && note "builder is ready." || note "builder is NOT ready — see the FAIL lines above."
  exit "$fail"
fi

# --- the C libraries abyss-sys/build.rs links ------------------------------
# Its pkg-config names, plus the scanner. The wlroots version is PINNED, to
# 0.20 since 2026-09-30: a compositor that builds against different wlroots
# on each platform is a failure mode this project has not had (PHASE6.md
# §7.3), so it must match build.rs's.
for pc in wayland-client wayland-scanner xkbcommon cairo freetype2 harfbuzz fontconfig \
          pixman-1 wayland-server wlroots-0.20; do
  if ssh_run "pkg-config --exists $pc" 2>/dev/null; then
    note "pkg-config $pc: $(ssh_run "pkg-config --modversion $pc" 2>/dev/null)"
  else
    bad "pkg-config cannot find '$pc' (abyss-sys/build.rs needs it)"
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

# --- Rust -------------------------------------------------------------------
if ssh_run "command -v cargo >/dev/null" 2>/dev/null; then
  note "cargo: $(ssh_run "cargo --version" 2>/dev/null)"
else
  bad "missing tool: cargo (pkg install rust)"
fi

if [ "$fail" -eq 0 ]; then
  note "VM is ready."
else
  note "VM is NOT ready — see the FAIL lines above."
fi
exit "$fail"
