// Sound, joysticks and Econet in the page, end to end: what the BBC hears
// reaching the AudioWorklet, a gamepad read by BASIC's ADVAL, two stations
// in the page talking over their Econet, and (with an Internet Econet
// service: MACBEEB_ECONET_SERVICE=http://127.0.0.1:8787) two pages talking
// through a room.

import { expect, test, type Page } from "@playwright/test";

const service = process.env.MACBEEB_ECONET_SERVICE;

async function screenText(page: Page, station?: number): Promise<string> {
  return (await page.evaluate((s) => window.macbeeb.screenText(s), station)) ?? "";
}

async function waitForScreen(page: Page, pattern: RegExp, station?: number, timeout = 30_000) {
  await expect.poll(() => screenText(page, station), { timeout, intervals: [100, 250, 500] }).toMatch(pattern);
}

/** A Model B at BASIC's prompt, with Econet's ROM chosen too (and Econet on, if asked). */
async function boot(page: Page, options: { econet?: boolean; station?: number } = {}) {
  // It starts by itself, with MacBeeb's ROMs.
  await page.goto("/");
  await waitForScreen(page, /BASIC\s*\n>/);
  if (options.econet) {
    await page.locator("#econet-panel summary").click();
    if (options.station) {
      await page.fill("#station-number", String(options.station));
      await page.locator("#station-number").dispatchEvent("change");
    }
    // Econet power cycles it, with DNFS.
    await page.check("#econet-on");
    await expect.poll(() => page.evaluate(() => window.macbeeb.powered())).toBe(true);
    await waitForScreen(page, /BASIC\s*\n>/);
  }
}

/** Types through BeebCore's own typing (the Type text box). */
async function typeText(page: Page, text: string) {
  await page.fill("#type-text", text);
  await page.click("#type");
}

const receiver = `10 DIM B% 80,C% 20
20 C%?0=0:C%?1=&7F:C%?2=&77:C%?3=0:C%?4=0:C%!5=B%:C%!9=B%+80
30 X%=C%:Y%=C% DIV 256:A%=&11:CALL &FFF1
40 N%=C%?0:PRINT "OPEN ";N%
50 REPEAT:A%=&33:X%=N%:R%=USR(&FFF4):UNTIL (R% AND &8000)<>0
60 C%?0=N%:X%=C%:Y%=C% DIV 256:A%=&11:CALL &FFF1
70 PRINT "FROM ";C%?3;" GOT ";$B%
RUN`;
const sender = (to: number) => `10 DIM B% 80,C% 20
20 $B%="HELLO ECONET"
30 C%?0=&80:C%?1=&77:C%?2=${to}:C%?3=0:C%!4=B%:C%!8=B%+LEN$B%+1
40 X%=C%:Y%=C% DIV 256:A%=&10:CALL &FFF1
50 REPEAT:A%=&32:R%=USR(&FFF4):UNTIL (R% AND &8000)=0
60 PRINT "RESULT ";(R% AND &FF00) DIV 256;" ";C%?0
RUN`;

test("sound reaches the speakers", async ({ page }) => {
  await boot(page);
  await page.click("#sound");
  await expect(page.locator("#sound")).toHaveText("Sound on");
  await typeText(page, "SOUND 1,-15,100,100");
  // The worklet heard it (its loudest sample), and the worker sends a steady stream.
  await expect.poll(() => page.evaluate(() => window.macbeeb.audioPeak()), { timeout: 15_000 }).toBeGreaterThan(0.05);
  await expect.poll(() => page.evaluate(() => window.macbeeb.status()?.stats.audioPerSecond ?? 0), { timeout: 5000 })
    .toBeGreaterThan(30_000);
  await page.click("#sound");
  await expect(page.locator("#sound")).toHaveText("Sound off");
});

test("a gamepad is the BBC's joystick", async ({ page }) => {
  // A gamepad held right and half down, fire pressed.
  await page.addInitScript(() => {
    const button = (pressed: boolean) => ({ pressed, touched: pressed, value: pressed ? 1 : 0 });
    const pad = {
      id: "Test pad (STANDARD GAMEPAD)", index: 0, connected: true, mapping: "standard", timestamp: 0,
      axes: [1, 0.5, 0, 0], buttons: [button(true), ...Array.from({ length: 16 }, () => button(false))],
    };
    Object.defineProperty(navigator, "getGamepads", { value: () => [pad, null, null, null] });
  });
  await boot(page);
  await expect(page.locator("#gamepads")).toHaveText(/Joystick 0: Test pad/);
  await typeText(page, 'PRINT ADVAL(1);" ";ADVAL(2);" ";ADVAL(0) AND 3');
  // Right reads low on a BBC, down low; fire button 1.
  await waitForScreen(page, /\n\s*0 16320 1\s*\n>/);
});

test("two BBCs in the page talk over their Econet", async ({ page }) => {
  test.setTimeout(180_000);
  await boot(page, { econet: true, station: 1 });
  await page.click("#add-station");
  // The new BBC is station 2, and selected.
  await expect(page.locator("figure.station.selected figcaption")).toHaveText(/Station 2/);
  await expect.poll(() => page.evaluate(() => window.macbeeb.powered(2))).toBe(true);
  await waitForScreen(page, /BASIC\s*\n>/, 2);
  await typeText(page, receiver);
  await waitForScreen(page, /^OPEN \d+/m, 2, 60_000);
  // Station 1 sends to station 2.
  await page.locator("figure.station[data-station='1'] canvas").click();
  await expect(page.locator("figure.station.selected figcaption")).toHaveText(/Station 1/);
  await typeText(page, sender(2));
  await waitForScreen(page, /^RESULT 0 \d+/m, 1, 60_000);
  await waitForScreen(page, /^FROM 1 GOT HELLO ECONET/m, 2);
  await expect(page.locator("#network-stats")).toHaveText(/[1-9]\d* frames on the line/);
});

test("a file server comes with Acorn's Level 1 server in its drive", async ({ page }) => {
  test.setTimeout(120_000);
  await boot(page, { econet: true, station: 1 });
  await page.click("#add-fileserver");
  await expect(page.locator("figure.station.selected figcaption")).toHaveText(/Station 254 · File server.*Level 1 file server/);
  await waitForScreen(page, /BASIC\s*\n>/, 2);
  await typeText(page, '*CAT');
  await waitForScreen(page, /\bFS\b/, 2);
});

test("two browsers' BBCs talk through an Internet Econet room", async ({ browser }) => {
  test.skip(!service, "needs MACBEEB_ECONET_SERVICE");
  test.setTimeout(240_000);
  const host = await (await browser.newContext()).newPage();
  const guest = await (await browser.newContext()).newPage();
  await boot(host, { econet: true, station: 1 });
  await boot(guest, { econet: true, station: 2 });
  for (const page of [host, guest]) await page.fill("#room-service", service!);

  await host.fill("#room-display-name", "Host");
  await host.fill("#room-new-name", "Browser test");
  await host.click("#room-create");
  const code = (await host.locator(".room-status .invite").first().textContent({ timeout: 20_000 }))!.trim();
  await guest.fill("#room-display-name", "Guest");
  await guest.fill("#room-invite", code);
  await guest.click("#room-join");
  // Each sees the other's station.
  await expect(guest.locator("#room-status")).toContainText("Station 1", { timeout: 20_000 });
  await expect(host.locator("#room-status")).toContainText("Station 2", { timeout: 20_000 });

  await typeText(guest, receiver);
  await waitForScreen(guest, /^OPEN \d+/m, undefined, 60_000);
  await typeText(host, sender(2));
  await waitForScreen(host, /^RESULT 0 \d+/m, undefined, 90_000);
  await waitForScreen(guest, /^FROM 1 GOT HELLO ECONET/m, undefined, 30_000);
  await expect(host.locator("#network-stats")).toHaveText(/to the room [1-9]/);

  await host.click("#room-leave");
  await expect(host.locator("#room-status")).toBeHidden();
});
