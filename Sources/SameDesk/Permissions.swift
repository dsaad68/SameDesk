import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Screen Recording + Accessibility permission helpers.
enum Permissions {
    /// Non-prompting status checks, for diagnostics / status display. Unlike
    /// `ensure*`, these never trigger a system prompt or open System Settings.
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Accessibility (required for CGEvent injection). If not trusted, prompts
    /// and opens the relevant System Settings pane.
    @discardableResult
    static func ensureAccessibility(prompt: Bool = true) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            openSettings("Privacy_Accessibility")
        }
        return trusted
    }

    /// Screen Recording. Requesting `SCShareableContent` triggers the system
    /// prompt the first time; if denied it throws and we guide the user.
    static func ensureScreenRecording() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            await MainActor.run { openSettings("Privacy_ScreenCapture") }
            return false
        }
    }

    static func openSettings(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }
}
