// The Distributed Mandelbrot page: MacBeeb's Network Studio demo, in the
// browser. The same worker as the single-BBC page runs the network: a
// Guide (station 1), workers (2 up), and a Level 2 file server (254, with a
// 6502 Second Processor), all Model Bs with DNFS on one Econet. This page
// powers them on, starts the server as its manual says, boots the Guide's
// disc, and offers the Guide's two commands.

import wasmUrl from "../../.build-wasm/beeb.wasm?url";
import workletUrl from "./audio-worklet.ts?worker&url";
import { DiscFormat, Model, Reset } from "./beeb-wasm.ts";
import { bundledDisc, bundledROM } from "./bundled.ts";
import { KeyboardTranslator } from "./keys.ts";
import type { FromWorker, ToWorker } from "./messages.ts";

const GUIDE = 1;
const SERVER = 254;
const ECONET_CLOCK = 200_000;

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const versionSelect = $<HTMLSelectElement>("version");
const workersSelect = $<HTMLSelectElement>("workers");
const startButton = $<HTMLButtonElement>("start");
const pauseButton = $<HTMLButtonElement>("pause");
const soundButton = $<HTMLButtonElement>("sound");
const clusterButton = $<HTMLButtonElement>("cluster");
const mandelButton = $<HTMLButtonElement>("mandel");
const stateText = $("state");
const networkStats = $("network-stats");
const workersGrid = $("workers-grid");

const worker = new Worker(new URL("./beeb-worker.ts", import.meta.url), { type: "module" });
const send = (message: ToWorker, transfer: Transferable[] = []) => worker.postMessage(message, transfer);
const replies = new Map<number, (value: unknown) => void>();
let nextReply = 1;
function ask<T>(make: (id: number) => ToWorker): Promise<T> {
  const id = nextReply++;
  return new Promise((resolve) => {
    replies.set(id, resolve as (value: unknown) => void);
    send(make(id));
  });
}

interface Station {
  id: number;
  figure: HTMLElement;
  canvas: HTMLCanvasElement;
  generation: number;
  powered: boolean;
  translator: KeyboardTranslator;
  context: CanvasRenderingContext2D | null;
}

const stations = new Map<number, Station>();
let selectedId = GUIDE;
let paused = false;
let ready = false;
const target = (s: Station) => ({ station: s.id, generation: s.generation });

function addStation(id: number, figure: HTMLElement): Station {
  const canvas = figure.querySelector("canvas")!;
  const s: Station = { id, figure, canvas, generation: 0, powered: false, translator: new KeyboardTranslator(), context: null };
  stations.set(id, s);
  if (typeof canvas.transferControlToOffscreen === "function") {
    const offscreen = canvas.transferControlToOffscreen();
    send({ type: "canvas", station: id, canvas: offscreen }, [offscreen]);
  } else {
    s.context = canvas.getContext("2d");
    send({ type: "canvas", station: id, canvas: null });
  }
  const key = (event: KeyboardEvent, down: boolean) => {
    if (event.metaKey) return;
    if (s.translator.translate(event)) event.preventDefault();
    if (!s.powered) return;
    for (const a of down ? s.translator.keyDown(event) : s.translator.keyUp(event)) {
      send({ type: "key", ...target(s), code: a.code, down: a.down });
    }
  };
  canvas.addEventListener("keydown", (e) => key(e, true));
  canvas.addEventListener("keyup", (e) => key(e, false));
  canvas.addEventListener("blur", () => {
    if (!s.translator.holding) return;
    s.translator.reset();
    send({ type: "releaseKeys", ...target(s) });
  });
  canvas.addEventListener("focus", () => select(id));
  figure.addEventListener("pointerdown", () => canvas.focus());
  return s;
}

function select(id: number) {
  selectedId = id;
  for (const s of stations.values()) s.figure.classList.toggle("selected", s.id === id);
  send({ type: "select", station: id });
}

/** The workers' screens, stations 2 up. */
function layOutWorkers(count: number) {
  for (const s of [...stations.values()]) {
    if (s.id !== GUIDE && s.id !== SERVER && s.id > count + 1) {
      send({ type: "removeStation", station: s.id });
      s.figure.remove();
      stations.delete(s.id);
    }
  }
  for (let id = 2; id <= count + 1; id++) {
    if (stations.has(id)) continue;
    const figure = document.createElement("figure");
    figure.className = "station";
    figure.dataset.station = String(id);
    figure.innerHTML = `<div class="bezel"><canvas width="736" height="576" tabindex="0"></canvas></div><figcaption>Station ${id} · worker</figcaption>`;
    workersGrid.append(figure);
    addStation(id, figure);
  }
}

// MARK: Starting the network

let roms: { os: Uint8Array; basic: Uint8Array; dnfs: Uint8Array; tube: Uint8Array } | null = null;
let discs: Record<string, Uint8Array> = {};
let run = 0;

async function loadAssets() {
  const [os, basic, dnfs, tube] = await Promise.all(["os12.rom", "basic2.rom", "dnfs.rom", "tube110.rom"].map(bundledROM));
  if (!os || !basic || !dnfs || !tube) throw new Error("The ROMs didn't load.");
  roms = { os, basic, dnfs, tube };
  const names = ["econet-level2.ssd", "mandelbrot-guide.ssd", "mandelbrot-guide-colour.ssd", "mandelbrot-server.dsd", "mandelbrot-server-colour.dsd"];
  const loaded = await Promise.all(names.map(bundledDisc));
  loaded.forEach((bytes, i) => {
    if (!bytes) throw new Error(`${names[i]} didn't load: build it with make wasm.`);
    discs[names[i]] = bytes;
  });
}

const copy = (bytes: Uint8Array) => bytes.slice().buffer;

function power(s: Station, options: { tube?: boolean; nula?: boolean } = {}) {
  s.generation++;
  s.powered = false;
  const images = [
    { slot: -1, bytes: copy(roms!.os) },
    { slot: 15, bytes: copy(roms!.basic) },
    { slot: 14, bytes: copy(roms!.dnfs) },
  ];
  const tube = options.tube ? copy(roms!.tube) : undefined;
  const role = s.id === SERVER ? "fileServer" : "station";
  const label = s.id === GUIDE ? "Guide" : s.id === SERVER ? "Level 2 file server" : `Worker ${s.id}`;
  send({ type: "power", ...target(s), model: Model.modelB, roms: images, econet: s.id, tube, nula: options.nula,
         claim: { kind: "BBC Model B", label, role } },
       [...images.map((r) => r.bytes), ...(tube ? [tube] : [])]);
}

async function screen(s: Station): Promise<string> {
  return (await ask<string | null>((id) => ({ type: "query", ...target(s), id, what: "screenText" }))) ?? "";
}

/** Waits (polling the screen) for a station's screen to match, while this run lasts. */
async function waitFor(s: Station, pattern: RegExp, thisRun: number): Promise<boolean> {
  while (thisRun === run) {
    if (s.powered && pattern.test(await screen(s))) return true;
    await new Promise((r) => setTimeout(r, 400));
  }
  return false;
}

function step(id: string, state: "now" | "done" | "") {
  const li = $(id);
  li.classList.toggle("now", state === "now");
  li.classList.toggle("done", state === "done");
}

/** Today, in 1988 (the server can't hold this century's years), as it asks for it. */
function serverDate(): string {
  const now = new Date();
  const two = (n: number) => String(n).padStart(2, "0");
  return `${two(now.getDate())}/${two(now.getMonth() + 1)}/88`;
}

async function start() {
  const thisRun = ++run;
  const colour = versionSelect.value === "colour";
  const workers = Number(workersSelect.value);
  clusterButton.disabled = mandelButton.disabled = true;
  mandelButton.textContent = colour ? "Type *MANDEL2" : "Type *MANDEL";
  for (const id of ["step-server", "step-guide", "step-cluster", "step-mandel"]) step(id, "");
  step("step-server", "now");
  layOutWorkers(workers);
  const server = stations.get(SERVER)!, guide = stations.get(GUIDE)!;
  power(server, { tube: true });
  power(guide, { nula: colour });
  for (const s of stations.values()) if (s.id !== GUIDE && s.id !== SERVER) power(s);
  stateText.textContent = "Starting the file server…";

  // The server: its disc in drive 0, the Level 2 utilities in drive 1, and
  // its start-up answers typed (date, one drive, S to start, stations).
  if (!(await waitFor(server, /BASIC\s*\n>/, thisRun))) return;
  const suffix = colour ? "-colour" : "";
  send({ type: "insertDisc", ...target(server), drive: 0, format: DiscFormat.dsd, bytes: copy(discs[`mandelbrot-server${suffix}.dsd`]) });
  send({ type: "insertDisc", ...target(server), drive: 1, format: DiscFormat.ssd, bytes: copy(discs["econet-level2.ssd"]) });
  send({ type: "typeText", ...target(server), text: `*RUN :1.FS\n${serverDate()}\n1\nS\n${workers + 2}\n` });

  // The Guide boots its disc: it logs on (trying until the server's up) and shows what to do.
  if (!(await waitFor(guide, /BASIC\s*\n>/, thisRun))) return;
  send({ type: "insertDisc", ...target(guide), drive: 0, format: DiscFormat.ssd, bytes: copy(discs[`mandelbrot-guide${suffix}.ssd`]) });
  send({ type: "reset", ...target(guide), kind: Reset.shiftBreak });

  if (!(await waitFor(server, /Ready/, thisRun))) return;
  step("step-server", "done");
  step("step-guide", "now");
  stateText.textContent = "The file server's ready.";
  if (!(await waitFor(guide, /\*CLUSTER/, thisRun))) return;
  step("step-guide", "done");
  step("step-cluster", "now");
  clusterButton.disabled = false;
  stateText.textContent = "Ready: *CLUSTER on the Guide.";
  if (!(await waitFor(guide, /workers started/, thisRun))) return;
  step("step-cluster", "done");
  step("step-mandel", "now");
  mandelButton.disabled = false;
  stateText.textContent = `Workers started: ${colour ? "*MANDEL2" : "*MANDEL"} on the Guide.`;
}

clusterButton.addEventListener("click", () => {
  const guide = stations.get(GUIDE)!;
  send({ type: "typeText", ...target(guide), text: "*CLUSTER\n" });
  clusterButton.disabled = true;
  guide.canvas.focus();
});
mandelButton.addEventListener("click", () => {
  const guide = stations.get(GUIDE)!;
  send({ type: "typeText", ...target(guide), text: versionSelect.value === "colour" ? "*MANDEL2\n" : "*MANDEL\n" });
  mandelButton.disabled = true;
  step("step-mandel", "done");
  guide.canvas.focus();
});
startButton.addEventListener("click", () => start().catch(showError));
pauseButton.addEventListener("click", () => {
  paused = !paused;
  send({ type: "pause", paused });
  pauseButton.textContent = paused ? "Resume" : "Pause";
});

// MARK: Sound (the selected station's: the Guide's, to start with)

let audio: AudioContext | null = null;
soundButton.addEventListener("click", async () => {
  const on = soundButton.getAttribute("aria-pressed") !== "true";
  try {
    if (on && !audio) {
      audio = new AudioContext({ latencyHint: "interactive" });
      await audio.audioWorklet.addModule(workletUrl);
      const node = new AudioWorkletNode(audio, "beeb-sound", { numberOfInputs: 0, outputChannelCount: [2] });
      node.connect(audio.destination);
      const channel = new MessageChannel();
      node.port.postMessage({ port: channel.port1 }, [channel.port1]);
      send({ type: "audio", port: channel.port2, rate: audio.sampleRate }, [channel.port2]);
    }
    if (on) await audio!.resume();
    else await audio?.suspend();
    soundButton.setAttribute("aria-pressed", String(on));
    soundButton.textContent = on ? "Sound on" : "Sound off";
  } catch (error) {
    showError(error);
  }
});

// MARK: The worker

worker.onmessage = (event: MessageEvent<FromWorker>) => {
  const message = event.data;
  switch (message.type) {
    case "ready":
      ready = true;
      startButton.disabled = pauseButton.disabled = false;
      send({ type: "econet", on: true, clock: ECONET_CLOCK });
      loadAssets().then(start).catch(showError);
      break;
    case "powered": {
      const s = stations.get(message.station);
      if (s && message.generation === s.generation) s.powered = true;
      break;
    }
    case "status": {
      const { stats, network } = message;
      if (network) {
        networkStats.textContent = `${message.stations.length} BBCs at ${(stats.speed * 100).toFixed(0)}% of real time` +
          ` · ${network.frames.toLocaleString()} frames on the Econet, ${network.collisions} collisions`;
      }
      break;
    }
    case "frame": {
      const s = stations.get(message.station);
      if (s?.context && message.generation === s.generation) {
        s.context.putImageData(new ImageData(new Uint8ClampedArray(message.frame), 736, 576), 0, 0);
      }
      break;
    }
    case "reply":
      replies.get(message.id)?.(message.value);
      replies.delete(message.id);
      break;
    case "error":
      showError(message.message);
      break;
  }
};
worker.onerror = (event) => showError(event.message);

function showError(error: unknown) {
  $("error-text").textContent = error instanceof Error ? error.message : String(error);
  $("error").hidden = false;
}
$("error-dismiss").addEventListener("click", () => ($("error").hidden = true));
document.addEventListener("visibilitychange", () => send({ type: "hidden", hidden: document.hidden }));

addStation(GUIDE, document.querySelector<HTMLElement>("figure.guide")!);
addStation(SERVER, document.querySelector<HTMLElement>("figure.server")!);
select(GUIDE);
send({ type: "init", wasmUrl });

// For the browser tests.
declare global {
  interface Window {
    mandelbrot: {
      screenText(station: number): Promise<string>;
      ready(): boolean;
    };
  }
}
window.mandelbrot = {
  screenText: (id) => screen(stations.get(id)!),
  ready: () => ready,
};
