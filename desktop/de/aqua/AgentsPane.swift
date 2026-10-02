// The Agents pane (PHASE18 P18.11b): what agents did, and what was given.
//
// Every agent session leaves a transcript (abyss-model's and abyss-vocab's
// JSON lines in ~/Library/Logs/Agents/SESSION/). This pane lists the sessions,
// newest first, and says the selected one in sentences — what was asked, what
// the agent called, what it was given and refused, what the person allowed —
// the last lines that fit. Below it, the files given to confined applications
// this session (P18.4), each with Revoke: the keeper takes it back.
//
// Read from disk when the pane opens, as Accounts reads passwd; the grants
// are the keeper's to say (it holds the jails), asked over CurrentIPC.

import CCairo
import AquaDraw
import CurrentIPC
import Model

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A file given to a confined application: the jail, the grant's number,
/// read-only or not, and where it is.
public struct AgentGrantRow: Equatable, Sendable {
    public var jail: String
    public var n: UInt64
    public var writable: Bool
    public var path: String

    /// From the keeper's `grants`: "JAIL<TAB>N<TAB>ro|rw<TAB>inside<TAB>source".
    public static func parse(_ line: String) -> AgentGrantRow? {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5, let n = UInt64(f[1]) else { return nil }
        return AgentGrantRow(jail: f[0], n: n, writable: f[2] == "rw", path: f[4])
    }

    /// "app — /home/ada/notes.txt (read-write)": the jail's class, not its name.
    public var line: String {
        let cls = jail.split(separator: "-").dropFirst(2).joined(separator: "-")
        return "\(cls.isEmpty ? jail : cls) — \(path) (\(writable ? "read-write" : "read-only"))"
    }
}

public struct AgentsPaneState: Equatable, Sendable {
    public var sessions: [TranscriptSummary] = []
    public var selected: Int?
    public var digest: [String] = []
    public var grants: [AgentGrantRow] = []
    public var note = ""
    /// Whether agents are on: `agents.ini` exists (P18.13).
    public var on = true
    public init() {}

    /// Where transcripts are: $HOME/Library/Logs/Agents.
    public static var logs: String {
        (getenv("HOME").map { String(cString: $0) } ?? "/") + "/Library/Logs/Agents"
    }

    public static let sample: AgentsPaneState = {
        var s = AgentsPaneState()
        s.sessions = [
            TranscriptSummary(id: "20261002-173010-agent-1-1", agentClass: "agent", started: "2026-10-02 17:30",
                              questions: 1, tokens: 4469, given: ["TextEdit"]),
            TranscriptSummary(id: "20261002-162929-debug-1-1", agentClass: "debug", started: "2026-10-02 16:29",
                              questions: 1, tokens: 3120, given: []),
        ]
        s.selected = 0
        s.digest = ["17:30:12  You gave the agent TextEdit",
                    "17:30:15  You asked: Please save the document I have open in TextEdit.",
                    "17:30:17    The agent called activate({\"app\":\"TextEdit\",\"verb\":\"file.save\"})",
                    "17:30:17  The agent asked to write with TextEdit (Save)",
                    "17:30:27  You allowed TextEdit to write for the agent",
                    "17:30:27    TextEdit ran file.save: ok",
                    "17:30:28  The agent answered: The document has been saved."]
        s.grants = [AgentGrantRow(jail: "abyss-1001-app", n: 1, writable: true, path: "/home/ada/Documents/notes.txt")]
        return s
    }()
}

public struct AgentsLayout: Equatable, Sendable {
    public var sessions = Rect(0, 0, 0, 0)
    public var sessionRows: [Rect] = []
    public var digest = Rect(0, 0, 0, 0)
    public var grants = Rect(0, 0, 0, 0)
    public var grantRows: [Rect] = []
    public var revoke: [Rect] = []
    public var noteY = 0.0
    /// "Let agents run on this computer" (P18.13).
    public var onOff = Rect(0, 0, 0, 0)
    public static let maxSessions = 10, maxGrants = 4
}

public func agentsLayout(body: Rect, _ s: AgentsPaneState) -> AgentsLayout {
    var l = AgentsLayout()
    let left = body.x + 30, w = body.w - 60
    l.onOff = Rect(left, body.y + 14, w, 22)
    l.sessions = Rect(left, body.y + 74, 250, Double(AgentsLayout.maxSessions) * 22)
    for i in 0..<min(s.sessions.count, AgentsLayout.maxSessions) {
        l.sessionRows.append(Rect(left, l.sessions.y + Double(i) * 22, 250, 22))
    }
    l.digest = Rect(left + 262, l.sessions.y, w - 262, l.sessions.h)
    l.grants = Rect(left, l.sessions.y + l.sessions.h + 40, w, Double(AgentsLayout.maxGrants) * 26)
    for i in 0..<min(s.grants.count, AgentsLayout.maxGrants) {
        let r = Rect(left, l.grants.y + Double(i) * 26, w, 26)
        l.grantRows.append(r)
        l.revoke.append(Rect(r.x + r.w - 92, r.y + 2, 84, 22))
    }
    l.noteY = l.grants.y + l.grants.h + 24
    return l
}

public enum AgentsHit: Equatable, Sendable {
    case session(Int), revoke(Int), onOff
}

public func agentsHit(_ l: AgentsLayout, _ s: AgentsPaneState, x: Double, y: Double) -> AgentsHit? {
    if l.onOff.contains(x, y) { return .onOff }
    for (i, r) in l.revoke.enumerated() where r.contains(x, y) { return .revoke(i) }
    for (i, r) in l.sessionRows.enumerated() where r.contains(x, y) { return .session(i) }
    return nil
}

/// The digest as paragraphs to wrap: an agent's answer may hold line breaks,
/// which the word wrapper would draw as a missing glyph (seen on the
/// 12700KF), so each is a paragraph of its own.
public func agentsDigestParagraphs(_ digest: [String]) -> [String] {
    digest.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

public func paintAgentsPane(_ cr: OpaquePointer, _ l: AgentsLayout, _ s: AgentsPaneState) {
    func box(_ r: Rect) {
        Draw.setColor(cr, Color(1, 1, 1)); cairo_rectangle(cr, r.x, r.y, r.w, r.h); cairo_fill(cr)
        Draw.setColor(cr, Color(0.6, 0.6, 0.6)); cairo_set_line_width(cr, 1)
        cairo_rectangle(cr, r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1); cairo_stroke(cr)
    }
    Draw.checkbox(cr, Rect(l.onOff.x, l.onOff.y + 3, 16, 16), checked: s.on)
    Draw.textLeft(cr, "Let agents run on this computer", x: l.onOff.x + 24, baselineY: l.onOff.y + 15,
                  color: Theme.bodyText, size: 13)
    Draw.textLeft(cr, s.on ? "An agent runs only when you ask, confined, and only with what you give it."
                           : "Off: no Agent window, menu item, chord or Ask the Agent, and no agent runs.",
                  x: l.onOff.x + 24, baselineY: l.onOff.y + 32, color: Theme.secondaryText, size: 11)
    Draw.textLeft(cr, "What agents did, session by session:", x: l.sessions.x, baselineY: l.sessions.y - 12,
                  color: Theme.bodyText, size: 13)
    box(l.sessions)
    if s.sessions.isEmpty {
        Draw.textLeft(cr, "No agent has run yet.", x: l.sessions.x + 10, baselineY: l.sessions.y + 16,
                      color: Theme.secondaryText, size: 12)
    }
    for (i, (t, r)) in zip(s.sessions, l.sessionRows).enumerated() {
        let on = i == s.selected
        if on { Draw.setColor(cr, Color(0.22, 0.46, 0.84)); cairo_rectangle(cr, r.x + 1, r.y, r.w - 2, r.h); cairo_fill(cr) }
        Draw.textLeft(cr, "\(t.started) · \(t.agentClass)", x: r.x + 8, baselineY: r.y + 15,
                      color: on ? Color(1, 1, 1) : Theme.bodyText, size: 12)
    }
    box(l.digest)
    cairo_save(cr)
    cairo_rectangle(cr, l.digest.x, l.digest.y, l.digest.w, l.digest.h); cairo_clip(cr)
    // The last lines that fit: a session reads to its end.
    var lines: [String] = []
    if let i = s.selected, s.sessions.indices.contains(i) {
        lines.append(s.sessions[i].line)
        lines.append("")
    }
    for d in agentsDigestParagraphs(s.digest) { lines += wrapWords(cr, d, width: l.digest.w - 16, size: 11) }
    let fit = Int((l.digest.h - 10) / 15)
    let shown = lines.count > fit ? Array(lines.prefix(2)) + Array(lines.suffix(fit - 2)) : lines
    for (k, line) in shown.enumerated() {
        Draw.textLeft(cr, line, x: l.digest.x + 8, baselineY: l.digest.y + 16 + Double(k) * 15,
                      color: k == 0 ? Theme.bodyText : Theme.bodyText, size: 11, style: k == 0 ? .bold : .regular)
    }
    cairo_restore(cr)

    Draw.textLeft(cr, "Files given to confined applications:", x: l.grants.x, baselineY: l.grants.y - 12,
                  color: Theme.bodyText, size: 13)
    box(l.grants)
    if s.grants.isEmpty {
        Draw.textLeft(cr, "None: nothing confined holds one of your files.", x: l.grants.x + 10, baselineY: l.grants.y + 17,
                      color: Theme.secondaryText, size: 12)
    }
    for (i, (g, r)) in zip(s.grants, l.grantRows).enumerated() {
        Draw.textLeft(cr, g.line, x: r.x + 8, baselineY: r.y + 17, color: Theme.bodyText, size: 12)
        Draw.gelButton(cr, l.revoke[i], label: "Revoke", blue: false, pressed: false)
    }
    if !s.note.isEmpty {
        Draw.textLeft(cr, s.note, x: l.grants.x, baselineY: l.noteY, color: Theme.bodyText, size: 12)
    }
}

/// Reading it all: the sessions on disk, newest first, the selected one's
/// digest, and the grants the keeper reports.
public enum AgentsPaneIO {
    static func read(_ path: String) -> String? {
        guard let f = fopen(path, "r") else { return nil }
        defer { fclose(f) }
        var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
        while true { let n = fread(&buf, 1, buf.count, f); if n <= 0 { break }; out += buf[0..<n] }
        return String(decoding: out, as: UTF8.self)
    }

    public static func sessions(in dir: String = AgentsPaneState.logs) -> [TranscriptSummary] {
        guard let d = opendir(dir) else { return [] }
        defer { closedir(d) }
        var ids: [String] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if !name.hasPrefix(".") { ids.append(name) }
        }
        return ids.sorted(by: >).compactMap { id in
            read(dir + "/" + id + "/transcript.jsonl").map { Transcript.summary(id: id, lines: Transcript.lines($0)) }
        }
    }

    public static func digest(_ id: String, in dir: String = AgentsPaneState.logs) -> [String] {
        Transcript.digest(Transcript.lines(read(dir + "/" + id + "/transcript.jsonl") ?? ""))
    }

    /// The keeper's grants; nil when the session's jails are not running.
    public static func grants() -> [AgentGrantRow]? {
        var m = Msg(); m.set("method", "grants")
        guard let r = try? Current.call("jails", m), r.bool("ok") == true else { return nil }
        return unlist(r.bytes("grants") ?? []).compactMap(AgentGrantRow.parse)
    }

    /// Take grant `g` back; nil on success, else why not.
    public static func revoke(_ g: AgentGrantRow) -> String? {
        var m = Msg(); m.set("method", "revoke"); m.set("jail", g.jail); m.set("grant", g.n)
        guard let r = try? Current.call("jails", m) else { return "the session's jails are not running" }
        return r.bool("ok") == true ? nil : (r.string("error") ?? "refused")
    }

    /// JailWire's list encoding (NUL-separated), without linking jaild.
    static func unlist(_ b: [UInt8]) -> [String] {
        b.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }
}
