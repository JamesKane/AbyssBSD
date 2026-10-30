//! What the machine's network is doing, without privilege (Network.swift,
//! PHASE14 P14.4): the interfaces, their links and addresses, the default
//! router and the name servers, **as the kernel has them now**. Every read
//! is an ordinary user's, and so is the watch.

use abyss_sys::vents as sys;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Link {
    Up,
    Down,
    Unknown,
}

impl Link {
    pub fn as_str(self) -> &'static str {
        match self {
            Link::Up => "up",
            Link::Down => "down",
            Link::Unknown => "unknown",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Address {
    pub address: String,
    pub prefix: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Interface {
    pub name: String,
    pub up: bool,
    pub loopback: bool,
    pub link: Link,
    pub ipv4: Vec<Address>,
    /// `aa:bb:cc:dd:ee:ff`, or None when it has none.
    pub mac: Option<String>,
}

/// The default route: its gateway and interface.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Router {
    pub address: String,
    pub interface: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub interfaces: Vec<Interface>,
    pub router: Option<Router>,
    pub name_servers: Vec<String>,
}

/// Every interface, in the kernel's order, with its IPv4 addresses.
pub fn interfaces() -> Vec<Interface> {
    let mut order: Vec<(String, u32, Vec<Address>)> = vec![];
    for a in sys::ifaddrs() {
        let i = match order.iter().position(|(n, _, _)| *n == a.name) {
            Some(i) => i,
            None => {
                order.push((a.name.clone(), 0, vec![]));
                order.len() - 1
            }
        };
        order[i].1 |= a.flags;
        if let Some((addr, mask)) = a.ipv4 {
            order[i].2.push(Address { address: dotted(addr), prefix: mask.map_or(32, u32::count_ones) });
        }
    }
    order
        .into_iter()
        .map(|(name, flags, ipv4)| {
            let mac = sys::if_mac(&name).filter(|m| m.iter().any(|&b| b != 0)).map(|m| m.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(":"));
            let link = match sys::if_link(&name) {
                1 => Link::Up,
                0 => Link::Down,
                _ => Link::Unknown,
            };
            Interface { up: flags & sys::IFF_UP as u32 != 0, loopback: flags & sys::IFF_LOOPBACK as u32 != 0, link, ipv4, mac, name }
        })
        .collect()
}

/// The default route, or None for none.
pub fn default_router() -> Option<Router> {
    if cfg!(target_os = "linux") {
        parse_proc_route(&read_text("/proc/net/route")?)
    } else {
        let r = spawn::run_with(&["route", "-n", "get", "default"], spawn::Options { limit: 8192, ..Default::default() });
        if r.succeeded() { parse_route_get(&r.stdout_text()) } else { None }
    }
}

/// The resolver's name servers, in order.
pub fn name_servers(resolv_conf: &str) -> Vec<String> {
    parse_resolv_conf(&read_text(resolv_conf).unwrap_or_default())
}

pub fn status() -> Status {
    Status { interfaces: interfaces(), router: default_router(), name_servers: name_servers("/etc/resolv.conf") }
}

/// A descriptor readable when an interface, address or route changes: a
/// routing socket, or rtnetlink on Linux. `drain` it, then read `status`.
pub struct Watch(OwnedFd);

impl Watch {
    pub fn open() -> Option<Watch> {
        sys::route_watch_open().map(Watch)
    }

    pub fn fd(&self) -> BorrowedFd<'_> {
        self.0.as_fd()
    }

    /// Whether anything had changed.
    pub fn drain(&self) -> bool {
        sys::route_watch_drain(self.0.as_fd())
    }
}

// MARK: parsers (pure)

fn trim(s: &str) -> &str {
    s.trim_matches([' ', '\t'])
}

/// `route -n get default` (FreeBSD): its `gateway:` and `interface:`.
pub fn parse_route_get(text: &str) -> Option<Router> {
    let (mut gw, mut ifn) = (None, None);
    for line in text.split('\n') {
        let t = line.trim_start_matches(' ');
        if let Some(g) = t.strip_prefix("gateway:") {
            gw = Some(trim(g).to_owned());
        }
        if let Some(i) = t.strip_prefix("interface:") {
            ifn = Some(trim(i).to_owned());
        }
    }
    match (gw, ifn) {
        (Some(address), Some(interface)) if !address.is_empty() && !interface.is_empty() => Some(Router { address, interface }),
        _ => None,
    }
}

/// `/proc/net/route` (Linux): the row whose destination is 0, its gateway
/// in little-endian hex.
pub fn parse_proc_route(text: &str) -> Option<Router> {
    text.split('\n').filter(|l| !l.is_empty()).skip(1).find_map(|line| {
        let f: Vec<&str> = line.split([' ', '\t']).filter(|w| !w.is_empty()).collect();
        if f.len() < 3 || f[1] != "00000000" || !f[2].bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        let g = u32::from_str_radix(f[2], 16).ok().filter(|&g| g != 0)?;
        Some(Router { address: dotted(g.swap_bytes()), interface: f[0].to_owned() })
    })
}

/// `nameserver` lines, in order; comments and everything else ignored.
pub fn parse_resolv_conf(text: &str) -> Vec<String> {
    text.split('\n')
        .filter_map(|line| {
            let mut w = line.split([' ', '\t']).filter(|w| !w.is_empty());
            (w.next() == Some("nameserver")).then(|| w.next().map(str::to_owned)).flatten()
        })
        .collect()
}

pub(crate) fn dotted(v: u32) -> String {
    let [a, b, c, d] = v.to_be_bytes();
    format!("{a}.{b}.{c}.{d}")
}

fn read_text(path: &str) -> Option<String> {
    std::fs::read(path).ok().map(|b| String::from_utf8_lossy(&b).into_owned())
}
