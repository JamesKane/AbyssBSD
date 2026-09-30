// abyss-vt — a program on a pseudo-terminal, through Terminal's screen model,
// with no display (PHASE15 P15.4a).
//
// How "vi and top draw correctly" is asserted before there is a window to draw
// them in: the real program on a real pty, its output through `Screen`, keys
// typed on a script, and the screen printed as text for a test to read.
//
//   abyss-vt [--rows N] [--cols N] [--step 'KEYS'@MS | --resize ROWSxCOLS@MS]...
//            [--settle MS] -- PROGRAM ARGS…
//
// Each `--step` waits until the program has been quiet for MS milliseconds
// (at most 5 s), then types KEYS, in which `\e`, `\r`, `\n`, `\t` and `\xHH`
// are escapes; a `--resize` step gives the terminal a new size, as a window
// being resized does (the program gets SIGWINCH). After the last step it waits for quiet once more (`--settle`,
// default 300 ms) and prints:
//
//   title: …   cursor: ROW,COL   alternate: yes|no   exited: STATUS|no
//   |line 1…|
//   …
//
// Every line is framed in `|` so trailing spaces and empty lines are visible.

import Pty
import Terminal

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func die(_ s: String) -> Never {
    let m = "abyss-vt: \(s)\n"
    _ = m.withCString { write(2, $0, strlen($0)) }
    exit(2)
}

func unescape(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = Array(s.utf8)[...]
    while let b = it.popFirst() {
        guard b == 0x5C, let n = it.popFirst() else { out.append(b); continue }
        switch n {
        case 0x65: out.append(0x1B)                             // \e
        case 0x72: out.append(0x0D)                             // \r
        case 0x6E: out.append(0x0A)                             // \n
        case 0x74: out.append(0x09)                             // \t
        case 0x78:                                              // \xHH
            let h = String(decoding: it.prefix(2), as: UTF8.self)
            it = it.dropFirst(2)
            out.append(UInt8(h, radix: 16) ?? 0x3F)
        default: out.append(n)
        }
    }
    return out
}

var rows = 24, cols = 80, settle = 300
enum Step { case keys([UInt8]), resize(Int, Int) }
var steps: [(step: Step, quietMs: Int)] = []
var args = Array(CommandLine.arguments.dropFirst())
var program: [String] = []
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--rows": rows = Int(args.removeFirst()) ?? rows
    case "--cols": cols = Int(args.removeFirst()) ?? cols
    case "--settle": settle = Int(args.removeFirst()) ?? settle
    case "--step":
        let s = args.removeFirst()
        guard let at = s.lastIndex(of: "@"), let ms = Int(s[s.index(after: at)...]) else { die("--step wants KEYS@MS") }
        steps.append((.keys(unescape(String(s[..<at]))), ms))
    case "--resize":
        let s = args.removeFirst()
        guard let at = s.lastIndex(of: "@"), let ms = Int(s[s.index(after: at)...]) else { die("--resize wants ROWSxCOLS@MS") }
        let rc = s[..<at].split(separator: "x").compactMap { Int($0) }
        guard rc.count == 2 else { die("--resize wants ROWSxCOLS@MS") }
        steps.append((.resize(rc[0], rc[1]), ms))
    case "--": program = args; args = []
    default: die("unknown option \(a)")
    }
}
guard !program.isEmpty else { die("usage: abyss-vt [--rows N] [--cols N] [--step KEYS@MS]... -- PROGRAM ARGS…") }
guard let pty = Pty(program, rows: rows, cols: cols) else { die("cannot start \(program[0]) on a pty") }
var screen = Screen(rows: rows, cols: cols)

/// Read until the program has said nothing for `quietMs` (at most 5 s), or has
/// closed the terminal.
func drain(_ screen: inout Screen, _ pty: Pty, quietMs: Int) {
    var start = timespec(); clock_gettime(CLOCK_MONOTONIC, &start)
    func elapsedMs() -> Int {
        var now = timespec(); clock_gettime(CLOCK_MONOTONIC, &now)
        return (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1_000_000
    }
    while elapsedMs() < 5000 {
        guard pty.wait(timeoutMs: Int32(quietMs)) else { return }        // quiet long enough
        guard let bytes = pty.read() else { return }                      // closed
        screen.feed(bytes)
        if !screen.responses.isEmpty { pty.write(screen.responses); screen.responses = [] }
    }
}

for s in steps {
    drain(&screen, pty, quietMs: s.quietMs)
    switch s.step {
    case .keys(let k): pty.write(k)
    case .resize(let r, let c): screen.resize(rows: r, cols: c); pty.resize(rows: r, cols: c)
    }
}
drain(&screen, pty, quietMs: settle)
usleep(100_000)
let status = pty.reap()

var out = "title: \(screen.title)   cursor: \(screen.cursorRow + 1),\(screen.cursorCol + 1)   "
out += "alternate: \(screen.usingAlternate ? "yes" : "no")   exited: \(status.map { String($0) } ?? "no")\n"
for r in 0..<screen.rows {
    var line = String(String.UnicodeScalarView(screen.grid[r].map(\.scalar)))
    while line.last == " " { line.removeLast() }
    out += "|\(line)|\n"
}
print(out, terminator: "")
