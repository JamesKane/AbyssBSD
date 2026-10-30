//! DBusTests.swift, ported: the wire format's rules, without a bus. What is
//! not here is "does somebody else's D-Bus accept this": that is
//! `live-dbus.sh`, with GLib's `gdbus` on the other end, because a
//! marshaller tested against its own parser round-trips and is still wrong
//! (HANDOFF §2.37).

use super::*;

fn s(x: &str) -> Value {
    Value::String(x.into())
}

fn var(v: Value) -> Value {
    Value::Variant(Box::new(v))
}

fn marshal(v: &Value) -> Marshaller {
    let mut m = Marshaller::new(0);
    m.value(v).unwrap();
    m
}

fn read(bytes: &[u8], sig: &str) -> Result<Value, Error> {
    Unmarshaller::new(bytes, 0, true, &[]).value(sig)
}

// MARK: signatures

#[test]
fn signature_splitting_handles_nesting() {
    for (sig, want) in [
        ("sus", &["s", "u", "s"][..]),
        ("a{sv}", &["a{sv}"]),
        ("sa{sv}", &["s", "a{sv}"]),
        ("(si)", &["(si)"]),
        ("a(si)u", &["a(si)", "u"]),
        ("aas", &["aas"]),
        ("oa{sv}", &["o", "a{sv}"]),
        ("a{s(ua{sv})}x", &["a{s(ua{sv})}", "x"]),
        ("", &[]),
    ] {
        assert_eq!(split_signature(sig).unwrap(), want, "{sig}");
    }
}

/// Swift splits whatever it is given; these are not signatures.
#[test]
fn a_signature_that_is_not_one_is_refused() {
    for (sig, why) in [
        ("a", "array with no element type"),
        ("sa", "array with no element type"),
        ("(", "unbalanced signature"),
        ("(s", "unbalanced signature"),
        ("s)", "unbalanced signature"),
        ("()", "a struct with no fields"),
        ("a()", "a struct with no fields"),
        ("{s}", "dict entry needs exactly two types"),
        ("{sss}", "dict entry needs exactly two types"),
    ] {
        assert_eq!(split_signature(sig), Err(Error::new(why)), "{sig}");
    }
}

#[test]
fn values_report_the_signature_they_marshal_as() {
    assert_eq!(s("x").signature(), "s");
    assert_eq!(Value::ObjectPath("/a".into()).signature(), "o");
    assert_eq!(Value::UnixFd(3).signature(), "h");
    assert_eq!(Value::Array("s".into(), vec![s("a")]).signature(), "as");
    assert_eq!(Value::Struct(vec![s("a"), Value::UInt32(1)]).signature(), "(su)");
    assert_eq!(Value::options(vec![("k", Value::Bool(true))]).signature(), "a{sv}");
}

// MARK: alignment

/// **The rule the whole format turns on**: aligned from the MESSAGE's
/// start, not the buffer's.
#[test]
fn alignment_is_measured_from_the_message_origin_not_the_buffer() {
    let mut at_zero = Marshaller::new(0);
    at_zero.byte(1);
    at_zero.u32(0xAABBCCDD);
    assert_eq!(at_zero.bytes.len(), 8);
    let mut at_three = Marshaller::new(3);
    at_three.byte(1);
    at_three.u32(0xAABBCCDD);
    assert_eq!(at_three.bytes.len(), 5, "padding was computed from the buffer, not the message");
}

#[test]
fn eight_byte_types_align_to_eight() {
    let mut m = Marshaller::new(0);
    m.byte(1);
    m.u64(0x1122334455667788);
    assert_eq!(m.bytes.len(), 16);
    assert_eq!(m.bytes[1..8], [0; 7], "not zero-padded");
}

#[test]
fn a_double_is_its_bit_pattern_and_not_a_textual_approximation() {
    assert_eq!(marshal(&Value::Double(1.0)).bytes, [0, 0, 0, 0, 0, 0, 0xf0, 0x3f]);
    let neg = marshal(&Value::Double(-0.0)).bytes;
    assert_eq!(neg, [0, 0, 0, 0, 0, 0, 0, 0x80], "the sign bit was dropped");
    let Value::Double(z) = read(&neg, "d").unwrap() else { panic!("not a double") };
    assert!(z.is_sign_negative());
    let mut padded = Marshaller::new(0);
    padded.byte(1);
    padded.value(&Value::Double(1.0)).unwrap();
    assert_eq!(padded.bytes.len(), 16);
}

#[test]
fn string_bytes_are_exactly_what_the_spec_says() {
    assert_eq!(marshal(&s("abc")).bytes, [3, 0, 0, 0, 0x61, 0x62, 0x63, 0]);
}

#[test]
fn signature_length_is_a_byte_not_a_word() {
    assert_eq!(marshal(&Value::Signature("a{sv}".into())).bytes, [5, 0x61, 0x7b, 0x73, 0x76, 0x7d, 0]);
}

#[test]
fn array_length_excludes_the_padding_before_its_first_element() {
    let m = marshal(&Value::Array("t".into(), vec![Value::UInt64(1), Value::UInt64(2)]));
    assert_eq!(m.bytes.len(), 4 + 4 + 16);
    assert_eq!(m.bytes[0..4], [16, 0, 0, 0], "the declared length included the padding");
}

// MARK: round trips

fn round_trip(v: Value) {
    let m = marshal(&v);
    let mut u = Unmarshaller::new(&m.bytes, 0, true, &m.fds);
    assert_eq!(u.value(&v.signature()).unwrap(), v);
    assert_eq!(u.remaining(), 0, "trailing bytes");
}

#[test]
fn every_value_type_round_trips() {
    for v in [
        Value::Byte(0xFE),
        Value::Bool(true),
        Value::Bool(false),
        Value::UInt16(65535),
        Value::Int32(-42),
        Value::UInt32(4_000_000_000),
        Value::UInt64(0xDEADBEEFCAFEBABE),
        Value::Double(0.0),
        Value::Double(63.0 / 255.0),
        Value::Double(-1.797_693_134_862_315_7e308),
        s("hello"),
        s(""),
        s("ünïcödé ✓"),
        Value::ObjectPath("/org/freedesktop/portal/desktop".into()),
        Value::Signature("a{sv}".into()),
        Value::Array("s".into(), vec![s("a"), s("bb")]),
        Value::Array("s".into(), vec![]),
        Value::Struct(vec![s("x"), Value::UInt32(1)]),
        var(s("inner")),
        var(Value::Array("u".into(), vec![Value::UInt32(1), Value::UInt32(2)])),
        Value::UnixFd(9),
    ] {
        round_trip(v);
    }
}

#[test]
fn the_portal_options_dictionary_round_trips() {
    round_trip(Value::options(vec![
        ("handle_token", s("abyss1")),
        ("multiple", Value::Bool(false)),
        ("modal", Value::Bool(true)),
        ("count", Value::UInt32(3)),
    ]));
    round_trip(Value::options(vec![]));
}

// MARK: messages

#[test]
fn a_method_call_round_trips_through_the_wire() {
    let mut call = Message::method_call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.FileChooser",
        "OpenFile",
        vec![s(""), s("Open a file"), Value::options(vec![("multiple", Value::Bool(false))])],
    );
    call.serial = 7;
    let (bytes, fds) = call.encode().unwrap();
    assert!(fds.is_empty());
    assert_eq!(Message::framed_length(&bytes), Some(bytes.len()));
    let back = Message::decode(&bytes, &[]).unwrap();
    assert_eq!(back.signature(), "ssa{sv}");
    assert_eq!(back, call);
}

/// A descriptor travels out of band; the wire carries its INDEX.
#[test]
fn a_descriptor_is_marshalled_as_an_index_not_as_itself() {
    let m = Message { reply_serial: Some(3), body: vec![Value::UnixFd(77), Value::UnixFd(88)], ..Message::new(MessageType::MethodReturn) };
    let (bytes, fds) = m.encode().unwrap();
    assert_eq!(fds, [77, 88], "the descriptors must ride out of band");
    let back = Message::decode(&bytes, &[77, 88]).unwrap();
    assert_eq!(back.body, [Value::UnixFd(77), Value::UnixFd(88)]);
    assert_eq!(back.declared_fds, 2);
    // A decoded message encodes back to itself, descriptors once.
    assert_eq!(back.encode().unwrap(), (bytes.clone(), vec![77, 88]));
    assert_eq!(Message::decode(&bytes, &[77]), Err(Error::new("fd index 1 out of range")));
}

/// **A signal that answers one client must be addressed to it** (§2.40).
#[test]
fn an_addressed_signal_carries_a_destination_and_a_broadcast_does_not() {
    let mut addressed = Message::signal("/x", "i.f", "Sig", Some(":1.42"), vec![s("for you")]);
    addressed.serial = 3;
    let back = Message::decode(&addressed.encode().unwrap().0, &[]).unwrap();
    assert_eq!(back.destination.as_deref(), Some(":1.42"));
    let mut broadcast = Message::signal("/x", "i.f", "Sig", None, vec![s("for anyone")]);
    broadcast.serial = 4;
    assert_eq!(Message::decode(&broadcast.encode().unwrap().0, &[]).unwrap().destination, None);
}

#[test]
fn framing_reports_how_much_more_is_needed() {
    let mut m = Message::signal("/x", "i.f", "Sig", None, vec![s("payload")]);
    m.serial = 2;
    let (bytes, _) = m.encode().unwrap();
    assert_eq!(Message::framed_length(&bytes[..10]), None, "a partial prologue cannot be framed");
    assert_eq!(Message::framed_length(&bytes), Some(bytes.len()));
    assert_eq!(Message::framed_length(&[bytes.clone(), bytes.clone()].concat()), Some(bytes.len()));
}

#[test]
fn an_error_reply_carries_its_name_and_text() {
    let call = Message { serial: 11, sender: Some(":1.9".into()), ..Message::method_call("d", "/p", "i", "m", vec![]) };
    let back = Message::decode(&Message::error(&call, "org.freedesktop.DBus.Error.Failed", "no").encode().unwrap().0, &[]).unwrap();
    assert_eq!(back.kind, MessageType::Error);
    assert_eq!(back.error_name.as_deref(), Some("org.freedesktop.DBus.Error.Failed"));
    assert_eq!(back.reply_serial, Some(11));
    assert_eq!(back.destination.as_deref(), Some(":1.9"));
    assert_eq!(back.body, [s("no")]);
}

/// Big-endian messages are legal, and some peers send them: here is one,
/// written by hand (we only ever write little-endian).
#[test]
fn a_big_endian_message_is_read_correctly() {
    #[rustfmt::skip]
    let be: Vec<u8> = vec![
        b'B', 4, 0, 1,  0, 0, 0, 4,  0, 0, 0, 5,  0, 0, 0, 0x37,
        1, 1, b'o', 0,  0, 0, 0, 2,  b'/', b'x', 0, 0,  0, 0, 0, 0,
        2, 1, b's', 0,  0, 0, 0, 3,  b'i', b'.', b'f', 0,  0, 0, 0, 0,
        3, 1, b's', 0,  0, 0, 0, 1,  b'S', 0, 0, 0,  0, 0, 0, 0,
        8, 1, b'g', 0,  1, b'u', 0, 0,
        1, 2, 3, 4,
    ];
    let m = Message::decode(&be, &[]).unwrap();
    assert_eq!((m.serial, m.path.as_deref(), m.member.as_deref()), (5, Some("/x"), Some("S")));
    assert_eq!(m.body, [Value::UInt32(0x01020304)]);
    assert_eq!(Message::framed_length(&be), Some(be.len()));
    let mut bad = be.clone();
    bad[0] = b'?';
    assert_eq!(Message::decode(&bad, &[]), Err(Error::new("bad endianness byte")));
}

// MARK: addresses

#[test]
fn bus_address_parsing() {
    assert_eq!(parse_address("unix:path=/run/user/1000/bus"), Some(("/run/user/1000/bus".into(), false)));
    assert_eq!(parse_address("unix:abstract=/tmp/dbus-AbCdEf,guid=1234567890"), Some(("/tmp/dbus-AbCdEf".into(), true)));
    assert_eq!(parse_address("unix:path=/run/bus,guid=deadbeef"), Some(("/run/bus".into(), false)));
    assert_eq!(parse_address("tcp:host=localhost,port=1234"), None);
    assert_eq!(parse_address(""), None);
}

// MARK: refusals

#[test]
fn truncated_input_is_refused_rather_than_guessed() {
    let m = marshal(&s("hello"));
    for cut in 1..m.bytes.len() {
        assert!(read(&m.bytes[..cut], "s").is_err(), "a {cut}-byte string was accepted");
    }
}

#[test]
fn an_array_that_overruns_its_length_is_refused() {
    assert!(read(&[8, 0, 0, 0, 1, 0, 0, 0], "au").is_err());
}

#[test]
fn an_unknown_type_code_is_refused() {
    assert_eq!(read(&[0, 0, 0, 0], "Z"), Err(Error::new("unsupported type 'Z'")));
}

/// Swift loops for ever here: an array of `()` reads nothing per element.
#[test]
fn an_array_of_empty_structs_is_refused_not_spun_on() {
    assert_eq!(read(&[8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "a()"), Err(Error::new("a struct with no fields")));
}

/// Swift has no depth limit: variants nested deep enough run its stack out.
#[test]
fn values_nested_past_the_limit_are_refused() {
    let mut deep = Value::Byte(1);
    for _ in 0..MAX_DEPTH {
        deep = var(deep);
    }
    round_trip(deep.clone());
    let bytes = marshal(&var(deep)).bytes;
    assert_eq!(read(&bytes, "v"), Err(Error::new("values nested deeper than 64")));
    // Ten thousand of them, which is what a stack runs out on.
    let bomb: Vec<u8> = std::iter::repeat_n([1, b'v', 0], 10_000).flatten().collect();
    assert!(read(&bomb, "v").is_err());
}

/// A variant holds one complete type; Swift reads the first and ignores the
/// rest of the signature.
#[test]
fn a_variant_of_two_types_is_refused() {
    assert_eq!(read(&[2, b's', b's', 0], "v"), Err(Error::new("\"ss\" is not one type")));
}

/// What Swift traps on, or marshals as a lie, refused.
#[test]
fn a_value_that_cannot_be_marshalled_is_refused() {
    let mut m = Marshaller::new(0);
    assert_eq!(m.value(&Value::Signature("y".repeat(256))), Err(Error::new("a signature of 256 bytes (the most is 255)")));
    let mut wide = Value::Byte(0);
    for _ in 0..300 {
        wide = Value::Struct(vec![wide]);
    }
    assert!(Message { body: vec![wide], ..Message::new(MessageType::Signal) }.encode().is_err(), "a body signature past 255");
    assert_eq!(m.value(&Value::Array("s".into(), vec![Value::UInt32(1)])), Err(Error::new("an array of s holds a u")));
}
