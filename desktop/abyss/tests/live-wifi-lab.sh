#!/bin/sh
# AbyssBSD Swift DE — the Wi-Fi lab works, and survives (PHASE14 P14.5).
#
# The harness for P14.5's join: two wtap(4) radios, hostapd (WPA2-PSK) on one,
# a station on the other. 15.0's wtap cannot do either mode, so there the lab
# adds upstream's (d4de0a69a92); FreeBSD main has it. Either way it adds our
# three teardown fixes, each of which was a kernel panic in this guest
# (abyss/tests/wtap/). Claims, three rounds of each:
#
#   1. the access point comes up, and a scan from the station finds it (RSN);
#   2. wpa_supplicant joins it: wpa_state=COMPLETED;
#   3. the lab tears down — station, access point, radios, the module — and
#      THE KERNEL IS STILL UP: the same boot, and no new crash dump. A panic
#      here reboots the guest and reads, from outside, like a hang (HANDOFF
#      §2.80), so this is asserted, not assumed.
#
# On Linux there is no wtap: said, not skipped silently.
#
# Usage: abyss/tests/live-wifi-lab.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
lab="$root/abyss/tests/wtap/lab.sh"
fail() { echo "FAIL: $1"; sh "$lab" down >/dev/null 2>&1 || true; exit 1; }

if [ "$(uname -s)" != FreeBSD ]; then
  echo "ok: (wtap is FreeBSD's; the guest runs the Wi-Fi lab)"
  echo "all green (nothing to simulate here)."
  exit 0
fi
[ -f /usr/src/sys/dev/wtap/if_wtap.c ] || fail "no /usr/src/sys — abyss/vm/fetch-sets.sh puts the guest's src.txz there (PHASE14 §4.2)"
sudo -n true 2>/dev/null || fail "the lab needs passwordless sudo"

boot=$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')
dumps() { ls /var/crash 2>/dev/null | grep -c '^vmcore\.[0-9]' || true; }
before=$(dumps)
work=$(mktemp -d /tmp/abyss-wifilab-t.XXXXXX)
trap 'rm -rf "$work"' EXIT
printf 'ctrl_interface=%s/wpa.ctl\nnetwork={\n  ssid="abyss-lab"\n  psk="abyss-secret"\n}\n' "$work" > "$work/wpa.conf"

for round in 1 2 3; do
  sh "$lab" up abyss-lab abyss-secret >/dev/null || fail "round $round: the access point did not come up"
  sudo ifconfig wlan91 create wlandev wtap1 >/dev/null
  sudo ifconfig wlan91 up
  sudo ifconfig wlan91 scan > "$work/scan" 2>&1 || true
  grep -q '^abyss-lab .* RSN' "$work/scan" || fail "round $round: the scan did not find abyss-lab: $(cat "$work/scan")"
  sudo wpa_supplicant -B -P "$work/wpa.pid" -i wlan91 -c "$work/wpa.conf" < /dev/null > "$work/wpa.log" 2>&1 \
    || fail "round $round: wpa_supplicant: $(cat "$work/wpa.log")"
  i=0; st=""
  while [ $i -lt 50 ]; do
    st=$(sudo wpa_cli -p "$work/wpa.ctl" -i wlan91 status 2>/dev/null | sed -n 's/^wpa_state=//p')
    [ "$st" = COMPLETED ] && break
    sleep 0.2; i=$((i + 1))
  done
  [ "$st" = COMPLETED ] || fail "round $round: the station did not join (wpa_state=$st)"
  sudo kill "$(cat "$work/wpa.pid")"; sleep 0.3
  sudo ifconfig wlan91 destroy
  sh "$lab" down >/dev/null
  echo "ok: round $round: found by a scan, joined (COMPLETED), torn down"
done

# The TSF callout used to fire ~30 s after the module went (wtap-teardown.patch).
sleep 35
[ "$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')" = "$boot" ] || fail "the guest rebooted: a panic"
[ "$(dumps)" = "$before" ] || fail "a new crash dump appeared in /var/crash"
echo "ok: the same boot 35 s after the last unload, and no new crash dump — the kernel survived three labs"

echo "all green (the Wi-Fi lab: an access point, a scan, a WPA2 join, and a kernel still up)."
