# Lessons, hazards and gotchas

Read this before touching the board. Each hazard here cost power cycles to
learn.

## Things that reset the SoC

The hypervisor (EL2, Qualcomm's) polices SMMU programming. A violation
resets the SoC at once: the display goes off, the fan stops, and **no crash
dump** is written.

- **Writing CBAR with TYPE=0 (stage 2)**, even writing back the 0 it
  already held. Only ever write CBAR with type 1, as Linux does:
  `0x0001f300` (stage 1 translation, stage 2 bypass, BPSHCFG NSH, MEMATTR
  WB). For unused banks, only clear SCTLR. (Cost: 3 power cycles.)
- **SMR ID/mask pairs other than Linux's.** The hypervisor checks the pairs
  exactly:
  - id 0 mask `0xc01`, covering streams 0 and 1 together, resets the SoC;
  - routing every IORT stream ID (including the `0x2` family) resets it;
  - separate `<0 0xc00>` and `<1 0xc00>` are fine.

  No automatic packing.
- **A GMU mask of `0x400` instead of `0xc00`** leaves streams `0x805`/`0xc05`
  unmatched. That's a global fault (`sCR0` USFCFG=1, GFIE=1), and the SoC
  resets the instant the GMU leaves reset. (Cost: about 8 power cycles.)

## Things that panic or hang

- **`read(2)` on `/dev/mem` for the framebuffer** panics arm64
  ("pmap_map_io_transient: TODO: Map out of DMAP data"). `mmap` it
  read-only instead; screenshots do that.
- **Unloading msm within about 500 ms of a submit** hard-hangs the board
  (the fan stops, no dump). msm's hangcheck timer is a LinuxKPI callout that
  nothing drained at unload; Linux's `msm_gpu_cleanup()` never stops it
  either. Fixed in msm, but the class of bug remains.
- **`cpu_get_pcpu()` on the cpu device itself** panics (see
  [power-thermal-idle.md](power-thermal-idle.md)).
- **x18 after PSCI resume.** It's the pcpu pointer and must be restored
  before C runs.
- **iflib TSO:** `isc_tso_maxsize` without the VLAN header hits an `MPASS`.
- **A devres allocation not zeroed** made a garbage match list and a boot
  panic loop. LinuxKPI's `devres_alloc` now zeroes, as Linux does.
- **A LinuxKPI platform IRQ lookup under a shared bus lock** self-deadlocked
  inside probe and hung boot. It now takes the lock exclusive.

## Display pitfalls

- **Follow Linux's teardown order exactly.** The first msmfb mode changes
  stopped the INTF before pushing the DP idle pattern. The controller then
  waited for a frame end that never came. Training patterns never
  started, the monitor lost the signal, and it looked like the bridge
  couldn't take sparse streams at HBR3. That theory was wrong. Linux's
  atomic disable runs the bridge (push idle) before the encoder (INTF off).
  In that order, every mode works.
- **The monitor may lag a test.** Tell the watcher before each run, give
  each mode several seconds, and leave gaps. A 30-second four-mode sweep
  once "showed nothing" only because it had ended before anyone looked.
- **Scan-out captures need a cache clean.** `fbshot` mmaps the framebuffer
  cacheable, so it cleans and invalidates the range before reading, or it
  shows stale lines.

## Method

- **Read before experimenting.** On a hang or crash, list every
  asynchronous source on the failing path (timers, callouts, tasks, IRQs)
  and compare how Linux *and* LinuxKPI/drm-kmod tear each one down, before
  running a test that might jam the board. Design each board test so one
  run confirms the hypothesis, for example a printf of the suspect state
  alongside the fix.
- **It's all ours.** The whole port was written by us, recently. "It
  predates today's change" doesn't mean "not our bug".
- **Linux on the same board is ground truth.** Diffing registers (debugfs,
  `/dev/mem`) against UEFI's values found the USB threshold bug in minutes,
  after a day of hypotheses.
- **Validate LinuxKPI changes on amd64 too.** Our `dev_is_pci()` change once
  gave PCI GPUs a `platform:` bus ID, and Mesa then found no render device.
  The amd64 box with amdgpu caught it.
- **Stream the logs.** Logs on disk don't survive a power cut. Stream
  `dmesg` over ssh while testing.
- A watchdog script that reloads a known-good module and then reboots makes
  risky tests self-recovering. Examples: `tcx-guard.sh`, and `bootdiag.sh`
  from `@reboot` cron.

## Build and deploy gotchas

- **KLD_TIED:** after a `__FreeBSD_version` bump, deploy the whole kernel
  and all its modules, and rebuild drm-kmod and msm.
- **SU+J and panics:** a panic loses files written just before it. `sync`
  after copying modules, and run `pkg check -s` after a panic loop.
- **devd/devmatch reloads msm** right after `kldunload`. Expect that in
  unload tests.
- **`kldunload` with fbt probes enabled** returns EBUSY. Use printf builds
  for unload paths.
- **Crash dumps:** set `dumpdev` to the swap partition. `dmesg -M` fails on
  the vmcore ("msgbufp not found"); use `strings vmcore | grep -A40 panic:`.
  kgdb needs the PAC bits stripped from stack values.
- **`-DKERNFAST` misses edits** made in the same second as the last build.
  Touch the file and check the log.
- **An editor's git poller** can hold `index.lock`, so scripts that commit
  should retry.
- **checkstyle9:** run it per patch (`git format-patch` then `--patch`).
  `--branch <hash>` checks the whole history and takes hours.
