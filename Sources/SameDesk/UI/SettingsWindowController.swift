import AppKit
import SwiftUI

/// Lazily creates and shows the Settings window. Since SameDesk is an accessory
/// (menu-bar) app, we manage the window manually and activate the app when
/// showing it.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let viewModel: SettingsViewModel

    init(coordinator: AppCoordinator) {
        self.viewModel = SettingsViewModel(coordinator: coordinator)
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(vm: viewModel))
            let window = NSWindow(contentViewController: hosting)
            // Standard opaque dark window: full-size content so the sidebar runs
            // under the (visible) traffic lights, but a SOLID background — no
            // desktop blur / vibrancy.
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = true
            window.backgroundColor = NSColor(srgbRed: 0.043, green: 0.051, blue: 0.050, alpha: 1)
            window.hasShadow = true
            window.title = "SameDesk"
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 720, height: 520))
            window.minSize = NSSize(width: 660, height: 480)
            window.center()
            self.window = window
        }
        viewModel.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
