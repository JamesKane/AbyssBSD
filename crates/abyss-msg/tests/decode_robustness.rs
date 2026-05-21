// SPDX-License-Identifier: BSD-2-Clause

//! Decoding untrusted input is total: random and malformed bytes always
//! yield `Ok` or `Err`, never a panic, hang, or over-allocation
//! (`docs/design/wire-format.md` §4, §10). A panic fails the test.

mod common;

use abyss_msg::{Envelope, Header, MAX_DEPTH, MessageKind, RawHandle, Value, WireError};
use common::{Rng, gen_value};

#[test]
fn decode_random_bytes_never_panics() {
    let mut rng = Rng(0xF0F0);
    for _ in 0..200_000 {
        let len = rng.below(48) as usize;
        let bytes: Vec<u8> = (0..len).map(|_| rng.below(256) as u8).collect();
        let _ = Value::decode(&bytes);
        let _ = Envelope::decode(&bytes);
    }
}

#[test]
fn decode_mutated_valid_never_panics() {
    let mut rng = Rng(0x0102_0304);
    for _ in 0..50_000 {
        let mut bytes = gen_value(&mut rng, 4).encode();
        if !bytes.is_empty() {
            let i = rng.below(bytes.len() as u32) as usize;
            bytes[i] ^= 1_u8 << rng.below(8);
        }
        let _ = Value::decode(&bytes);
        let _ = Envelope::decode(&bytes);
    }
}

#[test]
fn every_truncation_of_a_valid_value_is_an_error() {
    let mut rng = Rng(0x7777);
    for _ in 0..2_000 {
        let bytes = gen_value(&mut rng, 4).encode();
        for cut in 0..bytes.len() {
            assert!(
                Value::decode(&bytes[..cut]).is_err(),
                "a strict prefix decoded as complete"
            );
        }
    }
}

#[test]
fn specific_malformed_values() {
    assert_eq!(Value::decode(&[]), Err(WireError::Truncated));
    assert_eq!(Value::decode(&[0xFF]), Err(WireError::BadTag(0xFF)));
    assert_eq!(Value::decode(&[0x00]), Err(WireError::BadTag(0x00)));
    // a bool byte that is neither 0 nor 1
    assert_eq!(Value::decode(&[0x01, 0x02]), Err(WireError::BadBool(0x02)));
    // a complete value, then a stray byte
    assert_eq!(
        Value::decode(&[0x01, 0x01, 0x99]),
        Err(WireError::TrailingBytes)
    );
    // a string claiming one byte, which is not valid UTF-8
    assert_eq!(
        Value::decode(&[0x04, 0x01, 0, 0, 0, 0xFF]),
        Err(WireError::BadUtf8)
    );
    // a dict with the same key twice
    let dup = [
        0x07, 0x02, 0, 0, 0, // dict, count 2
        0x01, 0, 0, 0, b'a', 0x01, 0x01, // "a" -> bool true
        0x01, 0, 0, 0, b'a', 0x01, 0x00, // "a" -> bool false
    ];
    assert_eq!(
        Value::decode(&dup),
        Err(WireError::DuplicateKey("a".to_owned()))
    );
}

#[test]
fn deep_nesting_is_rejected() {
    // a list nested far past MAX_DEPTH — each level is tag + count(1)
    let mut bytes = Vec::new();
    for _ in 0..MAX_DEPTH + 5 {
        bytes.push(0x06);
        bytes.extend_from_slice(&1_u32.to_le_bytes());
    }
    bytes.extend_from_slice(&[0x01, 0x01]); // innermost: bool true
    assert_eq!(Value::decode(&bytes), Err(WireError::DepthExceeded));
}

#[test]
fn envelope_header_is_validated() {
    let env = Envelope {
        header: Header {
            kind: MessageKind::Command,
            interface_id: 1,
            method_id: 1,
        },
        payload: Value::Bool(true),
        handles: vec![],
    };
    let good = env.encode();
    assert!(Envelope::decode(&good).is_ok());

    let mut bad_version = good.clone();
    bad_version[0] = 9;
    assert_eq!(
        Envelope::decode(&bad_version),
        Err(WireError::BadVersion(9))
    );

    let mut bad_kind = good.clone();
    bad_kind[1] = 0;
    assert_eq!(Envelope::decode(&bad_kind), Err(WireError::BadKind(0)));

    let mut bad_flags = good.clone();
    bad_flags[2] = 1;
    assert_eq!(Envelope::decode(&bad_flags), Err(WireError::BadFlags(1)));

    assert_eq!(Envelope::decode(&good[..10]), Err(WireError::Truncated));
}

#[test]
fn envelope_rejects_dangling_handle_index() {
    // the payload references handle 0, but the handle table is empty
    let env = Envelope {
        header: Header {
            kind: MessageKind::Event,
            interface_id: 1,
            method_id: 1,
        },
        payload: Value::Handle(0),
        handles: vec![],
    };
    let bytes = env.encode();
    assert_eq!(
        Envelope::decode(&bytes),
        Err(WireError::BadHandleIndex { index: 0, count: 0 })
    );
}

#[test]
fn handle_store_take_is_move_once() {
    use abyss_msg::HandleStore;

    let mut store = HandleStore::new(vec![RawHandle {
        kind: 1,
        body: vec![7],
    }]);
    assert_eq!(
        store.take(0),
        Ok(RawHandle {
            kind: 1,
            body: vec![7]
        })
    );
    assert_eq!(store.take(0), Err(WireError::HandleTaken(0)));
    assert!(matches!(
        store.take(5),
        Err(WireError::BadHandleIndex { index: 5, .. })
    ));
}
