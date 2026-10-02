// ModelSession — what `abyss-model` does with one agent session's requests
// (PHASE18 P18.7).
//
// Everything between an agent and a model passes here, so this is where the
// rules are that the agent cannot argue with:
//
//   - **the budget**: tokens per session, counted from what the backend says
//     each reply used. A request once the budget is spent is refused — HTTP
//     429 with the reason in the body — and nothing is sent anywhere. The
//     stop is at the next call, never mid-reply (PLAN: "stopping at the next
//     tool call with the reason visible");
//   - **the transcript**: every request, reply and refusal, one JSON line
//     each, appended to a file outside the jail and never rewritten — the
//     session *is* the log, and it outlives the process;
//   - **one wire format**: OpenAI-compatible chat completions in and out,
//     whatever the backend. Streaming is not offered yet, and is refused in
//     words rather than half-served.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Where a session's completions come from.
public protocol ModelBackend: AnyObject {
    var name: String { get }
    func complete(_ request: JSON) throws -> JSON
}

/// Canned replies, in order and then round again — for every test (P18.7):
/// each is a chat-completion object, tool calls and usage included.
public final class StubBackend: ModelBackend {
    public let name = "stub"
    let replies: [JSON]
    var next = 0
    /// How many requests reached it — what a refusal must leave unchanged.
    public private(set) var calls = 0
    /// A pause before each reply — a test's stand-in for a model that takes
    /// its time (the Agent window shows tool calls while it waits).
    public var delayMs = 0
    public init(replies: [JSON]) { self.replies = replies }
    public func complete(_ request: JSON) throws -> JSON {
        calls += 1
        if delayMs > 0 { usleep(useconds_t(delayMs) * 1000) }
        guard !replies.isEmpty else { throw HTTP.Failure("the stub has no replies") }
        defer { next = (next + 1) % replies.count }
        return replies[next]
    }
}

/// A server speaking the same wire — llama.cpp's `llama-server` on loopback.
public final class HTTPBackend: ModelBackend {
    public let name: String
    let endpoint: HTTP.Endpoint, path: String
    public init(host: String, port: UInt16, path: String = "/v1/chat/completions") {
        endpoint = .tcp(host: host, port: port); self.path = path
        name = "http://\(host):\(port)\(path)"
    }
    public init(socket: String, name: String, path: String = "/v1/chat/completions") {
        endpoint = .unix(path: socket); self.path = path; self.name = name
    }
    /// `http://HOST:PORT[/path]`.
    public convenience init?(url: String) {
        guard url.hasPrefix("http://") else { return nil }
        let rest = url.dropFirst(7)
        let hostport = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let path = rest.count > hostport.count ? String(rest.dropFirst(hostport.count)) : "/v1/chat/completions"
        let hp = hostport.split(separator: ":")
        guard hp.count == 2, let port = UInt16(hp[1]) else { return nil }
        self.init(host: String(hp[0]), port: port, path: path)
    }
    public func complete(_ request: JSON) throws -> JSON {
        let r = try HTTP.call(endpoint, method: "POST", path: path, json: request)
        guard r.status == 200 else {
            throw HTTP.Failure("the backend said \(r.status): \(String(decoding: r.body.prefix(300), as: UTF8.self))")
        }
        return try JSON.parse(r.body)
    }
}

public final class ModelSession {
    public let id: String
    public let budget: Int
    public private(set) var used = 0
    public private(set) var refusals = 0
    let backend: ModelBackend
    let transcript: Int32
    let clock: () -> Double

    /// `transcript`: an open, append-only descriptor (`TranscriptFile.open`).
    public init(id: String, budget: Int, backend: ModelBackend, transcript: Int32,
                clock: @escaping () -> Double = ModelSession.now) {
        self.id = id; self.budget = budget; self.backend = backend; self.transcript = transcript; self.clock = clock
    }

    public static func now() -> Double {
        var ts = timespec(); clock_gettime(CLOCK_REALTIME, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    /// Answer one HTTP request.
    public func handle(_ req: HTTPRequest) -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/v1/models"):
            return HTTPResponse(status: 200, reason: "OK", json: .object([
                ("object", .string("list")),
                ("data", .array([.object([("id", .string(backend.name)), ("object", .string("model"))])])),
            ]))
        case ("POST", "/v1/chat/completions"):
            return complete(req.body)
        default:
            return refuse(404, "Not Found", "not_found", "abyss-model answers POST /v1/chat/completions and GET /v1/models")
        }
    }

    func complete(_ body: [UInt8]) -> HTTPResponse {
        let request: JSON
        do { request = try JSON.parse(body) } catch {
            return refuse(400, "Bad Request", "invalid_request", "the body is not JSON: \(error)")
        }
        guard request["messages"]?.array != nil else {
            return refuse(400, "Bad Request", "invalid_request", "a chat completion needs messages")
        }
        if request["stream"]?.bool == true {
            return refuse(400, "Bad Request", "invalid_request", "streaming is not offered yet: ask with stream false")
        }
        // **The budget, before anything leaves.** Spent means spent: the next
        // call is refused with its reason, and the transcript says so.
        if used >= budget {
            refusals += 1
            let why = "the session's budget of \(budget) tokens is spent (\(used) used)"
            log("refused", [("reason", .string("budget")), ("message", .string(why)), ("request", request)])
            return refuse(429, "Too Many Requests", "budget", why)
        }
        log("request", [("request", request)])
        let reply: JSON
        do { reply = try backend.complete(request) } catch {
            log("failed", [("message", .string("\(error)"))])
            return refuse(502, "Bad Gateway", "backend", "the model did not answer: \(error)")
        }
        let tokens = reply["usage"]?["total_tokens"]?.int
            ?? ((reply["usage"]?["prompt_tokens"]?.int ?? 0) + (reply["usage"]?["completion_tokens"]?.int ?? 0))
        used += tokens
        log("reply", [("reply", reply), ("tokens", .number(Double(tokens))), ("used", .number(Double(used)))])
        return HTTPResponse(status: 200, reason: "OK", json: reply)
    }

    func refuse(_ status: Int, _ reason: String, _ type: String, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, json: .object([
            ("error", .object([("type", .string(type)), ("message", .string(message))])),
        ]))
    }

    /// One transcript line: when, which session, what kind, and the rest.
    func log(_ kind: String, _ fields: [(String, JSON)]) {
        let line = JSON.object([("t", .number((clock() * 1000).rounded() / 1000)), ("session", .string(id)),
                                ("kind", .string(kind)), ("budget", .number(Double(budget)))] + fields).text + "\n"
        let b = Array(line.utf8)
        _ = b.withUnsafeBufferPointer { write(transcript, $0.baseAddress, b.count) }
    }
}

public enum TranscriptFile {
    /// Open `dir/transcript.jsonl` for appending only — O_APPEND, so no write
    /// lands anywhere but the end — creating the directory (0700) and the file
    /// (0600) if need be.
    public static func open(dir: String) throws -> Int32 {
        var made = ""
        for part in dir.split(separator: "/") {
            made += "/" + part
            if mkdir(made, 0o700) != 0 && errno != EEXIST { throw HTTP.Failure("mkdir \(made): \(String(cString: strerror(errno)))") }
        }
        let fd = Glibc_open(dir + "/transcript.jsonl", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HTTP.Failure("open the transcript: \(String(cString: strerror(errno)))") }
        return fd
    }
}

#if canImport(Glibc)
@inline(__always) func Glibc_open(_ p: String, _ f: Int32, _ m: mode_t) -> Int32 { Glibc.open(p, f, m) }
#else
@inline(__always) func Glibc_open(_ p: String, _ f: Int32, _ m: mode_t) -> Int32 { Darwin.open(p, f, m) }
#endif

// MARK: - which model, for this machine (PHASE18 §6b.1)

public struct MachineMemory: Equatable, Sendable {
    public var vramMiB: Int?
    public var ramMiB: Int
    public init(vramMiB: Int?, ramMiB: Int) { self.vramMiB = vramMiB; self.ramMiB = ramMiB }

    /// The VRAM the GPU driver reported at boot ("amdgpu: 12272M of VRAM memory
    /// ready" on the 12700KF's RX 6750 XT), the largest if several.
    public static func vram(fromBootMessages text: String) -> Int? {
        var best: Int?
        for line in text.split(separator: "\n") where line.contains("of VRAM memory ready") {
            let words = line.split(separator: " ")
            if let i = words.firstIndex(where: { $0.hasSuffix("M") && Int($0.dropLast()) != nil }),
               let n = Int(words[i].dropLast()) { best = max(best ?? 0, n) }
        }
        return best
    }
}

public enum ModelTier: String, Equatable, Sendable, CaseIterable {
    case cpu, gpu8, gpu12, gpu24

    /// The tier, by VRAM first: a model that has to spill out of VRAM runs at
    /// a fraction of the speed, so RAM decides only when there is no GPU.
    public static func choose(_ m: MachineMemory) -> ModelTier {
        guard let v = m.vramMiB, v >= 6 * 1024 else { return .cpu }
        if v >= 22 * 1024 { return .gpu24 }
        if v >= 11 * 1024 { return .gpu12 }
        return .gpu8
    }

    /// The default model and context (PHASE18 §6b.1), as measured on the
    /// 12700KF's 6750 XT (2026-10-02, measure-model.sh). The context is
    /// chosen so the desktop keeps room: Granite 8B Q4 took 6.1 GB at 8K,
    /// 7.7 GB at 16K and 10.2 GB at 32K; Q8 took 11.4 GB at 16K, leaving
    /// 775 MiB, which is why the 12 GB tier is Q4 and not Q8.
    public var proposed: (model: String, quant: String, context: Int) {
        switch self {
        case .cpu: return ("MiniCPM5-2B", "Q4_K_M", 8192)
        case .gpu8: return ("Granite-4.2-8B", "Q4_K_M", 8192)
        case .gpu12: return ("Granite-4.2-8B", "Q4_K_M", 16384)
        case .gpu24: return ("Granite-4.2-30B", "Q4_K_M", 16384)
        }
    }
}
