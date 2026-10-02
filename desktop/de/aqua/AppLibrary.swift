// AppLibrary — the applications installed as bundles, for the Dock and the
// Apple menu (PHASE15 P15.2).
//
// `abyss-appgen` writes a bundle per installed port (P15.1) into ~/Applications
// (the session's) and /Applications (root's); anything else a person drops
// there is a bundle too. This reads both: each bundle's name, what to run, its
// icon, and — where appgen wrote them — the app_ids its windows may carry, which
// is how a running window finds its tile.

import AppBundles
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct InstalledApp: Equatable, Sendable {
    /// The bundle's name without `.app`: what the Dock and the menu show.
    public let name: String
    public let bundle: String
    public let executable: String?
    public let icon: String?
    /// From `Contents/app-id`; empty for a bundle appgen did not write, which
    /// then matches by its own name only.
    public let appIDs: [String]

    public func matches(appID: String) -> Bool {
        AppBundle.matches(appID: appID, candidates: appIDs.isEmpty ? [name] : appIDs)
    }
}

public enum AppLibrary {
    /// Where bundles live, the person's first: one of theirs shadows root's of
    /// the same name (PHASE15 §6.2).
    public static func directories() -> [String] {
        var dirs: [String] = []
        if let h = getenv("HOME"), h.pointee != 0 { dirs.append(finderJoin(String(cString: h), "Applications")) }
        dirs.append("/Applications")
        return dirs
    }

    /// Every bundle in those directories, by name, the first of a name winning.
    public static func all(in dirs: [String] = directories()) -> [InstalledApp] {
        var seen = Set<String>(), out: [InstalledApp] = []
        // Each folder, then its Utilities (Jaguar's: Terminal, Disk Utility…).
        for dir in dirs.flatMap({ [$0, finderJoin($0, "Utilities")] }) {
            for e in list(dir) where e.hasSuffix(".app") {
                let name = String(e.dropLast(4))
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                let bundle = finderJoin(dir, e)
                let ids = (readSmall(finderJoin(bundle, AppBundle.appIDFile)) ?? "")
                    .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                out.append(InstalledApp(name: name, bundle: bundle,
                                        executable: Launcher.bundleExecutable(bundle),
                                        icon: AppIcon.iconFile(inBundle: bundle), appIDs: ids))
            }
        }
        return out
    }

    /// The bundle a name means: `Galculator`, `Galculator.app`, or a path to one.
    public static func find(_ name: String, in apps: [InstalledApp]) -> InstalledApp? {
        if name.hasPrefix("/") { return apps.first { $0.bundle == name } }
        let n = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        return apps.first { $0.name == n }
    }

    /// The bundle a running window belongs to.
    public static func owner(of appID: String, in apps: [InstalledApp]) -> InstalledApp? {
        apps.first { $0.matches(appID: appID) }
    }

    private static func list(_ dir: String) -> [String] {
        guard let d = opendir(dir) else { return [] }
        defer { closedir(d) }
        var names: [String] = []
        while let e = readdir(d) {
            let n = withUnsafeBytes(of: e.pointee.d_name) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if n != "." && n != ".." { names.append(n) }
        }
        return names.sorted()
    }

    static func readSmall(_ path: String) -> String? {
        let fd = open(path, O_RDONLY); guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : nil
    }
}
