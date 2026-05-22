// SPDX-License-Identifier: BSD-2-Clause

//! `#[derive(Wire)]` integration tests — derived types round-trip and
//! fail as specified (`docs/design/wire-format.md` §7).

use abyss_msg::{HandleSink, HandleStore, MessageKind, Method, Request, Value, Wire, WireError};
use abyss_msg_derive::{Method, Request, Wire};

/// Round-trip a typed value through its derived `Wire` impl.
fn roundtrip<T: Wire + PartialEq + std::fmt::Debug + Clone>(value: T) -> T {
    let mut sink = HandleSink::new();
    let encoded = value.to_wire(&mut sink);
    let (handles, fds) = sink.into_parts();
    let mut store = HandleStore::new(handles, fds).expect("handle/fd counts match");
    T::from_wire(&encoded, &mut store).expect("decode")
}

fn encode<T: Wire>(value: &T) -> Value {
    value.to_wire(&mut HandleSink::new())
}

fn decode<T: Wire>(value: &Value) -> Result<T, WireError> {
    T::from_wire(
        value,
        &mut HandleStore::new(vec![], vec![]).expect("an empty store"),
    )
}

#[derive(Wire, Debug, Clone, PartialEq)]
struct Simple {
    a: i64,
    b: String,
    ok: bool,
}

#[derive(Wire, Debug, Clone, PartialEq)]
struct WithOption {
    name: String,
    note: Option<String>,
    count: Option<i64>,
}

#[derive(Wire, Debug, Clone, PartialEq)]
struct Nested {
    inner: Simple,
    list: Vec<i64>,
}

#[derive(Wire, Debug, Clone, PartialEq)]
#[wire(rename_all = "kebab-case")]
struct Renamed {
    repeat_rate: i64,
    #[wire(rename = "layout")]
    kbd_layout: String,
}

#[derive(Wire, Debug, Clone, PartialEq)]
enum Shape {
    Dot,
    Line(i64),
    Seg(i64, i64),
    Rect { w: i64, h: i64 },
}

#[derive(Wire, Debug, Clone, PartialEq)]
#[wire(rename_all = "kebab-case")]
enum ErrorCode {
    UnknownKey,
    TypeMismatch,
    OutOfScope,
}

#[test]
fn struct_roundtrip() {
    let value = Simple {
        a: 7,
        b: "x".to_owned(),
        ok: true,
    };
    assert_eq!(roundtrip(value.clone()), value);
}

#[test]
fn option_fields_roundtrip() {
    for value in [
        WithOption {
            name: "a".to_owned(),
            note: None,
            count: None,
        },
        WithOption {
            name: "a".to_owned(),
            note: Some("hi".to_owned()),
            count: Some(3),
        },
    ] {
        assert_eq!(roundtrip(value.clone()), value);
    }
}

#[test]
fn absent_option_is_omitted_from_the_dict() {
    let value = WithOption {
        name: "a".to_owned(),
        note: None,
        count: None,
    };
    let Value::Dict(entries) = encode(&value) else {
        panic!("struct must encode as a dict");
    };
    let keys: Vec<_> = entries.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(
        keys,
        ["name"],
        "None fields are omitted, not encoded as null"
    );
}

#[test]
fn nested_roundtrip() {
    let value = Nested {
        inner: Simple {
            a: 1,
            b: "y".to_owned(),
            ok: false,
        },
        list: vec![1, 2, 3],
    };
    assert_eq!(roundtrip(value.clone()), value);
}

#[test]
fn rename_attributes_set_the_wire_names() {
    let value = Renamed {
        repeat_rate: 30,
        kbd_layout: "dvorak".to_owned(),
    };
    let Value::Dict(entries) = encode(&value) else {
        panic!("expected a dict");
    };
    let keys: Vec<_> = entries.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(keys, ["repeat-rate", "layout"]);
    assert_eq!(roundtrip(value.clone()), value);
}

#[test]
fn enum_variants_roundtrip() {
    for value in [
        Shape::Dot,
        Shape::Line(3),
        Shape::Seg(1, 2),
        Shape::Rect { w: 4, h: 5 },
    ] {
        assert_eq!(roundtrip(value.clone()), value);
    }
}

#[test]
fn enum_encodes_as_a_variant() {
    assert_eq!(
        encode(&ErrorCode::UnknownKey),
        Value::Variant {
            tag: "unknown-key".to_owned(),
            value: None
        }
    );
    assert_eq!(roundtrip(ErrorCode::OutOfScope), ErrorCode::OutOfScope);
}

#[test]
fn missing_required_field_is_an_error() {
    let dict = Value::Dict(vec![("a".to_owned(), Value::Int(1))]); // b, ok absent
    assert_eq!(decode::<Simple>(&dict), Err(WireError::MissingField("b")));
}

#[test]
fn unknown_variant_is_an_error() {
    let value = Value::Variant {
        tag: "Hexagon".to_owned(),
        value: None,
    };
    assert_eq!(
        decode::<Shape>(&value),
        Err(WireError::UnknownVariant("Hexagon".to_owned()))
    );
}

#[test]
fn unknown_fields_are_ignored() {
    // forward compatibility: a newer sender's extra field is skipped
    let dict = Value::Dict(vec![
        ("a".to_owned(), Value::Int(1)),
        ("b".to_owned(), Value::Str("x".to_owned())),
        ("ok".to_owned(), Value::Bool(true)),
        ("added_in_v2".to_owned(), Value::Int(999)),
    ]);
    assert_eq!(
        decode::<Simple>(&dict),
        Ok(Simple {
            a: 1,
            b: "x".to_owned(),
            ok: true
        })
    );
}

#[test]
fn wrong_type_for_a_field_is_an_error() {
    let dict = Value::Dict(vec![
        ("a".to_owned(), Value::Str("not an int".to_owned())),
        ("b".to_owned(), Value::Str("x".to_owned())),
        ("ok".to_owned(), Value::Bool(true)),
    ]);
    assert!(matches!(
        decode::<Simple>(&dict),
        Err(WireError::TypeMismatch {
            expected: "int",
            ..
        })
    ));
}

#[test]
fn wrong_shape_entirely_is_an_error() {
    assert!(matches!(
        decode::<Simple>(&Value::Int(0)),
        Err(WireError::TypeMismatch {
            expected: "dict",
            ..
        })
    ));
    assert!(matches!(
        decode::<Shape>(&Value::Int(0)),
        Err(WireError::TypeMismatch {
            expected: "variant",
            ..
        })
    ));
}

/// An interface's message enum — requests, commands, and events. A real
/// message type derives both: `Wire` for the payload, `Method` for the
/// routing identity (§2.9).
#[derive(Method, Wire)]
enum Op {
    #[request]
    Connect(i64),
    #[command]
    SetTitle { title: String },
    #[event]
    Closed,
    #[request]
    Ping,
}

#[test]
fn derived_method_assigns_ordinals_by_declaration_and_kinds_by_attribute() {
    assert_eq!(Op::Connect(0).method_id(), 0);
    assert_eq!(Op::Connect(0).kind(), MessageKind::Request);

    let set_title = Op::SetTitle {
        title: String::new(),
    };
    assert_eq!(set_title.method_id(), 1);
    assert_eq!(set_title.kind(), MessageKind::Command);

    assert_eq!(Op::Closed.method_id(), 2);
    assert_eq!(Op::Closed.kind(), MessageKind::Event);

    assert_eq!(Op::Ping.method_id(), 3);
    assert_eq!(Op::Ping.kind(), MessageKind::Request);
}

#[derive(Wire, Debug, PartialEq)]
struct Open {
    path: String,
}

#[derive(Wire, Debug, PartialEq)]
struct Opened {
    handle: i64,
}

#[derive(Wire)]
struct Note {
    text: String,
}

/// A §2.10-conformant message enum: every variant a single-field tuple
/// wrapping its payload type.
#[derive(Wire, Method, Request)]
enum FileIface {
    #[request(reply = Opened)]
    Open(Open),
    #[command]
    Note(Note),
}

#[test]
fn derived_request_links_payloads_to_the_enum_and_their_reply_types() {
    // `From<payload>` for the message enum — every variant.
    assert!(matches!(
        FileIface::from(Open {
            path: String::new()
        }),
        FileIface::Open(_)
    ));
    assert!(matches!(
        FileIface::from(Note {
            text: String::new()
        }),
        FileIface::Note(_)
    ));

    // `Request::Reply` — an `Open` request is answered with `Opened`. A
    // wrong reply type would not type-check here.
    let reply: <Open as Request>::Reply = Opened { handle: 3 };
    assert_eq!(reply, Opened { handle: 3 });
}
