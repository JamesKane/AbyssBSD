// SPDX-License-Identifier: BSD-2-Clause

//! Round-trip tests: `decode(encode(x)) == x` for values, envelopes, and
//! typed `Wire` views (`docs/design/wire-format.md` §10).

mod common;

use abyss_msg::{
    Bytes, Envelope, HandleSink, HandleStore, Header, MessageKind, RawHandle, Value, Wire,
    WireError,
};
use common::{Rng, gen_value};

#[test]
fn value_roundtrip_explicit() {
    let cases = [
        Value::Bool(true),
        Value::Bool(false),
        Value::Int(0),
        Value::Int(i64::MIN),
        Value::Int(i64::MAX),
        Value::Float(0.0),
        Value::Float(-1.5),
        Value::Float(f64::INFINITY),
        Value::Str(String::new()),
        Value::Str("héllo, αβγ".to_owned()),
        Value::Bytes(vec![]),
        Value::Bytes(vec![0, 1, 255]),
        Value::List(vec![Value::Int(1), Value::Bool(true)]),
        Value::Dict(vec![
            ("a".to_owned(), Value::Int(1)),
            ("b".to_owned(), Value::Str("x".to_owned())),
        ]),
        Value::Variant {
            tag: "None".to_owned(),
            value: None,
        },
        Value::Variant {
            tag: "Some".to_owned(),
            value: Some(Box::new(Value::Int(9))),
        },
        Value::Handle(42),
    ];
    for case in cases {
        let bytes = case.encode();
        assert_eq!(
            Value::decode(&bytes),
            Ok(case.clone()),
            "roundtrip {case:?}"
        );
    }
}

#[test]
fn value_roundtrip_random() {
    let mut rng = Rng(0x5EED);
    for _ in 0..5_000 {
        let value = gen_value(&mut rng, 5);
        let bytes = value.encode();
        assert_eq!(
            Value::decode(&bytes),
            Ok(value.clone()),
            "roundtrip {value:?}"
        );
    }
}

#[test]
fn envelope_roundtrip() {
    let env = Envelope {
        header: Header {
            kind: MessageKind::Request,
            interface_id: 7,
            method_id: 3,
        },
        payload: Value::Dict(vec![("path".to_owned(), Value::Str("a.b".to_owned()))]),
        handles: vec![
            RawHandle {
                kind: 1,
                body: vec![0xDE, 0xAD],
            },
            RawHandle {
                kind: 2,
                body: vec![],
            },
        ],
    };
    let bytes = env.encode();
    assert_eq!(Envelope::decode(&bytes), Ok(env));
}

#[test]
fn envelope_roundtrip_with_handle_references() {
    let env = Envelope {
        header: Header {
            kind: MessageKind::Event,
            interface_id: 1,
            method_id: 1,
        },
        payload: Value::List(vec![Value::Handle(0), Value::Handle(1)]),
        handles: vec![
            RawHandle {
                kind: 1,
                body: vec![1],
            },
            RawHandle {
                kind: 2,
                body: vec![2, 3],
            },
        ],
    };
    let bytes = env.encode();
    assert_eq!(Envelope::decode(&bytes), Ok(env));
}

/// Round-trip a typed value through the `Wire` trait.
fn wire_roundtrip<T: Wire + PartialEq + std::fmt::Debug + Clone>(value: T) {
    let mut sink = HandleSink::new();
    let encoded = value.to_wire(&mut sink);
    let (handles, fds) = sink.into_parts();
    let mut store = HandleStore::new(handles, fds).expect("handle/fd counts match");
    assert_eq!(T::from_wire(&encoded, &mut store), Ok(value));
}

#[test]
fn handle_sink_collects_metadata_and_its_fd_together() {
    use std::os::fd::AsRawFd;

    let (reader, _writer) = std::io::pipe().expect("pipe");
    let fd_number = reader.as_raw_fd();

    let mut sink = HandleSink::new();
    let index = sink.push(
        RawHandle {
            kind: 1,
            body: vec![9],
        },
        reader.into(),
    );
    assert_eq!(index, 0);

    let (handles, fds) = sink.into_parts();
    let mut store = HandleStore::new(handles, fds).expect("handle/fd counts match");
    let (handle, fd) = store.take(0).expect("the capability is in the store");
    assert_eq!(
        handle,
        RawHandle {
            kind: 1,
            body: vec![9],
        },
    );
    assert_eq!(fd.as_raw_fd(), fd_number);
}

#[test]
fn handle_store_rejects_a_handle_fd_count_mismatch() {
    let mismatch = HandleStore::new(
        vec![RawHandle {
            kind: 1,
            body: vec![],
        }],
        vec![],
    );
    assert!(matches!(
        mismatch,
        Err(WireError::HandleFdMismatch { handles: 1, fds: 0 }),
    ));
}

#[test]
fn from_message_and_into_message_round_trip_a_payload() {
    let header = Header {
        kind: MessageKind::Event,
        interface_id: 4,
        method_id: 2,
    };
    let (envelope, fds) = Envelope::from_message(header, &1234_i64);
    assert!(fds.is_empty(), "an i64 payload carries no capabilities");
    assert_eq!(envelope.into_message::<i64>(fds), Ok(1234));
}

#[test]
fn wire_primitives_roundtrip() {
    wire_roundtrip(true);
    wire_roundtrip(false);
    wire_roundtrip(0_i64);
    wire_roundtrip(i64::MIN);
    wire_roundtrip(i64::MAX);
    wire_roundtrip(-128_i8);
    wire_roundtrip(i16::MIN);
    wire_roundtrip(i32::MAX);
    wire_roundtrip(0_u8);
    wire_roundtrip(u8::MAX);
    wire_roundtrip(u16::MAX);
    wire_roundtrip(u32::MAX);
    wire_roundtrip(3.5_f64);
    wire_roundtrip("abyss".to_owned());
    wire_roundtrip(Bytes(vec![1, 2, 3]));
    wire_roundtrip(vec![1_i64, 2, 3]);
    wire_roundtrip(vec!["a".to_owned(), "b".to_owned()]);
    wire_roundtrip(Value::Dict(vec![("k".to_owned(), Value::Int(1))]));
}

#[test]
fn narrow_int_out_of_range_is_rejected() {
    let mut store = HandleStore::new(vec![], vec![]).expect("an empty store");

    let too_big = Value::Int(i64::from(u32::MAX) + 1);
    assert!(matches!(
        u32::from_wire(&too_big, &mut store),
        Err(WireError::IntOutOfRange { .. })
    ));

    let negative = Value::Int(-1);
    assert!(matches!(
        u8::from_wire(&negative, &mut store),
        Err(WireError::IntOutOfRange { .. })
    ));
}

#[test]
fn wire_type_mismatch_is_rejected() {
    let mut store = HandleStore::new(vec![], vec![]).expect("an empty store");
    assert!(matches!(
        bool::from_wire(&Value::Int(1), &mut store),
        Err(WireError::TypeMismatch {
            expected: "bool",
            ..
        })
    ));
    assert!(matches!(
        String::from_wire(&Value::Bool(true), &mut store),
        Err(WireError::TypeMismatch {
            expected: "string",
            ..
        })
    ));
}
