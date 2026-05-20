# Broker — interface schema

> Concrete message schema for the **broker interface**. Shape: `DESIGN.md`
> §11.9. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Exported by** — the broker (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §11.9.
- **Consumed by** — components that launch children (chiefly the desktop
  shell, launching apps) and an inspection tool.
- **Interface id** — `broker`.

The broker is **unusual** — most of what it does is not a request/reply API.
`rc` starts it; it reads the component manifests and brings up the fixed
system-component set itself (`DESIGN.md` §11.9) — that bring-up is the
broker's startup logic, manifest-driven, not messages. The runtime message
interface below is narrow: delegated spawn, termination, supervision
notices, inspection.

## The bundle — a component's birth state (not a message)

A component does not *request* its capabilities; it is **born holding
them**. When the broker spawns a component into its jail, the process starts
with its **bundle** already in hand — the capabilities its manifest declares
(§11.9): the pre-wired connection endpoints to its peers, its device and
resource capabilities, its scoped `Cap<Settings>`. There is no "get my
capabilities" message; from its first instruction a component holds exactly
its bundle and no more (`DESIGN.md` §10.1).

The broker, the **root of authority** (§10.4), grants the bundle. For a
system component the grant is the manifest, full stop. For an app the grant
is the app manifest **∩ what the user approved** (§11.14). The bundle is
*not* bounded by whoever asked for the spawn — the broker is the authority;
the caller is only the launcher.

## Messages — client → broker

```
Spawn     — request   bundle : Path        → ChildId | Error
Terminate — command   child  : ChildId
Inspect   — request                        → SystemPicture | Error
```

`Spawn` launches a child — chiefly the shell launching an app (`bundle` is
the app bundle's path, §11.14). The broker reads the bundle's manifest,
computes the grant (above), creates the jail, and spawns the child holding
its bundle. `ChildId` lets the caller `Terminate` the child or correlate
`ChildExited`.

A caller may *additionally* hand capabilities **it itself holds** to a child
— by ordinary capability delegation over the bus, attenuated. *That* is
bounded by what the caller holds (`DESIGN.md` §10.1); a child's *birth
bundle* is not.

`Inspect` returns the live picture — components running, the connection and
capability graph — plainly, for a debug or inspection tool (§11.9).

## Messages — broker → component

```
PeerRestarted — event   peer : InterfaceId   connection : Cap
ChildExited   — event   child : ChildId      status : enum { exited, crashed }
```

When the broker restarts a crashed component (supervision, §11.9), each of
its peers receives `PeerRestarted` with a fresh connection capability — the
old connection is dead. A component that `Spawn`ed a child receives
`ChildExited` when the child goes away (the shell uses it to drop the app
from the window list).

## Capabilities

- `Cap<Broker>` with the **spawn grant** — held by components that launch
  children (chiefly the shell); permits `Spawn`, and `Terminate` of that
  component's own children only.
- `Cap<Broker>` with the **inspect grant** — held by a debug/inspection
  tool; permits `Inspect`.
- Most components hold *no* broker capability — they neither spawn nor
  inspect; they are simply spawned and supervised. `PeerRestarted` arrives
  on broker-established wiring and needs no capability to receive.

The spawn grant is the authority to *launch* — it is not the authority an
app receives. So the shell need not hold microphone, network, or file
capabilities in order to launch apps that use them.

## Errors

`ErrorCode`: `no-such-bundle` (`Spawn` of a bundle that is not installed);
`manifest-invalid` (the bundle's manifest is malformed); `unknown-child`
(`Terminate` of a `ChildId` the caller did not spawn); `not-permitted` (a
message the capability does not grant).

## Examples

**The shell launches an app:**
```
→ Spawn  bundle = "/Applications/Editor.app"
  broker: reads the manifest; grant = manifest ∩ user-approved;
          creates the jail; spawns the app holding its bundle
← ChildId 22
…  the user closes the app; it exits  …
← ChildExited  child=22  status=exited
```

**A component crashes and is restarted:**
```
   the settings service crashes
   broker: restarts it — fresh jail, fresh bundle, peers re-wired
→ (to each peer)  PeerRestarted  peer=settings  connection=<fresh cap>
```

**Rejected — spawning without the grant:**
```
→ Spawn  bundle = "/Applications/Editor.app"     (caller: a component with
         no spawn grant — only the shell launches apps)
← Error  code=not-permitted  detail="capability does not grant Spawn"
```
