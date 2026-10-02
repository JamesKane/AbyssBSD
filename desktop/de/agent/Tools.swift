// The agent's own tools (PHASE18 P18.8): reading what the jail holds.
//
// Read-only, and bounded by the jail, not by checks here: inside, the jail's
// filesystem *is* what the agent may see — the system read-only, its own
// home, and what was granted to it. Checks here would be a second boundary
// that could disagree with the first. The vocabulary (P18.10) and lldb
// (P18.9) are added the same way, as tools.

import Model
import Spawn

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

    /// The `debug` class's tool (P18.9): lldb on one crash — its core and its
    /// binary, both fixed by the session (granted read-only by the keeper), so
    /// the model chooses the command and never the target. `--batch`: it runs
    /// the command and exits; the output is cut at readLimit.
    public static func lldb(core: String, binary: String, lldb: String = "/usr/bin/lldb") -> AgentTool {
        AgentTool(
            name: "lldb",
            description: "Run one lldb command on the crashed program's core, e.g. \"bt\", \"frame select 1\", \"frame variable\", \"register read\", \"image list\".",
            parameters: .object([("type", .string("object")), ("properties", .object([
                ("command", .object([("type", .string("string"))]))])), ("required", .array([.string("command")]))])
        ) { args in
            guard let command = args["command"]?.string, !command.isEmpty else { return "error: lldb needs a command" }
            let r = Spawn.run([lldb, "--batch", "--no-lldbinit", "-c", core, binary, "-o", command],
                              stderr: .merge, limit: readLimit + 1)
            if let why = r.failure { return "error: lldb could not run: \(why)" }
            let out = r.stdoutText
            let cut = out.utf8.count > readLimit ? String(decoding: Array(out.utf8.prefix(readLimit)), as: UTF8.self) + "\n(cut)" : out
            return r.succeeded ? cut : "lldb exited \(r.code):\n" + cut
        }
    }
}
