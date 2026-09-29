#!/bin/sh
# AbyssBSD Swift DE — the Network pane (PHASE14 P14.4c).
#
# System Preferences on our compositor, its Network pane driven by the virtual
# pointer and keyboard, talking to a real `abyss-settings`. Claims:
#
#   1. the Status box is the kernel's: the pane's status line for its interface
#      agrees with `ventsctl network` (itself checked against ifconfig/ip(8));
#   2. Configure is rc.conf's, read through the helper — or, where the helper
#      will not read (Linux), the page says why in the helper's words;
#   3. typed fields are what is sent: a bad address is refused by the helper,
#      in its words, shown on the page; corrected, it is sent again;
#   4. on FreeBSD the helper is WRITE-ONLY on scratch files: Apply Now writes
#      rc.conf and resolvconf.conf, the pane says "not put into effect" rather
#      than "applied", reads back what it wrote — and the guest's real address
#      is unchanged, because the guest's network is how this test reaches it
#      (§6.3). On Linux the corrected plan is refused as "not FreeBSD";
#   5. Revert reads rc.conf again, dropping what was typed;
#   6. FreeBSD: a change in the kernel (an alias on lo0) redraws the page,
#      through the routing socket.
#
# Coordinates come from the application's published layout (§2.46).
#
# Usage: abyss/tests/live-network-pane.sh
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
work=$(mktemp -d /tmp/abyss-netpane.XXXXXX)
chmod 755 "$work"                       # the root helper writes its scratch files here
rundir=$(mktemp -d /tmp/abyss-netpaner.XXXXXX)
aliased=0
cleanup() {
  exec 3>&- 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  [ "$aliased" = 1 ] && { sudo ifconfig lo0 -alias 127.0.0.78 2>/dev/null || true; }
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
  [ -s "$work/app.log" ] && grep 'network' "$work/app.log" | sed 's/^/  app| /' | tail -15
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
iface_guess=""
if [ "$freebsd" = 1 ]; then
  iface_guess=$(ifconfig -l | tr ' ' '\n' | grep -v '^lo' | grep -v '^wl' | head -1)
  printf 'hostname="abyss"\nifconfig_%s="DHCP"\n' "$iface_guess" > "$work/rc.conf"
  helper_mode="--write-only"
else
  echo 'hostname="abyss"' > "$work/rc.conf"
  helper_mode=""
fi
chmod 644 "$work/rc.conf"
$sudo env ABYSS_RUNTIME_DIR="$rundir" "$helper" --uid "$me" --admin-group "$mygroup" \
    --rc-conf "$work/rc.conf" --resolvconf "$work/resolvconf.conf" --journal "$work/journal" \
    $helper_mode 2> "$work/svc.err" &
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

wd="abyss-netpane-$$"
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
  p=$(grep 'network layout' "$work/app.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p")
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

# ------------------------------------------------------ 1. the kernel's status
"$menu" run systempreferences view.pane.network > /dev/null || fail "could not open the Network pane by its verb"
await "network: status " 0 "the pane did not read the kernel's status"
await "network layout" 0 "the pane did not publish its layout"
status=$(last "network: status " | sed 's/.*network: status //')
iface=${status%% *}
[ -z "$iface_guess" ] || [ "$iface" = "$iface_guess" ] || fail "the pane shows $iface, the machine's first wired interface is $iface_guess"
# The same fields, from ventsctl, in the pane's words.
v=$("$vents" network) || fail "ventsctl network failed"
ifl=$(printf '%s\n' "$v" | grep "^interface $iface ")
ipv4=$(printf '%s\n' "$ifl" | sed -n 's/.* ipv4 \([^ ]*\).*/\1/p')
router=$(printf '%s\n' "$v" | sed -n 's/^router //p')
dns=$(printf '%s\n' "$v" | sed -n 's/^dns //p' | tr ' ' ',')
want="$iface $(printf '%s\n' "$ifl" | awk '{print $3}') link $(printf '%s\n' "$ifl" | awk '{print $5}') ipv4 $ipv4 router $router dns $dns"
[ "$status" = "$want" ] || fail "the pane's status is not the kernel's:
  pane:     $status
  ventsctl: $want"
echo "ok: 1. the Status box is the kernel's: $status"

# ---------------------------------------------------- 2. rc.conf's, or why not
if [ "$freebsd" = 1 ]; then
  await "network: read $iface dhcp" 0 "the pane did not read rc.conf's DHCP through the helper"
  echo "ok: 2. Configure is rc.conf's, through the helper: $(last 'network: read ' | sed 's/.*network: //')"
else
  await "network: cannot read $iface: " 0 "the pane did not say why the helper would not read"
  echo "ok: 2. the helper will not read here, and the page says so: $(last 'network: cannot read' | sed 's/.*network: //')"
fi

# ------------------------------------------- 3. what was typed is what is sent
b=$(mark "network: mode manual"); click mode.manual
await "network: mode manual" "$b" "Manually was not chosen"
b=$(mark "network: focus address"); click field.address
await "network: focus address" "$b" "the address field did not take focus"
printf 't 10.0.2.300\n' >&4; sleep 0.2
printf 'k 15\n' >&4; printf 't 255.255.255.0\n' >&4; sleep 0.2
printf 'k 15\n' >&4; printf 't 10.0.2.2\n' >&4; sleep 0.2
printf 'k 15\n' >&4; printf 't 9.9.9.9, 1.1.1.1\n' >&4; sleep 0.3
b=$(mark "network: not applied"); a=$(mark "network: apply ")
click apply
await "network: apply " "$a" "Apply Now sent nothing"
case "$(last 'network: apply ')" in
  *"network: apply $iface manual address=10.0.2.300 netmask=255.255.255.0 router=10.0.2.2 dns=9.9.9.9, 1.1.1.1") ;;
  *) fail "what was sent is not what was typed: $(last 'network: apply ')" ;;
esac
await "network: not applied" "$b" "a bad address was not refused"
case "$(last 'network: not applied')" in
  *"10.0.2.300 is not an IPv4 address"*) ;;
  *) fail "the refusal is not the helper's words: $(last 'network: not applied')" ;;
esac
echo "ok: 3. typed (with Tab between fields) and sent as typed; the helper refused 10.0.2.300, in its words"

# ------------------------------------------------ 4. corrected, and applied
b=$(mark "network: focus address"); click field.address
await "network: focus address" "$b" "the address field did not take focus again"
printf 'k 14 14 14\n' >&4; printf 't 50\n' >&4; sleep 0.2
a=$(mark "network: apply "); n=$(mark "network: not applied"); y=$(mark "network: applied")
printf 'k 28\n' >&4                                              # Return is Apply Now
await "network: apply " "$a" "Return did not apply"
case "$(last 'network: apply ')" in
  *"address=10.0.2.50 "*) ;; *) fail "the corrected address was not sent: $(last 'network: apply ')" ;;
esac
if [ "$freebsd" = 1 ]; then
  r=$(mark "network: read $iface manual")
  await "network: applied" "$y" "a write-only apply did not finish"
  case "$(last 'network: applied')" in
    *"Saved, and not put into effect (write-only"*) ;;
    *) fail "a write-only apply was not said to be saved-and-not-in-effect: $(last 'network: applied')" ;;
  esac
  [ "$(mark 'network: skipped: ')" = 3 ] || fail "netif, routing and resolvconf were not all said to be skipped"
  grep -q "^ifconfig_$iface=\"inet 10.0.2.50 netmask 255.255.255.0\"" "$work/rc.conf" || fail "rc.conf: $(cat "$work/rc.conf")"
  grep -q '^defaultrouter="10.0.2.2"' "$work/rc.conf" || fail "no defaultrouter: $(cat "$work/rc.conf")"
  grep -q '^name_servers="9.9.9.9 1.1.1.1"' "$work/resolvconf.conf" || fail "resolvconf.conf: $(cat "$work/resolvconf.conf")"
  await "network: read $iface manual" "$r" "the pane did not read back what it wrote"
  case "$(last 'network: read ')" in
    *"manual address=10.0.2.50 netmask=255.255.255.0 router=10.0.2.2 dns=9.9.9.9 1.1.1.1") ;;
    *) fail "read back: $(last 'network: read ')" ;;
  esac
  now=$("$vents" network | grep "^interface $iface " | sed -n 's/.* ipv4 \([^ ]*\).*/\1/p')
  [ "$now" = "$ipv4" ] || fail "the guest's real address changed: $ipv4 -> $now"
  echo "ok: 4. corrected and applied (Return): rc.conf and resolvconf.conf written, three actions skipped and said, read back — and $iface still $now"
else
  await "network: not applied" "$n" "the corrected plan was neither applied nor refused"
  case "$(last 'network: not applied')" in
    *"this machine is not FreeBSD"*) ;;
    *) fail "the corrected plan was refused for the wrong reason: $(last 'network: not applied')" ;;
  esac
  echo "ok: 4. corrected and sent (Return); refused here because this is not FreeBSD, in the helper's words"
fi

# ---------------------------------------------------------------- 5. Revert
b=$(mark "network: focus dns"); click field.dns
await "network: focus dns" "$b" "the DNS field did not take focus"
printf 't  8.8.8.8\n' >&4; sleep 0.2
if [ "$freebsd" = 1 ]; then pat="network: read $iface"; else pat="network: cannot read $iface"; fi
r=$(mark "$pat"); v0=$(mark "network: revert")
click revert
await "network: revert" "$v0" "Revert did nothing"
await "$pat" "$r" "Revert did not read rc.conf again"
a=$(mark "network: apply "); printf 'k 28\n' >&4
await "network: apply " "$a" "Return after Revert sent nothing"
case "$(last 'network: apply ')" in
  *8.8.8.8*) fail "Revert kept what was typed: $(last 'network: apply ')" ;;
esac
echo "ok: 5. Revert read rc.conf again, and what was typed went with it"

# ------------------------------------------------------ 6. the kernel changes
if [ "$freebsd" = 1 ]; then
  sleep 0.5
  c=$(mark "network: changed")
  sudo ifconfig lo0 alias 127.0.0.78/32; aliased=1
  await "network: changed" "$c" "an address added in the kernel did not redraw the page"
  sudo ifconfig lo0 -alias 127.0.0.78; aliased=0
  echo "ok: 6. an alias added in the kernel reached the page through the routing socket"
else
  echo "ok: 6. (the kernel-change half needs root to add an address; it runs in the FreeBSD guest)"
fi

exec 3>&- 4>&- 2>/dev/null || true
echo "all green (the Network pane: the kernel's status, rc.conf's configuration, and the helper's word on every change)."
