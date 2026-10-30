#!/bin/sh
# Start an AbyssBSD VM under bhyve. This runs ON the FreeBSD box (run.sh
# sends it there with ssh), as the user whose home holds the VM's files,
# with doas for bhyve itself.
#
#   bhyve-run.sh <name> <cpus> <mem> <disk.raw> <tap> <mac> [seed.iso]
#
# The guest's NIC is a tap on bridge0 (igc0's bridge: the LAN), with a fixed
# MAC so its DHCP lease stays put. com1 is a null modem, /dev/nmdm-abyss-
# <name>.1A: its B side is copied to serial-<name>.log beside the disk, which
# run.sh reads the guest's address from, and `doas cu -l /dev/nmdm-abyss-
# <name>.1B` is the console when ssh is not. bhyve exits 0 when the
# guest reboots and is started again; any other exit (power-off is 1) ends
# the VM.
set -eu
name=$1 cpus=$2 mem=$3 disk=$4 tap=$5 mac=$6 seed=${7:-}
home=$(cd "$(dirname "$disk")" && pwd)
disk=$home/$(basename "$disk")
log=$home/serial-$name.log
code=/usr/local/share/uefi-firmware/BHYVE_UEFI_CODE.fd
vars=$home/vars-$name.fd

[ -f "$disk" ] || { echo "bhyve-run: no disk $disk (bhyve-migrate.sh puts one there)" >&2; exit 1; }
[ -f "$code" ] || { echo "bhyve-run: no $code (pkg install edk2-bhyve)" >&2; exit 1; }
if [ -e "/dev/vmm/$name" ]; then
  echo "bhyve-run: $name is already running"
  exit 0
fi
doas kldload -n vmm if_bridge if_tuntap nmdm
con=/dev/nmdm-abyss-$name.1
ifconfig bridge0 >/dev/null 2>&1 || { echo "bhyve-run: no bridge0 (rc.conf: cloned_interfaces, ifconfig_bridge0)" >&2; exit 1; }
ifconfig "$tap" >/dev/null 2>&1 || doas ifconfig "$tap" create
ifconfig bridge0 | grep -q "member: $tap " || doas ifconfig bridge0 addm "$tap"
[ -f "$vars" ] || cp /usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd "$vars"

cd_slot=
[ -n "$seed" ] && [ -f "$seed" ] && cd_slot="-s 5,ahci-cd,$seed,ro"
cat > "$home/loop-$name.sh" <<EOF
#!/bin/sh
# Written by bhyve-run.sh: $name until it powers off.
while :; do
  bhyve -c $cpus -m $mem -H -w -u \\
    -s 0,hostbridge -s 31,lpc -l com1,${con}A \\
    -l bootrom,$code,$vars \\
    -s 2,virtio-blk,$disk \\
    -s 3,virtio-net,$tap,mac=$mac \\
    -s 4,virtio-rnd $cd_slot \\
    $name
  rc=\$?
  bhyvectl --destroy --vm=$name 2>/dev/null
  echo "[bhyve-run] bhyve exited \$rc"
  [ \$rc -eq 0 ] || break
done
kill \$(cat $home/pid-$name-console) 2>/dev/null
EOF
: > "$log"
# The console's copy first, so nothing the firmware says is lost.
doas daemon -f -o "$log" -p "$home/pid-$name-console" cat "${con}B"
doas daemon -f -p "$home/pid-$name" sh "$home/loop-$name.sh"
echo "bhyve-run: started $name ($cpus vCPUs, $mem, $tap, $mac); serial: $log"
