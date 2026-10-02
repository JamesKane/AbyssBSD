// abyss-model — the only way to a model (PHASE18 P18.7).
//
//   abyss-model serve --listen PATH --session ID --budget TOKENS --transcript DIR
//                     (--stub FILE | --backend http://HOST:PORT[/path])
//       OpenAI-compatible chat completions over the unix socket at PATH, for
//       one agent session: its budget, its append-only transcript in DIR, and
//       its backend — canned replies from FILE (a JSON array), or a server
//       speaking the same wire (llama.cpp's llama-server). The keeper puts
//       PATH inside an agent's jail; the transcript stays outside it.
//   abyss-model tier
//       this machine's VRAM and RAM, its tier, and the model proposed for it
//       (PHASE18 §6b.1).

import CurrentIPC
import Model
import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func die(_ s: String) -> Never { emit(2, "abyss-model: \(s)"); exit(1) }

func readFile(_ path: String) -> [UInt8]? {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        out += buf[0..<n]
    }
    return out
}

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch args.first {
case "tier":
    var boot = ""
    if let b = readFile("/var/run/dmesg.boot") { boot = String(decoding: b, as: UTF8.self) }
    var ram = 0
    let r = Spawn.run(["sysctl", "-n", "hw.physmem"], stderr: .capture)
    if r.succeeded, let bytes = Int(r.stdoutText.split(separator: "\n").first ?? "") { ram = bytes >> 20 }
    else if let m = readFile("/proc/meminfo"),
            let line = String(decoding: m, as: UTF8.self).split(separator: "\n").first(where: { $0.hasPrefix("MemTotal:") }),
            let kb = Int(line.split(separator: " ").dropFirst().first ?? "") { ram = kb >> 10 }
    let mem = MachineMemory(vramMiB: MachineMemory.vram(fromBootMessages: boot), ramMiB: ram)
    let tier = ModelTier.choose(mem)
    emit(1, "vram=\(mem.vramMiB.map { "\($0)M" } ?? "none") ram=\(mem.ramMiB)M tier=\(tier.rawValue) proposed=\(tier.proposed.model) \(tier.proposed.quant)")

case "serve":
    guard let listen = opt("--listen"), let session = opt("--session"), let dir = opt("--transcript"),
          let budget = opt("--budget").flatMap(Int.init), budget > 0 else {
        die("serve needs --listen PATH --session ID --budget TOKENS --transcript DIR")
    }
    let backend: ModelBackend
    if let stub = opt("--stub") {
        guard let b = readFile(stub), let j = try? JSON.parse(b), let replies = j.array else {
            die("--stub \(stub) is not a JSON array of chat completions")
        }
        backend = StubBackend(replies: replies)
    } else if let url = opt("--backend") {
        guard let h = HTTPBackend(url: url) else { die("--backend must be http://HOST:PORT[/path]") }
        backend = h
    } else { die("serve needs --stub FILE or --backend URL") }
    let fd: Int32
    do { fd = try TranscriptFile.open(dir: dir) } catch { die("\(error)") }
    signal(SIGPIPE, SIG_IGN)
    let server: Current.Server
    do { server = try Current.Server(path: listen, mode: 0o600) } catch { die("cannot listen at \(listen): \(error)") }
    let s = ModelSession(id: session, budget: budget, backend: backend, transcript: fd)
    emit(1, "ready (session \(session), budget \(budget) tokens, backend \(backend.name))")
    while true {
        guard let c = try? server.accept() else { continue }
        // A slow reply is the model's, not the client's: no receive timeout
        // on the answer, only on reading the request.
        if let req = try? HTTP.readRequest(c) {
            let r = s.handle(req)
            try? HTTP.send(r, on: c)
            if r.status == 429 { emit(1, "refused: budget (\(s.used) of \(s.budget))") }
        }
        close(c)
    }

default:
    emit(2, "usage: abyss-model serve --listen PATH --session ID --budget N --transcript DIR (--stub FILE | --backend URL) | tier")
    exit(2)
}
