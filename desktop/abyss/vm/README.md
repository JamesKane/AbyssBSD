# AbyssBSD build VM

A scripted, reproducible FreeBSD VM (qemu + KVM) that acts as the build/test
host for the Swift DE: **16.0-CURRENT** since 2026-09-30, pinned to one
snapshot, because the distribution's base is FreeBSD `main` (PLAN decision 5).
The 15.0-RELEASE box it replaces stays bootable with
`ABYSS_FBSD_VERSION=15.0-RELEASE` until 16 has passed the same gates. We edit source on the Linux host and build
inside the guest, because the target is FreeBSD and only a real FreeBSD system
can tell us the truth about kqueue, `pdfork`, OSS, devd and the rest.

Everything is driven by plain `sh` scripts + qemu — no vagrant/libvirt. Large VM
artifacts live in `abyss-swift-vm/` beside the monorepo (`../../../../abyss-swift-vm/`
from here), never in git.

## Quick start

```sh
cd abyss/vm
./fetch-image.sh          # download + verify SHA512 + decompress base qcow2
./make-seed.sh            # ssh key (generated if absent) + cloud-init seed
ABYSS_DAEMON=1 ./run.sh   # boot headless in background
./check.sh                # wait for provisioning, then assert the VM is usable
./fetch-sets.sh           # the snapshot's base/kernel.txz -> ~/dist, src.txz -> /usr/src
./build.sh                # sync + swift build + swift test, in the guest
```

`build.sh` is the Phase-3 dev loop. It exists because Swift on FreeBSD installs
**off PATH** (`/usr/local/swift6/bin`, so 5.10 and 6.x can coexist) and a
non-interactive `ssh host 'cmd'` reads no profile — so nothing scripted may
assume `swift` resolves. `--no-sync` builds what's already there, `--no-test`
skips the tests, and `-- <args>` passes through to `swift build`.

`check.sh` is the one that tells you whether first boot actually worked — see
below.

## Files

| script          | purpose                                                        |
|-----------------|----------------------------------------------------------------|
| `config.sh`     | All tunables (paths, ports, CPUs, RAM). Override via env. `ABYSS_FBSD_VERSION` picks the image, disk, seed and sets together. |
| `fetch-image.sh`| Download, checksum, decompress the pristine base image.        |
| `make-seed.sh`  | Generate the ssh key if needed; build the NoCloud cloud-init seed (Rock Ridge ISO, via pycdlib). |
| `run.sh`        | Boot the VM on a COW overlay disk (base image stays pristine), plus a 12G **scratch disk** the installer tests are allowed to destroy. |
| `check.sh`      | Assert the guest is ready: ssh, cloud-init, packages, **the base still the pinned snapshot**, pkg-config, harness tools. |
| `fetch-sets.sh` | Download the snapshot's `base.txz`/`kernel.txz`/`src.txz` once, verify them against `config.sh`'s pins, and put them in the guest: `~/dist` for the medium and installer tests, `/usr/src` for the wtap lab. |
| `build.sh`      | The dev loop: sync, then `swift build` (+ `swift test`) in the guest. |
| `provision-rv64.sh` | The `rv64` role only (RUST.md R0): set the riscv64 guest up over its serial console, since riscv64 has no CLOUDINIT image. Run once, after the first `ABYSS_DAEMON=1 ./run.sh`. |
| `rv64-build.sh` | RUST.md R0: on the builder VM, make the poudriere `rv64` jail (our `src/` for riscv64, native-xtools) if missing, install `rv64-make.conf`, and bulk-build `rv64-ports.list`. FreeBSD builds no riscv64 packages. |
| `rv64-sysroot.sh` | RUST.md R0: pull the builder's riscv64 poudriere jail (world) and package repository to the host, and unpack them into the sysroot the cross-build links against. |
| `rv64-cross.sh` | Run a command (cargo) with the cross-build environment for FreeBSD/riscv64: host clang/lld, the sysroot, pkg-config. |
| `bhyve-run.sh` | Runs **on the FreeBSD box**: start a role's VM under bhyve (tap on `bridge0`, fixed MAC, UEFI, console on an nmdm pair copied to a log). `run.sh` sends it there. |
| `bhyve-migrate.sh` | Move a role's qemu disk to the box as bhyve's sparse raw disk, state and all. |
| `ssh.sh`        | SSH in (passes through args/commands).                          |
| `sync.sh`       | rsync host `desktop/` → guest `~/AbyssBSD/desktop`.             |

## Notes

- **bhyve on the build box** (`ABYSS_VMM=bhyve`, 2026-10-30). The FreeBSD box
  AbyssBSD-Rust also uses (`ssh abyss-build`: FreeBSD 15.1, 20 threads,
  128 GB) runs the build and builder roles under bhyve, so they get far more
  than this host can spare and this host stays quiet. The box bridges
  `igc0` onto `bridge0` (its `rc.conf`); each VM is a tap on it with a
  fixed MAC, gets its address from the LAN's DHCP, and `run.sh` records it
  (`ip<role>` beside the disks) for `ssh.sh` and the rest, which reach it
  on port 22. The VM's console is `doas cu -l /dev/nmdm-abyss-<name>.1B`
  on the box. riscv64 has no bhyve: the rv64 guest stays qemu.

- **The riscv64 guest** (`ABYSS_VM_ROLE=rv64`, RUST.md R0, §6.10) is
  FreeBSD/riscv64 under TCG: `fetch-image.sh`, `ABYSS_DAEMON=1 ./run.sh`,
  `./provision-rv64.sh`, then `./ssh.sh` on port 2224, all with the role set.
  Its packages are ours (`rv64-sysroot.sh` fetches the repository the
  provisioner installs from), and `./ssh.sh shutdown -p now` stops it.
  It is ~38x slower than the host and FreeBSD has no riscv64 packages, so
  nothing is built in it: binaries are cross-built on amd64 and copied in.
  Boot it only when RV64 is what is being tested.

- **COW overlay**: `run.sh` boots a qcow2 overlay backed by the pristine image.
  To reset to a clean machine: `rm ../../../../abyss-swift-vm/abyss-build-16.qcow2`
  (`abyss-build.qcow2` for 15.0) and re-run.
- **One snapshot, held.** CURRENT's "Latest" moves weekly and its sets directory
  only ever holds the newest build, so `config.sh` pins a dated image and the
  sets' checksums, and the seed stops the image's first boot from upgrading its
  own base (`firstboot_pkg_upgrade`, the `FreeBSD-base` repository) — otherwise
  the guest drifts past the `base.txz` the medium is built from. `check.sh`
  asserts the installed base is still the pinned build. **Moving the base is a
  deliberate step**: a new pin in `config.sh`, `fetch-sets.sh`, a fresh guest.
- **Login**: user `build`, key-only auth with `abyss-swift-vm/id_abyss`
  (generated on first `make-seed.sh`). Passwordless sudo. No passwords anywhere.
- **Why `check.sh` exists**: every `pkg install` in the seed is best-effort
  (`|| true`) so one missing port can't wedge first boot. The cost is that a
  silent miss looks exactly like success — `~/.cloud-init-done` appears either
  way. The seed therefore records anything absent in `~/.pkg-missing`, and
  `check.sh` asserts on that plus the pkg-config names `Package.swift` uses and
  the tools `abyss/tests` shells out to. It **reports** Swift's absence without
  failing: a Swift toolchain on FreeBSD is the P3.2 spike
  (`docs/SWIFT-ON-FREEBSD.md`), not a precondition for a usable VM.
- **What's installed**: base tooling, Swift's runtime deps (icu, libxml2, curl,
  libedit), the C substrate the Swift targets FFI into (wayland, xkbcommon,
  cairo, freetype2, harfbuzz, png, jpeg-turbo, a font), wlroots + seatd +
  **sway** + **grim** so the shell runs and the live tests can capture it, and
  what the harness grew into: `edk2-bhyve` for the nested installs, `gdb` for
  vmcores, `zenity`/`galculator` as foreign (GTK) applications, `firefox-esr` + `ffmpeg` for the medium's browser, `wlr-randr`.
  No Rust: the engine is a Swift *rewrite*, not a reuse of the sibling's crates.
- **Stop the VM**: `kill $(cat ../../../../abyss-swift-vm/qemu.pid)` (daemon mode),
  or `Ctrl-A X` in the foreground console.

## The scratch disk (Phase 5)

`run.sh` attaches a third virtio disk, `$ABYSS_SCRATCH`
(`abyss-swift-vm/abyss-scratch.qcow2`, 12G, created on demand). It shows up in
the guest as `vtbd2`, and `abyss/tests/live-install.sh` installs onto it — which
means **that disk is wiped on every live run**, deliberately.

It is a *real* virtio disk rather than a file-backed `md(4)` device because
`geom disk list` does not show md devices (nor does `sysctl kern.disks`), so the
installer's own machine probe cannot see one. A test that needed the product to
grow a code path for memory disks would be testing something the product does
not do. Delete the file to reclaim the space; `run.sh` makes another.
