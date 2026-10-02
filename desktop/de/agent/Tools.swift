// The agent's own tools (PHASE18 P18.8): reading what the jail holds.
//
// Read-only, and bounded by the jail, not by checks here: inside, the jail's
// filesystem *is* what the agent may see — the system read-only, its own
// home, and what was granted to it. Checks here would be a second boundary
// that could disagree with the first. The vocabulary (P18.10) and lldb
// (P18.9) are added the same way, as tools.

import Model

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum AgentTools {
    public static let readLimit = 16 << 10
    public static let listLimit = 200

    public static var reading: [AgentTool] { [listDirectory, readFile] }

    public static let listDirectory = AgentTool(
        name: "list_directory",
        description: "List the entries of a directory. Directories end in /.",
        parameters: .object([("type", .string("object")), ("properties", .object([
            ("path", .object([("type", .string("string"))]))])), ("required", .array([.string("path")]))])
    ) { args in
        guard let path = args["path"]?.string, !path.isEmpty else { return "error: list_directory needs a path" }
        guard let d = opendir(path) else { return "error: \(path): \(String(cString: strerror(errno)))" }
        defer { closedir(d) }
        var names: [String] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { b in
                String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            let full = path.hasSuffix("/") ? path + name : path + "/" + name
            let dir = lstat(full, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            names.append(dir ? name + "/" : name)
        }
        names.sort()
        let more = names.count > listLimit ? "\n(\(names.count - listLimit) more)" : ""
        return names.isEmpty ? "(empty)" : names.prefix(listLimit).joined(separator: "\n") + more
    }

    public static let readFile = AgentTool(
        name: "read_file",
        description: "Read a text file, up to 16 KB from an optional byte offset.",
        parameters: .object([("type", .string("object")), ("properties", .object([
            ("path", .object([("type", .string("string"))])),
            ("offset", .object([("type", .string("integer"))]))])), ("required", .array([.string("path")]))])
    ) { args in
        guard let path = args["path"]?.string, !path.isEmpty else { return "error: read_file needs a path" }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return "error: \(path): \(String(cString: strerror(errno)))" }
        defer { close(fd) }
        let offset = max(0, args["offset"]?.int ?? 0)
        if offset > 0 { lseek(fd, off_t(offset), SEEK_SET) }
        var buf = [UInt8](repeating: 0, count: readLimit + 1)
        var got = 0
        while got < buf.count {
            let n = buf[got...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { return "error: \(path): \(String(cString: strerror(errno)))" }
            if n == 0 { break }
            got += n
        }
        let more = got > readLimit ? "\n(more from offset \(offset + readLimit))" : ""
        return String(decoding: buf[0..<min(got, readLimit)], as: UTF8.self) + more
    }
}
