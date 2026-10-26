// The WebAssembly side of native/WebAssembly parity: the scenarios in
// Tests/BeebWasmTests/Fixtures, run in the module, must give the checkpoints
// in expected.json, which the native build (Tests/BeebWasmTests) gives too.
//
// Scenarios that need Acorn's ROMs (from Sources/BeebROMs/ROMs) are skipped
// with MACBEEB_SKIP_LICENSED=1. MACBEEB_PARITY_STATES: as in
// ParityTests.swift, save states are written to that folder, and the
// native build's restored in their place.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { BeebModule, type BeebMachine, type BeebNetwork, type Model, type DiscFormat, type Reset } from "../src/beeb-wasm.ts";
import { loadModule, repository } from "./module.ts";

const fixtures = path.join(repository, "Tests/BeebWasmTests/Fixtures");
const roms = path.join(repository, "Sources/BeebROMs/ROMs");
const { scenarios } = JSON.parse(fs.readFileSync(path.join(fixtures, "scenarios.json"), "utf8"));
const expected = JSON.parse(fs.readFileSync(path.join(fixtures, "expected.json"), "utf8"));
const skipLicensed = process.env.MACBEEB_SKIP_LICENSED === "1";
const states = process.env.MACBEEB_PARITY_STATES;

function file(name: string): Uint8Array {
  return fs.readFileSync(name.startsWith("@") ? path.join(roms, name.slice(1)) : path.join(fixtures, name));
}

function fnv(bytes: Uint8Array): string {
  let hash = 0x811c9dc5;
  for (const byte of bytes) hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  return hash.toString(16).padStart(8, "0");
}

type Record = { [key: string]: number | string };

class Runner {
  module: BeebModule;
  scenario: any;
  machine: BeebMachine;
  /** Machines after the first ("on": 1, 2...). */
  others: BeebMachine[];
  network: BeebNetwork | null = null;
  twin: BeebMachine | null = null;
  disc: string | null = null;
  /** Machines making sound, and a hash of all they've made. */
  audio = new Map<BeebMachine, number>();

  constructor(module: BeebModule, scenario: any) {
    this.module = module;
    this.scenario = scenario;
    const specs = this.specs;
    this.machine = this.make(specs[0]);
    this.others = specs.slice(1).map((spec: any) => this.make(spec));
    if (scenario.network) {
      this.network = module.createNetwork(scenario.network.clock ?? 200_000);
      for (const m of [this.machine, ...this.others]) this.network.add(m);
    }
  }

  get specs(): any[] {
    return this.scenario.machines ?? [this.scenario];
  }

  on(step: any): BeebMachine {
    return (step.on ?? 0) === 0 ? this.machine : this.others[step.on - 1];
  }

  make(spec: any): BeebMachine {
    const machine = this.module.createMachine(spec.model as Model);
    for (const [slot, name] of Object.entries(spec.roms)) machine.loadROM(Number(slot), file(name as string));
    if (spec.station) machine.setEconetStation(spec.station);
    if (spec.tube) machine.setSecondProcessor(file(spec.tube));
    machine.powerOn();
    return machine;
  }

  run(cycles: number, chunk: number) {
    for (let done = 0; done < cycles; ) {
      const n = Math.min(chunk, cycles - done);
      if (this.network) {
        assert.ok(this.network.run(n) >= n);
      } else {
        assert.equal(this.machine.run(n), n);
        if (this.twin) assert.equal(this.twin.run(n), n);
      }
      done += n;
    }
  }

  release() {
    this.network?.release();
    for (const m of [this.machine, ...this.others]) m.release();
    this.twin?.release();
  }

  check(machine: BeebMachine, licensed: boolean): Record {
    const cpu = machine.cpu;
    const record: Record = {
      cycles: machine.cycles,
      pc: cpu.pc, a: cpu.a, x: cpu.x, y: cpu.y, s: cpu.s, p: cpu.p,
      ram: fnv(machine.readMemory(0, 0x8000)),
      frame: machine.frameHash.toString(16).padStart(8, "0"),
      frames: machine.frameCount,
      status: machine.status,
    };
    if (licensed) record.text = machine.screenText();
    if (this.disc) record.disc = this.disc;
    if (this.audio.has(machine)) {
      // Every sample made so far, hashed as little-endian floats.
      let hash = this.audio.get(machine)!;
      for (;;) {
        const samples = machine.readAudio(4096);
        for (const byte of new Uint8Array(samples.buffer)) hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
        if (samples.length < 4096) break;
      }
      this.audio.set(machine, hash);
      record.audio = hash.toString(16).padStart(8, "0");
    }
    return record;
  }

  saveRestore(point: string) {
    let state = this.machine.saveState();
    assert.ok(state.length > 0);
    if (states) {
      const base = path.join(states, point.replaceAll("/", "-"));
      fs.mkdirSync(states, { recursive: true });
      fs.writeFileSync(`${base}.wasm.beebstate`, state);
      if (fs.existsSync(`${base}.native.beebstate`)) {
        console.log(`${point}: restoring the native build's state`);
        state = fs.readFileSync(`${base}.native.beebstate`);
      }
    }
    this.machine.release();
    this.machine = this.module.createMachine(this.scenario.model as Model);
    this.machine.restoreState(state);
  }
}

function runScenario(module: BeebModule, scenario: any): { [key: string]: Record } {
  const licensed = scenario.licensed ?? false;
  const runner = new Runner(module, scenario);
  const checks: { [key: string]: Record } = {};
  try {
    for (const [index, step] of scenario.steps.entries()) {
      if (step.run !== undefined) runner.run(step.run, 20_000_000);
      else if (step.runChunks) runner.run(step.runChunks[0], step.runChunks[1]);
      else if (step.twin) runner.twin = runner.make(runner.specs[0]);
      else if (step.audio !== undefined) {
        runner.on(step).startAudio(step.audio);
        runner.audio.set(runner.on(step), 0x811c9dc5);
      } else if (step.joystick) runner.on(step).setJoystick(step.joystick[0], step.joystick[1], step.joystick[2], step.joystick[3] === 1);
      else if (step.type !== undefined) runner.on(step).type(step.type);
      else if (step.untilTyped) while ([runner.machine, ...runner.others].some((m) => m.isTyping)) runner.run(100_000, 100_000);
      else if (step.key) runner.on(step).setKey(step.key[0], step.key[1] === 1);
      else if (step.reset !== undefined) runner.machine.reset(step.reset as Reset);
      else if (step.insertDisc) runner.machine.insertDisc(step.insertDisc[0], step.insertDisc[1] as DiscFormat, file(step.insertDisc[2]));
      else if (step.exportDisc) runner.disc = fnv(runner.machine.exportDisc(step.exportDisc[0], step.exportDisc[1] as DiscFormat));
      else if (step.saveRestore) runner.saveRestore(`${scenario.name}/${index}`);
      else if (step.check) {
        const record = runner.check(runner.on(step), licensed);
        checks[`${scenario.name}/${step.check}`] = record;
        if (runner.twin) assert.deepEqual(runner.check(runner.twin, licensed), record);
      }
    }
  } finally {
    runner.release();
  }
  return checks;
}

test("scenarios give the same checkpoints as the native build", async (t) => {
  const module = await loadModule();
  const all: { [key: string]: Record } = {};
  for (const scenario of scenarios) {
    if (scenario.licensed && skipLicensed) {
      t.diagnostic(`skipped ${scenario.name} (needs Acorn's ROMs)`);
      continue;
    }
    const started = performance.now();
    Object.assign(all, runScenario(module, scenario));
    t.diagnostic(`${scenario.name}: ${(performance.now() - started).toFixed(0)}ms`);
  }
  for (const scenario of scenarios) {
    for (const step of scenario.steps) {
      const mine = `${scenario.name}/${step.check}`;
      if (!step.sameAs || !all[mine] || !all[step.sameAs]) continue;
      const pick = (r: Record) => (step.fields ? Object.fromEntries(step.fields.map((f: string) => [f, r[f]])) : r);
      assert.deepEqual(pick(all[mine]), pick(all[step.sameAs]), `${mine} vs ${step.sameAs}`);
    }
  }
  for (const [key, record] of Object.entries(all)) {
    assert.deepEqual(record, expected[key], key);
  }
  assert.equal(module.machineCount, 0);
});
