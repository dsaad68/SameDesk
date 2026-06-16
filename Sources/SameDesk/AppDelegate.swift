import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        coordinator = AppCoordinator()
        menuBar = MenuBarController(coordinator: coordinator)

        // Keep the long-form security checklist on disk for reference; the native
        // onboarding window (shown on first launch) covers the interactive steps.
        FirstRunDocs.ensureWritten()
        menuBar.showOnboardingIfNeeded()

        // Start the server immediately.
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
