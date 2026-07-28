# AbyssBSD build VM

A scripted, reproducible FreeBSD 15.0-RELEASE VM (qemu + KVM) that acts as the
build/test host for the Swift DE. We edit source on the Linux host and build
inside the guest, because the target is FreeBSD and only a real FreeBSD system
can tell us the truth about kqueue, `pdfork`, OSS, devd and the rest.

Everything is driven by plain `sh` scripts + qemu — no vagrant/libvirt. Large VM
artifacts live in `../../../abyss-swift-vm/` (a sibling of the repo), never in
git. That is deliberately *not* the Rust sibling's `../abyss-vm`: the two
projects keep separate boxes. (They do share port 2222, so only one can run at a
time.)

## Quick start

```sh
cd abyss/vm
./fetch-image.sh          # download + verify SHA512 + decompress base qcow2
./make-seed.sh            # ssh key (generated if absent) + cloud-init seed
ABYSS_DAEMON=1 ./run.sh   # boot headless in background
./check.sh                # wait for provisioning, then assert the VM is usable
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
| `config.sh`     | All tunables (paths, ports, CPUs, RAM). Override via env.       |
| `fetch-image.sh`| Download, checksum, decompress the pristine base image.        |
| `make-seed.sh`  | Generate the ssh key if needed; build the NoCloud cloud-init seed (Rock Ridge ISO, via pycdlib). |
| `run.sh`        | Boot the VM on a COW overlay disk (base image stays pristine). |
| `check.sh`      | Assert the guest is ready: ssh, cloud-init, packages, pkg-config, harness tools. |
| `build.sh`      | The dev loop: sync, then `swift build` (+ `swift test`) in the guest. |
| `ssh.sh`        | SSH in (passes through args/commands).                          |
| `sync.sh`       | rsync host source tree → guest `~/AbyssBSD-swiftDE`.            |

## Notes

- **COW overlay**: `run.sh` boots a qcow2 overlay backed by the pristine image.
  To reset to a clean machine: `rm ../../../abyss-swift-vm/abyss-build.qcow2`
  and re-run.
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
  cairo, freetype2, harfbuzz, png, jpeg-turbo, a font), and wlroots + seatd +
  **sway** + **grim** so the shell runs and the live tests can capture it. No
  Rust: the engine is a Swift *rewrite*, not a reuse of the sibling's crates.
- **Stop the VM**: `kill $(cat ../../../abyss-swift-vm/qemu.pid)` (daemon mode),
  or `Ctrl-A X` in the foreground console.
