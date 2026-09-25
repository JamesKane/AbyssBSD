// FinderModel — the Finder's pure half: directory listing, sorting, and all of
// the geometry (icon grid, list rows, scrolling). No cairo, no Wayland, so it is
// unit-testable with no compositor and no window — the "one layout function
// feeds both paint and hit-test" rule from HANDOFF §2.9, applied to a file view.
//
// Divergence from the Rust sibling's `reef-fm` (a GNOME-2 file manager): it
// sorted folders first and listed rows only. The Mac OS X Finder interleaves
// folders and files in one case-insensitive alphabetical run, and its default is
// the icon *grid*, so that is what this models.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// stat(2) mode bits, spelled out rather than imported: mode_t is UInt32 on
// Linux and UInt16 on FreeBSD, and the S_IF* macros don't always surface.
private let kFileTypeMask: UInt32 = 0o170000
private let kDirectory: UInt32 = 0o040000

public enum FinderItemKind: Sendable, Equatable {
    case folder
    case application     // a bundle directory (name ends in .app)
    case document
    case disk            // a volume root
}

public struct FinderEntry: Sendable, Equatable {
    public let name: String
    public let kind: FinderItemKind
    public let size: UInt64          // bytes; meaningless for folders
    /// An application bundle's own icon file, when it has one (§AppIcon).
    /// Resolved once per listing, not per repaint.
    public let iconPath: String?

    public init(name: String, kind: FinderItemKind, size: UInt64 = 0,
                iconPath: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.iconPath = iconPath
    }

    /// Whether activating this entry navigates into it.
    public var isContainer: Bool { kind == .folder || kind == .disk }
}

public enum FinderView: Sendable, Equatable {
    case icon
    case list
}

// MARK: - Paths

/// Join a directory and a leaf name, without doubling the root's slash.
public func finderJoin(_ dir: String, _ name: String) -> String {
    if dir.isEmpty { return name }
    return dir == "/" ? "/" + name : dir + "/" + name
}

/// The containing directory of `path`, or nil at the root.
public func finderParent(_ path: String) -> String? {
    guard !path.isEmpty, path != "/" else { return nil }
    var p = path
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    guard let slash = p.lastIndex(of: "/") else { return nil }
    let parent = p[p.startIndex..<slash]
    return parent.isEmpty ? "/" : String(parent)
}

/// The name a Finder window shows for a directory: its leaf, or "Computer" at
/// the volume root (the Jaguar title for the machine itself).
public func finderDisplayName(_ path: String) -> String {
    guard path != "/", !path.isEmpty else { return "Computer" }
    var p = path
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    if let slash = p.lastIndex(of: "/") {
        return String(p[p.index(after: slash)...])
    }
    return p
}

// MARK: - Listing

/// Classify an entry from its name and whether it is a directory. A directory
/// whose name ends in `.app` is an application bundle, which the Finder shows as
/// a single item rather than a folder.
public func finderKind(name: String, isDirectory: Bool) -> FinderItemKind {
    guard isDirectory else { return .document }
    return name.hasSuffix(".app") ? .application : .folder
}

/// Finder ordering: one case-insensitive alphabetical run over every kind (the
/// Mac Finder does *not* float folders to the top), ties broken by the raw name
/// so the sort is total and stable across platforms.
public func finderSort(_ entries: [FinderEntry]) -> [FinderEntry] {
    entries.sorted { a, b in
        let la = a.name.lowercased(), lb = b.name.lowercased()
        return la == lb ? a.name < b.name : la < lb
    }
}

/// Read and sort a directory. Dot-files are hidden unless `showHidden`; an
/// unreadable directory lists as empty (the window still opens, Finder-style).
public func readDirectory(_ path: String, showHidden: Bool = false) -> [FinderEntry] {
    guard let dir = opendir(path) else { return [] }
    defer { closedir(dir) }

    var out: [FinderEntry] = []
    while let e = readdir(dir) {
        var raw = e.pointee.d_name
        let cap = MemoryLayout.size(ofValue: raw)
        let name = withUnsafePointer(to: &raw) {
            $0.withMemoryRebound(to: CChar.self, capacity: cap) {
                String(cString: $0)
            }
        }
        if name == "." || name == ".." { continue }
        if !showHidden && name.hasPrefix(".") { continue }

        // stat (not d_type): d_type is DT_UNKNOWN on some filesystems, and we
        // want the symlink target's kind — the Finder follows aliases.
        var st = stat()
        let full = finderJoin(path, name)
        let ok = full.withCString { stat($0, &st) == 0 }
        let isDir = ok && (UInt32(st.st_mode) & kFileTypeMask) == kDirectory
        let size = ok && !isDir ? UInt64(max(0, st.st_size)) : 0
        let kind = finderKind(name: name, isDirectory: isDir)
        // An app bundle may carry its own icon; look once, here, rather than
        // touching the filesystem from the painter every frame.
        let iconPath = kind == .application ? AppIcon.iconFile(inBundle: full) : nil
        out.append(FinderEntry(name: name, kind: kind, size: size, iconPath: iconPath))
    }
    return finderSort(out)
}

/// Free space on the volume holding `path`, in bytes (0 if it can't be read).
public func finderFreeSpace(_ path: String) -> UInt64 {
    var vfs = statvfs()
    guard path.withCString({ statvfs($0, &vfs) == 0 }) else { return 0 }
    return UInt64(vfs.f_bavail) * UInt64(vfs.f_frsize)
}

/// A byte count in the Finder's decimal units ("1.4 MB", "12.7 GB"). Pure, so
/// the status-bar and list-view strings are testable. No Foundation here, so the
/// one decimal place is assembled by hand.
public func finderFormatBytes(_ bytes: UInt64) -> String {
    func oneDecimal(_ v: Double) -> String {
        let t = Int((v * 10).rounded())
        return "\(t / 10).\(t % 10)"
    }
    let b = Double(bytes)
    if bytes >= 1_000_000_000 { return "\(oneDecimal(b / 1_000_000_000)) GB" }
    if bytes >= 1_000_000     { return "\(oneDecimal(b / 1_000_000)) MB" }
    if bytes >= 1_000         { return "\(oneDecimal(b / 1_000)) KB" }
    return bytes == 1 ? "1 byte" : "\(bytes) bytes"
}

/// The Finder's status line: item count plus free space on the volume.
public func finderStatusText(count: Int, freeBytes: UInt64) -> String {
    let items = count == 1 ? "1 item" : "\(count) items"
    guard freeBytes > 0 else { return items }
    return "\(items), \(finderFormatBytes(freeBytes)) available"
}

// MARK: - Window geometry

public enum FinderMetrics {
    public static var toolbarHeight: Double { Theme.current.finderToolbarHeight }
    public static var statusHeight: Double { Theme.current.finderStatusHeight }
    public static var scrollbarWidth: Double { Theme.current.finderScrollbarWidth }
    // Icon view: a 48px icon over a centred label, in a fixed cell.
    public static var iconSize: Double { Theme.current.finderIconSize }
    public static var cellW: Double { Theme.current.finderCellW }
    public static var cellH: Double { Theme.current.finderCellH }
    public static var gridPad: Double { Theme.current.finderGridPad }
    // List view.
    public static var rowHeight: Double { Theme.current.finderRowHeight }
    public static var listIcon: Double { Theme.current.finderListIcon }
}

/// Chrome rects for a Finder window at logical size (w, h). Pure: paint draws
/// from it and the pointer hit-tests the same rects.
public struct FinderLayout: Equatable, Sendable {
    public var toolbar = Rect(0, 0, 0, 0)
    public var backButton = Rect(0, 0, 0, 0)
    public var viewControl = Rect(0, 0, 0, 0)   // 2-segment icon/list switch
    public var content = Rect(0, 0, 0, 0)       // the clipped item viewport
    public var track = Rect(0, 0, 0, 0)
    public var upArrow = Rect(0, 0, 0, 0)
    public var downArrow = Rect(0, 0, 0, 0)
    public var status = Rect(0, 0, 0, 0)
    public init() {}
}

public func finderLayout(w: Double, h: Double,
                         toolbarVisible: Bool = true) -> FinderLayout {
    var L = FinderLayout()
    let top = Theme.titleBarHeight
    let barH = toolbarVisible ? FinderMetrics.toolbarHeight : 0
    L.toolbar = Rect(0, top, w, barH)
    L.backButton = Rect(12, top + 6, 30, 24)
    L.viewControl = Rect(52, top + 6, 62, 24)

    let statusY = h - FinderMetrics.statusHeight
    L.status = Rect(0, statusY, w, FinderMetrics.statusHeight)

    let bodyY = top + barH
    let bodyH = statusY - bodyY
    let barW = FinderMetrics.scrollbarWidth
    L.content = Rect(0, bodyY, w - barW, bodyH)
    let barX = w - barW
    // Jaguar pairs both scroll arrows at the bottom of the bar.
    L.track = Rect(barX, bodyY, barW, max(0, bodyH - 2 * barW))
    L.upArrow = Rect(barX, bodyY + bodyH - 2 * barW, barW, barW)
    L.downArrow = Rect(barX, bodyY + bodyH - barW, barW, barW)
    return L
}

/// How many icon columns fit a viewport of width `viewportW` (at least one).
public func finderColumns(viewportW: Double) -> Int {
    let usable = viewportW - 2 * FinderMetrics.gridPad
    return max(1, Int(usable / FinderMetrics.cellW))
}

/// The cell rect for item `i` in the current view, in surface coordinates.
public func finderItemRect(_ i: Int, view: FinderView, viewport: Rect,
                           scroll: Double) -> Rect {
    switch view {
    case .icon:
        let cols = finderColumns(viewportW: viewport.w)
        let row = i / cols, col = i % cols
        return Rect(viewport.x + FinderMetrics.gridPad + Double(col) * FinderMetrics.cellW,
                    viewport.y + FinderMetrics.gridPad + Double(row) * FinderMetrics.cellH - scroll,
                    FinderMetrics.cellW, FinderMetrics.cellH)
    case .list:
        return Rect(viewport.x,
                    viewport.y + Double(i) * FinderMetrics.rowHeight - scroll,
                    viewport.w, FinderMetrics.rowHeight)
    }
}

/// Total scrollable height of `count` items in this view and viewport.
public func finderContentHeight(count: Int, view: FinderView,
                                viewport: Rect) -> Double {
    switch view {
    case .icon:
        let cols = finderColumns(viewportW: viewport.w)
        let rows = (count + cols - 1) / cols
        return Double(rows) * FinderMetrics.cellH + 2 * FinderMetrics.gridPad
    case .list:
        return Double(count) * FinderMetrics.rowHeight
    }
}

public func finderMaxScroll(count: Int, view: FinderView, viewport: Rect) -> Double {
    max(0, finderContentHeight(count: count, view: view, viewport: viewport) - viewport.h)
}

/// The item under a surface point, or nil (empty space / past the last item).
public func finderIndex(atX x: Double, y: Double, count: Int, view: FinderView,
                        viewport: Rect, scroll: Double) -> Int? {
    guard viewport.contains(x, y), count > 0 else { return nil }
    switch view {
    case .icon:
        let cols = finderColumns(viewportW: viewport.w)
        let localX = x - viewport.x - FinderMetrics.gridPad
        let localY = y - viewport.y - FinderMetrics.gridPad + scroll
        guard localX >= 0, localY >= 0 else { return nil }
        let col = Int(localX / FinderMetrics.cellW)
        let row = Int(localY / FinderMetrics.cellH)
        guard col < cols else { return nil }
        let i = row * cols + col
        return i < count ? i : nil
    case .list:
        let localY = y - viewport.y + scroll
        guard localY >= 0 else { return nil }
        let i = Int(localY / FinderMetrics.rowHeight)
        return i < count ? i : nil
    }
}

/// The scroll offset that brings item `i` fully on screen, moving as little as
/// possible from `scroll`.
public func finderScrollToShow(_ i: Int, scroll: Double, count: Int,
                               view: FinderView, viewport: Rect) -> Double {
    guard i >= 0, i < count, viewport.h > 0 else { return scroll }
    let top: Double, height: Double
    switch view {
    case .icon:
        let cols = finderColumns(viewportW: viewport.w)
        top = FinderMetrics.gridPad + Double(i / cols) * FinderMetrics.cellH
        height = FinderMetrics.cellH
    case .list:
        top = Double(i) * FinderMetrics.rowHeight
        height = FinderMetrics.rowHeight
    }
    // Reveal the grid's margin along with the item, so scrolling to the first
    // item lands at the very top and to the last item at the very bottom.
    let margin = view == .icon ? FinderMetrics.gridPad : 0
    var s = scroll
    if top - margin < s { s = top - margin }
    if top + height + margin > s + viewport.h { s = top + height + margin - viewport.h }
    return max(0, min(s, finderMaxScroll(count: count, view: view, viewport: viewport)))
}

/// Keyboard motion: the index an arrow key moves to. Left/right step one item;
/// up/down step a row (a full column stride in icon view, one item in list
/// view). Returns the clamped destination.
public func finderMove(from i: Int?, dx: Int, dy: Int, count: Int,
                       view: FinderView, viewport: Rect) -> Int? {
    guard count > 0 else { return nil }
    guard let i else { return 0 }   // no selection yet: start at the first item
    let stride = view == .icon ? finderColumns(viewportW: viewport.w) : 1
    let next = i + dx + dy * stride
    return max(0, min(count - 1, next))
}

// MARK: - Sample listing (offscreen previews)

/// A fixed Jaguar-flavoured home folder for the PNG scene render, so the
/// screenshot is reproducible on any machine.
public func finderSampleEntries() -> [FinderEntry] {
    finderSort([
        FinderEntry(name: "Applications", kind: .folder),
        FinderEntry(name: "Desktop", kind: .folder),
        FinderEntry(name: "Documents", kind: .folder),
        FinderEntry(name: "Library", kind: .folder),
        FinderEntry(name: "Movies", kind: .folder),
        FinderEntry(name: "Music", kind: .folder),
        FinderEntry(name: "Pictures", kind: .folder),
        FinderEntry(name: "Public", kind: .folder),
        FinderEntry(name: "Sites", kind: .folder),
        FinderEntry(name: "TextEdit.app", kind: .application),
        FinderEntry(name: "Read Me.txt", kind: .document, size: 4_812),
        FinderEntry(name: "Aqua Notes.rtf", kind: .document, size: 61_440),
    ])
}
