# Audio — interface schema

> Concrete message schema for the **audio interface**. Shape: `DESIGN.md`
> §11.13. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Exported by** — the audio component (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §11.13.
- **Consumed by** — the desktop shell (the volume indicator and control)
  and apps (querying devices and volume).
- **Interface id** — `audio`.

**This interface is control only.** Audio playback and capture do *not*
flow through it: an app opens the kernel audio device directly, via a
brokered, playback/capture-scoped capability granted from its app manifest,
and the FreeBSD kernel mixes (`DESIGN.md` §11.13). That device capability is
separate from `Cap<Audio>` below. This interface sets volume, selects the
default device, and reports changes — nothing more. It is deliberately
small because the data path is elsewhere.

## Data types

- **`AudioDeviceId`** — an opaque audio-device id.
- **`Direction`** — `enum { output, input }`.
- **`AudioDevice`** — `{ id, name : string, direction : Direction,
  default : bool }`.
- **`Target`** — `enum { master } | AudioDeviceId | StreamId` — what a
  volume applies to.
- **`Volume`** — `{ level : f64 (0–1), muted : bool }`.

## Messages — consumer → audio service

```
ListDevices      — request                       → list<AudioDevice> | Error
GetVolume        — request   target : Target      → Volume | Error
SetVolume        — request   target : Target   volume : Volume   → Ack | Error
SetDefaultDevice — request   device : AudioDeviceId   → Ack | Error
Subscribe        — request (retained)             → Snapshot | Error
```

`Snapshot` is `{ devices : list<AudioDevice>, volumes : dict<Target,Volume> }`;
the retained capability then receives the events below.

## Messages — audio service → subscriber

```
DeviceChanged — event                  (a device arrived, left, or became default)
VolumeChanged — event   target : Target   volume : Volume
```

When the default output device changes — headphones plugged in — a playing
app re-opens on the new device; because AbyssBSD has a single toolkit, that
is handled once in the Media Kit (`DESIGN.md` §11.13), not per app.

## Capabilities

A `Cap<Audio>` carries which targets it may control. Typical grants: the
**shell** — `master` and per-device volume, `SetDefaultDevice`, `Subscribe`
(it draws the volume indicator); an **app** — `Subscribe` and `SetVolume`
on its *own* stream only. Microphone capture is gated separately, on the
audio-device capability, not here (§11.13).

## Errors

`ErrorCode`: `unknown-device`; `unknown-target`; `not-permitted` (a target
or operation outside the capability's grant).

## Examples

**The volume indicator:**
```
→ Subscribe
← Snapshot { devices:[…], volumes:{ master:{level:0.6, muted:false} } }
…  the user drags the slider  …
→ SetVolume  target=master  volume={level:0.4, muted:false}
← Ack
audio service → subscribers:  VolumeChanged  target=master  volume={0.4,false}
```

**Rejected — an app setting master volume:**
```
→ SetVolume  target=master  volume={level:1.0, muted:false}
← Error      code=not-permitted  detail="app may set only its own stream"
```
