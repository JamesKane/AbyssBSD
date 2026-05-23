// SPDX-License-Identifier: BSD-2-Clause

//! The broker's session runtime — compiled only on FreeBSD.
//!
//! A [`Session`] is one running manifest set. The broker pre-wires it from
//! an authority [`Graph`] — a `SOCK_SEQPACKET` ring per connection, each
//! component's bootstrap [`Bundle`] assembled — spawns every component into
//! its jail, and then *supervises* it. Wiring, spawning, and supervision are
//! one runtime (`docs/design/broker-and-transport.md` §5.2, §5.5): the
//! `Session` owns every component's process and the broker's end of its
//! control channel, watches each process descriptor on a `kqueue` reactor,
//! and on an exit re-wires.
//!
//! Re-wiring a restarted component: the session creates a fresh ring for
//! every connection the dead component touched, respawns it holding a fresh
//! bundle of its ends, and sends each surviving peer a [`PeerRestarted`]
//! over that peer's control channel — one fresh [`Grant`] replacing the
//! now-dead ring (§5.5).
//!
//! Activation is eager and pre-wired: every ring exists before any component
//! is spawned, so each component is born holding both ends of every ring it
//! touches. A restart restores that invariant for one component.

use std::collections::HashMap;
use std::fmt;
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, RawFd};
use std::path::PathBuf;

use abyss_bundle::{
    Bundle, CapBody, CasperChannel, Grant, PeerRestarted, Role, SpawnChild, SpawnReply,
};
use abyss_msg::{Envelope, Header, MessageKind};
use abyss_transport::{Channel, Event, Interest, MessageChannel, Reactor};
use freebsd_capsicum_sys::{CapRights, Rights};
use freebsd_jail_sys::remove;
use freebsd_libcasper_sys::CapChannel;

use crate::catalogue::{CatalogueError, InterfaceCatalogue};
use crate::graph::{Connection, Graph};
use crate::manifest::{CapabilityKind, Manifest, RestartPolicy};
use crate::spawn::{Component, spawn_component};
use crate::spawnable::SpawnableSet;

/// The program to exec for a component — its binary and argument vector.
pub struct Program {
    /// The component binary.
    pub path: PathBuf,
    /// The argument vector after `argv[0]`.
    pub args: Vec<String>,
}

/// Why launching a [`Session`] failed.
#[derive(Debug)]
pub enum SessionError {
    /// A descriptor or process operation failed — creating or limiting a
    /// ring, spawning a component, registering it on the reactor.
    Io(io::Error),
    /// A connection's requested rights did not resolve against the
    /// interface catalogue — a malformed manifest set (§5.1).
    Rights(CatalogueError),
}

impl From<io::Error> for SessionError {
    fn from(err: io::Error) -> Self {
        SessionError::Io(err)
    }
}

impl From<CatalogueError> for SessionError {
    fn from(err: CatalogueError) -> Self {
        SessionError::Rights(err)
    }
}

impl fmt::Display for SessionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SessionError::Io(err) => write!(f, "launching a session: {err}"),
            SessionError::Rights(err) => write!(f, "launching a session: {err}"),
        }
    }
}

impl std::error::Error for SessionError {}

/// One component under the session: its name and its live process.
struct Live {
    name: String,
    component: Component,
}

/// What [`Session::step`] did with one component that exited (§5.5).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Exit {
    /// The component that exited.
    pub name: String,
    /// The exit status as from `wait(2)` — zero is a clean exit.
    pub status: i32,
    /// `true` if its restart policy re-wired and restarted it; `false` if
    /// the policy stopped it — it is no longer supervised.
    pub restarted: bool,
}

/// The broker's running session — one wired, spawned, supervised manifest
/// set (§5.2, §5.5).
///
/// [`Session::launch`] wires and spawns it; [`Session::step`] supervises it,
/// re-wiring and restarting any component that exits.
pub struct Session {
    /// The authority graph — kept so a restart can re-wire from it.
    graph: Graph,
    /// The interface catalogue — kept so a restart re-mints object rights.
    catalogue: InterfaceCatalogue,
    /// Each component's resolved program, so it can be respawned.
    programs: HashMap<String, Program>,
    /// The manifests a delegated spawn may name — read at boot, spawned
    /// only on a `SpawnChild` request (§5.6).
    spawnable: SpawnableSet,
    /// The broker's root channel to `casperd` — opened lazily on the
    /// first component that declares a `kind = casper` capability (§5.7),
    /// kept for the session's life so restart-casper and delegated-spawn
    /// casper reuse it. Dropping the `Session` `cap_close`s the root.
    casper_root: Option<CapChannel>,
    /// The reactor every component's process descriptor is watched on.
    reactor: Reactor,
    /// Every component, live, in graph order.
    components: Vec<Live>,
}

impl Session {
    /// Wire `graph`, spawn every component, and bring the session up
    /// supervised: each component's process descriptor is registered on a
    /// `kqueue` reactor, ready for [`step`](Self::step) to watch.
    ///
    /// `catalogue` resolves each connection's requested rights classes to
    /// the object-rights mask the broker mints for it (§3.3). `spawnable`
    /// is the set of manifests a delegated spawn may name later (§5.6);
    /// none of it is spawned now. `program` resolves a component name to
    /// the binary to exec; it is consulted once per component now and
    /// again on every restart.
    ///
    /// If a spawn fails, the components already spawned are torn down before
    /// the error is returned, so a failed launch leaves no jails behind.
    pub fn launch<F>(
        graph: Graph,
        catalogue: InterfaceCatalogue,
        spawnable: SpawnableSet,
        program: F,
    ) -> Result<Session, SessionError>
    where
        F: Fn(&str) -> Program,
    {
        let mut programs: HashMap<String, Program> = graph
            .components()
            .iter()
            .map(|manifest| (manifest.name.clone(), program(&manifest.name)))
            .collect();
        // A delegated spawn may name any spawnable manifest later (§5.6);
        // resolve each one's program now, so the resolver is not needed
        // past launch. A name shared with a boot component keeps the boot
        // entry.
        for name in spawnable.names() {
            programs
                .entry(name.to_owned())
                .or_insert_with(|| program(name));
        }
        let mut casper_root: Option<CapChannel> = None;
        let bundles = wire_bundles(&graph, &catalogue, &mut casper_root)?;
        let reactor = Reactor::new()?;

        let mut components: Vec<Live> = Vec::with_capacity(bundles.len());
        for (name, bundle) in bundles {
            let component = match spawn_bundle(&name, &programs[&name], &bundle) {
                Ok(component) => component,
                Err(err) => {
                    teardown(components);
                    return Err(err.into());
                }
            };
            if let Err(err) = reactor.register(component.descriptor(), Interest::ProcessExit) {
                let _ = component.shutdown();
                teardown(components);
                return Err(err.into());
            }
            components.push(Live { name, component });
        }

        Ok(Session {
            graph,
            catalogue,
            programs,
            spawnable,
            casper_root,
            reactor,
            components,
        })
    }

    /// The set of manifests a delegated spawn may name (§5.6).
    pub fn spawnable(&self) -> &SpawnableSet {
        &self.spawnable
    }

    /// The live process of a component, by name.
    pub fn component(&self, name: &str) -> Option<&Component> {
        self.components
            .iter()
            .find(|live| live.name == name)
            .map(|live| &live.component)
    }

    /// Every component, paired with its name, in graph order.
    pub fn components(&self) -> impl Iterator<Item = (&str, &Component)> {
        self.components
            .iter()
            .map(|live| (live.name.as_str(), &live.component))
    }

    /// Whether any component is still supervised. The session is over once
    /// this is false — every component has exited under a policy that did
    /// not restart it.
    pub fn is_empty(&self) -> bool {
        self.components.is_empty()
    }

    /// Wait for one or more components to exit and act on each per its
    /// restart policy (§5.5), returning what was done. Blocks until at
    /// least one exits; control requests that arrive meanwhile (§5.6) are
    /// answered along the way.
    ///
    /// A component whose policy restarts it is re-wired and respawned —
    /// see [`handle_exit`](Self::handle_exit); one whose policy does not is
    /// stopped, its jail reclaimed and its peers' rings left closed.
    pub fn step(&mut self) -> io::Result<Vec<Exit>> {
        if self.components.is_empty() {
            return Ok(Vec::new());
        }
        loop {
            // Watch every component's control connection for an incoming
            // request, alongside the process descriptors (§5.6). A
            // readiness registration is one-shot, so it is renewed here on
            // each wait; a process descriptor, registered once, is not.
            for live in &self.components {
                self.reactor
                    .register(live.component.bootstrap().as_fd(), Interest::Readable)?;
            }
            let events = self.reactor.wait(None)?;

            let mut readable: Vec<RawFd> = Vec::new();
            let mut exited: Vec<(RawFd, i32)> = Vec::new();
            for event in events {
                match event {
                    Event::Readable(fd) => readable.push(fd),
                    Event::ProcessExited { fd, status } => exited.push((fd, status)),
                    _ => {}
                }
            }

            // Answer control requests first: every `fd` here was just
            // reported readable and no component has been restarted since,
            // so a receive on it does not block.
            for fd in readable {
                self.handle_control(fd)?;
            }
            if exited.is_empty() {
                // Only control traffic, or a bare wake — keep waiting for
                // an exit to report.
                continue;
            }
            let mut exits = Vec::with_capacity(exited.len());
            for (fd, status) in exited {
                exits.push(self.handle_exit(fd, status)?);
            }
            return Ok(exits);
        }
    }

    /// Act on the exit of the component whose process descriptor is
    /// `pd_fd`, which exited with `status` (§5.5).
    ///
    /// Its manifest's restart policy decides: `always` restarts it,
    /// `on-failure` restarts it only on a non-zero `status`, `never` never.
    /// A restart re-creates a fresh ring for every connection the component
    /// touched, respawns it holding its ends, and sends each surviving peer
    /// a [`PeerRestarted`] over that peer's control channel. A component
    /// that is *not* restarted is stopped: its jail is reclaimed and it is
    /// dropped from the session, and its peers' rings stay closed.
    fn handle_exit(&mut self, pd_fd: RawFd, status: i32) -> io::Result<Exit> {
        let idx = self
            .components
            .iter()
            .position(|live| live.component.descriptor().as_raw_fd() == pd_fd)
            .ok_or_else(|| io::Error::other("process-exit event for an unknown component"))?;
        let name = self.components[idx].name.clone();

        // The component's restart policy, from its manifest (§5.5). A
        // non-zero exit status is a failure — a non-zero exit code or a
        // signal.
        let policy = self
            .graph
            .component(&name)
            .map_or(RestartPolicy::Always, |manifest| manifest.restart);
        let restart = match policy {
            RestartPolicy::Always => true,
            RestartPolicy::OnFailure => status != 0,
            RestartPolicy::Never => false,
        };

        if !restart {
            // Stop: reclaim the jail and drop the component. Its peers'
            // rings are left closed — they are not re-wired (§5.5).
            let stopped = self.components.remove(idx);
            remove(stopped.component.jid())?;
            return Ok(Exit {
                name,
                status,
                restarted: false,
            });
        }

        // Re-wire: fresh rings for every connection the dead component
        // touched. Its own ends go into a fresh bundle; each peer's end
        // travels to it in a `PeerRestarted`. The catalogue resolved every
        // one of these connections at launch, so a failure here is a
        // descriptor error, not a malformed manifest.
        let (mut bundle, peer_grants) = rewire(&self.graph, &self.catalogue, &name)
            .map_err(|err| io::Error::other(err.to_string()))?;

        // The restarted component's Casper channels are minted afresh too
        // (§5.7) — the old ones closed when its process died.
        let manifest = self
            .graph
            .component(&name)
            .expect("a restarted component is in the graph");
        bundle.casper_channels = open_casper_channels_for(manifest, &mut self.casper_root)?;

        // Reclaim the dead component's jail — the replacement reuses its
        // name — then respawn it into the fresh bundle and re-watch it.
        remove(self.components[idx].component.jid())?;
        let fresh = spawn_bundle(&name, &self.programs[&name], &bundle)?;
        self.reactor
            .register(fresh.descriptor(), Interest::ProcessExit)?;
        self.components[idx].component = fresh;

        // Tell every surviving peer where its re-wired ring now leads. A
        // peer that is itself awaiting restart is skipped — its own restart
        // will re-wire this connection from the other side.
        for (peer, grant) in peer_grants {
            if let Some(live) = self.components.iter().find(|live| live.name == peer) {
                send_peer_restarted(live.component.bootstrap(), grant)?;
            }
        }
        Ok(Exit {
            name,
            status,
            restarted: true,
        })
    }

    /// Handle a control connection that became readable: receive the
    /// component's request and answer it (§5.6).
    ///
    /// `fd` is a control channel the reactor reported readable, so the
    /// receive does not block — it yields a datagram, or end-of-file as
    /// the component winds down. The only request defined is [`SpawnChild`];
    /// a datagram from a since-departed component, or one that is not a
    /// recognised request, is dropped. The reply travels back on the same
    /// control connection.
    fn handle_control(&mut self, fd: RawFd) -> io::Result<()> {
        let Some(idx) = self
            .components
            .iter()
            .position(|live| live.component.bootstrap().as_fd().as_raw_fd() == fd)
        else {
            // A readable event for a control channel no live component
            // owns — a component that has since departed.
            return Ok(());
        };
        let requester = self.components[idx].name.clone();

        let (envelope, handles) = match self.components[idx].component.bootstrap().recv() {
            Ok(message) => message,
            // End-of-file, or a malformed datagram — the component is
            // winding down; there is nothing to answer.
            Err(_) => return Ok(()),
        };
        let Ok(request) = envelope.into_message::<SpawnChild>(handles) else {
            // Not a request the broker understands — drop it.
            return Ok(());
        };

        let reply = self.try_spawn_child(&requester, request);

        // Send the reply on the same control connection. After
        // `try_spawn_child`, `idx` may no longer be valid (a successful
        // spawn pushes a new component), so the requester is found again
        // by name — its `Live` was not removed.
        let channel = self
            .components
            .iter()
            .find(|live| live.name == requester)
            .map(|live| live.component.bootstrap());
        let Some(channel) = channel else {
            return Ok(());
        };
        let (reply_envelope, fds) = Envelope::from_message(control_header(), &reply);
        let borrowed: Vec<BorrowedFd<'_>> = fds.iter().map(AsFd::as_fd).collect();
        channel.send(&reply_envelope, &borrowed)
    }

    /// Carry out a [`SpawnChild`] request, mutating the session only if
    /// every check and the spawn itself succeed (§5.6).
    ///
    /// On any failure, returns a [`SpawnReply::Refused`] naming the reason
    /// and leaves the session as it was. On success, the child has joined
    /// the authority graph, been spawned, and every live peer has been
    /// notified by [`PeerRestarted`] — and the reply is [`SpawnReply::Spawned`].
    fn try_spawn_child(&mut self, requester: &str, request: SpawnChild) -> SpawnReply {
        // The requester must declare `kind = spawn`: only then may it ask
        // the broker for a child (§5.6).
        let permitted = self
            .graph
            .component(requester)
            .map(|manifest| {
                manifest
                    .capabilities
                    .iter()
                    .any(|cap| cap.kind == CapabilityKind::Spawn)
            })
            .unwrap_or(false);
        if !permitted {
            return SpawnReply::Refused(format!("`{requester}` holds no `spawn` capability",));
        }

        // The named manifest must be in the spawnable set.
        let Some(child_manifest) = self.spawnable.get(&request.manifest).cloned() else {
            return SpawnReply::Refused(format!(
                "no spawnable manifest named `{}`",
                request.manifest,
            ));
        };
        let child_name = child_manifest.name.clone();

        // The child's name must not collide with a component already in
        // the session.
        if self.graph.component(&child_name).is_some() {
            return SpawnReply::Refused(format!(
                "a component named `{child_name}` is already in the session",
            ));
        }

        // Resolve the child's connections against the running graph — does
        // every peer interface exist? — non-mutating.
        let connections = match self.graph.connections_for(&child_manifest) {
            Ok(connections) => connections,
            Err(err) => {
                return SpawnReply::Refused(format!(
                    "the child's authority does not resolve: {err}",
                ));
            }
        };

        // Wire those connections — fresh rings, the child's ends in a
        // bundle, peers' ends as grants. Still no mutation of the session.
        let (mut bundle, peer_grants) =
            match wire_connections(&self.catalogue, connections.iter(), &child_name) {
                Ok(wired) => wired,
                Err(err) => {
                    return SpawnReply::Refused(format!(
                        "could not wire the child's connections: {err}",
                    ));
                }
            };

        // Open the child's Casper channels too (§5.7) — minted afresh on
        // every spawn, like its rings.
        bundle.casper_channels =
            match open_casper_channels_for(&child_manifest, &mut self.casper_root) {
                Ok(channels) => channels,
                Err(err) => {
                    return SpawnReply::Refused(format!(
                        "could not open the child's Casper channels: {err}",
                    ));
                }
            };

        // Last fallible step before mutation: the spawn itself.
        let Some(program) = self.programs.get(&child_name) else {
            return SpawnReply::Refused(format!("no program resolved for `{child_name}`",));
        };
        let component = match spawn_bundle(&child_name, program, &bundle) {
            Ok(component) => component,
            Err(err) => {
                return SpawnReply::Refused(format!("could not spawn the child: {err}",));
            }
        };

        // The session mutates from here on. Watch the child for exit,
        // record it in the graph and supervised set, then notify every
        // live peer that its ring now leads to a freshly delegated child —
        // the §5.5 `PeerRestarted` mechanism, reused.
        if let Err(err) = self
            .reactor
            .register(component.descriptor(), Interest::ProcessExit)
        {
            // The broker's own reactor failed — the child is up but
            // unsupervised; tearing it down here keeps the session
            // consistent. The graph has not yet been mutated.
            let _ = component.shutdown();
            return SpawnReply::Refused(format!(
                "could not watch the child's process descriptor: {err}",
            ));
        }
        if let Err(err) = self.graph.add(child_manifest) {
            // `connections_for` already validated the same thing, so this
            // is effectively unreachable; report it cleanly if it happens.
            let _ = component.shutdown();
            return SpawnReply::Refused(format!("the child's graph add failed: {err}",));
        }
        self.components.push(Live {
            name: child_name,
            component,
        });

        for (peer, grant) in peer_grants {
            if let Some(live) = self.components.iter().find(|live| live.name == peer) {
                // A failed peer-notify leaves that one connection dangling
                // — the child is up; the broker stays up.
                let _ = send_peer_restarted(live.component.bootstrap(), grant);
            }
        }

        SpawnReply::Spawned
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // Tear down every component's jail, which kills the process.
        for live in &self.components {
            let _ = remove(live.component.jid());
        }
    }
}

/// Pre-wire `graph`: create a `SOCK_SEQPACKET` ring for every connection and
/// assemble each component's bundle, in graph component order. No process is
/// spawned — every ring is created here, before any component is.
///
/// `catalogue` resolves each connection's requested rights classes to the
/// object-rights mask the broker mints for it (§3.3).
fn wire_bundles(
    graph: &Graph,
    catalogue: &InterfaceCatalogue,
    casper_root: &mut Option<CapChannel>,
) -> Result<Vec<(String, Bundle)>, SessionError> {
    // The §3.3 kernel mask every service ring carries, built once and
    // applied to each ring descriptor before it enters a bundle.
    let ring_rights = CapRights::new(service_ring_rights());
    let cap_rights = ring_cap_rights(&ring_rights);

    // Seed every component with a grant list — one with no connections
    // still gets a bundle, an empty one.
    let mut grants: HashMap<String, Vec<Grant>> = graph
        .components()
        .iter()
        .map(|manifest| (manifest.name.clone(), Vec::new()))
        .collect();

    // One ring per connection: the requester holds the client end, the
    // provider the server end (§5.2).
    for connection in graph.connections() {
        // The object-rights mask the broker mints for this connection — the
        // requester's rights tokens resolved against the provider
        // interface's catalogue (§3.3). Both ends carry it.
        let object_rights = catalogue.resolve(&connection.interface, &connection.rights)?;
        let body = CapBody {
            cap_rights,
            object_rights,
        };
        let (client_end, server_end) = Channel::pair()?;
        grants
            .get_mut(&connection.requester)
            .expect("a connection names only components in the graph")
            .push(make_grant(
                &connection.interface,
                Role::Client,
                client_end,
                &ring_rights,
                body,
            )?);
        grants
            .get_mut(&connection.provider)
            .expect("a connection names only components in the graph")
            .push(make_grant(
                &connection.interface,
                Role::Server,
                server_end,
                &ring_rights,
                body,
            )?);
    }

    // Assemble the bundles in graph component order, opening each
    // component's Casper service channels per its `kind = casper`
    // capabilities (§5.7). Lazy: `cap_init` only runs the first time
    // some manifest holds at least one such capability.
    let mut bundles: Vec<(String, Bundle)> = Vec::with_capacity(graph.components().len());
    for manifest in graph.components() {
        let grants = grants
            .remove(&manifest.name)
            .expect("every component was seeded with a grant list");
        let casper_channels = open_casper_channels_for(manifest, casper_root)?;
        bundles.push((
            manifest.name.clone(),
            Bundle {
                grants,
                casper_channels,
            },
        ));
    }
    Ok(bundles)
}

/// Open one component's Casper service channels (§5.7), per its
/// manifest's `kind = casper` capabilities — empty for a manifest with
/// none, and (the common path) cheap when `casper_root` is already open.
///
/// `casper_root` is the broker's root channel to `casperd`, lazily
/// opened on first use — a session with no Casper-using component never
/// forks the helper. Each per-service channel is opened from the root;
/// its underlying fd is duplicated into a [`CasperChannel`] for the
/// bundle, and the broker's own `CapChannel` is dropped (closing the
/// broker's reference) — the kernel has the dup for `SCM_RIGHTS`.
///
/// Used at launch (`wire_bundles`), at restart (`handle_exit`), and at
/// delegated spawn (`try_spawn_child`): a component's Casper channels
/// are minted afresh on every spawn, like its rings.
fn open_casper_channels_for(
    manifest: &Manifest,
    casper_root: &mut Option<CapChannel>,
) -> io::Result<Vec<CasperChannel>> {
    let services: Vec<&str> = manifest
        .capabilities
        .iter()
        .filter(|cap| cap.kind == CapabilityKind::Casper)
        .map(|cap| cap.target.as_str())
        .collect();
    if services.is_empty() {
        return Ok(Vec::new());
    }
    if casper_root.is_none() {
        *casper_root = Some(CapChannel::root()?);
    }
    let root = casper_root.as_ref().expect("just opened");

    let mut channels = Vec::with_capacity(services.len());
    for service in services {
        let service_chan = root.open_service(service)?;
        // The `CasperChannel` owns its own dup of the fd; the broker
        // drops the `CapChannel` next, closing its reference.
        let channel = service_chan.as_fd().try_clone_to_owned()?;
        channels.push(CasperChannel {
            service: service.to_owned(),
            channel,
        });
    }
    Ok(channels)
}

/// Re-wire one restarted component: a fresh ring per connection it touches.
///
/// Returns the dead component's fresh [`Bundle`] — its end of every ring —
/// and, per connection, the surviving peer's name with the [`Grant`] for the
/// peer's fresh end, to be delivered to that peer as a [`PeerRestarted`].
fn rewire(
    graph: &Graph,
    catalogue: &InterfaceCatalogue,
    component: &str,
) -> Result<(Bundle, Vec<(String, Grant)>), SessionError> {
    wire_connections(catalogue, graph.connections_of(component), component)
}

/// Wire a list of connections for one component: a fresh ring per
/// connection, the component's ends in a [`Bundle`] and each peer's end as
/// a [`Grant`] paired with that peer's name.
///
/// This is the shared core of [`rewire`] (a restarted component's
/// `connections_of`) and the §5.6 delegated-spawn handler (a delegated
/// child's `connections_for`).
fn wire_connections<'c>(
    catalogue: &InterfaceCatalogue,
    connections: impl Iterator<Item = &'c Connection>,
    component: &str,
) -> Result<(Bundle, Vec<(String, Grant)>), SessionError> {
    let ring_rights = CapRights::new(service_ring_rights());
    let cap_rights = ring_cap_rights(&ring_rights);

    let mut own_grants: Vec<Grant> = Vec::new();
    let mut peer_grants: Vec<(String, Grant)> = Vec::new();

    for connection in connections {
        let object_rights = catalogue.resolve(&connection.interface, &connection.rights)?;
        let body = CapBody {
            cap_rights,
            object_rights,
        };
        let (client_end, server_end) = Channel::pair()?;

        // The wired component is one end of the connection; the peer is
        // the other. The requester holds the client end, the provider the
        // server end — exactly as at first wiring (§5.2).
        let (own_role, own_end, peer_name, peer_role, peer_end) =
            if connection.requester == component {
                (
                    Role::Client,
                    client_end,
                    &connection.provider,
                    Role::Server,
                    server_end,
                )
            } else {
                (
                    Role::Server,
                    server_end,
                    &connection.requester,
                    Role::Client,
                    client_end,
                )
            };

        own_grants.push(make_grant(
            &connection.interface,
            own_role,
            own_end,
            &ring_rights,
            body,
        )?);
        peer_grants.push((
            peer_name.clone(),
            make_grant(
                &connection.interface,
                peer_role,
                peer_end,
                &ring_rights,
                body,
            )?,
        ));
    }

    Ok((
        Bundle {
            grants: own_grants,
            casper_channels: Vec::new(),
        },
        peer_grants,
    ))
}

/// Build one ring-endpoint [`Grant`], limiting the descriptor to its §3.3
/// kernel rights first; a duplicate the bundle later passes inherits the
/// limit.
fn make_grant(
    interface: &str,
    role: Role,
    endpoint: Channel,
    ring_rights: &CapRights,
    body: CapBody,
) -> io::Result<Grant> {
    let endpoint = endpoint.into_fd();
    ring_rights.limit(endpoint.as_raw_fd())?;
    Ok(Grant {
        interface: interface.to_owned(),
        role,
        rights: body,
        endpoint,
    })
}

/// Spawn `program` as the component `name`, holding `bundle` as its
/// bootstrap bundle.
fn spawn_bundle(name: &str, program: &Program, bundle: &Bundle) -> io::Result<Component> {
    // `from_message` duplicates each grant's endpoint onto the handle table;
    // `fds` are those duplicates, sent via `SCM_RIGHTS` and dropped once the
    // datagram is away.
    let (envelope, fds) = Envelope::from_message(bundle_header(), bundle);
    let borrowed: Vec<BorrowedFd<'_>> = fds.iter().map(AsFd::as_fd).collect();
    let args: Vec<&str> = program.args.iter().map(String::as_str).collect();
    spawn_component(name, &program.path, &args, &envelope, &borrowed)
}

/// Send a [`PeerRestarted`] to a surviving peer over its control channel —
/// the same channel its bootstrap bundle arrived on (§5.5).
fn send_peer_restarted(channel: &MessageChannel, grant: Grant) -> io::Result<()> {
    let message = PeerRestarted { grant };
    let (envelope, fds) = Envelope::from_message(control_header(), &message);
    let borrowed: Vec<BorrowedFd<'_>> = fds.iter().map(AsFd::as_fd).collect();
    channel.send(&envelope, &borrowed)
}

/// Tear down a partially launched session — remove every component's jail,
/// which kills the process.
fn teardown(components: Vec<Live>) {
    for live in components {
        let _ = live.component.shutdown();
    }
}

/// The §3.3 kernel rights a service-ring socket carries: send and receive,
/// `kqueue` readiness, and `fcntl` (the async transport sets the ring
/// non-blocking).
fn service_ring_rights() -> Rights {
    Rights::SEND
        .with(Rights::RECV)
        .with(Rights::EVENT)
        .with(Rights::FCNTL)
        .with(Rights::FSTAT)
}

/// The §3.2 `cap_rights` bytes a service-ring grant records — the kernel
/// mask `ring` was built from. A grant's `CapBody` pairs these with the
/// connection's object-rights mask (§3.3).
fn ring_cap_rights(ring: &CapRights) -> [u8; 16] {
    let bytes = ring.as_bytes();
    let mut cap_rights = [0u8; 16];
    assert_eq!(
        bytes.len(),
        cap_rights.len(),
        "a cap_rights_t is 16 bytes (broker-and-transport.md §3.2)",
    );
    cap_rights.copy_from_slice(bytes);
    cap_rights
}

/// The header of a bootstrap-bundle envelope. The bundle rides on no
/// interface ring, so its interface id is zero; method id 0 marks it the
/// initial bundle (§5.3).
fn bundle_header() -> Header {
    Header {
        kind: MessageKind::Event,
        interface_id: 0,
        method_id: 0,
    }
}

/// The header of a `PeerRestarted` control envelope. It rides the same
/// control connection the bundle arrived on; method id 1 marks it a
/// post-boot re-wire rather than the initial bundle (§5.5).
fn control_header() -> Header {
    Header {
        kind: MessageKind::Event,
        interface_id: 0,
        method_id: 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;

    /// A complete, valid manifest with the given name, interface, and an
    /// optional run of `[capability]` blocks spliced in — restart policy
    /// `always`.
    fn manifest(name: &str, interface: &str, caps: &str) -> Manifest {
        manifest_with_policy(name, interface, caps, "always")
    }

    /// As [`manifest`], with a chosen restart policy.
    fn manifest_with_policy(name: &str, interface: &str, caps: &str, policy: &str) -> Manifest {
        let text = format!(
            "name = {name}\ninterface = {interface}\nversion = 1\n{caps}\
             [jail]\nroot = /\nnetwork = none\nuser = _{name}\n\
             [budget]\nmemory = 1M\nfds = 8\n[restart]\npolicy = {policy}\n",
        );
        Manifest::parse(&text).expect("the test manifest parses")
    }

    fn peer(interface: &str) -> String {
        format!("[capability]\nkind = peer\ninterface = {interface}\nrights = recv\n")
    }

    /// The single bundle of the component named `name`.
    fn bundle_of<'b>(bundles: &'b [(String, Bundle)], name: &str) -> &'b Bundle {
        &bundles
            .iter()
            .find(|(component, _)| component == name)
            .expect("the component is in the wiring")
            .1
    }

    #[test]
    fn wire_assembles_a_bundle_per_component() {
        // compositor → input is one connection; `log` peers no one.
        let graph = Graph::build(vec![
            manifest("compositor", "display", &peer("input")),
            manifest("input", "input", ""),
            manifest("log", "log", ""),
        ])
        .expect("the graph builds");

        // `input`'s rights classes — the `peer` capability asks for `recv`.
        let mut catalogue = InterfaceCatalogue::new();
        catalogue.register("input", &[("recv", 0b01), ("send", 0b10)]);

        let bundles = wire_bundles(&graph, &catalogue, &mut None).expect("the session wires");
        assert_eq!(bundles.len(), 3);

        // The requester holds the client end of the ring …
        let compositor = bundle_of(&bundles, "compositor");
        assert_eq!(compositor.grants.len(), 1);
        assert_eq!(compositor.grants[0].interface, "input");
        assert_eq!(compositor.grants[0].role, Role::Client);

        // … the provider the server end.
        let input = bundle_of(&bundles, "input");
        assert_eq!(input.grants.len(), 1);
        assert_eq!(input.grants[0].interface, "input");
        assert_eq!(input.grants[0].role, Role::Server);

        // Both ends carry the minted §3.3 kernel mask — not the zero body.
        assert_ne!(compositor.grants[0].rights.cap_rights, [0u8; 16]);
        assert_eq!(
            compositor.grants[0].rights.cap_rights, input.grants[0].rights.cap_rights,
            "both ends of a ring carry the same service-ring mask",
        );

        // And the object-rights mask the catalogue resolved `recv` to —
        // the same on both ends of the connection.
        assert_eq!(compositor.grants[0].rights.object_rights, 0b01);
        assert_eq!(input.grants[0].rights.object_rights, 0b01);

        // A component that peers no one is wired an empty bundle.
        assert!(bundle_of(&bundles, "log").grants.is_empty());
    }

    #[test]
    fn an_empty_manifest_set_wires_to_nothing() {
        let graph = Graph::build(vec![]).expect("graph");
        let bundles = wire_bundles(&graph, &InterfaceCatalogue::new(), &mut None).expect("wire");
        assert!(bundles.is_empty());
    }

    #[test]
    fn an_unknown_rights_class_fails_the_wiring() {
        // The manifest asks for `recv`, but the catalogue's `input` has no
        // such class — a malformed manifest set (§5.1).
        let graph = Graph::build(vec![
            manifest("compositor", "display", &peer("input")),
            manifest("input", "input", ""),
        ])
        .expect("the graph builds");

        let mut catalogue = InterfaceCatalogue::new();
        catalogue.register("input", &[("send", 0b10)]);

        match wire_bundles(&graph, &catalogue, &mut None) {
            Err(SessionError::Rights(CatalogueError::UnknownRightsClass { class, .. })) => {
                assert_eq!(class, "recv");
            }
            Err(other) => panic!("expected an unknown-rights-class error, got {other:?}"),
            Ok(_) => panic!("expected the wiring to fail"),
        }
    }

    #[test]
    fn rewire_freshens_one_components_rings() {
        // compositor → input: input is the provider, compositor the peer.
        let graph = Graph::build(vec![
            manifest("compositor", "display", &peer("input")),
            manifest("input", "input", ""),
        ])
        .expect("the graph builds");

        let mut catalogue = InterfaceCatalogue::new();
        catalogue.register("input", &[("recv", 0b01)]);

        // Re-wire `input`: it provides one interface, so its fresh bundle
        // holds one server-end grant, and its one peer — compositor, the
        // requester — is to be sent the matching client end.
        let (bundle, peers) = rewire(&graph, &catalogue, "input").expect("input re-wires");
        assert_eq!(bundle.grants.len(), 1);
        assert_eq!(bundle.grants[0].interface, "input");
        assert_eq!(bundle.grants[0].role, Role::Server);
        assert_eq!(bundle.grants[0].rights.object_rights, 0b01);

        assert_eq!(peers.len(), 1);
        assert_eq!(peers[0].0, "compositor");
        assert_eq!(peers[0].1.interface, "input");
        assert_eq!(peers[0].1.role, Role::Client);
        assert_eq!(peers[0].1.rights.object_rights, 0b01);

        // Re-wiring the requester is the mirror image: a client-end grant
        // for itself, the server end to be sent to the provider.
        let (bundle, peers) =
            rewire(&graph, &catalogue, "compositor").expect("compositor re-wires");
        assert_eq!(bundle.grants[0].role, Role::Client);
        assert_eq!(peers[0].0, "input");
        assert_eq!(peers[0].1.role, Role::Server);
    }

    #[test]
    fn rewire_a_component_with_no_peers_is_empty() {
        let graph = Graph::build(vec![manifest("lonely", "lonely", "")]).expect("the graph builds");
        let (bundle, peers) = rewire(&graph, &InterfaceCatalogue::new(), "lonely")
            .expect("a lone component re-wires");
        assert!(bundle.grants.is_empty());
        assert!(peers.is_empty());
    }

    #[test]
    fn a_failed_component_is_re_wired_and_restarted() {
        let pid = std::process::id();
        let caller = format!("rw-caller-{pid}");
        let callee = format!("rw-callee-{pid}");

        // caller → callee is one connection. /bin/sh ignores its bootstrap
        // fd: this test exercises the broker's re-wire, not the component
        // side, so a successful `step` proves the re-wire and the
        // `PeerRestarted` send to the live caller both went through.
        let graph = Graph::build(vec![
            manifest(&caller, "rw-caller-iface", &peer("rw-callee-iface")),
            manifest(&callee, "rw-callee-iface", ""),
        ])
        .expect("the graph builds");

        let mut catalogue = InterfaceCatalogue::new();
        catalogue.register("rw-callee-iface", &[("recv", 1)]);

        // The callee lives just long enough to be registered, then exits;
        // the caller lingers so it is a live peer to be re-wired.
        let callee_name = callee.clone();
        let mut session = Session::launch(graph, catalogue, SpawnableSet::new(), |name| {
            let script = if name == callee_name {
                "sleep 0.3"
            } else {
                "sleep 30"
            };
            Program {
                path: PathBuf::from("/bin/sh"),
                args: vec!["-c".to_owned(), script.to_owned()],
            }
        })
        .expect("the session launches");

        let callee_first = session.component(&callee).expect("callee is live").pid();
        let caller_first = session.component(&caller).expect("caller is live").pid();

        let restarted = session.step().expect("supervise one exit");
        assert_eq!(
            restarted,
            vec![Exit {
                name: callee.clone(),
                status: 0,
                restarted: true,
            }],
        );

        let callee_second = session
            .component(&callee)
            .expect("callee is live again")
            .pid();
        let caller_second = session
            .component(&caller)
            .expect("caller is still live")
            .pid();

        assert_ne!(
            callee_first, callee_second,
            "the callee was restarted as a fresh process",
        );
        assert_eq!(
            caller_first, caller_second,
            "the caller, a surviving peer, was not restarted",
        );
    }

    /// A single-component session whose one component runs `script` under
    /// `policy`, stepped once — the exit, and whether the component is
    /// still supervised after it.
    fn step_one_under_policy(tag: &str, policy: &str, script: &'static str) -> (Exit, bool) {
        let name = format!("rp-{tag}-{}", std::process::id());
        let graph = Graph::build(vec![manifest_with_policy(
            &name,
            &format!("rp-{tag}-iface"),
            "",
            policy,
        )])
        .expect("the graph builds");

        let mut session = Session::launch(
            graph,
            InterfaceCatalogue::new(),
            SpawnableSet::new(),
            |_name| Program {
                path: PathBuf::from("/bin/sh"),
                args: vec!["-c".to_owned(), script.to_owned()],
            },
        )
        .expect("the session launches");

        let exits = session.step().expect("supervise one exit");
        assert_eq!(exits.len(), 1, "one component, one exit");
        let supervised = session.component(&name).is_some();
        (exits.into_iter().next().unwrap(), supervised)
    }

    #[test]
    fn a_never_policy_component_is_not_restarted() {
        // `never`: the component exits cleanly and is left stopped.
        let (exit, supervised) = step_one_under_policy("never", "never", "sleep 0.3");
        assert!(!exit.restarted, "a `never` component is not restarted");
        assert!(
            !supervised,
            "a stopped component is dropped from the session"
        );
    }

    #[test]
    fn an_on_failure_component_restarts_on_a_crash() {
        // `on-failure`: a non-zero exit is a failure — restart it.
        let (exit, supervised) = step_one_under_policy("crash", "on-failure", "sleep 0.3; exit 1");
        assert!(exit.restarted, "on-failure restarts a crashed component");
        assert!(supervised, "the restarted component is supervised again");
    }

    #[test]
    fn an_on_failure_component_is_left_stopped_on_a_clean_exit() {
        // `on-failure`: a clean exit is not a failure — do not restart.
        let (exit, supervised) = step_one_under_policy("clean", "on-failure", "sleep 0.3");
        assert!(!exit.restarted, "on-failure does not restart a clean exit",);
        assert!(!supervised, "the component is left stopped");
    }
}
