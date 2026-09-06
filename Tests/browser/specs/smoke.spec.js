import { expect, test } from "@playwright/test";
import { addClientMocks } from "./helpers.js";

test.beforeEach(async ({ page }) => {
  await addClientMocks(page);
});

test("loads and reaches the connected state with no JS errors", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e));

  await page.goto("/");

  // The mock media socket opens immediately, so the client calls setStatus(null)
  // and the "Connecting…" overlay is hidden — i.e. it reached the live state.
  await expect(page.locator("#status")).toHaveClass(/hidden/);
  // A decoder backend was selected (WebCodecs preferred, MSE fallback).
  await expect(page.locator("#decoder")).toHaveText(/WebCodecs|MSE/);

  expect(errors.map(String).join("\n")).toBe("");
});

test("HUD shows the stat rows and can be hidden and reopened", async ({ page }) => {
  await page.goto("/");

  const hud = page.locator("#hud");
  await expect(hud).toBeVisible();
  await expect(page.locator("#fps")).toBeVisible();
  await expect(page.locator("#bitrate")).toBeVisible();
  await expect(page.locator("#latency")).toBeVisible();

  await page.locator("#hudToggle").click();
  await expect(hud).toHaveClass(/hidden/);
  await expect(page.locator("#hudReopen")).not.toHaveClass(/hiddenEl/);

  await page.locator("#hudReopen").click();
  await expect(hud).not.toHaveClass(/hidden/);
});

test("HUD reports the bitrate the server settled on", async ({ page }) => {
  await page.goto("/");

  // Quality is server-owned now: until the server says otherwise there is
  // nothing to report.
  await expect(page.locator("#quality")).toHaveText("–");

  // __sdSockets[1] is the /input socket (the media socket connects first).
  await page.evaluate(() =>
    window.__sdSockets[1].emit(JSON.stringify({ type: "quality", mbps: 6.5 })));

  await expect(page.locator("#quality")).toHaveText("6.5 Mbps");
});

test("draws the client-rendered cursor from a server update", async ({ page }) => {
  await page.goto("/");

  // Nothing to draw until the server sends a shape; the stream may still be
  // compositing its own cursor.
  const cursor = page.locator("#cursor");
  await expect(cursor).toHaveClass(/hiddenEl/);

  const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
  await page.evaluate((data) =>
    window.__sdSockets[1].emit(JSON.stringify({
      type: "cursor", x: 0.5, y: 0.5, hx: 0, hy: 0, w: 0.02, h: 0.02, png: data,
    })), png);

  await expect(cursor).not.toHaveClass(/hiddenEl/);
  // Sized and positioned relative to the displayed video area.
  await expect
    .poll(() => cursor.evaluate((el) => el.style.width))
    .not.toBe("");
  await expect
    .poll(() => cursor.evaluate((el) => el.style.transform))
    .toContain("translate");
});

test("falls back to the native pointer when the server has no cursor shape", async ({ page }) => {
  await page.goto("/");

  await page.evaluate(() =>
    window.__sdSockets[1].emit(JSON.stringify({
      type: "cursor", x: 0.25, y: 0.25, fallback: true,
    })));

  // The stream carries no cursor in this mode, so showing none at all would be
  // worse than showing a generic arrow.
  await expect(page.locator("body")).toHaveClass(/nativeCursor/);
  await expect(page.locator("#cursor")).toHaveClass(/hiddenEl/);
});

test("shortcut-passthrough (keyboard lock) engages", async ({ page }) => {
  await page.goto("/");

  const pass = page.locator("#passthrough");
  await expect(pass).toHaveText("Shortcut Passthrough: Off");

  await pass.click();
  await expect(pass).toHaveText("Shortcut Passthrough: On");
  await expect(pass).toHaveClass(/active/);
});

test("surfaces a reconnecting status when the socket drops", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#status")).toHaveClass(/hidden/);   // connected first

  // Drop the media socket; the client should surface a reconnecting status.
  await page.evaluate(() => window.__sdSockets[0].close());

  const status = page.locator("#status");
  await expect(status).not.toHaveClass(/hidden/);
  await expect(status).toContainText(/reconnect/i);
});
