# The wire format & the typed-message layer

> Design elaboration for **Gate A** (`../ROADMAP.md` §5). It makes
> `../DESIGN.md` §6.2–§6.4 implementable: the self-describing value
> vocabulary, the byte layout of the envelope, and the `#[derive(Wire)]`
> contract. This is the foundation for **Phase 1** — the `abyss-msg` and
> `abyss-msg-derive` crates.
>
> Status: draft.

---

## 1. Scope & principles

One message primitive carries everything (`DESIGN.md` §6). In-process it is
a value moved by ownership — no serialization. This document governs the
*other* case: the **cross-process representation**, the only place a wire
format exists at all.

The shape is fixed by `DESIGN.md`:

- **Self-describing** (§6.3). A message is a BMessage-like dict of named,
  typed fields. A script — or the bus router, or a generic tool — can parse
  and build one with *no compile-time schema*.
- **Tagged, copying, not zero-copy** (§6.4). Construction ergonomics win
  over marshalling cost. Every value carries its type tag; the serializer
  copies. No layout trickery, no unsafe transmutes.
- **Typed views for OS code** (§6.3). AbyssBSD's own code does not touch the
  untyped dict — `#[derive(Wire)]` generates typed structs over it, with
  compile-time field checking. Scripts use the dict directly.
- **Validated on receipt** (§6.3). Because scripts send arbitrary messages,
  every decode is fallible and total: malformed input is an `Err`, never a
  panic, never undefined behaviour.
- **Hold it in your head** (§3.5). Nine value kinds, a 16-byte header, one
  recursive encoder. If this document needs a second sitting to understand,
  it is wrong.

Three layers, bottom-up: the **value vocabulary** (§2), its **byte
encoding** and the **envelope** (§3–§4), and the **`Wire` trait + derive**
that projects typed Rust onto it (§6–§7).

---

## 2. The value vocabulary

A `Value` is the self-describing unit. There are **nine kinds** — and the
interface schemas (`interfaces/README.md`) already name them.

| Kind      | Holds                                             | Rust (in `abyss-msg`)            |
|-----------|---------------------------------------------------|----------------------------------|
| `bool`    | `true` / `false`                                  | `Value::Bool(bool)`              |
| `int`     | a signed 64-bit integer                           | `Value::Int(i64)`                |
| `float`   | an IEEE-754 binary64                              | `Value::Float(f64)`              |
| `string`  | UTF-8 text                                        | `Value::Str(String)`             |
| `bytes`   | an opaque binary blob (small — see below)         | `Value::Bytes(Vec<u8>)`          |
| `list`    | an ordered sequence of `Value`                    | `Value::List(Vec<Value>)`        |
| `dict`    | an ordered map, `string` name → `Value`           | `Value::Dict(Vec<(String,Value)>)` |
| `variant` | a tagged union: a name + optional payload `Value` | `Value::Variant { tag, value }`  |
| `handle`  | a reference to a capability in the handle table   | `Value::Handle(u32)`             |

That is the whole vocabulary. Notes that are decisions, not description:

- **One integer width.** The wire has exactly one integer type, `int` =
  `i64`. Narrower Rust integers ride it (§6); `u64`, `usize`, and `isize`
  are deliberately *not* representable — a desktop message needs neither the
  top bit of a u64 nor a pointer-width type on the wire (the 32-bit-clean
  goal, §3.6). One width, no `usize` — hold it in your head.
- **One float width**, `float` = `f64`. No `f32` on the wire.
- **`bytes` is for *small* binary** — a hash, a cookie, a keymap blob.
  Large data never travels inline (§6.2): it is shared as a memory
  capability (`memfd`/shm) in the handle table. `bytes` is not an escape
  hatch from that rule.
- **`dict` is ordered.** Entries serialize in the order given; duplicate
  names are rejected on decode. A `#[derive(Wire)]` type always emits its
  fields in declaration order, so a typed message has one canonical
  encoding — which makes golden-vector tests and the §11.16 on-disk
  attribute format well-defined.
- **`variant` is the enum.** `tag` is the variant name; `value` is its
  payload, `None` for a unit variant. This is how Rust `enum`s — message
  errors, `ErrorCode`, kind discriminants — cross the bus.
- **`handle` carries no authority itself.** It is a `u32` index into the
  envelope's handle table (§4). The capability — fd or bus token, with its
  rights — lives there, out of band. This *is* the §6.2 payload/handle
  split.

The **payload of a message is a single `Value`** — for a message defined by
named fields, a `dict`; for a reply defined as returning one value (e.g.
settings `Get → Value`), that value directly. The encoder is uniform: it
serializes one `Value`, whatever its kind.

---

## 3. The byte encoding

### 3.1 Conventions

- **Little-endian** for every multi-byte integer. The reference
  architecture is amd64 (`DESIGN.md` §5); aarch64 agrees. Fixed, not
  negotiated.
- **Fixed-width** lengths and counts — `u32` unless stated. No varints:
  §6.4 chose ergonomics over marshalling size; a varint is an optimization
  to measure-then-add, not to assume (§3.5).
- **No padding, no alignment.** The serializer copies; nothing is cast.
- Sizes below are exact.

### 3.2 Value encoding

Every value is `[ tag : u8 ] [ body ]`. The tag:

```
0x01 bool     0x04 string    0x07 dict
0x02 int      0x05 bytes     0x08 variant
0x03 float    0x06 list      0x09 handle
```

Bodies:

```
bool      1 byte         0x00 = false, 0x01 = true; any other byte → error
int       8 bytes        i64, two's-complement, little-endian
float     8 bytes        IEEE-754 binary64, little-endian
string    4 + N bytes    len : u32, then N = len bytes of UTF-8 (no NUL)
bytes     4 + N bytes    len : u32, then N = len raw bytes
list      4 + … bytes    count : u32, then `count` values (tag+body each)
dict      4 + … bytes    count : u32, then `count` entries; each entry is
                         name (a string body: u32 len + UTF-8) then a value
variant   … bytes        tag  (a string body: u32 len + UTF-8),
                         then present : u8 (0 = no payload, 1 = payload),
                         then one value iff present = 1
handle    4 bytes        index : u32 into the envelope handle table
```

`string` and a `dict` entry's name share the same `u32 len + UTF-8` shape;
both are validated as UTF-8 on decode.

### 3.3 The envelope

The cross-process unit (`DESIGN.md` §6.2). Three sections, in order:

```
┌─ Header — 16 bytes, fixed ─────────────────────────────────────────┐
│ off  size  field                                                   │
│  0    1    version       wire-format version; 1                    │
│  1    1    kind          1 = request, 2 = command, 3 = event        │
│  2    2    flags         u16, reserved — must be 0 in v1            │
│  4    4    interface_id  u32  (§7)                                  │
│  8    2    method_id     u16  (§7)                                  │
│ 10    2    handle_count  u16  number of handle-table entries        │
│ 12    4    payload_len   u32  byte length of the payload section    │
├─ Payload — payload_len bytes ──────────────────────────────────────┤
│ exactly one encoded Value (§3.2) — a `dict` for a fielded message   │
├─ Handle table — handle_count entries ──────────────────────────────┤
│ entry := [ kind : u8 ] [ body_len : u32 ] [ body : body_len bytes ] │
└─────────────────────────────────────────────────────────────────────┘
```

`kind` is carried even though a method's kind is fixed by its schema (§7):
it lets the bus router and generic tools treat an envelope without holding
every schema — the point of "self-describing". A `request` carries a
reply-to capability; the router must see that from the header alone.

`flags` is reserved. One future use is named so the bit is not
re-purposed: selecting a **compact payload encoding** for hot paths (§6.3 —
input events, frame callbacks). v1 has only the tagged encoding above; a
decoder rejects a nonzero `flags`.

Framing: on `SOCK_SEQPACKET` the datagram boundary delimits the envelope; a
decoder still reads `payload_len` / `handle_count` exactly and **rejects
trailing bytes**. The shm fast-path ring frames by these same lengths.

### 3.4 The handle table

A handle-table entry is, to `abyss-msg`, **opaque framed bytes**:
`kind : u8`, then `body_len : u32`, then `body`. `abyss-msg` serializes the
framing and bounds-checks `Value::Handle` indices against `handle_count` —
it does not interpret `kind` or `body`.

The body's *meaning* belongs to the next layer down:

- **kind 1 — fd-capability.** A kernel resource (device, memory, socket).
  The fd itself is passed by `SCM_RIGHTS`, out of band; the body carries
  the Capsicum `cap_rights_t` mask. fd-capabilities correlate to the passed
  fd array by order.
- **kind 2 — object-capability.** A bus routing token naming an object
  exported by another process, plus its object-rights set.

The exact body layouts, the `cap_rights_t` encoding, and `SCM_RIGHTS`
correlation are defined with `abyss-cap` (Phase 2) and the transport
(**Gate D**) — not here. The layering is deliberate: `abyss-msg` owns
*framing*, `abyss-cap` owns *capability meaning* (`DESIGN.md` §3.4). It is
also what lets Phase 1 build and test `abyss-msg` on the host with no
FreeBSD and no real fds — a handle is just opaque bytes until Phase 4.

---

## 4. Decoding untrusted input

Scripts — and any peer — send arbitrary bytes. Decoding is **total**: it
returns `Result`, never panics, never reads or allocates out of bounds.
Every one of these is a checked `Err`, not a trap:

- a truncated section (a length/count exceeding the remaining input);
- an unknown value tag, an unknown envelope `version`, a nonzero `flags`;
- a `bool` byte other than `0x00`/`0x01`;
- non-UTF-8 in a `string`, a `dict` name, or a `variant` tag;
- a `dict` with a duplicate name;
- a `Value::Handle` index ≥ `handle_count`;
- bytes left over after the one root `Value`, or after the handle table;
- **nesting deeper than `MAX_DEPTH` = 64** — `list`/`dict`/`variant` recur,
  and a hostile payload must not exhaust the stack. The decoder counts
  depth and rejects past the bound.

The decoder **never pre-allocates from an untrusted count.** A `u32` count
of four billion does not become a four-billion-capacity `Vec`; elements are
decoded one at a time and the input runs out first. `payload_len` is
likewise capped by the transport's maximum message size (Gate D).

`WireError` names the failure — `Truncated`, `BadTag`, `BadUtf8`,
`BadVersion`, `BadFlags`, `DepthExceeded`, `DuplicateKey`,
`BadHandleIndex`, `TrailingBytes` for the byte layer; the typed layer adds
more (§6).

---

## 5. Bytes ↔ Value

`abyss-msg` exposes the byte layer directly:

```rust
impl Value {
    fn encode(&self) -> Vec<u8>;                       // §3.2, infallible
    fn decode(bytes: &[u8]) -> Result<Value, WireError>;
}

struct Envelope { header: Header, payload: Value, handles: Vec<RawHandle> }

impl Envelope {
    fn encode(&self) -> Vec<u8>;                       // §3.3
    fn decode(bytes: &[u8]) -> Result<Envelope, WireError>;
}
```

`RawHandle { kind: u8, body: Vec<u8> }` is the opaque framed entry of §3.4.
This layer is the whole of what scripts and generic tools need. Typed Rust
code goes through §6 instead.

---

## 6. The `Wire` trait

`Wire` marks a type that may cross the bus (`DESIGN.md` §6.10) and converts
it to and from a `Value`. Encoding threads a **handle sink** so capability
fields land in the handle table (§3.4); decoding threads a **handle store**
they are moved out of.

```rust
pub trait Wire: Sized {
    /// Encode into a `Value`; push any capability into `handles`.
    fn to_wire(&self, handles: &mut HandleSink) -> Value;

    /// Decode from a `Value`; move any capability out of `handles`.
    fn from_wire(value: &Value, handles: &mut HandleStore) -> Result<Self, WireError>;
}
```

- `HandleSink` is an append-only collector: `push(RawHandle) -> u32` returns
  the index a `Value::Handle` then carries.
- `HandleStore` owns the received handles: `take(u32) -> Result<RawHandle,
  WireError>` moves one out. A handle has exactly one owner — taking it
  twice is `WireError::HandleTaken` (`DESIGN.md` §6.10, move-only).

Plain data types ignore both parameters; only capability types
(`abyss-cap`, Phase 2) use them. A whole message encodes by building its
payload `Value` and the handle table together, then framing the envelope
(§3.3); it decodes by `Envelope::decode` then `T::from_wire`.

**Hand-written impls in `abyss-msg`:**

- `bool` → `Bool`; `i64` → `Int`; `f64` → `Float`; `String` → `Str`.
- `i8`, `i16`, `i32`, `u8`, `u16`, `u32` → `Int`, **range-checked** on
  decode (`WireError::IntOutOfRange` if the `i64` does not fit). `u64`,
  `usize`, `isize` are intentionally not `Wire` (§2).
- `Bytes` (a newtype around `Vec<u8>`) → `bytes`. `Vec<u8>` itself is *not*
  `bytes` — a plain `Vec<T>` is a `list` (next line), and Rust cannot
  specialize the two on stable. A `bytes` field uses `abyss_msg::Bytes`.
- `Vec<T: Wire>` → `list`.
- `Value` → itself (the identity impl — for replies typed as a bare value).
- `Option<T>` is **field-level only**: it is not a value kind. In a `dict`,
  `Some` is an entry present, `None` is the entry omitted. The derive
  handles it (§7); `Option` is not `Wire` on its own.

The typed layer's `WireError` variants: `TypeMismatch { expected, found }`,
`MissingField(name)`, `UnknownVariant(tag)`, `IntOutOfRange`,
`HandleTaken`.

---

## 7. The derive macro

`abyss-msg-derive` provides `#[derive(Wire)]`. It generates the `Wire` impl
— the typed view over the dict (`DESIGN.md` §6.3). The generated
`from_wire` *is* the "validated on receipt" check: it is the only thing OS
code needs to call, and it is total.

**On a `struct` → `dict`.** Each field is one entry; the key is the field
name. `from_wire` requires a `Value::Dict`, then for each field looks up its
key and calls the field type's `from_wire`:

- a missing entry for a non-`Option` field → `WireError::MissingField`;
- a missing entry for an `Option<T>` field → `None`; present → `Some`;
- **unknown extra entries are ignored** — a newer sender may add a field; an
  older receiver reads what it knows and is unharmed (it still validates
  every field it does read). Forward compatibility, safely.

**On an `enum` → `variant`.** The `tag` is the variant name.

- a unit variant `V` → `Variant { tag: "V", value: None }`;
- a one-field tuple variant `V(T)` → `value` is `T`'s `Value`;
- a multi-field tuple variant `V(A, B)` → `value` is a `list`;
- a struct variant `V { a, b }` → `value` is a `dict`;
- an unknown `tag` on decode → `WireError::UnknownVariant`.

**Attributes** — kept minimal; each earns its place:

- `#[wire(rename = "name")]` on a field or variant — the wire name differs
  from the Rust identifier.
- `#[wire(rename_all = "kebab-case")]` on the container — map every field
  or variant name. Justified concretely: interface error codes are
  kebab-case (`unknown-key`, `type-mismatch` — `settings.md`) while Rust
  variants are `UpperCamel`.

No `default`, `skip`, or `flatten` in v1 — `Option` already covers an
absent field, and the rest are speculative until a schema needs them
(§3.5). They are added when one does, not before.

`abyss-msg-derive` is tested with `trybuild`: derivation on the supported
shapes compiles; unsupported shapes (a union, a generic without bounds)
fail with a clear message.

---

## 8. Interface & method ids

The header's `interface_id : u32` and `method_id : u16` are the numeric
form of the names in `interfaces/` (`settings`, its `Get` / `Set` / …).
Sixty-five thousand methods per interface and four billion interfaces is
ample headroom that costs six header bytes.

The **name → id registry** is a single explicit, version-controlled table
(§3.5 — never an opaque or auto-hashed mapping; a stable id must never
shift). Its mechanism — hand-maintained constants, or generated from the
`interfaces/` docs — is settled when interface-schema codegen is designed
(a later gate). Phase 1's `abyss-msg` carries `interface_id` / `method_id`
as plain header fields and does not assign them.

---

## 9. Deferred — named so it is not forgotten

- **Compact payload encoding** (§6.3 hot path). A `flags` bit is reserved
  (§3.3). Designed when the input/display fast-path is measured to need it
  — not before (§3.5).
- **Envelope nesting** for bus routing (§6.2). An outer routing envelope
  carries an inner one; the inner's handle table must be hoisted to the
  outer, since fds pass at the transport. No special wire support is
  reserved — it is a transport concern, specified at **Gate D**.
- **Handle body layouts** — `cap_rights_t`, bus tokens, `SCM_RIGHTS`
  correlation. `abyss-cap` (Phase 2) and the transport (**Gate D**).
- **The id registry mechanism** (§8).

---

## 10. What Phase 1 builds

This document is complete enough to implement Phase 1 with no further
design. Two crates, both host-built and host-tested (`ROADMAP.md` §4):

**`crates/abyss-msg`** — `Value` and its `encode`/`decode` (§3.2, §5); the
`Envelope`, `Header`, and `RawHandle` and their `encode`/`decode` (§3.3);
the `Wire` trait with `HandleSink` / `HandleStore` and the hand-written
primitive impls (§6); `WireError`; the `Bytes` newtype.

**`crates/abyss-msg-derive`** — `#[derive(Wire)]` for structs and enums
with the `#[wire(...)]` attributes (§7).

**Test plan** (the host-testability the phase ordering was chosen for):

- **Round-trip** — `decode(encode(v)) == v` for `Value`, for envelopes, and
  for derived typed messages.
- **Property tests** — arbitrary `Value` trees (bounded depth) round-trip;
  arbitrary derived messages round-trip.
- **Decoder fuzzing** — arbitrary and mutated byte input always yields
  `Ok` or `Err`, never a panic, hang, or over-allocation. The §4
  guarantees are the fuzz oracle.
- **Golden vectors** — encodings of fixed messages are checked into the
  repo as bytes; a diff catches an accidental format change.
- **`trybuild`** — the derive's accepted and rejected forms (§7).

CI (`cargo xtask ci`) runs all of it on every change.
