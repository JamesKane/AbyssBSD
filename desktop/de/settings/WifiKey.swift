// WifiKey — a WPA passphrase turned into the key WPA uses, before it leaves
// the pane (PHASE14 P14.5).
//
// WPA-PSK's pre-shared key is PBKDF2-HMAC-SHA1(passphrase, ssid, 4096, 32
// bytes) — exactly what `wpa_passphrase(8)` prints as `psk=`. Computing it
// here means the passphrase itself **never crosses the control plane and never
// reaches a file**: the plan, the helper's journal and wpa_supplicant.conf all
// carry only the derived key, as the installer's plan carries only a password
// hash (P5.4). The key still joins the network — it is the secret that
// matters to WPA — but a person's passphrase, often reused, is not kept.
//
// `Settings` imports nothing, so SHA-1 is here too, in a few dozen lines, and
// checked against IEEE 802.11i's own test vectors.

public enum WifiKey {
    /// The 64-hex-digit PSK for `passphrase` on `ssid`, or nil when the
    /// passphrase is not one WPA accepts (8 to 63 printable ASCII characters).
    public static func psk(passphrase: String, ssid: String) -> String? {
        let p = Array(passphrase.utf8)
        guard (8...63).contains(p.count), p.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }), !ssid.isEmpty else { return nil }
        return pbkdf2SHA1(password: p, salt: Array(ssid.utf8), iterations: 4096, length: 32)
            .map { hex($0) }.joined()
    }

    /// Whether `s` is a PSK in the form wpa_supplicant.conf takes: 64 hex digits.
    public static func isPSK(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    static func hex(_ b: UInt8) -> String {
        let d = Array("0123456789abcdef")
        return String([d[Int(b >> 4)], d[Int(b & 0xf)]])
    }

    // MARK: - PBKDF2-HMAC-SHA1 (RFC 8018), HMAC (RFC 2104), SHA-1 (FIPS 180-4)

    static func pbkdf2SHA1(password: [UInt8], salt: [UInt8], iterations: Int, length: Int) -> [UInt8] {
        var out: [UInt8] = []
        var block: UInt32 = 1
        while out.count < length {
            var u = hmacSHA1(key: password, message: salt + [UInt8(block >> 24), UInt8((block >> 16) & 0xff),
                                                             UInt8((block >> 8) & 0xff), UInt8(block & 0xff)])
            var t = u
            for _ in 1..<iterations {
                u = hmacSHA1(key: password, message: u)
                for i in 0..<t.count { t[i] ^= u[i] }
            }
            out += t
            block += 1
        }
        return Array(out.prefix(length))
    }

    static func hmacSHA1(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? sha1(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        return sha1(k.map { $0 ^ 0x5c } + sha1(k.map { $0 ^ 0x36 } + message))
    }

    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var m = message
        let bitLength = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(m[j]) << 24 | UInt32(m[j + 1]) << 16 | UInt32(m[j + 2]) << 8 | UInt32(m[j + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (x << 1) | (x >> 31)
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let t = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = t
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { v in [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    }
}
