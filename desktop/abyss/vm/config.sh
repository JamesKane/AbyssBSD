# shellcheck shell=sh
# Shared config for the AbyssBSD build VM. Override any var via the environment.
#
# Large VM artifacts (images, disks, seed) live OUTSIDE the git repo so they
# never bloat history.

# The desktop's root (this file lives at $REPO/abyss/vm/config.sh), which is
# the monorepo's desktop/. The vm/ scripts get this right from $0; anything
# else that sources this file (abyss/tests/run.sh --vm) sets ABYSS_VM_DIR
# first, since $0 would then point somewhere else.
: "${ABYSS_VM_DIR:=$(cd "$(dirname "$0")" && pwd)}"
ABYSS_REPO="$(cd "$ABYSS_VM_DIR/../.." && pwd)"
# The monorepo holding it.
ABYSS_MONOREPO="$(cd "$ABYSS_REPO/.." && pwd)"

# Where VM artifacts are stored: beside the monorepo, never inside it. The
# name predates the monorepo and is kept, so a box provisioned when the
# desktop was a repo of its own is the one used.
: "${ABYSS_VM_HOME:=$(cd "$ABYSS_MONOREPO/.." && pwd)/abyss-swift-vm}"

# FreeBSD image, and what goes with it. The version picks the whole set:
# image, disk, seed, and the distribution sets the medium is built from. Two
# boxes share this home and one runs at a time (same port, same serial log).
#
#   16.0-CURRENT   the default since 2026-09-30: the distribution's base is
#                  FreeBSD main (PLAN decision 5). A snapshot, pinned by date
#                  and revision, because CURRENT's "Latest" moves every week
#                  and the image and the sets must come from one build.
#   15.0-RELEASE   the box the project was built on, kept bootable until the
#                  16 box has passed the same gates; its files keep their
#                  original, unversioned names.
: "${ABYSS_FBSD_VERSION:=16.0-CURRENT}"
: "${ABYSS_VM_ROLE:=build}"
: "${ABYSS_ARCH:=amd64}"
# The riscv64 guest (RUST.md R0, §6.10) is its own snapshot: there is no
# CLOUDINIT image for riscv64, so it boots the plain UFS image and
# provision-rv64.py sets it up over the serial console. Set first, so the
# amd64 recipe below leaves these alone.
if [ "$ABYSS_VM_ROLE" = rv64 ]; then
  ABYSS_ARCH=riscv64
  _snap=20261027-61c70dc16a79-290352
  : "${ABYSS_BASE_PKG_PREFIX:=16.snap${_snap%%-*}}"
  : "${ABYSS_FBSD_IMG:=FreeBSD-16.0-CURRENT-riscv-riscv64-ufs-${_snap}.qcow2}"
  : "${ABYSS_FBSD_URL:=https://download.freebsd.org/snapshots/VM-IMAGES/16.0-CURRENT/riscv64/${_snap%%-*}/${ABYSS_FBSD_IMG}.xz}"
  : "${ABYSS_FBSD_SHA512:=cf7f46a4b86f2ce858286cf16c951299a1acb4aa8300d7dee93428136515c81f4b97a3d807da82ac670945252384315430fa16f206d2f3e9caf491971da5b72e}"
  : "${ABYSS_SETS_SHA256:=}"
fi
case "$ABYSS_FBSD_VERSION" in
  16.0-CURRENT)
    _snap=20260928-36d3e711bc62-289650
    # check.sh asserts the installed base is still this build (make-seed.sh
    # holds it there): pkgbase versions it as 16.snapYYYYMMDD….
    : "${ABYSS_BASE_PKG_PREFIX:=16.snap${_snap%%-*}}"
    : "${ABYSS_FBSD_IMG:=FreeBSD-16.0-CURRENT-amd64-BASIC-CLOUDINIT-${_snap}-zfs.qcow2}"
    : "${ABYSS_FBSD_URL:=https://download.freebsd.org/snapshots/VM-IMAGES/16.0-CURRENT/amd64/${_snap%%-*}/${ABYSS_FBSD_IMG}.xz}"
    : "${ABYSS_FBSD_SHA512:=965024b27ba52fcd35a66d40022e7702c9619a88bd6ab82ac20684d959e402d83dcfc89a060927e727893691363919da873fec3d8d98b4c80c3ba997c35eeef7}"
    # The snapshot's sets. Only the newest build is published, so they are
    # fetched once and pinned here by the MANIFEST's SHA256 (src.txz for the
    # wtap lab's /usr/src).
    : "${ABYSS_SETS_URL:=https://download.freebsd.org/snapshots/amd64/16.0-CURRENT}"
    : "${ABYSS_SETS_SHA256:=base.txz=bc0a4c7b66ee6add4cac176ef4733c8a56cf7fef508326ace6e62dadd29e91e9 kernel.txz=6b1ef72d2d4d9e222cbb1155c0de13b98e7c60cd2f175a6b813059a7c992602e src.txz=6af2d6210a36745b89f736fa885bf9a7e2f7c460e63a623621a7263545808cb9}"
    _suffix=-16
    ;;
  15.0-RELEASE)
    : "${ABYSS_FBSD_IMG:=FreeBSD-15.0-RELEASE-amd64-BASIC-CLOUDINIT-zfs.qcow2}"
    : "${ABYSS_FBSD_URL:=https://download.freebsd.org/ftp/releases/VM-IMAGES/15.0-RELEASE/amd64/Latest/${ABYSS_FBSD_IMG}.xz}"
    : "${ABYSS_FBSD_SHA512:=e863bd451ca1bf0529643b4d6380805fe8464a26f4ab8e0ae0adfddd2e68376546dbe2ebee3ba3e44f1ff9ee853921b866524e442b762f7ff5c1cdc07f6dab3e}"
    : "${ABYSS_SETS_URL:=https://download.freebsd.org/ftp/releases/amd64/15.0-RELEASE}"
    : "${ABYSS_SETS_SHA256:=}"
    : "${ABYSS_BASE_PKG_PREFIX:=}"   # freebsd-update, not pkgbase: nothing to assert
    _suffix=
    ;;
  *) echo "config.sh: no image recipe for ABYSS_FBSD_VERSION=$ABYSS_FBSD_VERSION" >&2; exit 2 ;;
esac

# The VM's role. `build` is the desktop's guest: its fast loop, the harness, the
# medium. `builder` (PHASE17 P17.0) is the release pipeline's: world, kernel,
# pkgbase and poudriere, on more disk and cores, running beside the guest on
# its own port, disk, seed and logs. Same image, same scripts:
#   ABYSS_VM_ROLE=builder abyss/vm/make-seed.sh && ABYSS_VM_ROLE=builder ABYSS_DAEMON=1 abyss/vm/run.sh
#
# `rv64` (RUST.md R0) is FreeBSD/riscv64 under TCG: the Rust port's third
# gate platform. No KVM, so it is slow; it never runs --full.
case "$ABYSS_VM_ROLE" in
  build) _role= ;;
  builder)
    _role=-builder
    : "${ABYSS_DISK:=$ABYSS_VM_HOME/abyss-builder$_suffix.qcow2}"
    : "${ABYSS_DISK_SIZE:=160G}"
    : "${ABYSS_SSH_PORT:=2223}"
    : "${ABYSS_HOSTNAME:=abyss-builder}"
    # The host has 16 cores and 46 GB; the build guest keeps its 8 and 16 GB.
    : "${ABYSS_CPUS:=12}"
    : "${ABYSS_MEM:=14G}"
    : "${ABYSS_SCRATCH:=none}"           # nothing here for an installer to destroy
    # The whole monorepo: the pipeline builds src/ and ports/ as well as desktop/.
    : "${ABYSS_GUEST_SRC:=/home/build/AbyssBSD}"
    : "${ABYSS_SYNC_ROOT:=$ABYSS_MONOREPO}"
    ;;
  rv64)
    _role=-rv64
    : "${ABYSS_DISK:=$ABYSS_VM_HOME/abyss-rv64$_suffix.qcow2}"
    : "${ABYSS_DISK_SIZE:=60G}"
    : "${ABYSS_SSH_PORT:=2224}"
    : "${ABYSS_HOSTNAME:=abyss-rv64}"
    # TCG runs one host thread per vCPU (MTTCG). The virt machine's EDK2
    # takes at most 8 harts happily; more buys little under emulation.
    : "${ABYSS_CPUS:=8}"
    : "${ABYSS_MEM:=8G}"
    : "${ABYSS_SCRATCH:=none}"
    # RVA22 is the Orange Pi RV2's (SpacemiT K1) profile, the older board, so
    # what runs here runs on both (the K3 is RVA23).
    : "${ABYSS_RV64_CPU:=rva22s64}"
    : "${ABYSS_RV64_FW_CODE:=/usr/share/edk2/riscv/RISCV_VIRT_CODE.fd}"
    : "${ABYSS_RV64_FW_VARS:=/usr/share/edk2/riscv/RISCV_VIRT_VARS.fd}"
    : "${ABYSS_RV64_VARS:=$ABYSS_VM_HOME/rv64-vars.fd}"
    ;;
  *) echo "config.sh: no role ABYSS_VM_ROLE=$ABYSS_VM_ROLE (build, builder or rv64)" >&2; exit 2 ;;
esac
: "${ABYSS_SERIAL_LOG:=$ABYSS_VM_HOME/serial$_role.log}"
: "${ABYSS_PIDFILE:=$ABYSS_VM_HOME/qemu$_role.pid}"
: "${ABYSS_CONSOLE_SOCK:=$ABYSS_VM_HOME/console$_role.sock}"

# Cross-building for FreeBSD/riscv64 on the host (RUST.md §6.8, §6.9). The
# sysroot and the package repository come from the builder's rv64 jail
# (rv64-sysroot.sh); the toolchain is pinned, and bumping it is its own pass.
: "${ABYSS_RV64_SYSROOT:=$ABYSS_VM_HOME/sysroot-rv64}"
: "${ABYSS_RV64_PKGS:=$ABYSS_VM_HOME/pkgs-rv64}"
: "${ABYSS_RUST_NIGHTLY:=nightly-2026-10-04}"
: "${ABYSS_RV64_HOST_CLANG:=/usr/bin/clang}"
: "${ABYSS_RV64_HOST_AR:=/usr/bin/llvm-ar}"
: "${ABYSS_SYNC_ROOT:=$ABYSS_REPO}"

# Disk / paths
: "${ABYSS_IMAGES:=$ABYSS_VM_HOME/images}"
: "${ABYSS_BASE_QCOW:=$ABYSS_IMAGES/$ABYSS_FBSD_IMG}"          # pristine, never booted
: "${ABYSS_DISK:=$ABYSS_VM_HOME/abyss-build$_suffix.qcow2}"   # working overlay disk
: "${ABYSS_DISK_SIZE:=80G}"
: "${ABYSS_SEED:=$ABYSS_VM_HOME/seed$_role$_suffix.iso}"            # cloud-init cidata (Rock Ridge ISO)
: "${ABYSS_SETS_DIR:=$ABYSS_VM_HOME/dist$_suffix}"            # base/kernel/src.txz, host copy
# A scratch disk for Phase 5: something the installer can be pointed at and
# destroy. It is a real virtio disk on purpose — `geom disk list` does not show
# md(4) devices, so an install onto a memory disk is one the installer's own
# machine probe cannot see, and a test that worked around that would be testing
# a code path the product does not have. Small, sparse, and recreated whenever
# it is missing.
: "${ABYSS_SCRATCH:=$ABYSS_VM_HOME/abyss-scratch.qcow2}"
: "${ABYSS_SCRATCH_SIZE:=12G}"

# SSH
: "${ABYSS_SSH_KEY:=$ABYSS_VM_HOME/id_abyss}"
: "${ABYSS_SSH_PORT:=2222}"
: "${ABYSS_SSH_USER:=build}"
: "${ABYSS_HOSTNAME:=abyss-swift-build}"

# QEMU resources
: "${ABYSS_CPUS:=8}"
: "${ABYSS_MEM:=16G}"

# Where a VM runs. `qemu` is here, on this host's KVM, reached on a
# forwarded localhost port. `bhyve` is on the FreeBSD build box
# (ABYSS_BHYVE_HOST, the ssh alias AbyssBSD-Rust uses too), bridged onto the
# LAN: the guest's address comes from DHCP and run.sh records it from the
# serial log. The box has 20 threads and 128 GB, so its guests get more than
# this host can spare. riscv64 has no bhyve: the rv64 guest is qemu.
# The builder and the build guest moved to bhyve on 2026-10-30
# (bhyve-migrate.sh). The build guest's qcow2 stays here for --full, which
# needs nested virtualization (README): ABYSS_VMM=qemu picks it.
case "$ABYSS_VM_ROLE" in
  build|builder) : "${ABYSS_VMM:=bhyve}" ;;
  *)             : "${ABYSS_VMM:=qemu}" ;;
esac
if [ "$ABYSS_VMM" = bhyve ]; then
  : "${ABYSS_BHYVE_HOST:=abyss-build}"
  : "${ABYSS_BHYVE_HOME:=abyssbsd-vm}"        # on the box, under its home
  _disk=$(basename "$ABYSS_DISK"); _disk=${_disk%.qcow2}.raw
  : "${ABYSS_BHYVE_DISK:=$ABYSS_BHYVE_HOME/$_disk}"
  # A fixed MAC per role, in bhyve's OUI, so the router's lease stays put.
  case "$ABYSS_VM_ROLE" in
    build)   : "${ABYSS_BHYVE_MAC:=58:9c:fc:ab:00:01}" "${ABYSS_BHYVE_TAP:=tap51}"
             : "${ABYSS_BHYVE_CPUS:=8}" "${ABYSS_BHYVE_MEM:=16G}" ;;
    builder) : "${ABYSS_BHYVE_MAC:=58:9c:fc:ab:00:02}" "${ABYSS_BHYVE_TAP:=tap52}"
             : "${ABYSS_BHYVE_CPUS:=16}" "${ABYSS_BHYVE_MEM:=48G}" ;;
    *) echo "config.sh: no bhyve for ABYSS_VM_ROLE=$ABYSS_VM_ROLE" >&2; exit 2 ;;
  esac
  ABYSS_SSH_PORT=22
  _ipfile=$ABYSS_VM_HOME/ip$_role$_suffix
  if [ -z "${ABYSS_SSH_HOST:-}" ] && [ -f "$_ipfile" ]; then
    ABYSS_SSH_HOST=$(cat "$_ipfile")
  fi
fi
# The guest's address as ssh sees it.
: "${ABYSS_SSH_HOST:=127.0.0.1}"

# Source location inside the guest: the desktop only, where it sits in the
# monorepo. The rest of the monorepo (the FreeBSD fork, drm-kmod) is not synced.
: "${ABYSS_GUEST_SRC:=/home/${ABYSS_SSH_USER}/AbyssBSD/desktop}"

# Where the FreeBSD swift6 port puts its toolchain. It is deliberately NOT on
# the default PATH (so lang/swift510 and lang/swift6 can coexist), and a
# non-interactive `ssh host 'cmd'` reads no profile — so anything scripted must
# say where Swift lives rather than assume it.
: "${ABYSS_GUEST_SWIFT_BIN:=/usr/local/swift6/bin}"

abyss_ssh_opts() {
  # Key-only: never fall back to password/keyboard-interactive (no GUI askpass
  # popup, fails fast while the guest is still provisioning).
  printf '%s' "-i $ABYSS_SSH_KEY -p $ABYSS_SSH_PORT \
-o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o BatchMode=yes \
-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
}
