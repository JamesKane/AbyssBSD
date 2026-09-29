#!/bin/sh
# The Wi-Fi lab (PHASE14 P14.5): two simulated radios on one simulated medium,
# an access point on the first, the second left for the system under test.
#
#   lab.sh up SSID PASSPHRASE   build/load wtap (with station + AP, see
#                               build-wtap.sh), create wtap0/wtap1, link them,
#                               run hostapd (WPA2-PSK) on wlan90 over wtap0
#   lab.sh down                 stop hostapd, destroy wlan90 and both radios
#
# The station's radio is `wtap1`; the test (or rc.conf's wlans_wtap1) makes its
# wlan interface. Nothing here touches the guest's own network. FreeBSD only,
# and root through sudo. State lives in /tmp/abyss-wifilab.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
lab=/tmp/abyss-wifilab
cmd=${1:-}

[ "$(uname -s)" = FreeBSD ] || { echo "lab.sh: wtap is FreeBSD's" >&2; exit 2; }

down() {
  [ -f "$lab/hostapd.pid" ] && { sudo kill "$(cat "$lab/hostapd.pid")" 2>/dev/null || true; }
  sleep 0.3
  sudo ifconfig wlan90 destroy 2>/dev/null || true
  for id in 1 0; do [ -x "$lab/wtapctl" ] && sudo "$lab/wtapctl" delete "$id" 2>/dev/null || true; done
  rm -f "$lab/hostapd.pid"
  # Unloaded, so each `up` starts from a fresh module. (Unloading used to
  # panic: the HAL's TSF callout outlived its mutex — wtap-teardown.patch.)
  kldstat -q -n wtap && sudo kldunload wtap 2>/dev/null || true
}

case "$cmd" in
up)
  ssid=${2:?usage: lab.sh up SSID PASSPHRASE}; pass=${3:?usage: lab.sh up SSID PASSPHRASE}
  mkdir -p "$lab"
  down
  # A wtap that can be a station and an access point: ours, built once per
  # kernel. The stock module (mesh and ad-hoc only) is unloaded for it.
  if [ ! -s "$lab/wtap.ko" ] || [ "$lab/wtap.ko" -ot "$here/wtap-sta-hostap.patch" ] \
     || [ "$lab/wtap.ko" -ot "$here/wtap-teardown.patch" ]; then
    sh "$here/build-wtap.sh" "$lab" >/dev/null
  fi
  sudo kldload "$lab/wtap.ko"          # down() unloaded any wtap, ours or stock
  # WPA's authenticator and ciphers are modules a real NIC's driver pulls in;
  # wtap's does not, and without them hostapd cannot enable WPA ("Invalid
  # argument" on IEEE80211_IOC_AUTHMODE).
  for m in wlan_xauth wlan_ccmp wlan_tkip; do sudo kldload -n "$m"; done
  sudo "$lab/wtapctl" create 0
  sudo "$lab/wtapctl" create 1
  sudo "$lab/wtapctl" open
  sudo "$lab/wtapctl" link 0 1
  sudo "$lab/wtapctl" link 1 0
  sudo ifconfig wlan90 create wlandev wtap0 wlanmode hostap
  sudo ifconfig wlan90 up
  cat > "$lab/hostapd.conf" <<C
interface=wlan90
ctrl_interface=$lab/hostapd.ctl
ssid=$ssid
wpa=2
wpa_passphrase=$pass
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
C
  # stdin from /dev/null: a daemon that keeps its caller's stdin keeps an ssh
  # session (or a test's pipe) open after it has "gone into the background".
  sudo hostapd -B -P "$lab/hostapd.pid" "$lab/hostapd.conf" < /dev/null > "$lab/hostapd.log" 2>&1 \
    || { cat "$lab/hostapd.log" >&2; down; exit 1; }
  i=0; while ! grep -q AP-ENABLED "$lab/hostapd.log" && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  grep -q AP-ENABLED "$lab/hostapd.log" || { cat "$lab/hostapd.log" >&2; down; exit 1; }
  echo "lab: access point \"$ssid\" on wlan90 (wtap0); the station's radio is wtap1"
  ;;
down) down; echo "lab: down" ;;
*) echo "usage: lab.sh up SSID PASSPHRASE | down" >&2; exit 2 ;;
esac
