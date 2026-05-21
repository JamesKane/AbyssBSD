// SPDX-License-Identifier: BSD-2-Clause

//! Component spawn — compiled only on FreeBSD.
//!
//! [`spawn_component`] is where the broker brings a component into being
//! (`docs/design/broker-and-transport.md` §5.3): it creates the
//! component's jail, opens the bootstrap channel, `pdfork`s the component
//! into that jail holding the channel as fd 3, and sends the bootstrap
//! bundle over it. The returned [`Component`] keeps the process descriptor
//! and the broker's end of the bootstrap channel.

use std::io;
use std::os::fd::AsFd;
use std::path::Path;

use abyss_msg::Envelope;
use abyss_transport::MessageChannel;
use freebsd_jail_sys::{JailSpec, remove};
use freebsd_procdesc_sys::{Child, SpawnOptions, spawn};

/// A component the broker has spawned.
///
/// It holds the component's process descriptor — `wait`-able, and the lever
/// supervision pulls (§5.5) — and the broker's end of the bootstrap channel.
pub struct Component {
    child: Child,
    bootstrap: MessageChannel,
    jid: i32,
}

impl Component {
    /// The component's process id.
    pub fn pid(&self) -> i32 {
        self.child.pid()
    }

    /// The broker's end of the bootstrap channel.
    pub fn bootstrap(&self) -> &MessageChannel {
        &self.bootstrap
    }

    /// Block until the component process exits.
    pub fn wait(&self) -> io::Result<()> {
        self.child.wait()
    }

    /// Tear the component down: remove its jail, which kills the process.
    pub fn shutdown(self) -> io::Result<()> {
        remove(self.jid)
    }
}

/// Spawn `program` as the component `name`: create its jail, hand it the
/// bootstrap channel as fd 3, and send it `bundle`.
///
/// `args` is the argument vector after `argv[0]`.
pub fn spawn_component(
    name: &str,
    program: &Path,
    args: &[&str],
    bundle: &Envelope,
) -> io::Result<Component> {
    // The component's jail. `path = "/"` until the broker stages a root
    // filesystem per component (§5.3); the process confinement is real
    // regardless.
    // A `.` in a jail name is the hierarchical-jail separator, so the
    // component name is joined with a `-`.
    let spec = JailSpec::new(Path::new("/"), &format!("abyss-{name}"))?;
    let jid = spec.create()?;

    // The bootstrap channel: the broker keeps one end; the component is
    // execed holding the other as fd 3.
    let (broker_end, child_end) = MessageChannel::pair()?;

    let child = spawn(
        program,
        args,
        &SpawnOptions {
            jail: Some(jid),
            bootstrap_fd: Some(child_end.as_fd()),
        },
    )
    .inspect_err(|_| {
        // The jail would otherwise persist with nothing in it.
        let _ = remove(jid);
    })?;
    // The component holds fd 3 now; the broker's copy of that end is spent.
    drop(child_end);

    // Hand the component its bootstrap bundle.
    if let Err(err) = broker_end.send(bundle, &[]) {
        let _ = remove(jid);
        return Err(err);
    }

    Ok(Component {
        child,
        bootstrap: broker_end,
        jid,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use abyss_msg::{Header, MessageKind, Value};
    use std::fs;

    #[test]
    fn spawn_component_delivers_the_bootstrap_bundle() {
        let marker = format!("/tmp/abyss-broker-spawn-{}", std::process::id());
        let log = format!("{marker}.log");
        let _ = fs::remove_file(&marker);
        let _ = fs::remove_file(&log);

        let bundle = Envelope {
            header: Header {
                kind: MessageKind::Event,
                interface_id: 7,
                method_id: 1,
            },
            payload: Value::Int(0xB007),
            handles: Vec::new(),
        };
        let encoded = bundle.encode();

        // The component reads its bootstrap datagram off fd 3; a single
        // SOCK_SEQPACKET read returns exactly one datagram, and asking for
        // the exact encoded length means `head` reads once and stops.
        let script = format!(
            "echo ran > {log}; head -c {} <&3 > {marker} 2>> {log}; echo done >> {log}",
            encoded.len()
        );
        let name = format!("spawn-test-{}", std::process::id());
        let component = spawn_component(&name, Path::new("/bin/sh"), &["-c", &script], &bundle)
            .expect("spawn the component");
        component.wait().expect("the component runs and exits");

        let log_contents = fs::read_to_string(&log).unwrap_or_else(|e| format!("<no log: {e}>"));
        let received = fs::read(&marker).unwrap_or_default();
        let _ = fs::remove_file(&marker);
        let _ = fs::remove_file(&log);
        component.shutdown().expect("remove the component jail");

        assert_eq!(
            Envelope::decode(&received).ok().as_ref(),
            Some(&bundle),
            "bundle not delivered ({} bytes received); component log: {log_contents:?}",
            received.len(),
        );
    }
}
