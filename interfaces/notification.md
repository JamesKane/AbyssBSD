# Notification — interface schema

> Concrete message schema for the **notification interface**. Shape:
> `DESIGN.md` §11.6. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Exported by** — the notification service (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §11.6.
- **Consumed by** — *posters* (any app or service holding a post capability)
  and the *desktop shell* (which renders).
- **Interface id** — `notification`.

A poster's identity is **taken from its capability**, not self-declared — a
poster cannot post as another app.

## Data types

- **`NotificationId`** — assigned by the service; lets a poster `Update` or
  `Withdraw` its own notification.
- **`Urgency`** — `enum { low, normal, critical }`; `critical` bypasses
  do-not-disturb.
- **`Action`** — `{ label : string, invoke : Cap }` — a button label and the
  capability the service invokes when the user clicks it.

## Messages — poster → notification service

```
Post     — request
  title   : string    body : string    icon : string?
  urgency : Urgency   actions : list<Action>
  timeout : i64?                          (ms; service default if absent)
  replace : NotificationId?               (update one in place, not stack)
  → NotificationId | Error

Update   — request    id : NotificationId   …any Post field to change…   → Ack | Error
Withdraw — command    id : NotificationId
```

`actions` carries capabilities (`Action.invoke`) — handles in the envelope
handle array (`README.md`, envelope mapping). When the user clicks an
action the service sends to that capability; the poster is called back
directly, no name routing.

## Messages — shell ↔ notification service

```
Subscribe — request (retained)   (shell → service)   → list<Notification> | Error
History   — request              (shell → service)   → list<Notification> | Error

Posted / Updated / Withdrawn — event   (service → shell)

Dismissed     — command   (shell → service)   id : NotificationId
ActionInvoked — command   (shell → service)   id : NotificationId   action : i64
Expired       — command   (shell → service)   id : NotificationId
```

`Subscribe` returns the current active set, then streams `Posted` /
`Updated` / `Withdrawn`; the shell renders popups and the notification
centre from these. `History` returns the session history. On `ActionInvoked`
the service invokes the corresponding `Action.invoke` capability.

## Capabilities

- A **poster** holds `Cap<Notifications>`, post-scoped, handed out by the
  broker; the service derives the poster's identity from it.
- The **shell** holds a shell-scoped capability — `Subscribe`, `History`,
  and the interaction commands; a poster's capability grants none of those.

## Errors

`ErrorCode`: `unknown-id` (`Update`/`Withdraw` of an id not posted by this
capability); `rate-limited` (the poster exceeded its per-app policy, §11.6);
`not-permitted` (a shell-only message sent on a poster capability).

## Examples

**Post with an action:**
```
→ Post  title="Build finished"  body="abyssbsd: 0 errors"  urgency=normal
        actions=[ {label:"Open log", invoke:<cap>} ]
← NotificationId  4711
…  the user clicks "Open log"  …
shell → service:   ActionInvoked  id=4711  action=0
service → poster:  «sends to the action capability»
```

**Posting as another app is unexpressible** — there is no app-identity
field; identity *is* the capability. The attempt cannot even be formed.
