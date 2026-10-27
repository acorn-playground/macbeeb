import { chromium, webkit } from "playwright";
for (const [name, type] of [["chromium", chromium], ["webkit", webkit]]) {
  const browser = await type.launch();
  const page = await browser.newPage();
  await page.goto("http://localhost:8095/");
  await page.waitForFunction(() => (globalThis).bench);
  const r = await page.evaluate(() => (globalThis).bench());
  console.log(name, Object.entries(r).map(([k, v]) => `${k} ${v.toFixed(1)}x real time`).join(", "));
  await browser.close();
}
