#!/bin/sh
# Build (and by default test) the repo inside the FreeBSD VM.
#
# The dev loop in one command: rsync the host tree into the guest, then run
# cargo there.
#
# Usage:
#   ./build.sh                 # sync + cargo build + cargo test
#   ./build.sh --no-test       # sync + cargo build
#   ./build.sh --no-sync       # build what is already in the guest
#   ./build.sh -- <args>       # pass extra args to `cargo build` (e.g. --release)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/config.sh"

do_sync=1
do_test=1
extra=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-sync) do_sync=0 ;;
    --no-test) do_test=0 ;;
    --) shift; extra="$*"; break ;;
    *) echo "usage: build.sh [--no-sync] [--no-test] [-- <cargo build args>]" >&2; exit 2 ;;
  esac
  shift
done

[ "$do_sync" -eq 1 ] && "$here/sync.sh"

# shellcheck disable=SC2046
run() { ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@$ABYSS_SSH_HOST" "$@"; }

# **The status of the build, not of the filter** (P11.10). Piped straight
# into a filter, a failed build's exit status was the filter's: "[build] done"
# was printed over a compile error, and everything after it ran against the
# binaries the last good build left. So the output goes to a file, and the
# build's status is the command's.
echo "[build] cargo build ${extra}"
run "cd $ABYSS_GUEST_SRC && cargo build --workspace --bins --examples $extra > /tmp/abyss-cargo.log 2>&1; rc=\$?; tail -3 /tmp/abyss-cargo.log; exit \$rc" \
  || { echo "[build] FAILED: cargo build in the guest" >&2; exit 1; }

if [ "$do_test" -eq 1 ]; then
  echo "[build] cargo test"
  run "cd $ABYSS_GUEST_SRC && cargo test --workspace > /tmp/abyss-cargo-test.log 2>&1; rc=\$?; tail -3 /tmp/abyss-cargo-test.log; exit \$rc" \
    || { echo "[build] FAILED: cargo test in the guest" >&2; exit 1; }
fi
echo "[build] done"
