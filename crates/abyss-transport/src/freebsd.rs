// SPDX-License-Identifier: BSD-2-Clause

//! The FreeBSD IPC transport — compiled only on FreeBSD.
//!
//! [`Channel`] is one end of a `SOCK_SEQPACKET` connection. The `extern`
//! declarations match `c/cmsg_shim.c`; both are verified by the test below
//! when the crate is built in the FreeBSD VM.

use std::ffi::{c_int, c_void};
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};

use abyss_msg::Envelope;

/// The largest descriptor count one datagram may carry. Must match
/// `ABYSS_MAX_FDS` in `c/cmsg_shim.c`.
const MAX_FDS: usize = 64;

unsafe extern "C" {
    fn abyss_seqpacket_pair(sv: *mut c_int) -> c_int;
    fn abyss_send_fds(
        sock: c_int,
        data: *const c_void,
        len: usize,
        fds: *const c_int,
        nfds: usize,
    ) -> isize;
    fn abyss_recv_fds(
        sock: c_int,
        buf: *mut c_void,
        buflen: usize,
        fds: *mut c_int,
        fdcap: usize,
        nfds: *mut usize,
    ) -> isize;
}

/// One end of a `SOCK_SEQPACKET` connection — an ordered, reliable,
/// message-boundary-preserving channel that also carries file descriptors
/// (`docs/design/broker-and-transport.md` §2.1).
pub struct Channel {
    fd: OwnedFd,
}

impl Channel {
    /// A connected pair of channels — the two ends of one ring.
    pub fn pair() -> io::Result<(Channel, Channel)> {
        let mut sv = [0 as c_int; 2];
        // SAFETY: `sv` is a two-element array; the shim writes two fds into it.
        let rc = unsafe { abyss_seqpacket_pair(sv.as_mut_ptr()) };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `socketpair` just produced sv[0] and sv[1] as fresh owned
        // descriptors.
        let a = unsafe { OwnedFd::from_raw_fd(sv[0]) };
        let b = unsafe { OwnedFd::from_raw_fd(sv[1]) };
        Ok((Channel { fd: a }, Channel { fd: b }))
    }

    /// Send one datagram: `data` as the body, `fds` passed via `SCM_RIGHTS`.
    ///
    /// The descriptors are borrowed — the receiver is handed its own owned
    /// copies, and the caller keeps ownership of the ones passed here.
    pub fn send(&self, data: &[u8], fds: &[BorrowedFd<'_>]) -> io::Result<usize> {
        if fds.len() > MAX_FDS {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "too many descriptors for one datagram",
            ));
        }
        let raw: Vec<c_int> = fds.iter().map(AsRawFd::as_raw_fd).collect();
        // SAFETY: `data` and `raw` are valid for the lengths passed; the
        // shim reads them within the call and retains neither pointer.
        let n = unsafe {
            abyss_send_fds(
                self.fd.as_raw_fd(),
                data.as_ptr().cast(),
                data.len(),
                raw.as_ptr(),
                raw.len(),
            )
        };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(n as usize)
    }

    /// Receive one datagram into `buf`, returning the body length and any
    /// descriptors that rode `SCM_RIGHTS` with it.
    ///
    /// `buf` should be large enough for the whole datagram; `SOCK_SEQPACKET`
    /// discards any body that does not fit.
    pub fn recv(&self, buf: &mut [u8]) -> io::Result<(usize, Vec<OwnedFd>)> {
        let mut raw = [0 as c_int; MAX_FDS];
        let mut nfds: usize = 0;
        // SAFETY: `buf` and `raw` are valid for the capacities passed, and
        // `nfds` is a valid out-pointer.
        let n = unsafe {
            abyss_recv_fds(
                self.fd.as_raw_fd(),
                buf.as_mut_ptr().cast(),
                buf.len(),
                raw.as_mut_ptr(),
                MAX_FDS,
                &mut nfds,
            )
        };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        let fds = raw[..nfds]
            .iter()
            // SAFETY: each fd was just produced by `recvmsg`/`SCM_RIGHTS` as
            // a fresh owned descriptor in this process.
            .map(|&fd| unsafe { OwnedFd::from_raw_fd(fd) })
            .collect();
        Ok((n as usize, fds))
    }
}

impl AsFd for Channel {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.fd.as_fd()
    }
}

impl AsRawFd for Channel {
    fn as_raw_fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }
}

/// The largest envelope one datagram carries. Envelopes are small by
/// design — large data travels as a shared-memory handle, never inline
/// (`docs/design/broker-and-transport.md` §2.4).
const MAX_ENVELOPE: usize = 64 * 1024;

/// A [`Channel`] that carries whole [`Envelope`]s.
///
/// One `send` is one `SOCK_SEQPACKET` datagram: the envelope's encoded
/// bytes as the body (`broker-and-transport.md` §2.2), and the descriptors
/// of its fd-bearing handles passed via `SCM_RIGHTS`. The handle-table
/// entries and the `SCM_RIGHTS` descriptors correlate by order; matching
/// them to capability meaning is a layer above this one.
pub struct MessageChannel {
    channel: Channel,
}

impl MessageChannel {
    /// A connected pair — the two ends of one message ring.
    pub fn pair() -> io::Result<(MessageChannel, MessageChannel)> {
        let (a, b) = Channel::pair()?;
        Ok((MessageChannel { channel: a }, MessageChannel { channel: b }))
    }

    /// Frame envelopes over an existing channel.
    pub fn new(channel: Channel) -> Self {
        MessageChannel { channel }
    }

    /// Send one envelope, the descriptors of its handles carried alongside
    /// via `SCM_RIGHTS`.
    pub fn send(&self, envelope: &Envelope, fds: &[BorrowedFd<'_>]) -> io::Result<()> {
        let bytes = envelope.encode();
        let sent = self.channel.send(&bytes, fds)?;
        if sent != bytes.len() {
            return Err(io::Error::other("envelope datagram truncated on send"));
        }
        Ok(())
    }

    /// Receive one envelope and the descriptors that rode with it.
    pub fn recv(&self) -> io::Result<(Envelope, Vec<OwnedFd>)> {
        let mut buf = vec![0u8; MAX_ENVELOPE];
        let (n, fds) = self.channel.recv(&mut buf)?;
        let envelope = Envelope::decode(&buf[..n]).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("malformed envelope: {err:?}"),
            )
        })?;
        Ok((envelope, fds))
    }
}

impl AsFd for MessageChannel {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.channel.as_fd()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::{Read, Seek, SeekFrom, Write};

    #[test]
    fn round_trips_a_datagram() {
        let (a, b) = Channel::pair().expect("socketpair");
        a.send(b"hello transport", &[]).expect("send");

        let mut buf = [0u8; 64];
        let (n, fds) = b.recv(&mut buf).expect("recv");
        assert_eq!(&buf[..n], b"hello transport");
        assert!(fds.is_empty());
    }

    #[test]
    fn preserves_message_boundaries() {
        // SOCK_SEQPACKET: each send is a distinct datagram, never coalesced.
        let (a, b) = Channel::pair().expect("socketpair");
        a.send(b"one", &[]).expect("send one");
        a.send(b"three", &[]).expect("send three");

        let mut buf = [0u8; 64];
        let (n1, _) = b.recv(&mut buf).expect("recv one");
        assert_eq!(&buf[..n1], b"one");
        let (n2, _) = b.recv(&mut buf).expect("recv three");
        assert_eq!(&buf[..n2], b"three");
    }

    #[test]
    fn carries_a_file_descriptor() {
        // A file with known content; its descriptor is passed across the
        // channel, and the receiver reads the same open file through it.
        let mut path = std::env::temp_dir();
        path.push(format!("abyss-transport-{}", std::process::id()));
        File::create(&path)
            .expect("create temp file")
            .write_all(b"descriptor crossed")
            .expect("write temp file");
        let file = File::open(&path).expect("open temp file");

        let (a, b) = Channel::pair().expect("socketpair");
        a.send(b"fd", &[file.as_fd()]).expect("send with fd");

        let mut buf = [0u8; 16];
        let (n, mut fds) = b.recv(&mut buf).expect("recv with fd");
        assert_eq!(&buf[..n], b"fd");
        assert_eq!(fds.len(), 1);

        // The received descriptor is an independent handle on the same open
        // file — read it from the start.
        let mut received = File::from(fds.pop().expect("one fd"));
        received.seek(SeekFrom::Start(0)).expect("seek");
        let mut got = String::new();
        received.read_to_string(&mut got).expect("read passed fd");
        assert_eq!(got, "descriptor crossed");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn round_trips_a_plain_envelope() {
        use abyss_msg::{Header, MessageKind, Value};

        let (a, b) = MessageChannel::pair().expect("socketpair");
        let envelope = Envelope {
            header: Header {
                kind: MessageKind::Command,
                interface_id: 11,
                method_id: 2,
            },
            payload: Value::Int(42),
            handles: Vec::new(),
        };
        a.send(&envelope, &[]).expect("send envelope");

        let (got, fds) = b.recv().expect("recv envelope");
        assert_eq!(got, envelope);
        assert!(fds.is_empty());
    }

    #[test]
    fn round_trips_an_envelope_with_a_handle() {
        use abyss_msg::{Header, MessageKind, RawHandle, Value};

        // A file behind the handle, to prove the descriptor crossed with
        // the envelope.
        let mut path = std::env::temp_dir();
        path.push(format!("abyss-transport-env-{}", std::process::id()));
        File::create(&path)
            .expect("create temp file")
            .write_all(b"handle target")
            .expect("write temp file");
        let file = File::open(&path).expect("open temp file");

        let envelope = Envelope {
            header: Header {
                kind: MessageKind::Request,
                interface_id: 7,
                method_id: 4,
            },
            payload: Value::Handle(0),
            handles: vec![RawHandle {
                kind: 1,
                body: vec![0xAB, 0xCD],
            }],
        };
        let (a, b) = MessageChannel::pair().expect("socketpair");
        a.send(&envelope, &[file.as_fd()]).expect("send envelope");

        let (got, mut fds) = b.recv().expect("recv envelope");
        assert_eq!(got, envelope);
        assert_eq!(fds.len(), 1);

        let mut received = File::from(fds.pop().expect("one fd"));
        received.seek(SeekFrom::Start(0)).expect("seek");
        let mut content = String::new();
        received.read_to_string(&mut content).expect("read");
        assert_eq!(content, "handle target");

        let _ = std::fs::remove_file(&path);
    }
}
