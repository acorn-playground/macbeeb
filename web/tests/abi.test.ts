// The ABI in the WebAssembly module: bad input is refused, not trapped on,
// and machines come and go without leaking. No Acorn ROMs needed.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { BeebError, DiscFormat, Model, OS_SLOT, Reset, StatusCode } from "../src/beeb-wasm.ts";
import { loadModule, repository } from "./module.ts";

const rom = fs.readFileSync(path.join(repository, "Tests/BeebWasmTests/Fixtures/parity.rom"));

function rejects(status: number, body: () => unknown) {
  assert.throws(body, (e: unknown) => e instanceof BeebError && e.status === status);
}

test("bad input is an error, not a trap", async () => {
  const module = await loadModule();
  rejects(StatusCode.unsupported, () => module.createMachine(99 as Model));
  const m = module.createMachine(Model.modelB);
  rejects(StatusCode.notReady, () => m.run(100));
  rejects(StatusCode.notReady, () => m.powerOn());
  rejects(StatusCode.badData, () => m.loadROM(OS_SLOT, new Uint8Array(100)));
  rejects(StatusCode.invalidArgument, () => m.loadROM(16, rom));
  rejects(StatusCode.badData, () => m.loadROM(3, new Uint8Array(0x5000)));
  m.loadROM(OS_SLOT, rom);
  m.powerOn();
  rejects(StatusCode.invalidArgument, () => m.run(-1));
  rejects(StatusCode.invalidArgument, () => m.run(20_000_001));
  rejects(StatusCode.invalidArgument, () => m.readMemory(0x10000, 1));
  rejects(StatusCode.invalidArgument, () => m.readMemory(0, 1, 5));
  rejects(StatusCode.invalidArgument, () => m.setKey(0x80, true));
  rejects(StatusCode.invalidArgument, () => m.insertDisc(2 as 0, DiscFormat.ssd, new Uint8Array(256)));
  rejects(StatusCode.unsupported, () => m.insertDisc(0, 9 as DiscFormat, new Uint8Array(256)));
  rejects(StatusCode.badData, () => m.insertDisc(0, DiscFormat.adf, new Uint8Array(100)));
  rejects(StatusCode.badData, () => m.insertDisc(0, DiscFormat.ssd, new Uint8Array(5 << 20)));
  rejects(StatusCode.invalidArgument, () => m.exportDisc(0, DiscFormat.ssd));
  rejects(StatusCode.invalidArgument, () => m.reset(7 as Reset));
  rejects(StatusCode.invalidArgument, () => m.setRTC(0, 13, 1, 1, 0, 0, 0));
  assert.equal(m.run(1000), 1000);
  const state = m.saveState();
  rejects(StatusCode.badData, () => m.restoreState(state.subarray(0, state.length >> 1)));
  rejects(StatusCode.badData, () => m.restoreState(new Uint8Array(100)));
  assert.equal(m.cycles, 1000, "a failed restore leaves the machine as it was");
  // Reading wraps at &FFFF.
  assert.deepEqual(m.readMemory(0xffff, 2), new Uint8Array([rom[0x3fff], m.readMemory(0, 1)[0]]));
  m.release();
  rejects(StatusCode.invalidHandle, () => m.run(1));
  assert.equal(module.failed, null);
});

test("at most 16 machines, and their handles are checked", async () => {
  const module = await loadModule();
  const machines = Array.from({ length: 16 }, () => module.createMachine(Model.modelB));
  rejects(StatusCode.limitReached, () => module.createMachine(Model.modelB));
  for (const m of machines) m.release();
  assert.equal(module.machineCount, 0);
  assert.equal(module.call("beeb_release", machines[0].handle), StatusCode.invalidHandle);
});

test("machines made, run, saved, restored and released repeatedly don't grow memory", async () => {
  const module = await loadModule();
  const cycle = () => {
    const m = module.createMachine(Model.modelB);
    m.loadROM(OS_SLOT, rom);
    m.powerOn();
    m.run(200_000);
    const state = m.saveState();
    const copy = module.createMachine(Model.modelB);
    copy.restoreState(state);
    copy.run(100_000);
    m.frame();
    m.release();
    copy.release();
  };
  for (let i = 0; i < 10; i++) cycle();
  const settled = module.memory.buffer.byteLength;
  for (let i = 0; i < 100; i++) cycle();
  assert.equal(module.memory.buffer.byteLength, settled, `memory grew from ${settled}`);
  assert.equal(module.machineCount, 0);
});
