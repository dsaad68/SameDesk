# Changelog

All notable changes to SameDesk are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

The latest entry below drives the GitHub Release published automatically when
`main` is updated (see `.github/workflows/release.yml`). To cut a release, add a
new `## [x.y.z] - YYYY-MM-DD` section at the top and merge to `main`.

## [Unreleased]

### Fixed
- **Dropped frames no longer corrupt the stream.** Both drop-oldest queues
  (encoder→consumer and per-client) discarded encoded frames silently; with no
  periodic IDR, a discarded P-frame broke the decoder's reference chain until
  something happened to throw. Overflow now resynchronises that client on a fresh
  init segment and keyframe.
- **A Wi-Fi blip is a brief freeze, not a multi-second fast-forward.** The
  per-client queue held ~1.5 s of video (90 frames) with an auto-tuned kernel send
  buffer holding megabytes more below it. The queue is now 6 frames, `SO_SNDBUF`
  is capped, and a slow socket write sheds the stale backlog instead of playing it
  out late. The browser does the same on its side, skipping to the next keyframe
  rather than decoding a backlog.
- **Browser decoders no longer buffer decoded frames.** VideoToolbox omits the
  VUI bitstream restriction, so decoders fall back to the reorder window implied
  by the level — up to 16 frames of latency invisible in any bitrate or RTT graph.
  The muxer now rewrites the SPS to signal `max_num_reorder_frames = 0`.
- **Blurry text after scrolling.** Delta encoding skipped every frame once motion
  stopped, freezing the last motion-quality frame on screen. The encoder now gets
  two refinement passes once things settle.
- **Audio no longer shares the video socket.** Uncompressed audio queued behind
  keyframes and was shed by video congestion as clicks. It now has its own
  `/audio` connection and goes out as Int16 rather than Float32 (half the
  bandwidth).
- **Stale decoder configs.** When the encoder's parameter sets changed mid-stream,
  clients kept the init segment they were first given.

### Changed
- **Bitrate is decided server-side** from measured send-queue delay rather than
  by the client from RTT on an idle socket. The Bitrate setting is now a ceiling,
  and the HUD reports what the server actually settled on. The client-side "Auto
  Quality" toggle is gone.
- **The cursor is drawn by the browser** (Settings → Video → Client-Rendered
  Cursor, default on): no round trip to see your own pointer move, and a mouse
  move no longer dirties an otherwise idle frame.
- **Capture matches the client's viewport**, snapped to a short ladder, so a
  2560 px stream is not encoded for a 900 px window.
- **Encoding**: VideoToolbox low-latency rate control with a per-frame QP cap
  (a quality floor for text), two frames in flight rather than one, and 420v
  capture so the encoder no longer colour-converts every frame.
- Glass-to-glass latency is measured from capture rather than from broadcast, and
  the HUD and CSV export gained decoder latency and skipped-frame counts.
- Mouse input uses `pointerrawupdate` where available.

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
