import AppKit
import Combine
import SwiftUI

/// Native first-run setup checklist: live permission + mkcert status, the
/// tokenized URL with a QR code, and the per-device trust steps. Reuses the flat
/// theme + components from `SettingsView`.
struct OnboardingView: View {
    @ObservedObject var vm: OnboardingViewModel
    var onDone: () -> Void

    // Poll permission/mkcert status while the window is open so checkmarks flip
    // as the user grants them in System Settings.
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                permissionsSection
                certificateSection
                connectSection
                trustSection
                footer
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 640, height: 700)
        .background(Theme.base)
        .preferredColorScheme(.dark)
        .onReceive(poll) { _ in vm.refresh() }
        .onAppear { vm.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to SameDesk")
                .font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
            Text("Stream this Mac to a browser on your LAN. A few one-time steps:")
                .font(.callout).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 12)
    }

    private var permissionsSection: some View {
        SettingsSection("Permissions") {
            StatusRow(title: "Screen Recording",
                      subtitle: "Required to capture the screen.",
                      ok: vm.hasScreenRecording,
                      actionTitle: "Open Settings",
                      action: vm.openScreenRecordingSettings)
            Divider().overlay(Theme.hairline)
            StatusRow(title: "Accessibility",
                      subtitle: "Required to inject keyboard, mouse, and clipboard.",
                      ok: vm.hasAccessibility,
                      actionTitle: "Open Settings",
                      action: vm.openAccessibilitySettings)
        }
    }

    private var certificateSection: some View {
        SettingsSection("Certificate") {
            StatusRow(title: "mkcert",
                      subtitle: "Provides the locally-trusted HTTPS certificate. Install it on this Mac and each client device:",
                      ok: vm.mkcertInstalled,
                      actionTitle: "How to install",
                      action: vm.openMkcertHelp)
            CodeSnippet(code: "brew install mkcert && mkcert -install")
        }
    }

    @ViewBuilder private var connectSection: some View {
        SettingsSection("Connect a device") {
            if vm.isRunning, !vm.url.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Open this URL on a device on the same Wi-Fi, or scan the code:")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(vm.url)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button("Copy URL") { vm.copyURL() }
                                .buttonStyle(FlatButton(prominence: .primary))
                            if vm.canAirDrop {
                                Button("AirDrop…") { vm.airDrop() }
                                    .buttonStyle(FlatButton())
                            }
                        }
                    }
                    Spacer()
                    if let qr = vm.qrImage {
                        Image(nsImage: qr)
                            .interpolation(.none).resizable()
                            .frame(width: 132, height: 132)
                            .padding(9)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            } else {
                Text("Starting the server… the connection URL and QR code appear here once it's listening.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trustSection: some View {
        SettingsSection("On the other device (one-time)") {
            VStack(alignment: .leading, spacing: 8) {
                bullet("Trust the mkcert CA, or the browser shows a certificate warning.")
                bullet("Mac / Linux / Windows: install mkcert, then run mkcert -install.")
                bullet("iOS / iPadOS: Settings → General → About → Certificate Trust Settings → enable the mkcert root.")
                Button("Full security checklist") { vm.openSecurityChecklist() }
                    .buttonStyle(FlatButton())
                    .padding(.top, 2)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Circle().fill(vm.allReady ? Theme.leaf : Theme.amber).frame(width: 8, height: 8)
            Text(vm.allReady ? "All set — you're ready to connect." : "Finish the steps above to be ready.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Done") { onDone() }
                .buttonStyle(FlatButton(prominence: .primary))
        }
        .padding(.top, 4)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(Theme.textTertiary)
            Text(text).font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A checklist row: status glyph + title/subtitle + an action (when not ready).
private struct StatusRow: View {
    let title: String
    let subtitle: String
    let ok: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(ok ? Theme.leaf : Theme.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if ok {
                Text("Ready").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.leaf)
            } else {
                Button(actionTitle, action: action).buttonStyle(FlatButton(prominence: .primary))
            }
        }
    }
}

/// A copy-pasteable inline command: monospaced text on a panel with a copy
/// button (text is also selectable for manual copy).
struct CodeSnippet: View {
    let code: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? Theme.leaf : Theme.mint)
            }
            .buttonStyle(.plain)
            .help("Copy command")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
