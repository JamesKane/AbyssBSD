# Phase 17 — delivery: the overlay, a release pipeline, and `abyss update`

_Scoped 2026-10-02. PLAN's Phase 17 and PRODUCT §6.2–§6.3 say what; this says
how, in passes, from what the tree has today._

**The goal:** the desktop and the base it runs on update as one thing, safely.
An image built by our own pipeline installs a machine; that machine updates
itself into a boot environment; and an update that breaks it is undone by
rebooting.

**Needs:** 5 (the installer), 14 (a network, and the root-helper shape), 15
(applications, and appgen to hook). All three are complete.

---

## 1. Where it starts

None of Phase 17 exists. What it builds on:

| Have | Where | What it becomes |
|---|---|---|
| A ports overlay: Mesa, libdrm, drm-kmod and firmware for the Q8B, `qairt`, `linux-fastrpc` | `ports/`; a recipe in `ports/README.md` and BUILDING §5, never scripted; every package so far made with `make package` on the board | the overlay poudriere builds, with the desktop added (P17.1) |
| Cross-built kernels on Linux | BUILDING §3, `src/tools/build/make.py` | half of the world build; **nothing runs `buildworld`** |
| pkgbase in `src/` | `Makefile.inc1`: `packages`, `update-packages`, `sign-packages` | the base as packages, updatable by `pkg` (P17.3) |
| `beinstall.sh` | `src/tools/build/beinstall.sh` | the reference for installing into a boot environment (P17.7) |
| The live medium | `desktop/abyss/mk/live-image.sh`: snapshot `base.txz`/`kernel.txz` from download.freebsd.org (pinned, amd64 only), desktop binaries from `.build/debug` plus an `ldd` closure, GPU packages untarred without registering, **Firefox copied from the build host**, all tarred as `abyss.tzst` | an image made from the pipeline's sets and packages (P17.6) |
| The installer | `de/install`: pool `abyss`, `ROOT/default` with `canmount=noauto`, `bootfs` set; extracts the sets | already boot-environment shaped; installs packages instead of a tarball (P17.6) |
| The root-helper shape, twice | `abyss-install` (uid check), `abyss-settings` (uid + `wheel`, typed plans, a journal, rc.d) | `abyss-update`, the third (P17.8) |
| `abyss-appgen` | run by `anchor` at each login into `~/Applications` | a `pkg` trigger into `/Applications` (P17.2) |
| Software Update | an icon in System Preferences, "This pane cannot change anything yet" | the pane (P17.8) |

**What the medium does today that this phase removes:** a package database
nobody has. The installed system's `pkg` knows nothing of the desktop, its
GPU drivers or Firefox, so nothing could update them. Fixing that is the
precondition for everything after P17.6.

**The machine the pipeline needs.** The build guest is small for it (25 GB
free in its pool, 8 cores, 16 GB). A world, a kernel, pkgbase and a
poudriere jail want ~60 GB and as many cores as there are. The host has
494 GB free and 16 cores (§6.2).

---

## 2. The shape

```
 src/ ──make.py / buildworld, buildkernel──▶ world ──make packages──▶ AbyssBSD-base repo
   │                                            │
   │                                            └─▶ poudriere jail
 ports/ (overlay) + freebsd-ports (pinned) ──poudriere bulk -O abyss──▶ AbyssBSD repo
   (only our origins; every other dependency fetched from pkg.FreeBSD.org/latest)

 both repos ──sign──▶ publish ──▶ a machine:  FreeBSD-ports  (FreeBSD's, as today)
                                             AbyssBSD       (ours, higher priority)
                                             AbyssBSD-base  (ours: the base)
 both repos ──live-image.sh──▶ the medium (an offline copy of what it installs)

 abyss update:  bectl create → pkg -r <clone> upgrade (base + ports) → migrations
                → bectl activate -t (one boot) → reboot → login reached → activate for good
                (no login: the next boot is the old environment, untouched)
```

**Our repository carries only what is ours** — the desktop, its theme and
tools, and the overlay's patched ports. Everything else stays FreeBSD's:
their mirrors, their security advisories, their bandwidth. That is PRODUCT
§6.3's discipline as a repository layout, and it keeps hosting small.

**One release identifier**, the date and the monorepo commit
(`2026.10.02-3ca6aa3`), names the base packages, the desktop package and the
image built together. `abyss update` moves a machine from one to the next.

---

## 3. Ordered passes

Sizes: **S** a day or less, **M** a few days, **L** a week or more.

- **P17.0 — the builder (S).** A FreeBSD 16 builder VM on the host, beside the
  build guest, made by the same `abyss/vm` scripts with more disk and cores.
  Poudriere installed. Two spikes before anything is written on them:
  1. **SwiftPM in poudriere.** A port builds with no network; does
     `swift build -c release` of `desktop/` (no remote packages, but SwiftPM
     still writes caches under `$HOME`) succeed in a poudriere build jail?
  2. **pkgbase from our world**: `make packages` on the builder, and
     `pkg -r` installing it into an empty directory that then boots in bhyve.

- **P17.1 — the desktop as a port (M).** `ports/x11/abyss-desktop`: the
  distfile is `git archive` of `desktop/` at the release commit, made by the
  pipeline into `DISTDIR`. It builds every product with `swift build -c
  release` and installs:
  - the binaries in `/usr/local/bin` and `/usr/local/libexec/abyss`;
  - the themes, icons and data in `/usr/local/share/abyss`;
  - the rc.d scripts `live-image.sh` writes inline today, moved into files
    under `desktop/abyss/etc/rc.d`.

  `RUN_DEPENDS` replace the `ldd` closures: wlroots, GTK's stack, seatd,
  Firefox ESR, `llama-cpp`, the GPU kmods and firmware. One package to start
  with; split it only when something asks. **Verify:** `poudriere testport`;
  `pkg install abyss-desktop` into a clean jail gives a tree on which the
  session runs (`live-desktop.sh` against the installed paths).

- **P17.2 — appgen as a `pkg` trigger (S).**
  `/usr/local/share/pkg/triggers/abyss-appgen.ucl`, run when any package
  changes `share/applications/*.desktop`: `abyss-appgen --to /Applications`
  as root. The login run stays, for a person's own `~/Applications`.
  **Verify:** in a jail, `pkg install galculator` makes
  `/Applications/Galculator.app`; `pkg delete` removes it.

- **P17.3 — the world, as packages (M).** `tools/release/` at the
  monorepo's root (the first build script the root has):
  - `buildworld` and `buildkernel` from `src/` on the builder;
  - `make packages`: the **AbyssBSD-base** repository;
  - the distribution sets (`base.txz`, `kernel.txz`) from the same world, for
    the medium and for the poudriere jail.

  amd64 first. arm64 is the same script with `TARGET=arm64`, built but not
  gated here (§6.7). **Verify:** the sets extract into a root that boots in
  bhyve; pkgbase installs into one that does too.

- **P17.4 — the overlay's bulk build (M).** A poudriere jail from P17.3's
  world, a FreeBSD ports tree pinned by commit, the overlay as `-O abyss`.
  `bulk` builds only our origins; `PACKAGE_FETCH_BRANCH=latest` brings every
  other dependency from FreeBSD's binaries. The three known overlay bugs
  (MIGRATION §2) are the board's to fix, and the amd64 bulk leaves the
  board's ports out until they are. **Verify:** the bulk's own report, and
  `pkg install abyss-desktop` from the resulting repository alone (with
  FreeBSD's for the rest) into a clean jail.

- **P17.5 — signing and publishing (S).** Both repositories signed with
  `signing_command`, so the key never sits in the builder (§6.4). The repo
  configuration (`/usr/local/etc/pkg/repos/AbyssBSD.conf`, the base's
  `AbyssBSD-base.conf`) and the public fingerprint ship in the base and the
  desktop package. Publishing is a copy to a static location (§6.3).
  **Verify:** a client trusts the repositories by fingerprint; a tampered
  `packagesite` and an unsigned repository are refused.

- **P17.6 — the medium, from the pipeline (M).** `live-image.sh` takes the
  pipeline's sets and installs packages into the stage with `pkg -r`,
  replacing `.build/debug`, the `ldd` closures, the untarred GPU packages and
  the copied Firefox. The medium carries both repositories, offline. **The
  installer** extracts nothing of ours by hand: it installs the base
  (pkgbase, or the sets, §6.1) and then `pkg -r /mnt install abyss-desktop`
  from the offline copy, with the network repositories configured for later.
  The live session itself keeps no package database (P5.3); the installed
  system has a complete one. **Verify:** `run.sh --vm --live --full`: the
  image installs in nested bhyve and boots to the desktop, and `pkg info` on
  it lists the desktop, its kmods and Firefox (PLAN's first verify item).

- **P17.7 — `abyss update` (M).** A command, root's:
  1. `bectl create` a clone named for the release it moves to, and mount it;
  2. `pkg -r` the clone: update the repositories, upgrade the base and the
     packages;
  3. run the **migrations** the new release brings that the clone has not
     had (`/usr/local/share/abyss/migrations/NNNN-name`, each run once,
     chrooted, recorded in the clone);
  4. `bectl activate -t`: the clone boots **once**;
  5. reboot. When the session reaches a login, `abyss update --confirm` (from
     the login window's start) makes the clone the default. If it never does,
     the next boot is the environment the machine had, untouched.

  Old environments are kept, the last three by default. **Verify** (PLAN's
  second and third items): in nested bhyve, an update applied to a clone,
  rebooted into and confirmed; and a deliberately broken one (a desktop that
  cannot start) reboots back into the previous environment by itself.

- **P17.8 — Software Update (M).** `abyss-update`, the third root helper in
  `abyss-settings`' shape (uid, `wheel`, typed plans, a journal, rc.d): check,
  list what changes, apply (P17.7's steps 1–4), restart. The pane: what is
  available and how large, a progress bar, Restart. A non-admin is told to
  ask one, as the other admin panes do. **Verify:** `live-software-update.sh`
  against a local repository with a newer release: listed, applied into a
  clone, the pane offers Restart; and refused for a person not in `wheel`.

- **P17.9 — Install Software (M).** The same helper, over `pkg search` and
  `pkg install`: an application to find and install ports, which appear in
  Applications through P17.2. Removing one too. **Verify:** installing
  galculator from it gives `Galculator.app`, as a person would see it.

- **P17.10 — the gate (S).** PLAN's three items, end to end, in the `--full`
  lane: an image built by the pipeline from `src/` and the overlay installs
  and boots; an update is applied, rebooted into and confirmed; a broken one
  rolls back. On the 12700KF when the medium is back.

---

## 4. What this phase does not do

- **Hosting for anyone else's mirrors**, or a CDN. One static location.
- **Delta updates.** pkg downloads whole packages; fine at this size.
- **The board's image.** The arm64 world builds here; the Q8B's image, its
  kmods and firmware stay the board side's (the Mac Studio's) until the
  overlay's board ports are fixed and swift6 for aarch64 is hosted
  (MIGRATION §5).
- **Firmware updates** (fwupd's job elsewhere): nothing here.

---

## 5. Verification

Each pass's own claims, above, on Linux where it can run and in the guest or
the builder where it cannot. The phase gate is P17.10. The `--full` lane is
the rule for P17.6 onwards: they touch the medium, the sets and the boot path.

---

## 6. Decisions

**1–4 decided 2026-10-02, each as recommended.** 5–8 stand as recommended
until a pass says otherwise.

1. **How the base updates.** **Decided: pkgbase.** Our world as
   packages (`make packages`), installed and upgraded by the same `pkg` as
   everything else, in one transaction into the clone. FreeBSD 15 made pkgbase
   the supported path; `freebsd-update` cannot serve a fork at all. The
   alternative, distribution sets extracted into the clone, cannot remove a
   file a release dropped and knows nothing of what changed.
2. **Where the pipeline runs.** **Decided: a dedicated builder VM on the
   host** (16 cores, ~150 GB), made by `abyss/vm`. The build guest stays the
   desktop's fast loop; the 12700KF is a test machine, and its medium is away.
3. **Where packages are published.** A pkg repository is static files over
   HTTPS. **Decided: GitHub Releases on the monorepo for now** (each
   release a tag; assets up to 2 GB each, and our repository holds only our
   packages, so it is small), behind one URL in the repo configuration that can
   move to a server later without reinstalling. Until the first outside
   install, the gate serves it locally.
4. **The signing key.** **Decided: an RSA key you hold, offline from the
   builder**, used through pkg's `signing_command` (the builder sends the
   digest, gets a signature back). Who holds it, and its backup, is yours to
   decide (PLAN risk 8).
5. **Release identity.** *Recommendation: rolling, dated releases*
   (`YYYY.MM.DD-<commit>`), one per pipeline run that passes the gate; no
   numbered versions until there is a reason.
6. **The medium's package database.** *Recommendation: the live session
   keeps none (P5.3 stands); the medium carries an offline repository, and the
   installed system gets a complete database.* P5.3 was right that a live
   system should not pretend to be installed; it was not meant to leave the
   installed one without one.
7. **arm64.** *Recommendation: the pipeline is built for both architectures
   from P17.3, and gated on amd64 only.* The Q8B's image stays the board
   side's (§4).
8. **When an update is confirmed.** *Recommendation: the login window coming
   up* (the session's own start, P16), not a timer. A machine that boots but
   cannot show a login is a broken update, and should go back.
