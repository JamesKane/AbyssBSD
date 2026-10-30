#!/bin/sh
# Push the AbyssBSD source tree into the VM via rsync over SSH.
# Reproducible and decoupled: edit on the host, build in the guest.
# Excludes git internals and build output to keep transfers fast.
set -eu
. "$(dirname "$0")/config.sh"

echo "[sync] $ABYSS_SYNC_ROOT/  ->  $ABYSS_SSH_USER@vm:$ABYSS_GUEST_SRC"
# rsync creates the last directory of the target, never its parents, and the
# guest copy sits two deep (~/AbyssBSD/desktop) since the monorepo move.
# shellcheck disable=SC2046
ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@$ABYSS_SSH_HOST" "mkdir -p '$ABYSS_GUEST_SRC'"
# shellcheck disable=SC2046
rsync -a --delete \
  --exclude '.git/' \
  --exclude '.git' \
  --exclude 'obj/' \
  --exclude '.build/' \
  --exclude 'abyss-vm/' \
  --exclude 'abyss-swift-vm/' \
  -e "ssh $(abyss_ssh_opts)" \
  "$ABYSS_SYNC_ROOT/" "$ABYSS_SSH_USER@$ABYSS_SSH_HOST:$ABYSS_GUEST_SRC/"
echo "[sync] done"
