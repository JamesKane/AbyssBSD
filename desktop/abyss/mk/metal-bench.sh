#!/bin/sh
# Measure C2 and C6 on the bring-up machine (PHASE13 P13.8, HANDOFF §2.118).
#
# The harness proves C2 and C6 headless; this asks the hardware. It builds the
# test clients in the build VM (the same FreeBSD as the machine, so they run
# there as they are), puts them on the machine over ssh, and runs one of:
#
#   abyss/mk/metal-bench.sh c2 [--no-adversaries]
#       undertow alone on DRM, 1800 frames at 60 Hz, a healthy window and C2's
#       eleven adversaries (from 6 s in, after the warm-up); undertow's own
#       summary: missed, commits refused, present events delivered late.
#       Stops the live session first, and starts it again after.
#   abyss/mk/metal-bench.sh c6 [--no-adversaries]
#       in the live session: twelve windows on four islands, the adversaries,
#       50 island switches by a virtual keyboard at jittered phases; undertow's
#       island-commit samples, as frames from key to vblank.
#
# A diagnostic for a person, like metal.sh — not part of the gate, which stays
# hermetic. Needs a developer medium (`live-image.sh --ssh-key`) and
# ABYSS_METAL_HOST.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
. "$root/abyss/vm/config.sh"
mode=${1:-}; shift || true
adv=1; [ "${1:-}" = --no-adversaries ] && adv=0
case "$mode" in c2|c6) ;; *) echo "usage: metal-bench.sh c2|c6 [--no-adversaries]" >&2; exit 2 ;; esac
host="${ABYSS_METAL_HOST:?set ABYSS_METAL_HOST to the medium's address}"
box() { ssh -i "${ABYSS_METAL_KEY:-$ABYSS_VM_HOME/id_metal}" -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$host" "$@"; }
guest() { ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@127.0.0.1" "$@"; }

# The clients, built where the machine's twin is.
guest "sh -s" <<EOF
set -e; cd $ABYSS_GUEST_SRC; T=/tmp/metalbench; rm -rf \$T; mkdir -p \$T
protos=\$(pkg-config --variable=pkgdatadir wayland-protocols)
wayland-scanner client-header "\$protos/staging/ext-session-lock/ext-session-lock-v1.xml" \$T/ext-session-lock-proto.h
wayland-scanner private-code  "\$protos/staging/ext-session-lock/ext-session-lock-v1.xml" \$T/ext-session-lock-proto.c
wayland-scanner client-header abyss/tests/virtual-keyboard-unstable-v1.xml \$T/vkeyboard-proto.h
wayland-scanner private-code  abyss/tests/virtual-keyboard-unstable-v1.xml \$T/vkeyboard-proto.c
cc -I\$T abyss/tests/vkeyboard.c \$T/vkeyboard-proto.c \$(pkg-config --cflags --libs wayland-client xkbcommon) -o \$T/vkeyboard
cc -I\$T -Ide/cwayland/include abyss/tests/lockclient.c de/cabyssprotocols/xdg-shell-protocol.c \$T/ext-session-lock-proto.c \$(pkg-config --cflags --libs wayland-client) -o \$T/lockclient
cc -Ide/cwayland/include abyss/tests/adversary.c de/cabyssprotocols/xdg-shell-protocol.c \$(pkg-config --cflags --libs wayland-client) -o \$T/adversary
EOF
guest "tar -cf - -C /tmp/metalbench vkeyboard lockclient adversary" < /dev/null \
  | box 'rm -rf /tmp/metalbench && mkdir -p /tmp/metalbench && tar -xpf - -C /tmp/metalbench && chmod -R a+rx /tmp/metalbench'

# What runs on the machine, as the live account.
box 'cat > /tmp/metalbench/run.sh; chmod a+rx /tmp/metalbench/run.sh' <<'EOF'
#!/bin/sh
set -u
mode=$1 adv=$2
export XDG_RUNTIME_DIR=/var/run/abyss-abyss
T=$(mktemp -d /tmp/metalbench-run.XXXXXX); cd $T; mkfifo hold; exec 5<>hold; : > pids
B=/tmp/metalbench
loose() {
  [ "$adv" = 1 ] || return 0
  for n in 1 2 3 4 5 6 7 8; do $B/adversary hard 0 > /dev/null 2>&1 & echo $! >> pids; done
  $B/adversary zombie > /dev/null 2>&1 & echo $! >> pids
  $B/adversary deaf > /dev/null 2>&1 & echo $! >> pids
  $B/adversary churn 0 > /dev/null 2>&1 & echo $! >> pids
}
if [ "$mode" = c2 ]; then
  /usr/local/bin/undertow run --hz 60 --frames 1800 --backend auto --width 1024 --height 768 \
      --socket metalbench --config-dir $T > ut.out 2> ut.err & ut=$!
  i=0; while ! grep -q '^WAYLAND_DISPLAY=' ut.out 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  export WAYLAND_DISPLAY=metalbench
  $B/lockclient window ff336699 org.abyssbsd.healthy < hold > /dev/null 2>&1 & echo $! >> pids
  sleep 6; loose
  wait $ut
  grep -E '^(missed=|commits-refused=|present-delivery|wake-late-p99)' ut.out
else
  export WAYLAND_DISPLAY=abyss-live-0
  mkfifo vk; $B/vkeyboard < vk > vk.log 2>&1 & echo $! >> pids; exec 4>vk
  i=0; while ! grep -q ready vk.log && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  for island in 1 2 3 4; do
    printf 'c 4 %s\n' $((island + 1)) >&4; sleep 0.4
    for k in 1 2 3; do $B/lockclient window ff336699 org.abyssbsd.c6-$island-$k < hold > /dev/null 2>&1 & echo $! >> pids; done
    sleep 0.6
  done
  loose; sleep 1
  before=$(grep -c island-commit /var/log/abyss-live.log)
  awk 'BEGIN { srand(13); for (i = 0; i < 50; i++) printf "%.3f\n", 0.09 + rand() * 0.2 }' > plan
  last=4
  while read -r pause; do n=$(( last % 4 + 1 )); sleep "$pause"; printf 'c 4 %s\n' $((n + 1)) >&4; last=$n; done < plan
  sleep 1
  grep island-commit /var/log/abyss-live.log | tail -n +$((before + 1)) \
    | awk '{ split($3, f, "="); split($4, u, "="); fr[f[2]]++; n++; t += u[2]; if (u[2] > mx) mx = u[2] }
           END { printf "c6 switches=%d", n; for (k = 1; k <= 9; k++) if (fr[k]) printf "  %d frame(s): %d", k, fr[k];
                 printf "  mean %.1f ms, worst %.1f ms\n", t / n / 1000, mx / 1000 }'
fi
while read -r p; do kill -9 "$p" 2>/dev/null; done < pids
cd /; rm -rf "$T"
EOF

if [ "$mode" = c2 ]; then
  ABYSS_METAL_HOST=$host sh "$root/abyss/mk/metal.sh" stop > /dev/null
  box "su -m abyss -c 'sh /tmp/metalbench/run.sh c2 $adv'"
  ABYSS_METAL_HOST=$host sh "$root/abyss/mk/metal.sh" start > /dev/null
else
  box "su -m abyss -c 'sh /tmp/metalbench/run.sh c6 $adv'"
fi
