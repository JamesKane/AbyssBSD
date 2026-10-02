// Agent presence (PHASE18 P18.13b): a session waiting for a yes is visible
// without hunting for its window.
//
// Only the Agent window knows whether its session is working (a question with
// the model), waiting (a requester in front of the person) or idle; the keeper
// and the model are not asked mid-request. So the window says it, as a file:
// `<runtime dir>/agents/<pid>`, two lines — the state and what it is about.
// The Dock, the menu bar and the island menu read the directory. A file is
// written to a temporary name and renamed into place, so a watcher on the
// directory sees every change (kqueue reports entries, not writes); one whose
// process is gone is ignored, and removed, when read.

import CurrentIPC
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum AgentState: String, Equatable, Sendable, Comparable {
    case idle, working, waiting
    /// Waiting outranks working outranks idle: what a person must do first.
    public static func < (a: AgentState, b: AgentState) -> Bool { a.rank < b.rank }
    var rank: Int { switch self { case .idle: 0; case .working: 1; case .waiting: 2 } }
    /// How the menu bar and the island menu say it.
    public var words: String {
        switch self { case .idle: "Idle"; case .working: "Working"; case .waiting: "Waiting for you" }
    }
}

public struct AgentPresence: Equatable, Sendable {
    public var pid: Int32
    public var state: AgentState
    /// What it is about: the question, or what the requester asks.
    public var about: String
    public init(pid: Int32, state: AgentState, about: String) {
        self.pid = pid; self.state = state; self.about = about
    }

    /// The text of a presence file.
    public var text: String { "\(state.rawValue)\n\(String(about.map { $0 == "\n" ? " " : $0 }))\n" }

    /// A presence file's text, or nil if it is not one.
    public static func parse(pid: Int32, _ text: String) -> AgentPresence? {
        let l = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let s = l.first, let state = AgentState(rawValue: String(s)) else { return nil }
        let about = l.count > 1 ? String(l[1].filter { $0 != "\n" }) : ""
        return AgentPresence(pid: pid, state: state, about: about)
    }

    /// Every session's presence, waiting first, then working, then idle.
    public static func sort(_ all: [AgentPresence]) -> [AgentPresence] {
        all.sorted { $0.state != $1.state ? $0.state > $1.state : $0.pid < $1.pid }
    }
}

/// What the Dock's Agent tile shows: how many are waiting, or that one is
/// working, or nothing.
public enum AgentBadge: Equatable, Sendable {
    case none, working, waiting(Int)
    public init(_ all: [AgentPresence]) {
        let waiting = all.filter { $0.state == .waiting }.count
        if waiting > 0 { self = .waiting(waiting) }
        else if all.contains(where: { $0.state == .working }) { self = .working }
        else { self = .none }
    }
}

public enum AgentPresenceIO {
    /// `<runtime dir>/agents`, made if it is not there.
    public static func dir() -> String? {
        guard let r = try? Current.runtimeDir() else { return nil }
        let d = r + "/agents"
        if mkdir(d, 0o700) != 0 && errno != EEXIST { return nil }
        return d
    }

    /// Say this process's state: written aside, renamed into place.
    public static func publish(_ p: AgentPresence) {
        guard let d = dir() else { return }
        let tmp = "\(d)/.\(p.pid).tmp", path = "\(d)/\(p.pid)"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let bytes = Array(p.text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        if rename(tmp, path) != 0 { unlink(tmp) }
    }

    /// This process has no session any more.
    public static func withdraw(pid: Int32 = getpid()) {
        guard let d = dir() else { return }
        unlink("\(d)/\(pid)")
    }

    /// Every live session's presence, sorted; a file whose process is gone is
    /// removed (a window killed outright cannot withdraw its own).
    public static func read(in dir: String? = nil) -> [AgentPresence] {
        guard let d = dir ?? self.dir(), let dp = opendir(d) else { return [] }
        defer { closedir(dp) }
        var out: [AgentPresence] = []
        while let e = readdir(dp) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard let pid = Int32(name), pid > 0 else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { unlink("\(d)/\(name)"); continue }
            guard let f = fopen("\(d)/\(name)", "r") else { continue }
            var text = "", buf = [CChar](repeating: 0, count: 1024)
            while fgets(&buf, Int32(buf.count), f) != nil { text += String(cString: buf) }
            fclose(f)
            if let p = AgentPresence.parse(pid: pid, text) { out.append(p) }
        }
        return AgentPresence.sort(out)
    }
}
