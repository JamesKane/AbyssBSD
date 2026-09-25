// AppMenuRegistrar — the name a Qt application looks for (PHASE10.md P10.7).
//
// Qt exports its menu bar over `com.canonical.dbusmenu` **only if**
// `com.canonical.AppMenu.Registrar` is owned on the session bus when it starts;
// otherwise it draws its own menubar in the window. On Wayland it then reports
// where the menu is through the compositor (`org_kde_kwin_appmenu`), not through
// this service — the X11 methods below exist because the interface has them
// and a client may call them, and they answer honestly: a window id is an X11
// idea and means nothing here.

import DBus

public final class AppMenuRegistrar {
    public static let busName = "com.canonical.AppMenu.Registrar"
    static let interface = "com.canonical.AppMenu.Registrar"
    static let path = "/com/canonical/AppMenu/Registrar"

    /// X11 window id → (service, path), as RegisterWindow told us.
    public private(set) var windows: [UInt32: (String, String)] = [:]

    public init(connection conn: DBusConnection) throws {
        let code = try conn.requestName(AppMenuRegistrar.busName)
        guard code == 1 else {
            throw DBusError("\(AppMenuRegistrar.busName) is owned by somebody else (reply \(code))")
        }
        conn.handle(AppMenuRegistrar.interface, "RegisterWindow") { [weak self] call in
            if case .uint32(let id)? = call.body.first,
               case .objectPath(let p)? = call.body.dropFirst().first {
                self?.windows[id] = (call.sender ?? "", p)
            }
            return .methodReturn(to: call)
        }
        conn.handle(AppMenuRegistrar.interface, "UnregisterWindow") { [weak self] call in
            if case .uint32(let id)? = call.body.first { self?.windows[id] = nil }
            return .methodReturn(to: call)
        }
        conn.handle(AppMenuRegistrar.interface, "GetMenuForWindow") { [weak self] call in
            guard case .uint32(let id)? = call.body.first, let w = self?.windows[id] else {
                return .error(to: call, name: "com.canonical.AppMenu.Registrar.Error.NoMenu",
                              message: "no menu registered for that window")
            }
            return .methodReturn(to: call, body: [.string(w.0), .objectPath(w.1)])
        }
    }
}
