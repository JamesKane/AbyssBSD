// Vents.Network — what the machine's network is doing, without privilege
// (PHASE14 P14.4).
//
// The Network pane shows this beside the settings it writes through the root
// helper: which interfaces there are, whether each has a link, what address it
// holds, the default router and the name servers — **as the kernel has them
// now**, which after a DHCP lease or a cable pulled is not what rc.conf says.
// Every read here is one an ordinary user may make, and so is the watch: a
// routing socket (FreeBSD) or rtnetlink (Linux) needs no privilege to listen.
//
// The parsers are pure functions of text, so they are tested on captured output
// rather than on whatever network the test machine happens to have.

import CVents
import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public extension Vents {
    enum Network {
        public enum Link: String, Equatable, Sendable { case up, down, unknown }

        public struct Address: Equatable, Sendable {
            public let address: String
            public let prefix: Int
        }

        public struct Interface: Equatable, Sendable {
            public let name: String
            public let up: Bool
            public let loopback: Bool
            public let link: Link
            public let ipv4: [Address]
            /// `aa:bb:cc:dd:ee:ff`, or nil when it has none.
            public let mac: String?
        }

        public struct Status: Equatable, Sendable {
            public let interfaces: [Interface]
            public let router: (address: String, interface: String)?
            public let nameServers: [String]

            public static func == (a: Status, b: Status) -> Bool {
                a.interfaces == b.interfaces && a.nameServers == b.nameServers
                    && a.router?.address == b.router?.address && a.router?.interface == b.router?.interface
            }
        }

        /// Every interface, in the kernel's order, with its IPv4 addresses.
        public static func interfaces() -> [Interface] {
            var head: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&head) == 0 else { return [] }
            defer { freeifaddrs(head) }
            var order: [String] = []
            var flags: [String: UInt32] = [:]
            var addrs: [String: [Address]] = [:]
            var p = head
            while let a = p {
                defer { p = a.pointee.ifa_next }
                guard let n = a.pointee.ifa_name else { continue }
                let name = String(cString: n)
                if flags[name] == nil { order.append(name) }
                flags[name, default: 0] |= UInt32(a.pointee.ifa_flags)
                guard let sa = a.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET else { continue }
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                var prefix = 32
                if let nm = a.pointee.ifa_netmask {
                    prefix = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        UInt32(bigEndian: $0.pointee.sin_addr.s_addr).nonzeroBitCount
                    }
                }
                addrs[name, default: []].append(Address(address: dotted(addr), prefix: prefix))
            }
            return order.map { name in
                let f = flags[name] ?? 0
                var mac = [UInt8](repeating: 0, count: 6)
                let hasMac = av_if_mac(name, &mac) == 0 && mac.contains { $0 != 0 }
                let l = av_if_link(name)
                return Interface(name: name, up: f & UInt32(IFF_UP) != 0,
                                 loopback: f & UInt32(IFF_LOOPBACK) != 0,
                                 link: l == 1 ? .up : l == 0 ? .down : .unknown,
                                 ipv4: addrs[name] ?? [],
                                 mac: hasMac ? mac.map { hex2($0) }.joined(separator: ":") : nil)
            }
        }

        /// The default route's gateway and interface, or nil for none.
        public static func defaultRouter() -> (address: String, interface: String)? {
            #if os(Linux)
            guard let text = readText("/proc/net/route") else { return nil }
            return parseProcRoute(text)
            #else
            let r = Spawn.run(["route", "-n", "get", "default"], limit: 8192)
            return r.succeeded ? parseRouteGet(r.stdoutText) : nil
            #endif
        }

        /// The resolver's name servers, in order.
        public static func nameServers(resolvConf: String = "/etc/resolv.conf") -> [String] {
            parseResolvConf(readText(resolvConf) ?? "")
        }

        public static func status() -> Status {
            Status(interfaces: interfaces(), router: defaultRouter(), nameServers: nameServers())
        }

        /// A descriptor readable when an interface, address or route changes —
        /// for the pane's own loop; `drain()` it, then read `status()` again.
        public final class Watch {
            public let fileDescriptor: Int32
            public init?() {
                let fd = av_route_watch_open()
                guard fd >= 0 else { return nil }
                fileDescriptor = fd
            }
            deinit { close(fileDescriptor) }
            /// Whether anything had changed.
            @discardableResult public func drain() -> Bool { av_route_watch_drain(fileDescriptor) == 1 }
        }

        // MARK: - Parsers (pure)

        /// `route -n get default` (FreeBSD): its `gateway:` and `interface:`.
        public static func parseRouteGet(_ text: String) -> (address: String, interface: String)? {
            var gw: String?, ifn: String?
            for line in text.split(separator: "\n") {
                let t = line.drop { $0 == " " }
                if t.hasPrefix("gateway:") { gw = t.dropFirst(8).trimmingSpaces() }
                if t.hasPrefix("interface:") { ifn = t.dropFirst(10).trimmingSpaces() }
            }
            guard let g = gw, let i = ifn, !g.isEmpty, !i.isEmpty else { return nil }
            return (g, i)
        }

        /// `/proc/net/route` (Linux): the row whose destination is 0, its
        /// gateway in little-endian hex.
        public static func parseProcRoute(_ text: String) -> (address: String, interface: String)? {
            for line in text.split(separator: "\n").dropFirst() {
                let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard f.count >= 3, f[1] == "00000000", let g = UInt32(f[2], radix: 16), g != 0 else { continue }
                return (dotted(g.byteSwapped), String(f[0]))
            }
            return nil
        }

        /// `nameserver` lines, in order; comments and everything else ignored.
        public static func parseResolvConf(_ text: String) -> [String] {
            text.split(separator: "\n").compactMap { line in
                let w = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                return w.count >= 2 && w[0] == "nameserver" ? String(w[1]) : nil
            }
        }

        static func dotted(_ v: UInt32) -> String {
            "\(v >> 24).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
        }
        static func hex2(_ b: UInt8) -> String {
            let d = Array("0123456789abcdef")
            return String([d[Int(b >> 4)], d[Int(b & 0xf)]])
        }
        static func readText(_ path: String) -> String? {
            guard let f = fopen(path, "r") else { return nil }
            defer { fclose(f) }
            var out = "", buf = [CChar](repeating: 0, count: 4096)
            while fgets(&buf, 4096, f) != nil { out += String(cString: buf) }
            return out
        }
    }
}

private extension Substring {
    func trimmingSpaces() -> String {
        var s = self
        while let c = s.first, c == " " || c == "\t" { s = s.dropFirst() }
        while let c = s.last, c == " " || c == "\t" { s = s.dropLast() }
        return String(s)
    }
}
