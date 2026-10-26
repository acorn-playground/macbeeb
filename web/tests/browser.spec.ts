// The demo end to end in a real browser: ROMs chosen, BASIC booted, typing
// on the keyboard, a disc run, pause, reset and power cycles. Screen text
// comes from the machine (BeebCore's screenText, via window.macbeeb); the
// canvas is checked to be showing frames.

import { expect, test, type Page } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const rom = (name: string) => path.join(repository, "Sources/BeebROMs/ROMs", name);
const fixture = (name: string) => path.join(repository, "Tests/BeebWasmTests/Fixtures", name);

async function screenText(page: Page): Promise<string> {
  return (await page.evaluate(() => window.macbeeb.screenText())) ?? "";
}

async function waitForScreen(page: Page, pattern: RegExp, timeout = 20_000) {
  await expect.poll(() => screenText(page), { timeout, intervals: [100, 250, 500] }).toMatch(pattern);
}

async function bootModelB(page: Page) {
  // It starts by itself, with MacBeeb's ROMs.
  await page.goto("/");
  await waitForScreen(page, /BASIC\s*\n>/);
}

/** Whether the canvas has something other than black on it. */
async function canvasHasPicture(page: Page): Promise<boolean> {
  const shot = await page.locator("#screen").screenshot();
  // A PNG of a black canvas is tiny; one with text on it isn't.
  return shot.length > 8000;
}

test("a viewer's own ROM replaces MacBeeb's", async ({ page }) => {
  await bootModelB(page);
  await page.locator("#roms summary").click();
  await page.setInputFiles("#rom-15", rom("basic2.rom"));
  await expect(page.locator("#rom-slots")).toContainText("BASIC II");
  await page.click("#power");
  await waitForScreen(page, /BASIC\s*\n>/);
});

test("boots to BASIC and answers PRINT 2+2", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await bootModelB(page);
  expect(await canvasHasPicture(page)).toBe(true);

  // Typed on the keyboard, by the host layout: "+" is Shift-= here.
  await page.locator("#screen").click();
  await page.keyboard.type("PRINT 2+2");
  await page.keyboard.press("Enter");
  await waitForScreen(page, /PRINT 2\+2\s*\n\s+4\s*\n>/);

  // Running at the BBC's speed.
  await expect.poll(async () => (await page.evaluate(() => window.macbeeb.status()))?.stats.speed ?? 0, { timeout: 5000 })
    .toBeGreaterThan(0.9);
  expect(errors).toEqual([]);
});

test("pause holds the machine, resume and Break carry on", async ({ page }) => {
  await bootModelB(page);
  await page.click("#pause");
  await expect(page.locator("#pause")).toHaveText("Resume");
  await expect.poll(async () => (await page.evaluate(() => window.macbeeb.status()))?.paused).toBe(true);
  const cycles = async () => (await page.evaluate(() => window.macbeeb.status()))?.stations[0]?.cycles ?? 0;
  const held = await cycles();
  await page.waitForTimeout(700);
  expect(await cycles()).toBe(held);
  await page.click("#pause");
  await expect.poll(cycles, { timeout: 5000 }).toBeGreaterThan(held);

  // A key held when the screen loses focus is released: one A, not a
  // row of them auto-repeating.
  await page.locator("#screen").click();
  await page.keyboard.down("KeyA");
  await page.locator("#type-text").click();
  await page.keyboard.up("KeyA");
  await page.waitForTimeout(1500);
  expect(await screenText(page)).toMatch(/\n>A\s*$/);
  await page.locator("#screen").click();
  await page.keyboard.press("Backspace");
  await page.keyboard.type("PRINT 1");
  await page.keyboard.press("Enter");
  await waitForScreen(page, /\n>PRINT 1\s*\n\s+1\s*\n>/);

  await page.click("#break");
  await waitForScreen(page, /BBC Computer[^\n]*\n[\s\S]*BASIC\s*\n>\s*$/);
});

test("a disc boots and runs, writes, and can be saved back", async ({ page }) => {
  await bootModelB(page);
  await page.setInputFiles("#disc-file", fixture("parity.ssd"));
  await expect(page.locator("#disc-name")).toHaveText(/parity\.ssd/);
  await page.click("#disc-boot");
  await waitForScreen(page, /HELLO FROM DISC\s*\nSUM 5050\s*\nSAVED/, 30_000);
  const download = page.waitForEvent("download");
  await page.click("#disc-export");
  const saved = await (await download).path();
  const image = fs.readFileSync(saved);
  // The catalogue has the file HELLO wrote.
  expect(image.subarray(8, 0x100).toString("latin1")).toContain("OUT");
});

test("power cycles and model changes start a new machine", async ({ page }) => {
  await bootModelB(page);
  await page.locator("#screen").click();
  await page.keyboard.type("A=6*7");
  await page.keyboard.press("Enter");
  await page.click("#power");
  await waitForScreen(page, /BBC Computer 32K/);
  await page.locator("#screen").click();
  await page.keyboard.type("PRINT A");
  await page.keyboard.press("Enter");
  // A power cycle clears the variable A (it was 42).
  await waitForScreen(page, /PRINT A\s*\n\s+0\s*\n>|No such variable/);

  await page.selectOption("#model", "master128");
  await page.click("#power");
  await waitForScreen(page, /Acorn MOS[\s\S]*BASIC\s*\n>/);
});
