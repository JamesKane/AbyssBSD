// DBusPortal — org.freedesktop.portal.FileChooser, the rules (PHASE8.md P8.2).
//
// Everything here is pure: given a sender, a token and an options dictionary,
// what object path does the Request live at, what does the picker get asked for,
// and what goes back in the Response. No socket, no bus, no picker — so the
// parts that are easy to get quietly wrong are pinned by unit tests and the live
// script is left to prove only the things that need three real processes.
//
// The interface is somebody else's, and it is on disk to be read rather than
// remembered: /usr/share/dbus-1/interfaces/org.freedesktop.portal.{FileChooser,
// Request}.xml. Two things in it govern this file.
//
//   1. **The answer is a URI, not a descriptor.** `OpenFile`'s Response carries
//      `uris` (`as`) and nothing else that names the file. There is no `h` in
//      it, anywhere, in any version. That is a property of *their* protocol, and
//      §6.6 says what it costs us — but it means this bridge's job ends at a
//      name, and the descriptor `abyss-portal` opened stops here.
//
//   2. **The client computes the handle path before it calls.** The path is
//      `/org/freedesktop/portal/desktop/request/SENDER/TOKEN`, derived from the
//      caller's own unique name and its own `handle_token`, precisely so it can
//      subscribe to the Response *before* making the call. Derive it any other
//      way — invent a serial, use our own name — and a correct client subscribes
//      to a path nothing is ever emitted on, then hangs with no error.

import CurrentIPC
// Re-exported: a caller of this module works in `DBusValue`s, and having to
// import both modules to read one function's signature is friction with no
// payoff.
@_exported import DBus

/// The `response` code in a `Request::Response` signal.
public enum PortalResponse: UInt32, Equatable, Sendable {
    case success = 0
    case cancelled = 1
    case other = 2
}

/// Which chooser was asked for.
public enum ChooserKind: Equatable, Sendable {
    case open
    case save
}

// MARK: - The Request object's path

public enum RequestHandle {
    public static let prefix = "/org/freedesktop/portal/desktop/request"

    /// A valid object-path element: the spec's `handle_token` "must be a valid
    /// object path element", which is `[A-Za-z0-9_]+` and nothing else. A token
    /// with a `/` in it would silently move the Request somewhere else in the
    /// tree; one with a `-` produces a path a strict client refuses to parse.
    public static func isValidElement(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for ch in s.unicodeScalars {
            switch ch {
            case "A"..."Z", "a"..."z", "0"..."9", "_": continue
            default: return false
            }
        }
        return true
    }

    /// The caller's unique name as a path element: `:1.42` → `1_42`.
    ///
    /// Exactly the transformation in the Request spec — the leading `:` removed
    /// and every `.` replaced by `_`. Not a hash, not an escape scheme of our
    /// own: the client performs the same transformation on its own name to
    /// predict where to subscribe, so any divergence is a hang.
    public static func senderElement(_ sender: String) -> String? {
        var s = sender
        if s.hasPrefix(":") { s.removeFirst() }
        s = String(s.map { $0 == "." ? "_" : $0 })
        return isValidElement(s) ? s : nil
    }

    /// The full path, or nil if either component is unusable.
    public static func path(sender: String, token: String) -> String? {
        guard let who = senderElement(sender), isValidElement(token) else { return nil }
        return "\(prefix)/\(who)/\(token)"
    }
}

// MARK: - file:// URIs

public enum FileURI {
    /// Percent-encode a filesystem path into a `file://` URI.
    ///
    /// Unreserved characters (RFC 3986) and `/` pass through; everything else
    /// becomes `%XX` **per UTF-8 byte**, which is the part worth being careful
    /// about — encoding per *character* mangles any path outside ASCII, and a
    /// desktop whose home directories are English-only is not a desktop.
    ///
    /// This escapes a superset of what `g_filename_to_uri` escapes (it leaves
    /// sub-delimiters like `,` and `:` alone). Escaping more is always safe to
    /// decode; escaping less is not, so the superset is the deliberate choice.
    public static func encode(_ path: String) -> String {
        var out = "file://"
        for byte in Array(path.utf8) {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
                 UInt8(ascii: "~"), UInt8(ascii: "/"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let d = Array("0123456789ABCDEF".utf8)
                out.append("%")
                out.unicodeScalars.append(Unicode.Scalar(d[Int(byte >> 4)]))
                out.unicodeScalars.append(Unicode.Scalar(d[Int(byte & 0xf)]))
            }
        }
        return out
    }

    /// The inverse, so a test can check the round trip rather than trust the
    /// encoder's own idea of what it produced.
    public static func decode(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        var bytes: [UInt8] = []
        let src = Array(uri.dropFirst("file://".count).utf8)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        while i < src.count {
            if src[i] == UInt8(ascii: "%") {
                guard i + 2 < src.count, let h = hex(src[i + 1]), let l = hex(src[i + 2])
                else { return nil }
                bytes.append(h << 4 | l)
                i += 3
            } else {
                bytes.append(src[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - The options vardict

/// The subset of the chooser's options this bridge acts on.
///
/// Everything else in the spec — `filters`, `choices`, `accept_label`, `modal`,
/// `current_filter` — is **parsed and ignored**, which is different from being
/// unsupported: the whole `a{sv}` must decode successfully or the method call
/// fails, so `filters`' `a(sa(us))` exercises the unmarshaller's nesting on
/// every real GTK call whether we look at the value or not.
public struct ChooserOptions: Equatable, Sendable {
    public var handleToken: String?
    public var currentFolder: String?
    public var currentName: String?
    public var multiple = false
    public var directory = false
    /// Keys we saw and did not act on — logged, so "the picker ignored my
    /// filter" is answerable from the journal instead of by guessing.
    public var ignored: [String] = []

    public init() {}

    /// Read an `a{sv}`. Anything of an unexpected shape is skipped rather than
    /// rejected: a client sending `multiple` as a string is a client bug, and
    /// failing its file dialog outright helps nobody.
    public init(_ options: DBusValue) {
        self.init()
        guard case .array(_, let entries) = options else { return }
        for entry in entries {
            guard case .dictEntry(.string(let key), .variant(let v)) = entry else { continue }
            switch key {
            case "handle_token":
                if case .string(let s) = v { handleToken = s }
            case "current_folder":
                currentFolder = ChooserOptions.pathFromByteArray(v)
            case "current_name":
                if case .string(let s) = v, !s.isEmpty { currentName = s }
            case "multiple":
                if case .bool(let b) = v { multiple = b }
            case "directory":
                if case .bool(let b) = v { directory = b }
            default:
                ignored.append(key)
            }
        }
    }

    /// `current_folder` is `ay`, not `s`: a byte array in the filesystem's
    /// encoding, "expected to be terminated by a nul byte". The trailing NUL is
    /// part of the value and must come off — leave it on and the path handed to
    /// the picker ends in a NUL, which `open(2)` will not find.
    static func pathFromByteArray(_ v: DBusValue) -> String? {
        guard case .array("y", let items) = v else { return nil }
        var bytes: [UInt8] = []
        for item in items {
            guard case .byte(let b) = item else { return nil }
            bytes.append(b)
        }
        while bytes.last == 0 { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        let s = String(decoding: bytes, as: UTF8.self)
        // Only an absolute path is worth forwarding, for the same reason
        // `PortalRequest.sanitise` says: a relative one resolves against a
        // working directory the app should not get to point the picker at.
        return s.hasPrefix("/") ? s : nil
    }
}

// MARK: - Translating to `abyss-portal`

/// The `CurrentIPC` request this D-Bus call becomes.
///
/// Note what does not appear: nothing from `options` that could name a file to
/// open. `current_name` is a *suggestion* for a save dialog's filename field and
/// `abyss-portal` sanitises it again on arrival (`PortalRequest.sanitiseName`);
/// the confused-deputy rule is enforced there, by the type, and this bridge is
/// not trusted to have got it right.
public func portalCallMessage(kind: ChooserKind, options: ChooserOptions) -> Msg {
    var msg = Msg()
    switch kind {
    case .open:
        msg.set("method", "file.open")
    case .save:
        msg.set("method", "file.save")
        if let n = options.currentName { msg.set("name", n) }
    }
    if let d = options.currentFolder { msg.set("dir", d) }
    return msg
}

/// What `abyss-portal` said, as the Response signal's two arguments.
///
/// The reply's `ok`/`error` pair collapses to the spec's three codes: 0 chose,
/// 1 declined, 2 anything else. Telling 1 from 2 matters — a client that treats
/// a cancel as an error pops up a failure dialog every time somebody changes
/// their mind.
public func chooserResponse(reply: Msg) -> (PortalResponse, DBusValue) {
    let empty = DBusValue.options([])
    guard reply.bool("ok") == true else {
        let why = reply.string("error") ?? "unknown"
        return (why == "cancelled" ? .cancelled : .other, empty)
    }
    guard let path = reply.string("path"), path.hasPrefix("/") else {
        // `ok` with no absolute path is a broken portal, and must not be
        // reported as a success with an empty file list — the client would
        // silently open nothing.
        return (.other, empty)
    }
    return (.success, chooserResults(paths: [path]))
}

/// The results vardict: `uris`, and only `uris`.
public func chooserResults(paths: [String]) -> DBusValue {
    .options([("uris", .array("s", paths.map { .string(FileURI.encode($0)) }))])
}
