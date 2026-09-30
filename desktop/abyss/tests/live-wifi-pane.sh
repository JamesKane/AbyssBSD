#!/bin/sh
# AbyssBSD Swift DE — Wi-Fi on the Network pane (PHASE14 P14.5c).
#
# System Preferences driven by the virtual pointer and keyboard, against a real
# helper and — in the guest — the Wi-Fi lab. Claims:
#
#   1. the radio is offered beside the wired interfaces; choosing it shows its
#      status and that no network is known;
#   2. Scan (the helper, as root) lists "abyss-lab";
#   3. choosing it and typing the passphrase, then Return, joins it through the
#      helper — and the station associates, which the page shows;
#   4. the page knows the network; Forget takes it out again;
#   5. the passphrase and the key never appear in anything the app logged
#      (the pane logs how many characters were typed, never which);
#   6. the kernel is still on the same boot.
#
# In the guest this uses the real /etc/rc.conf and /etc/wpa_supplicant.conf, as
# live-wifi.sh does, backed up and restored. On Linux there is no radio, and
# none is offered.
#
# Usage: abyss/tests/live-wifi-pane.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
menu="$root/.build/debug/abyssmenu"
helper="$root/.build/debug/abyss-settings"
vents="$root/.build/debug/ventsctl"
for b in "$undertow" "$client" "$menu" "$helper" "$vents"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

freebsd=0; [ "$(uname -s)" = FreeBSD ] && freebsd=1
sudo=""
if [ "$freebsd" = 1 ]; then
  sudo -n true 2>/dev/null || { echo "FAIL: on FreeBSD the helper runs as root, and this needs passwordless sudo"; exit 1; }
  sudo=sudo
fi

W=1024; H=768
work=$(mktemp -d /tmp/abyss-wifipane.XXXXXX)
chmod 755 "$work"                       # the root helper writes its scratch files here
rundir=$(mktemp -d /tmp/abyss-wifipaner.XXXXXX)
restored=1
cleanup() {
  exec 3>&- 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  if [ "$restored" = 0 ]; then
    sudo service netif stop wlan0 >/dev/null 2>&1 || true
    sudo pkill -f 'wpa_supplicant.*-i ?wlan0' 2>/dev/null || true
    sudo ifconfig wlan0 destroy 2>/dev/null || true
    sudo cp "$work/rc.conf.bak" /etc/rc.conf
    if [ -f "$work/wpa.bak" ]; then sudo cp -p "$work/wpa.bak" /etc/wpa_supplicant.conf; else sudo rm -f /etc/wpa_supplicant.conf; fi
    sh "$root/abyss/tests/wtap/lab.sh" down >/dev/null 2>&1 || true
  fi
  for p in ${vk_pid:-} ${vp_pid:-} ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  [ -n "${svc_pid:-}" ] && { $sudo kill "$svc_pid" 2>/dev/null || true; }
  $sudo rm -rf "$work" "$rundir" 2>/dev/null || rm -rf "$work" "$rundir" || true
}
trap cleanup EXIT INT TERM HUP
export ABYSS_RUNTIME_DIR="$rundir"
mkdir -p "$work/cfg"
export ABYSS_CONFIG_DIR="$work/cfg"
fail() {
  echo "FAIL: $1"
  [ -s "$work/app.log" ] && grep -E 'wifi|network' "$work/app.log" | sed 's/^/  app| /' | tail -15
  [ -s "$work/svc.err" ] && sed 's/^/  helper| /' "$work/svc.err" | tail -8
  exit 1
}

mark() { grep -c -- "$1" "$work/app.log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY — a line AFTER the mark (§2.61)
  i=0
  while [ $i -lt 100 ]; do
    [ "$(mark "$1")" -gt "$2" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  fail "$3 (no new '$1' in the log)"
}
last() { grep -- "$1" "$work/app.log" | tail -1; }

# ------------------------------------------------------------- the helper
me=$(id -u); mygroup=$(id -gn)
if [ "$freebsd" = 0 ]; then
  echo 'hostname="abyss"' > "$work/rc.conf"
  helper_files="--rc-conf $work/rc.conf --wpa-conf $work/wpa.conf"
else
  [ -f /usr/src/sys/dev/wtap/if_wtap.c ] || fail "no /usr/src/sys — the lab needs it (PHASE14 §4.2)"
  boot=$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')
  sudo cp /etc/rc.conf "$work/rc.conf.bak"
  [ -f /etc/wpa_supplicant.conf ] && sudo cp -p /etc/wpa_supplicant.conf "$work/wpa.bak"
  sudo rm -f /etc/wpa_supplicant.conf
  restored=0
  sh "$root/abyss/tests/wtap/lab.sh" up abyss-lab abyss-secret >/dev/null || fail "the lab did not come up"
  helper_files=""                  # rc's netif reads only the real files (live-wifi.sh)
fi
$sudo env ABYSS_RUNTIME_DIR="$rundir" "$helper" --uid "$me" --admin-group "$mygroup" $helper_files \
    --journal "$work/journal" 2> "$work/svc.err" &
svc_pid=$!
i=0; while [ ! -S "$rundir/settings.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$rundir/settings.sock" ] || fail "the helper never came up"

# --------------------------------------------------- compositor, app, input
for t in vpointer:wlr-virtual-pointer-unstable-v1 vkeyboard:virtual-keyboard-unstable-v1; do
  n=${t%%:*}; x=${t#*:}
  wayland-scanner client-header "$root/abyss/tests/$x.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$x.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "could not build vkeyboard"

wd="abyss-wifipane-$$"
"$undertow" run --frames 0 --width "$W" --height "$H" --socket "$wd" \
   --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/$wd" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/$wd" ] || fail "undertow never bound $wd"

env WAYLAND_DISPLAY="$wd" AQUA_SCENE=sysprefs ABYSS_PREFS_DUMP=1 "$client" > "$work/app.log" 2>&1 &
app_pid=$!
await "System Preferences is up" 0 "the application never started"
await "SystemPreferences: layout " 0 "it never drew its grid"

i=0; geom=""
while [ -z "$geom" ] && [ $i -lt 60 ]; do
  geom=$(grep '^window org.abyssbsd.preferences/' "$work/ut.out" | head -1 | awk '{print $(NF-1)}')
  sleep 0.05; i=$((i + 1))
done
[ -n "$geom" ] || fail "undertow never reported the window"
wx=${geom%,*}; wy=${geom#*,}
at() {  # at NAME -> "X Y" on the output, from the pane's latest layout line
  p=$(grep -E "(network|wifi) layout" "$work/app.log" | tr ' ' '\n' | sed -n "s/^$1=//p" | tail -1)
  [ -n "$p" ] || fail "the pane's layout does not say where $1 is"
  echo "$((wx + ${p%,*})) $((wy + ${p#*,}))"
}
click() { printf 'm %s\np\nr\n' "$(at "$1")" >&3; }

fifo="$work/vp.fifo"; mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" "$W" "$H" < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!; exec 3>"$fifo"
kfifo="$work/vk.fifo"; mkfifo "$kfifo"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$kfifo" > "$work/vk.log" 2>&1 &
vk_pid=$!; exec 4>"$kfifo"
i=0; while { ! grep -q ready "$work/vp.log" || ! grep -q ready "$work/vk.log"; } 2>/dev/null && [ $i -lt 60 ]; do
  i=$((i+1)); sleep 0.1; done
grep -q ready "$work/vp.log" && grep -q ready "$work/vk.log" || fail "the virtual pointer or keyboard never bound"
sleep 0.5

"$menu" run systempreferences view.pane.network > /dev/null || fail "could not open Network by its verb"
await "network layout" 0 "the pane did not publish its layout"
if [ "$freebsd" = 0 ]; then
  grep 'network layout' "$work/app.log" | grep -q 'iface.wifi:' && fail "a radio was offered on Linux"
  echo "ok: no radio on this machine, and none is offered"
  echo "all green (Wi-Fi on the Network pane: nothing to join here)."
  exit 0
fi

# ------------------------------------------------------------ 1. the radio
b=$(mark "wifi: status "); click "iface.wifi:wtap1"
await "wifi: status " "$b" "choosing the radio showed no status"
last "wifi: status " | grep -q 'wtap1 wlan0 not-associated known none' || fail "the radio's page: $(last 'wifi: status ')"
echo "ok: 1. the radio is offered beside the wired interfaces, not associated, knowing nothing"

# ------------------------------------------------------------ 2. scan
await "wifi layout" 0 "the Wi-Fi page published no layout"
b=$(mark "wifi: scanned"); click scan
await "wifi: scanned" "$b" "Scan returned nothing"
last "wifi: scanned" | grep -q '0=abyss-lab' || fail "the scan did not list abyss-lab: $(last 'wifi: scanned')"
echo "ok: 2. Scan (the helper, as root) listed abyss-lab"

# ------------------------------------------------- 3. choose, type, join
b=$(mark "wifi: chose"); sleep 0.3; click net.0
await "wifi: chose abyss-lab" "$b" "choosing abyss-lab did nothing"
printf 't abyss-secret\n' >&4
await "wifi: password 12 characters" 0 "the passphrase was not typed into the field"
a=$(mark "wifi: applied"); printf 'k 28\n' >&4
await "wifi: apply join abyss-lab (secured)" 0 "Return did not join"
i=0; while [ "$(mark 'wifi: applied')" -le "$a" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(mark 'wifi: applied')" -gt "$a" ] || fail "the join was not applied: $(last 'wifi: ')"
# wtap's own handshake fails about one attempt in three (live-wifi.sh): ask
# again, as a person pressing Join again would, and say how often.
retries=0; i=0
while [ $i -lt 150 ]; do
  [ "$(sudo wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')" = COMPLETED ] && break
  if sudo wpa_cli -i wlan0 list_networks 2>/dev/null | grep -q TEMP-DISABLED && [ $retries -lt 6 ]; then
    sudo wpa_cli -i wlan0 enable_network 0 >/dev/null 2>&1; sudo wpa_cli -i wlan0 reassociate >/dev/null 2>&1
    retries=$((retries + 1)); sleep 3; i=$((i + 15))
  fi
  sleep 0.2; i=$((i + 1))
done
await "wifi: status .*associated abyss-lab" 0 "the page never showed the association"
echo "ok: 3. chosen, typed, Return: joined through the helper, and the page shows it associated ($retries retries of wtap's handshake)"

# ------------------------------------------------------ 4. known, forgotten
await "wifi: status .*known abyss-lab" 0 "the page does not know the network it joined"
await "wifi layout .*forget.0=" 0 "no Forget button was published"
b=$(mark "wifi: applied"); sleep 0.3; click forget.0
await "wifi: applied" "$b" "Forget applied nothing"
await "wifi: status .*known none" 0 "the network is still known after Forget"
sudo grep -q 'ssid=' /etc/wpa_supplicant.conf 2>/dev/null && fail "wpa_supplicant.conf still holds a network"
echo "ok: 4. the page knew abyss-lab, and Forget took it out"

# ------------------------------------------------------ 5. never the secret
grep -q 'abyss-secret' "$work/app.log" && fail "the passphrase is in the app's log"
grep -Eq '[0-9a-f]{64}' "$work/app.log" && fail "a key is in the app's log"
grep -q 'abyss-secret' "$work/journal" 2>/dev/null && fail "the passphrase is in the journal"
echo "ok: 5. neither the passphrase nor the key is in anything the app or the helper wrote down"

# ------------------------------------------------------ 6. the kernel
[ "$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')" = "$boot" ] || fail "the guest rebooted: a panic"
echo "ok: 6. the same boot"

exec 3>&- 4>&- 2>/dev/null || true
echo "all green (Wi-Fi on the Network pane: scanned, joined, shown, forgotten — and the passphrase kept by no one)."
