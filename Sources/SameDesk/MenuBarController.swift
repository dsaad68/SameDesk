import AppKit

/// The `NSStatusItem` menu-bar UI. Deliberately minimal — all settings live in
/// the Settings window (see `SettingsWindowController`).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let coordinator: AppCoordinator
    private let settingsWindow: SettingsWindowController
    private let onboardingWindow: OnboardingWindowController

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.settingsWindow = SettingsWindowController(coordinator: coordinator)
        self.onboardingWindow = OnboardingWindowController(coordinator: coordinator)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.and.arrow.down", accessibilityDescription: "SameDesk")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        coordinator.addStateObserver { [weak self] in self?.rebuild() }
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // One concise status line.
        let status = NSMenuItem(
            title: coordinator.isRunning ? "SameDesk — \(coordinator.baseURL)" : "SameDesk — stopped",
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        menu.addItem(action("Copy URL", #selector(copyURL), symbol: "doc.on.doc"))
        if coordinator.canAirDropURL {
            menu.addItem(action("AirDrop URL…", #selector(airDropURL), symbol: "square.and.arrow.up"))
        }
        menu.addItem(action("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(action("Setup Guide…", #selector(openOnboarding), symbol: "checklist"))
        menu.addItem(action("Copy Diagnostics", #selector(copyDiagnostics), symbol: "stethoscope"))

        menu.addItem(.separator())

        menu.addItem(action(coordinator.isRunning ? "Stop Server" : "Start Server",
                            coordinator.isRunning ? #selector(stopServer) : #selector(startServer),
                            symbol: coordinator.isRunning ? "stop.fill" : "play.fill"))

        menu.addItem(.separator())
        menu.addItem(action("Quit SameDesk", #selector(quit), key: "q", symbol: "power"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            item.image = image
        }
        return item
    }

    // MARK: - Actions

    @objc private func copyURL() {
        coordinator.copyURLToPasteboard()
        flashTitle("Copied URL")
    }

    @objc private func airDropURL() { coordinator.shareURLViaAirDrop() }

    @objc private func copyDiagnostics() {
        Task {
            await coordinator.copyDiagnosticsToPasteboard()
            flashTitle("Copied diagnostics")
        }
    }

    @objc private func openSettings() { settingsWindow.show() }
    @objc private func openOnboarding() { onboardingWindow.show() }

    /// Show the onboarding window on first launch only.
    func showOnboardingIfNeeded() { onboardingWindow.showIfNeeded() }

    @objc private func startServer() { coordinator.start() }
    @objc private func stopServer() { coordinator.stop() }

    @objc private func quit() {
        coordinator.stop()
        NSApplication.shared.terminate(nil)
    }

    private func flashTitle(_ text: String) {
        guard let button = statusItem.button else { return }
        let original = button.title
        button.title = " \(text)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { button.title = original }
    }
}
