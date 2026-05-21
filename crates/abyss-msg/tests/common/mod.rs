//! Shared test helpers — a deterministic PRNG and a `Value` generator.

#![allow(dead_code)]

use abyss_msg::Value;

/// SplitMix64 — a tiny deterministic PRNG. Deterministic so any failure
/// reproduces from its seed.
pub struct Rng(pub u64);

impl Rng {
    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A value in `0..n`.
    pub fn below(&mut self, n: u32) -> u32 {
        (self.next_u64() % u64::from(n)) as u32
    }

    pub fn coin(&mut self) -> bool {
        self.next_u64() & 1 == 1
    }
}

/// A random value. Composites recur only while `budget` allows, so depth
/// and breadth stay bounded. Floats are finite and integer-valued, so
/// round-trip equality holds under IEEE-754 (no `NaN`).
pub fn gen_value(rng: &mut Rng, budget: u32) -> Value {
    let kinds = if budget == 0 { 5 } else { 9 };
    match rng.below(kinds) {
        0 => Value::Bool(rng.coin()),
        1 => Value::Int(rng.next_u64() as i64),
        2 => Value::Float(f64::from(rng.next_u64() as i32)),
        3 => Value::Str(gen_string(rng)),
        4 => Value::Bytes((0..rng.below(6)).map(|_| rng.below(256) as u8).collect()),
        5 => Value::List(
            (0..rng.below(4))
                .map(|_| gen_value(rng, budget - 1))
                .collect(),
        ),
        6 => {
            let entries = (0..rng.below(4))
                .map(|i| (format!("k{i}"), gen_value(rng, budget - 1)))
                .collect();
            Value::Dict(entries)
        }
        7 => Value::Variant {
            tag: gen_string(rng),
            value: rng.coin().then(|| Box::new(gen_value(rng, budget - 1))),
        },
        _ => Value::Handle(rng.below(8)),
    }
}

fn gen_string(rng: &mut Rng) -> String {
    (0..rng.below(8))
        .map(|_| char::from(b'a' + rng.below(26) as u8))
        .collect()
}
