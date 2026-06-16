# Changelog

All notable changes to SameDesk are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

The latest entry below drives the GitHub Release published automatically when
`main` is updated (see `.github/workflows/release.yml`). To cut a release, add a
new `## [x.y.z] - YYYY-MM-DD` section at the top and merge to `main`.

## [1.1.0] - 2026-06-15

### Added
- **Homebrew cask** install (`brew install --cask dsaad68/tap/samedesk`) backed
  by a proper, ad-hoc-signed **`SameDesk.app`** bundle. Releases now ship the
  `.app` (not a bare binary), so granted Screen Recording / Accessibility
  permissions persist across upgrades.
- `scripts/make-app.sh` — assembles and signs the `.app` (Info.plist,
  `LSUIElement`, stable bundle id `io.github.dsaad68.SameDesk`) with a built-in
  bundled-asset self-test (`SAMEDESK_SELFTEST`).
- MIT `LICENSE`.

### Changed
- Browser assets resolve from standard bundle locations
  (`ClientAssets.candidateURLs`) instead of `Bundle.module`, so the client page
  loads whether SameDesk runs as a `.app` or a bare binary.
- The release workflow builds and publishes the `.app` zip and can auto-bump the
  Homebrew cask in `dsaad68/homebrew-tap`.

## [1.0.0] - 2026-06-15

First tagged release.

### Added
- **Local-network remote desktop**: stream a Mac's screen to any modern browser
  on the same LAN and control it back (keyboard, mouse, scroll, clipboard).
- **Capture → encode → mux pipeline**: ScreenCaptureKit capture, H.264 encoding
  via VideoToolbox (High / auto-level), and an on-the-fly hand-rolled fragmented
  MP4 muxer.
- **Two browser video backends** sharing one interface: low-latency **WebCodecs**
  (decode to `<canvas>`) by default, with **MSE** (`SourceBuffer`) as fallback.
  The init segment is self-describing, so the client adapts to the stream codec.
- **HEVC / H.265 option** (~2× compression at the same bitrate) with automatic
  fallback to H.264 when the Mac can't encode HEVC.
- **System audio streaming** (off by default): interleaved Float32 PCM over the
  socket, played via the Web Audio API.
- **Separate `/input` WebSocket** so input/clipboard/ping never queue behind
  video frames, and the measured RTT reflects true input latency.
- **Delta encoding**: skip frames with no dirty rects so an idle screen drops to
  near-zero bandwidth.
- **RTT-driven auto quality**: the client tunes target bitrate to keep latency low.
- **Headless / virtual display** support via the private `CGVirtualDisplay` API,
  with graceful fallback when unavailable.
- **In-page HUD**: FPS, bitrate, RTT, glass-to-glass latency (incl. 1s peak), a
  bitrate graph, and an "Export last 5 min (CSV)" button for offline analysis.
- **Security**: ≥32-byte Keychain-stored access token (constant-time compare),
  HTTPS + WSS only via a locally-trusted mkcert certificate, binding to the LAN
  IPv4 interface only (never `0.0.0.0`/IPv6), a startup pre-flight that refuses to
  start if not LAN-private, and no UPnP/NAT-PMP port mapping by design.
- **Menu bar**: status line, Copy URL, AirDrop URL…, Settings… (⌘,), Start/Stop
  Server, and Quit — each with an SF Symbol icon.
- **Settings window**: vertical tabs (Connection / Video / Audio / Display /
  Security) covering port, bitrate, delta encoding, HEVC, audio, headless display,
  and access-token reveal/copy/regenerate.

### Changed
- The browser client is now served as **static `client.html` + `client.js`**
  assets from the resource bundle (authored as real files, no Swift-string
  escaping). The video codec is delivered to the client at runtime as the first
  message on the media socket, keeping the page fully static.
- **Settings window redesigned** to a flat, opaque dark theme — removed the
  vibrancy/"glass" surfaces while keeping the mint/green accent palette.

### Fixed
- Client script no longer fails to parse (page stuck on "Connecting…"): a `\n`
  inside the embedded JS was being turned into a real newline by Swift's string
  literal, producing an unterminated string in the served JavaScript.
- Periodic-keyframe hiccup in the latency readout.
