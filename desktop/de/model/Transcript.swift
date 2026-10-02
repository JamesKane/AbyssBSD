// Transcript — reading an agent session's log back, for a person
// (PHASE18 P18.11b).
//
// abyss-model and abyss-vocab append JSON lines to
// ~/Library/Logs/Agents/SESSION/transcript.jsonl: every request and reply,
// refusal and raise, give and take, requester and answer. That is the record;
// this is how the Preferences pane says it in sentences — what was asked, what
// the agent did with what, what it was refused, and what the person decided —
// without reading it as JSON. Pure, given the lines.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct TranscriptSummary: Equatable, Sendable {
    /// The session's ID (its directory's name): `YYYYMMDD-HHMMSS-CLASS-PID-N`.
    public var id: String
    public var agentClass: String
    /// "2026-10-02 17:30" from the ID.
    public var started: String
    public var questions: Int
    public var tokens: Int
    public var given: [String]

    public init(id: String, agentClass: String, started: String, questions: Int, tokens: Int, given: [String]) {
        self.id = id; self.agentClass = agentClass; self.started = started
        self.questions = questions; self.tokens = tokens; self.given = given
    }

    /// One line for a list: when, which class, how much, and what it drove.
    public var line: String {
        var s = "\(started) · \(agentClass) · \(questions) question\(questions == 1 ? "" : "s") · \(tokens) tokens"
        if !given.isEmpty { s += " · " + given.joined(separator: ", ") }
        return s
    }
}

public enum Transcript {
    /// The lines of a transcript file; a line that is not JSON is skipped,
    /// never fatal (a write cut short by a crash).
    public static func lines(_ text: String) -> [JSON] {
        text.split(separator: "\n").compactMap { try? JSON.parse(String($0)) }
    }

    /// `20261002-173010-agent-23133-1` → ("agent", "2026-10-02 17:30").
    public static func parseID(_ id: String) -> (agentClass: String, started: String) {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0].count == 8, parts[1].count == 6 else { return ("?", id) }
        let d = Array(parts[0]), t = Array(parts[1])
        let started = "\(String(d[0..<4]))-\(String(d[4..<6]))-\(String(d[6..<8])) \(String(t[0..<2])):\(String(t[2..<4]))"
        // The class is everything between the time and the trailing pid-n.
        let cls = parts.count >= 5 ? parts[2..<(parts.count - 2)].joined(separator: "-") : parts[2]
        return (cls, started)
    }

    public static func summary(id: String, lines: [JSON]) -> TranscriptSummary {
        let (cls, started) = parseID(id)
        var tokens = 0, questions = 0, given: [String] = []
        var users = 0
        for l in lines {
            switch (l["kind"]?.string, l["event"]?.string) {
            case ("reply", _): tokens = l["used"]?.int ?? tokens
            case ("request", _):
                let n = (l["request"]?["messages"]?.array ?? []).filter { $0["role"]?.string == "user" }.count
                if n > users { questions += n - users; users = n }
            case ("vocabulary", "given"): if let a = l["app"]?.string, !given.contains(a) { given.append(a) }
            case ("vocabulary", "taken"): given.removeAll { $0 == l["app"]?.string }
            default: break
            }
        }
        return TranscriptSummary(id: id, agentClass: cls, started: started, questions: questions, tokens: tokens, given: given)
    }

    /// The session in sentences, one an event, in order.
    public static func digest(_ lines: [JSON]) -> [String] {
        var out: [String] = []
        var users = 0
        func time(_ l: JSON) -> String {
            guard let t = l["t"]?.number else { return "" }
            var secs = time_t(t), tmv = tm()
            localtime_r(&secs, &tmv)
            func two(_ n: Int32) -> String { n < 10 ? "0\(n)" : "\(n)" }
            return "\(two(tmv.tm_hour)):\(two(tmv.tm_min)):\(two(tmv.tm_sec))  "
        }
        for l in lines {
            let at = time(l)
            switch (l["kind"]?.string, l["event"]?.string) {
            case ("request", _):
                // A request carries the whole conversation: what is new is the
                // user's turns since the last.
                let msgs = (l["request"]?["messages"]?.array ?? []).filter { $0["role"]?.string == "user" }
                for m in msgs.dropFirst(users) { out.append(at + "You asked: " + (m["content"]?.string ?? "")) }
                users = max(users, msgs.count)
            case ("reply", _):
                let msg = l["reply"]?["choices"]?[0]?["message"]
                for c in msg?["tool_calls"]?.array ?? [] {
                    out.append(at + "  The agent called \(c["function"]?["name"]?.string ?? "?")(\(c["function"]?["arguments"]?.string ?? ""))")
                }
                if let text = msg?["content"]?.string, !text.isEmpty { out.append(at + "The agent answered: " + text) }
            case ("refused", _):
                out.append(at + "Stopped: " + (l["message"]?.string ?? "refused"))
            case ("raised", _):
                out.append(at + "You allowed \(l["by"]?.int ?? 0) more tokens")
            case ("failed", _):
                out.append(at + "The model did not answer: " + (l["message"]?.string ?? ""))
            case ("fetch", let e?):
                let host = l["host"]?.string ?? ""
                switch e {
                case "asked": out.append(at + "The agent asked to reach \(host) (\(l["url"]?.string ?? ""))")
                case "permitted": out.append(at + "You allowed the agent to reach \(host)")
                case "denied": out.append(at + "You did not allow the agent to reach \(host)")
                case "fetched": out.append(at + "  Fetched \(l["url"]?.string ?? "") (\(l["status"]?.int ?? 0), \(l["bytes"]?.int ?? 0) bytes)")
                case "redirected": out.append(at + "  Redirected to \(l["to"]?.string ?? "")")
                case "refused": out.append(at + "Refused \(l["url"]?.string ?? ""): \(l["reason"]?.string ?? "")")
                default: break
                }
            case ("vocabulary", let e?):
                let app = l["app"]?.string ?? "?"
                switch e {
                case "given": out.append(at + "You gave the agent \(app)")
                case "taken": out.append(at + "You took \(app) back")
                case "asked": out.append(at + "The agent asked to write with \(app) (\(l["title"]?.string ?? l["verb"]?.string ?? ""))")
                case "permitted": out.append(at + "You allowed \(app) to write for the agent")
                case "denied": out.append(at + "You did not allow \(app) to write")
                case "refused": out.append(at + "Refused: \(app) was not given to the agent")
                case "activate":
                    let verb = l["verb"]?.string ?? "?"
                    let result = l["result"]?.string ?? l["failed"].map { _ in "failed" } ?? "?"
                    out.append(at + "  \(app) ran \(verb): \(result == "refused" ? "refused (\(l["why"]?.string ?? ""))" : result)")
                default: break
                }
            default: break
            }
        }
        return out
    }
}
