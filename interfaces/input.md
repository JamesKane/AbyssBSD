# Input — interface schema

> Concrete message schema for the **input interface**. Shape: `DESIGN.md`
> §7.5. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Exported by** — the input service (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §7.5.
- **Consumed by** — the compositor (device lifecycle and the event stream)
  and the power & lifecycle service (the activity signal only).
- **Interface id** — `input`.

This interface is **push-only**: the input service emits, consumers issue no
requests. The connections are pre-wired by the broker at session start
(`DESIGN.md` §11.9) — there is no `Subscribe`; a consumer holds a sink
capability and receives events on it. Keyboard events carry **both** a raw
keycode and a cooked interpretation (§7.5) — see `Key` below.

## Data types

- **`DeviceId`** — an opaque per-device id, stable for the device's lifetime.
- **`Time`** — a monotonic event timestamp (nanoseconds).
- **`DeviceKind`** — `enum { keyboard, pointer, touch, tablet }`.
- **`Modifiers`** — a bitset: shift, control, alt, meta, caps-lock, … .

## Messages — input service → compositor

```
DeviceAdded   — event     device : DeviceId   kind : DeviceKind   axes : dict
DeviceRemoved — event     device : DeviceId

Key           — event
  device  : DeviceId   time : Time
  keycode : i64                    (raw physical key — layout-independent)
  keysym  : i64                    (cooked — xkb keymap applied)
  text    : string                 (cooked — committed text, if any)
  mods    : Modifiers              (cooked modifier state)
  pressed : bool                   (physical transition: down / up)
  repeat  : bool                   (true = synthetic key-repeat)

PointerMotion — event
  device : DeviceId   time : Time
  dx, dy : f64                              (relative)
  x, y   : f64?                             (absolute, if reported)

PointerButton — event     device : DeviceId   time : Time   button : i64   pressed : bool
PointerScroll — event     device : DeviceId   time : Time   axis : enum{vertical,horizontal}   delta : f64

Touch         — event
  device : DeviceId   time : Time
  touch  : i64        phase : enum{down,move,up}   x, y : f64

Gesture       — event
  device : DeviceId   time : Time
  kind   : enum{swipe,pinch,hold}   phase : enum{begin,update,end}   params : dict

Tablet        — event     device : DeviceId   time : Time   …tool, pressure, tilt, x, y…
```

Every `Key` carries **both** representations: the raw `keycode` — the
physical key, independent of keyboard layout, which games bind directly
(WASD by position) — and the cooked `keysym` / `text` / `mods` (the xkb
keymap applied), which text-handling apps use. `pressed` is the physical
transition; `repeat = true` marks a synthetic key-repeat (per the
key-repeat-rate setting) that games filter out.

`Tablet` is sketched; its fields are pinned when tablet support lands.

## Messages — input service → power & lifecycle service

```
Activity — event
```
A coarse pulse: the user produced input recently. It is **de-rated** — at
most one per second — so the power service learns of activity without
seeing raw input (§7.5). The power service times idle from the last
`Activity` (§11.8).

## Capabilities

Two sink capabilities, both handed out by the broker at wiring time: the
**compositor's** sink receives device lifecycle and the event stream; the
**power service's** sink receives `Activity` and nothing else. A consumer
cannot request input it was not wired to receive — there is no
general-subscription request.

## Errors

None. The interface carries only events, no requests.

## Examples

**A keypress reaches the focused window:**
```
input service → compositor:
  Key  device=kbd0  time=…  keycode=30  keysym=0x61  text="a"  mods={}  pressed=true  repeat=false
```
The compositor routes it to the focused surface via the display protocol
(§7.4).

**Idle detection:**
```
input service → power service:  Activity            (the user moves the mouse)
…  no Activity for the configured timeout  …
power service: idle — emits IdleEntered to its subscribers (§11.8)
```
