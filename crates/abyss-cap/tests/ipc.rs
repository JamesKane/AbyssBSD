// SPDX-License-Identifier: BSD-2-Clause

//! `Cap::send` over the IPC backend — a message framed and sent over a
//! `SOCK_SEQPACKET` ring (`broker-and-transport.md` §2.8, §2.9).

#![cfg(target_os = "freebsd")]

use std::sync::Arc;
use std::thread;

use abyss_cap::{Interface, Rights, ipc_cap};
use abyss_looper::Looper;
use abyss_msg::MessageKind;
use abyss_msg_derive::{Method, Wire};
use abyss_transport::{AsyncChannel, Connection, FrameKind, FramedChannel, ReactorSource};

/// A one-method test interface.
#[derive(Wire, Method, Debug, PartialEq)]
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

#[allow(dead_code)] // a marker type — only ever a type parameter
struct Full;
impl Rights for Full {}

#[test]
fn send_over_ipc_frames_the_message_with_its_interface_and_method() {
    let (client_framed, server_framed) = FramedChannel::pair().expect("socketpair");
    let source = Arc::new(ReactorSource::new().expect("kqueue source"));
    let client = AsyncChannel::new(client_framed, Arc::clone(&source)).expect("async channel");
    let (connection, _inbox) = Connection::open(client);
    let cap = ipc_cap::<Poke, Full>(connection);

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
