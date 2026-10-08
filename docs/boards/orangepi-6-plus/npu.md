# NPU: Arm China Zhouyi X2 (scope)

Scope (2026-10-07) for running the Sky1's NPU on FreeBSD. The approach is
the GPU's and the Q8B's: Linux's driver ported through LinuxKPI, out of
tree (GPL), with FreeBSD glue for what Linux gets from ACPI power domains
and SCMI; user space as open source rebuilt for FreeBSD where it exists,
under the Linuxulator where it is binary-only (the Q8B's FastRPC pattern).

**Phase 1 done (2026-10-08):** `aipu-kmod` (local repository): the driver
attaches, reports the NPU (Zhouyi v3, one cluster of three cores, four TECs
each, 4 MB of GM), and buffers allocate, map, verify and free through
`/dev/aipu`, translated by the SMMU.

**Phase 2 done (2026-10-08):** `aipu-umd` (local repository): Arm China's
user-mode driver **4.1.0**, the release CIX's kernel driver 6.2.0 comes from
(4.2.0 and later changed the ioctl structures), built natively on FreeBSD.
CIX's MobileNetV2 (model hub, the ELF graph inside its `.cix`) labels
ImageNet images right, about 7.3 ms each, with `tools/npurun`.

Stock Ubuntu on the board has no NPU stack installed (no module, no
packages): it comes from CIX's and Radxa's package repositories.

## The hardware, from the board's ACPI tables

- `\_SB.NPU0` (`CIXH4000`): registers at `0x14260000` (64 KB), one
  interrupt, GSIV `0x167`; `_CCA` 0 (not coherent).
- `_DSD`: `cluster-partition` (patched by `_INI` from the firmware),
  `gm-policy` 1, `core_mask` 3, and the SCMI performance domain 8
  (`power-domains = <\_SB.SCMI.DVFS 8>`, name "perf") for DVFS.
- Power: ACPI power resources, `PPRS` for the NPU and `PRS0`-`PRS2` for
  the three cores (`CRE0`-`CRE2`, `CIXH4010`, no registers or interrupts
  of their own). `_ON` sets a control register (`0x1425020c`,
  `0x14250200`/`204`/`208`) and resets through the firmware's `DMRP`
  (masks 1, 2, 4, 8 at `0x14250000`).
- IORT: one stream, SID `0x1E`, on SMMU1, the SMMU that already
  translates the display controller (named-component contexts, sky1-iommu).
- Architecture: Zhouyi "v3", marketed as X2 (Arm China's mapping; CIX
  builds the driver with `BUILD_ZHOUYI_V3`). Some community pages say Z3;
  that contradicts Arm China's table.

## The software

| Layer | What | Licence | Source |
|---|---|---|---|
| Kernel driver | `aipu.ko` (`armchina-npu/`), a misc device `/dev/aipu`: ioctl, mmap, poll; dma-buf exporter and importer | GPL-2.0, UAPI with syscall note | Arm China [Compass_NPU_Driver](https://github.com/Arm-China/Compass_NPU_Driver) `Linux/driver/kmd` (has a `sky1/` SoC layer); CIX [cix_opensource__npu_driver](https://github.com/cixtech/cix_opensource__npu_driver) (DKMS 6.2.0 for kernel 7.0) |
| Arm China user driver | `libaipudrv` ("standard API": context, graph, job, tensors), Python bindings | Apache-2.0, C++14, plain POSIX | Compass_NPU_Driver `Linux/driver/umd` |
| CIX user driver | `libnoe` (NOE API), Python wheel | binary only, glibc 2.34; header Apache-2.0 | `cix-noe-umd` (3.x dlopens `libaipudrv`; 2.x opens `/dev/aipu` itself) |
| ONNX Runtime | Zhouyi execution provider, compiles ONNX to NPU graphs on the board | EP source MIT; CIX's build and its toolchain libraries binary | [Compass_Onnxruntime](https://github.com/Arm-China/Compass_Onnxruntime); `cix-npu-onnxruntime` |
| Compiler | CixBuilder (`cixbuild`), quantises to INT8 | binary, x86-64 Linux, Python 3.10 | CIX NOE SDK |
| Alternative | tinygrad's Zhouyi backend, straight on `/dev/aipu` | MIT | tinygrad |

No firmware: the NPU's code arrives in the compiled graph, and the driver
loads nothing (`request_firmware` appears nowhere in it).

The interface is 32 ioctls, magic `'A'` (Arm China 4.3.0), plus two CIX
cache ioctls (`BUF_CACHE_FLUSH`/`INVALID`, numbers 24 and 25, told apart
from Arm China's by size and direction). Struct layouts changed between
CIX's user-driver generations 2.x and 3.x (the ioctl numbers encode the
sizes), so the port supports one generation: **3.x**, matching driver
6.2.0 and Arm China 4.x.

## Plan

1. **Driver port** (`aipu-kmod`, GPL, out of tree, like
   `drm-panthor-kmod`): CIX's 6.2.0 driver through LinuxKPI, with
   FreeBSD glue in place of the `sky1/` layer: ACPI attach to
   `CIXH4000`, the power resources (`_PR0`, through `acpi(4)`), and a
   fixed clock at first. Buffers through the DMA API with a 32-bit mask
   (the NPU drives 32 address bits; Linux needed a `force_dma32` patch),
   over the IOMMU's busdma tag: the driver's own IOMMU path (which reads
   the IOMMU's private IOVA cookie) stays out.
   - Needs from LinuxKPI: misc devices, dma-buf (drm-kmod's `dmabuf`),
     `poll`, `mmap` of buffers. To check: what else `aipu.c` and
     `aipu_mm.c` use.
   - Buffers are mapped write-combined everywhere (kernel and user), as
     Linux maps a non-coherent device's DMA buffers; LinuxKPI's coherent
     memory is cacheable, so the glue changes the pages' attribute (as
     komeda's). busdma_iommu's non-coherent syncs stay unexercised: the
     driver does its own cache maintenance, which write-combined memory
     makes moot.
   - Found on the way: `QUERY_CAP` copies uninitialised kernel stack to
     user space (a bug on Linux too; fixed in `aipu-kmod`).
   - Known Linux bug to carry: a job-scheduling race that hangs the second
     inference ([n4hy/NPU_OrangePi6Plus](https://github.com/n4hy/NPU_OrangePi6Plus)).
2. **Native user space:** `libaipudrv` rebuilt for FreeBSD, with Arm
   China's samples, running a graph compiled on an x86-64 Linux host
   (CixBuilder) or a precompiled one from CIX's model hub. This is the
   first test of the whole stack.
3. **Linux shim:** `/dev/aipu` under the Linuxulator (a Linux ioctl
   handler; the structs are the same on arm64, so it passes through, as
   `qcom_fastrpc_linux` does), for `libnoe`, the ONNX Runtime provider
   and the Python wheels, all glibc-only.
4. **DVFS:** SCMI performance domain 8 through `sky1_scmi`, in place of
   CIX's private `scmi_device_*_freq` helpers.

## Open questions

- Whether CIX's 6.2.0 driver builds against drm-kmod's LinuxKPI without
  more shims than `drm-panthor-kmod` needed.
- ~~`core_mask` 3~~: CIX's probe reads it as "all three cores" (1 means
  one, 0 and 2 none); the driver finds three.
- ~~A compiled graph without an x86 Linux host~~: CIX's model hub on
  ModelScope (`cix/ai_model_hub_26_Q2`, no login); a `.cix` file is a
  FlatBuffers wrapper around the Zhouyi ELF graph libaipudrv loads (its
  length is the uint32 before `\x7fELF`).
- CixBuilder's licence (unconfirmed); whether CIX's
  `libaipu_driver.so` is a rebuild of `libaipudrv` (unconfirmed).

Research notes and the packages examined: Claude's scratchpad of
2026-10-07 (`cnd/`, `debs/`); sources are the links above.
