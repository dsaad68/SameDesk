# Changelog

All notable changes to SameDesk are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

The latest entry below drives the GitHub Release published automatically when
`main` is updated (see `.github/workflows/release.yml`). To cut a release, add a
new `## [x.y.z] - YYYY-MM-DD` section at the top and merge to `main`.

## [0.1.0] - 2026-06-16

Initial public release.

### Added
- **Local-network remote desktop**: stream a Mac's screen to any modern browser
  on the same LAN and control it back (keyboard, mouse, scroll, pinch-zoom, and
  two-way clipboard) over an authenticated HTTPS + WebSocket endpoint.
- **Capture → encode → mux pipeline**: ScreenCaptureKit capture, H.264 (or
  optional HEVC — ~2× compression, automatic H.264 fallback) via VideoToolbox,
  and an on-the-fly hand-rolled fragmented-MP4 muxer.
- **Two browser video backends** behind one interface: low-latency WebCodecs
  (decode to `<canvas>`) by default, MSE (`SourceBuffer`) fallback. The
  self-describing init segment lets the client adapt to the stream codec.
- **System audio streaming** (optional), played via the Web Audio API, over a
  separate `/input` socket so input/clipboard/ping never queue behind video.
- **Delta encoding** drops an idle screen to near-zero bandwidth, and
  **RTT-driven auto quality** tunes the target bitrate to keep latency low.
- **Native first-run onboarding**: live permission + mkcert status, the tokenized
  URL with QR code, Copy URL / AirDrop, a copyable mkcert command, and per-device
  trust steps.
- **Pairing-cookie auth**: a tokenized URL sets an HttpOnly session cookie and
  redirects to a clean URL (keeping the token out of browser history); WebSockets
  stay token/cookie-gated.
- **In-page HUD**: FPS, bitrate, RTT, glass-to-glass latency (incl. 1s peak), a
  bitrate graph, and an "Export last 5 min (CSV)" button.
- **Settings window** (Connection / Video / Audio / Display / Security): port,
  bitrate, delta encoding, HEVC, audio, headless display, capture-resolution
  presets (Auto / 1080p / 1440p / Native-ish), access-token reveal/regenerate,
  and a Copy Diagnostics action.
- **Headless / virtual display** support via the private `CGVirtualDisplay` API.
- **Security hardening**: ≥32-byte Keychain-stored token (constant-time compare),
  HTTPS + WSS only via a locally-trusted mkcert cert, binding to the LAN IPv4
  interface only (never `0.0.0.0` / IPv6), a LAN-private startup pre-flight, and
  no UPnP/NAT-PMP port mapping by design.
- **Packaging & tooling**: a signed `SameDesk.app` (stable bundle id so
  permission grants persist across upgrades), a `justfile` (build / run /
  install-on-PATH / test / lint), unit tests plus Playwright browser smoke
  tests, and a GitHub Actions CI + release pipeline.
- App icon authored in Icon Composer (Liquid Glass), and an MIT `LICENSE`.
