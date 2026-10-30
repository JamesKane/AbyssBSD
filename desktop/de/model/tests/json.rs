//! The JSON half of ModelTests.swift, ported, and the grammar Swift is loose
//! about.

use model::Json;

fn parse(s: &str) -> Result<Json, model::ParseError> {
    Json::parse(s.as_bytes())
}

#[test]
fn json_round_trips_what_the_wire_carries() {
    let text = r#"{"model":"m","messages":[{"role":"user","content":"hi \"there\"\n"}],"tools":[{"type":"function","function":{"name":"menu.activate","parameters":{"type":"object"}}}],"temperature":0.2,"n":1,"stream":false,"x":null}"#;
    let j = parse(text).unwrap();
    assert_eq!(j.get("messages").and_then(|m| m.at(0)).and_then(|m| m.get("content")).and_then(Json::as_str), Some("hi \"there\"\n"));
    assert_eq!(j.get("temperature").and_then(Json::as_f64), Some(0.2));
    assert_eq!(j.get("n").and_then(Json::as_int), Some(1));
    assert_eq!(j.get("stream").and_then(Json::as_bool), Some(false));
    assert_eq!(j.get("x"), Some(&Json::Null));
    assert_eq!(j.text(), text, "keys keep their order; whole numbers have no fraction");
    assert_eq!(parse(&j.text()).unwrap(), j);
}

#[test]
fn json_escapes_and_unicode() {
    assert_eq!(parse(r#""\u00e9\ud83d\ude00\t\/""#).unwrap().as_str(), Some("é😀\t/"));
    assert_eq!(Json::String("a\u{1}b".into()).text(), r#""a\u0001b""#);
    let s = "😀 é \u{0} ";
    assert_eq!(parse(&Json::String(s.into()).text()).unwrap().as_str(), Some(s));
}

#[test]
fn json_refuses_what_is_not_json() {
    for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "\"\\x\"", "1 2", "\"a\nb\"", "\"\\ud800\"", "\"\\udc00\""] {
        assert!(parse(bad).is_err(), "{bad}");
    }
    let deep = "[".repeat(1000) + &"]".repeat(1000);
    assert_eq!(parse(&deep).unwrap_err().why, "nested too deep", "a hostile body cannot exhaust the stack");
    assert!(parse(&("[".repeat(127) + &"]".repeat(127))).is_ok());
}

/// Swift's `Double(_:)` and `UInt32(_:radix:)` take these; JSON does not.
#[test]
fn json_numbers_and_escapes_are_the_grammars() {
    for bad in ["+1", "01", "-01", ".5", "1.", "-", "1e", "1e+", "-.5", "\"\\u+abc\"", "\"\\u00g0\""] {
        assert!(parse(bad).is_err(), "{bad}");
    }
    for (good, n) in [("0", 0.0), ("-0", 0.0), ("10", 10.0), ("1.5", 1.5), ("-2e3", -2000.0), ("1E-2", 0.01), ("1e+2", 100.0)] {
        assert_eq!(parse(good).unwrap(), Json::Number(n), "{good}");
    }
}

#[test]
fn json_writes_numbers_as_swift_does() {
    for (n, text) in [
        (0.2, "0.2"),
        (-0.0, "0"),
        (42.0, "42"),
        (8.999e15, "8999000000000000"),
        (9e15, "9000000000000000.0"),
        (9_007_199_254_740_992.0, "9007199254740992.0"),
        (9_007_199_254_740_994.0, "9.007199254740994e+15"),
        (1e16, "1e+16"),
        (1e300, "1e+300"),
        (0.0001, "0.0001"),
        (0.00001, "1e-05"),
        (1.5e-7, "1.5e-07"),
        (f64::INFINITY, "null"),
        (f64::NAN, "null"),
    ] {
        assert_eq!(Json::Number(n).text(), text, "{n}");
    }
}

#[test]
fn json_setting_replaces_in_place() {
    let j = Json::Object(vec![("a".into(), Json::Number(1.0)), ("b".into(), Json::Number(2.0))]).setting("a", Json::String("x".into())).setting("c", Json::Null);
    assert_eq!(j.text(), r#"{"a":"x","b":2,"c":null}"#);
    assert_eq!(parse(r#"{"a":1,"a":2}"#).unwrap().get("a"), Some(&Json::Number(2.0)), "the last of a key given twice");
}
