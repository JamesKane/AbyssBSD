#!/bin/sh
# Download (if needed), verify, and decompress the FreeBSD base qcow2.
# Idempotent: re-running with the pristine qcow2 already present is a no-op.
set -eu
. "$(dirname "$0")/config.sh"

mkdir -p "$ABYSS_IMAGES"
xz="$ABYSS_IMAGES/$ABYSS_FBSD_IMG.xz"

if [ -f "$ABYSS_BASE_QCOW" ]; then
  echo "[fetch] base image already present: $ABYSS_BASE_QCOW"
  exit 0
fi

if [ ! -f "$xz" ]; then
  echo "[fetch] downloading $ABYSS_FBSD_URL"
  curl -L --fail --retry 3 -C - -o "$xz" "$ABYSS_FBSD_URL"
fi

if [ -n "$ABYSS_FBSD_SHA512" ]; then
  echo "[fetch] verifying SHA512"
  got=$(sha512sum "$xz" | awk '{print $1}')
  if [ "$got" != "$ABYSS_FBSD_SHA512" ]; then
    echo "[fetch] CHECKSUM MISMATCH" >&2
    echo "  expected: $ABYSS_FBSD_SHA512" >&2
    echo "  got:      $got" >&2
    exit 1
  fi
  echo "[fetch] checksum OK"
fi

echo "[fetch] decompressing -> $ABYSS_BASE_QCOW"
xz -dkc "$xz" > "$ABYSS_BASE_QCOW"
echo "[fetch] done"
