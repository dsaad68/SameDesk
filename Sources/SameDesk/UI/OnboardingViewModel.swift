import AppKit
import SwiftUI

/// Backs the native first-run onboarding window. Permission + mkcert status are
/// re-read on demand (the view polls while open) so the checklist updates live
/// as the user grants things in System Settings.
@MainActor
final class OnboardingViewModel: ObservableObject {
    private unowned let coordinator: AppCoordinator

    @Published private(set) var hasScreenRecording = false
    @Published private(set) var hasAccessibility = false
    @Published private(set) var mkcertInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var securitySummary = ""
    @Published private(set) var url = ""
    @Published private(set) var qrImage: NSImage?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        coordinator.addStateObserver { [weak self] in self?.refresh() }
        refresh()
    }

    /// Everything green: capture + input permissions and a usable cert toolchain.
    var allReady: Bool { hasScreenRecording && hasAccessibility && mkcertInstalled }

    func refresh() {
        hasScreenRecording = Permissions.hasScreenRecording
        hasAccessibility = Permissions.hasAccessibility
        mkcertInstalled = coordinator.isMkcertInstalled
        isRunning = coordinator.isRunning
        securitySummary = coordinator.securitySummary

        // The URL/QR only make sense once the listener is up. Regenerate the QR
        // only when the URL actually changes (it's mildly expensive).
        let liveURL = isRunning ? coordinator.fullURLWithToken : ""
        if liveURL != url {
            url = liveURL
            qrImage = liveURL.isEmpty ? nil : QRCode.image(for: liveURL)
        }
    }

    // MARK: - Actions

    var canAirDrop: Bool { coordinator.canAirDropURL }

    func openScreenRecordingSettings() { Permissions.openSettings("Privacy_ScreenCapture") }
    func openAccessibilitySettings() { Permissions.openSettings("Privacy_Accessibility") }
    func copyURL() { coordinator.copyURLToPasteboard() }
    func airDrop() { coordinator.shareURLViaAirDrop() }
    func openSecurityChecklist() { FirstRunDocs.open() }

    func openMkcertHelp() {
        if let url = URL(string: "https://github.com/FiloSottile/mkcert#installation") {
            NSWorkspace.shared.open(url)
        }
    }
}
