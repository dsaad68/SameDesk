import Foundation
import Security

/// Persists the access token in the login Keychain so it survives restarts,
/// and provides a constant-time comparison used by every entry point.
final class TokenStore {
    static let shared = TokenStore()

    private let service = "com.samedesk.accesstoken"
    private let account = "samedesk"

    private init() {}

    /// The current token, generating and persisting one on first access.
    private(set) lazy var token: String = {
        if let existing = load() { return existing }
        let fresh = Self.generateToken()
        store(fresh)
        return fresh
    }()

    /// Generate a new token and persist it, replacing the old one.
    @discardableResult
    func regenerate() -> String {
        let fresh = Self.generateToken()
        store(fresh)
        token = fresh
        return fresh
    }

    // MARK: - Token generation

    /// >= 32 bytes of CSPRNG output, base64url-encoded (URL-safe, no padding).
    private static func generateToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64URLEncodedString()
    }

    /// Constant-time comparison. Never short-circuits on the first mismatched
    /// byte, so it does not leak token length/prefix via timing.
    func isValid(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        return Self.constantTimeEquals(candidate, token)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        // Mix the length difference into the accumulator so unequal lengths
        // still cost a full pass over the longer string.
        var diff = UInt8(ab.count == bb.count ? 0 : 1)
        let n = max(ab.count, bb.count)
        var i = 0
        while i < n {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= (x ^ y)
            i += 1
        }
        return diff == 0
    }

    // MARK: - Keychain

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func store(_ value: String) {
        let data = Data(value.utf8)
        // Delete any existing item, then add fresh. Simpler than update and
        // avoids stale attributes.
        SecItemDelete(baseQuery() as CFDictionary)

        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("SameDesk: failed to store token in Keychain: \(status)")
        }
    }
}

extension Data {
    /// base64url (RFC 4648 §5): + -> -, / -> _, '=' padding stripped.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
