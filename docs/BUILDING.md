# Building AbyssBSD on a Linux workstation

This guide takes a fresh Linux machine to the point where it can build every
piece of AbyssBSD and put it on a Radxa Dragon Q8B. It replaces the macOS
recipes used until 2026-09-30. macOS's case-insensitive filesystem could not
check out `firmware/`, and its toolchain needed a pile of workarounds.

What is built where:

| Piece | Built on | Output |
|---|---|---|
| Kernel + base modules (`src/`) | Linux, cross, `tools/build/make.py` | `kernel`, `*.ko` for arm64 (or amd64) |
| drm-kmod (`kmod/drm/`), msm (`kmod/drm-msm/`), firmware kmods (`firmware/`) | Linux, cross, inside `make.py buildenv` | `drm.ko`, `sysfbdrm.ko`, `msm.ko`, `qcom_*.ko` |
| Q8B boot image | Linux (no root), from a snapshot `base.txz` + our kernel | `q8b-usb.img` |
| Ports overlay (`ports/`): Mesa, libdrm, packaged kmods | **FreeBSD only** (poudriere or `make package`) | `.pkg` files |
| Desktop (`desktop/`) | Linux for the dev loop; FreeBSD VM for the truth | `swift build` products |

Anything marked *unverified on Linux* below is our best translation of a
recipe that was only run on the Mac. Once it has been run, fix the doc and
remove the marker.

---

## 1. Host setup

A case-sensitive filesystem with about 60 GB free: the kernel obj tree is about
6 GB per architecture, the image workspace about 7 GB, the VM disks about 80 GB
sparse.

Packages (Debian/Ubuntu names; adjust for your distribution):

```sh
# FreeBSD cross-build
sudo apt install git python3 clang lld llvm libarchive-dev libbz2-dev zlib1g-dev
# desktop (pkg-config names from desktop/Package.swift)
sudo apt install pkg-config libwayland-dev wayland-protocols libxkbcommon-dev \
    libcairo2-dev libpixman-1-dev libfreetype-dev libharfbuzz-dev \
    libfontconfig-dev libwlroots-0.19-dev sway   # 0.20 after the upgrade (MIGRATION.md §5)
# desktop VM harness
sudo apt install qemu-system-x86 qemu-utils rsync python3-pycdlib
```

The desktop needs Swift 6.3.x (installed with swiftly). The FreeBSD guest has
`swift6` 6.3.2.

`make.py` finds `clang`, `clang++`, `clang-cpp` and `ld.lld` on `PATH`. On
Debian, the versioned tools live in `/usr/lib/llvm-NN/bin`: pass that
directory as `--cross-bindir`, or give a bindir of symlinks as below.

---

## 2. Clone

```sh
git clone https://github.com/JamesKane/AbyssBSD.git
cd AbyssBSD
git submodule update --init src kmod/drm firmware      # firmware is fine on Linux
```

Before trusting the result, check that the submodule pins are current (see
[MIGRATION.md](MIGRATION.md) §1). The pins set on 2026-09-30 predated Phase C,
and the Phase C glue in `kmod/drm-msm` needs a kernel with
`__FreeBSD_version` ≥ 1600031.

Paths used below:

```sh
export ABYSS=$PWD
export SRC=$ABYSS/src
export OBJ=$HOME/abyss-build/obj          # MAKEOBJDIRPREFIX; must already exist
export XBIN=$HOME/abyss-build/xbin        # cross tool bindir
mkdir -p $OBJ $XBIN
```

Keep `OBJ`, the image workspace and VM artifacts **outside the monorepo**.
The monorepo has a `.gitignore` for the usual strays, but big trees don't
belong in a git working copy.

---

## 3. Cross toolchain bindir

```sh
LLVM=/usr/lib/llvm-19/bin                 # whatever version you have
for t in clang clang++ clang-cpp ld.lld llvm-nm llvm-objcopy llvm-size \
         llvm-strip llvm-ar llvm-ranlib; do ln -sf $LLVM/$t $XBIN/$t; done
```

Don't put `$XBIN` on `PATH`, and don't alias `ld`. On the Mac, host
bootstrap tools then picked up lld and failed on `-zrelro`. It's probably
harmless on Linux, but keep to the rule.

## 4. Kernel (arm64 GENERIC)

The Q8B runs stock `GENERIC`: every driver we wrote is in `std.qcom` /
`std.dev`, so nothing board-specific is needed in loader.conf.

```sh
cd $SRC
MK="python3 tools/build/make.py --cross-bindir=$XBIN TARGET=arm64 TARGET_ARCH=aarch64 -j$(nproc) \
    -DWITHOUT_CLANG_BOOTSTRAP -DWITHOUT_LLD_BOOTSTRAP \
    -DWITHOUT_LLVM_BINUTILS_BOOTSTRAP -DWITHOUT_ELFTOOLCHAIN_BOOTSTRAP \
    NM=$XBIN/llvm-nm XNM=$XBIN/llvm-nm OBJCOPY=$XBIN/llvm-objcopy XOBJCOPY=$XBIN/llvm-objcopy \
    SIZE=$XBIN/llvm-size STRIP=$XBIN/llvm-strip XSTRIP=$XBIN/llvm-strip"
export MAKEOBJDIRPREFIX=$OBJ

$MK -DWITH_DISK_IMAGE_TOOLS_BOOTSTRAP kernel-toolchain   # once; also builds host makefs/mkimg
$MK buildkernel KERNCONF=GENERIC                           # full: kernel + all modules
$MK buildkernel KERNCONF=GENERIC -DKERNFAST                # incremental, ~1 min
```

The `WITHOUT_*_BOOTSTRAP` flags skip building in-tree LLVM with the host
compiler. On the Mac that step failed. It might work on Linux, but it costs
about an hour for nothing.

The `NM`/`OBJCOPY`/`SIZE`/`STRIP` overrides fixed three macOS failures:
- an empty `offset.inc` from Apple's `nm`;
- missing `objcopy` for `.debug` files;
- missing `size` at kernel link.

With GNU binutils installed they are *probably* unnecessary. They're harmless,
so keep them until someone proves otherwise. If a genoffset failure ever
leaves an empty `offset.inc`, delete the kernel objdir: it isn't regenerated.

Outputs are under `$OBJ$SRC/arm64.aarch64/sys/GENERIC/`, and host `makefs`
and `mkimg` are under `$OBJ$SRC/arm64.aarch64/tmp/legacy/bin/`.

**Always use that explicit path** when copying a kernel. Once the obj tree
also holds amd64, a `find … -name kernel | head -1` can pick the wrong
architecture. It did once, and the board then said "can't load kernel".

### amd64 (regression box)

This is the same recipe with `TARGET=amd64 TARGET_ARCH=amd64`. Pass
`STRIP`/`XSTRIP` to `buildkernel` only: passed to `kernel-toolchain`, they
break `install -s`. We use amd64 to check that LinuxKPI changes don't regress
amdgpu. Our test box has an i7-12700KF and a Radeon RX 6750 XT.

## 5. drm-kmod, msm and firmware modules

These build against the kernel's obj dir (`KERNBUILDDIR`), inside
`make.py buildenv`:

```sh
KB=$OBJ$SRC/arm64.aarch64/sys/GENERIC
bmk() { $MK buildenv BUILDENV_SHELL="make $*"; }

# drm-kmod: dmabuf, drm, sysfbdrm (sysfbdrm is aarch64's default extra)
bmk -C $ABYSS/kmod/drm -j$(nproc) SYSDIR=$SRC/sys KERNBUILDDIR=$KB \
    MAKEOBJDIRPREFIX=$HOME/abyss-build/drmobj KMODS=\'dmabuf drm sysfbdrm\' DEBUG_FLAGS=-g
# msm
bmk -C $ABYSS/kmod/drm-msm -j$(nproc) DRMKMOD=$ABYSS/kmod/drm SYSDIR=$SRC/sys \
    KERNBUILDDIR=$KB MAKEOBJDIRPREFIX=$HOME/abyss-build/msmobj DEBUG_FLAGS=-g
# GPU firmware as kmods (a660 SQE/GMU + the SC8280XP zap shader)
bmk -C $ABYSS/firmware KMODS=msmkmsfw -j$(nproc) SYSDIR=$SRC/sys \
    KERNBUILDDIR=$KB MAKEOBJDIRPREFIX=$HOME/abyss-build/fwobj
```

*Unverified on Linux:* check how the quoting of `KMODS` survives the
`BUILDENV_SHELL` round trip.

**KLD_TIED rule.** After any `__FreeBSD_version` bump (LinuxKPI changes bump
it), modules built with the kernel, and drm-kmod built with `KERNBUILDDIR`,
only load on that exact kernel. So:
- deploy the **whole** kernel together with **all** its modules;
- rebuild drm-kmod and msm;
- otherwise every load fails with "depends on kernel - version mismatch".

## 6. Q8B boot image (no root needed)

The recipe is `tools/q8b/mkimage.sh` (see [MIGRATION.md](MIGRATION.md) §3 for
its import). What it does:

1. **Userland.** Download a 16.0-CURRENT (FreeBSD `main`) arm64 snapshot `base.txz` from
   download.freebsd.org/snapshots/arm64/aarch64/ and check its sha256 against
   `MANIFEST`. Extract it with `tar --no-fflags --no-xattrs`. On Linux, use
   `bsdtar` from libarchive-tools: GNU tar can't read the mtree options below.
2. **Kernel.** Run `$MK installkernel KERNCONF=GENERIC -DNO_ROOT DESTDIR=$STAGE`.
   It writes a `METALOG`.
3. **Configuration.**
   - `loader.conf`: **empty**. The board needs nothing, and anything special
     here is a smell.
   - `rc.conf`: DHCP on `tcx0`/`tcx1`, sshd, `ntpd` + `ntpd_sync_on_start`
     (there's no RTC), powerd, `fsck_y`, growfs.
   - `sysctl.conf`: `kern.eventtimer.timer="ARM MMIO Timer"`,
     `hw.acpi.cpu.cx_lowest=C3` (deep idle), `debug.debugger_on_panic=0`,
     `kern.panic_reboot_wait_time=5`.
   - `fstab`: `/dev/gpt/rootfs`.
   - root's `authorized_keys`, `PermitRootLogin prohibit-password`.
   - `/firstboot`, so growfs runs.
   - our per-domain `powerd`: it's in base now, so after a world build this
     step goes away.
4. **Spec.** Take `bsdtar -cf - --format=mtree --options='!all,type,uid,gid,mode,link,flags' @base.txz`,
   change the first `/.` to `.`, append the METALOG minus `./usr/lib/debug`,
   then append the new files.
5. **Images.**
   ```sh
   makefs -t ffs -B little -D -N $STAGE/etc -o version=2,label=rootfs -s 3g -F spec root.ufs $STAGE
   makefs -t msdos -o fat_type=16,volume_label=EFISYS -s 64m esp.img esp/   # loader.efi as EFI/BOOT/BOOTAA64.EFI
   mkimg -s gpt -p efi/efiboot0:=esp.img -p freebsd-ufs/rootfs:=root.ufs -o q8b-usb.img
   ```
6. **Write it.** `lsblk` first, **every time**, then
   `sudo dd if=q8b-usb.img of=/dev/sdX bs=4M conv=fsync status=progress`.

On first boot growfs fixes the GPT, grows root to fill the stick and adds
swap. To boot the NVMe root from the stick instead, see
[boards/radxa-dragon-q8b/firmware-acpi-boot.md](boards/radxa-dragon-q8b/firmware-acpi-boot.md).

The image uses a snapshot userland with our kernel. A shippable image needs
`buildworld` from `src/`, `make release` or equivalent, and the desktop's
`live-image.sh`. None of that exists for arm64 yet: see MIGRATION.md §5.

## 7. Deploying to a running board

```sh
tar -C $STAGE -czf kstage.tgz --no-xattrs boot/kernel    # the full kernel + modules
scp kstage.tgz root@q8b:
ssh root@q8b 'mv /boot/kernel /boot/kernel.old && tar -xzf kstage.tgz -C / && kldxref /boot/kernel && reboot'
```

- Keep `/boot/kernel.old` as a known-good fallback. From a boot panic loop,
  escape to the loader prompt and `boot kernel.old`.
- After replacing a module, `sync` before `kldunload`/`reboot`. A panic
  loses recently written files on SU+J. After one, run `pkg check -s` and
  reinstall any damaged packages.
- Load and unload the msm module by file name: `kldunload msm.ko` (its
  module name is `acpi/msm`).

## 8. Ports overlay (FreeBSD host required)

The overlay replaces ports of the same origin in a stock ports tree:

```sh
poudriere ports -c -p abyss -m null -M $ABYSS/ports
poudriere bulk -j <arm64 jail> -p default -O abyss graphics/mesa-dri graphics/mesa-libs \
    graphics/libdrm graphics/drm-msm-kmod graphics/gpu-firmware-qcom-kmod
```

There are three ways to get an arm64 FreeBSD builder:
- **The Q8B itself** (8 cores): this is how every package so far
  was built. Use `make -C /usr/ports/<origin> package` with
  `BATCH=yes NOCLEANDEPENDS=yes`. `make clean` in mesa-dri also cleans the
  work dirs of its dependencies unless `NOCLEANDEPENDS` is set.
- **An arm64 VM:** fast under KVM only if the workstation is itself arm64.
- **An amd64 poudriere with qemu-user-static:** slow, but it works for Mesa.

Before the packaged stack matches what was tested, fix the overlay (see
MIGRATION.md §2):
- `drm-latest-kmod` fetches upstream drm-kmod and is amd64-only.
- `gpu-firmware-qcom-kmod` points at a tag that doesn't exist upstream.

## 9. Desktop

The desktop has always been developed on Linux; see
[desktop/README.md](../desktop/README.md) and
[desktop/abyss/vm/README.md](../desktop/abyss/vm/README.md).

```sh
cd $ABYSS/desktop
swift build && swift test
sh abyss/tests/run.sh            # the Linux lane
# FreeBSD truth: the qemu/KVM VM (FreeBSD 15.0-RELEASE amd64)
cd abyss/vm && ./fetch-image.sh && ./make-seed.sh && ABYSS_DAEMON=1 ./run.sh && ./check.sh && ./build.sh
```

**Set `ABYSS_VM_HOME`.** Since the move into the monorepo, its default
(`$ABYSS_REPO/..`, where `ABYSS_REPO` is now `desktop/`) resolves to
`AbyssBSD/abyss-swift-vm`, *inside* the monorepo. Point it at an existing VM
or a directory outside:

```sh
export ABYSS_VM_HOME=$HOME/abyss-swift-vm
```

`live-image.sh`'s default output (`$root/../abyss-live.img`) also lands in the
monorepo root. Pass `--out`.

AbyssBSD tracks FreeBSD `main`, but the VM harness still boots
15.0-RELEASE. The desktop still links `wlroots-0.19`, while ports and the
Q8B are on 0.20. Both are open in [MIGRATION.md](MIGRATION.md) §5. Until
they're done, install `wlroots019` next to 0.20 on a FreeBSD `main` machine.
