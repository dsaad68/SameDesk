import Foundation
import SystemConfiguration

/// Resolves the Mac's own Bonjour hostname.
///
/// macOS's mDNS responder automatically answers `<LocalHostName>.local` on the
/// LAN, so that name resolves on every device with zero extra configuration.
/// An arbitrary name like `samedesk.local` does NOT resolve unless something
/// publishes an mDNS host (A) record for it — publishing a Bonjour *service* is
/// not enough. So we advertise/connect via the real `.local` name and fall back
/// to the raw IP.
enum Hostname {
    /// e.g. "Johns-MacBook-Pro" (without the ".local" suffix), or nil.
    static var localName: String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else {
            return nil
        }
        return name
    }

    /// The resolvable mDNS hostname, e.g. "Johns-MacBook-Pro.local".
    static var resolvableLocalHost: String? {
        localName.map { "\($0).local" }
    }
}
