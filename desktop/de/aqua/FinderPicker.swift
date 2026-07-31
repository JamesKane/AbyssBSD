// The Finder as a file picker — the seam the portal needs (PHASE7.md P7.1).
//
// A portal must not link the file manager in as a library: the picker stays a
// *separate process*, chosen by the user, with no API surface the requesting app
// can reach. So the contract is deliberately tiny and file-shaped, exactly as
// the sibling's `reef-portal` did it:
//
//   $ABYSS_FINDER_PICK=/path/to/result   AquaDemo (AQUA_SCENE=finder)
//
//   the user chooses a file  →  its path is written to the result file, exit 0
//   the user cancels         →  nothing is written,                   exit 1
//   anything else            →  a crash, and the portal must be able to tell
//
// That last line is why the exit code and the result file are *both* part of the
// contract (PHASE7.md §6.2): "the user declined" and "the picker died" must not
// look alike, or a crashing picker silently reads as a cancelled dialog.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What activating an item should do. In picker mode a *file* is chosen rather
/// than launched — opening a document in a file dialog must not run it, which
/// would be both surprising and a way to make the picker execute things on an
/// app's behalf.
public enum FinderActivation: Equatable, Sendable {
    case navigate(String)   // a folder: browse into it (or open its window)
    case choose(String)     // picker mode: this is the answer
    case launch(String)     // normal mode: hand it to the Launcher
}

/// Decide what activating `entry` in `directory` means. Pure, so the rule that
/// picker mode never launches anything is testable without a compositor.
public func finderActivation(entry: FinderEntry, in directory: String,
                             picking: Bool) -> FinderActivation {
    let full = finderJoin(directory, entry.name)
    if entry.isContainer { return .navigate(full) }
    return picking ? .choose(full) : .launch(full)
}

/// The picker's side of the contract.
public enum FinderPicker {
    /// The result file named by `$ABYSS_FINDER_PICK`, or nil when the Finder is
    /// running normally.
    public static func resultPath() -> String? {
        guard let v = getenv("ABYSS_FINDER_PICK"), v.pointee != 0 else { return nil }
        return String(cString: v)
    }

    /// True when this process is a picker.
    public static var isPicking: Bool { resultPath() != nil }

    public static let chosenExitCode: Int32 = 0
    public static let cancelledExitCode: Int32 = 1

    /// In *save* mode the portal passes a suggested filename
    /// (`$ABYSS_FINDER_SAVE_NAME`). A save dialog has to be able to name a file
    /// that doesn't exist yet, which picking from a listing cannot express — so
    /// **⌘S saves into the folder on screen** under that name.
    ///
    /// This is a stopgap with a real Aqua save panel (a name field, a New Folder
    /// button) behind it; it is called out in PHASE7.md rather than left to be
    /// discovered. Without it `file.save` could only ever overwrite something
    /// that already existed.
    public static func saveName() -> String? {
        guard let v = getenv("ABYSS_FINDER_SAVE_NAME"), v.pointee != 0 else { return nil }
        let name = String(cString: v)
        // The portal sanitises this too; a picker that trusts its environment
        // blindly would still be wrong, and the check is one line.
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return name
    }

    public static var isSaving: Bool { isPicking && saveName() != nil }

    /// Write the chosen path and exit 0.
    ///
    /// Written with `O_TRUNC` and a trailing newline, then `fsync`ed: the portal
    /// reads this file the moment the picker exits, and a partial write would
    /// hand back a truncated path — which, since the portal then *opens* what it
    /// reads, is a bug with consequences rather than a cosmetic one.
    public static func chose(_ path: String) -> Never {
        if let result = resultPath() {
            let fd = open(result, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            if fd >= 0 {
                let bytes = Array((path + "\n").utf8)
                _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, bytes.count) }
                fsync(fd)
                close(fd)
            }
        }
        exit(chosenExitCode)
    }

    /// Exit without writing: the user declined.
    public static func cancelled() -> Never {
        exit(cancelledExitCode)
    }

    /// Read a result file the way the portal does. Returns nil for "no choice"
    /// — an absent file, an empty one, or one holding something that isn't an
    /// absolute path.
    ///
    /// The absolute-path check is not decoration: the portal opens whatever
    /// comes back, so a relative path would resolve against the *portal's*
    /// working directory rather than the user's choice.
    public static func readResult(_ path: String) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, 4096) }
        guard n > 0 else { return nil }
        var s = String(decoding: buf[0..<n], as: UTF8.self)
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        guard !s.isEmpty, s.hasPrefix("/") else { return nil }
        return s
    }
}
