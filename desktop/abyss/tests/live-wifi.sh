#!/bin/sh
# AbyssBSD Swift DE — joining a Wi-Fi network, through the helper (PHASE14 P14.5).
#
# The lab (live-wifi-lab.sh) gives an access point, "abyss-lab" (WPA2-PSK), on a
# simulated radio; the machine's own radio is `wtap1`. `abyss-settingsctl`
# speaks to a root `abyss-settings` exactly as the pane will. Claims:
#
#   1. a scan, as root through the helper, finds "abyss-lab", secured — and
#      leaves no wlan behind it;
#   2. joining with the wrong passphrase is applied (rc.conf and
#      wpa_supplicant.conf are written) and does NOT associate;
#   3. joining with the right one does: `service netif restart wlan0` — rc's
#      own path, from rc.conf — makes wlan0 on wtap1 and wpa_supplicant joins
#      (wpa_state=COMPLETED);
#   4. read agrees; wpa_supplicant.conf is mode 600 and holds the derived key,
#      never the passphrase; the journal names the network, never the key;
#   5. forgetting it takes the network out, and the station leaves it;
#   6. the kernel is still on the same boot, with no new crash dump.
#
# **This runs on the guest's real /etc/rc.conf and /etc/wpa_supplicant.conf**,
# because rc's netif reads nothing else — the only way to verify the join rc
# performs. Both are backed up and put back, wlan0 is stopped, and nothing
# touches vtnet0: the radio is a simulated one. On Linux: the refusals, and the
# passphrase refused before it is ever sent.
#
# Usage: abyss/tests/live-wifi.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

helper="$root/.build/debug/abyss-settings"
ctl="$root/.build/debug/abyss-settingsctl"
lab="$root/abyss/tests/wtap/lab.sh"
[ -x "$helper" ] && [ -x "$ctl" ] || swift build

work=$(mktemp -d /tmp/abyss-wifi.XXXXXX)
chmod 755 "$work"
rundir="$work/run"; mkdir -p "$rundir"; chmod 700 "$rundir"
export ABYSS_RUNTIME_DIR="$rundir"
freebsd=0; [ "$(uname -s)" = FreeBSD ] && freebsd=1
me=$(id -u); mygroup=$(id -gn)
sudo=""; [ "$freebsd" = 1 ] && sudo=sudo
restored=1
cleanup() {
  [ -n "${svc_pid:-}" ] && { $sudo kill "$svc_pid" 2>/dev/null || true; }
  if [ "$restored" = 0 ]; then
    sudo service netif stop wlan0 >/dev/null 2>&1 || true
    sudo pkill -f 'wpa_supplicant.*-i ?wlan0' 2>/dev/null || true
    sudo ifconfig wlan0 destroy 2>/dev/null || true
    sudo cp "$work/rc.conf.bak" /etc/rc.conf
    if [ -f "$work/wpa.bak" ]; then sudo cp -p "$work/wpa.bak" /etc/wpa_supplicant.conf
    else sudo rm -f /etc/wpa_supplicant.conf; fi
    sh "$lab" down >/dev/null 2>&1 || true
  fi
  $sudo rm -rf "$work" 2>/dev/null || rm -rf "$work" || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; [ -s "$work/svc.err" ] && tail -8 "$work/svc.err" | sed 's/^/  helper| /'; exit 1; }
ctlrun() { rc=0; out=$("$ctl" "$@" 2>&1) || rc=$?; }

if [ "$freebsd" = 0 ]; then
  "$helper" --uid "$me" --admin-group "$mygroup" --rc-conf "$work/rc.conf" --wpa-conf "$work/wpa.conf" \
      --journal "$work/journal" 2> "$work/svc.err" &
  svc_pid=$!
  i=0; while [ ! -S "$rundir/settings.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  ctlrun scan wifi --device wtap1
  [ "$rc" != 0 ] && case "$out" in *"not FreeBSD"*) ;; *) false ;; esac || fail "Linux scan: $out"
  ctlrun apply wifi --device wtap1 --join abyss-lab --passphrase short
  [ "$rc" = 2 ] && case "$out" in *"8 to 63 characters"*) ;; *) false ;; esac || fail "a short passphrase: $out"
  ctlrun check wifi --device wtap1 --join abyss-lab --passphrase abyss-secret
  [ "$rc" != 0 ] && case "$out" in *"there is no wireless device wtap1"*) ;; *) false ;; esac || fail "Linux check: $out"
  echo "ok: a scan refused (not FreeBSD), a short passphrase refused before it is sent, and a radio this machine lacks refused"
  echo "all green (Wi-Fi's refusals, where there is no Wi-Fi to join)."
  exit 0
fi

[ -f /usr/src/sys/dev/wtap/if_wtap.c ] || fail "no /usr/src/sys — the lab needs it (PHASE14 §4.2)"
boot=$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')
dumps() { ls /var/crash 2>/dev/null | grep -c '^vmcore\.[0-9]' || true; }
before=$(dumps)

sudo cp /etc/rc.conf "$work/rc.conf.bak"
[ -f /etc/wpa_supplicant.conf ] && sudo cp -p /etc/wpa_supplicant.conf "$work/wpa.bak"
sudo rm -f /etc/wpa_supplicant.conf
restored=0
sh "$lab" up abyss-lab abyss-secret >/dev/null || fail "the lab did not come up"

sudo env ABYSS_RUNTIME_DIR="$rundir" "$helper" --uid "$me" --admin-group "$mygroup" \
    --journal "$work/journal" 2> "$work/svc.err" &
svc_pid=$!
i=0; while [ ! -S "$rundir/settings.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$rundir/settings.sock" ] || fail "the helper never came up"

# **Joined is wpa_state=COMPLETED**, not "status: associated": 802.11
# association comes before WPA's four-way handshake, so a station with the
# wrong key associates — and then fails the handshake. The first version of
# this test watched ifconfig's status and "joined" with the wrong passphrase.
associated() { [ "$(sudo wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')" = COMPLETED ]; }
wait_assoc() {  # wait_assoc SECONDS -> 0 when associated in time
  i=0; while [ $i -lt $(($1 * 5)) ]; do associated && return 0; sleep 0.2; i=$((i + 1)); done; return 1
}

# ------------------------------------------------------------ 1. scan
ctlrun scan wifi --device wtap1
[ "$rc" = 0 ] || fail "scan: $out"
printf '%s\n' "$out" | grep -q '^network "abyss-lab" signal .* secured$' || fail "the scan did not find abyss-lab, secured: $out"
ifconfig wlan0 >/dev/null 2>&1 && fail "the scan left wlan0 behind"
echo "ok: 1. a scan through the helper found \"abyss-lab\", secured, and left no wlan behind"

# ------------------------------------------------------ 2. wrong key
ctlrun apply wifi --device wtap1 --join abyss-lab --passphrase not-the-secret
[ "$rc" = 0 ] || fail "applying a join failed: $out"
if wait_assoc 8; then fail "the wrong passphrase completed WPA"; fi
echo "ok: 2. joined with the wrong passphrase: written and restarted, and WPA never completed"

# **Fresh radios for the next join.** wtap's WPA (upstream, June 2026) is
# unreliable re-joining on the SAME radios: the simulated access point keeps
# the last session's pairwise key for the station and encrypts the next
# handshake's first message with it ("4-Way Handshake failed - pre-shared key
# may be incorrect" with the right key, then TEMP-DISABLED); restarting hostapd
# on the same vap leaves it with no channel. Fresh radios have joined every
# time. A lab artifact — a real AP clears a station's keys on a new
# association — so the lab is rebuilt, and rc.conf is left exactly as the
# helper wrote it.
sudo service netif stop wlan0 >/dev/null 2>&1 || true
sudo pkill -f 'wpa_supplicant.*-i ?wlan0' 2>/dev/null || true
sh "$lab" down >/dev/null
sh "$lab" up abyss-lab abyss-secret >/dev/null || fail "the lab did not come up again"

# ------------------------------------------------------ 3. right key
ctlrun apply wifi --device wtap1 --join abyss-lab --passphrase abyss-secret
[ "$rc" = 0 ] || fail "applying a join failed: $out"
case "$out" in *"restart the netif service"*"done"*) ;; *) fail "the join did not restart netif: $out" ;; esac
# **wtap's WPA handshake fails about one attempt in three with the RIGHT key**
# ("4-Way Handshake failed" on a fresh lab; measured 4 of 6 through rc, with
# or without DHCP) — upstream's June 2026 code, not rc or this plan. When the
# supplicant gives up (TEMP-DISABLED), ask it again, as a person pressing Join
# again would; at most six times, and the count is SAID in the ok line.
retries=0; joined=0; i=0
while [ $i -lt 150 ]; do
  associated && { joined=1; break; }
  if sudo wpa_cli -i wlan0 list_networks 2>/dev/null | grep -q 'TEMP-DISABLED' && [ $retries -lt 6 ]; then
    sudo wpa_cli -i wlan0 enable_network 0 >/dev/null 2>&1; sudo wpa_cli -i wlan0 reassociate >/dev/null 2>&1
    retries=$((retries + 1))
    sleep 3; i=$((i + 15))          # time to try; the flag lingers a moment after enable
  fi
  sleep 0.2; i=$((i + 1))
done
[ "$joined" = 1 ] || fail "the right passphrase did not complete WPA (after $retries retries): $(sudo wpa_cli -i wlan0 status 2>&1 | grep wpa_state)"
st=$(sudo wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')
[ "$st" = COMPLETED ] || fail "wpa_state=$st"
ifconfig wlan0 | grep -q 'ssid abyss-lab' || fail "associated, but not to abyss-lab: $(ifconfig wlan0 | grep ssid)"
echo "ok: 3. joined with the right one: rc made wlan0 on wtap1 and wpa_supplicant is COMPLETED on abyss-lab ($retries retr$([ $retries = 1 ] && echo y || echo ies) of wtap's handshake)"

# ------------------------------------------------------ 4. what was kept
ctlrun read wifi --device wtap1
[ "$out" = 'wifi wtap1: wlan0, networks: "abyss-lab"' ] || fail "read: $out"
[ "$(stat -f %Lp /etc/wpa_supplicant.conf)" = 600 ] || fail "wpa_supplicant.conf is mode $(stat -f %Lp /etc/wpa_supplicant.conf)"
sudo grep -q 'abyss-secret\|not-the-secret' /etc/wpa_supplicant.conf && fail "a passphrase is in wpa_supplicant.conf"
sudo grep -q '^	psk=[0-9a-f]\{64\}$' /etc/wpa_supplicant.conf || fail "no derived key in wpa_supplicant.conf"
grep -q 'add network "abyss-lab"' "$work/journal" || fail "the journal does not name the network"
grep -Eq '[0-9a-f]{64}|abyss-secret' "$work/journal" && fail "a key is in the journal"
echo "ok: 4. read agrees; wpa_supplicant.conf is 600 with the derived key and no passphrase; the journal names the network, not the key"

# ------------------------------------------------------ 5. forget
ctlrun apply wifi --device wtap1 --forget abyss-lab
[ "$rc" = 0 ] || fail "forget: $out"
ctlrun read wifi --device wtap1
[ "$out" = 'wifi wtap1: wlan0, networks: none' ] || fail "read after forgetting: $out"
i=0; while associated && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
associated && fail "WPA still completed after forgetting the network"
echo "ok: 5. forgotten: the network is out of wpa_supplicant.conf, and the station left it"

# ------------------------------------------------------ 6. the kernel
[ "$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')" = "$boot" ] || fail "the guest rebooted: a panic"
[ "$(dumps)" = "$before" ] || fail "a new crash dump appeared"
echo "ok: 6. the same boot, no new crash dump"

echo "all green (Wi-Fi: scanned, refused a wrong key, joined by rc's own path, kept without the passphrase, forgotten)."
