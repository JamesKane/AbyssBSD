// SPDX-License-Identifier: BSD-2-Clause

//! Component supervision — compiled only on FreeBSD.
//!
//! The broker keeps every component it spawned alive: when one exits, the
//! [`Supervisor`] spawns it again (`docs/design/broker-and-transport.md`
//! §5.5). The exit is learned from the component's process descriptor
//! through the kqueue reactor — no `SIGCHLD`, no pid races.
//!
//! This module restarts the *process*. Re-wiring the components that were
//! talking to a restarted peer — the `PeerRestarted` signal — is the next
//! layer.

use std::io;
use std::os::fd::{AsRawFd, RawFd};
use std::path::PathBuf;

use abyss_msg::Envelope;
use abyss_transport::{Event, Interest, Reactor};
use freebsd_jail_sys::remove;

use crate::spawn::{Component, spawn_component};

/// How to spawn — and respawn — a component: its identity and its bundle.
pub struct ComponentSpec {
    /// The component's name; also names its jail.
    pub name: String,
    /// The component binary.
    pub program: PathBuf,
    /// The argument vector after `argv[0]`.
    pub args: Vec<String>,
    /// The bootstrap bundle handed to the component on every (re)spawn.
    pub bundle: Envelope,
}

/// One supervised component: how to spawn it, and its current live process.
struct Supervised {
    spec: ComponentSpec,
    component: Component,
}

/// Keeps a set of components alive: a component that exits is spawned again.
pub struct Supervisor {
    reactor: Reactor,
    components: Vec<Supervised>,
}

impl Supervisor {
    /// A supervisor with nothing yet under it.
    pub fn new() -> io::Result<Supervisor> {
        Ok(Supervisor {
            reactor: Reactor::new()?,
            components: Vec::new(),
        })
    }

    /// Spawn `spec` and keep it alive — restart it whenever it exits.
    pub fn supervise(&mut self, spec: ComponentSpec) -> io::Result<()> {
        let component = start(&spec)?;
        self.reactor
            .register(component.descriptor(), Interest::ProcessExit)?;
        self.components.push(Supervised { spec, component });
        Ok(())
    }

    /// The live process of a supervised component, by name.
    pub fn component(&self, name: &str) -> Option<&Component> {
        self.components
            .iter()
            .find(|supervised| supervised.spec.name == name)
            .map(|supervised| &supervised.component)
    }

    /// Wait for one or more supervised components to exit, spawn each
    /// afresh, and return their names. Blocks until at least one exits.
    pub fn step(&mut self) -> io::Result<Vec<String>> {
        loop {
            let events = self.reactor.wait(None)?;
            let exited: Vec<RawFd> = events
                .iter()
                .filter_map(|event| match event {
                    Event::ProcessExited(fd) => Some(*fd),
                    _ => None,
                })
                .collect();
            if exited.is_empty() {
                // A wake with no process-exit event — keep waiting.
                continue;
            }
            let mut restarted = Vec::with_capacity(exited.len());
            for fd in exited {
                restarted.push(self.restart(fd)?);
            }
            return Ok(restarted);
        }
    }

    /// Restart the component whose process descriptor is `pd_fd`.
    fn restart(&mut self, pd_fd: RawFd) -> io::Result<String> {
        let idx = self
            .components
            .iter()
            .position(|supervised| supervised.component.descriptor().as_raw_fd() == pd_fd)
            .ok_or_else(|| io::Error::other("process-exit event for an unknown component"))?;

        // Reclaim the dead component's jail — the replacement reuses its
        // name — then spawn the component afresh and watch the new process.
        remove(self.components[idx].component.jid())?;
        let fresh = start(&self.components[idx].spec)?;
        self.reactor
            .register(fresh.descriptor(), Interest::ProcessExit)?;
        self.components[idx].component = fresh;
        Ok(self.components[idx].spec.name.clone())
    }
}

impl Drop for Supervisor {
    fn drop(&mut self) {
        // Tear down every component's jail, which kills the process.
        for supervised in &self.components {
            let _ = remove(supervised.component.jid());
        }
    }
}

/// Spawn the component described by `spec`.
fn start(spec: &ComponentSpec) -> io::Result<Component> {
    let args: Vec<&str> = spec.args.iter().map(String::as_str).collect();
    spawn_component(&spec.name, &spec.program, &args, &spec.bundle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use abyss_msg::{Header, MessageKind, Value};

    fn test_bundle() -> Envelope {
        Envelope {
            header: Header {
                kind: MessageKind::Event,
                interface_id: 0,
                method_id: 0,
            },
            payload: Value::Int(0),
            handles: Vec::new(),
        }
    }

    #[test]
    fn a_failed_component_is_restarted() {
        let name = format!("sup-test-{}", std::process::id());
        let spec = ComponentSpec {
            name: name.clone(),
            program: PathBuf::from("/bin/sh"),
            // Lives just long enough to be registered, then exits — the
            // supervisor should spawn it again.
            args: vec!["-c".to_owned(), "sleep 0.5".to_owned()],
            bundle: test_bundle(),
        };

        let mut supervisor = Supervisor::new().expect("supervisor");
        supervisor.supervise(spec).expect("supervise the component");

        let first = supervisor
            .component(&name)
            .expect("the component is live")
            .pid();
        let restarted = supervisor.step().expect("supervise one exit");
        let second = supervisor
            .component(&name)
            .expect("the component is live again")
            .pid();

        assert_eq!(restarted, vec![name]);
        assert_ne!(
            first, second,
            "the component was restarted as a fresh process",
        );
    }
}
