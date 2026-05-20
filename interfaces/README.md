# AbyssBSD component interfaces — concrete schemas

`DESIGN.md` (repo root) gives each component interface its *shape* — its
responsibility, what it exports and consumes, the boundary. This directory
gives the **concrete typed message schema** for each interface: the actual
messages, their fields and types, their request/reply pairings.

One document per interface. `settings.md` is the first, and the template.

## Conventions

All interface docs follow these. They are fixed here so no doc repeats them.

### Message kinds

Every message is one of three kinds:

- **request** — carries a *reply-to capability*; the recipient sends back
  exactly one message: the typed success reply, or an `Error`.
- **command** — fire-and-forget; no reply, no reply-to capability.
- **event** — unsolicited; sent by a service to a *retained* sink
  capability the client gave it earlier.

A **subscription** is a request whose reply-to capability the service
*retains* — rather than spending it on one reply — and uses as the event
sink for an ongoing stream.

### Request/reply

A request carries a **fresh reply-to capability** (`DESIGN.md` §6.5). The
reply — success or `Error` — is the single message sent to it; the
capability is then spent. The capability *is* the correlation: there are no
request-ids, and a reply can reach no one but the one waiter. A
subscription's reply-to capability is retained, not spent.

### Errors are values

A request's reply is a success value or an `Error` — never an exception;
errors are ordinary `Result`-style values, not unwinding (a `panic!` is for
defects, not for an interface's failure modes). `Error` is `{ code, detail }`:
`code` a per-interface enum, `detail` a human-readable string. Errors are
ordinary messages.

### Lifetime

A subscription — and any retained capability — ends when the capability is
dropped or its holder disconnects. No explicit teardown is needed for
*correctness*; an `Unsubscribe`-style command exists only to release
resources early. (Same discipline as the power inhibitors, `DESIGN.md`
§11.8.)

### Envelope mapping

Each message is one envelope (`DESIGN.md` §6.2): the **interface id** and
the message's **method id** in the header; the fields serialized as the
payload (the self-describing dict, §6.3); every capability — including the
reply-to capability — in the handle array.

### Document template

Each interface doc has, in order: **Interface** (id, exporting component,
the `DESIGN.md` section it realizes, consumers); **Data types**; **Messages**
(grouped by direction — each with kind, fields, reply); **Capabilities**;
**Errors**; **Examples** (accepted and rejected exchanges).

### Notation

A message is written:

```
Name  — kind
  field : Type
  field : Type
  → ReplyType | Error        (requests only)
```

`Ack` is the empty success reply (a request that succeeds with no payload).
Types are the §6.3 typed-value types — `bool`, `i64`, `f64`, `string`,
`enum`, `list<T>`, `dict` — plus interface-defined types.

## The interfaces

One document per component interface:

- `settings.md` — the typed configuration store (get / set / subscribe).
- `input.md` — the normalized input event stream (input service → compositor).
- `notification.md` — posting notifications and rendering them.
- `power.md` — power & lifecycle: events, control, inhibitors.
- `device-monitor.md` — device presence and removable-volume mounting.
- `networking.md` — desktop network management.
- `audio.md` — desktop audio control (control-plane only).
- `display.md` — the compositor's display protocol.
- `broker.md` — spawn, supervision, and the capability bundle.
- `scripting.md` — the cross-cutting introspect / get / set / invoke suite
  every handler answers.
- `session-lock.md` — the unlock report.
- `shell.md` — the desktop shell (a consumer; exports only scripting).
- `toolkit.md` — the toolkit (a library; the scriptable window/view model).
