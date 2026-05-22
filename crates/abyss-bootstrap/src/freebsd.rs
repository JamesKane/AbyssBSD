// SPDX-License-Identifier: BSD-2-Clause

//! The component bootstrap shim — compiled only on FreeBSD.

use std::io;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};

use abyss_bundle::{Bundle, Grant, Role};
use abyss_cap::{Cap, Interface, Rights, unbound_ipc_cap};
use abyss_transport::{Channel, MessageChannel};

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
