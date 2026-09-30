// FinderOps — what the Finder does *to* files: new folder, rename, duplicate,
// copy/cut/paste, and move to Trash.
//
// Split in two on purpose:
//   * the **naming rules** are pure functions over an `exists` predicate, so
//     "untitled folder 2" and "Read Me copy 3.txt" are unit-testable with no
//     filesystem at all;
//   * the **syscall layer** is a thin POSIX wrapper (mkdir/rename/open/read/
//     write/unlink), returning Bool rather than throwing, because every caller
//     reacts the same way: log it and leave the listing alone.
//
// Deleting is *move to Trash* (`~/.Trash`), as on Mac — nothing here unlinks a
// file the user asked to delete, so a mistake is recoverable. The single
// exception is `finderEmptyTrash`, driven from the Dock's Trash menu: that is
// what emptying the Trash *means*, and it's the only path in the project that
// really unlinks.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Naming rules (pure)

/// Whether `name` is usable as a filename: non-empty, no path separator, and
/// not one of the directory aliases.
public func finderIsValidName(_ name: String) -> Bool {
    guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255 else {
        return false
    }
    return !name.contains("/")
}

/// Split a leaf name into (base, extension-with-dot). A leading dot is part of
/// the base ("`.hidden`" has no extension), and so is a trailing one.
public func finderSplitExtension(_ name: String) -> (base: String, ext: String) {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
          dot != name.index(before: name.endIndex) else {
        return (name, "")
    }
    return (String(name[name.startIndex..<dot]), String(name[dot...]))
}

/// The Finder's name for a new folder: "untitled folder", then "untitled
/// folder 2", "untitled folder 3", … until one is free.
public func finderNewFolderName(exists: (String) -> Bool) -> String {
    let base = "untitled folder"
    if !exists(base) { return base }
    var n = 2
    while exists("\(base) \(n)") { n += 1 }
    return "\(base) \(n)"
}

/// The Finder's name for a copy of `name`: " copy" before the extension, then
/// " copy 2", " copy 3", … ("Read Me.txt" → "Read Me copy.txt").
public func finderCopyName(_ name: String, exists: (String) -> Bool) -> String {
    let (base, ext) = finderSplitExtension(name)
    let first = "\(base) copy\(ext)"
    if !exists(first) { return first }
    var n = 2
    while exists("\(base) copy \(n)\(ext)") { n += 1 }
    return "\(base) copy \(n)\(ext)"
}

/// The name a pasted item takes in a directory: its own, unless that's taken —
/// then the copy naming applies (pasting into the folder it came from).
public func finderPasteName(_ name: String, exists: (String) -> Bool) -> String {
    exists(name) ? finderCopyName(name, exists: exists) : name
}

// MARK: - Syscall layer

public func finderExists(_ path: String) -> Bool {
    path.withCString { access($0, F_OK) == 0 }
}

public func finderIsDirectory(_ path: String) -> Bool {
    var st = stat()
    guard path.withCString({ stat($0, &st) == 0 }) else { return false }
    return (UInt32(st.st_mode) & 0o170000) == 0o040000
}

@discardableResult
public func finderCreateDirectory(_ path: String) -> Bool {
    path.withCString { mkdir($0, 0o755) == 0 }
}

@discardableResult
public func finderRenameEntry(from: String, to: String) -> Bool {
    from.withCString { f in to.withCString { t in rename(f, t) == 0 } }
}

/// Copy a file's bytes (preserving the mode bits). Returns false on any error,
/// removing a partially written destination so a failure leaves no debris.
@discardableResult
public func finderCopyFile(from: String, to: String) -> Bool {
    var st = stat()
    guard from.withCString({ stat($0, &st) == 0 }) else { return false }
    let src = from.withCString { open($0, O_RDONLY) }
    guard src >= 0 else { return false }
    defer { close(src) }
    let mode = mode_t(UInt32(st.st_mode) & 0o777)
    let dst = to.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, mode) }
    guard dst >= 0 else { return false }

    var ok = true
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    loop: while true {
        let n = buf.withUnsafeMutableBytes { read(src, $0.baseAddress, $0.count) }
        if n == 0 { break }
        if n < 0 { ok = false; break }
        var written = 0
        while written < n {
            let w = buf.withUnsafeBytes {
                write(dst, $0.baseAddress! + written, n - written)
            }
            if w <= 0 { ok = false; break loop }
            written += w
        }
    }
    close(dst)
    if !ok { to.withCString { _ = unlink($0) } }
    return ok
}

/// Copy a file or a whole directory tree. Directories recurse; anything that
/// isn't a regular file or directory (sockets, devices) is skipped rather than
/// failing the whole copy.
@discardableResult
public func finderCopyPath(from: String, to: String) -> Bool {
    guard finderIsDirectory(from) else { return finderCopyFile(from: from, to: to) }
    guard finderCreateDirectory(to) else { return false }
    var ok = true
    // showHidden: a copy must take dot-files with it, whatever the view shows.
    for entry in readDirectory(from, showHidden: true) {
        let childFrom = finderJoin(from, entry.name)
        let childTo = finderJoin(to, entry.name)
        if finderIsDirectory(childFrom) {
            if !finderCopyPath(from: childFrom, to: childTo) { ok = false }
        } else if !finderCopyFile(from: childFrom, to: childTo) {
            ok = false
        }
    }
    return ok
}

/// Where the Trash *would* be (nil when there's no HOME to hang it off). Does
/// not create it — the Dock asks this every time it repaints, and a shell
/// component shouldn't conjure directories just by looking.
public func finderTrashPath() -> String? {
    guard let home = getenv("HOME") else { return nil }
    return String(cString: home) + "/.Trash"
}

/// `~/.Trash`, created on demand (nil when there's no HOME to hang it off).
public func finderTrashDirectory() -> String? {
    guard let dir = finderTrashPath() else { return nil }
    if !finderExists(dir), !finderCreateDirectory(dir) { return nil }
    return dir
}

/// Move `path` to the Trash, uniquing the name if something of that name is
/// already in there. Returns the destination, or nil if it couldn't be moved
/// (notably across filesystems — rename(2) can't, and we don't fall back to a
/// copy+delete, because a half-finished "delete" is worse than a refusal).
@discardableResult
public func finderMoveToTrash(_ path: String) -> String? {
    guard let trash = finderTrashDirectory() else { return nil }
    let name = finderDisplayName(path)
    let unique = finderPasteName(name) { finderExists(finderJoin(trash, $0)) }
    let dest = finderJoin(trash, unique)
    return finderRenameEntry(from: path, to: dest) ? dest : nil
}

/// What's in the Trash right now, as full paths — dot-files included, since the
/// Trash shows (and empties) everything it holds. Empty when there is no Trash
/// yet, which is the same thing to every caller.
public func finderTrashContents() -> [String] {
    guard let trash = finderTrashPath(), finderIsDirectory(trash) else { return [] }
    return readDirectory(trash, showHidden: true).map { finderJoin(trash, $0.name) }
}

/// Remove a file, or a directory and everything under it. **This unlinks** —
/// the one place in the project that does, and only `finderEmptyTrash` calls it.
/// Depth-first: children before the directory itself, since `rmdir` needs it
/// empty. A failure anywhere is reported but doesn't stop the rest.
@discardableResult
public func finderRemovePath(_ path: String) -> Bool {
    guard finderIsDirectory(path) else {
        return path.withCString { unlink($0) == 0 }
    }
    var ok = true
    for entry in readDirectory(path, showHidden: true)
    where entry.name != "." && entry.name != ".." {
        if !finderRemovePath(finderJoin(path, entry.name)) { ok = false }
    }
    return path.withCString { rmdir($0) == 0 } && ok
}

/// Empty the Trash: permanently remove everything in it. Returns how many
/// top-level items went and how many refused, so the caller can say so — the
/// Dock logs it. Emptying an empty (or absent) Trash is (0, 0), not an error.
@discardableResult
public func finderEmptyTrash() -> (removed: Int, failed: Int) {
    var removed = 0, failed = 0
    for path in finderTrashContents() {
        if finderRemovePath(path) { removed += 1 } else { failed += 1 }
    }
    return (removed, failed)
}

// MARK: - What a drop contains

/// The first local path in a `text/uri-list` payload, or nil if there is none.
///
/// **A drop is not a string.** `text/uri-list` (RFC 2483) is a CRLF-separated
/// list whose lines beginning with `#` are comments, and whose entries are URIs
/// — so they are percent-encoded, and a file called `My Report` arrives as
/// `file:///home/me/My%20Report`. Taking the bytes as a path gets that file
/// wrong, and gets a multi-file drag wrong in a way that only shows up on the
/// second file.
///
/// One entry, for now: the Finder drags one icon at a time (P9.3). The parser
/// returns the first because that is what a list of one contains, and because
/// the shape it walks is the one a list of many needs.
public func finderDroppedPath(_ bytes: [UInt8]) -> String? {
    // Split on the *bytes*. `"\r\n"` is one Swift `Character` — a grapheme
    // cluster — so splitting a String on "\r" silently matches nothing and the
    // whole list comes back as a single line with the separators still in it.
    let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
    let sp = UInt8(ascii: " "), tab = UInt8(ascii: "\t")
    for rawLine in bytes.split(whereSeparator: { $0 == cr || $0 == lf }) {
        var line = rawLine
        while let c = line.first, c == sp || c == tab { line = line.dropFirst() }
        while let c = line.last, c == sp || c == tab { line = line.dropLast() }
        if line.isEmpty || line.first == UInt8(ascii: "#") { continue }
        var s = String(decoding: line, as: UTF8.self)
        if s.hasPrefix("file://") {
            s = String(s.dropFirst("file://".count))
            // `file://host/path` — an empty host is the local machine, and a
            // remote one is not a path we can open.
            if !s.hasPrefix("/") {
                guard let slash = s.firstIndex(of: "/") else { continue }
                if s[s.startIndex..<slash] != "localhost" { continue }
                s = String(s[slash...])
            }
        }
        guard s.hasPrefix("/"), let path = finderPercentDecode(s) else { continue }
        return path
    }
    return nil
}

/// A path as a `file://` URI, percent-encoded per UTF-8 byte.
///
/// **The encoding is not optional.** Our own parser would read a raw path back
/// happily, but a `text/uri-list` is what we hand to *other* applications — the
/// GTK clients Phase 8 exists to serve — and a name with a space in it is two
/// entries to anything that follows the RFC. Everything outside RFC 3986's
/// unreserved set, `/` excepted, becomes `%XX`.
///
/// Deliberately the same rule as `DBusPortal.FileURI.encode`, written out again
/// rather than depended on: the toolkit must not pull in D-Bus to name a file.
/// `finderPercentDecode` is its inverse, and they are tested as a round trip.
public func finderFileURI(_ path: String) -> String {
    var out = "file://"
    let hex = Array("0123456789ABCDEF".utf8)
    for byte in Array(path.utf8) {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
             UInt8(ascii: "~"), UInt8(ascii: "/"):
            out.unicodeScalars.append(Unicode.Scalar(byte))
        default:
            out.append("%")
            out.unicodeScalars.append(Unicode.Scalar(hex[Int(byte >> 4)]))
            out.unicodeScalars.append(Unicode.Scalar(hex[Int(byte & 0xf)]))
        }
    }
    return out
}

/// Percent-decoding, byte-wise. Nil if an escape is malformed, because a path
/// we cannot read exactly is a path we must not act on.
public func finderPercentDecode(_ s: String) -> String? {
    var out: [UInt8] = []
    var it = Array(s.utf8)[...]
    while let b = it.first {
        it = it.dropFirst()
        guard b == UInt8(ascii: "%") else { out.append(b); continue }
        guard it.count >= 2, let hi = hexValue(it.first!),
              let lo = hexValue(it.dropFirst().first!) else { return nil }
        out.append(hi << 4 | lo)
        it = it.dropFirst(2)
    }
    return String(decoding: out, as: UTF8.self)
}

private func hexValue(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
    default: return nil
    }
}
