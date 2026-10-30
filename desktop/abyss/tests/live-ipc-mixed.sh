#!/bin/sh
# The control plane between Swift and Rust (docs/RUST.md R2, §3.3): the
# fixtures in abyss/tests/wire/current prove both halves pack and unpack the
# same bytes; this proves the framing and the descriptor between two real
# processes, each side either language. live-ipc.sh, four times: Swift and
# Rust ipcprobe as server and as client.
#
# Usage: abyss/tests/live-ipc-mixed.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
. "$root/abyss/common.sh"
cd "$root"
swift=$root/.build/debug/ipcprobe
rust=${CARGO_TARGET_DIR:-$root/target}/debug/ipcprobe
[ -x "$swift" ] || swift build --product ipcprobe
[ -x "$rust" ] || cargo build -q -p ipcprobe
for pair in "swift swift" "swift rust" "rust swift" "rust rust"; do
  set -- $pair
  eval s=\$$1 c=\$$2
  out=$(ABYSS_IPC_SERVER=$s ABYSS_IPC_CLIENT=$c sh "$root/abyss/tests/live-ipc.sh" 2>&1) \
    || { echo "FAIL: $1 server, $2 client:"; echo "$out"; exit 1; }
  echo "ok: $1 server, $2 client: $(echo "$out" | tail -1)"
done
echo "all green (the control plane, Swift and Rust, all four ways)."
