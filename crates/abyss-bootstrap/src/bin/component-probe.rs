// SPDX-License-Identifier: BSD-2-Clause

//! A minimal AbyssBSD component — the bootstrap probe.
//!
//! It runs the startup shim, then acts on the capabilities its bundle
//! delivered: a probe wired a `client` grant binds it to a looper and
//! `call`s over the ring; one wired a `server` grant serves the ring and
//! answers the request; one wired nothing simply reports. Two probes
//! wired as a pair therefore hold a real conversation over a broker-wired
//! ring — the fixture the spawn, wiring, and bootstrap path
//! (`broker-and-transport.md` §5.2–§5.4) is tested against.
//!
//! Every probe reports back to the broker over the bootstrap channel a
//! four-field record: whether it is in capability mode, its grant count,
//! the client capabilities it claimed, and a role-specific outcome — the
//! reply a client received, or the number of requests a server answered.

#[cfg(target_os = "freebsd")]
mod component {
    use std::sync::Arc;

    use abyss_bootstrap::Startup;
    use abyss_bundle::Role;
    use abyss_cap::{Cap, Interface, Rights};
    use abyss_looper::Looper;
    use abyss_msg::{Envelope, Header, MessageKind, Value};
    use abyss_msg_derive::{Method, Request, Wire};
    use abyss_transport::{AsyncChannel, Connection, FramedChannel, MessageChannel, ReactorSource};

    /// The probe's test interface — one request, `Ping`, answered with its
    /// value. Both ends of a wired pair run this one binary, so a single
    /// interface definition serves the client and the server alike.
    #[derive(Wire, Method, Request)]
    enum EchoMsg {
        #[request(reply = i64)]
        Ping(Ping),
    }

    #[derive(Wire)]
    struct Ping {
        value: i64,
    }

    #[allow(dead_code)] // a marker type — only ever a type parameter
    struct Echo;
    impl Interface for Echo {
        const ID: u32 = 1;
        type Message = EchoMsg;
    }

    #[allow(dead_code)] // a marker type — only ever a type parameter
    struct AnyRights;
    impl Rights for AnyRights {}

    /// The value a client `Ping`s with; the server echoes it back.
    const PING_VALUE: i64 = 41;

    /// The header of a bootstrap-channel report, and of a reply envelope —
    /// neither rides an interface ring, so the ids are zero.
    fn plain_header() -> Header {
        Header {
            kind: MessageKind::Event,
            interface_id: 0,
            method_id: 0,
        }
    }

    /// Send the probe's four-field report to the broker, and exit.
    fn report_and_exit(bootstrap: &MessageChannel, fields: [i64; 4]) -> ! {
        let report = Envelope {
            header: plain_header(),
            payload: Value::List(fields.iter().copied().map(Value::Int).collect()),
            handles: Vec::new(),
        };
        bootstrap.send(&report, &[]).expect("report to the broker");
        std::process::exit(0);
    }

    /// Run the probe: bootstrap, then act on the role its grants imply.
    pub fn run() {
        let startup = abyss_bootstrap::enter().expect("component bootstrap");
        // `enter` has called `cap_enter`; confirm the process is confined.
        let confined = i64::from(freebsd_capsicum_sys::cap_getmode().expect("cap_getmode"));
        let grant_count =
            i64::try_from(startup.grants().len()).expect("the grant count fits an i64");

        let client = startup
            .grants()
            .iter()
            .find(|grant| grant.role == Role::Client)
            .map(|grant| grant.interface.clone());
        let server = startup
            .grants()
            .iter()
            .find(|grant| grant.role == Role::Server)
            .map(|grant| grant.interface.clone());

        match (client, server) {
            (Some(interface), _) => run_client(startup, &interface, confined, grant_count),
            (None, Some(interface)) => run_server(startup, &interface, confined, grant_count),
            // No grants: nothing to do but report.
            (None, None) => report_and_exit(&startup.bootstrap, [confined, grant_count, 0, 0]),
        }
    }

    /// Claim the client capability, bind it to a looper, and `call` over
    /// the wired ring; report the reply.
    fn run_client(mut startup: Startup, interface: &str, confined: i64, grant_count: i64) {
        let cap: Cap<Echo, AnyRights> = startup
            .take_client_cap(interface)
            .expect("the client grant claims");
        let bootstrap = startup.bootstrap;

        let reactor = Arc::new(ReactorSource::new().expect("kqueue reactor"));
        // `reactor.clone()` (not `Arc::clone`) so the `Arc<ReactorSource>`
        // coerces to the looper's `Arc<dyn EventSource>`; the original
        // `reactor` is the concrete `Arc` `Cap::bind` needs.
        let mut looper = Looper::with_event_source(reactor.clone());
        let spawner = looper.spawner();
        looper.spawn(async move {
            // Binding spawns the connection's serve loop onto this looper,
            // so the call's reply routes back (§3.5).
            let cap = cap.bind(reactor, &spawner);
            let reply = cap
                .call(Ping { value: PING_VALUE })
                .await
                .expect("call over the broker-wired ring");
            report_and_exit(&bootstrap, [confined, grant_count, 1, reply]);
        });
        looper.run();
    }

    /// Claim the server endpoint, serve the ring, and answer one request.
    fn run_server(mut startup: Startup, interface: &str, confined: i64, grant_count: i64) {
        let grant = startup
            .take_server_grant(interface)
            .expect("the server grant claims");
        let bootstrap = startup.bootstrap;

        let reactor = Arc::new(ReactorSource::new().expect("kqueue reactor"));
        let channel =
            AsyncChannel::new(FramedChannel::from_fd(grant.endpoint), Arc::clone(&reactor))
                .expect("drive the service ring");
        let (connection, mut inbox) = Connection::open(channel);

        let mut looper = Looper::with_event_source(reactor);
        looper.spawn(connection.serve());
        looper.spawn(async move {
            let inbound = inbox.accept().await.expect("a request arrives");
            let EchoMsg::Ping(ping) = inbound
                .envelope
                .into_message::<EchoMsg>(inbound.fds)
                .expect("decode the request");
            let responder = inbound.responder.expect("a request carries a responder");
            let (reply, _fds) = Envelope::from_message(plain_header(), &ping.value);
            responder
                .respond(&reply, &[])
                .await
                .expect("answer the request");
            report_and_exit(&bootstrap, [confined, grant_count, 0, 1]);
        });
        looper.run();
    }
}

#[cfg(target_os = "freebsd")]
fn main() {
    component::run();
}

#[cfg(not(target_os = "freebsd"))]
fn main() {
    // The bootstrap probe is a FreeBSD component; elsewhere it is a stub so
    // the workspace still builds on the macOS dev bed.
}
