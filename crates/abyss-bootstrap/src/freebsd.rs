// SPDX-License-Identifier: BSD-2-Clause

//! The component bootstrap shim — compiled only on FreeBSD.
//!
//! [`enter`] receives the bootstrap bundle and confines the process;
//! [`Control`] then keeps the same channel as a control connection and
//! re-wires the component's durable capabilities when a peer restarts
//! (`broker-and-transport.md` §5.5).

use std::collections::HashMap;
use std::io;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::sync::Arc;

use abyss_bundle::{Bundle, CasperChannel, Grant, PeerRestarted, Role};
use abyss_cap::{Cap, DurableCap, Interface, Rights, durable, unbound_ipc_cap};
use abyss_looper::{Receiver, Spawner, channel};
use abyss_msg::{Method, Wire};
use abyss_transport::{AsyncMessageChannel, Channel, MessageChannel, ReactorSource};

/// The descriptor a component is spawned holding — its bootstrap socket
/// (`broker-and-transport.md` §5.3). Matches `ABYSS_BOOTSTRAP_FD` in the
/// `freebsd-procdesc-sys` spawn shim.
const BOOTSTRAP_FD: RawFd = 3;

/// What [`enter`] hands the component once it is bootstrapped.
pub struct Startup {
    /// The capability grants the broker delivered (`broker-and-transport.md`
    /// §5.8) — claimed by [`take_client_cap`](Self::take_client_cap).
    bundle: Bundle,
    /// The channel back to the broker, kept for the rest of the component's
    /// life.
    pub bootstrap: MessageChannel,
}

impl Startup {
    /// The capability grants still unclaimed in the bundle.
    pub fn grants(&self) -> &[Grant] {
        &self.bundle.grants
    }

    /// Claim the client capability for `interface` as an unbound
    /// [`Cap<I, R>`].
    ///
    /// A bundle grant is move-only (`DESIGN.md` §6.10): the grant is
    /// removed from the bundle, so it is claimed exactly once. The `Cap`
    /// is *unbound* — the framework binds it to a looper before a handler
    /// uses it (`broker-and-transport.md` §3.5). `None` if no `client`
    /// grant names `interface`.
    pub fn take_client_cap<I, R>(&mut self, interface: &str) -> Option<Cap<I, R>>
    where
        I: Interface,
        R: Rights,
    {
        let index = self
            .bundle
            .grants
            .iter()
            .position(|grant| grant.role == Role::Client && grant.interface == interface)?;
        let grant = self.bundle.grants.remove(index);
        Some(unbound_ipc_cap(grant.endpoint, grant.rights))
    }

    /// Claim the server endpoint for `interface` — the `Role::Server`
    /// grant, the service side of a ring.
    ///
    /// Returned as the raw [`Grant`]: its `endpoint` descriptor is the
    /// service end the component drives a `Connection` over. As with
    /// [`take_client_cap`](Self::take_client_cap), the grant is removed
    /// from the bundle, so it is claimed exactly once.
    pub fn take_server_grant(&mut self, interface: &str) -> Option<Grant> {
        let index = self
            .bundle
            .grants
            .iter()
            .position(|grant| grant.role == Role::Server && grant.interface == interface)?;
        Some(self.bundle.grants.remove(index))
    }

    /// The Casper service channels the broker opened for this component
    /// (`broker-and-transport.md` §5.7), still unclaimed.
    pub fn casper_channels(&self) -> &[CasperChannel] {
        &self.bundle.casper_channels
    }

    /// Claim the [`CasperChannel`] for `service` (§5.7) — its fd is the
    /// `cap_channel_t`'s underlying socket; libcasper's `cap_wrap` lifts
    /// it back into a `cap_channel_t` for the per-service client API.
    ///
    /// The channel is removed from the bundle, so it is claimed exactly
    /// once; `None` if no channel for `service` is left.
    pub fn take_casper_channel(&mut self, service: &str) -> Option<CasperChannel> {
        let index = self
            .bundle
            .casper_channels
            .iter()
            .position(|ch| ch.service == service)?;
        Some(self.bundle.casper_channels.remove(index))
    }
}

/// Run the component startup shim: receive the bootstrap bundle, then enter
/// Capsicum capability mode (`broker-and-transport.md` §5.4).
///
/// Every component calls this once, before anything else. After it returns
/// the process is confined — it can open no new path, address, or socket;
/// it acts only through the capabilities the bundle delivered.
pub fn enter() -> io::Result<Startup> {
    // The broker spawned us holding the bootstrap socket at fd 3.
    // SAFETY: by the spawn contract (§5.3) fd 3 is this process's bootstrap
    // socket and nothing else holds it; ownership is taken exactly once,
    // here, at the single entry point every component passes through.
    let fd = unsafe { OwnedFd::from_raw_fd(BOOTSTRAP_FD) };
    let bootstrap = MessageChannel::new(Channel::from_fd(fd));

    let (envelope, handles) = bootstrap.recv()?;
    freebsd_capsicum_sys::cap_enter()?;

    // Decode the bundle off the received envelope and its descriptors
    // (§5.8). A malformed bundle is a fatal bootstrap fault.
    let bundle = envelope.into_message::<Bundle>(handles).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("malformed bootstrap bundle: {err}"),
        )
    })?;

    Ok(Startup { bundle, bootstrap })
}

/// The component's control loop — watching the bootstrap channel for
/// post-boot control messages (`broker-and-transport.md` §5.5).
///
/// Once [`enter`] has taken the bundle off it, the bootstrap channel
/// becomes a *control connection*: the broker sends a [`PeerRestarted`]
/// over it whenever one of the component's peers is re-wired. `Control`
/// watches for those and repoints the affected [`DurableCap`] at the fresh
/// ring, so a `call` made after a restart travels it transparently.
pub struct Control {
    channel: AsyncMessageChannel,
    /// One rewire handler per interface, invoked with the fresh [`Grant`]
    /// when a [`PeerRestarted`] for that interface arrives.
    rewires: HashMap<String, Box<dyn FnMut(Grant) + Send>>,
}

impl Control {
    /// Begin watching `bootstrap` — the channel [`enter`] received the
    /// bundle on — for control messages. `source` is the event source of
    /// the looper the control loop will run on.
    pub fn watch(bootstrap: MessageChannel, source: Arc<ReactorSource>) -> io::Result<Control> {
        Ok(Control {
            channel: AsyncMessageChannel::new(bootstrap, source)?,
            rewires: HashMap::new(),
        })
    }

    /// Register a rewire handler for `interface`: `handler` is called with
    /// the fresh [`Grant`] each time a [`PeerRestarted`] for that interface
    /// arrives. [`durable_cap`](Self::durable_cap) is the usual way to set
    /// one up.
    pub fn on_rewire(&mut self, interface: &str, handler: impl FnMut(Grant) + Send + 'static) {
        self.rewires.insert(interface.to_owned(), Box::new(handler));
    }

    /// Make `cap` — an already-bound client capability for `interface` — a
    /// [`DurableCap`], and register its re-wiring.
    ///
    /// Returns the `DurableCap` the component holds and `call`s through,
    /// and a [`Receiver`] that ticks once each time that capability is
    /// repointed. When the peer providing `interface` is restarted, the
    /// control loop binds the fresh ring the broker delivers, repoints the
    /// capability at it (§5.5), and sends that tick — a component awaiting
    /// it knows a `call` will now reach the fresh peer. `reactor` and
    /// `spawner` are the looper's, used to bind the fresh ring.
    pub fn durable_cap<I, R>(
        &mut self,
        interface: &str,
        cap: Cap<I, R>,
        reactor: Arc<ReactorSource>,
        spawner: Spawner,
    ) -> (DurableCap<I, R>, Receiver<()>)
    where
        I: Interface + 'static,
        R: Rights + 'static,
        I::Message: Wire + Method,
    {
        let (durable_cap, repointer) = durable(cap);
        let (repointed_tx, repointed_rx) = channel::<()>(1);
        self.on_rewire(interface, move |grant| {
            // The fresh ring the broker re-wired: bind it onto the looper,
            // then repoint the durable capability at it.
            let fresh: Cap<I, R> = unbound_ipc_cap(grant.endpoint, grant.rights);
            let bound = fresh.bind(Arc::clone(&reactor), &spawner);
            repointer.repoint(bound);
            // Signal the repoint. The channel holds one slot: a still
            // unconsumed tick means a rewire is already known, so dropping
            // this one loses nothing.
            let _ = repointed_tx.try_send(());
        });
        (durable_cap, repointed_rx)
    }

    /// Watch the control channel for the rest of the component's life,
    /// dispatching each [`PeerRestarted`] to its rewire handler.
    ///
    /// Spawn this as a task on the component's looper. It returns when the
    /// broker closes the control connection — the session winding down.
    pub async fn run(mut self) {
        loop {
            let (envelope, handles) = match self.channel.recv().await {
                Ok(message) => message,
                // The broker closed the control connection.
                Err(_) => return,
            };
            // Every message after the bundle is a `PeerRestarted`; a
            // malformed one is skipped rather than fatal.
            let Ok(restarted) = envelope.into_message::<PeerRestarted>(handles) else {
                continue;
            };
            let grant = restarted.grant;
            if let Some(handler) = self.rewires.get_mut(&grant.interface) {
                handler(grant);
            }
            // A `PeerRestarted` for an interface with no registered handler
            // — nothing the component holds to repoint — is ignored.
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use abyss_bundle::CapBody;
    use abyss_looper::Looper;
    use abyss_msg::{Envelope, Header, MessageKind};
    use std::os::fd::AsFd;
    use std::sync::Mutex;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn control_dispatches_a_peer_restarted_to_its_rewire_handler() {
        let (broker_end, component_end) = MessageChannel::pair().expect("socketpair");
        let source = Arc::new(ReactorSource::new().expect("kqueue source"));

        let mut control = Control::watch(component_end, Arc::clone(&source)).expect("control");
        let seen: Arc<Mutex<Vec<(String, Role)>>> = Arc::new(Mutex::new(Vec::new()));
        let recorder = Arc::clone(&seen);
        control.on_rewire("display", move |grant| {
            recorder
                .lock()
                .unwrap()
                .push((grant.interface.clone(), grant.role));
            // `grant.endpoint`, a throwaway ring end, drops here.
        });

        // The broker sends one `PeerRestarted`, then closes the control
        // connection — which is what ends the control loop.
        let peer = thread::spawn(move || {
            thread::sleep(Duration::from_millis(50));
            let (endpoint, _other_end) = Channel::pair().expect("a throwaway ring");
            let grant = Grant {
                interface: "display".to_owned(),
                role: Role::Client,
                rights: CapBody {
                    cap_rights: [0u8; 16],
                    object_rights: 0,
                },
                endpoint: endpoint.into_fd(),
            };
            let (envelope, fds) = Envelope::from_message(
                Header {
                    kind: MessageKind::Event,
                    interface_id: 0,
                    method_id: 1,
                },
                &PeerRestarted { grant },
            );
            let borrowed: Vec<_> = fds.iter().map(AsFd::as_fd).collect();
            broker_end
                .send(&envelope, &borrowed)
                .expect("send the PeerRestarted");
            // `broker_end` drops here, closing the control connection.
        });

        let mut looper = Looper::with_event_source(source);
        looper.spawn(control.run());
        looper.run();
        peer.join().expect("peer thread");

        // The control loop decoded the `PeerRestarted` and routed its grant
        // to the handler registered for that interface.
        assert_eq!(
            *seen.lock().unwrap(),
            vec![("display".to_owned(), Role::Client)],
        );
    }

    #[test]
    fn take_casper_channel_claims_by_service_exactly_once() {
        let (bootstrap_a, _bootstrap_b) = MessageChannel::pair().expect("socketpair");
        let (channel_a, _channel_b) = Channel::pair().expect("a channel for the casper grant");
        let mut startup = Startup {
            bundle: Bundle {
                grants: Vec::new(),
                casper_channels: vec![CasperChannel {
                    service: "system.dns".to_owned(),
                    channel: channel_a.into_fd(),
                }],
            },
            bootstrap: bootstrap_a,
        };
        assert_eq!(startup.casper_channels().len(), 1);

        let claimed = startup
            .take_casper_channel("system.dns")
            .expect("a system.dns channel was offered");
        assert_eq!(claimed.service, "system.dns");

        // The channel is removed from the bundle on claim — the next take
        // for the same service finds nothing.
        assert!(startup.take_casper_channel("system.dns").is_none());
        assert!(startup.casper_channels().is_empty());
    }
}
