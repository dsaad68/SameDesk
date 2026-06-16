import SwiftUI

/// Capture-resolution presets surfaced in Settings. The underlying setting is a
/// free-form width/height, but a few named caps cover the real cases without a
/// custom-size UI. `Auto` streams at native resolution.
enum DownscalePreset: String, CaseIterable, Identifiable {
    case auto, p1080, p1440, nativeish
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .nativeish: return "Native-ish"
        }
    }

    /// `nil` = no downscale (capture at native resolution).
    var size: (width: Int, height: Int)? {
        switch self {
        case .auto: return nil
        case .p1080: return (1920, 1080)
        case .p1440: return (2560, 1440)
        case .nativeish: return (3840, 2160)   // cap 5K/6K panels at 4K
        }
    }

    static func current(enabled: Bool, size: (width: Int, height: Int)) -> DownscalePreset {
        guard enabled else { return .auto }
        switch (size.width, size.height) {
        case (1920, 1080): return .p1080
        case (2560, 1440): return .p1440
        case (3840, 2160): return .nativeish
        default: return .auto
        }
    }
}

/// Bridges the SwiftUI settings window to `AppCoordinator` + `Settings`.
/// Toggles apply immediately (live where possible, restart where required).
@MainActor
final class SettingsViewModel: ObservableObject {
    private unowned let coordinator: AppCoordinator

    // Editable settings. didSet applies the change; assignments made in init and
    // refresh() target read-only state only, so they never loop.
    @Published var bitrateMbps: Double { didSet { coordinator.setBitrate(Int(bitrateMbps * 1_000_000)) } }
    @Published var deltaEncoding: Bool { didSet { coordinator.setDeltaEncoding(deltaEncoding) } }
    @Published var useHEVC: Bool { didSet { coordinator.setHEVC(useHEVC) } }
    @Published var audioEnabled: Bool { didSet { coordinator.setAudio(audioEnabled) } }
    @Published var headless: Bool { didSet { coordinator.setHeadless(headless) } }
    @Published var downscalePreset: DownscalePreset { didSet { coordinator.setDownscale(downscalePreset.size) } }
    @Published var port: Int        // applied explicitly via applyPort(_:)

    // Read-only surfaced state.
    @Published private(set) var baseURL = ""
    @Published private(set) var securitySummary = ""
    @Published private(set) var isRunning = false
    @Published private(set) var token = ""
    @Published private(set) var alternateURL: String?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        bitrateMbps = Double(Settings.shared.bitrateBps) / 1_000_000
        deltaEncoding = Settings.shared.deltaEncoding
        useHEVC = Settings.shared.useHEVC
        audioEnabled = Settings.shared.audioEnabled
        headless = Settings.shared.headlessVirtualDisplay
        downscalePreset = DownscalePreset.current(enabled: Settings.shared.downscaleEnabled,
                                                  size: Settings.shared.downscaleSize)
        port = Settings.shared.port
        refresh()
        coordinator.addStateObserver { [weak self] in self?.refresh() }
    }

    func refresh() {
        baseURL = coordinator.baseURL
        securitySummary = coordinator.securitySummary
        isRunning = coordinator.isRunning
        token = coordinator.token
        alternateURL = coordinator.alternateURLWithToken
    }

    // MARK: - Actions

    func applyPort(_ newPort: Int) {
        guard (1024...65535).contains(newPort) else { return }
        port = newPort
        coordinator.setPort(newPort)
    }

    var canAirDrop: Bool { coordinator.canAirDropURL }

    func copyURL() { coordinator.copyURLToPasteboard() }
    func copyAlternateURL() { coordinator.copyAlternateURLToPasteboard() }
    func airDrop() { coordinator.shareURLViaAirDrop() }
    func regenerateToken() { coordinator.regenerateToken(); refresh() }

    func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }

    func copyDiagnostics() { Task { await coordinator.copyDiagnosticsToPasteboard() } }

    func toggleServer() { if isRunning { coordinator.stop() } else { coordinator.start() } }
}
