// Installs deterministic browser-API stubs BEFORE client.js runs:
//
//  - A fake WebSocket that "opens" immediately (so the client reaches its
//    connected state without a real server), records instances on
//    window.__sdSockets, and lets a test emit() messages or close() the socket.
//  - Fullscreen + Keyboard Lock stubs so the "Shortcut Passthrough" control has
//    a deterministic success path in headless Chromium.
export async function addClientMocks(page) {
  await page.addInitScript(() => {
    class MockWebSocket {
      constructor(url) {
        this.url = url;
        this.binaryType = "blob";
        this.readyState = 0;
        this.onopen = null;
        this.onclose = null;
        this.onerror = null;
        this.onmessage = null;
        (window.__sdSockets = window.__sdSockets || []).push(this);
        // Open on the next tick — after client.js assigns its handlers.
        setTimeout(() => {
          this.readyState = 1;
          if (this.onopen) this.onopen({});
        }, 0);
      }

      send() {}

      close() {
        this.readyState = 3;
        if (this.onclose) this.onclose({ code: 1000 });
      }

      emit(data) {
        if (this.onmessage) this.onmessage({ data });
      }
    }
    MockWebSocket.CONNECTING = 0;
    MockWebSocket.OPEN = 1;
    MockWebSocket.CLOSING = 2;
    MockWebSocket.CLOSED = 3;
    window.WebSocket = MockWebSocket;

    Element.prototype.requestFullscreen = function () { return Promise.resolve(); };
    Document.prototype.exitFullscreen = function () { return Promise.resolve(); };
    Object.defineProperty(navigator, "keyboard", {
      configurable: true,
      value: { lock: () => Promise.resolve(), unlock: () => {} },
    });
  });
}
