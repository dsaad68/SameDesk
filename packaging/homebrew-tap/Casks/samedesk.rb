cask "samedesk" do
  version "1.1.0"
  sha256 "7b3c7d830acc11afc46f16001bf01ec6daccc1135320ede02a0d7b9b5e2f4cf8"

  url "https://github.com/dsaad68/SameDesk/releases/download/v#{version}/SameDesk-macos-arm64.zip",
      verified: "github.com/dsaad68/SameDesk/"
  name "SameDesk"
  desc "LAN-only remote desktop streamed to a web browser"
  homepage "https://github.com/dsaad68/SameDesk"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "SameDesk.app"

  # SameDesk is ad-hoc signed, not notarized — clear the quarantine flag so
  # Gatekeeper doesn't block first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/SameDesk.app"]
  end

  uninstall quit: "io.github.dsaad68.SameDesk"

  zap trash: [
    "~/Library/Application Support/SameDesk",
    "~/Library/Preferences/io.github.dsaad68.SameDesk.plist",
  ]

  caveats <<~EOS
    SameDesk runs as a menu-bar app (no Dock icon). On first launch, grant it:
      • Screen Recording — System Settings → Privacy & Security → Screen Recording
      • Accessibility    — System Settings → Privacy & Security → Accessibility

    It is ad-hoc signed (not notarized). The cask clears the quarantine flag for
    you; if macOS still blocks it, right-click SameDesk.app and choose Open once.
  EOS
end
