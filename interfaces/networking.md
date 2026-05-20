# Networking — interface schema

> Concrete message schema for the **networking interface**. Shape:
> `DESIGN.md` §11.12. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Exported by** — the networking component (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §11.12.
- **Consumed by** — the desktop shell (the network indicator and the user's
  network management) and apps (connectivity status).
- **Interface id** — `networking`.

This is a **control-plane** interface — it manages connectivity by driving
the FreeBSD base (`dhclient`, `wpa_supplicant`, `ifconfig`); no packet ever
flows through it (`DESIGN.md` §11.12).

## Data types

- **`NetworkId`** — an opaque id for a network (a Wi-Fi SSID/BSSID, a wired
  link).
- **`Network`** — `{ id, kind : enum{wifi,wired}, name : string,
  signal : f64?, security : enum{open,wpa,…}, saved : bool }`.
- **`Connectivity`** — `{ state : enum{offline,connecting,online},
  network : NetworkId?, address : string?, signal : f64? }`.

## Messages — consumer → networking

```
List       — request                          → list<Network> | Error
Status     — request                          → Connectivity | Error
Connect    — request
  network     : NetworkId
  credentials : dict?                          (e.g. a Wi-Fi passphrase)
  → Ack | Error
Disconnect — request   network : NetworkId?    → Ack | Error   (absent = the active one)
Subscribe  — request (retained)                → Connectivity | Error
Forget     — command   network : NetworkId     (drop a saved profile)
```

`Subscribe`'s reply is the current `Connectivity`; the retained capability
then receives the events below. Connection profiles — remembered networks,
auto-join — are the networking component's own persistent state; a
successful `Connect` to a new network saves one.

## Messages — networking → subscriber

```
ConnectivityChanged — event   connectivity : Connectivity
NetworksChanged     — event                              (the scan list changed)
```

`NetworksChanged` lets a Wi-Fi picker update live; the consumer re-issues
`List` to get the new set.

## Capabilities

A `Cap<Networking>` carries which operations it permits. Typical grants: the
**shell** — all of `List` / `Connect` / `Disconnect` / `Forget` /
`Subscribe` (the user manages networks through it); an **app** — `Status`
and `Subscribe` only, so it can tell whether it is online but cannot change
the connection.

## Errors

`ErrorCode`: `unknown-network`; `auth-failed` (wrong Wi-Fi credentials);
`connect-failed` (association or DHCP failed); `not-permitted` (an operation
the capability does not grant).

## Examples

**Join a Wi-Fi network:**
```
→ List
← [ {id:home, kind:wifi, name:"home", security:wpa, saved:false}, … ]
→ Connect  network=home  credentials={passphrase:"…"}
← Ack
networking → subscribers:  ConnectivityChanged  {state:online, network:home, …}
```

**Rejected — wrong passphrase:**
```
→ Connect  network=cafe  credentials={passphrase:"wrong"}
← Error    code=auth-failed  detail="WPA handshake failed"
```
