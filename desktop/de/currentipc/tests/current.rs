//! CurrentIPCTests.swift, ported: the codec, the framing, and handing a real
//! file descriptor to another process. Services bind at explicit paths in
//! a per-test scratch directory, so tests running in parallel never share
//! a socket or touch the environment (the precedence of $ABYSS_RUNTIME_DIR
//! is a unit test in src/transport.rs).

use abyss_sys::platform;
use current_ipc::{connect_path, receive, send, Error, Msg, Server};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

// MARK: the message and its wire format

#[test]
fn pack_unpack_round_trips_typed_fields() {
    let mut m = Msg::new();
    m.set_string("method", "Volume.Set");
    m.set_u64("percent", 80);
    m.set_bool("mute", false);
    m.set_bytes("blob", &[1, 2, 3, 0, 255]);
    let back = Msg::unpack(&m.pack(), vec![]).unwrap();
    assert_eq!(back.string("method"), Some("Volume.Set"));
    assert_eq!(back.u64("percent"), Some(80));
    assert_eq!(back.bool("mute"), Some(false));
    assert_eq!(back.bytes("blob"), Some(&[1u8, 2, 3, 0, 255][..]));
}

#[test]
fn missing_and_mistyped_fields_are_none() {
    let mut m = Msg::new();
    m.set_u64("n", 5);
    assert_eq!(m.u64("nope"), None);
    assert_eq!(m.string("n"), None, "present, wrong type");
    assert!(m.has("n"));
    assert!(!m.has("nope"));
}

#[test]
fn packing_is_deterministic_and_set_replaces_in_place() {
    let mut a = Msg::new();
    a.set_string("one", "1");
    a.set_u64("two", 2);
    let mut b = Msg::new();
    b.set_string("one", "1");
    b.set_u64("two", 2);
    assert_eq!(a.pack(), b.pack(), "same fields in the same order pack identically");
    let mut c = Msg::new();
    c.set_string("one", "x");
    c.set_u64("two", 2);
    c.set_string("one", "1");
    assert_eq!(c.pack(), a.pack(), "a replaced value keeps its position");
    assert_eq!(c.fields().len(), 2);
}

#[test]
fn unicode_and_empty_values_survive() {
    let mut m = Msg::new();
    m.set_string("emoji", "Aqua 💧 10.2");
    m.set_string("empty", "");
    m.set_bytes("nobytes", &[]);
    m.set_u64("big", u64::MAX);
    let back = Msg::unpack(&m.pack(), vec![]).unwrap();
    assert_eq!(back.string("emoji"), Some("Aqua 💧 10.2"));
    assert_eq!(back.string("empty"), Some(""));
    assert_eq!(back.bytes("nobytes"), Some(&[][..]));
    assert_eq!(back.u64("big"), Some(u64::MAX));
}

/// A hostile or buggy peer gets an error, never a crash or a hang.
#[test]
fn malformed_frames_are_rejected_not_crashed() {
    assert!(Msg::unpack(&[], vec![]).is_err());
    assert!(Msg::unpack(b"NOPE\x01", vec![]).is_err());
    assert!(Msg::unpack(b"ABYM\x63", vec![]).is_err());
    let mut m = Msg::new();
    m.set_string("s", "hello");
    let good = m.pack();
    for cut in 1..good.len() {
        assert!(Msg::unpack(&good[..cut], vec![]).is_err(), "truncation at {cut} accepted");
    }
    // A length that claims more string than the buffer holds.
    let mut lying = b"ABYM\x01\x00\x01".to_vec();
    lying.extend_from_slice(&[0, 1, b's', 1, 0xff, 0xff, 0xff, 0xff]);
    assert!(Msg::unpack(&lying, vec![]).is_err());
}

#[test]
fn an_fd_field_with_no_descriptor_is_malformed() {
    let mut m = Msg::new();
    m.set_fd("buffer", 1);
    assert!(matches!(Msg::unpack(&m.pack(), vec![]), Err(Error::Malformed(_))));
}

// MARK: descriptor passing, the point of the whole component

/// The descriptor out of the far end of a socket pair is a different number
/// for the same open file.
#[test]
fn scm_rights_carries_a_real_descriptor() {
    let (a, b) = UnixStream::pair().unwrap();
    let (file, contents) = temp_file_with("aqua-fd-pass");
    let mut out = Msg::new();
    out.set_string("method", "Buffer.Hand");
    out.set_fd("buffer", file.as_raw_fd());
    out.set_u64("bytes", contents.len() as u64);
    send(&out, &a).unwrap();

    let mut got = receive(&b).unwrap();
    assert_eq!(got.string("method"), Some("Buffer.Hand"));
    let received = got.take_fd("buffer").expect("no descriptor arrived");
    assert_ne!(received.as_raw_fd(), file.as_raw_fd(), "a passed fd arrives as a new number");
    assert_eq!(read_whole(received), contents, "the sender's file, through the receiver's fd");
    assert_eq!(got.fd("buffer"), None, "take_fd removed the field");
}

#[test]
fn several_descriptors_keep_their_fields_straight() {
    let (a, b) = UnixStream::pair().unwrap();
    let (fa, ta) = temp_file_with("aqua-fd-a");
    let (fb, tb) = temp_file_with("aqua-fd-b");
    let mut out = Msg::new();
    out.set_fd("first", fa.as_raw_fd());
    out.set_string("label", "between");
    out.set_fd("second", fb.as_raw_fd());
    send(&out, &a).unwrap();
    let mut got = receive(&b).unwrap();
    assert_eq!(got.string("label"), Some("between"));
    let (x, y) = (got.take_fd("first").unwrap(), got.take_fd("second").unwrap());
    assert_eq!(read_whole(x), ta, "indices map back to the right fields");
    assert_eq!(read_whole(y), tb);
}

#[test]
fn close_fds_drops_what_the_handler_didnt_want() {
    let (a, b) = UnixStream::pair().unwrap();
    let (file, _) = temp_file_with("aqua-fd-drop");
    let mut out = Msg::new();
    out.set_fd("buffer", file.as_raw_fd());
    send(&out, &a).unwrap();
    let mut got = receive(&b).unwrap();
    let received = got.fd("buffer").expect("a descriptor");
    assert!(platform::fd_is_open(received));
    got.close_fds();
    assert_eq!(got.fd("buffer"), None, "close_fds removes the fields too");
    assert!(!platform::fd_is_open(received), "and the descriptor is really closed");
}

/// What Swift had to call close_fds for, Rust does on drop.
#[test]
fn a_dropped_message_closes_its_descriptors() {
    let (a, b) = UnixStream::pair().unwrap();
    let (file, _) = temp_file_with("aqua-fd-drop2");
    let mut out = Msg::new();
    out.set_fd("buffer", file.as_raw_fd());
    send(&out, &a).unwrap();
    let got = receive(&b).unwrap();
    let received = got.fd("buffer").unwrap();
    drop(got);
    assert!(!platform::fd_is_open(received));
    assert!(platform::fd_is_open(file.as_raw_fd()), "a borrowed one is the sender's, untouched");
}

/// Writing to a peer that has gone is an error, never SIGPIPE (HANDOFF
/// §2.33). If this kills the test binary, that protection is gone.
#[test]
fn writing_to_a_closed_peer_errors_rather_than_killing_us() {
    let (a, b) = UnixStream::pair().unwrap();
    drop(b);
    let mut m = Msg::new();
    m.set_string("method", "into-the-void");
    m.set_bytes("filler", &vec![0x7f; 64 * 1024]);
    match send(&m, &a) {
        Err(Error::Closed) | Err(Error::System(..)) => {}
        r => panic!("expected closed or system, got {r:?}"),
    }
}

// MARK: a real service on a real socket

#[test]
fn server_and_client_over_a_real_socket() {
    let dir = Scratch::new();
    let server = Server::bind(&dir.sock("volume"), 0o600).unwrap();
    assert!(server.path.ends_with("/volume.sock"));
    // No thread: the connection waits in the backlog, so client and service
    // take turns, as a service hosted in a run loop does.
    let client = connect_path(&dir.sock("volume")).unwrap();
    let mut req = Msg::new();
    req.set_string("method", "Volume.Set");
    req.set_u64("percent", 41);
    send(&req, &client).unwrap();
    assert!(server
        .serve_one(&mut |r| {
            let mut reply = Msg::new();
            reply.set_bool("ok", true);
            reply.set_string("echo", r.string("method").unwrap_or(""));
            reply.set_u64("percent", r.u64("percent").unwrap_or(0) + 1);
            reply
        })
        .unwrap());
    let reply = receive(&client).unwrap();
    assert_eq!(reply.bool("ok"), Some(true));
    assert_eq!(reply.string("echo"), Some("Volume.Set"));
    assert_eq!(reply.u64("percent"), Some(42));
}

/// Rubbish costs that one connection and nothing more.
#[test]
fn a_garbage_request_does_not_kill_the_service() {
    let dir = Scratch::new();
    let server = Server::bind(&dir.sock("anchor"), 0o600).unwrap();
    let mut bad = connect_path(&dir.sock("anchor")).unwrap();
    bad.write_all(&[0, 0, 0, 5, b'n', b'o', b'p', b'e', b'!']).unwrap();
    drop(bad);
    let mut handled = false;
    assert!(!server
        .serve_one(&mut |_| {
            handled = true;
            Msg::new()
        })
        .unwrap());
    assert!(!handled, "a malformed request is dropped, not handled");

    let good = connect_path(&dir.sock("anchor")).unwrap();
    let mut req = Msg::new();
    req.set_string("method", "status");
    send(&req, &good).unwrap();
    assert!(server
        .serve_one(&mut |r| {
            let mut m = Msg::new();
            m.set_string("echo", r.string("method").unwrap_or(""));
            m
        })
        .unwrap());
    assert_eq!(receive(&good).unwrap().string("echo"), Some("status"));
}

/// An accepted connection is blocking whatever the listener is: the BSDs
/// pass O_NONBLOCK on, Linux does not (HANDOFF §2.33).
#[test]
fn accepted_connections_are_blocking_even_from_a_non_blocking_listener() {
    let dir = Scratch::new();
    let server = Server::bind(&dir.sock("anchor"), 0o600).unwrap();
    server.set_nonblocking(true).unwrap();
    let _client = connect_path(&dir.sock("anchor")).unwrap();
    let accepted = server.accept().unwrap();
    assert!(!platform::is_nonblocking(accepted.as_fd()).unwrap());
}

#[test]
fn bind_replaces_a_stale_socket_and_unlinks_on_close() {
    let dir = Scratch::new();
    let path = dir.sock("anchor");
    {
        let mut first = Server::bind(&path, 0o600).unwrap();
        assert!(fs::metadata(&first.path).is_ok());
        first.shutdown_and_unlink();
        assert!(fs::metadata(&path).is_err(), "the socket is removed on shutdown");
    }
    // A crash leaves the file behind; binding again must not be EADDRINUSE.
    File::create(&path).unwrap();
    let second = Server::bind(&path, 0o600).unwrap();
    assert!(fs::metadata(&second.path).is_ok());
    drop(second);
    assert!(fs::metadata(&path).is_err(), "and on drop");
}

#[test]
fn connecting_to_a_missing_service_fails() {
    let dir = Scratch::new();
    assert!(matches!(connect_path(&dir.sock("nobody-home")), Err(Error::System(..))));
}

#[test]
fn a_frame_over_the_size_cap_is_refused() {
    let mut m = Msg::new();
    m.set_bytes("blob", &vec![0xab; Msg::MAX_FRAME]);
    let (a, _b) = UnixStream::pair().unwrap();
    assert!(matches!(send(&m, &a), Err(Error::TooLarge(_))));
}

// MARK: helpers

/// A private scratch directory, removed when the test ends.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Scratch {
        static N: AtomicU32 = AtomicU32::new(0);
        let p = std::env::temp_dir().join(format!(
            "abyss-ipc-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        Scratch(p)
    }
    fn sock(&self, service: &str) -> String {
        format!("{}/{service}.sock", self.0.display())
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// An unlinked temporary file with known contents, at offset 0: alive only
/// through its descriptor, as a handed-over shm buffer is.
fn temp_file_with(tag: &str) -> (File, Vec<u8>) {
    static N: AtomicU32 = AtomicU32::new(0);
    let p = std::env::temp_dir().join(format!("{tag}-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
    let mut f = File::options().read(true).write(true).create_new(true).open(&p).unwrap();
    fs::remove_file(&p).unwrap();
    let contents = format!("contents of {tag} — {}", std::process::id()).into_bytes();
    f.write_all(&contents).unwrap();
    f.seek(SeekFrom::Start(0)).unwrap();
    (f, contents)
}

fn read_whole(fd: OwnedFd) -> Vec<u8> {
    let mut f = File::from(fd);
    f.seek(SeekFrom::Start(0)).unwrap();
    let mut out = Vec::new();
    f.read_to_end(&mut out).unwrap();
    out
}
