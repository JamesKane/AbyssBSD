// MenuService — an application publishing its vocabulary (PHASE10.md P10.2).
//
// The application supplies a `MenuProvider` — its model, and how to validate
// and perform one command — and folds `fd` into its run loop with
// `Display.addFileDescriptor`, calling `serviceReadable()` when it fires. That is
// `NotifyCenter`'s shape (HANDOFF §2.18): no thread, no second loop, and a
// request is answered between frames like any other input.
//
// What the service checks so that no application has to: that the verb exists,
// that the arguments are the ones the verb declares and parse as their types,
// and that the command is enabled — so a script calling a disabled command is
// told *why*, in the same words the menu would have used, and the application's
// own `perform` is never reached with something it did not ask for.

import CurrentIPC
import MenuModel

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public protocol MenuProvider: AnyObject {
    /// The vocabulary. May change; call `MenuService.changed()` when it does.
    var menuModel: MenuBarModel { get }
    /// Whether `command` can run now, and why not.
    func menuValidate(_ command: Command) -> Enablement
    /// Run it. Only ever called for an enabled command whose arguments passed
    /// `MenuService.check`.
    func menuPerform(_ command: Command, arguments: [String: String]) -> CommandResult
}

public final class MenuService {
    public let name: String
    private let server: Current.Server
    private weak var provider: MenuProvider?
    /// Connections that asked to be told when the vocabulary changes.
    private var subscribers: [Int32] = []

    /// The listening socket, for the application's run loop.
    public var fd: Int32 { server.fd }

    public init(name: String, provider: MenuProvider) throws {
        self.name = name
        self.provider = provider
        server = try Current.Server(service: name)
        try server.setNonBlocking(true)
    }

    deinit {
        for s in subscribers { close(s) }
        server.shutdownAndUnlink()
    }

    /// The listener is readable: answer one connection.
    public func serviceReadable() {
        guard let c = try? server.accept() else { return }   // EAGAIN: nothing after all
        guard var request = try? Current.receive(on: c) else { close(c); return }
        defer { request.closeFDs() }   // a menu request carries no descriptors
        if request.string("method") == "subscribe" {
            var ok = Msg(); ok.set("ok", true)
            if (try? Current.send(ok, on: c)) != nil { subscribers.append(c) } else { close(c) }
            return
        }
        let reply = handle(request)
        try? Current.send(reply, on: c)
        close(c)
    }

    /// The vocabulary changed — a title, an item, a menu. Pushed to every
    /// subscriber; one that has gone away is dropped here, which is the first
    /// moment anybody could know.
    public func changed() {
        var m = Msg(); m.set("method", "changed")
        subscribers.removeAll { s in
            if (try? Current.send(m, on: s)) != nil { return false }
            close(s)
            return true
        }
    }

    public var subscriberCount: Int { subscribers.count }

    /// One request → one reply. Internal so a test can drive it with no socket.
    func handle(_ request: Msg) -> Msg {
        guard let p = provider else { return MenuWire.errorReply("the application has gone") }
        let model = p.menuModel
        switch request.string("method") {
        case "describe":
            return MenuWire.describeReply(model, enablement: p.menuValidate)
        case "validate":
            return MenuWire.validateReply(model, enablement: p.menuValidate)
        case "activate":
            guard let verb = request.string("verb") else {
                return MenuWire.errorReply("activate needs a verb")
            }
            guard let command = model.command(verb) else {
                return MenuWire.resultReply(.refused("\(model.appName) has no verb \(verb)"))
            }
            let args: [String: String]
            do { args = try MenuWire.arguments(of: request) } catch {
                return MenuWire.resultReply(.refused("\(error)"))
            }
            if let why = MenuService.check(command, args) {
                return MenuWire.resultReply(.refused(why))
            }
            if case .disabled(let why) = p.menuValidate(command) {
                return MenuWire.resultReply(.refused(why))
            }
            return MenuWire.resultReply(p.menuPerform(command, arguments: args))
        default:
            return MenuWire.errorReply("unknown method \(request.string("method") ?? "(none)")")
        }
    }

    /// Why `args` are not what `command` declares, or nil if they are. Every
    /// declared argument is required, and nothing undeclared is accepted — a
    /// misspelt name must fail, not be ignored.
    public static func check(_ command: Command, _ args: [String: String]) -> String? {
        let declared = Set(command.arguments.map(\.name))
        if let extra = args.keys.sorted().first(where: { !declared.contains($0) }) {
            return "\(command.verb) takes no argument \(extra)"
        }
        for a in command.arguments {
            guard let v = args[a.name] else {
                return "\(command.verb) needs \(a.name) (\(a.type.rawValue)): \(a.summary)"
            }
            switch a.type {
            case .string:
                break
            case .path:
                if !v.hasPrefix("/") { return "\(a.name) must be an absolute path, not \(v)" }
            case .integer:
                if Int(v) == nil { return "\(a.name) must be an integer, not \(v)" }
            case .bool:
                if v != "true" && v != "false" { return "\(a.name) must be true or false, not \(v)" }
            }
        }
        return nil
    }
}
