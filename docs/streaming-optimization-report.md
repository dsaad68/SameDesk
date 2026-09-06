# SameDesk Streaming Review: Latency, Quality, Performance

**Date:** 2026-09-05
**Scope:** the capture → encode → mux → broadcast → browser pipeline, the input path, and audio. Based on a full read of the source on `main` plus a survey of how Sunshine/Moonlight (and the Lumen fork), Selkies, Parsec, RDP, Apple's own High Performance screen sharing, WebRTC (GCC), and Apple's VideoToolbox low‑latency mode approach the same problems. Sources are listed at the end.

> **Status (numbering follows the table in §1).** Items 1–8 are implemented, and
> the §10 instrumentation is in place, so the claims below can now be measured
> rather than argued about. Two items are partial:
>
> - **9 (audio)** — audio moved to its own `/audio` connection and to Int16
>   (half the bandwidth). Opus and the AudioWorklet ring buffer are not done:
>   both need codec negotiation with the client and an untested CoreAudio encoder
>   path, and on a LAN the transport split was the part that actually mattered.
> - **10 (worker)** — `pointerrawupdate` is in. The worker/OffscreenCanvas
>   migration is deliberately not; see §8.4.
>
> Also added beyond the list: capture is now sized to the client's viewport
> (§3.4), and a stale-init-segment bug found on the way is fixed — clients kept
> decoding against the first decoder config they were given even when the
> encoder's parameter sets changed.

---

## 1. Bottom line

SameDesk's architecture is already the right shape for a LAN remote desktop: hardware capture, hardware encode with no B‑frames and a one‑frame delay cap, one fragment per frame, a separate input socket, and WebCodecs on the client. The remaining latency and quality problems are not architectural. They are a handful of specific defects and missing feedback loops, most of which are cheap to fix. The transport (WebSocket over TCP) is fine on a LAN once the queueing amplifiers around it are removed; Selkies, the most active browser remote-desktop project, moved *to* WebSocket + WebCodecs as its default and keeps WebRTC as an opt‑in.

Ranked by expected impact per unit of work:

| # | Change | Expected effect | Effort |
|---|--------|-----------------|--------|
| 1 | **Fix silent P‑frame drops** in both drop‑oldest queues (encoder→consumer, per‑client). A dropped P‑frame breaks the reference chain; today nothing requests an IDR unless the decoder happens to throw. | Removes corruption/freeze episodes after any congestion; makes recovery deterministic (one keyframe instead of a stall). | Small |
| 2 | **Bound stale data in the send path**: shrink per‑client queue to ~3–6 frames, set a small `SO_SNDBUF`, and drive a server‑side "queue delay" signal (enqueue → write‑complete time) that both purges the backlog and steers bitrate. | Turns the documented 3–5 s freeze‑then‑fast‑forward into a ~100–300 ms freeze that snaps back to live. Replaces the coarse RTT‑only auto‑quality loop. | Medium |
| 3 | **Client catch‑up to live** in the WebCodecs sink: watch `decodeQueueSize` and frame age; when behind, drop deltas until the next keyframe and request one. | Same failure mode as #2 on the receive side. Selkies does exactly this. | Small |
| 4 | **Check and fix the H.264 reorder window.** VideoToolbox's hardware H.264 encoder emits `pic_order_cnt_type=0` with no VUI `bitstream_restriction`. Chrome's hardware decoder then may hold 2–16 decoded frames before output even with `optimizeForLatency`. Rewrite the SPS VUI (`max_num_reorder_frames=0`, `max_dec_frame_buffering=1`) in the muxer, as WebRTC does. | If it affects your clients, this is the single largest hidden latency term: 4 frames at 60 fps is 67 ms. Measure first (see §8). | Small–Medium |
| 5 | **Stamp capture time from the ScreenCaptureKit PTS**, not at broadcast. Also send the timestamp as the `EncodedVideoChunk.timestamp`. | Makes the HUD's glass‑to‑glass number true and gives the client the frame‑age signal that #3 needs. | Small |
| 6 | **Local cursor rendering**: capture with `showsCursor=false`, send cursor position and shape on the input socket, draw it in the page. | Cursor latency drops from full glass‑to‑glass to ~0. Cursor‑only motion stops triggering encodes. Standard in Moonlight/Steam Link/Citrix/RDP. | Medium |
| 7 | **VideoToolbox low‑latency rate control** (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`) plus `MaxAllowedFrameQP` for a text‑quality floor, and a **static‑screen refinement pass** (re‑encode the last frame 1–2× when motion stops). | Faster rate‑control adaptation, guaranteed text sharpness, and no more "blurry frame stuck on screen after scrolling" (Sunshine issue #717 is exactly this). | Small–Medium |
| 8 | **Capture in `420v` instead of BGRA**, and **allow two frames in flight** in the encoder (or encode at the client's viewport size). | Removes a per‑frame colour conversion inside VideoToolbox; avoids the 30 fps cliff when encode time exceeds 16.7 ms at 2560‑wide capture. | Small |
| 9 | **Audio: Opus (or at least Int16) instead of Float32 PCM**, and an AudioWorklet ring buffer on the client. | Audio is currently ~3.1 Mbps of uncompressed PCM sharing the video TCP stream and the video drop‑oldest queue. Opus at 96–128 kbps is ~25× smaller. | Medium |
| 10 | **Move WebSocket receive + decode + render into a Worker** (OffscreenCanvas or `VideoTrackGenerator` → `<video>`), and use `pointerrawupdate` for mouse input where available. | Removes main‑thread jank from the render path; shaves ~half a frame of input latency in Chromium. | Medium |

Transport migration (WebRTC or WebTransport) is analysed in §7. Recommendation: not now. Do items 1–5 first, then measure; WebRTC only pays off if Wi‑Fi loss remains the dominant problem after the queueing fixes.

---

## 2. Where the time goes today

Estimated per‑stage budget for a healthy LAN session at 60 Hz on both ends. Numbers are ranges from the cited sources and from the pipeline's own configuration; SameDesk does not yet instrument most stages (§8 proposes how).

| Stage | Typical | Notes |
|-------|---------|-------|
| Screen change → SCStream delivers frame | 16–40 ms | One frame interval plus WindowServer compositing. A measured SCK delay of ~40 ms at 60 fps is reported on Stack Overflow; `queueDepth=3` is already minimal. |
| Encode (VideoToolbox HW) | 5–18 ms | Lumen (Sunshine fork) measures ~15 ms for 1080p60 H.264 and ~18 ms for HEVC on an M4. mac‑screen‑cast measures 8–16 ms capture→send at 1280×772. SameDesk's default capture is up to 2560 px wide, so >16.7 ms per frame is plausible on motion. |
| Mux + actor hop + tag + TLS + WS write | <2 ms | Several `Data` copies per frame per client; negligible at 8 Mbps, noticeable on 300–500 KB keyframes. |
| Network | 1–2 ms wired, 2–10 ms Wi‑Fi | Wi‑Fi spikes of 100s of ms are the root cause in `docs/latency-hiccups-analysis.md`; the amplifiers are in the code. |
| Browser: WS message → JS handler | 1–5 ms | Main thread shared with HUD timers, input handlers, clipboard polling. |
| Decode (WebCodecs HW) | 3–10 ms | **Plus a possible 2–16 frame reorder window (33–267 ms) if the SPS lacks VUI bitstream restrictions.** See §4.4. |
| Draw → display | 8–33 ms | Canvas draw in the decoder callback, then the compositor and vsync. Chrome does not honour `desynchronized` on macOS, so the low‑latency canvas path is not active for Mac clients. |

Healthy total: roughly 50–100 ms, which matches the 11–120 ms `e2e` values in the hiccups capture (those values exclude capture time because the stamp is taken at broadcast). The stall episodes are a different regime entirely: 1–5 s, driven by queue depth, not by any per‑stage cost.

---

## 3. Findings: capture (`ScreenCapturer.swift`)

**3.1 Pixel format.** Capture requests `kCVPixelFormatType_32BGRA`. VideoToolbox's hardware encoder consumes 4:2:0 YCbCr, so every frame goes through an internal BGRA→NV12 conversion before encoding. Apple's WWDC22 ScreenCaptureKit session explicitly shows `420v` "for encoding" and BGRA "for on‑screen display". Switch to `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (`420v`) and set `colorMatrix` to `kCVImageBufferYCbCrMatrix_ITU_R_709_2` so colours are stable. Expect a small CPU/GPU saving and a few ms per frame; high confidence that it is Apple's recommended configuration, medium confidence on the latency delta.

**3.2 Retained pool buffer.** `lastPixelBuffer` holds one of the pool's surfaces indefinitely. WWDC22 states frames are lost if the app does not release surfaces back to the pool within `minimumFrameInterval × (queueDepth − 1)`. With `queueDepth = 3`, retaining one buffer leaves two in circulation. Either copy the last frame into an app‑owned buffer when the screen goes idle, or raise `queueDepth` to 4–5. A deeper pool does not add latency here because the capturer drops instead of queueing.

**3.3 Cursor is baked in.** `showsCursor = true` means every cursor move dirties the frame, so an otherwise idle screen encodes a P‑frame per mouse move, and the cursor is drawn with the full glass‑to‑glass delay. Every mature remote desktop renders the cursor locally: RDP, Citrix (server‑rendered cursor analysis), Moonlight (Ctrl+Alt+Shift+C shows the client cursor; local cursor rendering is on their roadmap), Steam Link. Implementation on macOS: `showsCursor = false`; on the input socket, send the cursor position (the server already knows it from the injected events, or poll `CGEvent(source:nil).location` / `NSEvent.mouseLocation` at ~120 Hz) and the current cursor image + hotspot from `NSCursor.currentSystem` (as PNG, re‑sent only when its hash changes). The page draws the cursor at the last known position immediately on local `pointermove`, then corrects to the server position. This is the biggest *perceived* latency win available.

**3.4 Capture resolution vs. client viewport.** The server captures at up to 2560 px long edge regardless of who is watching. A phone or an iPad viewport is smaller, and any non‑integer downscale in the browser blurs text twice (once at 4:2:0 subsampling, once at CSS scaling). Let the client report `innerWidth × devicePixelRatio` on connect and after resize, and pick the capture size to match (max over connected clients). This reduces encode time, bitrate, and improves sharpness at once.

**3.5 Delta gating.** The `dirtyRects.isEmpty` skip is correct and valuable. One caveat: it interacts badly with quality (§6.2), because the encoder never gets a second pass at a static image.

---

## 4. Findings: encoder (`H264Encoder.swift`)

**4.1 Low‑latency rate control mode.** The session is created without `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` (macOS 11.3+). That mode: forces the hardware encoder, uses an all‑P GOP with no reordering (which the current config already approximates via `AllowFrameReordering=false` and `MaxFrameDelayCount=1`), and switches to a rate controller with "faster adaptation in response to network change". Apple's WWDC21 example claims up to 100 ms less delay for 720p30 versus the default mode. It also unlocks the properties that matter for screen content: `MaxAllowedFrameQP`/`MinAllowedFrameQP` (macOS 13+), `BaseLayerFrameRateFraction` (temporal layers), and `EnableLTR` (macOS 12+). Constraints reported on Apple's forums: it cannot be combined with `ConstantBitRate` or `VariableBitRate` keys; H.264 is the documented codec, HEVC appears to work in low‑latency mode on newer OSes (WebKit tries a low‑latency HEVC encoder and falls back), so try it and fall back.

**4.2 One frame in flight.** `inFlight` allows a single outstanding encode. If encode takes longer than 16.7 ms at the capture resolution, throughput halves to 30 fps under motion. Hardware encoders pipeline; allowing two in flight keeps 60 fps at the cost of one extra frame of latency only when the encoder is actually the bottleneck. Combine with §3.4 so the common case stays under budget. Lumen's Sunshine fork found the same: their `PARALLEL_ENCODING` flag "decouples the capture and encode threads; without it, frame capture blocks until the previous frame finishes encoding".

**4.3 Reference‑chain integrity.** With `MaxKeyFrameInterval` effectively infinite, every P‑frame depends on the previous one. Any drop anywhere downstream corrupts the stream for that client until an IDR arrives. See §5.1; the fix belongs in the pipeline, but the encoder should expose a cheaper recovery than a full IDR: with low‑latency mode on, `EnableLTR` plus `ForceLTRRefresh` produces an "LTR‑P" frame predicted from a long‑term reference the client acknowledged, which Apple says is "usually much smaller than a key frame". This is the VideoToolbox equivalent of Moonlight's reference‑frame invalidation. It is worth it only if keyframe spikes turn out to be a problem after the basic fixes; for a single client, a forced IDR is simpler.

**4.4 H.264 reorder window in the browser decoder (verify first).** A Stack Overflow report with the *same* configuration as SameDesk (`High_AutoLevel`, `AllowFrameReordering=false`, long keyframe interval, hardware encoder `com.apple.videotoolbox.videoencoder.ave.avc`) observed a persistent 4‑frame output delay in the browser, sometimes 2, sometimes 16. Root cause: the SPS has `pic_order_cnt_type=0` and no VUI `bitstream_restriction`, so the decoder's DPB output delay is derived from the level/profile (up to 16 frames). Chrome's engineers on w3c/webcodecs#732 confirm: "the default size of the buffer is large (about 16 frames)... it is possible to specify a bitstream_restriction which can limit... `max_dec_frame_buffering`... and `max_num_reorder_frames`", and that WebRTC's `sps_vui_rewriter.cc` rewrites the SPS to add exactly this. The reporter fixed it by injecting VUI with `max_dec_frame_buffering=1`; `hardwareAcceleration: "prefer-software"` also gave 1‑in‑1‑out on Chrome but not Safari. SameDesk owns the `avcC` (the SPS is inside it), so the rewrite is contained in `FMP4Muxer.updateParameterSets`. Measure before fixing: log the delay between `decoder.decode()` for chunk N and the output callback for chunk N in the client. If it is one frame, skip this item.

**4.5 Rate control shape.** `AverageBitRate` + `DataRateLimits [bps/4 bytes, 1 s]` allows 2× bursts over one second. That is reasonable for a LAN and keyframes need it. The problem is what happens *under* congestion: the burst allowance fills the send queue faster. Once the queue‑delay signal from §5.2 exists, clamp `DataRateLimits` down when the queue is growing and raise it back when it drains.

**4.6 Codec choice.** HEVC gives ~2× compression but Lumen measures it ~20% slower to encode on Apple Silicon (~18 vs ~15 ms at 1080p60) and browser decode support is narrower (Safari, Chrome/Edge on hardware, not Firefox, not Linux). Keep it as the opt‑in it is. AV1: Apple Silicon has AV1 decode only (M3+), no encode, so not applicable. 4:4:4 chroma: not available from the VideoToolbox hardware encoders; Apple's own High Performance screen sharing does 4:4:4 but through private media‑engine paths and requires Apple Silicon on both ends. For SameDesk, the realistic text‑sharpness levers are QP capping, capture at the display's true scale, and the refinement pass (§6).

---

## 5. Findings: pipeline, broadcaster, and transport

**5.1 Silent P‑frame drops (bug).** Two places drop frames without telling anyone:

- `AppCoordinator.startFrameConsumer` uses `AsyncStream` with `.bufferingNewest(8)`. If the broadcaster falls behind, encoded frames are discarded for *every* client.
- `ClientConnection` uses `.bufferingNewest(90)`. Under a slow socket the oldest frames are discarded for that client.

In both cases the decoder receives a P‑frame whose reference is missing. Chrome's hardware H.264 decoder may error (then `requestKeyframe()` fires, one RTT later), or conceal and display corruption until the next IDR, which with no periodic keyframes may be never. Fix: wrap the per‑client queue so that on overflow it (a) clears the queue entirely, (b) sets `hasReceivedKeyframe = false`, and (c) requests an IDR. The first stream should be effectively unbounded or trigger the same keyframe request. This alone converts a stall into a clean resync.

**5.2 Queue depth and a real congestion signal.** The hiccups analysis already recommends shrinking the 90‑frame queue to ~20. Go further: 3–6 frames is enough on a LAN, because the goal is to shed stale frames, not to smooth jitter. The more important addition is measurement. `outbound.write` in Hummingbird awaits NIO's write promise, which completes when the kernel accepted the bytes. Record `enqueueTime` per frame and compute `queueDelay = writeCompleteTime − enqueueTime`. This number is available today with no new dependencies, and it is the best congestion signal on a TCP path: it rises tens of milliseconds before RTT on the separate input socket does. Use it for two things:

1. **Purge to live.** If `queueDelay` exceeds ~150–250 ms, drop the client's queue and resync on a keyframe (same mechanism as 5.1).
2. **Bitrate control.** Replace the client's 3‑second RTT‑threshold loop with a server‑side controller: multiplicative decrease (×0.6) when `queueDelay` trends up over ~2 frames, additive/multiplicative increase (×1.1) after a few seconds of near‑zero delay. This is the delay‑gradient idea from Google Congestion Control applied to the one place where TCP lets you observe it. Keep the client's RTT as a secondary input if you want, but stop letting it drive alone.

**5.3 Kernel send buffer.** For the write promise to mean anything, the kernel must not absorb megabytes. macOS auto‑tunes `SO_SNDBUF` upward; set it explicitly to ~128–256 KB on the media channel. At LAN RTTs this caps throughput at hundreds of Mbps, far above any target. `TCP_NOTSENT_LOWAT` (Apple recommends 128 KB for streaming servers in WWDC22 "Reduce networking delays") is worth setting too, but note the macOS semantics: it gates `poll`/`kqueue` writability, not `send()`, so on its own it does not limit how much NIO can push. `SO_SNDBUF` is the option that actually bounds stale data on Darwin. SwiftNIO already enables `TCP_NODELAY` by default (since 2019, PR #1020), so Nagle is not a factor. Hummingbird does not expose child‑channel options; set them in a thin `ServerChildChannel` wrapper around `.http1WebSocketUpgrade(...)` whose `setup(channel:)` calls `channel.setOption(ChannelOptions.socket(SOL_SOCKET, SO_SNDBUF), ...)` before delegating.

**5.4 WebSocket framing.** One binary frame per video frame is right. Confirm `permessage-deflate` is not negotiated (Hummingbird's default extension list is empty; verify in the handshake headers). Compression of H.264 payloads wastes CPU and adds latency.

**5.5 Copies.** Per frame: VideoToolbox block buffer → `Data` (copy 1) → fragment `Data` (copy 2) → tagged `Data` per client (copy 3 × N) → `ByteBuffer` (copy 4). Build the tagged payload once and share it across clients; construct the `ByteBuffer` directly from the block buffer pointer. Not a latency issue at 8 Mbps, but it matters on 300–500 KB keyframes and with several viewers.

**5.6 Audio shares the video stream.** Float32 stereo 48 kHz PCM is 3.07 Mbps, sent on `/ws` and through the same drop‑oldest queue as video. Under congestion, a 400 KB keyframe delays the audio behind it, and drop‑oldest discards audio buffers as readily as video, producing the clicks the ordered audio consumer was meant to avoid. See §6.4 for the codec fix; separately, consider a third socket for audio so it is not head‑of‑line blocked by keyframes.

---

## 6. Findings: quality

**6.1 QP floor for text.** With `AverageBitRate` alone, the encoder is free to raise QP during motion and text turns to mush. In low‑latency mode, `kVTCompressionPropertyKey_MaxAllowedFrameQP` caps that. Apple presents it in WWDC21 specifically for "group screen sharing". A value in the low 30s keeps text readable; bitrate becomes a soft target, which is fine on a LAN when combined with the queue‑delay controller (§5.2) that cuts bitrate only when it actually hurts.

**6.2 Static refinement after motion.** Delta gating means the last frame of a scroll (encoded at motion quality) stays on screen indefinitely. Sunshine had precisely this bug (issue #717: "a very poor quality, persistent frame that does not correct itself until you move the mouse again"); their fix was to keep encoding a few frames after motion stops, and they now expose `minimum_fps_target` for it. SameDesk can do better than duplicate frames: when `dirtyRects` has been empty for ~100 ms after a burst of motion, resubmit `lastPixelBuffer` once or twice (the machinery already exists in `emitKeyframeFromCache`, minus the forced keyframe). The residual is near zero, so the encoder spends its per‑frame budget refining detail. Two extra P‑frames on a static screen cost almost nothing.

**6.3 Bitrate ownership.** Two controllers fight: the server default is 4 Mbps, the client's auto‑quality pushes 8 Mbps on connect and ramps to 20 Mbps, overriding the user's Settings value silently. Make the server the single owner (its controller in §5.2), keep the user setting as a ceiling, and show the effective value in the HUD.

**6.4 Audio codec.** macOS 14 ships an Opus codec in AudioToolbox (Wikipedia's OS support table lists "Full: macOS Sonoma (14.0)"; developer reports use `AudioConverterNew` with `kAudioFormatOpus`, 20 ms packets, `kAudioCodecPropertyBitRateControlMode` set). Encode with `AudioConverter` at 96–128 kbps, decode in the browser with `AudioDecoder({codec: "opus"})`, and play through an `AudioWorklet` ring buffer instead of scheduling `AudioBufferSourceNode`s with a 60 ms lead (freerdp‑web reports 5–20 ms this way). Selkies also uses Opus and adds RED redundancy for lossy links. Verify Opus encode availability at runtime and fall back to Int16 PCM (half the current bandwidth) if the converter fails to create.

**6.5 Capture scale.** Capturing at point resolution (capped at 2560) then scaling in the browser is the right trade for a 60 fps budget, but see §3.4: matching the viewer's pixel size removes one resampling step and often lets you raise the QP floor instead.

---

## 7. Transport: stay on WebSocket for now

| Option | What it buys | What it costs | Verdict |
|--------|--------------|---------------|---------|
| **WebSocket over TLS (current)** | Single port, works everywhere, mkcert already solved. With §5 fixes: stale data bounded to a few frames + `SO_SNDBUF`. | TCP head‑of‑line blocking: a lost packet on Wi‑Fi stalls everything for one retransmit (10–30 ms typical; RTO back‑off can be much worse). | Keep. Selkies ships this as its default with WebCodecs and a WebRTC opt‑in. |
| **WebRTC** (libwebrtc via `stasel/WebRTC` SPM binaries) | UDP, NACK/PLI, GCC congestion control that reacts in ~100 ms, jitter buffer you can set to ~0 (`jitterBufferTarget`), native `<video>` playback with hardware decode, Opus built in, data channel for input (optionally unordered/unreliable). mac‑screen‑cast (Rust + rustrtc, same capture/encode stack) reports 30–60 ms LAN glass‑to‑glass. | Large binary framework, C++ toolchain via xcframework, ICE/SDP signalling (trivial on a LAN with host candidates), and you hand keyframe/bitrate decisions to libwebrtc's own VideoToolbox encoder path. The hand‑rolled muxer and both client sinks go away. | Only if Wi‑Fi loss remains the dominant problem after §5. |
| **WebTransport / HTTP/3** | No HOL blocking, datagrams, and `serverCertificateHashes` would let the media channel skip mkcert (but Chrome ignores system roots for WebTransport, and hash‑pinned certs are limited to 14 days, so you would need rotation). | No production Swift server stack. Quiver (pure‑Swift QUIC/H3/WebTransport, Feb 2026) is promising but has 6 commits, is tested mainly on Linux, and Safari support for WebTransport is recent. | Not yet. Re‑evaluate in a year. |

A useful middle step that needs no new transport: keep video on WebSocket but move audio to its own socket, so keyframes never block it.

---

## 8. Findings: client (`client.js`)

**8.1 No catch‑up in the WebCodecs sink.** Already identified in the hiccups doc. Concretely: before `decoder.decode()`, check `decoder.decodeQueueSize`; if above ~2–3, or if the frame's capture age (once §5 stamps it) exceeds ~250 ms, set `waitingKey = true`, skip deltas, and call `requestKeyframe()`. Selkies' worker does exactly this with an `OVERLOAD_QUEUE` threshold and a throttled `needKeyframe`.

**8.2 Timestamps.** `ts += 16666` is synthetic. Pass the real capture time (µs) as `EncodedVideoChunk.timestamp`; the output `VideoFrame.timestamp` then lets the client compute decode latency and true frame age per frame, and the HUD can show a per‑stage breakdown.

**8.3 Render path.** `drawImage` into a `desynchronized` 2D canvas in the decoder callback is a reasonable choice, but note that Chrome does not implement the desynchronized (single‑buffer) canvas mode on macOS (a Feb 2025 chromium graphics‑dev thread: "the non‑copy‑on‑write mode currently doesn't work on Mac"), so Mac viewers get the ordinary compositor path. Selkies' "zero‑copy" path is `VideoTrackGenerator` (in a worker) or `MediaStreamTrackGenerator` feeding a `<video>` element's `srcObject`, with OffscreenCanvas and then main‑thread `drawImage` as fallbacks. That path lets the browser use its video overlay/compositor fast path and avoids a copy. Worth an A/B on the Macs and iPads you actually use; the difference is small on LAN but it is free once the worker exists.

**8.4 Worker isolation.** The main thread runs the WebSocket handler, box scanning, decode submission, canvas drawing, the HUD's 1 Hz redraw, a 1 Hz clipboard poll, a 1 Hz ping, and every mouse event. Any of these can delay a frame. Chrome's WebCodecs guidance and both Selkies and freerdp‑web move the socket + decoder + rendering into a Worker with `OffscreenCanvas`. Do the same; keep input and HUD on the main thread.

**8.5 Input events.** In Chromium, `mousemove`/`pointermove` are aligned to `requestAnimationFrame`, which adds on average half a frame before your handler runs. `pointerrawupdate` (Chrome 77+, Firefox 148+, not Safari) fires immediately; use it when present, fall back to `pointermove`. Each event is a small JSON text frame; that is fine, JSON parsing on the server is microseconds. Do not coalesce on the client; the server can coalesce moves if `CGEvent` posting ever becomes the bottleneck (it will not at mouse rates).

**8.6 Reconnect.** On reconnect the sink re‑inits, but the server sends the init segment only on the next keyframe. This is already handled by the connect‑time keyframe request; make sure the purge‑to‑live path (§5.1) reuses it.

---

## 9. What comparable projects do

- **Sunshine / Moonlight / Lumen.** Variable frame rate encode with damage tracking, forced IDR or reference‑frame invalidation on client‑reported loss, FEC on UDP, client cursor option, per‑stage latency overlay (encode, network, decode, render, queue). Lumen documents VideoToolbox specifics on Apple Silicon: `ReferenceBufferCount=1` makes every frame an IDR (do not set it), parallel capture/encode is needed to hold 60 fps, and H.264 encodes faster than HEVC.
- **Selkies.** Default transport is WebSocket + WebCodecs (WebRTC opt‑in), damage‑driven encode that "spins down to zero when there is no motion", Opus audio, decode in a worker, `VideoTrackGenerator` rendering, `decodeQueueSize`‑based overload handling with throttled keyframe requests, JPEG fallback for browsers without WebCodecs.
- **Parsec.** Recommends HEVC + "Prefer 4:4:4" + constant FPS for text‑heavy work; 4:4:4 is what makes coloured text crisp, and it is the one thing SameDesk cannot get from Apple's hardware encoder.
- **RDP (AVC444 / mixed mode).** Text is ~80% of a remote session; RDP uses a text‑optimised codec for it and AVC only for images/video, or AVC444 full‑screen. The lesson for a pure‑H.264 design is the QP floor plus refinement in §6.
- **Apple High Performance screen sharing (Sonoma).** Apple Silicon both ends, UDP ports 5900–5902, 4:4:4, 30/60 fps, HDR, up to 4K virtual display. Confirms that Apple's own answer to this problem is UDP plus the media engine; the 4:4:4 path is not exposed to third parties.
- **WebRTC / GCC.** Delay‑gradient congestion detection with a 5 ms pacer and per‑frame feedback. The queue‑delay controller in §5.2 is the TCP‑observable analogue.
- **mac‑screen‑cast (Rust).** Same SCK → VideoToolbox stack, RTP/WebRTC out: 8–16 ms capture→send, ~3% CPU, 30–60 ms LAN glass‑to‑glass. A useful reference point for what the server half should cost.

---

## 10. Measurement plan (do this first)

The HUD currently reports fps, bitrate, RTT, and a glass‑to‑glass number that starts at broadcast time. Add per‑stage stamps so each change can be verified:

1. **Server**: capture PTS (host clock → wall clock via `Date() − (CMClockGetTime(host) − pts)`), encode‑done time, write‑complete time. Send capture time in the existing 8‑byte header; log the other two per frame at debug level and expose 1 s percentiles in the diagnostics report.
2. **Client**: receive time (`performance.now()` in `onmessage`), decode‑submit time, decode‑out time (`VideoFrame` callback, keyed by timestamp), and paint time (`requestAnimationFrame` after `drawImage`, or `requestVideoFrameCallback` on the `<video>` path). Show decode latency and `decodeQueueSize` in the HUD, and add them to the CSV export.
3. **Reorder‑window check** (§4.4): with the above, decode latency of one frame interval or less means the SPS is fine; a stable 2–16 frames means it is not. Also test `hardwareAcceleration: "prefer-software"` once as a diagnostic.
4. **Stall test**: throttle Wi‑Fi (or use Network Link Conditioner with 1% loss, 50 ms delay) and confirm that after §5 a stall recovers with one keyframe within ~300 ms instead of a multi‑second fast‑forward.

---

## 11. Suggested order of work

**Phase 1 (days): correctness and measurement.** Items 1, 3, 5 from §1 plus the instrumentation in §10. No new dependencies. This is where the visible stalls go away.

**Phase 2 (a week): transport tuning and encoder mode.** Queue‑delay controller and `SO_SNDBUF` (§5.2–5.3), low‑latency rate control + `MaxAllowedFrameQP` + refinement pass (§4.1, §6.1–6.2), `420v` capture and two‑in‑flight encode (§3.1, §4.2), SPS VUI rewrite if §10.3 shows a reorder window, single bitrate owner (§6.3).

**Phase 3 (one to two weeks): client and cursor.** Worker + OffscreenCanvas/`VideoTrackGenerator` (§8.3–8.4), local cursor (§3.3), viewport‑matched capture (§3.4), `pointerrawupdate` (§8.5), Opus audio on its own socket (§6.4, §5.6).

**Phase 4 (only if needed): WebRTC.** Decide after measuring Phase 1–3 on the Wi‑Fi links you care about.

---

## Sources

Apple
- WWDC21, "Explore low‑latency video encoding with VideoToolbox": https://developer.apple.com/videos/play/wwdc2021/10158/
- `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`: https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablelowlatencyratecontrol
- Sample: Encoding video for low‑latency conferencing: https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing
- WWDC22, "Take ScreenCaptureKit to the next level" (420v for encoding, pool release rule): https://developer.apple.com/videos/play/wwdc2022/10155/
- `SCStreamConfiguration.pixelFormat` / `colorMatrix`: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/pixelformat
- WWDC22, "Reduce networking delays for a more responsive app" (TCP_NOTSENT_LOWAT 128 KB): https://developer.apple.com/videos/play/wwdc2022/10078/
- WWDC15, "Your App and Next Generation Networks" (TCP_NOTSENT_LOWAT): https://developer.apple.com/videos/play/wwdc2015/719/
- Apple Remote Desktop: High Performance screen sharing: https://support.apple.com/guide/remote-desktop/use-high-performance-screen-sharing-apdf8e09f5a9/mac
- VideoToolbox header availability (MinAllowedFrameQP macOS 13, EnableLTR macOS 12, PrioritizeEncodingSpeedOverQuality macOS 11): https://github.com/dotnet/macios/wiki/VideoToolbox-iOS-xcode16.0-b1
- Apple forum on LTR attachments: https://developer.apple.com/forums/thread/703292
- Apple forum: low‑latency rate control vs ConstantBitRate/VariableBitRate: https://developer.apple.com/forums/tags/videotoolbox
- WebKit: try low‑latency HEVC encoder: https://github.com/WebKit/WebKit/commit/d7ef486d1adcad4aa0b585313af3d2dda9c9ac1f
- `NSCursor.currentSystem`: https://developer.apple.com/documentation/appkit/nscursor/currentsystem

Decoder reorder window
- Stack Overflow, VideoToolbox H.264 → browser 4‑frame latency and the VUI fix: https://stackoverflow.com/questions/78191531/
- w3c/webcodecs #732, "best way to ensure 1‑in 1‑out decoding for h264": https://github.com/w3c/webcodecs/issues/732
- Chromium issue thread on H.264 1‑in‑1‑out requirements: https://issues.chromium.org/issues/439294798
- WebRTC `sps_vui_rewriter.cc` (reference implementation): https://webrtc.googlesource.com/src/+/refs/heads/main/common_video/h264/sps_vui_rewriter.cc

Capture latency
- ScreenCaptureKit delay >16 ms at 60 fps: https://stackoverflow.com/questions/79718758/
- SCK PTS clock domain: https://developer.apple.com/forums/thread/785046

Comparable projects
- Selkies (WebSocket + WebCodecs default): https://github.com/selkies-project/selkies and https://selkies-project.github.io/selkies/component
- LinuxServer.io on Selkies' WebSocket/WebCodecs design: https://www.linuxserver.io/blog/webtop-4-1-x11-is-dead-and-what-is-selkies-anyway
- Lumen (Sunshine fork for Apple Silicon; VideoToolbox timings and fixes): https://github.com/trollzem/Lumen
- Sunshine VideoToolbox all‑IDR issue: https://github.com/LizardByte/Sunshine/issues/5013
- Sunshine static‑frame quality issue: https://github.com/LizardByte/Sunshine/issues/717
- Sunshine configuration (fec_percentage, minimum_fps_target, vt_realtime): https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html
- Moonlight FAQ (latency breakdown): https://github.com/moonlight-stream/moonlight-docs/wiki/Frequently-Asked-Questions
- Moonlight local cursor discussion: https://github.com/moonlight-stream/moonlight-qt/issues/1929
- Parsec stream quality (4:4:4): https://support.parsec.app/hc/en-us/articles/32381785123860
- RDP graphics encoding (mixed mode, AVC444): https://learn.microsoft.com/en-us/azure/virtual-desktop/graphics-encoding
- mac‑screen‑cast (SCK + VT + WebRTC, measured latency): https://github.com/lichtcui/mac-screen-cast
- freerdp‑web (worker + OffscreenCanvas + AudioWorklet): https://github.com/qxsch/freerdp-web
- Google Congestion Control draft: https://datatracker.ietf.org/doc/html/draft-ietf-rmcat-gcc-02

Transport
- SwiftNIO enables TCP_NODELAY by default: https://github.com/apple/swift-nio/pull/1020
- Hummingbird `Server.swift` (child channel options): https://github.com/hummingbird-project/hummingbird/blob/main/Sources/HummingbirdCore/Server/Server.swift
- TCP_NOTSENT_LOWAT semantics on macOS (poll vs send): https://github.com/dabeaz/curio/issues/83 and https://github.com/python-trio/trio/issues/371
- Linux TCP_NOTSENT_LOWAT commit: https://lwn.net/Articles/560082/
- stasel/WebRTC (libwebrtc binaries for macOS via SPM): https://github.com/stasel/WebRTC
- Quiver (pure‑Swift QUIC/HTTP3/WebTransport): https://github.com/hironichu/Quiver
- WebTransport explainer (serverCertificateHashes, 2‑week limit): https://github.com/w3c/webtransport/blob/main/explainer.md
- WebTransport TLS caveats in Chrome: https://moq.dev/blog/tls-and-quic/

Browser client
- Chrome: low‑latency canvas `desynchronized`: https://developer.chrome.com/blog/desynchronized
- chromium graphics‑dev, "Enable canvas low‑latency mode on Mac" (not yet supported): https://groups.google.com/a/chromium.org/g/graphics-dev/c/20qDm3ZD2f8
- Chrome: Video processing with WebCodecs (workers): https://developer.chrome.com/docs/web-platform/best-practices/webcodecs
- WebCodecs decodeQueueSize handling: https://stackoverflow.com/questions/77609003/
- `pointerrawupdate` intent to ship (rAF‑aligned pointermove): https://groups.google.com/a/chromium.org/g/blink-dev/c/mUW58VMIrTM/m/gIotA4HwBAAJ
- `pointerrawupdate` support table: https://caniuse.com/mdn-api_element_pointerrawupdate_event

Audio
- Opus OS support (AudioToolbox, macOS 14): https://en.wikipedia.org/wiki/Opus_(audio_format)
- AudioConverter + kAudioFormatOpus usage: https://stackoverflow.com/questions/59444875/avaudioconverter-opus
