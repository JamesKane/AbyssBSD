//! The fetch bridge (Tests/ModelTests/FetchTests.swift): a host the person
//! allowed, never this computer's own, redirects asked about too, and
//! pages as text.

use super::*;
use std::cell::RefCell;
use std::rc::Rc;

fn page(status: u16, body: &str, kind: &str, location: Option<&str>) -> Response {
    let mut headers = vec![("Content-Type".to_owned(), kind.to_owned())];
    if let Some(l) = location {
        headers.push(("Location".into(), l.into()));
    }
    Response { status, reason: String::new(), headers, body: body.as_bytes().to_vec() }
}

fn public_dns(h: &str) -> Vec<String> {
    vec![if h == "home.lan" { "192.168.1.5" } else { "93.184.215.14" }.to_owned()]
}

fn no_log() -> Log {
    Box::new(|_, _| {})
}

#[test]
fn a_new_host_is_asked_about_first() {
    let got = Rc::new(RefCell::new(vec![]));
    let logged = Rc::new(RefCell::new(vec![]));
    let (g, l) = (got.clone(), logged.clone());
    let mut b = FetchBridge::new(
        false,
        public_dns,
        Box::new(move |u, _| {
            g.borrow_mut().push(u.text());
            Ok(page(200, "<p>hello</p>", "text/html", None))
        }),
        Box::new(move |k, _| l.borrow_mut().push(k.to_owned())),
    );
    let ask = Answer::Ask { host: "example.org".into(), url: "https://example.org/a".into() };
    assert_eq!(b.fetch("https://example.org/a"), ask);
    assert!(got.borrow().is_empty(), "nothing is fetched before the person answers");
    b.permit("example.org", false);
    assert_eq!(b.fetch("https://example.org/a"), ask, "Don't Allow is not remembered: asked again");
    b.permit("Example.ORG", true);
    assert_eq!(b.fetch("https://example.org/a"), Answer::Page { url: "https://example.org/a".into(), status: 200, text: "hello".into() });
    assert_eq!(*logged.borrow(), ["asked", "denied", "asked", "permitted", "fetched"]);
}

#[test]
fn this_computers_own_addresses_are_refused() {
    let resolve = |h: &str| if h == "localhost" { vec!["127.0.0.1".to_owned()] } else { public_dns(h) };
    let mut b = FetchBridge::new(false, resolve, Box::new(|_, _| panic!("fetched")), no_log());
    b.permit("localhost", true);
    b.permit("home.lan", true);
    let Answer::Refused(why) = b.fetch("http://localhost:631/") else { panic!("loopback reached") };
    assert!(why.contains("this computer's or a private network's (127.0.0.1)"), "{why}");
    assert!(matches!(b.fetch("http://home.lan/"), Answer::Refused(_)), "a private network reached");
    let mut test = FetchBridge::new(true, |_| vec!["127.0.0.1".into()], Box::new(|_, _| Ok(page(200, "ok", "text/plain", None))), no_log());
    test.permit("127.0.0.1", true);
    assert_eq!(test.fetch("http://127.0.0.1:9/"), Answer::Page { url: "http://127.0.0.1:9/".into(), status: 200, text: "ok".into() }, "a test may");
}

#[test]
fn a_redirect_to_a_new_host_is_asked_about_too() {
    let get: Get = Box::new(|u, _| Ok(if u.host == "a.org" { page(301, "", "text/html", Some("https://b.org/x")) } else { page(200, "B", "text/plain", None) }));
    let mut b = FetchBridge::new(false, public_dns, get, no_log());
    b.permit("a.org", true);
    assert_eq!(b.fetch("https://a.org/"), Answer::Ask { host: "b.org".into(), url: "https://b.org/x".into() });
    b.permit("b.org", true);
    assert_eq!(b.fetch("https://a.org/"), Answer::Page { url: "https://b.org/x".into(), status: 200, text: "B".into() });
}

/// DNS rebinding: the bridge connects to the address it checked, and looks
/// the host up once; a second answer cannot slip in a local one.
#[test]
fn it_connects_to_the_address_it_checked() {
    let lookups = Rc::new(RefCell::new(0));
    let connected = Rc::new(RefCell::new(vec![]));
    let (n, c) = (lookups.clone(), connected.clone());
    let rebinding = move |_: &str| {
        *n.borrow_mut() += 1;
        vec![if *n.borrow() == 1 { "93.184.215.14" } else { "127.0.0.1" }.to_owned()]
    };
    let get: Get = Box::new(move |_, address| {
        c.borrow_mut().push(address.map(str::to_owned));
        Ok(page(200, "ok", "text/plain", None))
    });
    let mut b = FetchBridge::new(false, rebinding, get, no_log());
    b.permit("example.org", true);
    assert_eq!(b.fetch("https://example.org/"), Answer::Page { url: "https://example.org/".into(), status: 200, text: "ok".into() });
    assert_eq!(*lookups.borrow(), 1, "one look-up");
    assert_eq!(*connected.borrow(), [Some("93.184.215.14".to_owned())], "the address that was checked");
}

#[test]
fn redirects_end() {
    let mut b = FetchBridge::new(false, public_dns, Box::new(|_, _| Ok(page(302, "", "text/html", Some("/again")))), no_log());
    b.permit("a.org", true);
    assert_eq!(b.fetch("https://a.org/"), Answer::Refused("too many redirects".into()));
    assert_eq!(b.fetch("ftp://a.org/"), Answer::Refused("not an http or https URL: ftp://a.org/".into()));
}

#[test]
fn a_page_is_its_words() {
    let html = "<html><head><title>T</title><style>p{}</style><script>alert(1)</script></head><body><h1>Head</h1><p>One &amp; two</p><p>  three\n   four </p></body></html>";
    assert_eq!(page_text(html, "text/html; charset=utf-8"), "T\nHead\nOne & two\nthree\nfour");
    assert_eq!(page_text("<b>raw</b>", "text/plain"), "<b>raw</b>");
    assert!(page_text(&"x".repeat(20000), "text/plain").ends_with("(cut at 16 KB)"));
}

#[test]
fn what_is_local() {
    for ip in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.2", "169.254.1.1", "0.0.0.0", "100.64.0.1", "::1", "fe80::1", "fd00::1", "::ffff:127.0.0.1", "not-an-ip"] {
        assert!(is_local(ip), "{ip}");
    }
    for ip in ["93.184.215.14", "172.32.0.1", "8.8.8.8", "2606:2800:220:1::1"] {
        assert!(!is_local(ip), "{ip}");
    }
}
