# Device monitor — interface schema

> Concrete message schema for the **device monitor interface**. Shape:
> `DESIGN.md` §11.7. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Exported by** — the device monitor (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §11.7.
- **Consumed by** — the input service (input-device arrivals), the desktop
  shell (removable media), networking (interface hotplug), and audio
  (audio-device hotplug).
- **Interface id** — `device-monitor`.

Reports hardware presence (fed by FreeBSD's `devd`) and mounts removable
volumes. ACPI/power events are *not* here — the power service reads those
from `devd` directly (`DESIGN.md` §11.8).

## Data types

- **`DeviceId`** — an opaque device id, stable for the device's lifetime.
- **`DeviceClass`** — `enum { input, storage, audio, network, other }`.
- **`Device`** — `{ id : DeviceId, class : DeviceClass, identity : dict,
  usable-via : dict }` — `identity` is descriptive (vendor, model, …);
  `usable-via` carries what a consumer needs to open it.

## Messages — consumer → device monitor

```
Subscribe — request (retained)
  classes : list<DeviceClass>            (the classes to watch)
  → list<Device> | Error                 (the current set, then events)

Mount   — request
  device : DeviceId                      (a removable-storage device)
  → MountedVolume | Error

Unmount — request
  device : DeviceId
  → Ack | Error
```

`Mount`'s success reply, `MountedVolume`, is a **capability** to the mounted
filesystem subtree — a handle in the envelope handle array. The requester
(typically the shell, on user action) may delegate it onward — e.g. to the
file manager — by ordinary capability delegation (`DESIGN.md` §10.4). Whether
a volume mounts automatically or only on `Mount` is a setting (§11.5).

## Messages — device monitor → subscriber

```
DeviceArrived — event   device : Device
DeviceRemoved — event   device : DeviceId
```

Delivered to each subscriber for the classes it watches — the input service
sees `input` arrivals, the shell sees `storage`, and so on.

## Capabilities

A `Cap<DeviceMonitor>` carries a **class scope** and whether it permits
`Mount`. Typical grants: the input service — `Subscribe` on `input`; the
shell — `Subscribe` on `storage` plus `Mount`/`Unmount`; networking and
audio — `Subscribe` on their class. `Mount` requires the mount grant; a
consumer without it cannot mount.

## Errors

`ErrorCode`: `unknown-device`; `not-mountable` (the device has no mountable
filesystem); `mount-failed` (the mount operation itself failed);
`already-mounted`; `not-permitted` (`Mount` without the grant, or a class
outside scope).

## Examples

**A USB stick is inserted and opened:**
```
device monitor → shell:   DeviceArrived  device={id:da0, class:storage, …}
…  the user clicks the volume in the shell  …
shell → device monitor:   Mount  device=da0
device monitor → shell:   MountedVolume <cap>
shell → file manager:     «delegates the MountedVolume capability» (§10.4)
```

**Rejected — mounting without the grant:**
```
→ Mount   device=da0
← Error   code=not-permitted  detail="capability does not grant Mount"
```
