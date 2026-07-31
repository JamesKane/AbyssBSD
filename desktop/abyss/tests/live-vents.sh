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
  echo "all green (stubs behave)."
  exit 0
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

echo "all green (the hardware bridges read the real machine)."
