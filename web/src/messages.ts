// Messages between the page (main.ts) and the emulation worker
// (beeb-worker.ts). The worker runs one or more stations (BBC Micros, each
// with its own screen), alone or together on an Econet. Messages for a
// station carry its id and the generation of the machine they're for:
// each power on or restore starts a new one, so a key or frame from before
// it can't reach the machine after.

import type { DiscFormat, GatewayStatus, Model, Reset } from "./beeb-wasm.ts";
import type { RoomCredentials, RoomSnapshot, StationClaim } from "./room.ts";

export interface StationTarget {
  station: number;
  generation: number;
}

export type ToWorker =
  | { type: "init"; wasmUrl: string }
  /** A station's screen (an OffscreenCanvas, or null to send the page the pixels). */
  | { type: "canvas"; station: number; canvas: OffscreenCanvas | null }
  | ({ type: "power"; model: Model; roms: { slot: number; bytes: ArrayBuffer }[]; econet: number | null;
       claim: Omit<StationClaim, "station"> } & StationTarget)
  | { type: "removeStation"; station: number }
  /** The station whose sound plays and whose joysticks the gamepads are. */
  | { type: "select"; station: number }
  | ({ type: "key"; code: number; down: boolean } & StationTarget)
  | ({ type: "releaseKeys" } & StationTarget)
  | ({ type: "reset"; kind: Reset } & StationTarget)
  | ({ type: "typeText"; text: string } & StationTarget)
  | ({ type: "insertDisc"; drive: 0 | 1; format: DiscFormat; bytes: ArrayBuffer } & StationTarget)
  | ({ type: "ejectDisc"; drive: 0 | 1 } & StationTarget)
  | ({ type: "exportDisc"; id: number; drive: 0 | 1; format: DiscFormat } & StationTarget)
  | ({ type: "saveState"; id: number } & StationTarget)
  | ({ type: "restoreState"; bytes: ArrayBuffer } & StationTarget)
  | ({ type: "query"; id: number; what: "screenText" | "cpu" } & StationTarget)
  | { type: "joystick"; index: 0 | 1; x: number; y: number; fire: boolean }
  /** Sound: samples for the selected station, at `rate`, to `port` (the AudioWorklet's); null stops it. */
  | { type: "audio"; port: MessagePort | null; rate: number }
  /** The stations share an Econet (with a clock of `clock` bits a second), or run alone. */
  | { type: "econet"; on: boolean; clock: number }
  | { type: "room"; action: "create"; service: string; name: string; displayName: string }
  | { type: "room"; action: "join"; service: string; invitation: string; displayName: string }
  | { type: "room"; action: "connect"; credentials: RoomCredentials }
  | { type: "room"; action: "leave" | "close" }
  | { type: "pause"; paused: boolean }
  | { type: "hidden"; hidden: boolean };

export interface Stats {
  /** Frames drawn per second (all stations), and the selected station's BBC frames (fields) per second. */
  drawnPerSecond: number;
  fieldsPerSecond: number;
  /** Cycles the clock asked for, and ran, per second (per station). */
  requestedPerSecond: number;
  executedPerSecond: number;
  /** Time running the machines per batch, ms. */
  runMedian: number;
  run95: number;
  /** Emulated speed, as a fraction of a real BBC. */
  speed: number;
  memoryBytes: number;
  /** Real BBC time dropped because the host fell behind (ms, total). */
  droppedMs: number;
  /** Sound samples sent to the page per second. */
  audioPerSecond: number;
}

export interface StationStatus {
  station: number;
  generation: number;
  cycles: number;
  lights: number;
}

export interface NetworkStatus {
  frames: number;
  collisions: number;
  gateway: GatewayStatus | null;
}

export type FromWorker =
  | { type: "ready"; wasmBytes: number; loadMs: number }
  | { type: "powered"; station: number; generation: number; createMs: number }
  | { type: "status"; running: boolean; paused: boolean; stations: StationStatus[]; stats: Stats; network: NetworkStatus | null }
  | { type: "frame"; station: number; generation: number; frame: ArrayBuffer }
  | { type: "reply"; id: number; value: unknown }
  | { type: "room"; snapshot: RoomSnapshot | null }
  /** New credentials for a room (made or joined), for the page to keep; null: forget them. */
  | { type: "roomCredentials"; credentials: RoomCredentials | null }
  | { type: "error"; message: string; fatal: boolean };
