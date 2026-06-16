import AppKit

// SameDesk runs headless as a menu-bar item. We build the AppKit app
// programmatically (no storyboard / main window) so there is no main UI.
//
// `@main` with a `@MainActor` entry point so the app/delegate are created on the
// main actor (a file named `main.swift` with top-level code can't be MainActor-
// isolated, which is why this is a `@main` type instead).
@main
enum SameDeskApp {
    @MainActor
    static func main() {
        // Packaging self-test: verify the bundled browser assets resolve in the
        // current bundle layout (bare binary or .app), then exit. Used by
        // `scripts/make-app.sh` / CI to validate an assembled .app without
        // needing permissions or a running server.
        if ProcessInfo.processInfo.environment["SAMEDESK_SELFTEST"] == "1" {
            let ok = !ClientAssets.html.isEmpty && !ClientAssets.js.isEmpty
            FileHandle.standardError.write(Data("selftest: client assets \(ok ? "OK" : "MISSING")\n".utf8))
            exit(ok ? 0 : 1)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
