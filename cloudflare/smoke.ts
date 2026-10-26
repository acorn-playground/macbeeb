// The local Cloudflare proof, end to end: starts `wrangler dev` (workerd,
// locally), and through the Worker and a Durable Object
//
//   1. creates a machine (our own parity ROM) and runs it in bounded bursts,
//      checking each checkpoint against the native build's
//      (Tests/BeebWasmTests/Fixtures/expected.json);
//   2. persists its state, evicts the object, and restores it into a new
//      instance;
//   3. stops workerd altogether, starts it again, and restores from storage;
//   4. with Acorn's ROMs (unless MACBEEB_SKIP_LICENSED=1), boots BASIC and
//      types PRINT 2+2.
//
// It prints timings and memory as it goes. Run: node smoke.ts (after
// scripts/build-wasm.sh and npm install).

import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

const here = import.meta.dirname;
const repository = path.resolve(here, "..");
const expected = JSON.parse(fs.readFileSync(path.join(repository, "Tests/BeebWasmTests/Fixtures/expected.json"), "utf8"));
const port = 8787 + Math.floor(Math.random() * 1000);
const base = `http://127.0.0.1:${port}/local/machines`;
const persist = fs.mkdtempSync(path.join(here, ".wrangler/smoke-"));
const machineId = `proof-${Date.now()}`;

let wrangler: ChildProcess | null = null;
const timings: Record<string, number> = {};

async function start(label: string) {
  const started = performance.now();
  wrangler = spawn("npx", ["wrangler", "dev", "--local", "--ip", "127.0.0.1", "--port", String(port), "--persist-to", persist],
    { cwd: here, env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" }, stdio: ["ignore", "pipe", "pipe"] });
  let log = "";
  wrangler.stdout!.on("data", (d) => (log += d));
  wrangler.stderr!.on("data", (d) => (log += d));
  for (let i = 0; i < 600; i++) {
    if (/Ready on/.test(log)) break;
    if (wrangler.exitCode != null) throw new Error(`wrangler exited:\n${log}`);
    await new Promise((r) => setTimeout(r, 100));
  }
  if (!/Ready on/.test(log)) throw new Error(`wrangler didn't start:\n${log}`);
  timings[`${label}: wrangler dev ready (ms)`] = Math.round(performance.now() - started);
}

async function stop() {
  if (!wrangler) return;
  const exited = new Promise((r) => wrangler!.once("exit", r));
  wrangler.kill("SIGINT");
  await exited;
  wrangler = null;
}

async function call(action: string, body?: unknown): Promise<any> {
  const started = performance.now();
  const response = await fetch(`${base}/${machineId}/${action}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const result = await response.json();
  (result as any).ms = Math.round((performance.now() - started) * 10) / 10;
  if ((result as any).error) throw new Error(`${action}: ${(result as any).error}`);
  return result;
}

function matches(result: any, checkpoint: string) {
  const e = expected[checkpoint];
  assert.deepEqual(
    { cycles: result.cycles, ...result.cpu, ram: result.ram },
    { cycles: e.cycles, pc: e.pc, a: e.a, x: e.x, y: e.y, s: e.s, p: e.p, ram: e.ram },
    `the Durable Object's machine vs the native build's ${checkpoint}`,
  );
  console.log(`  matches the native build's ${checkpoint}`);
}

try {
  await start("first start");

  console.log("1. create and run in bounded bursts");
  let r = await call("create", {});
  timings["create, first request: instantiate the module and power on (ms)"] = r.ms;
  r = await call("run", { cycles: 1_000_000 });
  matches(r, "synthetic/early");
  r = await call("run", { cycles: 3_000_000 });
  timings["run 3,000,000 cycles (ms)"] = r.ms;
  timings["throughput in workerd (MHz, from the request's time)"] = Math.round((3_000_000 / r.ms / 1000) * 10) / 10;
  timings["WebAssembly memory (bytes)"] = r.memoryBytes;
  matches(r, "synthetic/later");
  await call("run", { cycles: 50_000_000 }).then(
    () => assert.fail("an unbounded run was accepted"),
    (e) => console.log(`  a too-long run is refused: ${e.message}`),
  );

  console.log("2. persist, evict, restore into a new instance");
  r = await call("snapshot", {});
  timings["snapshot to storage (ms)"] = r.ms;
  timings["state (bytes)"] = r.bytes;
  await call("evict", {}).catch(() => {});
  r = await call("status");
  assert.equal(r.inMemory, false, "the evicted object came back with its machine in memory");
  console.log(`  evicted: a new instance, nothing in memory, ${r.stored.bytes} bytes stored`);
  r = await call("restore", {});
  timings["restore from storage (ms)"] = r.ms;
  assert.equal(r.cycles, 4_000_000);
  r = await call("run", { cycles: 2_000_000 });
  matches(r, "synthetic/afterRestore");

  console.log("3. stop workerd, start it again, restore from storage");
  await stop();
  await start("restart");
  r = await call("status");
  assert.equal(r.inMemory, false);
  r = await call("restore", {});
  timings["restore after a restart, first request (ms)"] = r.ms;
  r = await call("run", { cycles: 2_000_000 });
  matches(r, "synthetic/afterRestore");

  const roms = path.join(repository, "Sources/BeebROMs/ROMs");
  if (process.env.MACBEEB_SKIP_LICENSED !== "1" && fs.existsSync(path.join(roms, "os12.rom"))) {
    console.log("4. BBC BASIC (Acorn's ROMs, sent to the local runtime only)");
    const b64 = (name: string) => fs.readFileSync(path.join(roms, name)).toString("base64");
    await call("create", { model: 1, roms: { "-1": b64("os12.rom"), "15": b64("basic2.rom"), "14": b64("dfs12.rom") } });
    await call("run", { cycles: 4_000_000 });
    await call("type", { text: "PRINT 2+2\n" });
    for (let i = 0; i < 3; i++) await call("run", { cycles: 1_000_000 });
    r = await call("screen");
    console.log(r.text.split("\n").filter(Boolean).map((l: string) => `  | ${l}`).join("\n"));
    assert.match(r.text, /PRINT 2\+2\s*\n\s+4\s*\n>/);
  }

  console.log("\nMeasurements");
  for (const [k, v] of Object.entries(timings)) console.log(`  ${k}: ${v}`);
  console.log("\ncloudflare proof: the WebAssembly BeebCore runs, persists and restores in workerd");
} finally {
  await stop();
  fs.rmSync(persist, { recursive: true, force: true });
}
