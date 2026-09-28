#!/bin/sh
# AbyssBSD Swift DE — the hardware bridges, against the real machine (P3.7).
#
# The unit tests cover the parsing; this covers the kernel. On FreeBSD it reads
# real sysctls and watches **real devd events**, triggered here by creating and
# destroying a malloc-backed md(4) disk — a device arriving and leaving, which
# is exactly what the desktop wants to know about.
#
# On Linux the bridges are stubs by construction, so the script asserts that
# they *say so* rather than inventing readings, and stops there. That is the
# honest half of the contract: a facility that isn't there must report absent.
#
# Usage: abyss/tests/live-vents.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
ctl="$root/.build/debug/ventsctl"
[ -x "$ctl" ] || swift build
[ -x "$ctl" ] || { echo "FAIL: no ventsctl binary"; exit 1; }

os=$(uname -s)

# ---------------------------------------------------------------- sysctl

if [ "$os" != "FreeBSD" ]; then
  echo "== $os: the bridges are stubs =="
  # Exit 2 is "no such facility"; anything else would mean we invented an answer.
  if "$ctl" sysctl kern.ostype >/dev/null 2>&1; then
    echo "FAIL: sysctl answered on $os, where there is no sysctl"; exit 1
  fi
  rc=0; "$ctl" sysctl kern.ostype >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: expected exit 2 (unavailable), got $rc"; exit 1; }
  echo "ok: sysctl reports unavailable rather than guessing"
  rc=0; "$ctl" battery >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: battery should be unavailable, got $rc"; exit 1; }
  echo "ok: battery reports unavailable"
  # The network is NOT a stub (PHASE14 P14.4): getifaddrs and rtnetlink are
  # here, so it must agree with Linux's own tools.
  if command -v ip >/dev/null 2>&1; then
    net=$("$ctl" network)
    want=$(ip -4 -o addr | awk '{print $2, $4}' | sort)
    got=$(printf '%s\n' "$net" | awk '$1 == "interface" && $7 != "none" {
            n = split($7, a, ","); for (i = 1; i <= n; i++) print $2, a[i] }' | sort)
    [ "$got" = "$want" ] || { echo "FAIL: ventsctl network's addresses are not ip's:"; echo "$got"; echo "vs"; echo "$want"; exit 1; }
    r=$(ip route show default | awk '{print $3, $5; exit}')
    [ -z "$r" ] || printf '%s\n' "$net" | grep -qx "router ${r% *} via ${r#* }" \
      || { echo "FAIL: the router is not ip's ($r): $net"; exit 1; }
    echo "ok: the network agrees with ip(8) — every IPv4 address, and the default router"
  fi
  # Sound (P14.6) is OSS, and there is none here: say so, invent nothing.
  [ "$("$ctl" sound)" = "no sound devices" ] || { echo "FAIL: ventsctl sound found OSS devices on $os"; exit 1; }
  rc=0; "$ctl" sound set 0 vol 50 >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: setting a level on $os did not fail (rc=$rc)"; exit 1; }
  echo "ok: sound says there are no devices, and a set fails, rather than reaching for ALSA"
  echo "all green (stubs behave, and the network is real)."
  exit 0
fi

# ----------------------------------------------------------------- sound
# The guest's snd_dummy is a real pcm device with a real mixer (PHASE14 §4.3):
# ventsctl must agree with mixer(8) and /dev/sndstat, set what mixer(8) then
# reads back, and see a player that has /dev/dsp open, with its own volume.
echo "== sound =="
sudo kldload -n snd_dummy 2>/dev/null || true
if [ -e /dev/mixer0 ]; then
  snd=$("$ctl" sound)
  dunit=$(sysctl -n hw.snd.default_unit)
  printf '%s\n' "$snd" | grep -qx "default pcm$dunit" || { echo "FAIL: the default is not hw.snd.default_unit ($dunit): $snd"; exit 1; }
  # `mixer -o` is mixer(8)'s machine format: `pcm.volume=0.75:0.75`, `rec.mute=on`.
  mixer -f /dev/mixer0 -o | sed -n 's/^\([a-z0-9]*\)\.volume=\([0-9.]*\):\([0-9.]*\)$/\1 \2 \3/p' > /tmp/abyss-mixer.$$
  [ -s /tmp/abyss-mixer.$$ ] || { echo "FAIL: mixer -o gave no volumes"; exit 1; }
  while read -r name l r; do
    l=$(awk -v v="$l" 'BEGIN{printf "%d", v * 100 + 0.5}'); r=$(awk -v v="$r" 'BEGIN{printf "%d", v * 100 + 0.5}')
    printf '%s\n' "$snd" | grep -q "^  control $name $l:$r" || { rm -f /tmp/abyss-mixer.$$; echo "FAIL: $name is $l:$r to mixer(8): $snd"; exit 1; }
  done < /tmp/abyss-mixer.$$
  rm -f /tmp/abyss-mixer.$$
  echo "ok: every control agrees with mixer(8), and the default with hw.snd.default_unit"
  before=$(mixer -f /dev/mixer0 -o | sed -n 's/^pcm\.volume=\([0-9.]*\):.*/\1/p')
  "$ctl" sound set 0 pcm 33 >/dev/null || { echo "FAIL: could not set pcm"; exit 1; }
  "$ctl" sound mute 0 rec on >/dev/null || { echo "FAIL: could not mute rec"; exit 1; }
  after=$(mixer -f /dev/mixer0 -o)
  "$ctl" sound set 0 pcm "$(awk -v v="$before" 'BEGIN{printf "%d", v * 100 + 0.5}')" >/dev/null
  "$ctl" sound mute 0 rec off >/dev/null
  printf '%s\n' "$after" | grep -qx 'pcm.volume=0.33:0.33' || { echo "FAIL: mixer(8) does not see pcm at 0.33:"; echo "$after"; exit 1; }
  printf '%s\n' "$after" | grep -qx 'rec.mute=on' || { echo "FAIL: mixer(8) does not see rec muted:"; echo "$after"; exit 1; }
  printf '%s\n' "$after" | grep -q '^vol.volume=0.33' && { echo "FAIL: setting pcm moved vol (libmixer's selected control):"; echo "$after"; exit 1; }
  echo "ok: a level and a mute set by an unprivileged user are what mixer(8) reads back — on the control named"
  # A player with /dev/dsp open, at a volume it set itself.
  pw=$(mktemp -d)
  cat > "$pw/p.c" <<'C'
#include <sys/soundcard.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
int main(void) {
    int fd = open("/dev/dsp", O_WRONLY), v = 37 | (37 << 8);
    if (fd < 0) return 1;
    ioctl(fd, SNDCTL_DSP_SETPLAYVOL, &v);
    char buf[4096] = {0};
    for (int i = 0; i < 400; i++) write(fd, buf, sizeof buf);
    return 0;
}
C
  cc -o "$pw/tuneplayer" "$pw/p.c" || { echo "FAIL: could not build the player"; exit 1; }
  "$pw/tuneplayer" & pp=$!
  sleep 0.5
  snd=$("$ctl" sound)
  kill "$pp" 2>/dev/null || true; wait "$pp" 2>/dev/null || true; rm -rf "$pw"
  printf '%s\n' "$snd" | grep -qx "  playing $pp tuneplayer 37:37" || { echo "FAIL: the player ($pp, 37) is not seen playing: $snd"; exit 1; }
  echo "ok: a process playing is seen by pid and name, at the volume it set for itself"
else
  echo "(no /dev/mixer0 even with snd_dummy — skipping sound)"
fi

echo "== sysctl =="
ostype=$("$ctl" sysctl kern.ostype) \
  || { echo "FAIL: could not read kern.ostype"; exit 1; }
[ "$ostype" = "FreeBSD" ] \
  || { echo "FAIL: kern.ostype is '$ostype', expected FreeBSD"; exit 1; }
ncpu=$("$ctl" sysctl hw.ncpu)
[ "$ncpu" -gt 0 ] 2>/dev/null \
  || { echo "FAIL: hw.ncpu is '$ncpu'"; exit 1; }
# Cross-check against the system's own sysctl(8): the bridge must agree with it.
sys_ncpu=$(sysctl -n hw.ncpu)
[ "$ncpu" = "$sys_ncpu" ] \
  || { echo "FAIL: we read hw.ncpu=$ncpu, sysctl(8) says $sys_ncpu"; exit 1; }
echo "ok: kern.ostype=$ostype hw.ncpu=$ncpu (agrees with sysctl(8))"

if "$ctl" sysctl abyss.no.such.sysctl >/dev/null 2>&1; then
  echo "FAIL: an unknown sysctl should not succeed"; exit 1
fi
echo "ok: an unknown sysctl is reported unavailable"

# ------------------------------------------------------------ volume/battery
# A VM has neither a mixer nor a battery. Absence must be reported as absence —
# the status items then hide, which is the behaviour worth pinning.

echo "== volume / battery =="
rc=0; "$ctl" volume >/dev/null 2>&1 || rc=$?
case "$rc" in
  0) echo "ok: a mixer is present — $("$ctl" volume)" ;;
  2) echo "ok: no mixer here, reported as unavailable (the item stays hidden)" ;;
  *) echo "FAIL: volume exited $rc"; exit 1 ;;
esac
rc=0; "$ctl" battery >/dev/null 2>&1 || rc=$?
case "$rc" in
  0) echo "ok: a battery is present — $("$ctl" battery)" ;;
  2) echo "ok: no battery here, reported as unavailable" ;;
  *) echo "FAIL: battery exited $rc"; exit 1 ;;
esac

# ---------------------------------------------------------------- devd

echo "== devd =="
[ -S /var/run/devd.pipe ] \
  || { echo "(devd isn't running — skipping)"; echo "all green (sysctl)."; exit 0; }

log=$(mktemp)
cleanup() {
  [ -n "${md:-}" ] && sudo mdconfig -d -u "${md#md}" 2>/dev/null || true
  rm -f "$log"
}
trap cleanup EXIT

"$ctl" devd 8 > "$log" 2>&1 &
watcher=$!
# Wait until the watcher has actually connected before making an event happen.
i=0
while [ $i -lt 40 ]; do
  grep -q "watching devd" "$log" && break
  sleep 0.1; i=$((i + 1))
done
grep -q "watching devd" "$log" \
  || { echo "FAIL: the watcher never connected"; cat "$log"; exit 1; }

# A real device arriving and leaving.
md=$(sudo mdconfig -a -t malloc -s 8m) \
  || { echo "(cannot create an md device — skipping the event half)"; kill $watcher 2>/dev/null; exit 0; }
echo "created $md"
sleep 1
sudo mdconfig -d -u "${md#md}"
md=""
wait $watcher 2>/dev/null || true

if ! grep -q "type=CREATE" "$log"; then
  echo "FAIL: no CREATE event seen from devd"; cat "$log"; exit 1
fi
if ! grep -q "type=DESTROY" "$log"; then
  echo "FAIL: no DESTROY event seen from devd"; cat "$log"; exit 1
fi
echo "ok: devd delivered the device's arrival and departure:"
grep -E "type=(CREATE|DESTROY)" "$log" | sed 's/^/    /' | head -4

echo "== the network =="
net=$("$ctl" network)
for ifn in $(ifconfig -l); do
  want=$(ifconfig "$ifn" inet 2>/dev/null | awk '/inet /{print $2}' | sort | tr '\n' ' ')
  got=$(printf '%s\n' "$net" | awk -v i="$ifn" '$1 == "interface" && $2 == i && $7 != "none" {
          n = split($7, a, ","); for (k = 1; k <= n; k++) { sub(/\/.*/, "", a[k]); print a[k] } }' | sort | tr '\n' ' ')
  [ "$got" = "$want" ] || { echo "FAIL: $ifn's addresses are '$got', ifconfig says '$want'"; exit 1; }
done
gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
[ -z "$gw" ] || printf '%s\n' "$net" | grep -q "^router $gw via " || { echo "FAIL: the router is not route(8)'s ($gw): $net"; exit 1; }
dns=$(awk '$1 == "nameserver" {print $2}' /etc/resolv.conf | tr '\n' ' ' | sed 's/ $//')
printf '%s\n' "$net" | grep -qx "dns ${dns:-none}" || { echo "FAIL: the name servers are not resolv.conf's ($dns): $net"; exit 1; }
echo "ok: the network agrees with ifconfig(8), route(8) and resolv.conf"

# **Live.** A change the kernel makes must reach a listener with no privilege.
netwait=$(mktemp)
"$ctl" network --wait 5 > "$netwait" 2>&1 &
waiter=$!
sleep 1
sudo ifconfig lo0 alias 127.0.0.77/32
wait $waiter 2>/dev/null || true
sudo ifconfig lo0 -alias 127.0.0.77
grep -qx changed "$netwait" || { echo "FAIL: the routing socket did not report the new address"; cat "$netwait"; exit 1; }
grep -q "127.0.0.77/32" "$netwait" || { echo "FAIL: the new address is not in the status read after the change"; cat "$netwait"; exit 1; }
rm -f "$netwait"
echo "ok: an address added by root reached an unprivileged watcher, and the status read after it shows it"

echo "all green (the hardware bridges read the real machine)."
