"use strict";
(() => {
  // Auth rides an HttpOnly session cookie set by the pairing redirect (server's
  // GET /). The browser attaches it to these same-origin WS handshakes
  // automatically, so no token travels in the page or socket URLs.
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  const wsURL = `${scheme}://${location.host}/ws`;
  const inputURL = `${scheme}://${location.host}/input`;

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
  // Throttled so a burst of errors doesn't spam keyframes.
  let lastKfReq = 0;
  function requestKeyframe() {
    const now = performance.now();
    if (now - lastKfReq < 500) return;
    lastKfReq = now;
    sendInput({ type: "keyframe" });
  }

  // ---- WebCodecs sink -----------------------------------------------------
  const WebCodecsSink = (() => {
    let decoder = null, configured = false, ts = 0, waitingKey = true, codecKind = "avc";

    function init() {
      // Reset state so init() is safe to call again on reconnect.
      configured = false; waitingKey = true; ts = 0; codecKind = "avc";
      try { if (decoder && decoder.state !== "closed") decoder.close(); } catch (_) {}
      decoder = new VideoDecoder({
        output: (frame) => {
          if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
            canvas.width = frame.displayWidth;
            canvas.height = frame.displayHeight;
            mediaSize = { w: frame.displayWidth, h: frame.displayHeight };
          }
          ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
          frame.close();
          Stats.onFrame();
        },
        error: (e) => { setStatus("Decoder error: " + e.message, true); waitingKey = true; requestKeyframe(); },
      });
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

    function pushSegment(buf) {
      const bytes = new Uint8Array(buf);
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
      if (waitingKey && !key) return;        // start on a keyframe
      waitingKey = false;
      try {
        decoder.decode(new EncodedVideoChunk({
          type: key ? "key" : "delta",
          timestamp: ts,
          data: sample,
        }));
        ts += 16666; // ~60fps in microseconds; only needs to be monotonic
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
    function pushSegment(buf) { queue.push(new Uint8Array(buf)); flush(); manageLatency(); }
    return { init, pushSegment, name: "MSE" };
  })();

  // ---- Stats / HUD --------------------------------------------------------
  const Stats = (() => {
    let frameCount = 0, byteCount = 0, lastTick = performance.now();
    let latency = 0, e2e = 0, e2ePeak = 0;
    const history = [];
    const samples = [];          // rolling per-second records (last 5 min)
    const MAX_SAMPLES = 300;
    const g = document.getElementById("graph").getContext("2d");

    function onSegment(bytes) { byteCount += bytes; }
    function onFrame() { frameCount++; }
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
      e2ePeak = 0;

      samples.push({ t: Date.now(), fps, mbps: kbps / 1000, rttMs: latency,
                     e2eMs: e2e, e2ePeakMs: peak });
      if (samples.length > MAX_SAMPLES) samples.shift();

      history.push(kbps); if (history.length > 110) history.shift();
      draw();
    }, 1000);

    function exportCSV() {
      const header = "timestamp,fps,mbps,rtt_ms,e2e_ms,e2e_peak_ms";
      const lines = samples.map((r) => [
        new Date(r.t).toISOString(),
        r.fps.toFixed(1), r.mbps.toFixed(3), r.rttMs.toFixed(0),
        r.e2eMs.toFixed(0), r.e2ePeakMs.toFixed(0),
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
    return { onSegment, onFrame, onLatency, currentLatency, onE2E, exportCSV };
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
    function push(arrayBuffer) {
      const c = ensureCtx();
      if (!c || c.state !== "running") return;   // not unlocked yet
      const dv = new DataView(arrayBuffer);
      const ch = dv.getUint8(1) || 2;
      const sr = dv.getUint32(4, false) || 48000;
      const pcm = new Float32Array(arrayBuffer.slice(8));   // interleaved
      const frames = Math.floor(pcm.length / ch);
      if (frames === 0) return;
      const buf = c.createBuffer(ch, frames, sr);
      for (let chan = 0; chan < ch; chan++) {
        const out = buf.getChannelData(chan);
        for (let f = 0; f < frames; f++) out[f] = pcm[f * ch + chan];
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
  let mediaWS, inputWS, mediaTimer = null, inputTimer = null;

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
      if (u8[0] === 1) { AudioOut.push(ev.data); return; }
      if (!CODEC_ID) return;                       // wait for the config frame
      // Video frame: [tag=0][captureTimeMs: Float64 BE][fMP4]
      const captureMs = new DataView(ev.data).getFloat64(1, false);
      if (haveOffset) Stats.onE2E(Date.now() - (captureMs - clockOffset));
      const payload = u8.subarray(9);            // strip tag + timestamp
      Stats.onSegment(payload.length);
      sink.pushSegment(payload);
    };
  }

  function connectInput() {
    clearTimeout(inputTimer);
    inputWS = new WebSocket(inputURL);
    inputWS.onopen = () => { if (autoQuality) sendInput({ type: "bitrate", mbps: targetMbps }); };
    inputWS.onclose = () => { inputTimer = setTimeout(connectInput, 1500); };
    inputWS.onmessage = (ev) => { if (typeof ev.data === "string") handleControl(JSON.parse(ev.data)); };
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
    else if (msg.type === "clipboard" && msg.text != null) navigator.clipboard?.writeText(msg.text).catch(() => {});
    else if (msg.type === "reload") {
      // Server is restarting (settings/port change). Reload to recover cleanly —
      // navigate to the new URL if the port changed, else just refresh. The
      // freshly loaded page auto-reconnects until the new server is up.
      setStatus("Server restarting — reconnecting…", false);
      setTimeout(() => { if (msg.text) location.href = msg.text; else location.reload(); }, 300);
    }
  }

  // ---- Connection quality auto-tune (RTT-driven) -------------------------
  let autoQuality = true;
  let targetMbps = 8;
  let goodCycles = 0;
  function updateQualityHUD() {
    document.getElementById("quality").textContent =
      autoQuality ? (targetMbps.toFixed(1) + " Mbps (auto)") : "manual";
  }
  setInterval(() => {
    if (!autoQuality) return;
    const rtt = Stats.currentLatency();
    let changed = false;
    if (rtt > 250) { targetMbps = Math.max(1, +(targetMbps * 0.6).toFixed(1)); goodCycles = 0; changed = true; }
    else if (rtt > 0 && rtt < 100) {
      goodCycles++;
      if (goodCycles >= 2) {
        const nv = Math.min(20, +(targetMbps * 1.25).toFixed(1));
        if (nv !== targetMbps) { targetMbps = nv; changed = true; }
        goodCycles = 0;
      }
    } else goodCycles = 0;
    if (changed) sendInput({ type: "bitrate", mbps: targetMbps });
    updateQualityHUD();
  }, 3000);

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

  // ---- Mouse / scroll / pinch --------------------------------------------
  // Listeners live on the stable #stage container so they keep working whether
  // the visible element is the canvas (WebCodecs) or the video (MSE).
  stage.addEventListener("mousemove", (e) => {
    if (locked()) {
      const d = displayedRect();
      sendInput({ type: "mousemove", rel: true, dx: e.movementX / d.w, dy: e.movementY / d.h,
             button: e.buttons ? 0 : undefined });
    } else {
      const p = norm(e); sendInput({ type: "mousemove", x: p.x, y: p.y, button: e.buttons ? 0 : undefined });
    }
  });
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

  const aqBtn = document.getElementById("autoquality");
  aqBtn.addEventListener("click", () => {
    autoQuality = !autoQuality;
    aqBtn.textContent = "Auto Quality: " + (autoQuality ? "On" : "Off");
    aqBtn.classList.toggle("active", autoQuality);
    if (autoQuality) sendInput({ type: "bitrate", mbps: targetMbps });
    updateQualityHUD();
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
    displayEl.focus();
    // Watchdog: if the media socket never opens, say so instead of sitting silent.
    setTimeout(() => {
      if (mediaWS && mediaWS.readyState === WebSocket.CONNECTING) {
        setStatus("Still connecting… check the server is running and mkcert is trusted.", true);
      }
    }, 6000);
  })();
})();
