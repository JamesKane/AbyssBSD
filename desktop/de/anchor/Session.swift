// Anchor — what the default session *is*, as a value.
//
// P8.4's whole content is an ordering and an environment variable, and both are
// decisions rather than syscalls, so they live here where a test can read them
// without starting six processes. `abyss/tests/live-session-gtk.sh` then proves
// the same list actually composes.
//
// The session, in the order it has to start:
//
//   bus       dbus-daemon on a socket WE name, so the address is knowable
//             before it exists and survives a restart of the daemon
//   portal    abyss-portal (P7.1) — our own portal, for our own apps
//   bridge    abyss-dbus (P8.2) — the same portal, for everyone else's
//   desktop   the wallpaper and its icons
//   menubar   the menu bar
//   dock      the Dock
//
// **Why the bus is first, and not just early.** `DBUS_SESSION_BUS_ADDRESS` has
// to be in the environment of the shell, because the shell is what *launches
// applications* — a GTK app double-clicked in the Finder inherits its bus from
// the Dock, which inherited it from `anchor`. Start the bus after the shell and
// every app launched from the desktop is on no bus at all, which looks exactly
// like a desktop with no portal.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What kind of session this is.
///
/// The live medium runs the same compositor, the same toolkit and the same
/// supervisor as the installed desktop — it just runs *one application* instead
/// of a shell. Making that a mode rather than a separate program is what keeps
/// the medium honest: if `anchor` can boot the installer, then the installer is
/// running on the real desktop, not on a special one built to demonstrate it.
public enum SessionMode: String, Sendable, Equatable {
    /// Wallpaper, menu bar, Dock — the desktop.
    case desktop
    /// Wallpaper and the installer, and nothing else. No Dock (there is nothing
    /// to launch), no menu bar (there is nothing to quit to), and no bus — a
    /// machine being installed has no foreign apps to serve.
    case installer
}

/// The session as a plan: what to run, in what order, and what to export first.
public struct SessionPlan: Equatable, Sendable {
    /// Everything to supervise, already ordered.
    public let components: [ComponentSpec]
    /// The value for `DBUS_SESSION_BUS_ADDRESS`, or nil when this session has no
    /// bus of its own.
    public let busAddress: String?
    /// Things the caller should say out loud — a service that was asked for and
    /// could not be built. **Not** silent omissions: a desktop that quietly has
    /// no file chooser for foreign apps is the failure this phase exists to fix.
    public let notes: [String]

    public init(components: [ComponentSpec], busAddress: String?, notes: [String]) {
        self.components = components
        self.busAddress = busAddress
        self.notes = notes
    }
}

/// Where this session's own bus listens.
///
/// **We name it; we do not ask what it chose.** `dbus-daemon` will happily pick
/// an address and print it, and every example does it that way — but an address
/// that is only knowable after the daemon starts is one that *changes when the
/// daemon restarts*, stranding `DBUS_SESSION_BUS_ADDRESS` in the environment of
/// every child that already has it. Pinning the socket into the session's own
/// runtime directory, beside `anchor.sock` and `portal.sock`, makes the address
/// a property of the session rather than of the process.
public func sessionBusAddress(runtimeDir: String) -> String {
    "unix:path=" + runtimeDir + "/bus"
}

/// The socket path inside a `unix:path=…` address, or nil if it is some other
/// kind of address (`tcp:`, `unix:abstract=`) that no `connect(2)` probe here
/// would understand.
public func unixSocketPath(ofBusAddress address: String) -> String? {
    guard address.hasPrefix("unix:path=") else { return nil }
    let rest = address.dropFirst("unix:path=".count)
    if let comma = rest.firstIndex(of: ",") { return String(rest[rest.startIndex..<comma]) }
    return String(rest)
}

/// Build the default session.
///
/// Pure: it resolves nothing, spawns nothing and reads no environment — every
/// path it needs is an argument, so a test can ask what a session *would* be on
/// a machine it is not running on.
///
/// - Parameters:
///   - shellBinary: the AquaDemo-shaped binary the three shell components run.
///   - serviceDirectory: where `abyss-portal` and `abyss-dbus` live (normally
///     beside `anchor` itself).
///   - dbusDaemon: an absolute path to `dbus-daemon`, or nil if there is none on
///     this machine — in which case the bus and the bridge are dropped **with a
///     note**, because a desktop that boots without them still works for our own
///     apps and must not fail to start over somebody else's file chooser.
///   - dbusConfig: the `dbus-daemon` config to use — `--session` by default, or
///     a path when a test needs a bus with no activatable services.
///   - runtimeDir: the session's `ABYSS_RUNTIME_DIR`; every socket lands here.
///   - display: `WAYLAND_DISPLAY` for the components, if known.
///   - compositorSocket: the compositor's own socket, when its path is knowable
///     — the shell waits for it rather than racing it. Without this the three
///     shell components are spawned the instant the compositor is, fail to
///     connect, and spend their restart budget waiting for a display to exist:
///     a slow compositor start would tear the session down as if the shell were
///     broken.
///   - menubarDisplay: the compositor's **privileged** socket (undertow
///     `--privileged-socket`, PHASE10 P10.3), if it has one. The menu bar alone
///     connects there — it is the one connection offered who is frontmost — and
///     waits for it the way the shell waits for the ordinary socket.
///   - without: names to leave out (`bus`, `portal`, `bridge`, `menus`,
///     `desktop`, `menubar`, `dock`).
public func defaultSession(shellBinary: String,
                           serviceDirectory: String,
                           dbusDaemon: String?,
                           dbusConfig: String? = nil,
                           runtimeDir: String,
                           display: String?,
                           compositorSocket: String? = nil,
                           menubarDisplay: String? = nil,
                           menubarSocket: String? = nil,
                           mode: SessionMode = .desktop,
                           without: Set<String> = []) -> SessionPlan {
    var components: [ComponentSpec] = []
    var notes: [String] = []
    var busAddress: String?

    var shared: [String: String] = [:]
    if let display { shared["WAYLAND_DISPLAY"] = display }
    shared["ABYSS_RUNTIME_DIR"] = runtimeDir

    let busSocket = runtimeDir + "/bus"
    let portalSocket = runtimeDir + "/portal.sock"

    // ------------------------------------------------------------------ bus
    if !without.contains("bus") {
        if let dbusDaemon {
            let address = sessionBusAddress(runtimeDir: runtimeDir)
            busAddress = address
            // `--nofork` because a supervisor's child must be the process it
            // supervises: let dbus-daemon daemonise and the pollable descriptor
            // we are holding belongs to a parent that has already exited, so the
            // session would report the bus as dead a millisecond after starting
            // it and restart it for ever.
            //
            // `--print-address=1` earns its place even though we chose the
            // address: it goes to anchor's log, so "which bus is this session
            // on" is answerable from the log alone, and a mismatch with what we
            // asked for would be visible rather than mysterious.
            let argv = [dbusDaemon,
                        dbusConfig.map { "--config-file=" + $0 } ?? "--session",
                        "--address=" + address,
                        "--print-address=1",
                        "--nofork"]
            components.append(ComponentSpec(name: "bus", argv: argv, env: shared))
        } else {
            notes.append("no dbus-daemon on $PATH — this session has no bus, so a"
                         + " foreign (GTK/Qt) app gets no file chooser from us."
                         + " Our own apps are unaffected.")
        }
    }

    // --------------------------------------------------------------- portal
    if !without.contains("portal") {
        components.append(ComponentSpec(name: "portal",
                                        argv: [serviceDirectory + "/abyss-portal"],
                                        env: shared))
    }

    // --------------------------------------------------------------- bridge
    // The bridge is the one component with real dependencies, and it has both:
    // it cannot own `org.freedesktop.portal.Desktop` on a bus that is not
    // listening, and answering an `OpenFile` means reaching `abyss-portal`. So
    // "the bridge is up" is made to mean "a foreign app asking for a file will
    // get one", rather than "a process called abyss-dbus exists".
    if !without.contains("bridge") {
        if let address = busAddress {
            var needs = [busSocket]
            if !without.contains("portal") { needs.append(portalSocket) }
            var env = shared
            env["DBUS_SESSION_BUS_ADDRESS"] = address
            components.append(ComponentSpec(name: "bridge",
                                            argv: [serviceDirectory + "/abyss-dbus"],
                                            env: env,
                                            requires: needs))
        } else if without.contains("bus") {
            notes.append("the bus was left out, so the D-Bus bridge is not"
                         + " started either — there is nothing for it to own a"
                         + " name on.")
        }
        // The remaining case — a bus was wanted and there is no dbus-daemon —
        // is already explained by the note above; saying it twice helps nobody.
    }

    // ---------------------------------------------------------------- menus
    // GTK's menus, bridged into the bar (PHASE10 P10.6): `abyss-dbus --menus`,
    // its own process because the portal half blocks behind a file dialog. It
    // needs the bus; without one there is nothing to bridge.
    if !without.contains("menus"), let address = busAddress {
        var env = shared
        env["DBUS_SESSION_BUS_ADDRESS"] = address
        components.append(ComponentSpec(name: "menus",
                                        argv: [serviceDirectory + "/abyss-dbus", "--menus"],
                                        env: env, requires: [busSocket]))
    }

    // ---------------------------------------------------------------- shell
    // In stacking order: the desktop underneath, then the menu bar, then the
    // Dock — the same three `abyss/session.sh` ran. In installer mode, the
    // wallpaper and the installer instead: a backdrop and the one thing this
    // machine is for.
    let scenes: [(String, String)] = mode == .installer
        ? [("desktop", "wallpaper"), ("installer", "installer")]
        : [("desktop", "wallpaper"), ("menubar", "menubar"), ("dock", "dock")]
    for (name, scene) in scenes where !without.contains(name) {
        var env = shared
        env["AQUA_SCENE"] = scene
        env["ABYSS_APP_BINARY"] = shellBinary
        var needs = compositorSocket.map { [$0] } ?? []
        if name == "menubar", let bar = menubarDisplay {
            // The bar is privileged; what it launches must not be (P10.8).
            if let d = env["WAYLAND_DISPLAY"] { env["ABYSS_APP_WAYLAND_DISPLAY"] = d }
            env["WAYLAND_DISPLAY"] = bar
            if let s = menubarSocket { needs.append(s) }
        }
        components.append(ComponentSpec(name: name, argv: [shellBinary], env: env,
                                        requires: needs))
    }

    return SessionPlan(components: components, busAddress: busAddress, notes: notes)
}

// MARK: - The pointer, for the toolkits that draw their own (U.7b)

/// The XCursor theme the session writes and names.
public let sessionCursorTheme = "Abyss"

/// What every process in the session is told about cursors: the theme
/// `abyss-theme cursors` wrote into `<runtimeDir>/icons`, its size, and a
/// search path that finds it first. GTK 3, SDL and X clients read these
/// (libwayland-cursor, libXcursor); without them they draw Adwaita's arrow
/// over our windows.
///
/// **A person's own choice stands**: an `XCURSOR_THEME` or `XCURSOR_SIZE`
/// already in the environment is kept — the variables are theirs before they
/// are ours. The path is always extended, ours first, so that choosing
/// "Abyss" by hand also works.
public func cursorEnvironment(runtimeDir: String, environment: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    if (environment["XCURSOR_THEME"] ?? "").isEmpty { out["XCURSOR_THEME"] = sessionCursorTheme }
    if (environment["XCURSOR_SIZE"] ?? "").isEmpty { out["XCURSOR_SIZE"] = "24" }
    let home = environment["HOME"] ?? ""
    // libXcursor's own default path, with /usr/local for FreeBSD's ports, as
    // the tail — replacing it would hide every other theme.
    let defaults = (home.isEmpty ? [] : ["\(home)/.local/share/icons", "\(home)/.icons"])
        + ["/usr/local/share/icons", "/usr/share/icons", "/usr/share/pixmaps"]
    let rest = (environment["XCURSOR_PATH"].flatMap { $0.isEmpty ? nil : $0 }) ?? defaults.joined(separator: ":")
    out["XCURSOR_PATH"] = runtimeDir + "/icons:" + rest
    return out
}
