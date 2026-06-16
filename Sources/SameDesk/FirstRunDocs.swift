import AppKit
import Foundation

/// The long-form setup + security checklist, written to Application Support as a
/// Markdown reference. The native onboarding window (`OnboardingView`) covers the
/// interactive steps; this is the companion "things outside the app's control"
/// document, opened from the onboarding window's "Full security checklist" button.
enum FirstRunDocs {
    static var url: URL {
        Settings.shared.appSupportDirectory.appendingPathComponent("SameDesk-SETUP.md")
    }

    /// Write the checklist if it isn't there yet (idempotent, no UI).
    static func ensureWritten() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Write-if-needed, then open in the user's Markdown viewer.
    static func open() {
        ensureWritten()
        NSWorkspace.shared.open(url)
    }

    private static var body: String {
        """
        # SameDesk — Setup & Security Checklist

        SameDesk streams this Mac's screen to a browser on the **same WiFi/LAN**
        over HTTPS, and accepts keyboard/mouse/clipboard control back. It is
        **LAN-only by design** — there is no relay, no public-internet mode, and
        it never opens a router port mapping.

        ## One-time client trust (per device)

        Browsers must trust the local mkcert CA, or you'll get a certificate
        warning:

        1. Install mkcert and its CA on **each** client device:
           - macOS / Linux / Windows: `brew install mkcert` then `mkcert -install`
        2. On **iOS/iPadOS** you must additionally enable full trust:
           Settings → General → About → Certificate Trust Settings → enable the
           mkcert root.

        After that, opening the **Copy URL** link loads with no warning.

        ## Connecting

        - Use the menu-bar **Copy URL** item — it includes the access token and
          the Mac's **LAN IPv4** address. Because SameDesk binds IPv4-only, the
          IPv4 URL is the canonical one and always works on the LAN.
        - Opening that URL **pairs** the browser: the server sets a private,
          HttpOnly session cookie and redirects to the clean address, so the
          access token doesn't linger in the address bar or browser history.
        - The Settings window also offers a **.local URL** (the Mac's Bonjour
          hostname). It survives DHCP changes, but a `.local` name resolves to
          *both* IPv4 and IPv6 and browsers prefer IPv6 — so it only works on a
          LAN without IPv6.
        - Without a valid token or session cookie, every endpoint returns
          **401** / refuses the WebSocket upgrade.

        ## Security checklist (things outside the app's control)

        - [ ] **Disable UPnP / NAT-PMP** on your router. SameDesk never requests
              a port mapping, but other devices might have opened one.
        - [ ] Confirm your router's **inbound IPv6 firewall is closed**. SameDesk
              binds only a private LAN IPv4 address and refuses to start on a
              global address, but a wide-open IPv6 firewall is still bad hygiene.
        - [ ] Remove any **stale port-forwards** that could expose port \(Settings.shared.port).
        - [ ] Remember that an overlay VPN (e.g. **Tailscale**) widens what "LAN"
              means — anyone on that overlay with the token can connect.
        - [ ] Regenerate the access token (menu) if you ever shared a URL you
              shouldn't have.

        ## What the app guarantees

        - Binds a **specific LAN IPv4 interface** only — never 0.0.0.0, never ::.
        - **Never** requests UPnP IGD / NAT-PMP / PCP port mappings.
        - A startup pre-flight refuses to start if it would be reachable on a
          globally-routable address, and shows a one-line status in the menu.
        """
    }
}
