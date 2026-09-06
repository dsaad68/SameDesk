"use strict";
(() => {
  // Auth rides an HttpOnly session cookie set by the pairing redirect (server's
  // GET /). The browser attaches it to these same-origin WS handshakes
  // automatically, so no token travels in the page or socket URLs.
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  const wsURL = `${scheme}://${location.host}/ws`;
  const inputURL = `${scheme}://${location.host}/input`;
  const audioURL = `${scheme}://${location.host}/audio`;

  // The codec is delivered at runtime by the server as the first text frame on
  // the media socket (a {type:"config",codec} message, always sent before any
  // binary segment). That keeps this page fully static. Set once on connect.
  let CODEC_ID = null;     // e.g. avc1.640028
  let CODEC_MIME = null;   // video/mp4; codecs="…"

  const stage = document.getElementById("stage");
  const video = document.getElementById("screen");
  const canvas = document.getElementById("canvas");
  const ctx = canvas.getContext("2d", { alpha: false, desynchronized: true });
  const statusEl = document.getElementById("status");

  let displayEl = canvas;          // element used for input geometry
  let mediaSize = { w: 16, h: 9 }; // intrinsic stream size

  function setStatus(msg, isError) {
    if (!msg) { statusEl.classList.add("hidden"); return; }
    statusEl.classList.remove("hidden");
    statusEl.textContent = msg;
    statusEl.classList.toggle("error", !!isError);
  }

  // ---- fMP4 box helpers (we control the muxer, so a tiny scanner suffices) -
  function readU32(b, o) { return ((b[o] << 24) | (b[o+1] << 16) | (b[o+2] << 8) | b[o+3]) >>> 0; }
  function indexOfFourCC(b, s, from) {
    const a = s.charCodeAt(0), c = s.charCodeAt(1), d = s.charCodeAt(2), e = s.charCodeAt(3);
    for (let i = from || 0; i + 4 <= b.length; i++) {
      if (b[i] === a && b[i+1] === c && b[i+2] === d && b[i+3] === e) return i;
    }
    return -1;
  }
  // Returns the payload of the named box (data after the 8-byte header).
  function boxPayload(b, fourcc) {
    const idx = indexOfFourCC(b, fourcc, 0);
    if (idx < 4) return null;
    const size = readU32(b, idx - 4);
    return b.subarray(idx + 4, idx - 4 + size);
  }
  function isInitSegment(b) {
    // Top-level first box is 'ftyp' for our init segment, 'moof' for fragments.
    return b.length >= 8 && b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70;
  }
  // Detect a keyframe by walking length-prefixed NAL units. H.264: nal_type =
  // byte & 0x1F, IDR = 5. HEVC: nal_type = (byte >> 1) & 0x3F, IRAP = 16..23.
  function containsKeyframe(d, kind) {
    let off = 0;
    while (off + 4 <= d.length) {
      const len = readU32(d, off); off += 4;
      if (off >= d.length) break;
      if (kind === "hevc") {
        const t = (d[off] >> 1) & 0x3F;
        if (t >= 16 && t <= 23) return true;
      } else {
        if ((d[off] & 0x1F) === 5) return true;
      }
      off += len;
    }
    return false;
  }

  // Ask the server for a fresh IDR (e.g. after a decode error / dropped frame).
  // Throttled hard: a keyframe is many times the size of a P-frame, and on a
  // struggling link asking for another one before the last has even arrived
  // is how a hiccup turns into a storm of blurry keyframes.
  let lastKfReq = 0;
  function requestKeyframe() {
    const now = performance.now();
    if (now - lastKfReq < 1500) return;
    lastKfReq = now;
    sendInput({ type: "keyframe" });
  }

  // ---- WebCodecs sink -----------------------------------------------------
  // Decoding every queued chunk in order is the wrong thing for a live stream:
  // after a network stall it plays the whole backlog back-to-back (a freeze
  // followed by a fast-forward) instead of showing the present. So we watch how
  // far behind we are and, when it matters, skip to the next keyframe.
  const MAX_DECODE_QUEUE = 3;     // chunks waiting on the decoder before we shed
  // Frame age past which the backlog is worthless. Generous on purpose: the
  // server already bounds staleness with a 10-frame queue and a capped kernel
  // buffer, and the frames right behind a keyframe are legitimately late by
  // however long the keyframe took to push. Skipping those and asking for yet
  // another keyframe would only make the next batch later still.
  const STALE_FRAME_MS = 600;

  const WebCodecsSink = (() => {
    let decoder = null, configured = false, ts = 0, waitingKey = true, codecKind = "avc";
    let tsBase = null;
    const submitTimes = new Map();   // chunk timestamp -> performance.now() at submit

    function init() {
      // Reset state so init() is safe to call again on reconnect.
      configured = false; waitingKey = true; ts = 0; codecKind = "avc";
      tsBase = null; submitTimes.clear();
      try { if (decoder && decoder.state !== "closed") decoder.close(); } catch (_) {}
      decoder = new VideoDecoder({
        output: (frame) => {
          if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
            canvas.width = frame.displayWidth;
            canvas.height = frame.displayHeight;
            mediaSize = { w: frame.displayWidth, h: frame.displayHeight };
          }
          ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
          const submitted = submitTimes.get(frame.timestamp);
          if (submitted !== undefined) {
            submitTimes.delete(frame.timestamp);
            Stats.onDecode(performance.now() - submitted);
          }
          frame.close();
          Stats.onFrame();
        },
        error: (e) => { setStatus("Decoder error: " + e.message, true); waitingKey = true; requestKeyframe(); },
      });
    }

    // Chunk timestamps must be monotonic; feeding the real capture time (rather
    // than a synthetic 60fps counter) is what lets us measure decode latency and
    // spot a decoder that is buffering frames internally.
    function nextTimestamp(captureMs) {
      let t;
      if (typeof captureMs === "number" && isFinite(captureMs)) {
        if (tsBase === null) tsBase = captureMs;
        t = Math.round((captureMs - tsBase) * 1000);
      } else {
        t = ts + 16666;
      }
      if (t <= ts) t = ts + 1;
      ts = t;
      return t;
    }

    function configure(record) {
      try {
        decoder.configure({
          codec: CODEC_ID,
          description: record,
          optimizeForLatency: true,
          hardwareAcceleration: "prefer-hardware",
        });
        configured = true;
      } catch (e) {
        setStatus("Decoder configure failed: " + e.message, true);
      }
    }

    function pushSegment(bytes, meta) {
      if (isInitSegment(bytes)) {
        // The init segment is self-describing: hvcC => HEVC, avcC => H.264.
        let rec = boxPayload(bytes, "hvcC");
        if (rec) codecKind = "hevc";
        else { rec = boxPayload(bytes, "avcC"); codecKind = "avc"; }
        if (rec) configure(rec.slice());   // copy out of the WS buffer
        return;
      }
      if (!configured) return;
      const sample = boxPayload(bytes, "mdat");
      if (!sample) return;
      const key = containsKeyframe(sample, codecKind);
      if (!key) {
        if (waitingKey) return;            // start (and restart) on a keyframe
        // Behind live: either the decoder is backing up or the frame we are
        // holding is already old. Both mean the queued deltas are worthless —
        // skip to the next keyframe instead of replaying the past at speed.
        const stale = meta && meta.ageMs !== null && meta.ageMs > STALE_FRAME_MS;
        if (decoder.decodeQueueSize > MAX_DECODE_QUEUE || stale) {
          waitingKey = true;
          Stats.onSkip();
          requestKeyframe();
          return;
        }
      }
      waitingKey = false;
      try {
        const timestamp = nextTimestamp(meta && meta.captureMs);
        submitTimes.set(timestamp, performance.now());
        // Bound the map: a frame the decoder never emits must not leak.
        if (submitTimes.size > 64) {
          submitTimes.delete(submitTimes.keys().next().value);
        }
        decoder.decode(new EncodedVideoChunk({
          type: key ? "key" : "delta",
          timestamp,
          data: sample,
        }));
      } catch (e) {
        // A decode error usually means we need a fresh keyframe.
        waitingKey = true;
        requestKeyframe();
      }
    }

    return { init, pushSegment, name: "WebCodecs" };
  })();

  // ---- MSE sink (fallback) ------------------------------------------------
  const MSESink = (() => {
    let mediaSource, sourceBuffer, queue = [], initialized = false;

    function init() {
      // Reset state so init() is safe to call again on reconnect.
      queue = []; initialized = false; sourceBuffer = null;
      video.classList.remove("hiddenEl");
      canvas.classList.add("hiddenEl");
      displayEl = video;
      mediaSource = new MediaSource();
      video.src = URL.createObjectURL(mediaSource);
      mediaSource.addEventListener("sourceopen", () => {
        try {
          sourceBuffer = mediaSource.addSourceBuffer(CODEC_MIME);
          sourceBuffer.mode = "segments";
          sourceBuffer.addEventListener("updateend", () => { flush(); });
          initialized = true;
          flush();
        } catch (e) { setStatus("MSE setup failed: " + e.message, true); }
      });
    }
    function flush() {
      if (!initialized || !sourceBuffer || sourceBuffer.updating || queue.length === 0) return;
      try { sourceBuffer.appendBuffer(queue.shift()); }
      catch (e) {
        if (e.name === "QuotaExceededError") {
          try { const end = Math.max(0, video.currentTime - 4); if (end > 0) sourceBuffer.remove(0, end); } catch (_) {}
        }
      }
    }
    function manageLatency() {
      if (video.buffered.length === 0) return;
      const live = video.buffered.end(video.buffered.length - 1);
      const lat = live - video.currentTime;
      // Track close to live: catch up early/aggressively, jump only on a big stall.
      if (lat > 2) { video.currentTime = live - 0.03; video.playbackRate = 1.0; }
      else if (lat > 0.18) video.playbackRate = 1.25;
      else if (lat < 0.08) video.playbackRate = 1.0;
      if (video.paused) video.play().catch(() => {});
      mediaSize = { w: video.videoWidth || 16, h: video.videoHeight || 9 };
    }
    function pushSegment(bytes) { queue.push(bytes); flush(); manageLatency(); }
    return { init, pushSegment, name: "MSE" };
  })();

  // ---- Stats / HUD --------------------------------------------------------
  const Stats = (() => {
    let frameCount = 0, byteCount = 0, lastTick = performance.now();
    let latency = 0, e2e = 0, e2ePeak = 0, decodeMs = 0, skipped = 0;
    const history = [];
    const samples = [];          // rolling per-second records (last 5 min)
    const MAX_SAMPLES = 300;
    const g = document.getElementById("graph").getContext("2d");

    function onSegment(bytes) { byteCount += bytes; }
    function onFrame() { frameCount++; }
    // Decoder submit -> output. More than one frame interval here means the
    // decoder is holding frames back (see the SPS reorder-window note in the
    // muxer), which is latency no amount of network tuning can recover.
    function onDecode(ms) { decodeMs = decodeMs ? decodeMs * 0.8 + ms * 0.2 : ms; }
    function onSkip() { skipped++; }
    function onLatency(ms) { latency = ms; }
    function currentLatency() { return latency; }
    // Glass-to-glass: server capture time -> client receive, clock-corrected.
    // Smoothed, and we surface the 1s peak (that's where the hiccup shows up).
    function onE2E(ms) { e2e = e2e ? e2e * 0.7 + ms * 0.3 : ms; if (ms > e2ePeak) e2ePeak = ms; }

    setInterval(() => {
      const now = performance.now();
      const dt = (now - lastTick) / 1000; lastTick = now;
      const fps = frameCount / dt;
      const kbps = (byteCount * 8 / 1000) / dt;
      frameCount = 0; byteCount = 0;
      document.getElementById("fps").textContent = fps.toFixed(0);
      document.getElementById("bitrate").textContent = (kbps / 1000).toFixed(2) + " Mbps";
      document.getElementById("latency").textContent = latency.toFixed(0) + " ms (RTT)";
      const peak = e2ePeak;
      document.getElementById("e2e").textContent =
        e2e ? `${e2e.toFixed(0)} ms (pk ${peak.toFixed(0)})` : "–";
      document.getElementById("decode").textContent =
        decodeMs ? `${decodeMs.toFixed(1)} ms` : "–";
      const skips = skipped;
      e2ePeak = 0; skipped = 0;

      samples.push({ t: Date.now(), fps, mbps: kbps / 1000, rttMs: latency,
                     e2eMs: e2e, e2ePeakMs: peak, decodeMs, skipped: skips });
      if (samples.length > MAX_SAMPLES) samples.shift();

      history.push(kbps); if (history.length > 110) history.shift();
      draw();
    }, 1000);

    function exportCSV() {
      const header = "timestamp,fps,mbps,rtt_ms,e2e_ms,e2e_peak_ms,decode_ms,skipped";
      const lines = samples.map((r) => [
        new Date(r.t).toISOString(),
        r.fps.toFixed(1), r.mbps.toFixed(3), r.rttMs.toFixed(0),
        r.e2eMs.toFixed(0), r.e2ePeakMs.toFixed(0),
        r.decodeMs.toFixed(1), r.skipped,
      ].join(","));
      return [header, ...lines].join("\n");
    }

    function draw() {
      const w = 220, h = 56; g.clearRect(0, 0, w, h);
      const max = Math.max(1, ...history);
      g.beginPath(); g.moveTo(0, h);
      history.forEach((v, i) => g.lineTo((i / 110) * w, h - (v / max) * (h - 4)));
      g.lineTo(history.length / 110 * w, h); g.closePath();
      g.fillStyle = "rgba(10,132,255,0.35)"; g.fill();
      g.strokeStyle = "rgba(10,132,255,0.9)"; g.lineWidth = 1.5; g.stroke();
    }
    return { onSegment, onFrame, onLatency, currentLatency, onE2E, onDecode, onSkip, exportCSV };
  })();

  document.getElementById("hudExport").addEventListener("click", () => {
    const csv = Stats.exportCSV();
    const blob = new Blob([csv], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `samedesk-stats-${new Date().toISOString().replace(/[:.]/g, "-")}.csv`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });

  // Server/client clock offset (serverClock - clientClock), estimated from
  // ping/pong, for the glass-to-glass readout.
  let clockOffset = 0, haveOffset = false;

  // ---- Video backend selection -------------------------------------------
  // Synchronous on purpose: awaiting VideoDecoder.isConfigSupported() can hang
  // on some browsers and would block the connection (stuck on "Connecting…").
  // Presence of VideoDecoder is enough; a bad codec surfaces as a decode error
  // (which then requests a keyframe / can be diagnosed).
  let sink = WebCodecsSink;
  function chooseSink() {
    if ("VideoDecoder" in window) {
      sink = WebCodecsSink;
      document.getElementById("decoder").textContent = "WebCodecs";
    } else {
      sink = MSESink;
      document.getElementById("decoder").textContent = "MSE";
    }
  }

  // ---- Audio playback (Web Audio) ----------------------------------------
  // Raw interleaved Float32 PCM arrives tagged; we schedule buffers back-to-back
  // on an AudioContext. Browsers block audio until a user gesture, so the
  // context is resumed on the first interaction (see unlock listeners below).
  const AudioOut = (() => {
    let ctx = null, nextTime = 0;
    function ensureCtx() {
      if (!ctx) {
        const AC = window.AudioContext || window.webkitAudioContext;
        if (!AC) return null;
        ctx = new AC();
      }
      if (ctx.state === "suspended") ctx.resume().catch(() => {});
      return ctx;
    }
    function unlock() { ensureCtx(); }
    // [format:1][channels:1][reserved:2][sampleRate:4 BE][interleaved PCM…]
    // format 1 = Int16 (what the server sends), 0 = Float32.
    function push(arrayBuffer) {
      const c = ensureCtx();
      if (!c || c.state !== "running") return;   // not unlocked yet
      if (arrayBuffer.byteLength <= 8) return;
      const dv = new DataView(arrayBuffer);
      const format = dv.getUint8(0);
      const ch = dv.getUint8(1) || 2;
      const sr = dv.getUint32(4, false) || 48000;
      const body = arrayBuffer.slice(8);
      const pcm = format === 1 ? new Int16Array(body) : new Float32Array(body);
      const scale = format === 1 ? 1 / 32767 : 1;
      const frames = Math.floor(pcm.length / ch);
      if (frames === 0) return;
      const buf = c.createBuffer(ch, frames, sr);
      for (let chan = 0; chan < ch; chan++) {
        const out = buf.getChannelData(chan);
        for (let f = 0; f < frames; f++) out[f] = pcm[f * ch + chan] * scale;
      }
      const node = c.createBufferSource();
      node.buffer = buf;
      node.connect(c.destination);
      const now = c.currentTime;
      // Keep a tiny lead; resync if we've drifted behind or too far ahead.
      if (nextTime < now + 0.02 || nextTime > now + 0.4) nextTime = now + 0.06;
      node.start(nextTime);
      nextTime += buf.duration;
    }
    return { push, unlock };
  })();
  ["mousedown", "keydown", "touchstart"].forEach((e) =>
    window.addEventListener(e, () => AudioOut.unlock(), { passive: true }));

  // ---- WebSockets: separate media + input connections --------------------
  // Video/audio ride /ws; input/clipboard/ping/control ride /input. Splitting
  // them means input never queues behind video frames (TCP is one ordered
  // stream), so clicks/keys stay responsive even when video saturates the link.
  let mediaWS, inputWS, audioWS, mediaTimer = null, inputTimer = null, audioTimer = null;

  // The server's first frame on the media socket is a JSON {type:"config",codec}
  // that names the video codec; it always precedes any binary segment. We set
  // the codec from it and only then init the sink (MSE needs CODEC_MIME up front
  // for addSourceBuffer). This is what makes the page itself static.
  function handleMediaText(text) {
    let msg;
    try { msg = JSON.parse(text); } catch (_) { return; }
    if (msg.type === "config" && msg.codec) {
      CODEC_ID = msg.codec;
      CODEC_MIME = `video/mp4; codecs="${CODEC_ID}"`;
      sink.init();
    }
  }

  function connectMedia() {
    clearTimeout(mediaTimer);
    mediaWS = new WebSocket(wsURL);
    mediaWS.binaryType = "arraybuffer";
    mediaWS.onopen = () => { setStatus(null); };   // sink.init() waits for the config frame
    mediaWS.onclose = () => { setStatus("Reconnecting…", true); mediaTimer = setTimeout(connectMedia, 1500); };
    mediaWS.onerror = () => setStatus("Connection error. Did you run `mkcert -install` on this device?", true);
    mediaWS.onmessage = (ev) => {
      if (typeof ev.data === "string") { handleMediaText(ev.data); return; }
      const u8 = new Uint8Array(ev.data);
      if (u8[0] !== 0) return;                     // video only on this socket
      if (!CODEC_ID) return;                       // wait for the config frame
      // Video frame: [tag=0][captureTimeMs: Float64 BE][fMP4]. captureTimeMs is
      // stamped at CAPTURE (from the ScreenCaptureKit PTS), so the age below is
      // true glass-to-glass and can be trusted to decide we are behind live.
      const captureMs = new DataView(ev.data).getFloat64(1, false);
      let ageMs = null;
      if (haveOffset) {
        ageMs = Date.now() - (captureMs - clockOffset);
        Stats.onE2E(ageMs);
      }
      const payload = u8.subarray(9);            // strip tag + timestamp
      Stats.onSegment(payload.length);
      sink.pushSegment(payload, { captureMs, ageMs });
    };
  }

  // Tell the server how big we are drawing the stream, so it can capture at a
  // size that matches instead of encoding pixels the browser will throw away.
  // Debounced: a window drag should not reconfigure the capture stream.
  let viewportTimer = null;
  function sendViewport() {
    const dpr = window.devicePixelRatio || 1;
    sendInput({ type: "viewport",
                w: Math.round(window.innerWidth * dpr),
                h: Math.round(window.innerHeight * dpr) });
  }
  window.addEventListener("resize", () => {
    clearTimeout(viewportTimer);
    viewportTimer = setTimeout(sendViewport, 800);
  });

  function connectInput() {
    clearTimeout(inputTimer);
    inputWS = new WebSocket(inputURL);
    inputWS.onopen = () => sendViewport();
    inputWS.onclose = () => { inputTimer = setTimeout(connectInput, 1500); };
    inputWS.onmessage = (ev) => { if (typeof ev.data === "string") handleControl(JSON.parse(ev.data)); };
  }

  // Audio has its own socket so a keyframe never delays a sample, and a
  // congested video queue never sheds audio buffers as clicks.
  function connectAudio() {
    clearTimeout(audioTimer);
    audioWS = new WebSocket(audioURL);
    audioWS.binaryType = "arraybuffer";
    audioWS.onclose = () => { audioTimer = setTimeout(connectAudio, 1500); };
    audioWS.onmessage = (ev) => { if (typeof ev.data !== "string") AudioOut.push(ev.data); };
  }

  function sendInput(obj) {
    if (inputWS && inputWS.readyState === WebSocket.OPEN) inputWS.send(JSON.stringify(obj));
  }

  // Single global latency probe on the input socket (true input RTT).
  setInterval(() => sendInput({ type: "ping", t: Date.now() }), 1000);
  function handleControl(msg) {
    if (msg.type === "pong" && msg.t) {
      const rtt = Date.now() - msg.t;
      Stats.onLatency(rtt);
      // NTP-style: server reply time corresponds to client time (t0 + rtt/2).
      if (typeof msg.s === "number") {
        const off = msg.s - (msg.t + rtt / 2);
        clockOffset = haveOffset ? clockOffset * 0.8 + off * 0.2 : off;
        haveOffset = true;
      }
    }
    else if (msg.type === "quality" && typeof msg.mbps === "number") {
      targetMbps = msg.mbps;
      updateQualityHUD();
    }
    else if (msg.type === "cursor") Cursor.onMessage(msg);
    else if (msg.type === "clipboard" && msg.text != null) navigator.clipboard?.writeText(msg.text).catch(() => {});
    else if (msg.type === "reload") {
      // Server is restarting (settings/port change). Reload to recover cleanly —
      // navigate to the new URL if the port changed, else just refresh. The
      // freshly loaded page auto-reconnects until the new server is up.
      setStatus("Server restarting — reconnecting…", false);
      setTimeout(() => { if (msg.text) location.href = msg.text; else location.reload(); }, 300);
    }
  }

  // ---- Connection quality ------------------------------------------------
  // Bitrate is decided on the server, from how long each frame waits to reach
  // the socket. That signal only exists there, and it moves well before RTT
  // does — a client-side RTT loop was both blind and fighting the user's own
  // Bitrate setting. Here we just display what the server reports.
  let targetMbps = null;
  function updateQualityHUD() {
    document.getElementById("quality").textContent =
      targetMbps === null ? "–" : targetMbps.toFixed(1) + " Mbps";
  }

  // ---- Input geometry -----------------------------------------------------
  function displayedRect() {
    const r = displayEl.getBoundingClientRect();
    const vAspect = mediaSize.w / mediaSize.h;
    const rAspect = r.width / r.height;
    let dispW = r.width, dispH = r.height, offX = 0, offY = 0;
    if (rAspect > vAspect) { dispW = r.height * vAspect; offX = (r.width - dispW) / 2; }
    else { dispH = r.width / vAspect; offY = (r.height - dispH) / 2; }
    return { left: r.left + offX, top: r.top + offY, w: dispW, h: dispH };
  }
  function norm(ev) {
    const d = displayedRect();
    return {
      x: Math.max(0, Math.min(1, (ev.clientX - d.left) / d.w)),
      y: Math.max(0, Math.min(1, (ev.clientY - d.top) / d.h)),
    };
  }

  function locked() { return document.pointerLockElement === displayEl; }

  // ---- Client-rendered cursor --------------------------------------------
  // The stream is captured without a cursor; the server sends position and shape
  // on the input socket instead. While the pointer is over the stage and free,
  // we draw at the LOCAL mouse position — the pointer then moves at the speed of
  // the mouse rather than the speed of the network, which is most of what makes
  // a remote desktop feel remote. Server position takes over under pointer lock
  // and whenever the mouse is elsewhere, so app-driven cursor moves still show.
  const Cursor = (() => {
    const el = document.getElementById("cursor");
    let geom = null;          // hotspot + size, as fractions of the remote display
    let serverPos = null;     // fractions of the remote display
    let localPos = null;      // client px
    let haveShape = false;

    function onMessage(msg) {
      if (msg.fallback) {
        // The server is not compositing a cursor and could not read the system
        // one either. Show the browser's own pointer instead of nothing.
        el.classList.add("hiddenEl");
        document.body.classList.add("nativeCursor");
        return;
      }
      document.body.classList.remove("nativeCursor");
      if (typeof msg.png === "string") {
        el.src = "data:image/png;base64," + msg.png;
        haveShape = true;
        el.classList.remove("hiddenEl");
      }
      geom = { hx: msg.hx, hy: msg.hy, w: msg.w, h: msg.h };
      serverPos = { x: msg.x, y: msg.y };
      render();
    }
    function onLocalMove(ev) { localPos = { x: ev.clientX, y: ev.clientY }; render(); }
    function onLeave() { localPos = null; render(); }
    function render() {
      if (!geom || !haveShape) return;
      const d = displayedRect();
      let px, py;
      if (localPos && !locked()) { px = localPos.x; py = localPos.y; }
      else if (serverPos) { px = d.left + serverPos.x * d.w; py = d.top + serverPos.y * d.h; }
      else return;
      el.style.width = (geom.w * d.w) + "px";
      el.style.height = (geom.h * d.h) + "px";
      el.style.transform =
        `translate(${px - geom.hx * d.w}px, ${py - geom.hy * d.h}px)`;
    }
    return { onMessage, onLocalMove, onLeave, render };
  })();
  window.addEventListener("resize", () => Cursor.render());

  // ---- Mouse / scroll / pinch --------------------------------------------
  // Listeners live on the stable #stage container so they keep working whether
  // the visible element is the canvas (WebCodecs) or the video (MSE).
  // Chromium aligns pointermove/mousemove to the render frame, which costs half
  // a frame of input latency on average; pointerrawupdate fires as events
  // arrive. Both are registered and the raw one wins when it is live, so an
  // engine that never fires it (Safari) still moves the mouse.
  let lastRawUpdate = 0;
  // Raw updates arrive at the mouse's report rate — up to 1000 Hz — and each one
  // was a WebSocket message (its own TLS record and TCP segment) and a CGEvent on
  // the Mac. Under pointer lock the mouse never stops generating them. Wi-Fi is
  // half-duplex: a thousand tiny upstream packets a second steal airtime from
  // the video coming the other way, and the bitrate controller then sees the
  // video queue back up and cuts. Coalesce to 125 Hz — a USB mouse's native
  // rate, and what Moonlight batches relative motion to. Relative to Chrome's
  // old render-aligned mousemove this still trims ~4 ms of input latency on
  // average, without the flood.
  const MOVE_INTERVAL_MS = 8;
  let pendingMove = null, moveTimer = null, lastMoveSent = 0;
  function flushMove() {
    moveTimer = null;
    if (!pendingMove) return;
    lastMoveSent = performance.now();
    sendInput(pendingMove);
    pendingMove = null;
  }
  function queueMove(msg) {
    if (msg.rel && pendingMove && pendingMove.rel) {
      // Relative deltas must accumulate; absolute positions just replace.
      msg.dx += pendingMove.dx; msg.dy += pendingMove.dy;
    }
    pendingMove = msg;
    const since = performance.now() - lastMoveSent;
    if (since >= MOVE_INTERVAL_MS) flushMove();
    else if (!moveTimer) moveTimer = setTimeout(flushMove, MOVE_INTERVAL_MS - since);
  }
  function onPointerMove(e) {
    if (e.type === "pointerrawupdate") lastRawUpdate = performance.now();
    else if (performance.now() - lastRawUpdate < 500) return;
    Cursor.onLocalMove(e);
    if (locked()) {
      const d = displayedRect();
      queueMove({ type: "mousemove", rel: true, dx: e.movementX / d.w, dy: e.movementY / d.h,
                  button: e.buttons ? 0 : undefined });
    } else {
      const p = norm(e);
      queueMove({ type: "mousemove", x: p.x, y: p.y, button: e.buttons ? 0 : undefined });
    }
  }
  stage.addEventListener("pointerrawupdate", onPointerMove);
  stage.addEventListener("mousemove", onPointerMove);
  stage.addEventListener("mouseleave", () => Cursor.onLeave());
  stage.addEventListener("mousedown", (e) => {
    e.preventDefault(); displayEl.focus();
    if (locked()) sendInput({ type: "mousedown", rel: true, button: e.button });
    else { const p = norm(e); sendInput({ type: "mousedown", x: p.x, y: p.y, button: e.button }); }
  });
  stage.addEventListener("mouseup", (e) => {
    e.preventDefault();
    if (locked()) sendInput({ type: "mouseup", rel: true, button: e.button });
    else { const p = norm(e); sendInput({ type: "mouseup", x: p.x, y: p.y, button: e.button }); }
  });
  stage.addEventListener("contextmenu", (e) => e.preventDefault());
  stage.addEventListener("wheel", (e) => {
    e.preventDefault();
    // Normalize line/page deltas to pixels so scrolling feels smooth/native.
    const factor = e.deltaMode === 1 ? 16 : (e.deltaMode === 2 ? window.innerHeight : 1);
    sendInput({ type: "wheel", deltaX: e.deltaX * factor, deltaY: e.deltaY * factor, ctrl: e.ctrlKey });
  }, { passive: false });

  // ---- Keyboard -----------------------------------------------------------
  function modifiers(e) { return { meta: e.metaKey, shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey }; }
  function isPrintable(e) { return e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey; }
  window.addEventListener("keydown", (e) => {
    e.preventDefault();
    if (isPrintable(e)) sendInput({ type: "text", text: e.key });
    else sendInput(Object.assign({ type: "keydown", code: e.code }, modifiers(e)));
  });
  window.addEventListener("keyup", (e) => {
    e.preventDefault();
    if (!isPrintable(e)) sendInput(Object.assign({ type: "keyup", code: e.code }, modifiers(e)));
  });

  // ---- Clipboard ----------------------------------------------------------
  document.addEventListener("copy", async () => {
    try { const t = await navigator.clipboard.readText(); if (t) sendInput({ type: "clipboard", text: t }); } catch (_) {}
  });
  let lastClip = "";
  setInterval(async () => {
    if (!document.hasFocus()) return;
    try { const t = await navigator.clipboard.readText(); if (t && t !== lastClip) { lastClip = t; sendInput({ type: "clipboard", text: t }); } } catch (_) {}
  }, 1000);

  // ---- Controls -----------------------------------------------------------
  const plBtn = document.getElementById("pointerlock");
  plBtn.addEventListener("click", () => {
    if (locked()) document.exitPointerLock();
    else displayEl.requestPointerLock();
  });
  document.addEventListener("pointerlockchange", () => {
    const on = locked();
    plBtn.textContent = "Pointer Lock: " + (on ? "On" : "Off");
    plBtn.classList.toggle("active", on);
  });

  const passBtn = document.getElementById("passthrough");
  let passthrough = false;
  passBtn.addEventListener("click", async () => {
    passthrough = !passthrough;
    if (passthrough) {
      try {
        await document.documentElement.requestFullscreen();
        if (navigator.keyboard && navigator.keyboard.lock) await navigator.keyboard.lock();
        passBtn.textContent = "Shortcut Passthrough: On"; passBtn.classList.add("active");
      } catch (e) {
        passthrough = false; setStatus("Keyboard lock unavailable: " + e.message, true);
        setTimeout(() => setStatus(null), 2500);
      }
    } else {
      if (navigator.keyboard && navigator.keyboard.unlock) navigator.keyboard.unlock();
      if (document.fullscreenElement) document.exitFullscreen();
      passBtn.textContent = "Shortcut Passthrough: Off"; passBtn.classList.remove("active");
    }
  });

  const hud = document.getElementById("hud");
  const hudReopen = document.getElementById("hudReopen");
  const hudToggleBtn = document.getElementById("hudToggle");
  function showHUD() {
    hud.classList.remove("hidden");
    hudReopen.classList.add("hiddenEl");
    hudToggleBtn.textContent = "Hide HUD";
  }
  function hideHUD() {
    hud.classList.add("hidden");
    hudReopen.classList.remove("hiddenEl");   // reveal the reopen pill
    hudToggleBtn.textContent = "Show HUD";
  }
  document.getElementById("hudClose").addEventListener("click", hideHUD);
  hudReopen.addEventListener("click", showHUD);
  hudToggleBtn.addEventListener("click", () => {
    hud.classList.contains("hidden") ? showHUD() : hideHUD();
  });

  // Surface any otherwise-silent failure in the status bar (so we never sit on
  // "Connecting…" with no clue why).
  window.addEventListener("error", (e) => setStatus("Script error: " + e.message, true));
  window.addEventListener("unhandledrejection", (e) =>
    setStatus("Error: " + (e.reason && e.reason.message ? e.reason.message : e.reason), true));

  // ---- Go -----------------------------------------------------------------
  (() => {
    // The page only loads when the session cookie is valid (server returns 401
    // otherwise), so by here we're already paired — just connect.
    chooseSink();
    if (sink === MSESink && !("MediaSource" in window)) { setStatus("This browser supports neither WebCodecs nor MSE.", true); return; }
    updateQualityHUD();
    connectMedia();
    connectInput();
    connectAudio();
    displayEl.focus();
    // Watchdog: if the media socket never opens, say so instead of sitting silent.
    setTimeout(() => {
      if (mediaWS && mediaWS.readyState === WebSocket.CONNECTING) {
        setStatus("Still connecting… check the server is running and mkcert is trusted.", true);
      }
    }, 6000);
  })();
})();
