// SPDX-License-Identifier: BSD-2-Clause

//! The component bootstrap shim — compiled only on FreeBSD.

use std::io;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};

use abyss_msg::Envelope;
use abyss_transport::{Channel, MessageChannel};

/// The descriptor a component is spawned holding — its bootstrap socket
/// (`broker-and-transport.md` §5.3). Matches `ABYSS_BOOTSTRAP_FD` in the
/// `freebsd-procdesc-sys` spawn shim.
const BOOTSTRAP_FD: RawFd = 3;

/// What [`enter`] hands the component once it is bootstrapped.
pub struct Startup {
    /// The bootstrap bundle the broker sent (§5.3).
    pub bundle: Envelope,
    /// Descriptors delivered with the bundle — the component's initial
    /// capabilities.
    pub handles: Vec<OwnedFd>,
    /// The channel back to the broker, kept for the rest of the component's
    /// life.
    pub bootstrap: MessageChannel,
}

/// Run the component startup shim: receive the bootstrap bundle, then enter
/// Capsicum capability mode (`broker-and-transport.md` §5.4).
///
/// Every component calls this once, before anything else. After it returns
/// the process is confined — it can open no new path, address, or socket;
/// it acts only through the descriptors the bundle delivered.
pub fn enter() -> io::Result<Startup> {
    // The broker spawned us holding the bootstrap socket at fd 3.
    // SAFETY: by the spawn contract (§5.3) fd 3 is this process's bootstrap
    // socket and nothing else holds it; ownership is taken exactly once,
    // here, at the single entry point every component passes through.
    let fd = unsafe { OwnedFd::from_raw_fd(BOOTSTRAP_FD) };
    let bootstrap = MessageChannel::new(Channel::from_fd(fd));

    let (bundle, handles) = bootstrap.recv()?;
    freebsd_capsicum_sys::cap_enter()?;

    Ok(Startup {
        bundle,
        handles,
        bootstrap,
    })
}
