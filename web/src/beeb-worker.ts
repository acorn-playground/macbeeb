// The emulation worker: owns the WebAssembly module and the machine, and
// keeps it to the BBC's speed by the browser's monotonic clock. The page
// sends it input and control messages, in order; it draws frames to an
// OffscreenCanvas (or sends them to the page to draw).
//
// Time: the machine runs in batches, each for the real time since the
// last (2,000 cycles a millisecond). A tab that's hidden pauses; and after
// a stall (a busy host, a debugger) at most 100ms is caught up, the rest
// dropped, rather than racing through minutes of backlog.
//
// Keys: presses and releases go into a queue, in the order they came, and
// each is applied at a cycle between batches (a batch is split to reach
// it). A release comes at least 40ms of BBC time after its press, and a
// press 20ms after the release before it, so that the OS's keyboard scan
// sees every key however quickly the host sent them (as BeebCore's own
// typing does). Nothing is dropped.

import { BeebModule, type BeebMachine, WasiExit } from "./beeb-wasm.ts";
import type { FromWorker, Stats, ToWorker } from "./messages.ts";

const CYCLES_PER_MS = 2000;
const MAX_CATCH_UP_MS = 100;
const TICK_MS = 5;
const KEY_HOLD_CYCLES = 40 * CYCLES_PER_MS;
const KEY_GAP_CYCLES = 20 * CYCLES_PER_MS;

/** Key events waiting for their cycle. */
let keys: { code: number; down: boolean }[] = [];
const pressedAt = new Map<number, number>();
let lastReleaseAt = -Infinity;

/** Applies the key events that are due; returns cycles until the next (Infinity: none). */
function applyKeys(): number {
  while (machine && keys.length) {
    const event = keys[0];
    const now = machine.cycles;
    const due = event.down ? lastReleaseAt + KEY_GAP_CYCLES : (pressedAt.get(event.code) ?? -Infinity) + KEY_HOLD_CYCLES;
    if (now < due) return Math.ceil(due - now);
    keys.shift();
    machine.setKey(event.code, event.down);
    if (event.down) {
      pressedAt.set(event.code, now);
    } else {
      pressedAt.delete(event.code);
      lastReleaseAt = now;
    }
  }
  return Infinity;
}

function forgetKeys() {
  keys = [];
  pressedAt.clear();
  lastReleaseAt = -Infinity;
}

let module: BeebModule | null = null;
let machine: BeebMachine | null = null;
let generation = 0;
let paused = false;
let hidden = false;
let context: OffscreenCanvasRenderingContext2D | null = null;
let drawnFrame = -1;

let lastTick = 0;
let owed = 0;
const window_ = { started: 0, drawn: 0, fieldsAt: 0, requested: 0, executed: 0, runs: [] as number[] };
let droppedMs = 0;

function post(message: FromWorker, transfer: Transferable[] = []) {
  (self as unknown as Worker).postMessage(message, transfer);
}

function fail(error: unknown) {
  const fatal = module?.failed != null || error instanceof WasiExit;
  post({ type: "error", message: error instanceof Error ? error.message : String(error), fatal });
  if (fatal) machine = null;
}

function present() {
  if (!machine) return;
  const count = machine.frameCount;
  if (count === drawnFrame) return;
  drawnFrame = count;
  const pixels = machine.frame();
  if (context) {
    context.putImageData(new ImageData(pixels, module!.videoWidth, module!.videoHeight), 0, 0);
  } else {
    const copy = pixels.slice().buffer;
    post({ type: "frame", generation, frame: copy }, [copy]);
  }
  window_.drawn++;
}

function tick() {
  setTimeout(tick, TICK_MS);
  const now = performance.now();
  let elapsed = now - lastTick;
  lastTick = now;
  if (!machine || paused || hidden) {
    owed = 0;
    return;
  }
  try {
    if (elapsed > MAX_CATCH_UP_MS) {
      droppedMs += elapsed - MAX_CATCH_UP_MS;
      elapsed = MAX_CATCH_UP_MS;
    }
    owed += elapsed * CYCLES_PER_MS;
    const requested = Math.min(Math.floor(owed), 20_000_000);
    if (requested > 0) {
      const started = performance.now();
      let ran = 0;
      while (ran < requested) {
        const piece = Math.min(requested - ran, applyKeys());
        const done = machine.run(piece);
        ran += done;
        // A debugger stop runs short: don't owe what it didn't run.
        if (done < piece) break;
      }
      applyKeys();
      window_.runs.push(performance.now() - started);
      owed = ran < requested ? 0 : owed - ran;
      window_.requested += requested;
      window_.executed += ran;
    }
    present();
    if (now - window_.started >= 500) report(now);
  } catch (error) {
    fail(error);
  }
}

function report(now: number) {
  if (!machine) return;
  const seconds = (now - window_.started) / 1000;
  const runs = window_.runs.sort((a, b) => a - b);
  const fields = machine.frameCount;
  const stats: Stats = {
    drawnPerSecond: window_.drawn / seconds,
    fieldsPerSecond: (fields - window_.fieldsAt) / seconds,
    requestedPerSecond: window_.requested / seconds,
    executedPerSecond: window_.executed / seconds,
    runMedian: runs.length ? runs[runs.length >> 1] : 0,
    run95: runs.length ? runs[Math.min(runs.length - 1, Math.floor(runs.length * 0.95))] : 0,
    speed: window_.executed / seconds / (CYCLES_PER_MS * 1000),
    memoryBytes: module!.memory.buffer.byteLength,
    droppedMs,
  };
  post({ type: "status", generation, running: !paused && !hidden, paused, cycles: machine.cycles, lights: machine.status, stats });
  Object.assign(window_, { started: now, drawn: 0, fieldsAt: fields, requested: 0, executed: 0, runs: [] });
}

async function init(wasmUrl: string, canvas: OffscreenCanvas | null) {
  const started = performance.now();
  const response = await fetch(wasmUrl);
  if (!response.ok) throw new Error(`couldn't fetch the WebAssembly module (${response.status})`);
  const bytes = await response.arrayBuffer();
  module = await BeebModule.load(bytes, { stdout: (t) => console.log("[beeb]", t), stderr: (t) => console.warn("[beeb]", t) });
  context = canvas?.getContext("2d") ?? null;
  post({ type: "ready", wasmBytes: bytes.byteLength, loadMs: performance.now() - started, offscreen: context != null });
  lastTick = performance.now();
  window_.started = lastTick;
  tick();
}

/** Whether a message is for the machine that's running now. */
function current(message: { generation: number }) {
  return machine != null && message.generation === generation;
}

self.onmessage = async (event: MessageEvent<ToWorker>) => {
  const message = event.data;
  try {
    switch (message.type) {
      case "init":
        await init(message.wasmUrl, message.canvas);
        break;
      case "power": {
        if (!module) throw new Error("the WebAssembly module isn't loaded");
        const started = performance.now();
        machine?.release();
        machine = null;
        const m = module.createMachine(message.model);
        try {
          for (const rom of message.roms) m.loadROM(rom.slot, new Uint8Array(rom.bytes));
          m.powerOn();
        } catch (error) {
          m.release();
          throw error;
        }
        machine = m;
        generation = message.generation;
        drawnFrame = -1;
        owed = 0;
        forgetKeys();
        post({ type: "powered", generation, createMs: performance.now() - started });
        break;
      }
      case "key":
        if (current(message)) {
          keys.push({ code: message.code, down: message.down });
          applyKeys();
        }
        break;
      case "releaseKeys":
        if (current(message)) {
          forgetKeys();
          machine!.releaseAllKeys();
        }
        break;
      case "reset":
        if (current(message)) machine!.reset(message.kind);
        break;
      case "typeText":
        if (current(message)) machine!.type(message.text);
        break;
      case "insertDisc":
        if (current(message)) machine!.insertDisc(message.drive, message.format, new Uint8Array(message.bytes));
        break;
      case "ejectDisc":
        if (current(message)) machine!.ejectDisc(message.drive);
        break;
      case "exportDisc": {
        const image = current(message) ? machine!.exportDisc(message.drive, message.format) : null;
        post({ type: "reply", id: message.id, value: image?.buffer ?? null }, image ? [image.buffer as ArrayBuffer] : []);
        break;
      }
      case "saveState": {
        const state = current(message) ? machine!.saveState() : null;
        post({ type: "reply", id: message.id, value: state?.buffer ?? null }, state ? [state.buffer as ArrayBuffer] : []);
        break;
      }
      case "restoreState":
        if (!module) break;
        if (!machine) machine = module.createMachine();
        machine.restoreState(new Uint8Array(message.bytes));
        generation = message.generation;
        drawnFrame = -1;
        owed = 0;
        forgetKeys();
        post({ type: "powered", generation, createMs: 0 });
        break;
      case "query": {
        let value: unknown = null;
        if (current(message)) value = message.what === "screenText" ? machine!.screenText() : machine!.cpu;
        post({ type: "reply", id: message.id, value });
        break;
      }
      case "pause":
        paused = message.paused;
        if (machine) report(performance.now());
        break;
      case "hidden":
        hidden = message.hidden;
        break;
    }
  } catch (error) {
    fail(error);
  }
};
