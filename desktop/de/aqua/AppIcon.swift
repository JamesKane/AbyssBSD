// AppIcon — an application bundle's *own* icon, instead of the procedural "A".
//
// A Mac app is a directory (`Foo.app`) whose artwork lives in
// `Contents/Resources`. There is no LaunchServices here and no Info.plist
// parser, so the lookup is a convention rather than a declaration:
//
//     Contents/Resources/<BundleName>.{png,icns}   (the usual naming)
//     Contents/Resources/{icon,Icon}.{png,icns}
//     Contents/Resources/<the first *.png, else the first *.icns>
//
// PNG is loaded by cairo directly. `.icns` is a container, not a codec: since
// Mac OS X 10.7 its large variants are *embedded PNGs*, so we pick the biggest
// PNG chunk and hand that to cairo. Old-style RLE-compressed `.icns` variants
// (which is what a genuine 10.2-era bundle would hold) are not decoded — that
// needs a real ICNS decoder, the same call we made for JPEG wallpapers. An icon
// we can't read is not an error: the procedural glyph stands in, as before.
//
// Surfaces are cached by path for the process's life — icons are small, the
// same handful repaint every frame, and a Finder window full of apps would
// otherwise re-decode PNGs on every redraw.

import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum AppIcon {
    // Single-threaded UI paints, hence nonisolated(unsafe) — same discipline as
    // Text's shape/face caches.
    nonisolated(unsafe) private static var cache: [String: OpaquePointer?] = [:]

    /// The icon file inside `bundle` (a `*.app` directory), by the convention
    /// above. Pure policy over a directory listing — nil when there's nothing
    /// usable, which is the common case for our own bundles.
    public static func iconFile(inBundle bundle: String) -> String? {
        let resources = finderJoin(finderJoin(bundle, "Contents"), "Resources")
        guard finderIsDirectory(resources) else { return nil }
        let names = readDirectory(resources, showHidden: false).map(\.name)
        guard !names.isEmpty else { return nil }

        let base = finderSplitExtension(finderDisplayName(bundle)).base
        for candidate in ["\(base).png", "icon.png", "Icon.png",
                          "\(base).icns", "icon.icns", "Icon.icns"]
        where names.contains(candidate) {
            return finderJoin(resources, candidate)
        }
        if let png = names.first(where: { $0.lowercased().hasSuffix(".png") }) {
            return finderJoin(resources, png)
        }
        if let icns = names.first(where: { $0.lowercased().hasSuffix(".icns") }) {
            return finderJoin(resources, icns)
        }
        return nil
    }

    /// The decoded icon for a path from `iconFile`, or nil if it can't be read.
    /// Cached (including the failure, so a bad file is probed once).
    public static func surface(_ path: String) -> OpaquePointer? {
        if let hit = cache[path] { return hit }
        let loaded = decode(path)
        cache[path] = loaded
        return loaded
    }

    /// Draw the icon to fill `r`, preserving its aspect ratio (centred).
    /// Returns false if there's nothing to draw, so callers fall back.
    @discardableResult
    public static func draw(_ cr: OpaquePointer, path: String, _ r: Rect) -> Bool {
        guard let img = surface(path) else { return false }
        let iw = Double(cairo_image_surface_get_width(img))
        let ih = Double(cairo_image_surface_get_height(img))
        guard iw > 0, ih > 0 else { return false }
        let scale = min(r.w / iw, r.h / ih)
        let dw = iw * scale, dh = ih * scale
        cairo_save(cr)
        cairo_translate(cr, r.x + (r.w - dw) / 2, r.y + (r.h - dh) / 2)
        cairo_scale(cr, scale, scale)
        cairo_set_source_surface(cr, img, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD)
        cairo_paint(cr)
        cairo_restore(cr)
        return true
    }

    private static func decode(_ path: String) -> OpaquePointer? {
        if path.lowercased().hasSuffix(".icns") {
            guard let png = largestEmbeddedPNG(inICNS: path) else { return nil }
            return imageFromPNGBytes(png)
        }
        guard let s = path.withCString({ cairo_image_surface_create_from_png($0) })
        else { return nil }
        guard cairo_surface_status(s) == CAIRO_STATUS_SUCCESS else {
            cairo_surface_destroy(s)
            return nil
        }
        return s
    }

    // MARK: ICNS (a container of variants, one of which is usually a PNG)

    /// The biggest PNG chunk in an `.icns` file. Layout: "icns" + total length,
    /// then chunks of {4-byte type, 4-byte big-endian length, payload}, where a
    /// modern variant's payload is a whole PNG file.
    static func largestEmbeddedPNG(inICNS path: String) -> [UInt8]? {
        guard let data = readFileBytes(path), data.count > 8,
              data[0] == 0x69, data[1] == 0x63, data[2] == 0x6e, data[3] == 0x73
        else { return nil }

        func be32(_ at: Int) -> Int {
            (Int(data[at]) << 24) | (Int(data[at + 1]) << 16)
                | (Int(data[at + 2]) << 8) | Int(data[at + 3])
        }
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4e, 0x47]
        var best: [UInt8]?
        var off = 8
        while off + 8 <= data.count {
            let len = be32(off + 4)
            // A length that doesn't fit is a corrupt file — stop, don't guess.
            guard len >= 8, off + len <= data.count else { break }
            let payload = off + 8
            let size = len - 8
            if size > 8, Array(data[payload..<(payload + 4)]) == pngMagic,
               size > (best?.count ?? 0) {
                best = Array(data[payload..<(payload + size)])
            }
            off += len
        }
        return best
    }

    /// Decode PNG bytes already in memory (an ICNS payload) via cairo's stream
    /// reader — a `@convention(c)` callback walking a cursor we pass as context.
    private static func imageFromPNGBytes(_ bytes: [UInt8]) -> OpaquePointer? {
        final class Cursor {
            let bytes: [UInt8]
            var pos = 0
            init(_ b: [UInt8]) { bytes = b }
        }
        let cursor = Cursor(bytes)
        let reader: cairo_read_func_t = { closure, buffer, length in
            guard let closure, let buffer else { return CAIRO_STATUS_READ_ERROR }
            let c = Unmanaged<Cursor>.fromOpaque(closure).takeUnretainedValue()
            let n = Int(length)
            guard c.pos + n <= c.bytes.count else { return CAIRO_STATUS_READ_ERROR }
            c.bytes.withUnsafeBytes { src in
                buffer.update(from: src.baseAddress!.advanced(by: c.pos)
                                       .assumingMemoryBound(to: UInt8.self), count: n)
            }
            c.pos += n
            return CAIRO_STATUS_SUCCESS
        }
        let s = withExtendedLifetime(cursor) {
            cairo_image_surface_create_from_png_stream(
                reader, Unmanaged.passUnretained(cursor).toOpaque())
        }
        guard let s, cairo_surface_status(s) == CAIRO_STATUS_SUCCESS else {
            if let s { cairo_surface_destroy(s) }
            return nil
        }
        return s
    }

    private static func readFileBytes(_ path: String, limit: Int = 8 << 20) -> [UInt8]? {
        let fd = path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count < limit {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out.isEmpty ? nil : out
    }
}
