# Browser smoke tests

Lightweight [Playwright](https://playwright.dev) tests for the static browser
client (`Sources/SameDesk/Client/client.html` + `client.js`). They load the
**real, unmodified** assets through a tiny static server and mock the WebSocket
layer, so no Mac/server is needed.

They guard against the regressions that are easy to miss when hand-editing the
client:

- the connection screen never clearing (stuck on "Connecting…"),
- the HUD breaking or its controls disappearing,
- the keyboard-lock / shortcut-passthrough control failing,
- and uncaught JS runtime errors on load.

## Run

```sh
cd Tests/browser
npm install
npm run setup        # one-time: download the Chromium browser
npm test             # runs the suite (starts the static server automatically)
```

`npm run test:headed` runs with a visible browser for debugging.

## How it works

- `server.mjs` — serves `client.html` at `/` and `client.js` at `/client.js`
  from `Sources/`. Started automatically by Playwright's `webServer`.
- `specs/helpers.js` — installs a deterministic `WebSocket` stub (opens
  immediately; lets tests `emit()`/`close()`) plus Fullscreen + Keyboard Lock
  stubs, all **before** `client.js` runs.
- `specs/smoke.spec.js` — the tests.

CI runs these on every push/PR (see `.github/workflows/ci.yml`).
