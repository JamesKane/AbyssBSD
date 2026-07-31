# Phase 7 — Portals: the capability desktop (scope)

The phase carved out of Phase 3 (PHASE3.md §6.1), expanded from a sketch into
executable detail, grounded in a read of the sibling's `reef-portal`, `reef-open`
and `reef-notify`. Read [PLAN.md](PLAN.md) for the locked decisions and
[PHASE3.md](PHASE3.md) for the substrate this builds on.

Last updated: 2026-07-30.

**Numbered 7, being done out of order.** PLAN.md's phases run 0–6 and this one is
new; it is being built now, before Phase 4 (Mac Pro) and Phase 6 (the Swift
compositor), because **it depends on nothing either of them provides**. The
numbering keeps existing references stable rather than renumbering four phases
for the sake of chronology.

**A correction that made this phase possible now.** PHASE3.md §6.1 carved this
out partly on the grounds that "the sibling's portal design is *compositor-owned*
(`reef-portal` lives in `tide`)". **That was wrong.** `reef-portal` is a shell
service under `de/reef/portal`, bound to `current`, that launches the file
manager as the picker — no compositor involved. Only screenshot wants compositor
privilege, and even that is reachable from a client through `wlr-screencopy`,
which is how `grim` has been taking every screenshot in this repo since Phase 1.
The dependency was on **`CurrentIPC`**, which P3.5 delivered.

---

## 1. What this phase is

**The brokerless answer to xdg-desktop-portal**, and PLAN.md's goal #3 made real:

> An app asks the desktop to pick a file. The portal runs the **Finder** as the
> picker, **opens the chosen file itself**, and returns the *open descriptor*
> over `SCM_RIGHTS`. The app reads a file it could never have opened — the demo
> client calls `cap_enter(2)` first and has no filesystem at all.
> **The descriptor is the capability.** No D-Bus, no broker, no flatpak.

That last sentence is the whole phase. Everything else is in service of being
able to demonstrate it end to end.

**Explicitly NOT in Phase 7** (decided 2026-07-30 with the user):

- **No D-Bus bridge, and no `org.freedesktop.portal.*`.** Stock GTK/Qt apps
  therefore do *not* get a working file chooser from us in this phase. That is a
  real gap and it is deliberate: D-Bus is a wire protocol we would have to speak
  from Swift (or back stock `xdg-desktop-portal` with our own backend), it
  roughly doubles the phase, and none of it advances the capability story that
  makes this design worth having. The guest already carries `dbus-1.16.2` and
  `gtk3` for whenever we do.
- **No XWayland, MPRIS or AT-SPI.** Same reasoning, further out.
- **No jail plumbing.** The sandboxed client proves the *capability* half with
  Capsicum; running an app in a real jail with the portal socket bind-mounted in
  is FreeBSD systems work that belongs with Phase 4's hardware/jail story.
- **No compositor.** As everywhere else, we run on stock sway/labwc.

---

## 2. What we already have vs. what's new

The substrate is done, which is why this phase is mostly *assembly*:

| Need | Have | New in Phase 7 |
|---|---|---|
| Typed IPC + **fd passing** | `CurrentIPC` (P3.5) — `SCM_RIGHTS`, `Server`, `call` | — |
| A file picker | the **Finder** (P2.6/P2.6b/P2.6c) | a **picker mode**: choose one file, report it, exit |
| A service host | `Current.Server`, run-loop hook (§2.18) | the `portal` service itself |
| Notifications | — | an **Aqua toast** (layer-shell OVERLAY) + `notify` |
| Screenshot | `grim` in the harness | **`wlr-screencopy`** bound in `Surface` |
| Sandboxing | — | **Capsicum** `cap_enter(2)` in the demo client |

---

## 3. Component map (sibling → ours)

| Job | Sibling | Ours | Notes |
|---|---|---|---|
| The portal service | `reef-portal` (234 LOC) | `Portal` + `abyss-portal` | `file.open`, `file.save`, `notify`, `screenshot` |
| The sandboxed client | `reef-open` (90 LOC) | `abyssopen` | `cap_enter`, then read through the returned fd |
| Notify CLI | `reef-notify` (110 LOC) | `abyssnotify` | the `notify-send` analog |
| The picker | `reef-fm` | our **Finder** | needs the picker seam (P7.1) |
| The toast | `reef-panel`'s toast | **new Aqua UI** | the sibling's panel is GNOME-2 dress; ours is Jaguar |

Small components — ~430 LOC of Rust total — because the hard part (fd-passing
IPC) is already built and the picker is a program we already have.

---

## 4. Ordered passes

**P7.1 — The Finder as a picker.**
A `--pick` mode (`$ABYSS_FINDER_PICK=<result-path>`): the window opens as an
ordinary Finder, choosing a file writes its path to the result file and exits,
Cancel exits without writing. The sibling used exactly this — a private result
file — and it keeps the picker a *separate process* with no portal API surface,
which is what lets it be the app we already have rather than a library.
*Verify:* a live run picks a seeded file and the result file holds its path;
cancelling leaves it empty. Unit-test the pure part (result encoding, cancel).

**P7.2 — The portal service: `file.open` and `file.save`.**
`abyss-portal` binds the `portal` service and answers:
- `file.open {dir?}` → runs the picker, **opens the picked path itself**
  (`O_RDONLY`), replies `{ok, path}` + fd `file`.
- `file.save {dir?, name?}` → same, `O_WRONLY|O_CREAT`.
- Both reply `{ok:false, error:"cancelled"}` when the user declines.

**The confused-deputy rule, written down before the code:** the requesting app
supplies only a *suggested start directory*. The portal opens **the path the
user chose in the picker**, never a path the app sent. An app that could name
the file it wanted would be using the portal as a privileged `open(2)`, which is
the exact bug portals exist to prevent.
*Verify:* unit tests for the request/reply shapes; a live test where a client
gets a readable fd for a file it names nowhere.

**P7.3 — The sandboxed client (the headline).**
`abyssopen` calls **`cap_enter(2)`** — irreversibly dropping into Capsicum
capability mode, with no `open`-by-path and no global namespace — and *then*
asks the portal for a file. It reads the contents through the returned
descriptor and writes them to stdout (an already-open fd; a sandboxed process
cannot create a new one either).
Capsicum is FreeBSD-only, so this claim is **verifiable only in the VM**; on
Linux the same binary runs unsandboxed and says so rather than implying a
sandbox it doesn't have.
*Verify:* in the guest, `abyssopen` prints a file's contents **after** entering
capability mode, and a control run proves `open(2)` on the same path fails from
inside the sandbox — the second half is what makes the first half mean anything.

**P7.4 — Notifications: an Aqua toast, and `notify`.**
A notification window in Jaguar dress on a layer-shell **OVERLAY** surface, with
`keyboard_interactivity: none` so it never steals focus, stacking for multiple
notifications, a timeout, and click-to-dismiss. Then the portal's
`notify {summary, body?, timeout?}` relays to it, and `abyssnotify` is the CLI.
A jailed app reaches the toast **only** through the portal — it never holds the
shell's control socket, which is the same trust boundary the file chooser draws.
*Verify:* pure layout tests (stacking, wrapping, timeout arithmetic); live, a
toast appears on the desktop and disappears on its own, captured with grim.

**P7.5 — Screenshot, as a capability.**
Vendor `wlr-screencopy-unstable-v1`, bind it in `Surface` (the mechanical recipe
— HANDOFF §7 — `xdg-activation` is the worked example), and add
`screenshot {}` → a fd holding the PNG. Same shape as the file chooser: the app
receives **a descriptor, not a path**, and never gets to name what it captures.
*Verify:* live, a client with no filesystem access receives a screenshot fd whose
bytes are a valid PNG of the right dimensions.

---

## 5. Verification

Unchanged discipline: pure logic in unit tests, the real thing live under
headless sway, everything green on **both** platforms — except the Capsicum
half, which is FreeBSD-only by nature and must say so rather than being quietly
skipped. `abyss/tests/run.sh --vm --live` remains the gate.

---

## 6. Risks / open decisions

**6.1 The picker is a whole file manager, and it must not become a library.**
Keeping it a separate process (result file, exit code) is what makes this cheap;
the temptation will be to link the Finder into the portal for a "nicer" API and
lose the isolation that makes the design safe.

**6.2 Cancel must be unambiguous.** "The user cancelled" and "the picker
crashed" have to be distinguishable, or a crashed picker silently looks like a
declined request. Exit code *and* result-file state, checked together.

**6.3 The portal is a trusted process.** It runs as the user with full
filesystem access, on purpose. Its whole security value is that it opens only
what the *user* picked — §6.1's confused-deputy rule is the invariant to test,
not just document.

**6.4 Capsicum limits what the demo can do.** After `cap_enter` there is no
`open`, no `socket`... **including the portal socket itself** — so the client
must connect *before* entering capability mode and keep the connection as its
only capability. Getting that order wrong makes the demo fail in a way that
looks like the portal is broken.

**6.5 The toast is net-new Aqua UI.** Jaguar's notification style is not in the
512pixels library the way windows and menus are (Growl-era third-party
conventions muddy it), so this is a *design* decision as much as an
implementation one — expect to iterate on it rather than copy a reference.

**6.6 Screenshot on someone else's compositor.** `wlr-screencopy` is a wlroots
protocol; a Swift compositor (Phase 6) will have to implement it, or the
screenshot portal will need a compositor-owned path then. Worth knowing now, not
worth solving now.

**6.7 The D-Bus gap is real.** Until the carved-out bridge exists, a stock GTK
or Qt app gets no file chooser from us. Anyone reading "portals: done" should
read it as "*our* portals, for *our* apps, done".
