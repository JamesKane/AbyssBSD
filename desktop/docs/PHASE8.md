# Phase 8 — the D-Bus bridge: portals for everyone else (scope)

The half carved out of Phase 7, twice deferred and now due. Read
[PHASE7.md](PHASE7.md) for the portals this extends, [PLAN.md](PLAN.md) for the
locked decisions, and [HANDOFF.md](HANDOFF.md) for the interop traps.

Last updated: 2026-08-07. **Scoped, not started.** Two risks were spiked first,
on both platforms (§4), because the phase's shape depended on the answers.

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
knows how — gets **the Finder** as its file chooser and **a descriptor** as its
answer.

The claim in one line:

> An unmodified GTK application calls `org.freedesktop.portal.FileChooser.OpenFile`
> and receives an **open file descriptor** for a file the user picked in the
> Finder — the same picker, the same portal, and the same capability our own
> sandboxed clients already get.

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
| Descriptor passing | `CurrentIPC`, SCM_RIGHTS (P3.5) | fd out over D-Bus' own unix-fd type |
| A socket + codec discipline | `CurrentIPC`'s wire format, `Msg` | the D-Bus wire format |
| A service host pattern | `Current.Server`, the run-loop hook | a D-Bus connection in the same loop |
| A supervisor | `anchor` (P3.6) | it starts `dbus-daemon` and `abyss-dbus` |
| A compositor to run apps on | `undertow` (Phase 6) | GTK apps are just more clients |

---

## 3. Ordered passes

**P8.1 — `de/dbus`: the wire protocol, as a library.**
Connect to `$DBUS_SESSION_BUS_ADDRESS` (unix path *and* abstract), SASL EXTERNAL
authentication, the message header, the type system we actually need
(`s o u b v a{sv} ay h`), serial/reply matching, and method dispatch. No portal
yet.
*Verify:* unit tests for marshalling round-trips against known-good byte
sequences, and a live test that registers a name on a **real `dbus-daemon`** and
answers an introspection call — `dbus-send` as the client, so the other end is
not our own code.

**P8.2 — `abyss-dbus`: the portal on the bus.**
Own `org.freedesktop.portal.Desktop`, implement `FileChooser.OpenFile` and
`SaveFile`, and the `Request`/`Response` object lifecycle the portal API is built
on (a method returns an object path; the answer arrives later as a signal on it).
Translate to `abyss-portal` over `CurrentIPC`.
*Verify:* `dbus-send`/`gdbus` drives `OpenFile` end to end, the Finder opens, and
the reply carries a descriptor.

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

**6.1 The portal API is asynchronous and object-based.** A method call returns an
object path immediately and the *answer* arrives later as a `Response` signal on
that object, which the client is expected to have subscribed to first. Getting
the lifecycle wrong (emitting before the client subscribes, or reusing a path)
produces a client that hangs with no error — the same failure shape as P6.3's
missing configure. Budget for it.

**6.2 A descriptor over D-Bus is a different mechanism.** Our portal hands out
fds over `SCM_RIGHTS` directly; D-Bus has its own unix-fd type (`h`) with a
separate fd array and a `UNIX_FDS` header field, and the connection must have
negotiated fd passing. The fd we send is the same fd — only the envelope changes.

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
