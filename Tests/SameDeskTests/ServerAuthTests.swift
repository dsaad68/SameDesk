@testable import SameDesk
import XCTest

/// The pairing flow's cookie parsing/emission is security-relevant — a parser
/// bug could miss the session token or accept a look-alike name. Lock the
/// contract, including the cookie's hardening attributes.
final class ServerAuthTests: XCTestCase {
    func testSessionTokenFromSingleCookie() {
        XCTAssertEqual(SameDeskServer.sessionToken(fromCookieHeader: "sd_session=abc123"), "abc123")
    }

    func testSessionTokenAmongMultipleCookies() {
        let header = "theme=dark; sd_session=tok-EN_zz; other=1"
        XCTAssertEqual(SameDeskServer.sessionToken(fromCookieHeader: header), "tok-EN_zz")
    }

    func testSessionTokenTrimsWhitespace() {
        XCTAssertEqual(SameDeskServer.sessionToken(fromCookieHeader: "a=b;  sd_session = xyz "), "xyz")
    }

    func testSessionTokenMissing() {
        XCTAssertNil(SameDeskServer.sessionToken(fromCookieHeader: nil))
        XCTAssertNil(SameDeskServer.sessionToken(fromCookieHeader: ""))
        XCTAssertNil(SameDeskServer.sessionToken(fromCookieHeader: "theme=dark; other=1"))
        XCTAssertNil(SameDeskServer.sessionToken(fromCookieHeader: "sd_sessionx=nope"))   // look-alike name
    }

    func testSessionCookieAttributes() {
        let cookie = SameDeskServer.sessionCookie(token: "T0k_en-AB")
        XCTAssertTrue(cookie.hasPrefix("sd_session=T0k_en-AB;"))
        XCTAssertTrue(cookie.contains("HttpOnly"))         // not readable from JS
        XCTAssertTrue(cookie.contains("Secure"))           // TLS-only
        XCTAssertTrue(cookie.contains("SameSite=Strict"))  // never sent cross-site
        XCTAssertTrue(cookie.contains("Path=/"))
        XCTAssertFalse(cookie.contains("Max-Age"))         // session cookie
    }

    func testSessionCookieRoundTrips() {
        // What the server emits must parse back to the same token.
        let token = "Abc-123_XYZ"
        let cookie = SameDeskServer.sessionCookie(token: token)
        // A browser sends back only the name=value pair (no attributes).
        let nameValue = String(cookie.split(separator: ";")[0])
        XCTAssertEqual(SameDeskServer.sessionToken(fromCookieHeader: nameValue), token)
    }
}
