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
#                                 [--stay] [--frames N]
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
# Whether the medium stays up after its session ends. Off by default so a test
# can wait for the machine to power itself off; on for a person at the console,
# or for a test that means to drive one.
stay=0
frames=1800
# Shell tracing in the live session, baked in at build time — because on a
# headless medium the console is the only instrument there is, and a session
# that goes quiet tells you nothing about where. `ABYSS_LIVE_TRACE=1` when
# building turns it on (HANDOFF §2.47 is what it found).
trace=${ABYSS_LIVE_TRACE:-}

while [ $# -gt 0 ]; do
  case "$1" in
    --out)       out=$2; shift 2 ;;
    --dist)      dist=$2; shift 2 ;;
    --stage)     stage=$2; shift 2 ;;
    --build-dir) builddir=$2; shift 2 ;;
    --size)      size=$2; shift 2 ;;
    --keep)      keep=1; shift ;;
    --stay)      stay=1; shift ;;
    --frames)    frames=$2; shift 2 ;;
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

# The graphics stack, for a medium that has to come up on a real machine
# (PHASE4 P4.3). Packages rather than an `ldd` closure, because kernel modules
# are not linked by anything we build — nothing in `ldd` will ever mention them,
# and they are the difference between an installer you can see and one you
# cannot. Precise, not transitive: named packages, and only `/boot/modules` and
# `/usr/local` out of each.
#
#   drm-66-kmod   what `drm-kmod` resolves to on FreeBSD 15. 3.7 MB, six
#                 modules: amdgpu, radeonkms, i915kms, drm, ttm, dmabuf.
#   gpu-firmware  Southern Islands, which is what the Mac Pro's FirePros are —
#                 the D300 is Pitcairn, the D500 and D700 are Tahiti. The other
#                 three SI chips ride along at ~190 KB each; a medium that
#                 refuses to start on a slightly different card for want of a
#                 megabyte is a poor trade.
#   seatd         37 KB, and the reason the session can take DRM master without
#                 being root. The desktop runs as an unprivileged user on
#                 purpose (PHASE5 §4.4); libseat is already in our closure, but
#                 the daemon it talks to is not.
GPU_PKGS="drm-66-kmod seatd
          gpu-firmware-amd-kmod-tahiti gpu-firmware-amd-kmod-pitcairn
          gpu-firmware-amd-kmod-verde gpu-firmware-amd-kmod-oland
          gpu-firmware-amd-kmod-hainan"

# The desktop, as a distribution set. Named to match `InstallPlan.desktopSet`,
# which is what makes rc.conf on the installed machine turn the desktop on.
DESKTOP_SET="abyss.txz"
work_sets="${TMPDIR:-/tmp}/abyss-live-sets"

sudo rm -rf "$work_sets"; sudo mkdir -p "$work_sets"

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
# **The desktop is collected once, into a tree of its own**, and then used
# twice: it is copied into the medium so the medium can run it, and it is
# tarred into `abyss.txz` so the installer can install it. What the medium
# carries and what it installs are therefore the same collection, not two that
# have to be kept in step — the same argument as building the medium out of the
# distribution sets in the first place.
de="${TMPDIR:-/tmp}/abyss-live-de"
sudo chflags -R noschg "$de" 2>/dev/null || true
sudo rm -rf "$de"
sudo mkdir -p "$de/usr/local/bin" "$de/usr/local/libexec" "$de/etc/rc.d"

libs=""
for b in $BINARIES; do
  [ -x "$builddir/$b" ] || die "no $b in $builddir — run swift build first"
  libs="$libs
$(ldd "$builddir/$b" 2>/dev/null | awk '{print $3}' | grep '^/usr/local/')"
done
libs=$(echo "$libs" | sort -u | grep .)
[ -n "$libs" ] || die "ldd found nothing — is $builddir a FreeBSD build?"
for lib in $libs; do
  sudo mkdir -p "$de$(dirname "$lib")"
  sudo cp -p "$lib" "$de$lib"
done
# shellcheck disable=SC2086
echo "   $(echo "$libs" | wc -l | tr -d ' ') shared objects, $(du -ch $libs | tail -1 | awk '{print $1}')"

echo "== runtime data"
for d in $DATA; do
  [ -d "$d" ] || die "$d is missing on this machine, so the medium would have no $(basename "$d")"
  sudo mkdir -p "$de$(dirname "$d")"
  sudo cp -R "$d" "$de$(dirname "$d")/"
done
# libxkbcommon looks in /usr/local/share/X11/xkb, which on FreeBSD is a symlink
# into the versioned xkeyboard-config directory. Copying the target without the
# link leaves a compositor that cannot compile a keymap.
#
# **Carried on purpose, and not yet exercised.** Removing the layouts entirely
# leaves `live-medium.sh` green, because a headless session with no input device
# never compiles a keymap — so nothing here proves they are needed. They are:
# the installer (P5.4) is typed into. Said out loud so the green is not misread.
sudo mkdir -p "$de/usr/local/share/X11"
sudo ln -sf ../xkeyboard-config-2 "$de/usr/local/share/X11/xkb"

echo "== the graphics stack"
# Fetched into the *desktop* tree, so that what the medium runs and what the
# installer installs stay the same collection — a machine installed from this
# medium needs these modules exactly as much as the medium does.
gpudir="${TMPDIR:-/tmp}/abyss-live-gpu"
sudo rm -rf "$gpudir"; sudo mkdir -p "$gpudir"
# shellcheck disable=SC2086
if sudo pkg fetch -y -d -o "$gpudir" $GPU_PKGS > /dev/null 2>&1; then
  n=0
  for pkgfile in $(sudo find "$gpudir" -name '*.pkg'); do
    # `--exclude '+*'` drops pkg's own metadata (+MANIFEST and friends); what is
    # left is the payload at absolute paths, which tar re-roots for us.
    sudo tar -xf "$pkgfile" -C "$de" --exclude '+*' 2>/dev/null && n=$((n + 1))
  done
  mods=$(sudo find "$de/boot/modules" -name '*.ko' 2>/dev/null | wc -l | tr -d ' ')
  echo "   $n package(s), $mods kernel modules, $(sudo du -sh "$de/boot" 2>/dev/null | awk '{print $1}')"
  [ "$mods" -gt 4 ] || die "the graphics packages produced only $mods modules"
else
  # A medium with no GPU stack still installs and still runs headless — it just
  # cannot be *seen* on real hardware. Loud, because that is the whole point of
  # this pass and a silent omission would look like a driver problem later.
  echo "   WARNING: could not fetch $GPU_PKGS — this medium has no graphics"
  echo "            stack and will come up blank on real hardware."
fi
sudo rm -rf "$gpudir"

echo "== the desktop"
for b in $BINARIES; do
  sudo install -m 755 "$builddir/$b" "$de/usr/local/bin/$b"
done
echo "   $(echo $BINARIES | wc -w | tr -d ' ') binaries in /usr/local/bin"

# How an installed machine starts the desktop. Ships inside the set, so a system
# that extracted `abyss.txz` has it — and `rc.conf` turns it on only when that
# set was installed (de/install/Steps.swift).
sudo sh -c "cat > $de/usr/local/libexec/abyss-session" <<'SESSION'
#!/bin/sh
# One `anchor` command brings up the whole desktop (P8.4).
set -u
export ABYSS_RUNTIME_DIR="${ABYSS_RUNTIME_DIR:-/var/run/abyss}"
export XDG_RUNTIME_DIR="$ABYSS_RUNTIME_DIR"
mkdir -p "$ABYSS_RUNTIME_DIR" && chmod 700 "$ABYSS_RUNTIME_DIR"
sock="${ABYSS_WAYLAND_SOCKET:-abyss-0}"
mode="${ABYSS_SESSION_MODE:-desktop}"
frames="${ABYSS_SESSION_FRAMES:-0}"
limit=""
[ "$frames" = 0 ] || limit="--frames $frames"

# **Use the display if there is one.**
#
# `--backend auto` is right on a machine with a GPU and wrong everywhere else:
# in the build VM there is no `/dev/dri` at all, and asking for it there would
# take the harness's 39 live modes down with it. So the session looks. This is
# the one place in the tree that decides between the two, and it decides by
# what the machine has rather than by what somebody remembered to pass.
#
# The pixman pin that makes `--capture` work applies to headless only, so on a
# real display the capture is expected to fail — which is why the frame is a
# diagnostic and never an assertion on metal.
backend=headless
for card in /dev/dri/card*; do
  [ -e "$card" ] && backend=auto && break
done
echo "abyss-session: $backend backend ($(ls /dev/dri 2>/dev/null | tr '\n' ' ' || echo 'no /dev/dri'))"

exec /usr/local/bin/anchor \
  --mode "$mode" \
  --compositor "/usr/local/bin/undertow run --hz 60 $limit --backend $backend \
                --width ${ABYSS_WIDTH:-1024} --height ${ABYSS_HEIGHT:-768} \
                --socket $sock ${ABYSS_CAPTURE:+--capture $ABYSS_CAPTURE}" \
  --display "$sock"
SESSION
sudo chmod 755 "$de/usr/local/libexec/abyss-session"

sudo sh -c "cat > $de/etc/rc.d/abyss_desktop" <<'RCD'
#!/bin/sh
# PROVIDE: abyss_desktop
# REQUIRE: LOGIN
# KEYWORD: shutdown
. /etc/rc.subr
name="abyss_desktop"
rcvar="abyss_desktop_enable"
start_cmd="abyss_desktop_start"
stop_cmd=":"
: ${abyss_desktop_user:=""}
abyss_desktop_start()
{
	echo "abyss: starting the desktop${abyss_desktop_user:+ for $abyss_desktop_user}"
	if [ -n "$abyss_desktop_user" ]; then
		# The desktop belongs to whoever this machine was installed for. It
		# runs as them, not as root — the one privileged thing a desktop ever
		# needs is the installer, and this machine is already installed.
		#
		# **rc makes the runtime directory, because the session cannot.**
		# /var/run belongs to root, so an unprivileged session's own `mkdir`
		# fails and `anchor` exits with "no runtime directory" — which reads as
		# a supervisor bug and is a permissions one. The live medium got this
		# right because root set the directory up first; the installed system
		# did not, so it showed up only on the far side of an install.
		rundir="/var/run/abyss-$abyss_desktop_user"
		mkdir -p "$rundir"
		chown "$abyss_desktop_user" "$rundir"
		chmod 700 "$rundir"
		su -m "$abyss_desktop_user" -c \
			"ABYSS_RUNTIME_DIR=$rundir \
			 /usr/local/libexec/abyss-session" 2>&1 | sed 's/^/abyss| /'
	else
		/usr/local/libexec/abyss-session 2>&1 | sed 's/^/abyss| /'
	fi
	echo "abyss: the desktop exited $?"
}
load_rc_config $name
run_rc_command "$1"
RCD
sudo chmod 755 "$de/etc/rc.d/abyss_desktop"

echo "== abyss.txz — the desktop, as a distribution set"
sudo tar -cJf "$work_sets/$DESKTOP_SET" -C "$de" .
echo "   $(sudo ls -l "$work_sets/$DESKTOP_SET" | awk '{print $5}') bytes"

# ...and the same tree into the medium, so the medium runs what it installs.
sudo tar -cf - -C "$de" . | sudo tar -xpf - -C "$stage"

echo "== configuring the live system"
sudo sh -c "cat > $stage/etc/rc.conf" <<'RC'
# The AbyssBSD live medium.
hostname="abyss-live"
ifconfig_DEFAULT="DHCP"
sendmail_enable="NONE"
# The installer, started by rc rather than by a login: our compositor is headless
# (Phase 6 — real KMS is Phase 4), so there is no tty to log in on and nothing
# for a getty to hand over to.
abyss_live_enable="YES"
# The medium carries /etc/rc.d/abyss_desktop, because it carries the desktop set
# it installs — but the medium runs the INSTALLER session, not the desktop one.
# Saying so explicitly is what stops rc warning about an unset variable on every
# boot, which is noise in the one log this machine uses to report on itself.
abyss_desktop_enable="NO"

# **The GPU driver, and the thing that lets an unprivileged session use it.**
# `kld_list` rather than loader.conf, which is what FreeBSD's own drm-kmod
# instructions say: the module wants a running system, not a loader. On a
# machine with no AMD card this loads and attaches nothing — measured in the
# build VM, which has no GPU at all — so it is safe to ask for unconditionally.
kld_list="amdgpu"
seatd_enable="YES"
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

# **The Mac Pro scrolls "pcib26: Power Fault Detected" forever without this,
# and nothing else on the screen survives.** The 2013 Mac Pro's internal PCIe
# bridges report a power-fault bit that never clears, so pcib(4) re-logs it in a
# loop and the installer is buried under it. It is a loader tunable — there is
# no sysctl to undo it once the machine is up — so it has to be here, on the
# medium, before anyone can see anything. Measured on the target machine: the
# message is what a MacPro6,1 does, not what AbyssBSD does.
hw.pci.enable_pcie_hp="0"

# **Southern Islands is off by default in amdgpu, and the Mac Pro is Southern
# Islands.** Without this the FirePros are simply not claimed and the machine
# comes up with no display — which looks like a missing driver and is a default.
# `amdgpu` prints the fix itself ("Use radeon.si_support=0 amdgpu.si_support=1
# to override") in Linux's names; FreeBSD's linuxkpi registers BOTH of the
# spellings below, which was measured by loading the module and reading
# `sysctl -aN`, not guessed from the message.
compat.linuxkpi.amdgpu_si_support="1"
hw.amdgpu.si_support="1"
# ...and radeonkms must not claim them first. It is not in `kld_list`, so this
# is belt to that brace.
compat.linuxkpi.radeon_si_support="0"
hw.radeon.si_support="0"
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
# Two values are decided when the image is built and have nowhere to live at boot
# time on a medium with no configuration of its own — so they are written into
# the script, by the one heredoc here that interpolates.
sudo sh -c "cat > $stage/usr/local/libexec/abyss-live-session" <<EOF
#!/bin/sh
stay=$stay
frames=$frames
ABYSS_LIVE_TRACE=$trace
EOF
sudo sh -c "cat >> $stage/usr/local/libexec/abyss-live-session" <<'SESSION'
# The live session: the installer, on the real desktop.
#
# Two halves, and the split is the whole architecture (PHASE5 §1):
#
#   abyss-install   as ROOT, because partitioning a disk needs root
#   the session     as an UNPRIVILEGED user, because a GUI does not
#
# The medium could have run everything as root — it is a live image and nobody
# would notice. Not doing so is what makes the peer check load-bearing here
# rather than ornamental: the installer hands its socket to exactly one uid and
# then asks the kernel who called.
#
# **Where it runs, and where it talks, depends on whether anybody can see it.**
# Same rule as the backend, and for the same reason — ask the machine, do not
# take a flag:
#
#   No display (the build VM). A harness is watching, and the console is the
#   only channel it has. So: FOREGROUND, reporting to the console, and the
#   virtual terminals do not arrive until the session ends. That is not a
#   limitation to work around — a backgrounded session goes **silent** the
#   moment `getty` starts, because getty calls `revoke(2)` on the console and
#   invalidates every descriptor anyone else holds to it (HANDOFF §2.47). It
#   printed exactly one line and then nothing, three times, and looked like a
#   crash every time.
#
#   A display (a Mac Pro). A person is watching the screen, and what they need
#   is a console they can switch to WHILE the installer is up — which means rc
#   has to finish, which means the session has to be in the background. Its own
#   log then goes to a file rather than a terminal it cannot keep, and Alt-F2
#   reaches a getty on another virtual terminal while the compositor holds its
#   own.
#
# One machine cannot have both, and which one it wants is not a matter of taste.
set -u
user=abyss
rundir="/var/run/abyss-$user"
mkdir -p "$rundir" && chown "$user" "$rundir" && chmod 700 "$rundir"

run() {
  # **Write to /dev/console, not to whatever stdout rc happened to have.** This
  # runs in the background so the console comes up while the desktop does; once
  # rc finishes, getty takes that terminal and everything this process says
  # afterwards is lost. The first version printed exactly one line and then went
  # silent, which looked like a crash and was a redirection.
  [ -z "${ABYSS_LIVE_TRACE:-}" ] || set -x
  echo "abyss-live: $(cat /etc/abyss-live)"

  # The privileged half first: the disk spoke is empty until it answers.
  # Straight to the console, not into a file read at the end: a service that
  # fails to start is the thing you most need to see, and the end may never
  # come. (It didn't: the first run of this said only "THE INSTALLER SERVICE
  # NEVER STARTED", with the reason sitting in a log nobody had reached yet.)
  env ABYSS_RUNTIME_DIR="$rundir" /usr/local/bin/abyss-install \
      --uid "$(id -u "$user")" 2>&1 | sed 's/^/install| /' &
  i=0
  while [ ! -S "$rundir/install.sock" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
  [ -S "$rundir/install.sock" ] \
    && echo "abyss-live: the installer service is up, for uid $(id -u "$user")" \
    || echo "abyss-live: THE INSTALLER SERVICE NEVER STARTED"

  # `$rundir` is expanded here, by root, before su — the session's own shell has
  # no reason to know where root decided to put it.
  su -m "$user" -c "ABYSS_RUNTIME_DIR=$rundir \
                    ABYSS_SESSION_MODE=installer \
                    ABYSS_SESSION_FRAMES=$frames \
                    ABYSS_CAPTURE=$rundir/frame.ppm \
                    ABYSS_WAYLAND_SOCKET=abyss-live-0 \
                    /usr/local/libexec/abyss-session" > /var/log/abyss-live.log 2>&1
  rc=$?

  echo "abyss-live: session exited $rc"
  sed 's/^/abyss-live| /' /var/log/abyss-live.log
  # The session runs as an unprivileged user and cannot write to /var/log —
  # which is the right answer to "why did the capture fail", and cost a boot to
  # find. It writes into its own runtime directory; root moves it here.
  shot=/var/log/abyss-live.ppm
  [ -s "$rundir/frame.ppm" ] && cp "$rundir/frame.ppm" "$shot"
  if [ -s "$shot" ]; then
    echo "abyss-live: captured $(stat -f %z "$shot") bytes of desktop to $shot"
  else
    echo "abyss-live: NO FRAME CAPTURED"
  fi
  echo "abyss-live: done"
  # Leave the machine off rather than sitting at a login prompt: the medium's
  # job in a test is to come up, say what happened, and stop, so the harness
  # never has to guess whether it is finished or merely slow. Built with
  # `--stay` it stays, for a person at the console or a test driving one.
  # Never power off a machine somebody is looking at.
  [ "$stay" = 1 ] || [ "$haveDisplay" = 1 ] || (sleep 2; /sbin/shutdown -p now) &
}

# The choice above, made from what the machine has.
haveDisplay=0
for card in /dev/dri/card*; do
  [ -e "$card" ] && haveDisplay=1 && break
done

if [ "$haveDisplay" = 1 ]; then
  echo "abyss-live: a display is present — the session goes to the background so"
  echo "abyss-live: the virtual terminals come up; its log is /var/log/abyss-live.log"
  run >> /var/log/abyss-live.log 2>&1 &
else
  run
fi
SESSION
sudo chmod 755 "$stage/usr/local/libexec/abyss-live-session"

# The user the session runs as. No password: this is a live medium, the console
# is the machine, and an account that cannot be logged into cannot start a
# session either.
# Root with no password, as FreeBSD's own installation media have: the console
# IS the machine on a live medium, and one you cannot log into is one you can
# neither rescue nor drive. Nothing that gets *installed* inherits this — the
# installed system's accounts come from the plan (`rootPasswordHash` is `*`).
sudo sed -i '' 's|^root:[^:]*:|root::|' "$stage/etc/master.passwd"

sudo sh -c "cat >> $stage/etc/master.passwd" <<'PW'
abyss::1001:1001::0:0:AbyssBSD live:/home/abyss:/bin/sh
PW
sudo sh -c "cat >> $stage/etc/group" <<'GRP'
abyss:*:1001:
GRP
# seatd's socket is group `video`, which is how an unprivileged session is
# allowed to ask for DRM master. Without this the session runs, finds a card it
# may not open, and falls back to no display at all.
sudo sed -i '' 's|^video:\*:44:.*|video:*:44:abyss|' "$stage/etc/group" 2>/dev/null || true
grep -q '^video:' "$stage/etc/group" 2>/dev/null \
  || sudo sh -c "echo 'video:*:44:abyss' >> $stage/etc/group"
sudo mkdir -p "$stage/home/abyss"
# So that someone logging in at the live console can just run
# `abyss-installctl` — the installer service belongs to this user's session and
# lives in that session's runtime directory, and nothing else would find it.
sudo sh -c "cat > $stage/home/abyss/.profile" <<'PROF'
ABYSS_RUNTIME_DIR=/var/run/abyss-abyss
export ABYSS_RUNTIME_DIR
PATH=$PATH:/usr/local/bin
export PATH
PROF
sudo chown -R 1001:1001 "$stage/home/abyss"
sudo pwd_mkdb -p -d "$stage/etc" "$stage/etc/master.passwd"

echo "== the distribution sets the medium installs"
# **A live installer with nothing to install is a demonstration.** The medium
# carries the same base.txz and kernel.txz it was built from, plus the desktop
# set built above — so the machine it installs is the machine it is.
sudo mkdir -p "$stage/usr/freebsd-dist"
for set in base.txz kernel.txz; do
  sudo cp -p "$dist/$set" "$stage/usr/freebsd-dist/$set"
done
sudo cp -p "$work_sets/$DESKTOP_SET" "$stage/usr/freebsd-dist/$DESKTOP_SET"
sudo ls -1 "$stage/usr/freebsd-dist" | sed 's/^/   /'

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
