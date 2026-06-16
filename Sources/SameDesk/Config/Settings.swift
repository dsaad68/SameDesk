import Foundation

/// User-configurable, persisted settings. Backed by `UserDefaults`.
///
/// Only plain value types live here. Secrets (the access token) live in the
/// Keychain via `TokenStore`, never in defaults.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let port = "samedesk.port"
        static let bitrate = "samedesk.bitrateBps"
        static let deltaEncoding = "samedesk.deltaEncoding"
        static let headless = "samedesk.headlessVirtualDisplay"
        static let downscaleEnabled = "samedesk.downscaleEnabled"
        static let downscaleWidth = "samedesk.downscaleWidth"
        static let downscaleHeight = "samedesk.downscaleHeight"
        static let useHEVC = "samedesk.useHEVC"
        static let audioEnabled = "samedesk.audioEnabled"
        static let onboarded = "samedesk.onboarded"
    }

    private init() {
        defaults.register(defaults: [
            Key.port: 8080,
            Key.bitrate: 4_000_000,           // ~4 Mbps default (LAN text-heavy may want 8–20)
            Key.deltaEncoding: true,
            Key.headless: false,
            Key.downscaleEnabled: false,
            Key.downscaleWidth: 1920,
            Key.downscaleHeight: 1080,
            Key.useHEVC: false,
            Key.audioEnabled: false,
            Key.onboarded: false
        ])
    }

    /// Set once the first-run onboarding window has been shown.
    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

    /// Capture and stream system audio (ScreenCaptureKit) to the browser.
    /// Default off. Toggling restarts the capture pipeline.
    var audioEnabled: Bool {
        get { defaults.bool(forKey: Key.audioEnabled) }
        set { defaults.set(newValue, forKey: Key.audioEnabled) }
    }

    /// Encode with HEVC/H.265 instead of H.264. ~2x compression (sharper at the
    /// same bitrate), but decode is limited to Safari 17+ and Chrome/Edge with
    /// hardware HEVC. Falls back to H.264 automatically if the Mac can't encode
    /// HEVC. Default off for broadest client compatibility.
    var useHEVC: Bool {
        get { defaults.bool(forKey: Key.useHEVC) }
        set { defaults.set(newValue, forKey: Key.useHEVC) }
    }

    var port: Int {
        get { defaults.integer(forKey: Key.port) }
        set { defaults.set(newValue, forKey: Key.port) }
    }

    /// Average target bitrate for the H.264 encoder, in bits/sec.
    /// Dense text at native resolution can need 8–20 Mbps on a LAN; this is
    /// deliberately exposed so the user can raise it.
    var bitrateBps: Int {
        get { defaults.integer(forKey: Key.bitrate) }
        set { defaults.set(newValue, forKey: Key.bitrate) }
    }

    var deltaEncoding: Bool {
        get { defaults.bool(forKey: Key.deltaEncoding) }
        set { defaults.set(newValue, forKey: Key.deltaEncoding) }
    }

    var headlessVirtualDisplay: Bool {
        get { defaults.bool(forKey: Key.headless) }
        set { defaults.set(newValue, forKey: Key.headless) }
    }

    var downscaleEnabled: Bool {
        get { defaults.bool(forKey: Key.downscaleEnabled) }
        set { defaults.set(newValue, forKey: Key.downscaleEnabled) }
    }

    var downscaleSize: (width: Int, height: Int) {
        get { (defaults.integer(forKey: Key.downscaleWidth), defaults.integer(forKey: Key.downscaleHeight)) }
        set {
            defaults.set(newValue.width, forKey: Key.downscaleWidth)
            defaults.set(newValue.height, forKey: Key.downscaleHeight)
        }
    }

    /// Directory under Application Support used for the TLS cert/key and any
    /// user-facing docs the app writes on first run.
    var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SameDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
