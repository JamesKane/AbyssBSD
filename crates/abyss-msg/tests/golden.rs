// SPDX-License-Identifier: BSD-2-Clause

//! Golden vectors: fixed values encode to exact, checked-in bytes. A diff
//! here is an accidental wire-format change (`docs/design/wire-format.md`
//! §10).

use abyss_msg::{Envelope, Header, MessageKind, Value};

#[test]
fn golden_scalars() {
    assert_eq!(Value::Bool(false).encode(), [0x01, 0x00]);
    assert_eq!(Value::Bool(true).encode(), [0x01, 0x01]);
    assert_eq!(Value::Int(1).encode(), [0x02, 1, 0, 0, 0, 0, 0, 0, 0]);
    assert_eq!(
        Value::Int(-1).encode(),
        [0x02, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    );
    // f64 1.0 = 0x3FF0000000000000, little-endian
    assert_eq!(
        Value::Float(1.0).encode(),
        [0x03, 0, 0, 0, 0, 0, 0, 0xf0, 0x3f]
    );
    assert_eq!(Value::Handle(7).encode(), [0x09, 7, 0, 0, 0]);
}

#[test]
fn golden_composites() {
    assert_eq!(
        Value::Str("hi".to_owned()).encode(),
        [0x04, 2, 0, 0, 0, b'h', b'i']
    );
    assert_eq!(Value::Bytes(vec![0xAA]).encode(), [0x05, 1, 0, 0, 0, 0xAA]);
    assert_eq!(
        Value::List(vec![Value::Bool(true)]).encode(),
        [0x06, 1, 0, 0, 0, 0x01, 0x01]
    );
    assert_eq!(
        Value::Dict(vec![("a".to_owned(), Value::Bool(false))]).encode(),
        [0x07, 1, 0, 0, 0, 1, 0, 0, 0, b'a', 0x01, 0x00]
    );
    assert_eq!(
        Value::Variant {
            tag: "X".to_owned(),
            value: None
        }
        .encode(),
        [0x08, 1, 0, 0, 0, b'X', 0x00]
    );
    assert_eq!(
        Value::Variant {
            tag: "X".to_owned(),
            value: Some(Box::new(Value::Bool(true)))
        }
        .encode(),
        [0x08, 1, 0, 0, 0, b'X', 0x01, 0x01, 0x01]
    );
}

#[test]
fn golden_envelope() {
    let env = Envelope {
        header: Header {
            kind: MessageKind::Command,
            interface_id: 0x11,
            method_id: 0x22,
        },
        payload: Value::Bool(true),
        handles: vec![],
    };
    assert_eq!(
        env.encode(),
        [
            0x01, // version
            0x02, // kind = Command
            0x00, 0x00, // flags (reserved)
            0x11, 0x00, 0x00, 0x00, // interface_id
            0x22, 0x00, // method_id
            0x00, 0x00, // handle_count
            0x02, 0x00, 0x00, 0x00, // payload_len
            0x01, 0x01, // payload: Bool(true)
        ]
    );
}

#[test]
fn golden_decode_side() {
    // the format is pinned from the decode direction too
    assert_eq!(
        Value::decode(&[0x02, 42, 0, 0, 0, 0, 0, 0, 0]),
        Ok(Value::Int(42))
    );
}
