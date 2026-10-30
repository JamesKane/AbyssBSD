//! Service.swift: an application publishing its vocabulary.
//!
//! The application implements [`MenuProvider`] (its model, and how to
//! validate and perform one command), folds [`MenuService::fd`] into its run
//! loop, and calls [`MenuService::service_readable`] when it fires, handing
//! itself in. That is `NotifyCenter`'s shape (HANDOFF §2.18): no thread, no
//! second loop, and a request is answered between frames like any other
//! input. (Swift holds the provider weakly and answers "the application has
//! gone" once it is; here the application lends itself for each call, so it
//! cannot be gone.)
//!
//! What the service checks so that no application has to: that the verb
//! exists, that the arguments are the ones the verb declares and parse as
//! their types, and that the command is enabled. A script calling a disabled
//! command is told *why*, in the same words the menu would have used, and the
//! application's own `menu_perform` is never reached with something it did
//! not ask for.

use crate::{wire, Error};
use current_ipc::{receive, send, Msg, Server};
use menu_model::{ArgumentType, Command, CommandResult, Enablement, MenuBarModel};
use std::collections::{BTreeMap, HashSet};
use std::os::fd::RawFd;
use std::os::unix::net::UnixStream;

pub trait MenuProvider {
    /// The vocabulary. May change; call [`MenuService::changed`] when it
    /// does.
    fn menu_model(&self) -> MenuBarModel;
    /// Whether `command` can run now, and why not.
    fn menu_validate(&self, command: &Command) -> Enablement;
    /// Run it. Only ever called for an enabled command whose arguments
    /// passed [`MenuService::check`].
    fn menu_perform(&mut self, command: &Command, arguments: &BTreeMap<String, String>) -> CommandResult;
}

pub struct MenuService {
    pub name: String,
    server: Server,
    /// Connections that asked to be told when the vocabulary changes.
    subscribers: Vec<UnixStream>,
}

impl MenuService {
    /// Publish under `name` in the runtime directory
    /// ([`service_name`](crate::service_name)).
    pub fn new(name: &str) -> Result<MenuService, Error> {
        MenuService::with_server(name, Server::new(name)?)
    }

    /// Publish at an explicit socket path (the tests' scratch directories).
    pub fn bind(name: &str, path: &str) -> Result<MenuService, Error> {
        MenuService::with_server(name, Server::bind(path, 0o600)?)
    }

    fn with_server(name: &str, server: Server) -> Result<MenuService, Error> {
        server.set_nonblocking(true)?;
        Ok(MenuService { name: name.to_owned(), server, subscribers: Vec::new() })
    }

    /// The listening socket, for the application's run loop.
    pub fn fd(&self) -> RawFd {
        self.server.fd()
    }

    /// The listener is readable: answer one connection.
    pub fn service_readable(&mut self, provider: &mut dyn MenuProvider) {
        let Ok(c) = self.server.accept() else { return }; // EAGAIN: nothing after all
        // A menu request carries no descriptors; any that came close with it.
        let Ok(request) = receive(&c) else { return };
        if request.string("method") == Some("subscribe") {
            let mut ok = Msg::new();
            ok.set_bool("ok", true);
            // A subscriber that stops reading must not stall the
            // application once its socket buffer fills: a push that cannot
            // go in time drops it (Swift blocks: BACKLOG §5).
            let _ = c.set_write_timeout(Some(self.server.request_timeout));
            if send(&ok, &c).is_ok() {
                self.subscribers.push(c);
            }
            return;
        }
        let reply = MenuService::handle(&request, provider);
        let _ = send(&reply, &c);
    }

    /// The vocabulary changed: a title, an item, a menu. Pushed to every
    /// subscriber; one that has gone away is dropped here, which is the
    /// first moment anybody could know.
    pub fn changed(&mut self) {
        let mut m = Msg::new();
        m.set_string("method", "changed");
        self.subscribers.retain(|s| send(&m, s).is_ok());
    }

    pub fn subscriber_count(&self) -> usize {
        self.subscribers.len()
    }

    /// One request, one reply, with no socket (the tests drive it so).
    pub fn handle(request: &Msg, provider: &mut dyn MenuProvider) -> Msg {
        let model = provider.menu_model();
        match request.string("method") {
            Some("describe") => wire::describe_reply(&model, &|c| provider.menu_validate(c)),
            Some("validate") => wire::validate_reply(&model, &|c| provider.menu_validate(c)),
            Some("activate") => {
                let Some(verb) = request.string("verb") else {
                    return wire::error_reply("activate needs a verb");
                };
                let Some(command) = model.command(verb) else {
                    return refused(format!("{} has no verb {verb}", model.app_name));
                };
                let args = match wire::arguments(request) {
                    Ok(a) => a,
                    Err(e) => return refused(e.to_string()),
                };
                if let Some(why) = MenuService::check(command, &args) {
                    return refused(why);
                }
                if let Enablement::Disabled(why) = provider.menu_validate(command) {
                    return refused(why);
                }
                wire::result_reply(&provider.menu_perform(command, &args))
            }
            other => wire::error_reply(&format!("unknown method {}", other.unwrap_or("(none)"))),
        }
    }

    /// Why `args` are not what `command` declares, or None if they are.
    /// Every declared argument is required, and nothing undeclared is
    /// accepted: a misspelt name must fail, not be ignored.
    pub fn check(command: &Command, args: &BTreeMap<String, String>) -> Option<String> {
        let declared: HashSet<&str> = command.arguments.iter().map(|a| a.name.as_str()).collect();
        if let Some(extra) = args.keys().find(|k| !declared.contains(k.as_str())) {
            return Some(format!("{} takes no argument {extra}", command.verb));
        }
        for a in &command.arguments {
            let Some(v) = args.get(&a.name) else {
                return Some(format!("{} needs {} ({}): {}", command.verb, a.name, a.ty.as_str(), a.summary));
            };
            match a.ty {
                ArgumentType::String => {}
                ArgumentType::Path if !v.starts_with('/') => {
                    return Some(format!("{} must be an absolute path, not {v}", a.name));
                }
                ArgumentType::Integer if v.parse::<i64>().is_err() => {
                    return Some(format!("{} must be an integer, not {v}", a.name));
                }
                ArgumentType::Bool if v != "true" && v != "false" => {
                    return Some(format!("{} must be true or false, not {v}", a.name));
                }
                _ => {}
            }
        }
        None
    }
}

fn refused(why: String) -> Msg {
    wire::result_reply(&CommandResult::Refused(why))
}
