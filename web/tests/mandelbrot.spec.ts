// The Distributed Mandelbrot page end to end: the Level 2 server starts,
// the Guide logs on, *CLUSTER starts the eight workers by remote control,
// and *MANDEL has them draw the set between them.

import { expect, test } from "@playwright/test";

test("eight BBCs draw the Mandelbrot set between them over Econet", async ({ page }) => {
  test.setTimeout(420_000);
  await page.goto("/mandelbrot.html");
  const screen = (station: number) => page.evaluate((s) => window.mandelbrot.screenText(s), station);

  await expect(page.locator("#state")).toHaveText(/Ready: \*CLUSTER/, { timeout: 120_000 });
  expect(await screen(254)).toMatch(/Ready/);
  expect(await screen(1)).toMatch(/DISTRIBUTED MANDELBROT/);

  await page.click("#cluster");
  await expect(page.locator("#state")).toHaveText(/Workers started/, { timeout: 120_000 });
  expect((await screen(1)).replace(/\n/g, "")).toContain("8 workers started. 0 failed.");

  await page.click("#mandel");
  await expect.poll(async () => {
    const done = await Promise.all([2, 3, 4, 5, 6, 7, 8, 9].map(async (s) => (await screen(s)).includes("run complete")));
    return done.every(Boolean);
  }, { timeout: 240_000, intervals: [2000] }).toBe(true);
  await expect(page.locator("#network-stats")).toHaveText(/10 BBCs at \d+% of real time · [\d,]+ frames on the Econet/);

  // A key on the Guide ends it, with its count.
  await page.locator("figure.guide canvas").click();
  await page.keyboard.press("Space");
  await expect.poll(() => screen(1), { timeout: 30_000 }).toMatch(/320 of 320 tiles/);
});
