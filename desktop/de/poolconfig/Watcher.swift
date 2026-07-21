// Pool.Watcher — hot-reload support: wakes when a file in the config directory
// changes, so a shell component can reload its config without polling. Backed by
// CPoolWatch (inotify on Linux, kqueue on FreeBSD). The fd is pollable, so a
// component can add `fileDescriptor` to its own event loop next to the Wayland
// fd; `drain()` then clears the pending events once that loop reports it ready.

import CPoolWatch

public extension Pool {
    final class Watcher {
        /// A pollable fd, readable when the watched directory changes.
        public let fileDescriptor: Int32

        /// Watch the config directory (defaults to the resolved config dir).
        public init(in dir: String? = nil) throws {
            let d = try dir ?? Pool.configDir()
            let fd = d.withCString { awc_watch_open($0) }
            guard fd >= 0 else { throw PoolError.io("watch open \(d)") }
            fileDescriptor = fd
        }

        deinit { awc_watch_close(fileDescriptor) }

        /// Block up to `timeoutMs` (negative = forever) for a change. Returns
        /// true if the directory changed (events drained), false on timeout.
        public func wait(timeoutMs: Int32) throws -> Bool {
            let r = awc_watch_wait(fileDescriptor, timeoutMs)
            if r < 0 { throw PoolError.io("watch wait") }
            return r == 1
        }

        /// Non-blocking: drain and report whether anything changed since last check.
        public func drain() -> Bool { awc_watch_wait(fileDescriptor, 0) == 1 }
    }
}
