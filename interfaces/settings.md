# Settings — interface schema

> Concrete message schema for the **settings interface**. Shape: `DESIGN.md`
> §11.5. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Exported by** — the settings service (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §11.5.
- **Consumed by** — the input service, compositor, desktop shell, power &
  lifecycle service, notification service, networking, audio, and apps.
- **Interface id** — `settings` (the canonical name; a numeric id is
  assigned at the §6.2 envelope layer).

The settings service holds one typed, hierarchical key tree. Each key's
type, default, and metadata come from **declarative schema files** the
service loads at start (`DESIGN.md` §11.5) — the wire interface carries no
schema-registration message.

## Data types

- **`Path`** — a dotted key path, e.g. `input.keyboard.repeat-rate`. A path
  names either a *key* (a leaf holding a value) or a *subtree* (an interior
  node).
- **`Value`** — a §6.3 typed value: `bool`, `i64`, `f64`, `string`, an
  `enum` variant, `list<Value>`, or a `dict` (a name→`Value` map). A key
  holds a scalar `Value`; a subtree's value is a `dict`.
- **`Descriptor`** — a key's schema: `{ type, default: Value, label:
  string, … }` — metadata for a settings UI.
- **`ErrorCode`** — see *Errors*.

## Messages — client → settings service

```
Get  — request
  path : Path
  → Value | Error
```
Returns the **effective** value of `path` — resolved user → system → schema
default (`DESIGN.md` §11.5). If `path` is a subtree, the `Value` is a `dict`
of the subtree. `Error` if the path is unknown or outside the capability's
read scope.

```
Set  — request
  path  : Path
  value : Value
  → Ack | Error
```
Writes `value` to `path` in the per-user layer. `value`'s type is checked
against the key's schema type. On success `Changed` fires to every covering
subscriber. `Error` for `unknown-key`, `type-mismatch`, `out-of-scope`, or
`read-only`.

```
Subscribe  — request (retained)
  path : Path
  → Value | Error
```
The success reply is the current effective value of `path` — the initial
snapshot. The reply-to capability is then **retained** as the event sink:
the service sends a `Changed` event for every key under `path` whose
effective value subsequently changes, until the subscription ends.

```
Unsubscribe  — command
  path : Path
```
Releases the subscription `Subscribe` established for `path`. Optional for
correctness — a subscription also ends when its capability is dropped or the
client disconnects — it exists to free resources early.

```
Describe  — request
  path : Path
  → dict<Path, Descriptor> | Error
```
Returns the schema descriptors — type, default, metadata — for every key
under `path`. This is how a settings-UI app enumerates settings without
reading schema files directly.

## Messages — settings service → subscriber

```
Changed  — event
  key   : Path
  value : Value
```
Sent to a subscriber's retained sink for each key, under a path it
subscribed, whose effective value changed. `value` is the new effective
value. Events on one connection are ordered (`DESIGN.md` §6.4).

## Capabilities

A client holds a `Cap<Settings>` (`DESIGN.md` §11.5) carrying a **scope** —
a set of `(subtree, rights)` grants, `rights ∈ {read, read-write}`. A
typical component's capability grants `read-write` on its own subtree and
`read` elsewhere.

- `Get`, `Subscribe`, `Describe` require `read` covering `path`.
- `Set` requires `read-write` covering `path`.
- A request outside scope is rejected — `out-of-scope`, or `read-only` for a
  `Set` where only `read` is held. Scope is enforced by the capability (the
  §10 rights model), not by an ACL the service maintains.

## Errors

`Error { code: ErrorCode, detail: string }`. `ErrorCode`:

- `unknown-key` — `path` is in no loaded schema.
- `type-mismatch` — (`Set`) `value`'s type ≠ the key's schema type.
- `out-of-scope` — `path` is outside the capability's scope.
- `read-only` — (`Set`) the capability grants only `read` for `path`.

## Examples

**Accepted** — read, then watch:
```
→ Get        path = "compositor.display.scale"
← Value      1.0
→ Subscribe  path = "compositor.display"
← Value      { scale: 1.0, … }                 (snapshot)
…  the user changes the scale  …
← Changed    key = "compositor.display.scale"  value = 2.0
```

**Rejected** — a type mismatch:
```
→ Set    path = "input.keyboard.repeat-rate"  value = "fast"
← Error  code = type-mismatch  detail = "repeat-rate is i64, got string"
```

**Rejected** — out of scope (the audio component's capability grants write
only on `audio.*`):
```
→ Set    path = "input.keyboard.layout"  value = "dvorak"
← Error  code = out-of-scope  detail = "audio cannot write input.*"
```
