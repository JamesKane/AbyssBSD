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

# Disk / paths
: "${ABYSS_IMAGES:=$ABYSS_VM_HOME/images}"
: "${ABYSS_BASE_QCOW:=$ABYSS_IMAGES/$ABYSS_FBSD_IMG}"          # pristine, never booted
: "${ABYSS_DISK:=$ABYSS_VM_HOME/abyss-build$_suffix.qcow2}"   # working overlay disk
: "${ABYSS_DISK_SIZE:=80G}"
: "${ABYSS_SEED:=$ABYSS_VM_HOME/seed$_suffix.iso}"            # cloud-init cidata (Rock Ridge ISO)
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
