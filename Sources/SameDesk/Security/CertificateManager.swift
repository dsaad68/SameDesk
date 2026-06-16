import Foundation

/// Mints and loads a locally-trusted TLS leaf certificate using the `mkcert`
/// CLI. The cert's SANs include BOTH the current LAN IPv4 address AND a stable
/// `.local` hostname, so the same identity works whether the client connects by
/// IP or by Bonjour name. We prefer advertising the `.local` name because an
/// IP-SAN cert breaks the moment DHCP reassigns the address.
final class CertificateManager {
    struct Identity {
        let certURL: URL
        let keyURL: URL
        let localHostname: String   // e.g. "samedesk.local"
        let ipv4: String
    }

    enum CertError: Error, CustomStringConvertible {
        case mkcertNotFound
        case mkcertFailed(String)

        var description: String {
            switch self {
            case .mkcertNotFound:
                return "mkcert was not found. Install it (e.g. `brew install mkcert`) and run `mkcert -install` once."
            case .mkcertFailed(let msg):
                return "mkcert failed: \(msg)"
            }
        }
    }

    private let directory: URL

    init(directory: URL = Settings.shared.appSupportDirectory) {
        self.directory = directory
    }

    private var certURL: URL { directory.appendingPathComponent("samedesk-cert.pem") }
    private var keyURL: URL { directory.appendingPathComponent("samedesk-key.pem") }
    private var metaURL: URL { directory.appendingPathComponent("samedesk-cert.json") }

    /// Whether the `mkcert` CLI is available (a prerequisite for minting the
    /// locally-trusted cert). Checks fixed Homebrew paths first, then PATH.
    var isMkcertInstalled: Bool { locateMkcert() != nil }

    /// When the current leaf cert was minted (from the sidecar metadata), or nil
    /// if none exists yet. Used for diagnostics.
    var certificateMintedAt: Date? {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CertMeta.self, from: data) else { return nil }
        return meta.mintedAt
    }

    /// Returns a valid identity for the given LAN IPv4 and DNS hostnames, minting
    /// a fresh cert if none exists or the existing one was minted for a different
    /// identity. `primaryHost` is the name advertised/displayed (the first
    /// hostname that actually resolves on the LAN).
    func ensureCertificate(forIPv4 ipv4: String, hostnames: [String], primaryHost: String) throws -> Identity {
        let names = hostnames.filter { !$0.isEmpty }
        if existingCertIsValid(ipv4: ipv4, hostnames: names) {
            return Identity(certURL: certURL, keyURL: keyURL, localHostname: primaryHost, ipv4: ipv4)
        }
        try mint(ipv4: ipv4, hostnames: names)
        return Identity(certURL: certURL, keyURL: keyURL, localHostname: primaryHost, ipv4: ipv4)
    }

    // MARK: - Validity

    private struct CertMeta: Codable {
        let ipv4: String
        let hostnames: [String]
        let mintedAt: Date
    }

    private func existingCertIsValid(ipv4: String, hostnames: [String]) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: certURL.path),
              fm.fileExists(atPath: keyURL.path),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CertMeta.self, from: metaData)
        else { return false }

        // Identity must match the current LAN IP and hostname set...
        guard meta.ipv4 == ipv4, meta.hostnames == hostnames else { return false }
        // ...and the cert must not be near expiry. mkcert leaf certs are valid
        // for ~825 days; regenerate well before that.
        let age = Date().timeIntervalSince(meta.mintedAt)
        let maxAge: TimeInterval = 800 * 24 * 60 * 60
        return age < maxAge
    }

    // MARK: - Minting

    private func mint(ipv4: String, hostnames: [String]) throws {
        guard let mkcert = locateMkcert() else { throw CertError.mkcertNotFound }

        // mkcert <host...> <ipv4>  ->  writes a leaf cert with all as SANs.
        var args = ["-cert-file", certURL.path, "-key-file", keyURL.path]
        args.append(contentsOf: hostnames)
        args.append(ipv4)

        let (status, output) = try runProcess(mkcert, args)
        guard status == 0 else { throw CertError.mkcertFailed(output) }

        let meta = CertMeta(ipv4: ipv4, hostnames: hostnames, mintedAt: Date())
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL)
        }
    }

    private func locateMkcert() -> String? {
        let candidates = [
            "/opt/homebrew/bin/mkcert",   // Apple Silicon Homebrew
            "/usr/local/bin/mkcert",      // Intel Homebrew
            "/usr/bin/mkcert"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to PATH lookup via `which`.
        if let (status, out) = try? runProcess("/usr/bin/which", ["mkcert"]), status == 0 {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ args: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
