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
