import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case connection, video, audio, display, security
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connection: return "Connection"
        case .video: return "Video"
        case .audio: return "Audio"
        case .display: return "Display"
        case .security: return "Security"
        }
    }
    var icon: String {
        switch self {
        case .connection: return "link"
        case .video: return "video"
        case .audio: return "speaker.wave.2"
        case .display: return "display"
        case .security: return "lock.shield"
        }
    }
}

/// Flat, opaque dark palette. Keeps the original mint/leaf/amber accents; drops
/// all the vibrancy/gradient "glass" in favour of solid surfaces + hairlines.
enum Theme {
    static let base = Color(red: 0.043, green: 0.051, blue: 0.050)   // detail background (darkest)
    static let panel = Color(red: 0.078, green: 0.090, blue: 0.088)  // sidebar background
    static let card = Color(red: 0.105, green: 0.118, blue: 0.116)   // card fill
    static let field = Color(red: 0.145, green: 0.158, blue: 0.156)  // input fill

    static let mint = Color(red: 0.47, green: 1.0, blue: 0.86)
    static let leaf = Color(red: 0.36, green: 0.96, blue: 0.55)
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.38)

    static let text = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.38)

    static let hairline = Color.white.opacity(0.08)
    static let cardStroke = Color.white.opacity(0.06)
}

struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var tab: SettingsTab = .connection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 1)
            detail
        }
        .frame(width: 720, height: 520)
        .background(Theme.base)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            brandHeader
            ForEach(SettingsTab.allCases) { t in tabButton(t) }
            Spacer()
            footer
        }
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }

    private var brandHeader: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.mint.opacity(0.16))
                .overlay {
                    Image(systemName: "display.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.mint)
                }
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("SameDesk")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Settings")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 40)
        .padding(.bottom, 16)
    }

    private func tabButton(_ t: SettingsTab) -> some View {
        let selected = tab == t
        return Button { tab = t } label: {
            HStack(spacing: 11) {
                Image(systemName: t.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Theme.mint : Theme.textSecondary)
                Text(t.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.mint.opacity(0.12) : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Theme.mint.opacity(0.28) : .clear, lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(vm.isRunning ? Theme.leaf : Theme.amber)
                    .frame(width: 8, height: 8)
                Text(vm.isRunning ? "Running" : "Stopped")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Button(vm.isRunning ? "Stop Server" : "Start Server") { vm.toggleServer() }
                .buttonStyle(FlatButton(prominence: vm.isRunning ? .subtle : .primary))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
        }
        .padding(12)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(tab.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 4)

                switch tab {
                case .connection: connectionTab
                case .video: videoTab
                case .audio: audioTab
                case .display: displayTab
                case .security: securityTab
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.base)
    }

    private var connectionTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Address") {
                Text(vm.baseURL.isEmpty ? "—" : vm.baseURL)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Copy URL") { vm.copyURL() }
                        .buttonStyle(FlatButton(prominence: .primary))
                    if vm.alternateURL != nil {
                        Button(".local URL") { vm.copyAlternateURL() }
                            .buttonStyle(FlatButton())
                    }
                    if vm.canAirDrop {
                        Button("AirDrop…") { vm.airDrop() }
                            .buttonStyle(FlatButton())
                    }
                }
            }
            SettingsSection("Port") { PortField(vm: vm) }
        }
    }

    private var videoTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Encoding") {
                ToggleRow(title: "Delta Encoding",
                          subtitle: "Skip unchanged frames — idle screen drops to near-zero bandwidth.",
                          isOn: $vm.deltaEncoding)
                Divider().overlay(Theme.hairline)
                ToggleRow(title: "HEVC / H.265",
                          subtitle: "≈2× compression (sharper at the same bitrate). Needs Safari 17+ or hardware HEVC; falls back to H.264.",
                          isOn: $vm.useHEVC)
            }
            SettingsSection("Bitrate") {
                HStack {
                    Text("Target bitrate").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    Spacer()
                    Text("\(Int(vm.bitrateMbps)) Mbps").foregroundStyle(Theme.textSecondary)
                }
                Slider(value: $vm.bitrateMbps, in: 1...20, step: 1).tint(Theme.mint)
                Text("Dense text at high resolution may want 8–20 Mbps on a LAN.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var audioTab: some View {
        SettingsSection("Audio") {
            ToggleRow(title: "Audio",
                      subtitle: "Stream system audio to the browser. Browsers block audio until you click in the page once.",
                      isOn: $vm.audioEnabled)
        }
    }

    private var displayTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Capture Resolution") { DownscalePickerRow(vm: vm) }
            SettingsSection("Display") {
                ToggleRow(title: "Headless / Virtual Display",
                          subtitle: "When no monitor is attached, create a full-resolution virtual display (falls back cleanly if unavailable).",
                          isOn: $vm.headless)
            }
        }
    }

    private var securityTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Status") {
                HStack(spacing: 9) {
                    Image(systemName: "lock.shield").foregroundStyle(Theme.leaf)
                    Text(vm.securitySummary.isEmpty ? "—" : vm.securitySummary)
                        .font(.callout).foregroundStyle(Theme.text)
                }
            }
            SettingsSection("Access Token") { TokenView(vm: vm) }
            SettingsSection("Diagnostics") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Copy a diagnostics snapshot").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        Text("Bind, codec, bitrate, display, permissions, cert age, clients, and last errors — token-free, safe to share.")
                            .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Copy Diagnostics") { vm.copyDiagnostics() }
                        .buttonStyle(FlatButton(prominence: .primary))
                }
            }
        }
    }
}

// MARK: - Reusable flat pieces

/// A labelled section: small uppercase caption above a solid card.
struct SettingsSection<Content: View>: View {
    let title: String
    private let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)
            Card { content }
        }
    }
}

struct Card<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
    }
}

struct FlatButton: ButtonStyle {
    enum Prominence { case subtle, primary, danger }
    var prominence: Prominence = .subtle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.6 : 1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
    }

    private var foreground: Color {
        switch prominence {
        case .primary: return Theme.mint
        case .subtle: return Theme.text.opacity(0.85)
        case .danger: return Color(red: 1.0, green: 0.62, blue: 0.60)
        }
    }
    private var fill: Color {
        switch prominence {
        case .primary: return Theme.mint.opacity(0.12)
        case .subtle: return Color.white.opacity(0.05)
        case .danger: return Color.red.opacity(0.12)
        }
    }
    private var border: Color {
        switch prominence {
        case .primary: return Theme.mint.opacity(0.40)
        case .subtle: return Color.white.opacity(0.12)
        case .danger: return Color.red.opacity(0.35)
        }
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
        }
    }
}

/// Segmented selector for the capture-resolution presets. Matches the flat theme
/// (selectable mint chips) rather than a system Picker.
struct DownscalePickerRow: View {
    @ObservedObject var vm: SettingsViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Resolution").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text("Downscale the screen before encoding. Lower uses less bandwidth and latency; Auto streams at native resolution.")
                    .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(DownscalePreset.allCases) { preset in chip(preset) }
            }
        }
    }

    private func chip(_ preset: DownscalePreset) -> some View {
        let selected = vm.downscalePreset == preset
        return Button { vm.downscalePreset = preset } label: {
            Text(preset.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Theme.mint : Theme.text.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Theme.mint.opacity(0.12) : Color.white.opacity(0.05))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(selected ? Theme.mint.opacity(0.40) : Color.white.opacity(0.12), lineWidth: 1)
                        }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PortField: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var text = ""
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Port").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text("Listener port (1024–65535). Changing it restarts the server and reloads connected browsers.")
                    .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            TextField("", text: $text)
                .frame(width: 78).multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        }
                }
                .onSubmit(apply)
            Button("Apply", action: apply)
                .buttonStyle(FlatButton(prominence: .primary))
        }
        .onAppear { text = String(vm.port) }
    }
    private func apply() { if let p = Int(text) { vm.applyPort(p) } }
}

struct TokenView: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var reveal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reveal ? vm.token : String(repeating: "•", count: 28))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button(reveal ? "Hide" : "Reveal") { reveal.toggle() }
                    .buttonStyle(FlatButton())
                Button("Copy Token") { vm.copyToken() }
                    .buttonStyle(FlatButton(prominence: .primary))
                Spacer()
                Button(role: .destructive) { vm.regenerateToken() } label: { Text("Regenerate") }
                    .buttonStyle(FlatButton(prominence: .danger))
            }
            Text("Regenerating invalidates the old URL. The token is stored in the Keychain.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
