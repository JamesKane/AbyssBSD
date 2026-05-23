# DRM/KMS bring-up — the CPU/dumb-buffer scanout path

> Design elaboration for the **display gate** (`../ROADMAP.md` §5,
> alongside `../interfaces/display.md`). It pins the FreeBSD DRM/KMS
> uAPI surface the M1 compositor uses to scan out a CPU/dumb-buffer
> framebuffer, and how that surface reaches the compositor's looper
> through a `kqueue` `EventSource`.
>
> Phase 5. FreeBSD-only — the entire surface is in
> `freebsd-src/sys/dev/drm2` and exposed by `libdrm`-equivalent headers
> from `freebsd-src/sys/dev/drm2/drm`. Built and tested in the amd64
> FreeBSD 15.0 VM with **virtio-gpu**; the bare-metal AMD RX 6750 XT
> comes with Phase 6.
>
> Status: closed for M1.

---

## 1. Scope & principles

The M1 compositor presents a CPU-rendered framebuffer to the display.
That requires *just enough* DRM/KMS to allocate a CPU-mappable buffer,
push it to a connected display, and learn when a flip has completed —
nothing more.

Principles, each load-bearing:

- **Legacy KMS at M1, atomic later.** The M1 surface uses **legacy
  KMS** (`SETCRTC` + `PAGE_FLIP`), not the atomic ioctl. Atomic is the
  better long-term API — multi-plane, test-commit, properties — and
  the GPU compositor will want it for direct scanout. Adopt it in
  Phase 6 (`render-backends.md`, Gate G) alongside the GLES backend.
- **CPU buffers via dumb-buffer.** The kernel's `dumb-buffer` ioctl
  allocates a buffer the userspace process can `mmap` and write to with
  ordinary stores. The `abyss-render` `Canvas` already draws into a
  `&mut [u8]` — the dumb-buffer mapping is that slice. M2's GPU buffers
  arrive over `dmabuf` and are a different code path (the §6 deferred
  list).
- **The DRM fd is a looper `EventSource`.** Page-flip and VBlank
  completion arrive as readable events on the DRM fd. The compositor
  drives them through the same `EventSource` seam Gate D added
  (`looper-framework.md` §3.3, `broker-and-transport.md` §2.3) — no
  thread-park, no separate thread, the same `kqueue` reactor the
  transport already uses.
- **Capsicum from boot.** The DRM fd is opened by the **broker**
  pre-`cap_enter`, `cap_rights_limit`ed to the compositor's needs, and
  passed in the bootstrap bundle. The compositor never `open(2)`s a
  device — once jailed it has no `/dev` to walk.

---

## 2. The device

FreeBSD's DRM driver exposes `/dev/dri/cardN` per GPU and
`/dev/dri/renderDN` per render node:

- **`/dev/dri/card0`** — the **modesetting** device. M1 uses only
  this. The compositor performs discovery, modeset, dumb-buffer
  allocation, framebuffer attachment, and page-flips through it.
- **`/dev/dri/renderD128`** — the render node, GPU-only and modeset-
  free. Out of scope for M1 (no GPU at M1); brought in at M2.

**The broker opens `card0`** at session start, as a capability the
compositor's manifest declares (`broker-and-transport.md` §3.3 — the
kernel-layer mask for a GPU device). The mask:

| Capability | `cap_rights_t` |
|---|---|
| GPU modesetting device (`card0`, M1) | `CAP_IOCTL` `CAP_MMAP_RW` `CAP_EVENT` `CAP_FSTAT` |

`CAP_IOCTL` is the modeset ioctl surface (§3); `CAP_MMAP_RW` is the
dumb-buffer mapping (§3); `CAP_EVENT` is the kqueue readiness on the fd
(§4). The exact ioctl set the device exposes is further restricted by
`cap_ioctls_limit`; the M1 audited list is §3.

The fd reaches the compositor in its bootstrap bundle as a
`Cap<GpuDevice, …>` grant (`abyss-bundle`, `broker-and-transport.md`
§5.8). The compositor never sees `/dev/dri/`; in capability mode it
couldn't open it anyway.

---

## 3. The ioctl surface for CPU scanout

The closed set the M1 compositor exercises, in the order it issues them
at startup:

| Stage | ioctl | What it does |
|---|---|---|
| Discovery | `DRM_IOCTL_MODE_GETRESOURCES` | Enumerate CRTCs, connectors, encoders, fbs. |
| Discovery | `DRM_IOCTL_MODE_GETCONNECTOR` | Per connector — connected? modes? preferred mode? |
| Discovery | `DRM_IOCTL_MODE_GETENCODER` | Encoder ↔ CRTC compatibility. |
| Discovery | `DRM_IOCTL_MODE_GETCRTC` | Current CRTC state (none — first boot). |
| Allocate | `DRM_IOCTL_MODE_CREATE_DUMB` | A CPU-mappable buffer of `width × height × bpp`. Returns a GEM handle and the stride. |
| Map | `DRM_IOCTL_MODE_MAP_DUMB` | An mmap offset for the dumb buffer. |
| Map | `mmap(card0, MAP_SHARED, offset)` | The compositor's `&mut [u8]` to render into. |
| Frame | `DRM_IOCTL_MODE_ADDFB2` | Wrap the dumb buffer in a framebuffer object (format, modifier, stride). |
| Modeset | `DRM_IOCTL_MODE_SETCRTC` | Bind the framebuffer to the CRTC on the chosen connector at the chosen mode. The first frame is on screen. |
| Flip | `DRM_IOCTL_MODE_PAGE_FLIP` (`DRM_MODE_PAGE_FLIP_EVENT`) | Atomic page-flip to a new framebuffer; the kernel queues a completion event on the fd, readable on the next VBlank. |
| Teardown | `DRM_IOCTL_MODE_RMFB` / `DRM_IOCTL_MODE_DESTROY_DUMB` | On shutdown. |

`ADDFB2` is preferred over `ADDFB`: it carries the DRM FOURCC (matching
`display.md`'s `Buffer::Shm.format`) and a modifier, so the M2 GPU path
reuses the same call with a `dmabuf`-backed GEM handle and a tiled
modifier.

**Double-buffering**: the compositor allocates **two** dumb buffers per
output, wraps each in a framebuffer, and ping-pongs — the front being
scanned out while the back is being composed. `PAGE_FLIP` swaps which is
the front. A third buffer (triple-buffering) is not needed for M1 and is
left for measurement.

**`cap_ioctls_limit`**, the §3.3 second-layer kernel restriction: the
audited M1 set is exactly the eleven ioctls above (mmap, in the table
for context, is not an ioctl). The broker applies the limit after
opening the fd, before passing it in the bundle. A compositor that
tries an ioctl outside the set takes an `ENOTCAPABLE` — the
kernel-enforced floor under the M1 surface.

---

## 4. The kqueue `EventSource`

The DRM fd is poll-readable when a queued completion is ready. The
M1 compositor watches it with `EVFILT_READ` on the `kqueue` reactor
(`broker-and-transport.md` §2.3) — the same reactor the transport and
the broker use. On readable:

1. `read(card0, buf, sizeof(drm_event))` until `EAGAIN`. Each completion
   is a `struct drm_event` header followed by a typed body — for M1
   the only kinds are `DRM_EVENT_FLIP_COMPLETE` (page-flip completed,
   carrying the user_data the flip was queued with) and
   `DRM_EVENT_VBLANK` (a queued VBlank waited on; not used at M1).
2. Each `FLIP_COMPLETE` turns into a looper event the compositor's
   frame-pacing handler consumes: the front/back buffers swap roles,
   the just-flipped surface's `Released` event is emitted on the
   display protocol (the client may now reuse the buffer), and the
   next frame can be queued.

The seam is the same `EventSource` trait the `Reactor` already exposes:

```text
struct DrmEventSource { fd : OwnedFd }
impl EventSource for DrmEventSource {
    fn interest(&self) -> Interest { Interest::READ }
    fn fd(&self) -> BorrowedFd<'_> { self.fd.as_fd() }
    fn on_ready(&mut self, ctx: &mut Ctx) { /* drain, dispatch */ }
}
```

The compositor registers it on its `Reactor` at boot, alongside the
transport's existing sources. No new thread, no `poll`, no `select` —
one loop, one reactor.

---

## 5. Hotplug

A connector hot-plug or hot-unplug arrives out of band: FreeBSD signals
it via `devd` (the system event daemon, `freebsd-src/sbin/devd`) — the
analogue of Linux's `udev`. The M1 compositor does **not** watch `devd`:
the M1 reference setup is a single VM display, the virtio-gpu connector
is present from boot, and a hot-plug of the host's monitor does not
propagate through to the VM.

Hotplug is a Phase 6 / M2 addition — the doc that pins it is
`render-backends.md` (Gate G) alongside the GPU path. The compositor's
existing connector enumeration (§3) handles it correctly when a new
connector appears between sessions; live hotplug needs the `devd` source.

---

## 6. The FFI crate — `sys/drm-sys`

`sys/drm-sys` is the FreeBSD-gated FFI for the §3 surface, mirroring the
shape of `freebsd-capsicum-sys`, `freebsd-jail-sys`, and friends
(`broker-and-transport.md` §6):

- **`target_os = "freebsd"`-gated.** Compiles to an empty library
  elsewhere — the macOS dev bed never sees a DRM symbol.
- **`bindgen` in `build.rs`** for the struct layouts and the ioctl
  command numbers that are header constants
  (`freebsd-src/sys/dev/drm2/drm/drm.h` and `drm_mode.h`). The crate
  follows the **C-shim FFI pattern** (`ONBOARDING.md` Conventions) for
  the `_IOC*` macros, which are not exported symbols and cannot be
  reached by `bindgen` alone: a small `drm_shim.c` exposes
  `DRM_IOCTL_MODE_*` as `extern const unsigned long` symbols, built by
  a `build.rs` calling system `cc` / `ar`. Same pattern as
  `freebsd-capsicum-sys`'s `cap_rights_*`.
- **Raw FFI only.** Higher-level wrappers — `Resources`, `Connector`,
  `Crtc`, `DumbBuffer`, `Framebuffer` — live in `abyss-compositor`, not
  in `sys/drm-sys`. The sys crate is the kernel surface; the policy is
  one layer up. (The pattern `freebsd-procdesc-sys` set.)
- **No `unsafe` in the rest of the workspace.** Everything that
  dereferences a struct or invokes an ioctl is contained here.

---

## 7. Atomic vs legacy

Atomic KMS (`DRM_IOCTL_MODE_ATOMIC`) is the better long-term API for
three reasons that all matter to a desktop compositor: it can drive
multiple planes (primary + cursor + overlay) in a single commit, it can
*test* a commit without applying it (so a layout can be probed for
scanout-eligibility before it is shown), and it carries arbitrary
properties (HDR metadata, gamma, content protection) cleanly.

M1 needs none of these. A single primary plane carrying a single
composited framebuffer, modeset once, page-flipped per frame, is what a
CPU compositor with one tiled top-level produces. Legacy KMS does that
in two ioctls. Atomic is adopted in Phase 6 with the GLES backend, when
multi-plane and direct scanout (the §M2 work in `display.md`) genuinely
need it.

This is the §3.5 review lens applied to a kernel API: build the simple
mechanism, measure, lift only what measurement (or the protocol's M2
needs) shows necessary.

---

## 8. The VM reference setup

The amd64 FreeBSD 15.0 VM gains a **virtio-gpu** device. virtio-gpu
under FreeBSD presents the standard DRM/KMS surface — `card0`, a single
connector, a single mode at the host window's resolution, dumb buffers,
page-flip — and is sufficient for the M1 bring-up. It is *not*
sufficient for the GPU path (Mesa's virgl backend is a separate Phase-6
question) and not sufficient for direct-scanout testing (no real
display).

The bare-metal reference box (AMD RX 6750 XT, `ROADMAP.md` §2) comes in
with Phase 6, when the GPU backend genuinely needs real silicon. M1's
"the terminal is usable" is provable in the VM alone.

**Provisioning step.** `tools/vm/cloud-init/user-data` and the QEMU
launch in `tools/vm/vm.sh` need `-device virtio-gpu` (and the kernel
modules to load it) added before Phase-5 code runs. That is the
environment delta Phase 5 carries — the only one before the bare-metal
box.

---

## 9. Deferred

- **Atomic KMS** — Phase 6 / Gate G, with the GPU backend.
- **Live hotplug via `devd`** — Phase 6 / Gate G.
- **Multi-output composition** — the WM core supports multi-monitor
  (`window-management.md` §10), but the M1 VM has one connector;
  multi-output bring-up is exercised when the bare-metal box has
  multiple physical outputs (Phase 6).
- **VRR and content-pacing** — `display.md`'s `Output.vrr` and
  `SetPresentMode` are M2 / M3 work tied to direct scanout.
- **GPU buffers (`dmabuf` import / export)** — Phase 6, alongside the
  GLES backend.
- **GBM and EGL bootstrap** — not used at M1 (no GPU); Phase 6.
