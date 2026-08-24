// Who is allowed to command the installer.
//
// `abyss-install` runs as root and is driven by an unprivileged GUI, which is a
// first for this tree: every other service here is talked to by processes of the
// same user. The obvious mechanism — socket permissions — cannot answer it.
// `CurrentIPC` creates its runtime directory 0700 and every service socket 0600
// (`Current.swift`), which is the right default for a desktop and exactly wrong
// here: a root-owned 0600 socket is one the GUI cannot open at all.
//
// The tempting fix is a wider mode. That hands the installer to every process on
// the machine, which for a program whose job is to rewrite disks is a poor
// trade. So the socket stays private and the service **asks the kernel who is
// calling**.

import CPlatform

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The effective uid of the process at the other end of a connected unix
/// socket, or nil if the kernel would not say.
///
/// One call in Swift, two underneath: FreeBSD has `getpeereid(3)` and no
/// `SO_PEERCRED`; glibc has `SO_PEERCRED` (behind `_GNU_SOURCE`) and no
/// `getpeereid`. The `#if` lives in `de/cplatform`, beside the cmsg macros, for
/// the same reason they do.
public func peerUID(of socket: Int32) -> UInt32? {
    var uid: UInt32 = 0
    guard ap_peer_uid(socket, &uid) == 0 else { return nil }
    return uid
}

/// Whether a caller may command this installer.
public struct Authority: Sendable {
    /// The uid the service was started for. `nil` means "only the uid running
    /// the service", which for a root-run installer means root alone — a safe
    /// default that a session sets explicitly when it starts one for a user.
    public let allowed: UInt32

    public init(allowed: UInt32) { self.allowed = allowed }
    public init() { self.allowed = geteuid() }

    /// The decision, and the sentence to log when it is no.
    public func admits(_ socket: Int32) -> (ok: Bool, why: String) {
        guard let uid = peerUID(of: socket) else {
            // Never fall back to "allow" — a mechanism that fails open is worse
            // than no mechanism, because it looks like one.
            return (false, "the kernel would not identify the caller")
        }
        if uid == allowed { return (true, "") }
        return (false, "uid \(uid) may not command an installer started for uid \(allowed)")
    }
}
