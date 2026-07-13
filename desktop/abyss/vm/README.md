# AbyssBSD build VM

A scripted, reproducible FreeBSD 15.0-RELEASE VM (qemu + KVM) that acts as the
build/test host for AbyssBSD. We edit source on the Linux host and build inside
the guest, because FreeBSD `buildworld`/`buildkernel` and kernel-module loading
need a real FreeBSD system.

Everything is driven by plain `sh` scripts + qemu — no vagrant/libvirt. Large VM
artifacts live in `../../../abyss-vm/` (a sibling of the repo), never in git.

## Quick start

```sh
cd abyss/vm
./fetch-image.sh     # download + verify SHA512 + decompress base qcow2
./make-seed.sh       # build cloud-init cidata seed (ssh key, user, pkgs)
ABYSS_DAEMON=1 ./run.sh   # boot headless in background
# wait ~1-2 min for first-boot cloud-init (disk grow + pkg install)
./ssh.sh 'uname -a'  # log in as the build user
./sync.sh            # rsync the source tree into the guest
./ssh.sh 'cd AbyssBSD && uname -a'
```

## Files

| script          | purpose                                                        |
|-----------------|----------------------------------------------------------------|
| `config.sh`     | All tunables (paths, ports, CPUs, RAM). Override via env.       |
| `fetch-image.sh`| Download, checksum, decompress the pristine base image.        |
| `make-seed.sh`  | Build the NoCloud cloud-init seed (FAT `cidata`, via mtools).  |
| `run.sh`        | Boot the VM on a COW overlay disk (base image stays pristine). |
| `ssh.sh`        | SSH in (passes through args/commands).                          |
| `sync.sh`       | rsync host source tree → guest `~/AbyssBSD`.                    |

## Notes

- **COW overlay**: `run.sh` boots a qcow2 overlay backed by the pristine image.
  To reset to a clean machine: `rm ../../../abyss-vm/abyss-build.qcow2` and re-run.
- **Login**: user `build`, key-only auth with `abyss-vm/id_abyss`. Passwordless
  sudo. No passwords anywhere.
- **Cloud-init done marker**: `~/.cloud-init-done` appears when first-boot
  provisioning (disk grow + `pkg install git gmake rust`) finishes.
- **Stop the VM**: `kill $(cat ../../../abyss-vm/qemu.pid)` (daemon mode), or
  `Ctrl-A X` in the foreground console.
