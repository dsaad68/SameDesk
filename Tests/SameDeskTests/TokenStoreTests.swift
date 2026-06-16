@testable import SameDesk
import XCTest

/// Covers the two pure pieces of the token plumbing: the constant-time compare
/// every entry point relies on, and the URL-safe base64 used to mint tokens.
/// (Keychain I/O is intentionally not exercised here.)
final class TokenStoreTests: XCTestCase {
    func testConstantTimeEqualsMatching() {
        XCTAssertTrue(TokenStore.constantTimeEquals("abc123", "abc123"))
        XCTAssertTrue(TokenStore.constantTimeEquals("", ""))
        XCTAssertTrue(TokenStore.constantTimeEquals("café 🌍", "café 🌍"))
    }

    func testConstantTimeEqualsMismatch() {
        XCTAssertFalse(TokenStore.constantTimeEquals("abc123", "abc124"))
        XCTAssertFalse(TokenStore.constantTimeEquals("abc", "abcd"))   // length differs
        XCTAssertFalse(TokenStore.constantTimeEquals("abcd", "abc"))
        XCTAssertFalse(TokenStore.constantTimeEquals("", "x"))
        XCTAssertFalse(TokenStore.constantTimeEquals("token", ""))
        XCTAssertFalse(TokenStore.constantTimeEquals("café", "cafe"))
    }

    func testBase64URLKnownVectors() {
        // 0xFF 0xFF 0xFF -> standard "////" -> url-safe "____"
        XCTAssertEqual(Data([0xFF, 0xFF, 0xFF]).base64URLEncodedString(), "____")
        // 0xFB -> standard "+w==" -> url-safe "-w" (padding stripped, '+' -> '-')
        XCTAssertEqual(Data([0xFB]).base64URLEncodedString(), "-w")
        XCTAssertEqual(Data().base64URLEncodedString(), "")
    }

    func testBase64URLHasNoUnsafeChars() {
        let blob = Data((0...255).map { UInt8($0) })
        let encoded = blob.base64URLEncodedString()
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }
}
