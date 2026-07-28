#!/bin/sh
# Push the AbyssBSD source tree into the VM via rsync over SSH.
# Reproducible and decoupled: edit on the host, build in the guest.
# Excludes git internals and build output to keep transfers fast.
set -eu
. "$(dirname "$0")/config.sh"

echo "[sync] $ABYSS_REPO/  ->  $ABYSS_SSH_USER@vm:$ABYSS_GUEST_SRC"
# shellcheck disable=SC2046
rsync -a --delete \
  --exclude '.git/' \
  --exclude 'obj/' \
  --exclude '.build/' \
  --exclude 'abyss-vm/' \
  --exclude 'abyss-swift-vm/' \
  -e "ssh $(abyss_ssh_opts)" \
  "$ABYSS_REPO/" "$ABYSS_SSH_USER@127.0.0.1:$ABYSS_GUEST_SRC/"
echo "[sync] done"
