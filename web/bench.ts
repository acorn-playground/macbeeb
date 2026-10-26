// The WebAssembly module's speed on beeb-bench's "with TV" workload (a
// Model B running a busy BASIC loop drawing in MODE 2, 20 seconds of BBC
// time), for comparison with the native build's (swift run -c release
// beeb-bench). Also: start-up, save state and restore times.
//
//   node bench.ts            (needs ../.build-wasm/beeb.wasm and MacBeeb's ROMs)

import fs from "node:fs";
import path from "node:path";
import { BeebModule, Model, OS_SLOT } from "./src/beeb-wasm.ts";

const repository = path.resolve(import.meta.dirname, "..");
const roms = path.join(repository, "Sources/BeebROMs/ROMs");
const wasmPath = path.join(repository, ".build-wasm/beeb.wasm");

const t0 = performance.now();
const bytes = fs.readFileSync(wasmPath);
const compiled = await WebAssembly.compile(bytes);
const t1 = performance.now();
const module = await BeebModule.load(compiled, { stdout: () => {} });
const t2 = performance.now();
const machine = module.createMachine(Model.modelB);
machine.loadROM(OS_SLOT, fs.readFileSync(path.join(roms, "os12.rom")));
machine.loadROM(15, fs.readFileSync(path.join(roms, "basic2.rom")));
machine.loadROM(14, fs.readFileSync(path.join(roms, "dfs12.rom")));
machine.powerOn();
const t3 = performance.now();
machine.run(2_000_000);
const t4 = performance.now();

machine.type("MODE 2\nREPEAT:GCOL0,RND(7):DRAW RND(1280),RND(1024):UNTIL FALSE\n");
while (machine.isTyping) machine.run(200_000);

// 20 seconds of BBC time, in 20ms batches as a browser would run it.
const batches: number[] = [];
const started = performance.now();
for (let i = 0; i < 1000; i++) {
  const s = performance.now();
  machine.run(40_000);
  batches.push(performance.now() - s);
}
const elapsed = (performance.now() - started) / 1000;
batches.sort((a, b) => a - b);

const s0 = performance.now();
const state = machine.saveState();
const s1 = performance.now();
const copy = module.createMachine(Model.modelB);
copy.restoreState(state);
const s2 = performance.now();

const mhz = 40_000_000 / elapsed / 1e6;
console.log(`node ${process.version}, ${process.arch}`);
console.log(`module: ${bytes.length} bytes; compile ${(t1 - t0).toFixed(1)}ms, instantiate ${(t2 - t1).toFixed(1)}ms`);
console.log(`create and power on a Model B: ${(t3 - t2).toFixed(1)}ms; boot (1s of BBC time): ${(t4 - t3).toFixed(1)}ms`);
console.log(`with TV: ${mhz.toFixed(1)} MHz (${(mhz / 2).toFixed(1)}x a 2MHz BBC), 20s of BBC time in ${elapsed.toFixed(2)}s`);
console.log(`20ms batch: median ${batches[500].toFixed(2)}ms, 95th ${batches[950].toFixed(2)}ms, max ${batches[999].toFixed(2)}ms`);
console.log(`save state: ${state.length} bytes in ${(s1 - s0).toFixed(1)}ms; restore into a new machine ${(s2 - s1).toFixed(1)}ms`);
console.log(`linear memory: ${module.memory.buffer.byteLength} bytes with two machines`);
