// WebAssembly is 32-bit: Swift's Int is 32 bits there, so a count of
// microseconds or 2MHz cycles kept in an Int would trap after 18-36
// minutes of BBC time. This runs a Model B for 37 minutes of BBC time
// (about 3 minutes here) and then uses the disc and BASIC. Opt in with
// MACBEEB_SOAK=1; it needs MacBeeb's ROMs.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { DiscFormat, Model, OS_SLOT } from "../src/beeb-wasm.ts";
import { loadModule, repository } from "./module.ts";

const roms = path.join(repository, "Sources/BeebROMs/ROMs");

test("37 minutes of BBC time, past every 32-bit overflow", { skip: process.env.MACBEEB_SOAK !== "1" }, async () => {
  const module = await loadModule();
  const m = module.createMachine(Model.modelB);
  m.loadROM(OS_SLOT, fs.readFileSync(path.join(roms, "os12.rom")));
  m.loadROM(15, fs.readFileSync(path.join(roms, "basic2.rom")));
  m.loadROM(14, fs.readFileSync(path.join(roms, "dfs12.rom")));
  m.powerOn();
  m.insertDisc(0, DiscFormat.ssd, fs.readFileSync(path.join(repository, "Tests/BeebWasmTests/Fixtures/parity.ssd")));
  // 2^31 microseconds is 4,294,967,296 cycles; go past it.
  const target = 4_450_000_000;
  while (m.cycles < target) m.run(20_000_000);
  m.type("*CAT\nCHAIN \"HELLO\"\n");
  while (m.isTyping) m.run(200_000);
  m.run(16_000_000);
  m.type("PRINT 2+2\n");
  while (m.isTyping) m.run(200_000);
  m.run(400_000);
  const text = m.screenText();
  assert.match(text, /HELLO FROM DISC\s*\nSUM 5050\s*\nSAVED/);
  assert.match(text, /PRINT 2\+2\s*\n\s+4\s*\n>/);
  assert.ok(m.cycles > target);
  assert.equal(module.failed, null);
});
