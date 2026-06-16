# Latency Hiccup Analysis — Wi‑Fi Transport Stalls

**Date:** 2026-06-16
**Source capture:** `samedesk-stats-2026-06-16T14-49-32-286Z.csv` (51 s, sampled 1 Hz via the HUD "export stats" button)

## Summary

The periodic "hiccups" — a freeze followed by a fast-forward / jump — are **network
transport stalls, not encoder or capture problems.** The signature is a multi-second
window where no frames reach the client, during which encoded frames pile up in the
send path, followed by a burst that flushes the whole backlog at once.

The root cause is the **Wi‑Fi link**. Both machines being on the same network does not
rule this out: the stall happens at the 802.11 radio / link layer on whichever leg is
wireless (airtime contention, link-layer retransmits, or AP roaming / powersave).

Two code-side factors **amplify** each blip into a visible multi-second event but do
not cause it; both are cheap to fix and would make the app degrade gracefully under
any flaky link.

## The data

Columns: `timestamp, fps, mbps, rtt_ms, e2e_ms, e2e_peak_ms`.

- `rtt_ms` — input-socket ping/pong round trip (the `/input` WebSocket, independent of video).
- `e2e_ms` — smoothed glass-to-glass latency (EMA, 0.7 old + 0.3 new).
- `e2e_peak_ms` — worst single frame in that 1 s window.

### Two distinct kinds of `fps = 0`

Only one is a problem.

**Benign idle gaps** — delta encoding correctly skipping unchanged frames. Low fps,
near-zero bitrate, *low* RTT, *tiny* peak, and no burst afterward:

```
14:48:48   fps 1    mbps 0.020   rtt 30   e2e 68   peak 27
14:48:49   fps 1    mbps 0.018   rtt 9    e2e 54   peak 20
14:48:50   fps 2    mbps 0.039   rtt 8    e2e 37   peak 27
```

**Transport stalls (the hiccups)** — every other zero-window is followed by a
burst-flush. Example around `14:49:25`:

| time      | fps   | mbps  | rtt | e2e | e2e_peak |
|-----------|-------|-------|-----|-----|----------|
| :24       | 9     | 0.119 | 9   | 114 | 258      |
| :25       | **0** | 0     | 9\* | 114\* | 0      |
| :26       | **0** | 0     | 9\* | 114\* | 0      |
| :27       | **0** | 0     | 9\* | 114\* | 0      |
| :28       | **104** | 1.396 | 630 | 644 | **4844** |

`*` = frozen value: the HUD only updates `rtt`/`e2e` when a frame or pong arrives, so
during the stall the previous numbers are held.

The same shape repeats throughout the capture:

| stall window | recovery sample | recovery fps | recovery rtt | e2e_peak |
|--------------|-----------------|--------------|--------------|----------|
| :53          | :54             | 33           | 47           | 1288 ms  |
| :55–:57      | :58             | 33           | 270          | 3614 ms  |
| :03–:04      | :05             | 17           | 573          | 2939 ms  |
| :22          | :23             | 39           | 392          | 1286 ms  |
| :25–:27      | :28             | 104          | 630          | 4844 ms  |

For reference, the **healthy** baseline in this same session is e2e ≈ 11–120 ms and the
first second moved **3.99 Mbps** cleanly — so the link is fine when it isn't stalled.

## Why this is the transport, not capture/encode

Three independent pieces of evidence:

1. **104 fps in one second is physically impossible from capture.** Capture is capped
   at 60 fps (`Sources/SameDesk/Capture/ScreenCapturer.swift:71`,
   `minimumFrameInterval = 1/60`). Decoding ~100 frames in one second means ~100 frames
   were **encoded and queued but not sent** during the preceding "zero" seconds, then
   released together. If the *encoder* had stalled there would be no backlog at all —
   `ScreenCapturer.swift:167` drops frames when the encoder is busy and never queues
   them. So the backlog lives **downstream of the encoder**: the per-client send queue
   plus the TCP socket buffer.

2. **`e2e_peak` of 4844 ms** is the age of the oldest frame in that flushed backlog —
   ~4.8 s glass-to-glass. Note `captureTimeMs` is currently stamped at *broadcast* time
   (`Sources/SameDesk/AppCoordinator.swift:446`, `Date().timeIntervalSince1970`), **not**
   at capture, so that 4.8 s is purely queue + socket + client delay, all downstream of
   broadcast. (The true motion-to-photon is therefore slightly worse than reported.)

3. **RTT spikes to 270–630 ms on the *independent* input socket.** Ping/pong rides
   `/input` (`Sources/SameDesk/Client/client.js:388`), a separate WebSocket from the
   video stream. For it to spike in lockstep with the video stall, the whole link
   hiccuped — the hallmark of Wi‑Fi, not a video-specific encode issue. Confirming this:
   bitrate is tiny during stalls (0.02–0.6 Mbps) while the link hit ~4 Mbps healthy, so
   this is a **latency stall, not bandwidth exhaustion or a CPU ceiling.**

### Why "same network" still means Wi‑Fi

- **Half-duplex airtime contention** — Wi‑Fi is a shared medium; sender and receiver
  can't transmit simultaneously, and any other device on the AP (a phone, the AP's own
  beacons) steals airtime in bursts.
- **Link-layer retransmits** — a single corrupted 802.11 frame triggers retries that
  stall the TCP stream for tens-to-hundreds of ms; a burst of them is a multi-second
  freeze.
- **Roaming / band steering / NIC powersave** — the radio briefly parks, the queue
  backs up, then floods.

## Code-side amplifiers (do not cause it, but make it worse)

- **The WebCodecs sink has no catch-up-to-live.** `pushSegment`
  (`Sources/SameDesk/Client/client.js:117`) decodes *every* queued chunk in order, so
  after a stall it plays the entire backlog back-to-back — that is the 104 fps reading
  and the visible freeze→fast-forward. The MSE fallback path *does* jump to live
  (`client.js:186`, `if (lat > 2)`), but the WebCodecs path does not.
- **The per-client buffer is 90 frames deep** (`Sources/SameDesk/Server/Broadcaster.swift:28`)
  ≈ up to 1.5 s of video at 60 fps before drop-oldest engages, plus the kernel TCP
  buffer on top. That lets a lot of stale video accumulate, contradicting the
  "stay at the live edge" rationale behind the shallow `queueDepth = 3` on capture.

## Recommendations

1. **Confirm (no code).** Run one session with both ends on Ethernet (or a
   Thunderbolt/USB‑C bridge). If the bursts disappear, Wi‑Fi is confirmed.

2. **Make the app survive a flaky link anyway** — a 1 s RF blip should become a brief
   freeze that snaps back to live, not a 4 s fast-forward:
   - **WebCodecs drop-to-live** — when segments back up (or a frame's capture-age
     exceeds a threshold, e.g. ~250 ms), skip deltas and request a fresh keyframe
     instead of decoding the whole backlog.
   - **Shrink the per-client buffer** from 90 to ~20 frames so stale video is shed in
     ~0.3 s instead of ~1.5 s.
   - **Stamp `captureTimeMs` at capture** (carry the SCStream PTS through to broadcast)
     so the latency readout is true glass-to-glass and can drive the drop-to-live
     decision above.

3. **Environmental mitigations for Wi‑Fi** — prefer 5 GHz, keep the client near the AP,
   and reduce other traffic on the same AP.

## How to reproduce / collect more data

Open the HUD on the client, let a session run, then click the stats export button to
download a `samedesk-stats-*.csv`. The hiccup signature to look for: `fps` drops to 0
for ≥1 s with `rtt`/`e2e` frozen, immediately followed by a sample with `fps` above the
60 fps capture cap and an `e2e_peak` in the hundreds-to-thousands of ms.
