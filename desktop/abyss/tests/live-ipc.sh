#!/bin/sh
# AbyssBSD Swift DE — the control plane, between two real processes (P3.5).
#
# The unit tests prove the codec and prove SCM_RIGHTS over a socketpair. This
# proves the thing the component exists for: a *separate process* connects to a
# service's socket, hands over a **file descriptor**, and the service reads the
# sender's bytes through it. That is the seam a compositor will use to pass an
# shm/dmabuf handle with no pixel copies.
#
# Needs no compositor — unlike live-sway.sh, this is pure POSIX, so it runs
# anywhere the package builds.
#
# Usage: abyss/tests/live-ipc.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

probe="$root/.build/debug/ipcprobe"
[ -x "$probe" ] || swift build
[ -x "$probe" ] || { echo "FAIL: no ipcprobe binary at $probe"; exit 1; }

# Deliberately under /tmp rather than $TMPDIR: a unix socket path must fit in
# sockaddr_un.sun_path (108 bytes on Linux, 104 on FreeBSD), and a CI $TMPDIR
# can easily be longer than that on its own. CurrentIPC refuses to truncate —
# it would silently bind a different socket — so it errors instead, and this is
# the kind of environment that would trip it.
rundir=$(mktemp -d /tmp/abyss-ipc.XXXXXX)
export ABYSS_RUNTIME_DIR="$rundir"
srv_log="$rundir/server.log"
cli_log="$rundir/client.log"
secret="the pixels never moved $$"

cleanup() {
  [ -n "${srv_pid:-}" ] && kill "$srv_pid" 2>/dev/null || true
  rm -rf "$rundir"
}
trap cleanup EXIT

"$probe" serve probe > "$srv_log" 2>&1 &
srv_pid=$!

# Wait for the socket to exist rather than sleeping a guess.
i=0
while [ $i -lt 50 ]; do
  [ -S "$rundir/probe.sock" ] && break
  sleep 0.1
  i=$((i + 1))
done
[ -S "$rundir/probe.sock" ] \
  || { echo "FAIL: the service never bound its socket"; cat "$srv_log"; exit 1; }
echo "service listening on $rundir/probe.sock"

"$probe" send probe "$secret" > "$cli_log" 2>&1 \
  || { echo "FAIL: the client errored"; cat "$cli_log" "$srv_log"; exit 1; }

# Give the service a moment to finish writing its log and exit.
wait "$srv_pid" 2>/dev/null || true
srv_pid=""

# 1. The service read the sender's bytes *through the passed descriptor*.
grep -q "got fd, contents: $secret" "$srv_log" \
  || { echo "FAIL: the service didn't read the sender's file through the fd"
       echo "--- server ---"; cat "$srv_log"; exit 1; }
echo "ok: the descriptor crossed the process boundary and carried its contents"

# 2. The reply came back through the same socket, with the right length.
grep -q "reply ok, echo: $secret" "$cli_log" \
  || { echo "FAIL: the client didn't get its reply"; cat "$cli_log"; exit 1; }
len=$(printf '%s' "$secret" | wc -c | tr -d ' ')
grep -q "reply bytes: $len" "$cli_log" \
  || { echo "FAIL: reply byte count wrong (wanted $len)"; cat "$cli_log"; exit 1; }
echo "ok: request -> reply round-tripped ($len bytes echoed)"

# 3. The service unlinked its socket on the way out, so a restart is clean.
[ -e "$rundir/probe.sock" ] \
  && { echo "FAIL: the socket outlived the service"; exit 1; }
echo "ok: the service removed its socket on exit"

echo "all green (control plane, two processes)."
