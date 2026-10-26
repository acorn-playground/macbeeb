// Messages between the page (main.ts) and the emulation worker
// (beeb-worker.ts). Machine-affecting messages carry the generation of the
// machine they're for: each power on or restore starts a new one, so a
// key or frame from before it can't reach the machine after.

import type { DiscFormat, Model, Reset } from "./beeb-wasm.ts";

export type ToWorker =
  | { type: "init"; wasmUrl: string; canvas: OffscreenCanvas | null }
  | { type: "power"; generation: number; model: Model; roms: { slot: number; bytes: ArrayBuffer }[] }
  | { type: "key"; generation: number; code: number; down: boolean }
  | { type: "releaseKeys"; generation: number }
  | { type: "reset"; generation: number; kind: Reset }
  | { type: "typeText"; generation: number; text: string }
  | { type: "insertDisc"; generation: number; drive: 0 | 1; format: DiscFormat; bytes: ArrayBuffer }
  | { type: "ejectDisc"; generation: number; drive: 0 | 1 }
  | { type: "exportDisc"; generation: number; id: number; drive: 0 | 1; format: DiscFormat }
  | { type: "saveState"; generation: number; id: number }
  | { type: "restoreState"; generation: number; bytes: ArrayBuffer }
  | { type: "query"; generation: number; id: number; what: "screenText" | "cpu" }
  | { type: "pause"; paused: boolean }
  | { type: "hidden"; hidden: boolean };

export interface Stats {
  /** Frames drawn per second, and the BBC's own frames (fields) per second. */
  drawnPerSecond: number;
  fieldsPerSecond: number;
  /** Cycles the clock asked for, and ran, per second. */
  requestedPerSecond: number;
  executedPerSecond: number;
  /** Time in beeb_run per batch, ms. */
  runMedian: number;
  run95: number;
  /** Emulated speed, as a fraction of a real BBC. */
  speed: number;
  memoryBytes: number;
  /** Real BBC time dropped because the host fell behind (ms, total). */
  droppedMs: number;
}

export type FromWorker =
  | { type: "ready"; wasmBytes: number; loadMs: number; offscreen: boolean }
  | { type: "powered"; generation: number; createMs: number }
  | { type: "status"; generation: number; running: boolean; paused: boolean; cycles: number; lights: number; stats: Stats }
  | { type: "frame"; generation: number; frame: ImageBitmap | ArrayBuffer }
  | { type: "reply"; id: number; value: unknown }
  | { type: "error"; message: string; fatal: boolean };
