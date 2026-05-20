# Session lock — interface schema

> Concrete message schema for the **session lock interface**. Shape:
> `DESIGN.md` §11.11. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Exported by** — the session lock (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §11.11.
- **Consumed by** — the power & lifecycle service.
- **Interface id** — `session-lock`.

The session lock is the trusted, minimal unlock path. Its exported interface
is correspondingly minimal — a single message. Most of what it does it does
as a *consumer*: it receives `LockNow` from the power interface (§11.8),
draws its unlock surface as a display client (`display.md`), and
authenticates the user against the system (FreeBSD PAM). None of that is
this interface — this interface is only the result it reports.

## Messages — session lock → power & lifecycle service

```
Authenticated — command
```
Sent once, when the user has authenticated successfully. The power &
lifecycle service — which owns lock *state* — responds by emitting
`Unlocked` to its subscribers (§11.8); the compositor then releases the
input confinement. A failed authentication sends nothing: the session lock
simply keeps presenting its surface.

## Capabilities

The session lock holds a `Cap<Power>` permitting exactly this `Authenticated`
report and nothing else — it cannot request suspend, shutdown, or lock.

Conversely, **no component holds a capability to drive the session lock.**
In particular the broker mints no scripting capability to it, so — by the
rule in `scripting.md` — the session lock is not scriptable: the unlock path
cannot be driven by a script. It is moved only by the `LockNow` event it
consumes.

## Errors

None. `Authenticated` is a fire-and-forget command with no failure mode of
its own.

## Example

```
power service → session lock:  LockNow                  (power interface, §11.8)
session lock:  presents the unlock surface; the compositor confines input
…  the user authenticates successfully (FreeBSD PAM)  …
session lock → power service:  Authenticated
power service → subscribers:   Unlocked
```
