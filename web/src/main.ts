// The page: ROMs, controls, keyboard and screen. The machine itself runs in
// beeb-worker.ts, so this thread only handles the UI.

import wasmUrl from "../../.build-wasm/beeb.wasm?url";
import { DiscFormat, Model, Reset, Status } from "./beeb-wasm.ts";
import { KeyboardTranslator, type KeyboardMode } from "./keys.ts";
import type { FromWorker, Stats, ToWorker } from "./messages.ts";
import { forgetROMs, loadROMs, saveROMs } from "./rom-store.ts";

interface ROMSlot {
  slot: number;
  label: string;
  /** MacBeeb's name for it (Sources/BeebROMs/ROMs), for development. */
  file: string;
  required: boolean;
  note?: string;
}

const romSets: Record<"modelB" | "master128", { model: Model; slots: ROMSlot[]; formats: string[] }> = {
  modelB: {
    model: Model.modelB,
    formats: ["ssd", "dsd"],
    slots: [
      { slot: -1, label: "OS 1.20", file: "os12.rom", required: true },
      { slot: 15, label: "BASIC II", file: "basic2.rom", required: true },
      { slot: 14, label: "DFS 1.20", file: "dfs12.rom", required: false, note: "for discs" },
    ],
  },
  master128: {
    model: Model.master128,
    formats: ["ssd", "dsd", "adf", "ads", "adm", "adl"],
    slots: [
      // MOS 3.20 is one 128K ROM in eight parts, and the Master needs them all.
      { slot: -1, label: "MOS 3.20", file: "mos320-mos.rom", required: true },
      { slot: 15, label: "Terminal", file: "mos320-terminal.rom", required: true },
      { slot: 14, label: "View", file: "mos320-view.rom", required: true },
      { slot: 13, label: "ADFS 1.50", file: "mos320-adfs.rom", required: true },
      { slot: 12, label: "BASIC IV", file: "mos320-basic4.rom", required: true },
      { slot: 11, label: "Edit", file: "mos320-edit.rom", required: true },
      { slot: 10, label: "ViewSheet", file: "mos320-viewsht.rom", required: true },
      { slot: 9, label: "DFS 2.24", file: "mos320-dfs.rom", required: true },
    ],
  },
};

const MAX_DISC_BYTES = 4 << 20;
const MAX_STATE_BYTES = 64 << 20;
const ROM_BYTES = 16384;

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const canvas = $<HTMLCanvasElement>("screen");
const modelSelect = $<HTMLSelectElement>("model");
const powerButton = $<HTMLButtonElement>("power");
const breakButton = $<HTMLButtonElement>("break");
const ctrlBreakButton = $<HTMLButtonElement>("ctrl-break");
const pauseButton = $<HTMLButtonElement>("pause");
const stateText = $("state");
const romSlots = $("rom-slots");
const rememberROMs = $<HTMLInputElement>("remember-roms");
const devROMsButton = $<HTMLButtonElement>("dev-roms");
const discFile = $<HTMLInputElement>("disc-file");
const discBoot = $<HTMLButtonElement>("disc-boot");
const discEject = $<HTMLButtonElement>("disc-eject");
const discExport = $<HTMLButtonElement>("disc-export");
const discName = $("disc-name");
const typeText = $<HTMLTextAreaElement>("type-text");
const typeButton = $<HTMLButtonElement>("type");
const saveStateButton = $<HTMLButtonElement>("save-state");
const loadStateInput = $<HTMLInputElement>("load-state");
const statsList = $("stats");

/** ROM images chosen, by model then slot. */
const roms: Record<string, Map<number, Uint8Array>> = { modelB: new Map(), master128: new Map() };
let generation = 0;
let powered = false;
let paused = false;
let ready = false;
let lastStatus: (FromWorker & { type: "status" }) | null = null;
let readyInfo: (FromWorker & { type: "ready" }) | null = null;
let discFormat: DiscFormat = DiscFormat.ssd;
let discFileName = "disc.ssd";
const replies = new Map<number, (value: unknown) => void>();
let nextReply = 1;

// MARK: The worker

const worker = new Worker(new URL("./beeb-worker.ts", import.meta.url), { type: "module" });
const send = (message: ToWorker, transfer: Transferable[] = []) => worker.postMessage(message, transfer);

function ask<T>(make: (id: number) => ToWorker): Promise<T> {
  const id = nextReply++;
  return new Promise((resolve) => {
    replies.set(id, resolve as (value: unknown) => void);
    send(make(id));
  });
}

const canTransfer = typeof canvas.transferControlToOffscreen === "function";
const context2d = canTransfer ? null : (canvas as HTMLCanvasElement).getContext("2d");

worker.onmessage = (event: MessageEvent<FromWorker>) => {
  const message = event.data;
  switch (message.type) {
    case "ready":
      ready = true;
      readyInfo = message;
      stateText.textContent = "Choose the ROMs, then power on.";
      updateControls();
      break;
    case "powered":
      if (message.generation !== generation) break;
      powered = true;
      paused = false;
      stateText.textContent = "Running";
      $<HTMLDetailsElement>("roms").open = false;
      canvas.focus();
      updateControls();
      break;
    case "status":
      if (message.generation !== generation) break;
      lastStatus = message;
      showStatus(message.cycles, message.lights, message.stats);
      break;
    case "frame":
      // Without OffscreenCanvas: the worker sends the pixels.
      if (message.generation !== generation || !context2d || !(message.frame instanceof ArrayBuffer)) break;
      context2d.putImageData(new ImageData(new Uint8ClampedArray(message.frame), 736, 576), 0, 0);
      break;
    case "reply":
      replies.get(message.id)?.(message.value);
      replies.delete(message.id);
      break;
    case "error":
      showError(message.message);
      if (message.fatal) {
        powered = false;
        stateText.textContent = "Stopped: reload the page to start again.";
        updateControls();
      }
      break;
  }
};
worker.onerror = (event) => showError(`The emulation worker failed: ${event.message}`);

{
  let offscreen: OffscreenCanvas | null = null;
  if (canTransfer) offscreen = canvas.transferControlToOffscreen();
  send({ type: "init", wasmUrl, canvas: offscreen }, offscreen ? [offscreen] : []);
}

// MARK: ROMs

function currentSet() {
  return romSets[modelSelect.value as keyof typeof romSets];
}

function renderROMSlots() {
  const set = currentSet();
  const chosen = roms[modelSelect.value];
  romSlots.replaceChildren();
  for (const slot of set.slots) {
    const label = document.createElement("label");
    label.htmlFor = `rom-${slot.slot}`;
    label.textContent = `${slot.label}${slot.required ? "" : ` (optional${slot.note ? `, ${slot.note}` : ""})`}`;
    const cell = document.createElement("span");
    const input = document.createElement("input");
    input.type = "file";
    input.id = `rom-${slot.slot}`;
    input.dataset.slot = String(slot.slot);
    input.accept = ".rom,.bin";
    input.addEventListener("change", () => chooseROM(slot, input));
    const status = document.createElement("span");
    status.className = chosen.has(slot.slot) ? "ok" : "";
    status.textContent = chosen.has(slot.slot) ? " ✓ 16K" : "";
    cell.append(input, status);
    romSlots.append(label, cell);
  }
  updateControls();
}

async function chooseROM(slot: ROMSlot, input: HTMLInputElement) {
  const file = input.files?.[0];
  if (!file) return;
  if (file.size !== ROM_BYTES) {
    showError(`${file.name} isn't a 16K ROM image (it's ${file.size} bytes).`);
    input.value = "";
    return;
  }
  roms[modelSelect.value].set(slot.slot, new Uint8Array(await file.arrayBuffer()));
  if (rememberROMs.checked) await saveROMs(roms);
  renderROMSlots();
}

function romsReady() {
  const chosen = roms[modelSelect.value];
  return currentSet().slots.every((s) => !s.required || chosen.has(s.slot));
}

rememberROMs.addEventListener("change", async () => {
  if (rememberROMs.checked) await saveROMs(roms);
  else await forgetROMs();
});

// Development: MacBeeb's ROMs from the repository (vite.config.ts serves
// them only with MACBEEB_DEV_ROMS=1, and never in a build).
if (import.meta.env.DEV) {
  fetch("/__dev-roms/").then((r) => {
    if (r.ok) devROMsButton.hidden = false;
  }, () => {});
  devROMsButton.addEventListener("click", async () => {
    for (const [name, set] of Object.entries(romSets)) {
      for (const slot of set.slots) {
        const response = await fetch(`/__dev-roms/${slot.file}`);
        if (response.ok) roms[name].set(slot.slot, new Uint8Array(await response.arrayBuffer()));
      }
    }
    renderROMSlots();
  });
}

// MARK: Controls

function updateControls() {
  powerButton.disabled = !ready || !romsReady();
  powerButton.textContent = powered ? "Power cycle" : "Power on";
  for (const b of [breakButton, ctrlBreakButton, pauseButton, discBoot, typeButton, saveStateButton]) b.disabled = !powered;
  loadStateInput.disabled = !ready;
  discEject.disabled = discExport.disabled = !powered || !discName.textContent;
  pauseButton.textContent = paused ? "Resume" : "Pause";
  discFile.accept = currentSet().formats.map((f) => `.${f}`).join(",");
}

function powerOn() {
  generation++;
  powered = false;
  const set = currentSet();
  const chosen = roms[modelSelect.value];
  const images = [...chosen.entries()]
    .filter(([slot]) => set.slots.some((s) => s.slot === slot))
    .map(([slot, bytes]) => ({ slot, bytes: bytes.slice().buffer }));
  send({ type: "power", generation, model: set.model, roms: images }, images.map((r) => r.bytes));
  discName.textContent = "";
  stateText.textContent = "Powering on…";
  updateControls();
}

powerButton.addEventListener("click", powerOn);
breakButton.addEventListener("click", () => send({ type: "reset", generation, kind: Reset.break }));
ctrlBreakButton.addEventListener("click", () => send({ type: "reset", generation, kind: Reset.ctrlBreak }));
pauseButton.addEventListener("click", () => {
  paused = !paused;
  send({ type: "pause", paused });
  stateText.textContent = paused ? "Paused" : "Running";
  updateControls();
  if (!paused) canvas.focus();
});
modelSelect.addEventListener("change", () => {
  renderROMSlots();
});

// MARK: Discs

const formatsByExtension: Record<string, DiscFormat> = {
  ssd: DiscFormat.ssd, dsd: DiscFormat.dsd, adf: DiscFormat.adf, ads: DiscFormat.adf, adm: DiscFormat.adf,
  adl: DiscFormat.adl,
};

discFile.addEventListener("change", async () => {
  const file = discFile.files?.[0];
  discFile.value = "";
  if (!file || !powered) return;
  const extension = file.name.split(".").pop()?.toLowerCase() ?? "";
  const format = formatsByExtension[extension];
  if (format === undefined || !currentSet().formats.includes(extension)) {
    showError(`This machine can't read .${extension} discs.`);
    return;
  }
  if (file.size > MAX_DISC_BYTES) {
    showError(`${file.name} is too big for a disc image.`);
    return;
  }
  const bytes = await file.arrayBuffer();
  discFormat = format;
  discFileName = file.name;
  send({ type: "insertDisc", generation, drive: 0, format, bytes }, [bytes]);
  discName.textContent = `Drive 0: ${file.name}`;
  updateControls();
  canvas.focus();
});
discBoot.addEventListener("click", () => {
  send({ type: "reset", generation, kind: Reset.shiftBreak });
  canvas.focus();
});
discEject.addEventListener("click", () => {
  send({ type: "ejectDisc", generation, drive: 0 });
  discName.textContent = "";
  updateControls();
});
discExport.addEventListener("click", async () => {
  const image = await ask<ArrayBuffer | null>((id) => ({ type: "exportDisc", generation, id, drive: 0, format: discFormat }));
  if (image) download(new Blob([image]), discFileName);
});

// MARK: Typing and states

typeButton.addEventListener("click", () => {
  const text = typeText.value.replace(/\r\n?/g, "\n");
  if (!text) return;
  send({ type: "typeText", generation, text: text.endsWith("\n") ? text : `${text}\n` });
  canvas.focus();
});
saveStateButton.addEventListener("click", async () => {
  const state = await ask<ArrayBuffer | null>((id) => ({ type: "saveState", generation, id }));
  if (state) download(new Blob([state]), "macbeeb.beebstate");
});
loadStateInput.addEventListener("change", async () => {
  const file = loadStateInput.files?.[0];
  loadStateInput.value = "";
  if (!file) return;
  if (file.size > MAX_STATE_BYTES) {
    showError(`${file.name} is too big for a save state.`);
    return;
  }
  generation++;
  const bytes = await file.arrayBuffer();
  send({ type: "restoreState", generation, bytes }, [bytes]);
});

function download(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// MARK: Keyboard

const keyboardMode = $<HTMLSelectElement>("keyboard-mode");
const translator = new KeyboardTranslator(keyboardMode.value as KeyboardMode);
keyboardMode.addEventListener("change", () => {
  releaseAll();
  translator.mode = keyboardMode.value as KeyboardMode;
});

function key(event: KeyboardEvent, down: boolean) {
  if (event.metaKey) return;
  // Everything the BBC has a key for is its, not the browser's.
  if (translator.translate(event)) event.preventDefault();
  if (!powered) return;
  for (const action of down ? translator.keyDown(event) : translator.keyUp(event)) {
    send({ type: "key", generation, code: action.code, down: action.down });
  }
}

function releaseAll() {
  if (!translator.holding) return;
  translator.reset();
  send({ type: "releaseKeys", generation });
}

canvas.addEventListener("keydown", (e) => key(e, true));
canvas.addEventListener("keyup", (e) => key(e, false));
canvas.addEventListener("blur", () => {
  releaseAll();
  canvas.classList.remove("focused");
});
canvas.addEventListener("focus", () => canvas.classList.add("focused"));
canvas.addEventListener("pointerdown", () => canvas.focus());
window.addEventListener("blur", releaseAll);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) releaseAll();
  send({ type: "hidden", hidden: document.hidden });
});

// MARK: Status

function showStatus(cycles: number, lights: number, stats: Stats) {
  $("light-caps").classList.toggle("on", (lights & Status.capsLock) !== 0);
  $("light-shift").classList.toggle("on", (lights & Status.shiftLock) !== 0);
  $("light-drive").classList.toggle("on", (lights & (Status.drive0 | Status.drive1)) !== 0);
  if (!paused && powered) stateText.textContent = `Running at ${(stats.speed * 100).toFixed(0)}%`;
  const rows: [string, string][] = [
    ["BBC time", `${(cycles / 2e6).toFixed(1)}s (${cycles.toLocaleString()} cycles)`],
    ["Speed", `${(stats.speed * 100).toFixed(1)}% of a real BBC`],
    ["Cycles/s requested, run", `${Math.round(stats.requestedPerSecond).toLocaleString()}, ${Math.round(stats.executedPerSecond).toLocaleString()}`],
    ["BBC fields/s", stats.fieldsPerSecond.toFixed(1)],
    ["Frames drawn/s", stats.drawnPerSecond.toFixed(1)],
    ["Batch time, median / 95th", `${stats.runMedian.toFixed(2)}ms / ${stats.run95.toFixed(2)}ms`],
    ["Real time dropped", `${stats.droppedMs.toFixed(0)}ms`],
    ["WebAssembly memory", `${(stats.memoryBytes / 1048576).toFixed(1)}MB`],
    ["Module", readyInfo ? `${(readyInfo.wasmBytes / 1048576).toFixed(1)}MB, loaded in ${readyInfo.loadMs.toFixed(0)}ms` : ""],
    ["Drawing", readyInfo?.offscreen ? "OffscreenCanvas, in the worker" : "on the page"],
  ];
  statsList.replaceChildren(...rows.flatMap(([k, v]) => {
    const dt = document.createElement("dt");
    dt.textContent = k;
    const dd = document.createElement("dd");
    dd.textContent = v;
    return [dt, dd];
  }));
}

function showError(text: string) {
  $("error-text").textContent = text;
  $("error").hidden = false;
}
$("error-dismiss").addEventListener("click", () => ($("error").hidden = true));

// MARK: Start

loadROMs().then((saved) => {
  if (saved) {
    for (const [model, slots] of Object.entries(saved)) for (const [slot, bytes] of slots) roms[model]?.set(slot, bytes);
    rememberROMs.checked = true;
  }
  renderROMSlots();
});
renderROMSlots();

// For the browser tests: what the machine shows, without scraping pixels.
declare global {
  interface Window {
    macbeeb: {
      screenText(): Promise<string | null>;
      cpu(): Promise<unknown>;
      status(): typeof lastStatus;
      powered(): boolean;
    };
  }
}
window.macbeeb = {
  screenText: () => ask((id) => ({ type: "query", generation, id, what: "screenText" })),
  cpu: () => ask((id) => ({ type: "query", generation, id, what: "cpu" })),
  status: () => lastStatus,
  powered: () => powered,
};
