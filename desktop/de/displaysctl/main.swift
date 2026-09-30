// abyss-displays — the displays, as wlr-output-management-v1 tells them, and a
// way to rearrange them (PHASE14 P14.7b).
//
//   abyss-displays list
//   abyss-displays test  NAME:WxH[@mHz]:X,Y[:SCALE] ...
//   abyss-displays apply NAME:WxH[@mHz]:X,Y[:SCALE] ...
//
// A display not named keeps what it has. The same protocol the Displays pane
// speaks (P14.7c), and any wlroots compositor would answer it: nothing here is
// undertow's.

import Surface

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func say(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func usage() -> Never {
    say(2, "usage: abyss-displays list | test|apply NAME:WxH[@mHz]:X,Y[:SCALE] ...")
    exit(2)
}

func show(_ c: DisplayConfigurator) {
    for h in c.displays {
        let cur = h.current.map { "\($0.width)x\($0.height)@\($0.refreshMilliHz)" } ?? "none"
        say(1, "display \(h.name) \(cur) at \(h.x),\(h.y) scale \(h.scale)" + (h.enabled ? "" : " disabled"))
        for m in h.modes {
            say(1, "  mode \(m.width)x\(m.height)@\(m.refreshMilliHz)" + (m.preferred ? " preferred" : "")
                + (m == h.current ? " current" : ""))
        }
    }
}

func parse(_ arg: String) -> DisplayConfigurator.Setting? {
    let f = arg.split(separator: ":")
    guard f.count == 3 || f.count == 4 else { return nil }
    let mr = f[1].split(separator: "@"), wh = mr[0].split(separator: "x"), xy = f[2].split(separator: ",")
    guard wh.count == 2, let w = Int32(wh[0]), let h = Int32(wh[1]), xy.count == 2,
          let x = Int32(xy[0]), let y = Int32(xy[1]) else { return nil }
    let r = mr.count == 2 ? Int32(mr[1]) : 0
    let scale = f.count == 4 ? Double(f[3]) : 1
    guard let r, let scale else { return nil }
    return .init(name: String(f[0]), width: w, height: h, refreshMilliHz: r, x: x, y: y, scale: scale)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first, ["list", "test", "apply"].contains(verb) else { usage() }
guard let c = DisplayConfigurator() else {
    say(2, "abyss-displays: no compositor, or it does not offer wlr-output-management-v1"); exit(1)
}
if verb == "list" { show(c); exit(0) }

var asked: [DisplayConfigurator.Setting] = []
for a in args.dropFirst() {
    guard let s = parse(a) else { say(2, "abyss-displays: '\(a)' is not NAME:WxH[@mHz]:X,Y[:SCALE]"); exit(2) }
    guard c.displays.contains(where: { $0.name == s.name }) else { say(2, "abyss-displays: there is no display \(s.name)"); exit(1) }
    asked.append(s)
}
// Everyone else as they are: a display left out of a configuration is turned off.
var all = asked
for h in c.displays where !asked.contains(where: { $0.name == h.name }) {
    guard let m = h.current else { continue }
    all.append(.init(name: h.name, width: m.width, height: m.height, refreshMilliHz: m.refreshMilliHz,
                     x: h.x, y: h.y, scale: h.scale))
}
let outcome = c.request(all, testOnly: verb == "test")
switch outcome {
case .succeeded:
    say(1, verb == "test" ? "test succeeded" : "applied")
    if verb == "apply" { c.awaitUpdate(); show(c) }
    exit(0)
case .failed: say(1, "\(verb) failed: the compositor refused it"); exit(1)
case .cancelled: say(1, "\(verb) cancelled: the displays changed meanwhile"); exit(1)
case .timedOut: say(1, "\(verb): the compositor never answered"); exit(1)
}
