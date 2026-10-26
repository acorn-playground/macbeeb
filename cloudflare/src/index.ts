// A local-only proof that MacBeeb's WebAssembly BeebCore (the module the
// browser runs, not a second emulator) works in Cloudflare's runtime: a
// Worker routes to a Durable Object per machine, which runs it in bounded
// bursts and keeps its save state in Durable Object storage, so it comes
// back after the object is evicted or the runtime restarts.
//
// Only for `wrangler dev`: it answers only on localhost, has no
// authentication, and isn't configured to deploy anywhere. See README.md
// and docs/cloudflare-feasibility.md.

import { DurableObject } from "cloudflare:workers";
import wasm from "../../.build-wasm/beeb.wasm";
import { BeebError, BeebModule, type BeebMachine, type Model } from "../../web/src/beeb-wasm.ts";
import parityROM from "../../Tests/BeebWasmTests/Fixtures/parity.rom";

interface Env {
  MACHINES: DurableObjectNamespace<BeebMachineObject>;
  MACBEEB_LOCAL_ONLY: string;
}

/** Most BBC time a request may ask for: 5 seconds (10,000,000 cycles). */
const MAX_RUN_CYCLES = 10_000_000;
/** Storage values are at most 2MB, so states are kept in pieces. */
const CHUNK_BYTES = 1 << 20;
const MAX_BODY_BYTES = 1 << 20;

const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value, null, 2), { status, headers: { "content-type": "application/json" } });

function hex(bytes: Uint8Array): string {
  let hash = 0x811c9dc5;
  for (const byte of bytes) hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  return hash.toString(16).padStart(8, "0");
}

function base64(text: string): Uint8Array {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (env.MACBEEB_LOCAL_ONLY !== "true" || !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) {
      return json({ error: "this proof only answers locally (wrangler dev)" }, 403);
    }
    // /local/machines/:id/:action
    const match = url.pathname.match(/^\/local\/machines\/([A-Za-z0-9_-]{1,64})(?:\/([a-z]+))?$/);
    if (!match) return json({ error: "try POST /local/machines/:id/create, see README.md" }, 404);
    const [, id, action = "status"] = match;
    const length = Number(request.headers.get("content-length") ?? 0);
    if (length > MAX_BODY_BYTES) return json({ error: "request too big" }, 413);
    const body = request.method === "POST" && length > 0 ? await request.json() : {};
    const stub = env.MACHINES.get(env.MACHINES.idFromName(id));
    return json(await stub.command(action, body as Record<string, unknown>));
  },
};

/** One BBC Micro: its machine while the object's in memory, its state in storage. */
export class BeebMachineObject extends DurableObject<Env> {
  private module: BeebModule | null = null;
  private machine: BeebMachine | null = null;
  /** Created in this instance (as opposed to restored, or not yet). */
  private origin: "created" | "restored" | null = null;

  /** Requests to one object run one at a time (the input gate), so commands are a serial queue. */
  async command(action: string, body: Record<string, unknown>): Promise<unknown> {
    try {
      switch (action) {
        case "create": return await this.create(body);
        case "run": return this.run(body);
        case "type": return this.type(body);
        case "key": return this.key(body);
        case "status": return await this.status();
        case "screen": return this.screen();
        case "snapshot": return await this.snapshot();
        case "restore": return await this.restore();
        case "evict":
          // Throws away this instance: the next request gets a new one,
          // with nothing in memory.
          this.ctx.abort("evicted by request");
          return { evicted: true };
        default: return { error: `no action ${action}` };
      }
    } catch (error) {
      if (error instanceof BeebError) return { error: error.message, status: error.status };
      throw error;
    }
  }

  private async load(): Promise<BeebModule> {
    this.module ??= await BeebModule.load(wasm, { stdout: (t) => console.log(t), stderr: (t) => console.warn(t) });
    return this.module;
  }

  private require(): BeebMachine {
    if (!this.machine) throw new BeebError(-3, "no machine in memory: create or restore one");
    return this.machine;
  }

  /** A new machine: our own test ROM, or (locally) ROMs in the body, base64 by slot. */
  private async create(body: Record<string, unknown>) {
    const module = await this.load();
    this.machine?.release();
    const machine = module.createMachine((body.model as Model | undefined) ?? 1);
    const roms = (body.roms as Record<string, string> | undefined) ?? null;
    try {
      if (roms) for (const [slot, data] of Object.entries(roms)) machine.loadROM(Number(slot), base64(data));
      else machine.loadROM(-1, new Uint8Array(parityROM));
      machine.powerOn();
    } catch (error) {
      machine.release();
      throw error;
    }
    this.machine = machine;
    this.origin = "created";
    return { created: true, rom: roms ? "supplied" : "parity.rom", ...this.describe() };
  }

  private run(body: Record<string, unknown>) {
    const machine = this.require();
    const cycles = Math.floor(Number(body.cycles ?? 0));
    if (!(cycles > 0 && cycles <= MAX_RUN_CYCLES)) return { error: `run 1-${MAX_RUN_CYCLES} cycles a request` };
    let ran = 0;
    while (ran < cycles) {
      // Typing goes key by key; run in pieces so it's paced as usual.
      const done = machine.run(Math.min(cycles - ran, 2_000_000));
      ran += done;
      if (done === 0) break;
    }
    return { ran, ...this.describe() };
  }

  private type(body: Record<string, unknown>) {
    const text = String(body.text ?? "");
    if (text.length > 4096) return { error: "at most 4096 characters" };
    this.require().type(text);
    return { typing: true };
  }

  private key(body: Record<string, unknown>) {
    this.require().setKey(Number(body.code), Boolean(body.down));
    return this.describe();
  }

  private async status() {
    const stored = await this.ctx.storage.get<{ chunks: number; bytes: number; cycles: number; hash: string }>("state:meta");
    return { inMemory: this.machine != null, origin: this.origin, stored: stored ?? null, ...(this.machine ? this.describe() : {}) };
  }

  private screen() {
    return { text: this.require().screenText(), ...this.describe() };
  }

  /** Persists the whole machine (MacBeeb's save state) to storage. */
  private async snapshot() {
    const state = this.require().saveState();
    const chunks = Math.ceil(state.length / CHUNK_BYTES);
    const entries: Record<string, unknown> = {};
    for (let i = 0; i < chunks; i++) entries[`state:${i}`] = state.slice(i * CHUNK_BYTES, (i + 1) * CHUNK_BYTES);
    const meta = { chunks, bytes: state.length, cycles: this.machine!.cycles, hash: hex(state) };
    entries["state:meta"] = meta;
    await this.ctx.storage.put(entries);
    return { saved: true, ...meta };
  }

  /** A fresh machine from the stored state. */
  private async restore() {
    const meta = await this.ctx.storage.get<{ chunks: number; bytes: number; hash: string }>("state:meta");
    if (!meta) return { error: "no stored state: snapshot first" };
    const parts = await this.ctx.storage.get<Uint8Array>(Array.from({ length: meta.chunks }, (_, i) => `state:${i}`));
    const state = new Uint8Array(meta.bytes);
    let offset = 0;
    for (let i = 0; i < meta.chunks; i++) {
      const part = parts.get(`state:${i}`);
      if (!part) return { error: `stored state is missing piece ${i}` };
      state.set(part, offset);
      offset += part.length;
    }
    if (hex(state) !== meta.hash) return { error: "stored state is corrupt" };
    const module = await this.load();
    this.machine?.release();
    const machine = module.createMachine();
    machine.restoreState(state);
    this.machine = machine;
    this.origin = "restored";
    return { restored: true, ...this.describe() };
  }

  private describe() {
    const m = this.machine!;
    return {
      cycles: m.cycles,
      cpu: m.cpu,
      ram: hex(m.readMemory(0, 0x8000)),
      frames: m.frameCount,
      memoryBytes: this.module!.memory.buffer.byteLength,
    };
  }
}
