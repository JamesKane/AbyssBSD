# FreeBSD development VM

Phase 4 of AbyssBSD is the first work that needs a real FreeBSD kernel:
Capsicum, jails, `pdfork`, and `SOCK_SEQPACKET` do not exist on the macOS
development bed. This directory stands up a FreeBSD 15.0 **aarch64** guest
under QEMU with the **HVF** accelerator, so it runs at native speed on an
Apple Silicon host.

aarch64 (not amd64) is deliberate: HVF gives native-speed virtualisation
only for the host architecture, aarch64 is one of AbyssBSD's three shipping
targets, and the FreeBSD kernel facilities under test are identical across
architectures. The one cost is that `rustup` has no aarch64-FreeBSD
toolchain, so the guest builds with FreeBSD's `pkg` Rust rather than the
`rust-toolchain.toml` pin; the canonical build stays on the Mac.

## Prerequisites

- QEMU: `brew install qemu` — provides `qemu-system-aarch64`, `qemu-img`,
  and the EDK2 (`edk2-aarch64-code.fd`) UEFI firmware.
- Python 3 (for `console.py`); the macOS system Python is enough.
- About 3 GB of free disk for the image and the VM disk.

## Use

```
./vm.sh fetch    # download (if needed), checksum, and decompress the image
./vm.sh boot     # build the cloud-init seed, create the disk, start the VM
./vm.sh ssh      # ssh in as root (or: ./vm.sh ssh 'uname -a')
./vm.sh provision  # install the build/test packages (Rust, git, font stack)
./vm.sh sync     # rsync the repo into the VM (excludes .git, target, tools, site)
./vm.sh build    # sync, then run `cargo xtask ci` in the VM
./vm.sh status
./vm.sh stop     # shut the VM down
./vm.sh reset    # discard the VM disk; next boot is a clean FreeBSD
```

The VM is headless. It is reached over SSH as **root** on `localhost:2222`
(QEMU user-mode port forward, key `id_abyss_vm`). Its serial console is
both written to `console.log` and exposed on a socket (`127.0.0.1:4555`);
`console.py` drives that socket with an expect-style dialogue, for
provisioning and for debugging a kernel that will not boot far enough for
SSH:

```
./console.py 'send:' 'expect:login:' 'send:root' 'expect:Password:' 'send:abyssroot'
```

## How it is provisioned

The FreeBSD image is the `BASIC-CLOUDINIT` variant, so it carries
`nuageinit` — FreeBSD's own small cloud-init. `vm.sh seed` renders
`cloud-init/user-data` (substituting the generated SSH public key) and
`cloud-init/meta-data` onto an ISO labelled `cidata`; nuageinit's NoCloud
datasource finds it at first boot and applies it:

- the SSH key is authorised for the image's default `freebsd` user and
  (via a `runcmd` that runs as root) for `root`;
- `root` is given the password `abyssroot` — FreeBSD's console permits
  root login, and `su` then works from the `freebsd` account;
- key-based root SSH is enabled, because FreeBSD's `sshd` defaults
  `PermitRootLogin` to `no`.

Every provisioning step is logged inside the guest to
`/tmp/abyss-provision.log`. The **first boot is slow** (a few minutes):
the image runs `freebsd-update` to the latest patch level and reboots once
before nuageinit's work completes. Later boots take seconds.

A freshly-provisioned VM is made build-ready with `./vm.sh provision`,
which installs the package set the workspace needs: the Rust toolchain,
git, the `abyss-font` stack (`pkgconf` + `freetype2` + `harfbuzz`), the
`dejavu` font the `abyss-font` tests open, and `rsync`. From then on
`./vm.sh build` syncs the working tree and runs the full `cargo xtask ci`
inside the guest.

FreeBSD packages Rust 1.94.0; the workspace MSRV is set accordingly. The
macOS dev bed keeps the exact 1.95.0 pin from `rust-toolchain.toml`.

## What is committed

`vm.sh`, `console.py`, the `cloud-init/` templates, this README. The
downloaded image, the decompressed and overlay disks, the generated SSH
keypair, the seed ISO, the firmware variable store, and the console log are
all generated and git-ignored.
