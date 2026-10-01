// abyss-loginctl — ask the authenticator, from a shell (PHASE16 P16.1).
//
//   abyss-loginctl [--socket PATH] verify      the password on stdin, one line
//   abyss-loginctl [--socket PATH] power sleep|restart|shut-down   (P16.4a)
//
// Prints `accepted`, `refused`, `wait <ms>` or `unavailable: <why>`, and exits
// 0 only for `accepted`. For tests and for people; the lock screen links Login.

import Login

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

var socket = Login.defaultSocket
var args = Array(CommandLine.arguments.dropFirst())
if args.count >= 2, args[0] == "--socket" { socket = args[1]; args.removeFirst(2) }
if args.count == 2, args[0] == "power" {
    guard let action = PowerAction(rawValue: args[1]) else { print("no such action: \(args[1])"); exit(2) }
    do {
        let r = try PowerClient.request(action, socket: socket)
        if r.bool("ok") == true { print("ok"); exit(0) }
        print("refused: \(r.string("error") ?? "?")"); exit(1)
    } catch { print("error: \(error)"); exit(1) }
}
guard args == ["verify"] else {
    print("usage: abyss-loginctl [--socket PATH] verify | power sleep|restart|shut-down")
    exit(2)
}
// One line from stdin, without its newline, as bytes.
var password: [UInt8] = []
var c: Int32
repeat { c = getchar(); if c != EOF && c != 10 { password.append(UInt8(c)) } } while c != EOF && c != 10
defer { for k in password.indices { password[k] = 0 } }
do {
    switch try LoginClient.verify(password: password, socket: socket) {
    case .accepted: print("accepted"); exit(0)
    case .refused: print("refused"); exit(1)
    case .wait(let ms): print("wait \(ms)"); exit(1)
    case .unavailable(let why): print("unavailable: \(why)"); exit(1)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
