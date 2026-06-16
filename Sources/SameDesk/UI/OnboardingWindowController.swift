import AppKit
import SwiftUI

/// Lazily creates and shows the first-run onboarding window. Like the Settings
/// window, it's managed manually since SameDesk is an accessory (menu-bar) app.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let viewModel: OnboardingViewModel

    init(coordinator: AppCoordinator) {
        self.viewModel = OnboardingViewModel(coordinator: coordinator)
    }

    /// Show on first launch only, recording that it has been shown.
    func showIfNeeded() {
        guard !Settings.shared.hasCompletedOnboarding else { return }
        Settings.shared.hasCompletedOnboarding = true
        show()
    }

    func show() {
        if window == nil {
            let root = OnboardingView(vm: viewModel) { [weak self] in self?.window?.close() }
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = true
            window.backgroundColor = NSColor(srgbRed: 0.043, green: 0.051, blue: 0.050, alpha: 1)
            window.title = "Welcome to SameDesk"
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 700))
            window.center()
            self.window = window
        }
        viewModel.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
