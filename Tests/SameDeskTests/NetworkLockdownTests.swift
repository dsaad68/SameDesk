@testable import SameDesk
import XCTest

/// The LAN-lockdown guarantees are security-critical: these lock in the
/// address-classification and pre-flight rules so a refactor can't silently
/// start binding an internet-routable address.
final class NetworkLockdownTests: XCTestCase {
    func testPrivateIPv4Ranges() {
        for ip in ["10.0.0.1", "10.255.255.255", "192.168.1.1",
                   "172.16.0.1", "172.31.255.255",
                   "100.64.0.1", "100.127.255.255"] {  // CGNAT / overlay VPNs
            XCTAssertTrue(NetworkLockdown.isPrivateIPv4(ip), "\(ip) should be private")
        }
    }

    func testNonPrivateIPv4() {
        for ip in ["8.8.8.8", "1.1.1.1", "192.169.1.1",
                   "172.15.0.1", "172.32.0.1",
                   "100.63.255.255", "100.128.0.0",
                   "169.254.1.1"] {  // link-local is not "private"
            XCTAssertFalse(NetworkLockdown.isPrivateIPv4(ip), "\(ip) should not be private")
        }
    }

    func testMalformedAddresses() {
        for ip in ["", "10.0.0", "10.0.0.1.2", "not.an.ip", "10.0.0.x", "::1"] {
            XCTAssertFalse(NetworkLockdown.isPrivateIPv4(ip), "\(ip) should not parse as private")
        }
    }

    func testLinkLocal() {
        XCTAssertTrue(NetworkLockdown.isLinkLocalIPv4("169.254.0.1"))
        XCTAssertTrue(NetworkLockdown.isLinkLocalIPv4("169.254.255.255"))
        XCTAssertFalse(NetworkLockdown.isLinkLocalIPv4("169.253.0.1"))
        XCTAssertFalse(NetworkLockdown.isLinkLocalIPv4("10.0.0.1"))
    }

    func testPreflightRejectsWildcardAndIPv6() {
        for bad in ["0.0.0.0", "::", "::1", "fe80::1", "2001:db8::1"] {
            let result = NetworkLockdown.preflight(bindAddress: bad, interfaceName: "en0")
            XCTAssertFalse(result.safe, "\(bad) must be refused")
            XCTAssertNotNil(result.failureReason)
        }
    }

    func testPreflightRejectsPublicIPv4() {
        let result = NetworkLockdown.preflight(bindAddress: "8.8.8.8", interfaceName: "en0")
        XCTAssertFalse(result.safe)
        XCTAssertNotNil(result.failureReason)
    }

    func testPreflightAcceptsPrivateLAN() {
        let result = NetworkLockdown.preflight(bindAddress: "192.168.1.20", interfaceName: "en0")
        XCTAssertTrue(result.safe)
        XCTAssertNil(result.failureReason)
        XCTAssertEqual(result.bindAddress, "192.168.1.20")
        XCTAssertEqual(result.interfaceName, "en0")
    }

    func testPreflightAcceptsLinkLocal() {
        let result = NetworkLockdown.preflight(bindAddress: "169.254.10.10", interfaceName: "en1")
        XCTAssertTrue(result.safe)
        XCTAssertNil(result.failureReason)
    }
}
