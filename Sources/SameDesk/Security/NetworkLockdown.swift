import Foundation

/// Discovers the LAN IPv4 address to bind to and runs the startup pre-flight
/// that guarantees we are not internet-exposed.
///
/// Design rules (see README §Network lockdown):
///  - Bind ONLY to a specific LAN IPv4 interface address, never 0.0.0.0 / ::.
///  - Never request a UPnP / NAT-PMP / PCP port mapping. (We simply never call
///    any such API — there is no port-mapping code in this app, by design.)
///  - Refuse to start if we somehow resolve a globally-routable address.
enum NetworkLockdown {
    struct Interface {
        let name: String       // e.g. "en0"
        let ipv4: String       // dotted quad
    }

    /// Result of the pre-flight, surfaced in the menu.
    struct PreflightResult {
        let bindAddress: String
        let interfaceName: String
        /// True only if we are confident this is a private LAN address.
        let safe: Bool
        let summary: String
        let failureReason: String?
    }

    // MARK: - Interface discovery

    /// Enumerate active IPv4 interfaces, preferring en0/en1 (Wi-Fi / Ethernet).
    static func candidateInterfaces() -> [Interface] {
        var results: [Interface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }

            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }

            let name = String(cString: cur.pointee.ifa_name)

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                 &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(cString: host)
            guard isPrivateIPv4(ip) || isLinkLocalIPv4(ip) else {
                // Skip anything that isn't an RFC1918 / link-local LAN address.
                continue
            }
            results.append(Interface(name: name, ipv4: ip))
        }

        // Prefer en0, then en1, then any other.
        return results.sorted { lhs, rhs in
            rank(lhs.name) < rank(rhs.name)
        }
    }

    private static func rank(_ name: String) -> Int {
        switch name {
        case "en0": return 0
        case "en1": return 1
        default: return 2
        }
    }

    static func primaryInterface() -> Interface? {
        candidateInterfaces().first
    }

    // MARK: - Address classification

    /// RFC1918 private ranges + CGNAT (100.64/10).
    static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let (a, b) = (parts[0], parts[1])
        if a == 10 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && (64...127).contains(b) { return true } // CGNAT / overlay VPNs
        return false
    }

    static func isLinkLocalIPv4(_ ip: String) -> Bool {
        ip.hasPrefix("169.254.")
    }

    // MARK: - Pre-flight

    /// Confirm we are about to bind to a non-global address. Called before the
    /// listener starts; if it returns `safe == false`, the app refuses to start
    /// the server and shows `failureReason`.
    static func preflight(bindAddress: String, interfaceName: String) -> PreflightResult {
        // (a) We must be IPv4 and private. We never bind ::/0.0.0.0 (the caller
        //     passes a specific interface IP), but verify defensively.
        if bindAddress == "0.0.0.0" || bindAddress == "::" || bindAddress.contains(":") {
            return PreflightResult(
                bindAddress: bindAddress,
                interfaceName: interfaceName,
                safe: false,
                summary: "Refusing to start — wildcard/IPv6 bind detected",
                failureReason: "Bind address \(bindAddress) is a wildcard or IPv6 address, which could expose the app on a globally-routable address. SameDesk only binds a specific LAN IPv4 interface."
            )
        }

        guard isPrivateIPv4(bindAddress) || isLinkLocalIPv4(bindAddress) else {
            return PreflightResult(
                bindAddress: bindAddress,
                interfaceName: interfaceName,
                safe: false,
                summary: "Refusing to start — bind address is not a private LAN IPv4",
                failureReason: "\(bindAddress) is not an RFC1918/link-local address. SameDesk will not bind a potentially internet-routable address."
            )
        }

        return PreflightResult(
            bindAddress: bindAddress,
            interfaceName: interfaceName,
            safe: true,
            summary: "Listening on LAN IPv4 only (\(interfaceName)) — not internet-exposed",
            failureReason: nil
        )
    }
}
