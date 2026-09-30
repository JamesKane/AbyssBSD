#!/bin/sh
# AbyssBSD Swift DE — a manual address, set through the settings helper,
# survives a reboot (PHASE14 P14.4, the gate: §6.3).
#
# The claim: on an INSTALLED machine, the administrator asks the root helper
# for a manual address on vtnet0; the helper writes rc.conf and resolvconf.conf
# and restarts the interface; the machine reboots; and after the reboot the
# kernel has that address, because rc.conf said so — not because anything
# remembered it.
#
# It runs on the disk `live-desktop.sh` just installed (so, in --full, after
# it), booted nested with a virtio-net on a tap that goes nowhere: an address
# needs an interface, not a network. The machine is its own; this build
# guest's network — how the harness reaches it — is never touched.
#
# **What this does NOT prove, said plainly:** nobody clicks the pane here. The
# installed desktop holds rc's foreground, so its console never reaches a login
# (HANDOFF §2.47), and putting the harness's input tools into the product image
# is what live-desktop.sh already declines to do. Instead a one-shot rc script
# planted on the disk runs `abyss-settingsctl apply network`, **as the
# administrator**, against the real root helper — the same protocol the pane
# speaks, carrying the same plan the pane builds. The clicking is proven by
# live-network-pane.sh, on the same binary and the same helper.
#
# Usage: abyss/tests/live-network-reboot.sh   (after live-desktop.sh)
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
fail() { echo "FAIL: $1"; exit 1; }

if [ "$(uname -s)" != FreeBSD ]; then
  echo "== $(uname -s): no installed FreeBSD to reboot here; the pane's half is live-network-pane.sh =="
  echo "all green (nothing claimed here that was not checked)."
  exit 0
fi

uefi=/usr/local/share/uefi-firmware/BHYVE_UEFI.fd
target="${ABYSS_TARGET_IMG:-/home/$(id -un)/abyss-target.img}"
pool=abyss
addr=10.77.0.5; mask=255.255.255.0; router=10.77.0.1; dns=10.77.0.1

command -v bhyve >/dev/null || fail "bhyve is not installed"
[ -f "$uefi" ] || { echo "SKIP: no bhyve UEFI firmware — pkg install edk2-bhyve"; exit 0; }
sudo -n true 2>/dev/null || { echo "SKIP: this needs passwordless sudo"; exit 0; }
[ -s "$target" ] || fail "no installed disk at $target — run live-desktop.sh first"
if zpool list -H -o name 2>/dev/null | grep -qx "$pool"; then
  fail "this build guest already has a pool named $pool; the installed one cannot be imported beside it"
fi

work=$(mktemp -d /tmp/abyss-p144d.XXXXXX)
chmod 755 "$work"
cleanup() {
  sudo bhyvectl --destroy --vm=abyssp144 >/dev/null 2>&1 || true
  sudo zpool export "$pool" 2>/dev/null || true
  [ -n "${md:-}" ] && sudo mdconfig -d -u "${md#md}" 2>/dev/null || true
  [ -n "${tap:-}" ] && sudo ifconfig "$tap" destroy 2>/dev/null || true
  sudo rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

# ------------------------------------------------ 1. plant the one-shot
md=$(sudo mdconfig -a -t vnode -f "$target")
sudo zpool import -f -N -R "$work/root" -d "/dev/$md" "$pool" 2>/dev/null \
  || sudo zpool import -f -N -R "$work/root" -d /dev "$pool" \
  || fail "the installed pool would not import from $target"
sudo zfs mount "$pool/ROOT/default" || fail "$pool/ROOT/default would not mount"
r="$work/root"
admin=$(sudo sysrc -f "$r/etc/rc.conf" -n abyss_settings_admin 2>/dev/null || true)
[ -n "$admin" ] || fail "the installed rc.conf names no settings administrator (P14.3b): $(sudo cat "$r/etc/rc.conf")"
[ -x "$r/usr/local/bin/abyss-settingsctl" ] || fail "the installed system has no abyss-settingsctl"
sudo sysrc -f "$r/etc/rc.conf" -n "ifconfig_vtnet0" >/dev/null 2>&1 \
  && fail "the installed rc.conf already configures vtnet0 — the gate would prove nothing"

sudo sh -c "cat > $r/etc/rc.d/abyss_gate" <<RCD
#!/bin/sh
# PROVIDE: abyss_gate
# REQUIRE: abyss_settings
# BEFORE: abyss_desktop
# A test's, planted by live-network-reboot.sh — not part of the product.
. /etc/rc.subr
name="abyss_gate"
rcvar="abyss_gate_enable"
start_cmd="gate_start"
stop_cmd=":"
gate_start()
{
	if [ ! -e /var/db/abyss-gate.applied ]; then
		rundir=/var/run/abyss-$admin
		i=0
		while [ ! -S "\$rundir/settings.sock" ] && [ \$i -lt 50 ]; do sleep 0.2; i=\$((i + 1)); done
		echo "gate: applying, as $admin"
		su -m $admin -c "ABYSS_RUNTIME_DIR=\$rundir /usr/local/bin/abyss-settingsctl apply network --interface vtnet0 --address $addr --netmask $mask --router $router --dns $dns" 2>&1 | sed 's/^/gate| /'
		touch /var/db/abyss-gate.applied
		sync
		echo "gate: before the reboot, vtnet0 has \$(ifconfig vtnet0 inet | awk '/inet /{print \$2, \$4}')"
		echo "gate: rebooting"
		(sleep 2; shutdown -r now) &
		return 0
	fi
	echo "gate: after the reboot, vtnet0 has \$(ifconfig vtnet0 inet | awk '/inet /{print \$2, \$4}')"
	echo "gate: after the reboot, the default router is \$(route -n get default 2>/dev/null | awk '/gateway:/{print \$2}')"
	echo "gate: after the reboot, resolv.conf has \$(awk '/^nameserver/{print \$2}' /etc/resolv.conf | tr '\n' ' ')"
}
load_rc_config \$name
run_rc_command "\$1"
RCD
sudo chmod 755 "$r/etc/rc.d/abyss_gate"
sudo sysrc -f "$r/etc/rc.conf" abyss_gate_enable=YES >/dev/null
sudo rm -f "$r/var/db/abyss-gate.applied"
sudo zpool export "$pool" || fail "the installed pool would not export"
sudo mdconfig -d -u "${md#md}"; md=""
echo "ok: a one-shot planted on the installed disk: apply as $admin, then reboot"

# ------------------------------------------------ 2. boot, apply, reboot
sudo kldload -n if_tuntap 2>/dev/null || true
tap=$(sudo ifconfig tap create) || fail "no tap interface for the nested machine's vtnet0"
boot() {  # boot LOG [STOP] — until bhyve exits (the guest rebooted), or STOP
          # appears in the log (the desktop never exits by itself); 300s at most.
          # Sets rc to bhyve's exit status, or "stopped" for STOP.
  sudo bhyvectl --destroy --vm=abyssp144 >/dev/null 2>&1 || true
  ( st=0
    sudo timeout 300 bhyve -c 2 -m 2G -A -H -P -l com1,stdio \
      -l bootrom,"$uefi" \
      -s 0,hostbridge -s 31,lpc -s 4,virtio-blk,"$target" -s 5,virtio-net,"$tap" \
      abyssp144 < /dev/null > "$1" 2>&1 || st=$?
    echo "$st" > "$1.status" ) &
  rc=""
  while [ -z "$rc" ]; do
    sleep 0.5
    if [ -s "$1.status" ]; then rc=$(cat "$1.status")
    elif [ -n "${2:-}" ] && grep -q "$2" "$1" 2>/dev/null; then rc=stopped
    fi
  done
  sudo bhyvectl --destroy --vm=abyssp144 >/dev/null 2>&1 || true
  wait
}
echo "== booting the installed machine: apply, then reboot =="
boot "$work/first.log"
show() { grep -i "$2" "$1" | tail -15 | sed 's/^/    /'; }
grep -q "gate: applying, as $admin" "$work/first.log" || { show "$work/first.log" 'gate\|abyss'; fail "the one-shot never ran"; }
grep -q "^gate| done" "$work/first.log" || { show "$work/first.log" 'gate'; fail "the helper did not apply the plan"; }
[ "$(grep -c '^gate| \[' "$work/first.log" || true)" = 6 ] || { show "$work/first.log" 'gate'; fail "the apply did not report six steps"; }
grep -q "gate: before the reboot, vtnet0 has $addr 0xffffff00" "$work/first.log" \
  || { show "$work/first.log" 'gate'; fail "netif restart did not put $addr on vtnet0"; }
grep -q "gate: rebooting" "$work/first.log" || fail "the machine did not ask to reboot"
[ "$rc" = 0 ] || { tail -10 "$work/first.log" | sed 's/^/    /'; fail "bhyve exited $rc, not the 0 of a guest that rebooted (124 is the timeout)"; }
echo "ok: as $admin, through the helper: six steps, $addr on vtnet0 at once, and the machine rebooted itself"

# ------------------------------------------------ 3. and it held
echo "== booting it again =="
boot "$work/second.log" "gate: after the reboot, resolv.conf has"
[ "$rc" = stopped ] || { tail -15 "$work/second.log" | sed 's/^/    /'; fail "the machine did not come back up to the gate (bhyve exited $rc)"; }
grep -q "gate: after the reboot, vtnet0 has $addr 0xffffff00" "$work/second.log" \
  || { show "$work/second.log" 'gate\|vtnet0'; fail "after the reboot vtnet0 does not have $addr"; }
grep -q "gate: after the reboot, the default router is $router" "$work/second.log" \
  || { show "$work/second.log" 'gate'; fail "after the reboot the default router is not $router"; }
grep -q "gate: after the reboot, resolv.conf has $dns" "$work/second.log" \
  || { show "$work/second.log" 'gate'; fail "after the reboot resolv.conf does not name $dns"; }
grep -q "gate: applying" "$work/second.log" && fail "the one-shot ran twice — the second boot proves nothing"
echo "ok: after the reboot: $addr/24 on vtnet0, router $router, name server $dns — from rc.conf alone"

echo "all green (a manual address, set by the administrator through the helper, held across a reboot)."
