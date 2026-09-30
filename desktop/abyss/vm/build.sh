#!/bin/sh
# Build (and by default test) the repo inside the FreeBSD VM.
#
# This is the Phase-3 dev loop in one command: rsync the host tree into the
# guest, then run swift there. Swift lives off PATH on FreeBSD
# (ABYSS_GUEST_SWIFT_BIN — see config.sh), and a non-interactive
# `ssh host 'cmd'` reads no profile, so the PATH is set explicitly here rather
# than assumed.
#
# Usage:
#   ./build.sh                 # sync + swift build + swift test
#   ./build.sh --no-test       # sync + swift build
#   ./build.sh --no-sync       # build what is already in the guest
#   ./build.sh -- <args>       # pass extra args to `swift build` (e.g. -c release)
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
    *) echo "usage: build.sh [--no-sync] [--no-test] [-- <swift build args>]" >&2; exit 2 ;;
  esac
  shift
done

[ "$do_sync" -eq 1 ] && "$here/sync.sh"

# shellcheck disable=SC2046
run() { ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@127.0.0.1" "$@"; }

# FreeBSD's cairo.pc carries -D_THREAD_SAFE, which SwiftPM refuses to forward
# ("prohibited flag(s)") and drops. It is benign for us and would otherwise be
# the only thing on stderr, so it is filtered out of the transcript here.
filter='grep -v "^warning: prohibited flag"'

# **The status of swift, not of the filter** (P11.10). Piped straight into
# the filter, a failed build's exit status was the grep's: "[build] done" was
# printed over a compile error, and everything after it — goldens, tests in
# the guest — ran against the binaries the last good build left. So swift's
# output goes to a file, is filtered from there, and swift's status is the
# command's.
echo "[build] swift build ${extra}"
run "export PATH=$ABYSS_GUEST_SWIFT_BIN:\$PATH; cd $ABYSS_GUEST_SRC && swift build $extra > /tmp/abyss-build.log 2>&1; rc=\$?; $filter < /tmp/abyss-build.log; exit \$rc" \
  || { echo "[build] FAILED: swift build in the guest" >&2; exit 1; }

if [ "$do_test" -eq 1 ]; then
  echo "[build] swift test"
  run "export PATH=$ABYSS_GUEST_SWIFT_BIN:\$PATH; cd $ABYSS_GUEST_SRC && swift test > /tmp/abyss-test.log 2>&1; rc=\$?; $filter < /tmp/abyss-test.log | tail -5; exit \$rc" \
    || { echo "[build] FAILED: swift test in the guest" >&2; exit 1; }
fi
echo "[build] done"
