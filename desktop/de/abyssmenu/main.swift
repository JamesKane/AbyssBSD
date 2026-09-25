// abyssmenu — ask an application what it can do, and have it do it
// (PHASE10.md P10.2).
//
//     abyssmenu list                              # applications publishing menus
//     abyssmenu describe finder                   # the vocabulary: verbs, keys, arguments
//     abyssmenu validate finder                   # what can run now, and why not
//     abyssmenu run finder file.new-folder        # invoke one verb; prints its result
//     abyssmenu run finder go.to-folder path=/tmp # ... with typed arguments
//
// The first consumer of an application's vocabulary is deliberately this one,
// which cannot draw a menu: if a verb is only usable from the menu bar, the
// surface is a drawing routine and not a vocabulary (PLAN.md, Phase 10). Phase
// 18's agent reads the same thing.
//
// Output is line-oriented for a script. `run` exits 0 on `ok`, 1 on `refused`
// (the reason on stderr), 2 when the application could not be reached.

import CurrentIPC
import MenuModel
import MenuWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func fail(_ s: String, code: Int32 = 2) -> Never { emit(2, "abyssmenu: \(s)"); exit(code) }

let usage = """
usage: abyssmenu list
       abyssmenu describe APP
       abyssmenu validate APP
       abyssmenu run APP VERB [NAME=VALUE ...]
"""

signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { emit(2, usage); exit(2) }

func service(_ i: Int) -> String {
    guard i < args.count else { emit(2, usage); exit(2) }
    do { return try MenuClient.resolve(args[i]) } catch { fail("\(error)") }
}

func state(_ e: Enablement?) -> String {
    switch e {
    case .enabled?:           return "enabled"
    case .disabled(let why)?: return "disabled (\(why))"
    case nil:                 return "unknown"
    }
}

switch cmd {
case "list":
    for s in MenuClient.services() {
        let app = (try? MenuClient.describe(s))?.model.appName ?? "?"
        emit(1, "\(app)\t\(s)")
    }

case "describe":
    let s = service(1)
    let d: (model: MenuBarModel, enablement: [String: Enablement])
    do { d = try MenuClient.describe(s) } catch { fail("\(s): \(error)") }
    emit(1, "app \(d.model.appName)")
    func show(_ menu: Menu, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        emit(1, "\(pad)menu \(menu.title)")
        for item in menu.items {
            switch item {
            case .separator: break
            case .submenu(let m): show(m, depth: depth + 1)
            case .command(let c):
                var line = "\(pad)  \(c.verb)\t\(c.title)"
                if let k = c.key { line += "\t\(k.display)" }
                line += "\t\(state(d.enablement[c.verb]))"
                emit(1, line)
                emit(1, "\(pad)    \(c.summary)")
                for a in c.arguments {
                    emit(1, "\(pad)    arg \(a.name): \(a.type.rawValue) — \(a.summary)")
                }
            }
        }
    }
    for m in d.model.menus { show(m, depth: 0) }

case "validate":
    let s = service(1)
    let v: [String: Enablement]
    do { v = try MenuClient.validate(s) } catch { fail("\(s): \(error)") }
    for verb in v.keys.sorted() { emit(1, "\(verb)\t\(state(v[verb]))") }

case "run":
    let s = service(1)
    guard args.count > 2 else { emit(2, usage); exit(2) }
    let verb = args[2]
    var arguments: [String: String] = [:]
    for a in args.dropFirst(3) {
        guard let eq = a.firstIndex(of: "=") else { fail("argument \(a) is not NAME=VALUE") }
        arguments[String(a[..<eq])] = String(a[a.index(after: eq)...])
    }
    let r: CommandResult
    do { r = try MenuClient.activate(s, verb: verb, arguments: arguments) } catch {
        fail("\(s): \(error)")
    }
    switch r {
    case .ok(let value):
        emit(1, value.map { "ok \($0)" } ?? "ok")
    case .refused(let why):
        emit(1, "refused")
        fail(why, code: 1)
    }

case "-h", "--help":
    emit(1, usage)

default:
    emit(2, usage)
    exit(2)
}
