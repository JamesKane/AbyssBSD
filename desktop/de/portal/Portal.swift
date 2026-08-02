// Portal — the brokerless answer to xdg-desktop-portal (PHASE7.md P7.2).
//
// An app asks the desktop to let the user pick a file. The portal runs the
// **Finder** as the picker, **opens the chosen file itself**, and returns the
// open descriptor over SCM_RIGHTS. The app reads a file it could never have
// opened: the descriptor *is* the capability. No D-Bus, no broker, no flatpak.
//
// The trust story in one paragraph: the portal is a trusted process running as
// the user with full filesystem access — that is the point, not an oversight.
// Its security value is that it opens **only what the user picked in the
// picker**, so a sandboxed app gains exactly one capability per human decision.

import CurrentIPC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What an app may ask for.
///
/// **The confused-deputy rule is enforced by this type, not by a check
/// downstream** (PHASE7.md §6.3): there is deliberately *no case and no field*
/// carrying "the path to open". A request can suggest where the picker should
/// start and what a new file might be called; it cannot name the file that gets
/// opened. An app that could would be using the portal as a privileged
/// `open(2)`, which is the exact bug portals exist to prevent — so the bug is
/// made unrepresentable rather than guarded against.
public enum PortalRequest: Equatable, Sendable {
    case openFile(startDir: String?)
    case saveFile(startDir: String?, suggestedName: String?)
    /// Post a notification. A jailed app reaches the shell's toast **only**
    /// through here — it never holds the notify service's socket, which is the
    /// same trust boundary the file chooser draws.
    case notify(summary: String, body: String?, timeout: UInt64?)
    /// Capture the screen. **Deliberately carries nothing at all**: not what to
    /// capture, not where to put it, not what to call it. `file.open` at least
    /// takes a directory hint; a screenshot request has no hint worth honouring,
    /// so the case has no associated values and the reply names no path either.
    /// The app receives one descriptor and no way to ask for a second thing.
    case screenshot
    case unknown(String)

    /// Parse a control-plane message. Unknown methods are preserved so the
    /// reply can name them.
    public init(_ msg: Msg) {
        switch msg.string("method") ?? "" {
        case "file.open":
            self = .openFile(startDir: PortalRequest.sanitise(msg.string("dir")))
        case "file.save":
            self = .saveFile(startDir: PortalRequest.sanitise(msg.string("dir")),
                             suggestedName: PortalRequest.sanitiseName(msg.string("name")))
        case "notify":
            let summary = msg.string("summary") ?? ""
            // An empty summary is not a notification; refuse it here rather
            // than let an app post a blank panel.
            self = summary.isEmpty
                ? .unknown("notify (no summary)")
                : .notify(summary: summary, body: msg.string("body"),
                          timeout: msg.uint64("timeout"))
        case "screenshot":
            // Nothing is read out of the message. Anything an app sent along
            // with the method is, by construction, ignored.
            self = .screenshot
        case let other:
            self = .unknown(other)
        }
    }

    /// A suggested start directory is a *hint*, and an untrusted one. Only an
    /// absolute path is worth passing on — a relative one would resolve against
    /// the portal's working directory, which is not a place the app should get
    /// to point the picker at by accident.
    static func sanitise(_ dir: String?) -> String? {
        guard let d = dir, d.hasPrefix("/"), !d.contains("\0") else { return nil }
        return d
    }

    /// A suggested filename must be a single path component: an app proposing
    /// `../../.ssh/authorized_keys` is proposing a path, not a name.
    static func sanitiseName(_ name: String?) -> String? {
        guard let n = name, !n.isEmpty, !n.contains("/"), !n.contains("\0"),
              n != ".", n != ".." else { return nil }
        return n
    }
}

/// What running the picker produced.
public enum PickerOutcome: Equatable, Sendable {
    case chose(String)
    case cancelled
    case failed(String)

    /// Read the picker's two signals together — the exit status *and* the
    /// result file — because either alone is ambiguous (PHASE7.md §6.2):
    /// a crash and a decline both leave no result, and only the status tells
    /// them apart.
    public static func from(status: Int32, signalled: Bool, result: String?) -> PickerOutcome {
        if signalled { return .failed("the picker was killed by signal \(status)") }
        switch status {
        case FinderPickerExit.chose:
            guard let path = result else {
                // Exit 0 with nothing written is a broken picker, not a choice —
                // and must never be reported as one.
                return .failed("the picker exited 0 but wrote no result")
            }
            return .chose(path)
        case FinderPickerExit.cancelled:
            return .cancelled
        default:
            return .failed("the picker exited \(status)")
        }
    }
}

/// What running the capture helper produced (PHASE7.md P7.5).
///
/// Read from the same two signals as the picker's outcome, for the same reason
/// (§6.2): an exit status alone can't tell "the compositor refused" from "the
/// helper wrote a truncated file", and a file alone can't tell a fresh capture
/// from a stale one. A screenshot has no cancel — nobody was asked.
public enum GrabOutcome: Equatable, Sendable {
    case captured(width: Int, height: Int)
    case failed(String)

    public static func from(status: Int32, signalled: Bool,
                            image: PNGSize?) -> GrabOutcome {
        if signalled { return .failed("the capture helper was killed by signal \(status)") }
        guard status == 0 else {
            return .failed("the capture helper exited \(status)")
        }
        // Exit 0 with no readable PNG is a broken helper. The portal must not
        // hand over a descriptor to something it hasn't confirmed is an image:
        // a capability is only as good as knowing what it is a capability *to*.
        guard let image else {
            return .failed("the capture helper exited 0 but wrote no readable PNG")
        }
        return .captured(width: image.width, height: image.height)
    }
}

/// A PNG's declared dimensions.
public struct PNGSize: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// Just enough PNG to answer "is this a PNG, and how big?".
///
/// The portal decodes nothing — it only needs to confirm that the bytes it is
/// about to hand over as a capability really are the image it commissioned.
/// Pure, so it is tested without a compositor.
public enum PNGHeader {
    public static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The IHDR sits immediately after the signature: a 4-byte length, "IHDR",
    /// then width and height as big-endian 32-bit values.
    public static func size(of bytes: [UInt8]) -> PNGSize? {
        guard bytes.count >= 24, Array(bytes[0..<8]) == signature,
              Array(bytes[12..<16]) == Array("IHDR".utf8)
        else { return nil }
        func be32(_ at: Int) -> Int {
            (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
        }
        let w = be32(16), h = be32(20)
        guard w > 0, h > 0 else { return nil }
        return PNGSize(width: w, height: h)
    }
}

/// Build the reply for a capture. The descriptor is attached by the caller.
///
/// **Note what isn't here: a path.** `file.open` returns one because the user
/// picked it and already knows it; a screenshot has no name the app is entitled
/// to. The descriptor is the whole of what it gets.
public func portalScreenshotReply(_ outcome: GrabOutcome) -> Msg {
    var reply = Msg()
    switch outcome {
    case .captured(let w, let h):
        reply.set("ok", true)
        reply.set("mode", "r")
        reply.set("width", UInt64(w))
        reply.set("height", UInt64(h))
    case .failed(let why):
        reply.set("ok", false)
        reply.set("error", why)
    }
    return reply
}

/// The picker's exit codes, mirrored from `FinderPicker` so this module doesn't
/// depend on the Aqua toolkit — a portal shouldn't need to link a UI framework
/// to know what 0 and 1 mean.
public enum FinderPickerExit {
    public static let chose: Int32 = 0
    public static let cancelled: Int32 = 1
}

/// Build the reply for an outcome. The descriptor is attached by the caller,
/// which owns it.
public func portalReply(_ outcome: PickerOutcome, mode: PortalOpenMode) -> Msg {
    var reply = Msg()
    switch outcome {
    case .chose(let path):
        reply.set("ok", true)
        reply.set("path", path)
        reply.set("mode", mode == .read ? "r" : "w")
    case .cancelled:
        reply.set("ok", false)
        reply.set("error", "cancelled")
    case .failed(let why):
        reply.set("ok", false)
        reply.set("error", why)
    }
    return reply
}

public enum PortalOpenMode: Equatable, Sendable {
    case read       // file.open  — O_RDONLY
    case write      // file.save  — O_WRONLY|O_CREAT
}
