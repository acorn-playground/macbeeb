// The emulation worker: owns the WebAssembly module and its machines (the
// page's stations), and keeps them to the BBC's speed by the browser's
// monotonic clock. The page sends it input and control messages, in order;
// it draws each station's frames to its OffscreenCanvas (or sends them to
// the page to draw), sends the selected station's sound to the page's
// AudioWorklet, and carries an Internet Econet room's traffic to and from
// the network's gateway.
//
// Time: the machines run in batches, each for the real time since the
// last (2,000 cycles a millisecond). A tab that's hidden pauses; and after
// a stall (a busy host, a debugger) at most 100ms is caught up, the rest
// dropped, rather than racing through minutes of backlog. With Econet on,
// the stations run together in lockstep on one line (BeebNetwork); without,
// each runs alone.
//
// Keys: presses and releases go into a queue per station, in the order
// they came, and each is applied at a cycle between batches (a batch is
// split to reach it). A release comes at least 40ms of BBC time after its
// press, and a press 20ms after the release before it, so that the OS's
// keyboard scan sees every key however quickly the host sent them (as
// BeebCore's own typing does). Nothing is dropped.

import { BeebModule, type BeebMachine, type BeebNetwork, WasiExit } from "./beeb-wasm.ts";
import type { FromWorker, NetworkStatus, StationStatus, Stats, ToWorker } from "./messages.ts";
import { createRoom, joinRoom, RoomAPI, RoomConnection, type RoomCredentials, type StationClaim } from "./room.ts";

const CYCLES_PER_MS = 2000;
const MAX_CATCH_UP_MS = 100;
const TICK_MS = 5;
const KEY_HOLD_CYCLES = 40 * CYCLES_PER_MS;
const KEY_GAP_CYCLES = 20 * CYCLES_PER_MS;

interface Station {
  id: number;
  generation: number;
  machine: BeebMachine | null;
  context: OffscreenCanvasRenderingContext2D | null;
  /** No OffscreenCanvas: send the page the pixels. */
  sendsFrames: boolean;
  drawnFrame: number;
  econet: number | null;
  claim: Omit<StationClaim, "station"> | null;
  keys: { code: number; down: boolean }[];
  pressedAt: Map<number, number>;
  lastReleaseAt: number;
}

let module: BeebModule | null = null;
const stations = new Map<number, Station>();
let selected = 1;
let paused = false;
let hidden = false;

let network: BeebNetwork | null = null;
let room: RoomConnection | null = null;

/** The gamepads, as the selected station's joysticks: kept, for a machine powered on or chosen later. */
const joysticks = [{ x: 0, y: 0, fire: false }, { x: 0, y: 0, fire: false }];
/** The machine they're plugged into now. */
let joystickMachine: BeebMachine | null = null;

let audio: { port: MessagePort; rate: number } | null = null;
/** The station making the sound now, and its machine. */
let audible: BeebMachine | null = null;

let lastTick = 0;
let owed = 0;
const window_ = { started: 0, drawn: 0, fieldsAt: 0, requested: 0, executed: 0, audio: 0, runs: [] as number[] };
let droppedMs = 0;

function post(message: FromWorker, transfer: Transferable[] = []) {
  (self as unknown as Worker).postMessage(message, transfer);
}

function fail(error: unknown) {
  const fatal = module?.failed != null || error instanceof WasiExit;
  post({ type: "error", message: error instanceof Error ? error.message : String(error), fatal });
  if (fatal) for (const s of stations.values()) s.machine = null;
}

function station(id: number): Station {
  let s = stations.get(id);
  if (!s) {
    s = { id, generation: -1, machine: null, context: null, sendsFrames: false, drawnFrame: -1, econet: null, claim: null,
          keys: [], pressedAt: new Map(), lastReleaseAt: -Infinity };
    stations.set(id, s);
  }
  return s;
}

/** The station a message is for, if it's for the machine that's running there now. */
function current(message: { station: number; generation: number }): Station | null {
  const s = stations.get(message.station);
  return s?.machine && s.generation === message.generation ? s : null;
}

// MARK: Keys

/** Applies a station's key events that are due; returns cycles until its next (Infinity: none). */
function applyKeys(s: Station): number {
  while (s.machine && s.keys.length) {
    const event = s.keys[0];
    const now = s.machine.cycles;
    const due = event.down ? s.lastReleaseAt + KEY_GAP_CYCLES : (s.pressedAt.get(event.code) ?? -Infinity) + KEY_HOLD_CYCLES;
    if (now < due) return Math.ceil(due - now);
    s.keys.shift();
    s.machine.setKey(event.code, event.down);
    if (event.down) {
      s.pressedAt.set(event.code, now);
    } else {
      s.pressedAt.delete(event.code);
      s.lastReleaseAt = now;
    }
  }
  return Infinity;
}

function forgetKeys(s: Station) {
  s.keys = [];
  s.pressedAt.clear();
  s.lastReleaseAt = -Infinity;
}

// MARK: Running

/** Runs every station `cycles`, splitting at key events; returns the cycles run (per station). */
function runStations(cycles: number): number {
  const running = [...stations.values()].filter((s) => s.machine);
  if (network) {
    let ran = 0;
    while (ran < cycles) {
      const next = Math.min(...running.map(applyKeys));
      ran += network.run(Math.max(1, Math.min(cycles - ran, next)));
      for (const message of network.take()) room?.send(message);
    }
    running.forEach(applyKeys);
    return ran;
  }
  let least = cycles;
  for (const s of running) {
    let ran = 0;
    while (ran < cycles) {
      const piece = Math.min(cycles - ran, applyKeys(s));
      const done = s.machine!.run(piece);
      ran += done;
      // A debugger stop runs short.
      if (done < piece) break;
    }
    applyKeys(s);
    least = Math.min(least, ran);
  }
  return least;
}

function present(s: Station) {
  if (!s.machine) return;
  const count = s.machine.frameCount;
  if (count === s.drawnFrame) return;
  s.drawnFrame = count;
  const pixels = s.machine.frame();
  if (s.context) {
    s.context.putImageData(new ImageData(pixels, module!.videoWidth, module!.videoHeight), 0, 0);
  } else if (s.sendsFrames) {
    const copy = pixels.slice().buffer;
    post({ type: "frame", station: s.id, generation: s.generation, frame: copy }, [copy]);
  }
  window_.drawn++;
}

/** Sound comes from the selected station. */
function updateAudio() {
  const machine = audio ? (stations.get(selected)?.machine ?? null) : null;
  if (machine === audible) return;
  audible?.startAudio(0);
  audible = machine;
  audible?.startAudio(audio!.rate);
}

/** The joysticks go to the selected station (and are centred on the one before). */
function updateJoysticks() {
  const machine = stations.get(selected)?.machine ?? null;
  if (machine !== joystickMachine && joystickMachine && [...stations.values()].some((s) => s.machine === joystickMachine)) {
    for (const index of [0, 1] as const) joystickMachine.setJoystick(index, 0, 0, false);
  }
  joystickMachine = machine;
  for (const [index, stick] of joysticks.entries()) machine?.setJoystick(index as 0 | 1, stick.x, stick.y, stick.fire);
}

function pumpAudio() {
  if (!audio || !audible) return;
  const samples = audible.readAudio(16384);
  if (samples.length === 0) return;
  window_.audio += samples.length;
  audio.port.postMessage(samples, [samples.buffer]);
}

function tick() {
  setTimeout(tick, TICK_MS);
  const now = performance.now();
  let elapsed = now - lastTick;
  lastTick = now;
  if (stations.size === 0 || paused || hidden) {
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
      const ran = runStations(requested);
      window_.runs.push(performance.now() - started);
      owed = ran < requested ? 0 : owed - ran;
      window_.requested += requested;
      window_.executed += ran;
    }
    for (const s of stations.values()) present(s);
    pumpAudio();
    if (now - window_.started >= 500) report(now);
  } catch (error) {
    fail(error);
  }
}

function report(now: number) {
  const seconds = (now - window_.started) / 1000;
  const runs = window_.runs.sort((a, b) => a - b);
  const fields = stations.get(selected)?.machine?.frameCount ?? 0;
  const stats: Stats = {
    drawnPerSecond: window_.drawn / seconds,
    fieldsPerSecond: Math.max(0, fields - window_.fieldsAt) / seconds,
    requestedPerSecond: window_.requested / seconds,
    executedPerSecond: window_.executed / seconds,
    runMedian: runs.length ? runs[runs.length >> 1] : 0,
    run95: runs.length ? runs[Math.min(runs.length - 1, Math.floor(runs.length * 0.95))] : 0,
    speed: window_.executed / seconds / (CYCLES_PER_MS * 1000),
    memoryBytes: module?.memory.buffer.byteLength ?? 0,
    droppedMs,
    audioPerSecond: window_.audio / seconds,
  };
  const list: StationStatus[] = [];
  for (const s of stations.values()) {
    if (s.machine) list.push({ station: s.id, generation: s.generation, cycles: s.machine.cycles, lights: s.machine.status });
  }
  let net: NetworkStatus | null = null;
  if (network) {
    net = { frames: network.frames, collisions: network.collisions, gateway: room ? network.gatewayStatus : null };
  }
  post({ type: "status", running: !paused && !hidden, paused, stations: list, stats, network: net });
  Object.assign(window_, { started: now, drawn: 0, fieldsAt: fields, requested: 0, executed: 0, audio: 0, runs: [] });
}

// MARK: Econet

function setEconet(on: boolean, clock: number) {
  if (network && !on) {
    leaveRoom(false);
    network.release();
    network = null;
  } else if (on && !network) {
    network = module!.createNetwork(clock);
    for (const s of stations.values()) if (s.machine) network.add(s.machine);
  }
}

function claims(): StationClaim[] {
  return [...stations.values()].filter((s) => s.machine && s.econet && s.claim).map((s) => ({ station: s.econet!, ...s.claim! }));
}

function startRoom(credentials: RoomCredentials) {
  if (!network) throw new Error("Turn Econet on to join a room");
  leaveRoom(false);
  network.attachGateway();
  network.setSharedStations(null);
  const connection = new RoomConnection(credentials, claims());
  connection.onTraffic = (message) => {
    try {
      network?.receive(message);
    } catch (error) {
      console.warn("[beeb] a message from the room the gateway refused", error);
    }
  };
  connection.onChange = (snapshot) => {
    network?.setRemoteStations(connection.remoteStations);
    post({ type: "room", snapshot });
    if (snapshot.state.kind === "ended") post({ type: "roomCredentials", credentials: null });
  };
  room = connection;
  connection.start();
}

function leaveRoom(forget: boolean) {
  room?.stop();
  room = null;
  network?.attachGateway(false);
  post({ type: "room", snapshot: null });
  if (forget) post({ type: "roomCredentials", credentials: null });
}

async function roomCommand(message: ToWorker & { type: "room" }) {
  switch (message.action) {
    case "create": {
      const credentials = await createRoom(message.service, message.name, message.displayName);
      post({ type: "roomCredentials", credentials });
      startRoom(credentials);
      break;
    }
    case "join": {
      const credentials = await joinRoom(message.service, message.invitation, message.displayName);
      post({ type: "roomCredentials", credentials });
      startRoom(credentials);
      break;
    }
    case "connect":
      startRoom(message.credentials);
      break;
    case "leave":
    case "close": {
      const credentials = room?.credentials;
      leaveRoom(true);
      if (credentials) {
        const api = new RoomAPI(credentials.service);
        if (message.action === "close" && credentials.ownerToken) await api.close(credentials.roomId, credentials.ownerToken);
        else await api.leave(credentials.roomId, credentials.memberToken);
      }
      break;
    }
  }
}

// MARK: Messages

async function init(wasmUrl: string) {
  const started = performance.now();
  const response = await fetch(wasmUrl);
  if (!response.ok) throw new Error(`couldn't fetch the WebAssembly module (${response.status})`);
  const bytes = await response.arrayBuffer();
  module = await BeebModule.load(bytes, { stdout: (t) => console.log("[beeb]", t), stderr: (t) => console.warn("[beeb]", t) });
  post({ type: "ready", wasmBytes: bytes.byteLength, loadMs: performance.now() - started });
  lastTick = performance.now();
  window_.started = lastTick;
  tick();
}

function power(message: ToWorker & { type: "power" }) {
  if (!module) throw new Error("the WebAssembly module isn't loaded");
  const started = performance.now();
  const s = station(message.station);
  if (s.machine) {
    if (network) network.remove(s.machine);
    if (audible === s.machine) audible = null;
    s.machine.release();
    s.machine = null;
  }
  const m = module.createMachine(message.model);
  try {
    for (const rom of message.roms) m.loadROM(rom.slot, new Uint8Array(rom.bytes));
    if (message.econet) m.setEconetStation(message.econet);
    if (message.tube) m.setSecondProcessor(new Uint8Array(message.tube));
    if (message.nula) m.setVideoNuLA(true);
    m.powerOn();
  } catch (error) {
    m.release();
    throw error;
  }
  Object.assign(s, { machine: m, generation: message.generation, drawnFrame: -1, econet: message.econet, claim: message.claim });
  forgetKeys(s);
  network?.add(m);
  owed = 0;
  updateAudio();
  updateJoysticks();
  room?.setClaims(claims());
  post({ type: "powered", station: s.id, generation: s.generation, createMs: performance.now() - started });
}

function removeStation(id: number) {
  const s = stations.get(id);
  if (!s) return;
  if (s.machine) {
    if (network) network.remove(s.machine);
    if (audible === s.machine) audible = null;
    s.machine.release();
  }
  stations.delete(id);
  updateAudio();
  room?.setClaims(claims());
}

self.onmessage = async (event: MessageEvent<ToWorker>) => {
  const message = event.data;
  try {
    switch (message.type) {
      case "init":
        await init(message.wasmUrl);
        break;
      case "canvas": {
        const s = station(message.station);
        s.context = message.canvas?.getContext("2d") ?? null;
        s.sendsFrames = message.canvas === null;
        s.drawnFrame = -1;
        break;
      }
      case "power":
        power(message);
        break;
      case "removeStation":
        removeStation(message.station);
        break;
      case "select":
        selected = message.station;
        updateAudio();
        updateJoysticks();
        break;
      case "key": {
        const s = current(message);
        if (s) {
          s.keys.push({ code: message.code, down: message.down });
          applyKeys(s);
        }
        break;
      }
      case "releaseKeys": {
        const s = current(message);
        if (s) {
          forgetKeys(s);
          s.machine!.releaseAllKeys();
        }
        break;
      }
      case "reset":
        current(message)?.machine!.reset(message.kind);
        break;
      case "typeText":
        current(message)?.machine!.type(message.text);
        break;
      case "insertDisc":
        current(message)?.machine!.insertDisc(message.drive, message.format, new Uint8Array(message.bytes));
        break;
      case "ejectDisc":
        current(message)?.machine!.ejectDisc(message.drive);
        break;
      case "exportDisc": {
        const image = current(message)?.machine!.exportDisc(message.drive, message.format) ?? null;
        post({ type: "reply", id: message.id, value: image?.buffer ?? null }, image ? [image.buffer as ArrayBuffer] : []);
        break;
      }
      case "saveState": {
        const state = current(message)?.machine!.saveState() ?? null;
        post({ type: "reply", id: message.id, value: state?.buffer ?? null }, state ? [state.buffer as ArrayBuffer] : []);
        break;
      }
      case "restoreState": {
        if (!module) break;
        const s = station(message.station);
        if (!s.machine) {
          s.machine = module.createMachine();
          network?.add(s.machine);
        }
        s.machine.restoreState(new Uint8Array(message.bytes));
        Object.assign(s, { generation: message.generation, drawnFrame: -1 });
        forgetKeys(s);
        owed = 0;
        if (audible === s.machine) {
          audible = null;
          updateAudio();
        }
        post({ type: "powered", station: s.id, generation: s.generation, createMs: 0 });
        break;
      }
      case "query": {
        const s = current(message);
        let value: unknown = null;
        if (s) value = message.what === "screenText" ? s.machine!.screenText() : s.machine!.cpu;
        post({ type: "reply", id: message.id, value });
        break;
      }
      case "joystick":
        joysticks[message.index] = { x: message.x, y: message.y, fire: message.fire };
        updateJoysticks();
        break;
      case "audio":
        audible?.startAudio(0);
        audible = null;
        audio = message.port ? { port: message.port, rate: message.rate } : null;
        updateAudio();
        break;
      case "econet":
        setEconet(message.on, message.clock);
        break;
      case "room":
        await roomCommand(message);
        break;
      case "pause":
        paused = message.paused;
        report(performance.now());
        break;
      case "hidden":
        hidden = message.hidden;
        break;
    }
  } catch (error) {
    fail(error);
  }
};
