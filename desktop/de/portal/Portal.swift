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
