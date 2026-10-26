// A typed wrapper around the BeebWasm ABI (Sources/BeebWasm/Exports.swift;
// docs/wasm.md): loading the module, and passing bytes in and out of its
// linear memory, so that the browser, Node and Cloudflare hosts don't each
// do it themselves. No DOM, no Node APIs.

import { Wasi, WasiExit, type WasiOptions } from "./wasi.ts";

export { WasiExit };

/** The ABI version this wrapper speaks. */
export const ABI_VERSION = 1;

export const Model = { modelA: 0, modelB: 1, bPlus: 2, master128: 3, masterCompact: 4 } as const;
export type Model = (typeof Model)[keyof typeof Model];

export const DiscFormat = { ssd: 0, dsd: 1, adf: 2, adl: 3, img: 4, dos: 5 } as const;
export type DiscFormat = (typeof DiscFormat)[keyof typeof DiscFormat];

export const Reset = { power: 0, break: 1, ctrlBreak: 2, shiftBreak: 3 } as const;
export type Reset = (typeof Reset)[keyof typeof Reset];

/** ROM slots: the OS, or sideways banks 0-15. */
export const OS_SLOT = -1;

export const Status = {
  on: 1,
  stoppedByDebugger: 2,
  capsLock: 4,
  shiftLock: 8,
  drive0: 16,
  drive1: 32,
  cassetteMotor: 64,
} as const;

/** A failure the module reported (its status code and message). */
export class BeebError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export const StatusCode = {
  invalidHandle: -1,
  invalidArgument: -2,
  notReady: -3,
  badData: -4,
  unsupported: -5,
  limitReached: -6,
} as const;

export interface CPUState {
  pc: number;
  a: number;
  x: number;
  y: number;
  s: number;
  p: number;
}

interface Exports {
  memory: WebAssembly.Memory;
  _initialize(): void;
  [name: string]: any;
}

export type ModuleSource = WebAssembly.Module | BufferSource | Response | PromiseLike<Response>;

/** One instance of the module: up to 16 machines share its memory. */
export class BeebModule {
  readonly exports: Exports;
  readonly wasi: Wasi;
  /** Set once the module has trapped: it can't be trusted after that. */
  failed: unknown = null;

  private constructor(exports: Exports, wasi: Wasi) {
    this.exports = exports;
    this.wasi = wasi;
  }

  static async load(source: ModuleSource, options: WasiOptions = {}): Promise<BeebModule> {
    const wasi = new Wasi(options);
    const imports = { wasi_snapshot_preview1: wasi.imports };
    let instance: WebAssembly.Instance;
    if (source instanceof WebAssembly.Module) {
      instance = await WebAssembly.instantiate(source, imports);
    } else if (typeof Response !== "undefined" && (source instanceof Response || "then" in (source as object))) {
      const response = await (source as PromiseLike<Response>);
      if (typeof WebAssembly.instantiateStreaming === "function" && response.headers.get("content-type") === "application/wasm") {
        instance = (await WebAssembly.instantiateStreaming(response, imports)).instance;
      } else {
        instance = (await WebAssembly.instantiate(await response.arrayBuffer(), imports)).instance;
      }
    } else {
      instance = (await WebAssembly.instantiate(source as BufferSource, imports)).instance;
    }
    const exports = instance.exports as unknown as Exports;
    wasi.memory = exports.memory;
    exports._initialize();
    const module = new BeebModule(exports, wasi);
    const version = module.call("beeb_abi_version");
    if (version !== ABI_VERSION) throw new Error(`the module speaks BeebWasm ABI ${version}, not ${ABI_VERSION}`);
    return module;
  }

  /** Calls an export, noting a trap (a Swift runtime failure). */
  call(name: string, ...args: (number | bigint)[]): any {
    if (this.failed) throw new Error("the WebAssembly module failed earlier and can't be used", { cause: this.failed });
    try {
      return this.exports[name](...args);
    } catch (error) {
      this.failed = error;
      throw error;
    }
  }

  /** Throws the module's error for a negative status. */
  check(status: number): number {
    if (status >= 0) return status;
    const pointer = this.call("beeb_error_ptr");
    const length = this.call("beeb_error_len");
    throw new BeebError(status, new TextDecoder().decode(this.bytes(pointer, length)));
  }

  get memory(): WebAssembly.Memory {
    return this.exports.memory;
  }

  /** Bytes in linear memory: a view, valid until memory grows. */
  bytes(pointer: number, length: number): Uint8Array {
    return new Uint8Array(this.memory.buffer, pointer, length);
  }

  /** Copies `data` into module memory for the length of `body`. */
  withBytes<T>(data: Uint8Array, body: (pointer: number, length: number) => T): T {
    if (data.length === 0) return body(0, 0);
    const pointer = this.call("beeb_alloc", data.length);
    if (!pointer) throw new BeebError(StatusCode.limitReached, "out of WebAssembly memory");
    try {
      this.bytes(pointer, data.length).set(data);
      return body(pointer, data.length);
    } finally {
      this.call("beeb_free", pointer);
    }
  }

  /** A copy of the result buffer's first `length` bytes. */
  result(length: number): Uint8Array {
    return this.bytes(this.call("beeb_result_ptr"), length).slice();
  }

  get machineCount(): number {
    return this.call("beeb_machine_count");
  }

  createMachine(model: Model = Model.modelB): BeebMachine {
    return new BeebMachine(this, this.check(this.call("beeb_create", model)));
  }

  readonly videoWidth = 736;
  readonly videoHeight = 576;
}

/** A BBC Micro in the module, by handle. */
export class BeebMachine {
  readonly module: BeebModule;
  readonly handle: number;
  private released = false;

  constructor(module: BeebModule, handle: number) {
    this.module = module;
    this.handle = handle;
  }

  private call(name: string, ...args: number[]): number {
    if (this.released) throw new BeebError(StatusCode.invalidHandle, "the machine has been released");
    return this.module.check(this.module.call(name, this.handle, ...args));
  }

  release() {
    if (this.released) return;
    this.call("beeb_release");
    this.released = true;
  }

  /** `slot` OS_SLOT for the OS, or a sideways bank 0-15. Power cycles a machine that's on. */
  loadROM(slot: number, rom: Uint8Array) {
    this.module.withBytes(rom, (p, n) => this.call("beeb_load_rom", slot, p, n));
  }

  setRTC(year: number, month: number, day: number, dayOfWeek: number, hours: number, minutes: number, seconds: number) {
    this.call("beeb_set_rtc", year, month, day, dayOfWeek, hours, minutes, seconds);
  }

  powerOn() {
    this.call("beeb_power_on");
  }

  reset(kind: Reset) {
    this.call("beeb_reset", kind);
  }

  /** Runs up to `cycles` 2MHz cycles (at most 20,000,000); returns how many ran. */
  run(cycles: number): number {
    return this.call("beeb_run", cycles);
  }

  get cycles(): number {
    return this.module.call("beeb_cycles", this.handle);
  }

  get status(): number {
    return this.call("beeb_status");
  }

  get cpu(): CPUState {
    return this.withScratch(8, (p) => {
      this.call("beeb_cpu_state", p);
      const b = this.module.bytes(p, 8);
      return { pc: b[0] | (b[1] << 8), a: b[2], x: b[3], y: b[4], s: b[5], p: b[6] };
    });
  }

  /** Space 0: as the CPU sees memory; 1: the RAM the video hardware reads. */
  readMemory(address: number, length: number, space = 0): Uint8Array {
    if (length === 0) return new Uint8Array();
    return this.withScratch(length, (p) => {
      this.call("beeb_read_memory", space, address, length, p);
      return this.module.bytes(p, length).slice();
    });
  }

  /** A key in the matrix (row << 4 | column; 0x7F Break), now. */
  setKey(code: number, down: boolean) {
    this.call("beeb_set_key", code, down ? 1 : 0);
  }

  releaseAllKeys() {
    this.call("beeb_release_all_keys");
  }

  /** Types text a key at a time as the machine runs ("\n" is Return). */
  type(text: string) {
    this.module.withBytes(new TextEncoder().encode(text), (p, n) => this.call("beeb_type", p, n));
  }

  get isTyping(): boolean {
    return this.call("beeb_is_typing") === 1;
  }

  insertDisc(drive: 0 | 1, format: DiscFormat, image: Uint8Array) {
    this.module.withBytes(image, (p, n) => this.call("beeb_insert_disc", drive, format, p, n));
  }

  ejectDisc(drive: 0 | 1) {
    this.call("beeb_eject_disc", drive);
  }

  /** The disc in a drive, with what the BBC wrote to it. */
  exportDisc(drive: 0 | 1, format: DiscFormat): Uint8Array {
    return this.module.result(this.call("beeb_export_disc", drive, format));
  }

  get frameCount(): number {
    return this.call("beeb_video_frame_count");
  }

  /**
   * The last frame, RGBA8, 736 x 576, top row first: a view of the
   * module's memory, valid until the next call into it (copy it to keep it).
   */
  frame(): Uint8ClampedArray<ArrayBuffer> {
    const pointer = this.module.call("beeb_video_frame", this.handle);
    if (!pointer) this.module.check(-1);
    // (Linear memory is an ArrayBuffer: the module isn't built shared.)
    const buffer = this.module.memory.buffer as ArrayBuffer;
    return new Uint8ClampedArray(buffer, pointer, this.module.videoWidth * this.module.videoHeight * 4);
  }

  /** FNV-1a of the last frame: equal frames, equal hashes, on any host. */
  get frameHash(): number {
    return this.module.call("beeb_video_frame_hash", this.handle) >>> 0;
  }

  screenText(): string {
    return new TextDecoder().decode(this.module.result(this.call("beeb_screen_text")));
  }

  /** The whole machine, as MacBeeb's save state format (uncompressed). */
  saveState(): Uint8Array {
    return this.module.result(this.call("beeb_save_state"));
  }

  /** Becomes the machine in a save state (its model and ROMs included). */
  restoreState(state: Uint8Array) {
    this.module.withBytes(state, (p, n) => this.call("beeb_restore_state", p, n));
  }

  private withScratch<T>(length: number, body: (pointer: number) => T): T {
    const pointer = this.module.call("beeb_alloc", length);
    if (!pointer) throw new BeebError(StatusCode.limitReached, "out of WebAssembly memory");
    try {
      return body(pointer);
    } finally {
      this.module.call("beeb_free", pointer);
    }
  }
}
