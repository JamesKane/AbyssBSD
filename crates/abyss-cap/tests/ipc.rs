// SPDX-License-Identifier: BSD-2-Clause

//! `Cap` over the IPC backend (`broker-and-transport.md` §2.8–§2.9, §3.4–§3.5):
//! a message framed and sent over a `SOCK_SEQPACKET` ring, and a `Cap`
//! itself serialized through `Wire` — its ring socket onto `SCM_RIGHTS` —
//! then bound to a looper and used.

#![cfg(target_os = "freebsd")]

use std::sync::{Arc, Mutex};
use std::thread;

use abyss_cap::{
    Cap, CapBody, Interface, KIND_FD_CAPABILITY, Reply, Rights, Service, bind_service, cap_channel,
    ipc_cap,
};
use abyss_looper::Looper;
use abyss_msg::{Envelope, HandleSink, HandleStore, Header, MessageKind, Value, Wire};
use abyss_msg_derive::{Method, Request, Wire as WireDerive};
use abyss_transport::{
    AsyncChannel, Channel, Connection, FrameKind, FramedChannel, ReactorSource, RingFrame,
};

/// A one-method command interface.
#[derive(WireDerive, Method, Debug, PartialEq)]
enum PokeMsg {
    #[command]
    Poke(i64),
}

#[allow(dead_code)] // a marker type — only ever a type parameter
struct Poke;
impl Interface for Poke {
    const ID: u32 = 42;
    type Message = PokeMsg;
}

/// A request interface — `Ping`, answered with its value.
#[derive(WireDerive, Method, Request, Debug, PartialEq)]
enum EchoMsg {
    #[request(reply = i32)]
    Ping(Ping),
}

/// The `Ping` request payload.
#[derive(WireDerive, Debug, PartialEq)]
struct Ping {
    value: i32,
}

#[allow(dead_code)] // a marker type — only ever a type parameter
struct Echo;
impl Interface for Echo {
    const ID: u32 = 7;
    type Message = EchoMsg;
}

#[allow(dead_code)] // a marker type — only ever a type parameter
struct Full;
impl Rights for Full {
    const MASK: u32 = u32::MAX;
}

/// A service over `Echo` — answers each `Ping` with its value.
struct EchoService;
impl Service for EchoService {
    type Interface = Echo;
    async fn handle(&mut self, message: EchoMsg, reply: Reply) {
        let EchoMsg::Ping(ping) = message;
        let _ = reply.answer(ping.value).await;
    }
}

/// A `CapBody` carrying just an object-rights mask.
fn rights(object_rights: u32) -> CapBody {
    CapBody {
        cap_rights: [0u8; 16],
        object_rights,
    }
}

/// A distinctive capability body, so a round-trip can be checked exactly.
fn sample_body() -> CapBody {
    CapBody {
        cap_rights: [
            0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD,
            0xAE, 0xAF,
        ],
        object_rights: 0x0000_00FF,
    }
}

#[test]
fn send_over_ipc_frames_the_message_with_its_interface_and_method() {
    let (client_framed, server_framed) = FramedChannel::pair().expect("socketpair");
    let source = Arc::new(ReactorSource::new().expect("kqueue source"));
    let client = AsyncChannel::new(client_framed, Arc::clone(&source)).expect("async channel");
    let (connection, _inbox) = Connection::open(client);
    let cap = ipc_cap::<Poke, Full>(connection, sample_body());

    // The peer receives the framed datagram off the raw channel.
    let peer = thread::spawn(move || server_framed.recv().expect("peer recv"));

    let mut looper = Looper::with_event_source(source);
    looper.spawn(async move {
        cap.send(PokeMsg::Poke(99))
            .await
            .expect("send over the IPC ring");
    });
    looper.run();

    let (frame, envelope, fds) = peer.join().expect("peer thread");

    // The ring frame: a one-way message, so no correlation.
    assert_eq!(frame.kind, FrameKind::Message);
    assert_eq!(frame.correlation, 0);

    // The envelope header carries the interface and the method identity.
    assert_eq!(envelope.header.interface_id, Poke::ID);
    assert_eq!(envelope.header.method_id, 0);
    assert_eq!(envelope.header.kind, MessageKind::Command);

    // And the payload round-trips back to the message that was sent.
    assert_eq!(envelope.into_message::<PokeMsg>(fds), Ok(PokeMsg::Poke(99)));
}

#[test]
fn a_cap_serializes_to_an_fd_capability_handle() {
    let (client_framed, _server_framed) = FramedChannel::pair().expect("socketpair");
    let source = Arc::new(ReactorSource::new().expect("kqueue source"));
    let client = AsyncChannel::new(client_framed, source).expect("async channel");
    let (connection, _inbox) = Connection::open(client);
    let cap = ipc_cap::<Echo, Full>(connection, sample_body());

    // `to_wire` pushes the capability into the handle table: one fd, and a
    // §3.2 body carrying the rights the cap was minted with.
    let mut sink = HandleSink::new();
    let value = cap.to_wire(&mut sink);
    let (handles, fds) = sink.into_parts();

    assert_eq!(value, Value::Handle(0));
    assert_eq!(handles.len(), 1);
    assert_eq!(fds.len(), 1);
    assert_eq!(handles[0].kind, KIND_FD_CAPABILITY);
    assert_eq!(
        CapBody::decode(&handles[0].body),
        Ok(sample_body()),
        "the handle body is the cap's CapBody",
    );
}

#[test]
#[should_panic(expected = "in-process")]
fn an_in_process_cap_cannot_be_serialized() {
    let (cap, _rx) = cap_channel::<Echo, Full>(1);
    // An in-process `Cap` has no fd to cross a boundary (§2.8) — serializing
    // one is a contract violation.
    let _ = cap.to_wire(&mut HandleSink::new());
}

#[test]
fn a_received_cap_binds_to_a_looper_and_calls_over_its_ring() {
    let (client_framed, server_framed) = FramedChannel::pair().expect("socketpair");
    let source = Arc::new(ReactorSource::new().expect("kqueue source"));

    // The original IPC capability — what the broker would hold.
    let client = AsyncChannel::new(client_framed, Arc::clone(&source)).expect("async channel");
    let (connection, _inbox) = Connection::open(client);
    let original = ipc_cap::<Echo, Full>(connection, sample_body());

    // Serialize it (its ring socket is duplicated onto SCM_RIGHTS), then
    // decode the wire form back — yielding an *unbound* capability.
    let mut sink = HandleSink::new();
    let value = original.to_wire(&mut sink);
    let (handles, fds) = sink.into_parts();
    drop(original); // the duplicate keeps the ring open

    let mut store = HandleStore::new(handles, fds).expect("handle store");
    let unbound: Cap<Echo, Full> = Wire::from_wire(&value, &mut store).expect("decode the cap");

    // The peer answers one `Ping` with a reply frame echoing its id.
    let peer = thread::spawn(move || {
        let (frame, _request, _) = server_framed.recv().expect("peer recv request");
        assert_eq!(frame.kind, FrameKind::Message);
        let reply = Envelope {
            header: Header {
                kind: MessageKind::Event,
                interface_id: Echo::ID,
                method_id: 0,
            },
            payload: Value::Int(7),
            handles: Vec::new(),
        };
        server_framed
            .send(
                RingFrame {
                    kind: FrameKind::Reply,
                    correlation: frame.correlation,
                },
                &reply,
                &[],
            )
            .expect("peer reply");
    });

    // On the looper: bind the received cap — which spawns its `serve` loop
    // through the spawner — and call over the now-live ring.
    let answer = Arc::new(Mutex::new(None));
    let task_answer = Arc::clone(&answer);
    let bind_source = Arc::clone(&source);
    let mut looper = Looper::with_event_source(source);
    let spawner = looper.spawner();
    looper.spawn(async move {
        let bound = unbound.bind(bind_source, &spawner);
        let reply = bound
            .call(Ping { value: 7 })
            .await
            .expect("call over the bound capability");
        *task_answer.lock().unwrap() = Some(reply);
    });
    looper.run();

    peer.join().expect("peer thread");
    assert_eq!(answer.lock().unwrap().take(), Some(7));
}

#[test]
fn a_service_answers_a_request_within_its_rights() {
    let (client_chan, server_chan) = Channel::pair().expect("socketpair");
    let source = Arc::new(ReactorSource::new().expect("kqueue source"));

    // A raw client: send one request, receive the reply, then exit —
    // closing the ring so the service's looper winds down.
    let (request, _fds) = Envelope::from_message(
        Header {
            kind: MessageKind::Request,
            interface_id: Echo::ID,
            method_id: 0,
        },
        &EchoMsg::Ping(Ping { value: 99 }),
    );
    let client = thread::spawn(move || {
        let client = FramedChannel::new(client_chan);
        client
            .send(
                RingFrame {
                    kind: FrameKind::Message,
                    correlation: 1,
                },
                &request,
                &[],
            )
            .expect("send the request");
        client.recv().expect("receive the reply")
    });

    // Bind the service, granting `Ping` — ordinal 0, bit 0 of the mask.
    let looper = Looper::with_event_source(source.clone());
    let spawner = looper.spawner();
    bind_service::<EchoService>(
        server_chan.into_fd(),
        rights(0b1),
        EchoService,
        source,
        &spawner,
    );
    looper.run();

    let (frame, reply, fds) = client.join().expect("client thread");
    assert_eq!(frame.kind, FrameKind::Reply);
    assert_eq!(reply.into_message::<i32>(fds), Ok(99));
}

#[test]
fn a_service_refuses_a_request_outside_its_rights() {
    let (client_chan, server_chan) = Channel::pair().expect("socketpair");
    let source = Arc::new(ReactorSource::new().expect("kqueue source"));

    let (request, _fds) = Envelope::from_message(
        Header {
            kind: MessageKind::Request,
            interface_id: Echo::ID,
            method_id: 0,
        },
        &EchoMsg::Ping(Ping { value: 99 }),
    );
    let client = thread::spawn(move || {
        let client = FramedChannel::new(client_chan);
        client
            .send(
                RingFrame {
                    kind: FrameKind::Message,
                    correlation: 1,
                },
                &request,
                &[],
            )
            .expect("send the request");
        client.recv().expect("receive the outcome")
    });

    // Bind the service granting *no* rights — `Ping` is outside the mask.
    let looper = Looper::with_event_source(source.clone());
    let spawner = looper.spawner();
    bind_service::<EchoService>(
        server_chan.into_fd(),
        rights(0),
        EchoService,
        source,
        &spawner,
    );
    looper.run();

    let (frame, _envelope, _fds) = client.join().expect("client thread");
    assert_eq!(
        frame.kind,
        FrameKind::Error,
        "a request outside the granted rights is refused",
    );
}
