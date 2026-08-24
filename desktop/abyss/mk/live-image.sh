#!/bin/sh
# AbyssBSD Swift DE — build the live medium (PHASE5.md P5.3).
#
# A bootable image carrying FreeBSD, our desktop, and everything it links —
# built out of the **same distribution sets the installer extracts**, with base
# tools only. No `make release`, no source tree, no world build: `src.txz` is
# 118 MB and a world build is hours for an image whose contents we did not
# compile anyway (PHASE5 §4.3).
#
# One artifact, two uses. What the medium carries is what the installer
# installs, so there is no second source of truth about what AbyssBSD *is*.
#
#   usage: abyss/mk/live-image.sh [--out PATH] [--dist DIR] [--stage DIR]
#                                 [--build-dir DIR] [--size N] [--keep]
#
# FreeBSD only, and it says so: `makefs`, `mkimg` and the runtime closure have no analogue
# on the dev box, and an image built anywhere else would be a different image.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)

out="$root/../abyss-live.img"
dist="${ABYSS_DIST_DIR:-/home/$(id -un)/dist}"
stage="${TMPDIR:-/tmp}/abyss-live-stage"
builddir="$root/.build/debug"
size=3g
keep=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out)       out=$2; shift 2 ;;
    --dist)      dist=$2; shift 2 ;;
    --stage)     stage=$2; shift 2 ;;
    --build-dir) builddir=$2; shift 2 ;;
    --size)      size=$2; shift 2 ;;
    --keep)      keep=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "usage: live-image.sh [--out PATH] [--dist DIR] [--size N] [--keep]" >&2; exit 2 ;;
  esac
done

die() { echo "live-image: $1" >&2; exit 1; }

[ "$(uname -s)" = FreeBSD ] || die "the medium is built on FreeBSD (makefs, mkimg, and an ldd that agrees with it)"
[ -s "$dist/base.txz" ] && [ -s "$dist/kernel.txz" ] || die "no distribution sets in $dist"
[ -x "$builddir/undertow" ] || die "no build in $builddir — run swift build first"
sudo -n true 2>/dev/null || die "this needs passwordless sudo (it extracts a base system)"

# Runtime data the desktop reads by path rather than links against, so no
# amount of `ldd` will find it: the four DejaVu faces `de/ctext/ctext.c` names
# for FreeBSD (the whole directory, because losing text is a poor trade for
# 8 MB), the keyboard layouts libxkbcommon compiles keymaps from, and
# fontconfig's configuration — linked in through cairo even though we select
# faces by path ourselves.
DATA="/usr/local/share/fonts/dejavu
      /usr/local/share/xkeyboard-config-2
      /usr/local/etc/fonts"

# The products that go on the medium. An explicit list, not a glob over
# `.build/debug`, because that directory is full of SwiftPM's own intermediates.
BINARIES="undertow anchor abyssctl AquaDemo abyss-portal abyss-dbus
          abyss-install abyss-installctl abyssopen abyssgrab abyssnotify ventsctl"

echo "== staging root: $stage"
# `chflags` first, always. An extracted base system carries schg on a good deal
# of /var and /usr/bin, so `rm -rf` reports "Directory not empty" and explains
# nothing — a rebuild script without this line works exactly once (HANDOFF §2.43).
sudo chflags -R noschg "$stage" 2>/dev/null || true
sudo rm -rf "$stage"
sudo mkdir -p "$stage"

echo "== extracting base.txz and kernel.txz"
sudo tar -xpf "$dist/base.txz"   -C "$stage"
sudo tar -xpf "$dist/kernel.txz" -C "$stage"

echo "== the runtime closure"
# **Computed from the binaries, not installed from packages.** `pkg -r` was the
# obvious route and it is the wrong one for an appliance image: asking for
# `wlroots019 cairo harfbuzz dejavu …` produced a **5.66 GB** staging root, of
# which the desktop loads almost nothing. wlroots pulls Xwayland, mesa pulls
# LLVM, something pulls avahi — 409 binaries in /usr/local/bin, and `2to3` on a
# medium whose job is to partition a disk.
#
# `ldd` over what we built answers the question exactly: **84 shared objects,
# 22 MB**, transitively closed, and it cannot drift from the binaries because it
# IS the binaries. That includes the Swift runtime, where the arithmetic is
# starkest — the swift6 package is 2.70 GiB of toolchain and we load 19 libraries
# from it (PHASE5 §6.3). Paths are preserved, because that is where each
# binary's rpath says to look.
#
# The cost, stated rather than discovered: **the medium has no package
# database**, so nothing on it can `pkg install` anything. For a live installer
# that is fine — it runs one desktop and writes one disk. It is also why nothing
# here is a substitute for how the *installed* system gets its packages.
# **Only /usr/local.** `ldd` also names /lib/libc.so.7 and friends, and those
# must come from the distribution sets rather than from whichever machine did
# the building — a medium whose base libraries are a copy of the builder's is a
# mixture of two systems, and base.txz marks them `schg` so the attempt fails
# loudly, which is how this was found. (Our binaries are compiled against the
# builder's 15.0-RELEASE-p11 and run against the sets' 15.0-RELEASE; ABI is
# stable within a major release, which is the whole point of the guarantee.)
libs=""
for b in $BINARIES; do
  [ -x "$builddir/$b" ] || die "no $b in $builddir — run swift build first"
  libs="$libs
$(ldd "$builddir/$b" 2>/dev/null | awk '{print $3}' | grep '^/usr/local/')"
done
libs=$(echo "$libs" | sort -u | grep .)
[ -n "$libs" ] || die "ldd found nothing — is $builddir a FreeBSD build?"
for lib in $libs; do
  sudo mkdir -p "$stage$(dirname "$lib")"
  sudo cp -p "$lib" "$stage$lib"
done
# shellcheck disable=SC2086
echo "   $(echo "$libs" | wc -l | tr -d ' ') shared objects, $(du -ch $libs | tail -1 | awk '{print $1}')"

echo "== runtime data"
for d in $DATA; do
  [ -d "$d" ] || die "$d is missing on this machine, so the medium would have no $(basename "$d")"
  sudo mkdir -p "$stage$(dirname "$d")"
  sudo cp -R "$d" "$stage$(dirname "$d")/"
done
# libxkbcommon looks in /usr/local/share/X11/xkb, which on FreeBSD is a symlink
# into the versioned xkeyboard-config directory. Copying the target without the
# link leaves a compositor that cannot compile a keymap.
#
# **Carried on purpose, and not yet exercised.** Removing the layouts entirely
# leaves `live-medium.sh` green, because a headless session with no input device
# never compiles a keymap — so nothing here proves they are needed. They are:
# the installer (P5.4) is typed into. Said out loud so the green is not misread.
sudo mkdir -p "$stage/usr/local/share/X11"
sudo ln -sf ../xkeyboard-config-2 "$stage/usr/local/share/X11/xkb"

echo "== the desktop"
sudo mkdir -p "$stage/usr/local/bin"
for b in $BINARIES; do
  sudo install -m 755 "$builddir/$b" "$stage/usr/local/bin/$b"
done
echo "   $(echo $BINARIES | wc -w | tr -d ' ') binaries in /usr/local/bin"

echo "== configuring the live system"
sudo sh -c "cat > $stage/etc/rc.conf" <<'RC'
# The AbyssBSD live medium.
hostname="abyss-live"
ifconfig_DEFAULT="DHCP"
sendmail_enable="NONE"
# The desktop, started by rc rather than by a login: our compositor is headless
# (Phase 6 — real KMS is Phase 4), so there is no tty to log in on and nothing
# for a getty to hand over to.
abyss_live_enable="YES"
RC

sudo sh -c "cat > $stage/boot/loader.conf" <<'LOADER'
# The AbyssBSD live medium.
vfs.root.mountfrom="ufs:/dev/ufs/ABYSSLIVE"
boot_serial="YES"
comconsole_speed="115200"
console="comconsole,vidconsole"
# The same reason the installer writes it (HANDOFF §2.43): GEOM's disk-ident
# class can consume the disk and leave no /dev/ufs or /dev/gpt provider at all.
kern.geom.label.disk_ident.enable="0"
LOADER

# **The root is mounted read-write, and that is a v1 choice with a cost.** A
# medium on a real USB stick wants a read-only root with tmpfs over /tmp and
# /var, because a stick can be pulled out mid-write. This is a disk image in a
# VM, the installer writes almost nothing, and read-write keeps the whole
# arrangement to one line — but it is the thing to fix before anyone puts this
# on a stick. Said here rather than discovered later.
sudo sh -c "cat > $stage/etc/fstab" <<'FSTAB'
/dev/ufs/ABYSSLIVE	/	ufs	rw	1	1
FSTAB

sudo sh -c "cat > $stage/etc/rc.d/abyss_live" <<'RCD'
#!/bin/sh
# PROVIDE: abyss_live
# REQUIRE: LOGIN
# KEYWORD: shutdown
. /etc/rc.subr
name="abyss_live"
rcvar="abyss_live_enable"
start_cmd="abyss_live_start"
stop_cmd=":"
abyss_live_start()
{
	echo "abyss: starting the desktop"
	/usr/local/libexec/abyss-live-session
}
load_rc_config $name
run_rc_command "$1"
RCD
sudo chmod 755 "$stage/etc/rc.d/abyss_live"

sudo mkdir -p "$stage/usr/local/libexec"
sudo sh -c "cat > $stage/usr/local/libexec/abyss-live-session" <<'SESSION'
#!/bin/sh
# The live session: one `anchor` command brings up the whole desktop (P8.4),
# here on a machine that has never built any of it.
#
# Everything it says goes to the console on purpose. This is the only report a
# live medium can make about itself, and a medium that comes up silently and
# wrongly is indistinguishable from one that works.
set -u
export ABYSS_RUNTIME_DIR=/var/run/abyss
export XDG_RUNTIME_DIR=/var/run/abyss
export HOME=/root
mkdir -p "$ABYSS_RUNTIME_DIR" && chmod 700 "$ABYSS_RUNTIME_DIR"

sock=abyss-live-0
# `.ppm`, because that is what `undertow --capture` writes — P6, not PNG. The
# frame is left on the medium's own filesystem, which is the whole reason the
# root is mounted read-write: it is the only evidence a headless live system can
# leave behind.
shot=/var/log/abyss-live.ppm
frames="${ABYSS_LIVE_FRAMES:-180}"

echo "abyss-live: $(cat /etc/abyss-live)"
/usr/local/bin/anchor \
  --compositor "/usr/local/bin/undertow run --hz 60 --frames $frames \
                --width 1024 --height 768 --socket $sock \
                --capture $shot --assert-layers 3" \
  --display "$sock" > /var/log/abyss-live.log 2>&1
rc=$?

echo "abyss-live: session exited $rc"
sed 's/^/abyss-live| /' /var/log/abyss-live.log
if [ -s "$shot" ]; then
  echo "abyss-live: captured $(stat -f %z "$shot") bytes of desktop to $shot"
else
  echo "abyss-live: NO FRAME CAPTURED"
fi
# Leave the machine off rather than sitting at a login prompt: the medium's job
# in a test is to come up, say what happened, and stop, so the harness never has
# to guess whether it is finished or merely slow.
[ -n "${ABYSS_LIVE_STAY:-}" ] || (sleep 2; /sbin/shutdown -p now) &
echo "abyss-live: done"
SESSION
sudo chmod 755 "$stage/usr/local/libexec/abyss-live-session"

# A marker, so "it booted" can never be satisfied by some other FreeBSD.
sudo sh -c "echo 'AbyssBSD live medium, built by abyss/mk/live-image.sh' > $stage/etc/abyss-live"

echo "== assembling"
esp="${TMPDIR:-/tmp}/abyss-live-esp.img"
ufs="${TMPDIR:-/tmp}/abyss-live-root.ufs"
espdir="${TMPDIR:-/tmp}/abyss-live-espdir"
sudo rm -rf "$espdir" "$esp" "$ufs"
sudo mkdir -p "$espdir/EFI/BOOT"
# The loader out of what we just staged, not out of the machine doing the
# building — the medium must boot the loader that matches its own kernel.
sudo cp "$stage/boot/loader.efi" "$espdir/EFI/BOOT/BOOTX64.efi"
sudo makefs -t msdos -o fat_type=32,sectors_per_cluster=1,volume_label=EFISYS \
            -s 40m "$esp" "$espdir" > /dev/null
sudo makefs -t ffs -o label=ABYSSLIVE -o version=2 -b 10% -f 10% \
            -s "$size" "$ufs" "$stage" > /dev/null

sudo rm -f "$out"
sudo mkimg -s gpt -b "$stage/boot/pmbr" \
  -p efi:="$esp" \
  -p freebsd-boot:="$stage/boot/gptboot" \
  -p freebsd-ufs:="$ufs" \
  -o "$out"
sudo chown "$(id -un)" "$out"
sudo rm -f "$esp" "$ufs"
sudo rm -rf "$espdir"
[ "$keep" = 1 ] || { sudo chflags -R noschg "$stage" 2>/dev/null || true; sudo rm -rf "$stage"; }

echo "== $out  ($(du -h "$out" | awk '{print $1}'))"
