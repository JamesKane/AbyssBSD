//! WifiKey.swift: a WPA passphrase turned into the key WPA uses, before it
//! leaves the pane (PHASE14 P14.5).
//!
//! WPA-PSK's pre-shared key is PBKDF2-HMAC-SHA1(passphrase, ssid, 4096, 32
//! bytes): exactly what `wpa_passphrase(8)` prints as `psk=`. Computing it
//! here means the passphrase itself **never crosses the control plane and
//! never reaches a file**: the plan, the helper's journal and
//! wpa_supplicant.conf all carry only the derived key, as the installer's
//! plan carries only a password hash (P5.4).
//!
//! The crate depends on nothing, so SHA-1 is here too, in a few dozen lines,
//! and checked against IEEE 802.11i's own test vectors.

/// The 64-hex-digit PSK for `passphrase` on `ssid`, or None when the
/// passphrase is not one WPA accepts (8 to 63 printable ASCII characters).
pub fn psk(passphrase: &str, ssid: &str) -> Option<String> {
    let p = passphrase.as_bytes();
    if !(8..=63).contains(&p.len()) || !p.iter().all(|&b| (0x20..0x7f).contains(&b)) || ssid.is_empty() {
        return None;
    }
    Some(hex(&pbkdf2_sha1(p, ssid.as_bytes(), 4096, 32)))
}

/// Whether `s` is a PSK in the form wpa_supplicant.conf takes: 64 lower-case
/// hex digits.
pub fn is_psk(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// MARK: PBKDF2-HMAC-SHA1 (RFC 8018), HMAC (RFC 2104), SHA-1 (FIPS 180-4)

pub(crate) fn pbkdf2_sha1(password: &[u8], salt: &[u8], iterations: u32, length: usize) -> Vec<u8> {
    let mut out = Vec::new();
    let mut block: u32 = 1;
    while out.len() < length {
        let mut u = hmac_sha1(password, &[salt, &block.to_be_bytes()].concat());
        let mut t = u;
        for _ in 1..iterations {
            u = hmac_sha1(password, &u);
            for (ti, ui) in t.iter_mut().zip(u) {
                *ti ^= ui;
            }
        }
        out.extend_from_slice(&t);
        block += 1;
    }
    out.truncate(length);
    out
}

pub(crate) fn hmac_sha1(key: &[u8], message: &[u8]) -> [u8; 20] {
    let mut k = if key.len() > 64 { sha1(key).to_vec() } else { key.to_vec() };
    k.resize(64, 0);
    let inner: Vec<u8> = k.iter().map(|b| b ^ 0x36).chain(message.iter().copied()).collect();
    let outer: Vec<u8> = k.iter().map(|b| b ^ 0x5c).chain(sha1(&inner)).collect();
    sha1(&outer)
}

pub(crate) fn sha1(message: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let mut m = message.to_vec();
    let bit_length = (message.len() as u64) * 8;
    m.push(0x80);
    while m.len() % 64 != 56 {
        m.push(0);
    }
    m.extend_from_slice(&bit_length.to_be_bytes());
    let mut w = [0u32; 80];
    for chunk in m.as_chunks::<64>().0 {
        for (i, word) in chunk.as_chunks::<4>().0.iter().enumerate() {
            w[i] = u32::from_be_bytes(*word);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..20 => ((b & c) | (!b & d), 0x5A827999),
                20..40 => (b ^ c ^ d, 0x6ED9EBA1),
                40..60 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let t = a.rotate_left(5).wrapping_add(f).wrapping_add(e).wrapping_add(k).wrapping_add(*wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = t;
        }
        for (hi, x) in h.iter_mut().zip([a, b, c, d, e]) {
            *hi = hi.wrapping_add(x);
        }
    }
    let mut out = [0u8; 20];
    for (o, v) in out.as_chunks_mut::<4>().0.iter_mut().zip(h) {
        o.copy_from_slice(&v.to_be_bytes());
    }
    out
}
