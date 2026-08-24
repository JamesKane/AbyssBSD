# shellcheck shell=sh
# Shared config for the AbyssBSD build VM. Override any var via the environment.
#
# Large VM artifacts (images, disks, seed) live OUTSIDE the git repo so they
# never bloat history.

# Repo root (this file lives at $REPO/abyss/vm/config.sh). The vm/ scripts get
# this right from $0; anything else that sources this file (abyss/tests/run.sh
# --vm) sets ABYSS_VM_DIR first, since $0 would then point somewhere else.
: "${ABYSS_VM_DIR:=$(cd "$(dirname "$0")" && pwd)}"
ABYSS_REPO="$(cd "$ABYSS_VM_DIR/../.." && pwd)"

# Where VM artifacts are stored (sibling of the repo by default).
# A Swift-DE-specific home so we do NOT clobber the sibling Rust project's
# ../abyss-vm. Set ABYSS_VM_HOME=../abyss-vm to reuse that provisioned VM.
: "${ABYSS_VM_HOME:=$(cd "$ABYSS_REPO/.." && pwd)/abyss-swift-vm}"

# FreeBSD image
: "${ABYSS_FBSD_VERSION:=15.0-RELEASE}"
: "${ABYSS_FBSD_IMG:=FreeBSD-${ABYSS_FBSD_VERSION}-amd64-BASIC-CLOUDINIT-zfs.qcow2}"
: "${ABYSS_FBSD_URL:=https://download.freebsd.org/ftp/releases/VM-IMAGES/${ABYSS_FBSD_VERSION}/amd64/Latest/${ABYSS_FBSD_IMG}.xz}"
# SHA512 of the .xz (from the mirror's CHECKSUM.SHA512); empty = skip verify
: "${ABYSS_FBSD_SHA512:=e863bd451ca1bf0529643b4d6380805fe8464a26f4ab8e0ae0adfddd2e68376546dbe2ebee3ba3e44f1ff9ee853921b866524e442b762f7ff5c1cdc07f6dab3e}"

# Disk / paths
: "${ABYSS_IMAGES:=$ABYSS_VM_HOME/images}"
: "${ABYSS_BASE_QCOW:=$ABYSS_IMAGES/$ABYSS_FBSD_IMG}"          # pristine, never booted
: "${ABYSS_DISK:=$ABYSS_VM_HOME/abyss-build.qcow2}"           # working overlay disk
: "${ABYSS_DISK_SIZE:=80G}"
: "${ABYSS_SEED:=$ABYSS_VM_HOME/seed.iso}"                    # cloud-init cidata (Rock Ridge ISO)
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

# Source location inside the guest
: "${ABYSS_GUEST_SRC:=/home/${ABYSS_SSH_USER}/AbyssBSD-swiftDE}"

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
