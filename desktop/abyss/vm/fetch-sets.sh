#!/bin/sh
# Put the guest's FreeBSD version's distribution sets where the tests look:
# base.txz and kernel.txz in ~/dist (what the medium carries and the installer
# extracts — live-image.sh, live-install.sh, live-medium.sh), and src.txz
# unpacked at /usr/src (the wtap lab builds against /usr/src/sys — PHASE14 §4.2).
#
# The sets are downloaded once to the host ($ABYSS_SETS_DIR) and verified
# against config.sh's pinned SHA256. That matters on 16-CURRENT: the snapshot
# directory only ever holds the newest build, so "download it again later"
# would silently fetch a different system from the one the image was made of.
#
# Idempotent: a verified host copy is not fetched again, and the guest copies
# are replaced only when they differ.
set -eu
. "$(dirname "$0")/config.sh"

mkdir -p "$ABYSS_SETS_DIR"
for set in base.txz kernel.txz src.txz; do
  f="$ABYSS_SETS_DIR/$set"
  want=$(printf '%s\n' $ABYSS_SETS_SHA256 | sed -n "s/^$set=//p")
  if [ -s "$f" ] && { [ -z "$want" ] || [ "$(sha256sum "$f" | awk '{print $1}')" = "$want" ]; }; then
    echo "[sets] $set already here"
    continue
  fi
  echo "[sets] downloading $ABYSS_SETS_URL/$set"
  curl -L --fail --retry 3 -o "$f.part" "$ABYSS_SETS_URL/$set"
  if [ -n "$want" ]; then
    got=$(sha256sum "$f.part" | awk '{print $1}')
    if [ "$got" != "$want" ]; then
      echo "[sets] CHECKSUM MISMATCH for $set — the snapshot has moved on?" >&2
      echo "  expected: $want" >&2
      echo "  got:      $got" >&2
      rm -f "$f.part"
      exit 1
    fi
    echo "[sets] $set checksum OK"
  else
    echo "[sets] $set: no pinned checksum for $ABYSS_FBSD_VERSION, not verified"
  fi
  mv "$f.part" "$f"
done

# shellcheck disable=SC2046
ssh_run() { ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@127.0.0.1" "$@"; }
ssh_run 'mkdir -p ~/dist'
echo "[sets] base.txz kernel.txz -> guest ~/dist"
# shellcheck disable=SC2046
rsync -a -e "ssh $(abyss_ssh_opts)" "$ABYSS_SETS_DIR/base.txz" "$ABYSS_SETS_DIR/kernel.txz" \
  "$ABYSS_SSH_USER@127.0.0.1:dist/"
# src.txz unpacks to usr/src, so extracting at / puts it at /usr/src. Only when
# the guest's copy is a different tarball, because it takes a minute.
sum=$(sha256sum "$ABYSS_SETS_DIR/src.txz" | awk '{print $1}')
if [ "$(ssh_run 'cat /usr/src/.abyss-src-sha256 2>/dev/null' || true)" != "$sum" ]; then
  echo "[sets] src.txz -> guest /usr/src"
  # shellcheck disable=SC2046
  rsync -a -e "ssh $(abyss_ssh_opts)" "$ABYSS_SETS_DIR/src.txz" "$ABYSS_SSH_USER@127.0.0.1:/tmp/src.txz"
  # /usr/src is its own ZFS dataset on these images: empty it, never remove it.
  ssh_run "sudo find /usr/src -mindepth 1 -delete && sudo tar -xf /tmp/src.txz -C / && rm /tmp/src.txz \
    && echo $sum | sudo tee /usr/src/.abyss-src-sha256 >/dev/null"
else
  echo "[sets] guest /usr/src is already this src.txz"
fi
echo "[sets] done ($ABYSS_FBSD_VERSION)"
