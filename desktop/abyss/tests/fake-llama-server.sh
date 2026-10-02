#!/bin/sh
# A stand-in for llama.cpp's llama-server (PHASE18 P18.7b), for live-model.sh:
# it records its argv, listens on the unix socket given by --host (as the real
# one does when the address ends in .sock), and answers every request — /health
# included — with the canned HTTP reply in $FAKE_LLAMA_REPLY, one connection
# at a time through nc(1). FAKE_LLAMA_DIE=1 makes it fail as a bad model does,
# before it is ready. On SIGTERM it notes that it was stopped.
echo "$@" > "$FAKE_LLAMA_STATE.argv"
echo $$ > "$FAKE_LLAMA_STATE.pid"
sock=
while [ $# -gt 0 ]; do case $1 in --host) sock=$2; shift ;; esac; shift; done
if [ -n "${FAKE_LLAMA_DIE:-}" ]; then echo "llama_model_load: error loading model: (fake) not a GGUF"; exit 3; fi
nc_pid=
trap 'echo stopped > "$FAKE_LLAMA_STATE.stopped"; [ -n "$nc_pid" ] && kill $nc_pid 2>/dev/null; exit 0' TERM
if nc -h 2>&1 | grep -q Ncat; then o=; else o=-N; fi
while :; do
    rm -f "$sock"
    # In the background and waited for, so SIGTERM is handled at once.
    nc -lU $o "$sock" < "$FAKE_LLAMA_REPLY" > /dev/null 2>&1 &
    nc_pid=$!
    wait $nc_pid || true
done
