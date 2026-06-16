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

test("auto-quality control toggles", async ({ page }) => {
  await page.goto("/");

  const aq = page.locator("#autoquality");
  await expect(aq).toHaveText("Auto Quality: On");
  await expect(aq).toHaveClass(/active/);

  await aq.click();
  await expect(aq).toHaveText("Auto Quality: Off");
  await expect(aq).not.toHaveClass(/active/);
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
