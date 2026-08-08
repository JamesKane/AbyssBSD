# Phase 8 — the D-Bus bridge: portals for everyone else (scope)

The half carved out of Phase 7, twice deferred and now due. Read
[PHASE7.md](PHASE7.md) for the portals this extends, [PLAN.md](PLAN.md) for the
locked decisions, and [HANDOFF.md](HANDOFF.md) for the interop traps.

Last updated: 2026-08-08. **P8.1 and P8.2 done** — we speak D-Bus with no
library, we own `org.freedesktop.portal.Desktop`, and a foreign caller gets the
Finder. Two risks were spiked first, on both platforms (§4), because the phase's
shape depended on the answers; a third — what the answer actually *is* — was
found by reading the interface definition in P8.2 and is recorded in §6.6.

**Numbered 8 because it is new.** PLAN.md runs 0–6, Phase 7 was added for
portals; this is the piece Phase 7 explicitly refused, promoted to a phase of its
own rather than smuggled into another.

---

## 1. What this phase is

**The honest reading of "portals: done".** PHASE7 §6.7 says it plainly:

> *"Until the carved-out bridge exists, a stock GTK or Qt app gets no file
> chooser from us. Anyone reading 'portals: done' should read it as **our**
> portals, for **our** apps, done."*

This phase deletes that caveat. A stock GTK or Qt application — one that knows
nothing about AbyssBSD, was built for GNOME, and asks for a file the only way it
knows how — gets **the Finder** as its file chooser.

The claim in one line:

> An unmodified GTK application calls `org.freedesktop.portal.FileChooser.OpenFile`
> and **the Finder opens** — the same picker, the same portal, and the same file
> the user chose.

**That sentence used to end "and receives an open file descriptor", and it was
wrong.** P8.2 read the interface definition off disk
(`/usr/share/dbus-1/interfaces/org.freedesktop.portal.FileChooser.xml`, shipped
by xdg-desktop-portal) instead of remembering it, and the `Response` signal
carries `uris` — an array of strings — and nothing else that names the file.
There is no `h` in it, in any version. The descriptor is not something this
bridge withholds; it is something *their* protocol has no room for. §6.6 says
what that costs and why it is worth stating rather than papering over.

**We are the portal.** `abyss-dbus` owns `org.freedesktop.portal.Desktop` on the
session bus and translates each call into a `CurrentIPC` request to the existing
`abyss-portal`, which runs the Finder and opens the chosen file exactly as it
does today:

```
  GTK app ──D-Bus──▶ abyss-dbus ──CurrentIPC──▶ abyss-portal ──▶ Finder
                     (org.freedesktop.portal.Desktop)
```

Decided 2026-08-07 with the user, over backing stock `xdg-desktop-portal` with an
`org.freedesktop.impl.portal.*` implementation. The alternative is less protocol
surface for us, but it puts a **broker daemon** on the path — the exact thing
this project's architecture is a rejection of — and would leave two portal
frontends with different behaviour. One picker for our apps and legacy apps
alike is worth the extra code.

**Explicitly NOT in this phase:**

- **No XWayland.** X11 apps are a separate substrate; the D-Bus story stands on
  its own and this phase is long enough.
- **No MPRIS, no AT-SPI, no notifications-over-D-Bus.** They are the same
  machinery pointed at other interfaces, and each is cheap once the plumbing
  exists. FileChooser is the one that makes an application *usable*.
- **No jail plumbing.** PLAN.md wants the bridge jailed; that is FreeBSD systems
  work belonging with Phase 4's hardware/jail story, exactly as PHASE7 said of
  the sandboxed client.
- **We do not implement a bus.** `dbus-daemon` from ports is the session bus.
  Writing a broker would be absurd for a project whose whole argument is that
  brokers should not be on the critical path — and nothing here is.

---

## 2. What we already have vs. what's new

| Need | Have | New in Phase 8 |
|---|---|---|
| A portal that opens files | `abyss-portal` + the Finder picker (P7.1/P7.2) | nothing — it is reused verbatim |
| Descriptor passing | `CurrentIPC`, SCM_RIGHTS (P3.5) | nothing — `FileChooser` answers with a URI (§6.6) |
| A socket + codec discipline | `CurrentIPC`'s wire format, `Msg` | the D-Bus wire format |
| A service host pattern | `Current.Server`, the run-loop hook | a D-Bus connection in the same loop |
| A supervisor | `anchor` (P3.6) | it starts `dbus-daemon` and `abyss-dbus` |
| A compositor to run apps on | `undertow` (Phase 6) | GTK apps are just more clients |

---

## 3. Ordered passes

**P8.1 — `de/dbus`: the wire protocol, as a library. ✅ done.**
Connect (unix path *and* abstract addresses), SASL EXTERNAL with
`NEGOTIATE_UNIX_FD`, the message header and framing, the type system the portal
needs, serial/reply matching, and method dispatch. **No dependency at all** —
`de/dbus` imports only `CPlatform`, for the same `SCM_RIGHTS` helpers
`CurrentIPC` has used since P3.5.

**The rule the whole format turns on:** a value is aligned to its natural
boundary **measured from the start of the message**, not from the start of
whatever buffer it is being written into. A marshaller that trusts `bytes.count`
produces bytes its own reader accepts and every real bus rejects — so
`Marshaller` and `Unmarshaller` both carry an explicit `origin`, and a unit test
pins it by marshalling the same value at two different origins and checking the
padding differs.

Three more places the format is easy to get quietly wrong, each now a test:
a **string's** length is a `u32` and excludes its NUL, while a **signature's** is
a single *byte*; an **array's** declared length counts its content and **not**
the padding between the length word and the first element (include it and every
array of 8-aligned things reads four bytes long); and a **descriptor** is
marshalled as an *index* into an out-of-band array, exactly as `CurrentIPC`
learned in P3.5 — decoding with the wrong fd count now throws rather than
handing back somebody else's descriptor.

*Verified:* **18 unit tests** (197 total) for the rules above, plus
`abyss/tests/live-dbus.sh` — and the point of that test is **the client on the
other end is never our own code**. `dbus-daemon` is the bus; `dbus-send` calls
us; and **`gdbus` — GLib's implementation, an entirely independent encoder —
round-trips the `a{sv}` options dictionary every portal method takes, a nested
array, and parses our introspection XML with its own parser.** It also asserts
that an unknown method gets an **error reply rather than silence**, because a
caller that receives nothing hangs for its whole timeout with no diagnostic —
the same failure shape as P6.3's missing xdg-shell configure.

**P8.2 — `abyss-dbus`: the portal on the bus. ✅ done.**
`org.freedesktop.portal.Desktop` is ours: `FileChooser.OpenFile` and `SaveFile`,
the `Request`/`Response` object lifecycle, `Properties`, `Introspectable`, and a
translation to `abyss-portal` over `CurrentIPC`. The Finder that opens is the
same Finder P7.1 built, launched by the same portal, with no second code path.

**The API has two ways to hang and no way to report either**, and the pass is
arranged around them. Both end with a client waiting for a `Response` signal that
never comes — the same failure shape as P6.3's missing xdg-shell configure.

1. **The wrong object path.** The handle is
   `/org/freedesktop/portal/desktop/request/SENDER/TOKEN`, built from the
   *caller's* unique name (`:1.42` → `1_42`) and the caller's own `handle_token`.
   A modern client computes it *itself* and subscribes before calling. Derive it
   any other way — a serial of ours, our own name — and that client is listening
   to a path nothing is ever emitted on.
2. **Emitting before the reply is on the wire.** An older client has no token; it
   calls, takes the handle it is given, and subscribes *then*. So the picker must
   not run inside the method handler — a handler's return value is what gets
   sent, so blocking there would answer the dialog before the caller ever learned
   where to listen. The slow half is queued and drained by the run loop instead.

*Verified:* **14 unit tests** (211 total) and `abyss/tests/live-portal-dbus.sh`,
which runs five real processes — `dbus-daemon`, sway, `abyss-portal`,
`abyss-dbus`, a caller — and **both** client shapes. `gdbus` introspects us with
its own XML parser, reads the `version` property, has a `handle_token` containing
a `/` refused with `InvalidArgs`, and **decodes the `Response` signal and its
`uris` independently of our decoder**.

Both hazards were then *injected* to check the test can fail, because a suite
that has never failed has not been shown to test anything (§2.37): running the
picker inside the handler left the late client waiting the full 90s, and dropping
the `.`→`_` substitution failed both the unit test and the live one.

**P8.3 — A real GTK application.**
`GtkFileChooserNative` on a stock GTK 3 app, running as a client of `undertow`,
picking a file through the Finder. The guest already carries `gtk3`.
*Verify:* the app receives a file it never named, and the picker it saw was ours.
**This is the pass that deletes PHASE7 §6.7's caveat**, and nothing before it
does.

**P8.4 — The session, whole.**
`anchor` starts `dbus-daemon` and `abyss-dbus` alongside the shell, with
`DBUS_SESSION_BUS_ADDRESS` in the environment of everything it launches.
*Verify:* one command boots a desktop where a stock GTK app can open a file.

---

## 4. The spikes — two risks, retired before planning

### 4.1 Can Swift speak D-Bus without a library? — **Yes, on both platforms.**

The alternatives were all bad. **libdbus** is discouraged by its own
documentation for new code; **GDBus** means GLib, which drags in the whole GTK
stack this project rejects on principle (DESKTOP.md §1: *"No GTK … it pulls in
D-Bus"*, which would be a fine irony); **sd-bus** is systemd and does not exist
on FreeBSD. And the Linux dev box has `libdbus-1.so.3` but **no `dbus-devel`**,
so even the libdbus path would need a package installed with the user's sudo,
while the FreeBSD guest has the full `dbus-1.16.2` with pkg-config — an
asymmetry that would bite exactly once, on the wrong machine.

So the spike asked whether we need any of them. Connect → SASL EXTERNAL → a
hand-marshalled `Hello` → read the assigned name back, in ~110 throwaway lines:

```
auth: OK 022c46c2118662ffa53bb4b86a76206e
OK: the bus assigned us :1.0        # Linux
OK: the bus assigned us :1.0        # FreeBSD
```

**No dependency at all, and identical code on both platforms.** That is the same
answer this project reached for its own control plane: `CurrentIPC` speaks a wire
format we wrote rather than binding libnv. D-Bus is a bigger format but a
well-specified one, and we need only the *client* side of it — connect, own a
name, answer calls, emit signals.

*The one platform difference the spike found is already in the book:*
`SOCK_STREAM` imports as `__socket_type` on Linux and a plain `Int32` on the BSDs
(HANDOFF §2.32), so it needs the same one-line `#if` `CurrentIPC` already has.

### 4.2 Is there anything to test against? — **Yes, on both.**

`dbus-daemon`, `dbus-run-session` and `dbus-send` are present on the dev box and
in the guest (`dbus-1.16.2`), and the guest carries `gtk3` — put there in Phase 3
for exactly this, as PHASE7 noted while declining to use it. So every pass can be
tested against a **real bus and a real GTK client**, not against our own encoder.

---

## 5. Verification

Unchanged discipline: pure logic in unit tests, the real thing live, everything
green on **both** platforms, `abyss/tests/run.sh --vm --live` as the gate.

One addition specific to this phase, and it is the reason the passes are ordered
as they are: **the other end must not be our own code.** A marshaller tested only
against its own parser is the "model that agrees with you" trap (HANDOFF §2.37)
in its purest form — it will round-trip beautifully and still be wrong. So every
live test drives us with `dbus-send`, `gdbus`, or a real GTK application.

---

## 6. Risks / open decisions

**6.1 The portal API is asynchronous and object-based.** *Retired in P8.2, and it
cost about what was budgeted.* A method call returns an object path immediately
and the *answer* arrives later as a `Response` signal on that object, which the
client is expected to have subscribed to first. There turned out to be **two**
ways to get it wrong, not one, and each is invisible to the client shape that
exposes the other — see P8.2 above. Both are now driven by the live script, and
both were injected once to prove the script can fail.

**6.2 A descriptor over D-Bus is a different mechanism.** *Moot, as it turns
out.* This anticipated marshalling an `h` into the reply; §6.6 records what P8.2
found instead — `FileChooser` has no descriptor in its answer at all. The `h`
support in `de/dbus` is real and tested, but the file chooser does not use it.

**6.3 `dbus-daemon` is a broker, and we are running one.** Worth saying plainly
rather than pretending otherwise: this phase adds the exact kind of process the
architecture argues against. What keeps it honest is *where* it sits — nothing on
the frame path talks to it, no native app needs it, and if it dies the desktop
does not notice. It is a legacy adapter, and PLAN.md always called it one.

**6.4 GTK will want more than FileChooser.** A real GTK app may probe
`org.freedesktop.portal.Settings`, `Documents`, or the accessibility bus, and may
behave oddly when they are absent. The mitigation is to find out with a real app
in P8.3 rather than guess now — but expect the interface list to grow by one or
two before a GTK file dialog is happy.

**6.5 Version drift.** The portal interfaces are versioned and evolve upstream.
We implement what a current GTK asks for and pin the versions we advertise; a
future GTK may ask for more. This is the standing cost of speaking somebody
else's protocol, and it is why Phase 7 preferred its own.

**6.6 Their answer is a name; ours is a capability.** Found in P8.2 by reading
the interface definition rather than remembering it. `FileChooser`'s `Response`
returns `uris` — strings — so a legacy client is told *where* the file is and
opens it by name, with whatever authority it already had. Our own portal returns
an **open descriptor** over `SCM_RIGHTS`, which is why `abyssopen` can read a
file from inside Capsicum capability mode with no filesystem at all.

The gap is not ours to close. It is why flatpak needs a **FUSE daemon** — the
Documents portal — to make those names mean anything inside a sandbox: having
handed out a path, something must then be standing behind it. So `abyss-dbus`
closes the descriptor `abyss-portal` opened and forwards the path, and the
capability stops at the bridge. That is the honest boundary of this phase: a
foreign app gets **our picker and the user's choice**, and the confused-deputy
property survives (it still cannot name a file). What it does not get is the
capability, because its own protocol cannot hold one.

**6.7 One dialog at a time.** `abyss-portal` blocks while the picker is up
(P7.2's documented cost), so `abyss-dbus` does too. A second `OpenFile` arriving
mid-dialog is answered with its handle immediately and queued. The visible
consequence: a `Request.Close` sent while a picker is on screen is not *seen*
until that picker exits — the `Response` is correctly suppressed, but the dialog
is not torn down. Worth fixing when something needs it; not worth threads now.
