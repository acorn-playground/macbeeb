// The page: ROMs, controls, keyboard, sound, joysticks, Econet and the
// stations' screens. The machines themselves run in beeb-worker.ts, so this
// thread only handles the UI.

import wasmUrl from "../../.build-wasm/beeb.wasm?url";
import workletUrl from "./audio-worklet.ts?worker&url";
import { DiscFormat, Model, Reset, Status } from "./beeb-wasm.ts";
import { KeyboardTranslator, type KeyboardMode } from "./keys.ts";
import type { FromWorker, Stats, StationStatus, ToWorker } from "./messages.ts";
import { bundledROM, fileServerDisc } from "./bundled.ts";
import { forgetROMs, loadROMs, saveROMs } from "./rom-store.ts";
import { OFFICIAL_SERVICE, serviceOrigin, type RoomCredentials, type RoomSnapshot } from "./room.ts";

type ModelName = "modelB" | "master128";

interface ROMSlot {
  /** Where it's kept and its input's id: the bank, or a name for one that shares a bank. */
  key: string;
  slot: number;
  label: string;
  /** MacBeeb's name for it (Sources/BeebROMs/ROMs), for development. */
  file: string;
  required: boolean;
  note?: string;
  /** Only with Econet on (and then needed), or only with it off. */
  econet?: "with" | "without";
}

const romSets: Record<ModelName, { model: Model; name: string; slots: ROMSlot[]; formats: string[] }> = {
  modelB: {
    model: Model.modelB,
    name: "BBC Model B",
    formats: ["ssd", "dsd"],
    slots: [
      { key: "-1", slot: -1, label: "OS 1.20", file: "os12.rom", required: true },
      { key: "15", slot: 15, label: "BASIC II", file: "basic2.rom", required: true },
      { key: "14", slot: 14, label: "DFS 1.20", file: "dfs12.rom", required: false, note: "for discs", econet: "without" },
      // DNFS has DFS 1.20 in it too, so it takes DFS's place.
      { key: "dnfs", slot: 14, label: "DNFS 3.60", file: "dnfs.rom", required: true, note: "for Econet, and discs", econet: "with" },
    ],
  },
  master128: {
    model: Model.master128,
    name: "BBC Master 128",
    formats: ["ssd", "dsd", "adf", "ads", "adm", "adl"],
    slots: [
      // MOS 3.20 is one 128K ROM in eight parts, and the Master needs them all.
      { key: "-1", slot: -1, label: "MOS 3.20", file: "mos320-mos.rom", required: true },
      { key: "15", slot: 15, label: "Terminal", file: "mos320-terminal.rom", required: true },
      { key: "14", slot: 14, label: "View", file: "mos320-view.rom", required: true },
      { key: "13", slot: 13, label: "ADFS 1.50", file: "mos320-adfs.rom", required: true },
      { key: "12", slot: 12, label: "BASIC IV", file: "mos320-basic4.rom", required: true },
      { key: "11", slot: 11, label: "Edit", file: "mos320-edit.rom", required: true },
      { key: "10", slot: 10, label: "ViewSheet", file: "mos320-viewsht.rom", required: true },
      { key: "9", slot: 9, label: "DFS 2.24", file: "mos320-dfs.rom", required: true },
      { key: "anfs", slot: 8, label: "ANFS 4.25", file: "anfs425.rom", required: true, note: "for Econet", econet: "with" },
    ],
  },
};

const MAX_DISC_BYTES = 4 << 20;
const MAX_STATE_BYTES = 64 << 20;
const ROM_BYTES = 16384;
const ECONET_CLOCK = 200_000;
const ROOM_STORAGE = "macbeeb-web-room";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const modelSelect = $<HTMLSelectElement>("model");
const powerButton = $<HTMLButtonElement>("power");
const breakButton = $<HTMLButtonElement>("break");
const ctrlBreakButton = $<HTMLButtonElement>("ctrl-break");
const pauseButton = $<HTMLButtonElement>("pause");
const stateText = $("state");
const romSlots = $("rom-slots");
const rememberROMs = $<HTMLInputElement>("remember-roms");
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
const stationsElement = $("stations");
const soundButton = $<HTMLButtonElement>("sound");
const volume = $<HTMLInputElement>("volume");
const soundMeter = $("sound-meter").firstElementChild as HTMLElement;
const gamepadsText = $("gamepads");
const econetOn = $<HTMLInputElement>("econet-on");
const stationNumber = $<HTMLInputElement>("station-number");
const addStationButton = $<HTMLButtonElement>("add-station");
const addFileServerButton = $<HTMLButtonElement>("add-fileserver");
const networkStats = $("network-stats");
const roomService = $<HTMLInputElement>("room-service");
const roomDisplayName = $<HTMLInputElement>("room-display-name");
const roomInvite = $<HTMLInputElement>("room-invite");
const roomJoin = $<HTMLButtonElement>("room-join");
const roomNewName = $<HTMLInputElement>("room-new-name");
const roomCreate = $<HTMLButtonElement>("room-create");
const roomRejoin = $<HTMLButtonElement>("room-rejoin");
const roomLeave = $<HTMLButtonElement>("room-leave");
const roomStatus = $("room-status");

/** ROM images chosen, by model then slot key. */
const roms: Record<ModelName, Map<string, Uint8Array>> = { modelB: new Map(), master128: new Map() };
let ready = false;
let paused = false;
let lastStatus: (FromWorker & { type: "status" }) | null = null;
let readyInfo: (FromWorker & { type: "ready" }) | null = null;
let roomSnapshot: RoomSnapshot | null = null;
let audioPeak = 0;
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

// MARK: Stations

interface PageStation {
  id: number;
  model: ModelName;
  role: "station" | "fileServer";
  econet: number;
  generation: number;
  powered: boolean;
  figure: HTMLElement;
  canvas: HTMLCanvasElement;
  /** Without OffscreenCanvas, the page draws what the worker sends. */
  context: CanvasRenderingContext2D | null;
  disc: { name: string; format: DiscFormat } | null;
  /** A disc to put in once it's on (the file server's). */
  pendingDisc?: { name: string; format: DiscFormat; bytes: Uint8Array };
}

const stations = new Map<number, PageStation>();
let selectedId = 1;
let nextStationId = 2;
const selected = () => stations.get(selectedId)!;
const target = (s: PageStation = selected()) => ({ station: s.id, generation: s.generation });

function attachCanvas(s: PageStation) {
  if (typeof s.canvas.transferControlToOffscreen === "function") {
    const offscreen = s.canvas.transferControlToOffscreen();
    send({ type: "canvas", station: s.id, canvas: offscreen }, [offscreen]);
  } else {
    s.context = s.canvas.getContext("2d");
    send({ type: "canvas", station: s.id, canvas: null });
  }
}

function addStation(id: number, figure: HTMLElement, model: ModelName, role: PageStation["role"], econet: number): PageStation {
  const canvas = figure.querySelector("canvas")!;
  const s: PageStation = { id, model, role, econet, generation: 0, powered: false, figure, canvas, context: null, disc: null };
  stations.set(id, s);
  attachCanvas(s);
  canvas.addEventListener("keydown", (e) => key(s, e, true));
  canvas.addEventListener("keyup", (e) => key(s, e, false));
  canvas.addEventListener("blur", () => {
    releaseAll(s);
    canvas.classList.remove("focused");
  });
  canvas.addEventListener("focus", () => {
    canvas.classList.add("focused");
    select(s.id);
  });
  figure.addEventListener("pointerdown", () => {
    select(s.id);
    canvas.focus();
  });
  caption(s);
  return s;
}

/** A new station's figure and screen. */
function newStationFigure(): HTMLElement {
  const figure = document.createElement("figure");
  figure.className = "station";
  figure.dataset.station = String(nextStationId);
  figure.innerHTML = `<div class="bezel"><canvas width="736" height="576" tabindex="0"></canvas></div><figcaption></figcaption>`;
  stationsElement.append(figure);
  return figure;
}

function caption(s: PageStation) {
  const figcaption = s.figure.querySelector("figcaption")!;
  figcaption.replaceChildren();
  const name = document.createElement("span");
  name.className = "station-name";
  const what = s.role === "fileServer" ? "File server" : romSets[s.model].name;
  name.textContent = econetOn.checked ? `Station ${s.econet} · ${what}` : what;
  figcaption.append(name);
  if (s.disc) {
    const disc = document.createElement("span");
    disc.textContent = `· ${s.disc.name}`;
    figcaption.append(disc);
  }
  if (s.id !== 1) {
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "Remove";
    remove.addEventListener("click", (e) => {
      e.stopPropagation();
      removeStation(s);
    });
    figcaption.append(remove);
  }
  s.canvas.setAttribute("aria-label", `${name.textContent}: click to type`);
}

function select(id: number) {
  if (id === selectedId || !stations.has(id)) return;
  releaseAll(stations.get(selectedId));
  selectedId = id;
  for (const s of stations.values()) s.figure.classList.toggle("selected", s.id === id);
  send({ type: "select", station: id });
  const s = selected();
  stationNumber.value = String(s.econet);
  discName.textContent = s.disc ? `Drive 0: ${s.disc.name}` : "";
  updateControls();
}

function removeStation(s: PageStation) {
  send({ type: "removeStation", station: s.id });
  stations.delete(s.id);
  s.figure.remove();
  if (selectedId === s.id) {
    selectedId = -1;
    select(1);
  }
}

/** A free station number (from `from` up). */
function freeStationNumber(from: number): number {
  const used = new Set([...stations.values()].map((s) => s.econet));
  for (let n = from; n <= 254; n++) if (!used.has(n)) return n;
  return 1;
}

// MARK: ROMs

function slotsFor(model: ModelName, econet: boolean): ROMSlot[] {
  return romSets[model].slots.filter((s) => !s.econet || (s.econet === "with") === econet);
}

function renderROMSlots() {
  const model = modelSelect.value as ModelName;
  const chosen = roms[model];
  romSlots.replaceChildren();
  // All the model's ROMs (Econet's too), so they can be chosen first.
  for (const slot of romSets[model].slots) {
    const label = document.createElement("label");
    label.htmlFor = `rom-${slot.key}`;
    const optional = !slot.required ? ` (optional${slot.note ? `, ${slot.note}` : ""})` : slot.note ? ` (${slot.note})` : "";
    label.textContent = slot.label + optional;
    const cell = document.createElement("span");
    const input = document.createElement("input");
    input.type = "file";
    input.id = `rom-${slot.key}`;
    input.accept = ".rom,.bin";
    input.addEventListener("change", () => chooseROM(model, slot, input));
    const status = document.createElement("span");
    status.className = chosen.has(slot.key) ? "ok" : "";
    status.textContent = chosen.has(slot.key) ? " ✓ 16K" : "";
    cell.append(input, status);
    romSlots.append(label, cell);
  }
  updateControls();
}

async function chooseROM(model: ModelName, slot: ROMSlot, input: HTMLInputElement) {
  const file = input.files?.[0];
  if (!file) return;
  if (file.size !== ROM_BYTES) {
    showError(`${file.name} isn't a 16K ROM image (it's ${file.size} bytes).`);
    input.value = "";
    return;
  }
  roms[model].set(slot.key, new Uint8Array(await file.arrayBuffer()));
  if (rememberROMs.checked) await saveROMs(roms);
  renderROMSlots();
}

function romsReady(model: ModelName): boolean {
  const chosen = roms[model];
  return slotsFor(model, econetOn.checked).every((s) => !s.required || chosen.has(s.key));
}

rememberROMs.addEventListener("change", async () => {
  if (rememberROMs.checked) await saveROMs(roms);
  else await forgetROMs();
});

// MARK: Controls

function updateControls() {
  const s = selected();
  const model = modelSelect.value as ModelName;
  powerButton.disabled = !ready || !romsReady(model);
  powerButton.textContent = s.powered ? "Power cycle" : "Power on";
  for (const b of [breakButton, ctrlBreakButton, pauseButton, discBoot, typeButton, saveStateButton]) b.disabled = !s.powered;
  loadStateInput.disabled = !ready;
  discEject.disabled = discExport.disabled = !s.powered || !s.disc;
  pauseButton.textContent = paused ? "Resume" : "Pause";
  discFile.accept = romSets[s.model].formats.map((f) => `.${f}`).join(",");
  const anyPowered = [...stations.values()].some((x) => x.powered);
  addStationButton.disabled = !ready || !romsReady(model) || !anyPowered;
  addFileServerButton.disabled = !ready || !econetOn.checked || !romsReady("modelB") || !anyPowered;
  const inRoom = roomSnapshot !== null;
  roomJoin.disabled = roomCreate.disabled = !econetOn.checked || !anyPowered || inRoom;
  roomLeave.hidden = !inRoom;
  const saved = storedRoom();
  roomRejoin.hidden = inRoom || !saved;
  roomRejoin.disabled = !econetOn.checked || !anyPowered;
  if (saved) roomRejoin.textContent = `Rejoin ${saved.roomName}`;
}

/** Powers station `s` on (or power cycles it) as its model, with its ROMs. */
function powerOn(s: PageStation) {
  if (!romsReady(s.model)) {
    showError(`Choose the ${romSets[s.model].name}'s ROMs first${econetOn.checked ? " (with its Econet ROM)" : ""}.`);
    return;
  }
  s.generation++;
  s.powered = false;
  const chosen = roms[s.model];
  const images = slotsFor(s.model, econetOn.checked)
    .filter((slot) => chosen.has(slot.key))
    .map((slot) => ({ slot: slot.slot, bytes: chosen.get(slot.key)!.slice().buffer }));
  const econet = econetOn.checked ? s.econet : null;
  const claim = { kind: romSets[s.model].name, label: s.role === "fileServer" ? "File server" : `Station ${s.econet}`, role: s.role };
  send({ type: "power", ...target(s), model: romSets[s.model].model, roms: images, econet, claim }, images.map((r) => r.bytes));
  s.disc = null;
  caption(s);
  if (s === selected()) {
    discName.textContent = "";
    stateText.textContent = "Powering on…";
  }
  updateControls();
}

powerButton.addEventListener("click", () => {
  const s = selected();
  s.model = modelSelect.value as ModelName;
  powerOn(s);
});
breakButton.addEventListener("click", () => send({ type: "reset", ...target(), kind: Reset.break }));
ctrlBreakButton.addEventListener("click", () => send({ type: "reset", ...target(), kind: Reset.ctrlBreak }));
pauseButton.addEventListener("click", () => {
  paused = !paused;
  send({ type: "pause", paused });
  stateText.textContent = paused ? "Paused" : "Running";
  updateControls();
  if (!paused) selected().canvas.focus();
});
modelSelect.addEventListener("change", renderROMSlots);

// MARK: Econet

econetOn.addEventListener("change", () => {
  send({ type: "econet", on: econetOn.checked, clock: ECONET_CLOCK });
  // Every BBC needs its module fitted (or taken out), and its network ROM.
  for (const s of stations.values()) {
    if (s.powered) powerOn(s);
    caption(s);
  }
  renderROMSlots();
});

stationNumber.addEventListener("change", () => {
  const s = selected();
  const n = Math.round(Number(stationNumber.value));
  if (!(n >= 1 && n <= 254) || [...stations.values()].some((x) => x !== s && x.econet === n)) {
    showError("A station number is 1-254, and each station's must be different.");
    stationNumber.value = String(s.econet);
    return;
  }
  s.econet = n;
  caption(s);
  if (econetOn.checked && s.powered) powerOn(s);
});

async function newStation(model: ModelName, role: PageStation["role"], number: number) {
  const figure = newStationFigure();
  const id = nextStationId++;
  const s = addStation(id, figure, model, role, freeStationNumber(number));
  if (role === "fileServer") {
    const bytes = await fileServerDisc();
    if (bytes) s.pendingDisc = { name: "Level 1 file server.ssd", format: DiscFormat.ssd, bytes };
  }
  powerOn(s);
  select(id);
  s.canvas.focus();
}

addStationButton.addEventListener("click", () => newStation(modelSelect.value as ModelName, "station", 2));
addFileServerButton.addEventListener("click", () => newStation("modelB", "fileServer", 254));

// MARK: Internet Econet

function storedRoom(): RoomCredentials | null {
  try {
    const text = localStorage.getItem(ROOM_STORAGE);
    return text ? (JSON.parse(text) as RoomCredentials) : null;
  } catch {
    return null;
  }
}

function storeRoom(credentials: RoomCredentials | null) {
  try {
    if (credentials) localStorage.setItem(ROOM_STORAGE, JSON.stringify(credentials));
    else localStorage.removeItem(ROOM_STORAGE);
  } catch {
    // Not kept: it'll need the invitation again.
  }
}

function displayName(): string {
  return roomDisplayName.value.trim() || "Guest";
}

function service(): string | null {
  try {
    return serviceOrigin(roomService.value || OFFICIAL_SERVICE);
  } catch (error) {
    showError((error as Error).message);
    return null;
  }
}

roomJoin.addEventListener("click", () => {
  const origin = service();
  if (!origin || !roomInvite.value.trim()) return;
  send({ type: "room", action: "join", service: origin, invitation: roomInvite.value.trim(), displayName: displayName() });
});
roomCreate.addEventListener("click", () => {
  const origin = service();
  if (!origin) return;
  send({ type: "room", action: "create", service: origin, name: roomNewName.value.trim() || "A BBC Micro network", displayName: displayName() });
});
roomRejoin.addEventListener("click", () => {
  const credentials = storedRoom();
  if (credentials) send({ type: "room", action: "connect", credentials });
});
roomLeave.addEventListener("click", () => {
  const owner = roomSnapshot?.owner && storedRoom()?.ownerToken;
  send({ type: "room", action: owner ? "close" : "leave" });
});

function showRoom(snapshot: RoomSnapshot | null) {
  roomSnapshot = snapshot;
  roomStatus.hidden = snapshot === null;
  updateControls();
  if (!snapshot) return;
  const state = snapshot.state;
  const parts: string[] = [];
  const name = snapshot.room?.name ?? storedRoom()?.roomName ?? "the room";
  const how = state.kind === "connected" ? `connected${snapshot.rttMs !== null ? ` (${snapshot.rttMs}ms)` : ""}`
    : state.kind === "reconnecting" ? `reconnecting (attempt ${state.attempt})`
    : state.kind === "ended" ? state.reason : state.kind;
  parts.push(`<p><b>${escape(name)}</b>: ${escape(how)}</p>`);
  const invite = storedRoom()?.invite;
  if (snapshot.owner && invite) {
    parts.push(`<p>Invite others with the code <span class="invite">${escape(invite.code)}</span> or the link <span class="invite">${escape(invite.url)}</span></p>`);
  }
  if (snapshot.problem) parts.push(`<p>${escape(snapshot.problem)}</p>`);
  const people = snapshot.participants.map((p) =>
    `<li>${escape(p.name)}${p.id === snapshot.participantId ? " (you)" : ""}${p.owner ? ", the host" : ""}: ${escape(p.app)}${p.online ? "" : ", offline"}</li>`);
  if (people.length) parts.push(`<p>In the room:</p><ul>${people.join("")}</ul>`);
  const list = snapshot.stations.map((s) =>
    `<li>Station ${s.station}: ${escape(s.label)} (${escape(s.kind)})${s.participantId === snapshot.participantId ? ", here" : ""}${s.online ? "" : ", offline"}</li>`);
  if (list.length) parts.push(`<p>Stations:</p><ul>${list.join("")}</ul>`);
  for (const [station, why] of Object.entries(snapshot.refused)) parts.push(`<p>Station ${station} wasn't taken: ${escape(why)}</p>`);
  roomStatus.innerHTML = parts.join("");
}

function escape(text: string): string {
  return text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

// MARK: Discs

const formatsByExtension: Record<string, DiscFormat> = {
  ssd: DiscFormat.ssd, dsd: DiscFormat.dsd, adf: DiscFormat.adf, ads: DiscFormat.adf, adm: DiscFormat.adf,
  adl: DiscFormat.adl,
};

discFile.addEventListener("change", async () => {
  const file = discFile.files?.[0];
  discFile.value = "";
  const s = selected();
  if (!file || !s.powered) return;
  const extension = file.name.split(".").pop()?.toLowerCase() ?? "";
  const format = formatsByExtension[extension];
  if (format === undefined || !romSets[s.model].formats.includes(extension)) {
    showError(`This machine can't read .${extension} discs.`);
    return;
  }
  if (file.size > MAX_DISC_BYTES) {
    showError(`${file.name} is too big for a disc image.`);
    return;
  }
  const bytes = await file.arrayBuffer();
  send({ type: "insertDisc", ...target(s), drive: 0, format, bytes }, [bytes]);
  s.disc = { name: file.name, format };
  discName.textContent = `Drive 0: ${file.name}`;
  caption(s);
  updateControls();
  s.canvas.focus();
});
discBoot.addEventListener("click", () => {
  send({ type: "reset", ...target(), kind: Reset.shiftBreak });
  selected().canvas.focus();
});
discEject.addEventListener("click", () => {
  const s = selected();
  send({ type: "ejectDisc", ...target(s), drive: 0 });
  s.disc = null;
  discName.textContent = "";
  caption(s);
  updateControls();
});
discExport.addEventListener("click", async () => {
  const s = selected();
  if (!s.disc) return;
  const disc = s.disc;
  const image = await ask<ArrayBuffer | null>((id) => ({ type: "exportDisc", ...target(s), id, drive: 0, format: disc.format }));
  if (image) download(new Blob([image]), disc.name);
});

// MARK: Typing and states

typeButton.addEventListener("click", () => {
  const text = typeText.value.replace(/\r\n?/g, "\n");
  if (!text) return;
  send({ type: "typeText", ...target(), text: text.endsWith("\n") ? text : `${text}\n` });
  selected().canvas.focus();
});
saveStateButton.addEventListener("click", async () => {
  const state = await ask<ArrayBuffer | null>((id) => ({ type: "saveState", ...target(), id }));
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
  const s = selected();
  s.generation++;
  const bytes = await file.arrayBuffer();
  send({ type: "restoreState", ...target(s), bytes }, [bytes]);
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
const translators = new Map<number, KeyboardTranslator>();
const translator = (s: PageStation) => {
  let t = translators.get(s.id);
  if (!t) translators.set(s.id, (t = new KeyboardTranslator(keyboardMode.value as KeyboardMode)));
  return t;
};
keyboardMode.addEventListener("change", () => {
  for (const s of stations.values()) {
    releaseAll(s);
    translator(s).mode = keyboardMode.value as KeyboardMode;
  }
});

function key(s: PageStation, event: KeyboardEvent, down: boolean) {
  if (event.metaKey) return;
  const t = translator(s);
  // Everything the BBC has a key for is its, not the browser's.
  if (t.translate(event)) event.preventDefault();
  if (!s.powered) return;
  for (const action of down ? t.keyDown(event) : t.keyUp(event)) {
    send({ type: "key", ...target(s), code: action.code, down: action.down });
  }
}

function releaseAll(s: PageStation | undefined) {
  if (!s) return;
  const t = translator(s);
  if (!t.holding) return;
  t.reset();
  send({ type: "releaseKeys", ...target(s) });
}

window.addEventListener("blur", () => releaseAll(selected()));
document.addEventListener("visibilitychange", () => {
  if (document.hidden) for (const s of stations.values()) releaseAll(s);
  send({ type: "hidden", hidden: document.hidden });
});

// MARK: Sound

let audioContext: AudioContext | null = null;
let gain: GainNode | null = null;

async function startSound() {
  // Created on the click: browsers only let a page start sound when asked.
  audioContext ??= new AudioContext({ latencyHint: "interactive" });
  await audioContext.resume();
  if (!gain) {
    await audioContext.audioWorklet.addModule(workletUrl);
    const node = new AudioWorkletNode(audioContext, "beeb-sound", { numberOfInputs: 0, outputChannelCount: [2] });
    gain = audioContext.createGain();
    gain.gain.value = Number(volume.value);
    node.connect(gain).connect(audioContext.destination);
    node.port.onmessage = (e: MessageEvent<{ peak: number }>) => {
      audioPeak = e.data.peak;
      soundMeter.style.width = `${Math.min(100, audioPeak * 140)}%`;
    };
    // Samples go from the worker straight to the worklet.
    const channel = new MessageChannel();
    node.port.postMessage({ port: channel.port1 }, [channel.port1]);
    send({ type: "audio", port: channel.port2, rate: audioContext.sampleRate }, [channel.port2]);
  }
}

soundButton.addEventListener("click", async () => {
  const on = soundButton.getAttribute("aria-pressed") !== "true";
  try {
    if (on) await startSound();
    else await audioContext?.suspend();
    soundButton.setAttribute("aria-pressed", String(on));
    soundButton.textContent = on ? "Sound on" : "Sound off";
  } catch (error) {
    showError(`No sound: ${(error as Error).message}`);
  }
  selected().canvas.focus();
});
volume.addEventListener("input", () => {
  if (gain) gain.gain.value = Number(volume.value);
});

// MARK: Joysticks (gamepads)

const sticks: { x: number; y: number; fire: boolean }[] = [{ x: 0, y: 0, fire: false }, { x: 0, y: 0, fire: false }];

function pollGamepads() {
  requestAnimationFrame(pollGamepads);
  const pads = (navigator.getGamepads?.() ?? []).filter((p): p is Gamepad => p !== null && p.connected);
  const shown = pads.length === 0
    ? "No gamepads: connect one and press a button to use it as the BBC's joystick."
    : pads.slice(0, 2).map((p, i) => `Joystick ${i}: ${p.id.split("(")[0].trim() || "gamepad"}`).join("; ");
  if (gamepadsText.textContent !== shown) gamepadsText.textContent = shown;
  for (let i = 0; i < 2; i++) {
    const pad = pads[i];
    let x = 0, y = 0, fire = false;
    if (pad) {
      x = pad.axes[0] ?? 0;
      y = -(pad.axes[1] ?? 0);
      // The D-pad (standard mapping: buttons 12-15) too.
      if (pad.buttons[14]?.pressed) x = -1;
      if (pad.buttons[15]?.pressed) x = 1;
      if (pad.buttons[12]?.pressed) y = 1;
      if (pad.buttons[13]?.pressed) y = -1;
      fire = pad.buttons.slice(0, 4).some((b) => b?.pressed);
      // A little dead zone in the middle.
      if (Math.abs(x) < 0.08) x = 0;
      if (Math.abs(y) < 0.08) y = 0;
    }
    const last = sticks[i];
    if (Math.abs(last.x - x) > 0.01 || Math.abs(last.y - y) > 0.01 || last.fire !== fire) {
      sticks[i] = { x, y, fire };
      send({ type: "joystick", index: i as 0 | 1, x, y, fire });
    }
  }
}
requestAnimationFrame(pollGamepads);

// MARK: Status

worker.onmessage = (event: MessageEvent<FromWorker>) => {
  const message = event.data;
  switch (message.type) {
    case "ready":
      ready = true;
      readyInfo = message;
      stateText.textContent = "Starting…";
      updateControls();
      workerReady();
      break;
    case "powered": {
      const s = stations.get(message.station);
      if (!s || message.generation !== s.generation) break;
      s.powered = true;
      paused = false;
      if (s.pendingDisc) {
        const { name, format, bytes } = s.pendingDisc;
        s.pendingDisc = undefined;
        const copy = bytes.slice().buffer;
        send({ type: "insertDisc", ...target(s), drive: 0, format, bytes: copy }, [copy]);
        s.disc = { name, format };
        caption(s);
      }
      if (s === selected()) {
        stateText.textContent = "Running";
        s.canvas.focus();
      }
      $<HTMLDetailsElement>("roms").open = false;
      updateControls();
      break;
    }
    case "status":
      lastStatus = message;
      showStatus(message.stations, message.stats);
      if (message.network) {
        const g = message.network.gateway;
        networkStats.textContent = `${message.network.frames} frames on the line, ${message.network.collisions} collisions`
          + (g ? `; to the room ${g.framesOut + g.broadcastsOut}, from it ${g.framesIn + g.broadcastsIn}` : "");
      } else {
        networkStats.textContent = "";
      }
      break;
    case "frame": {
      const s = stations.get(message.station);
      if (!s?.context || message.generation !== s.generation) break;
      s.context.putImageData(new ImageData(new Uint8ClampedArray(message.frame), 736, 576), 0, 0);
      break;
    }
    case "reply":
      replies.get(message.id)?.(message.value);
      replies.delete(message.id);
      break;
    case "room":
      showRoom(message.snapshot);
      break;
    case "roomCredentials":
      storeRoom(message.credentials);
      updateControls();
      break;
    case "error":
      showError(message.message);
      if (message.fatal) {
        for (const s of stations.values()) s.powered = false;
        stateText.textContent = "Stopped: reload the page to start again.";
        updateControls();
      }
      break;
  }
};
worker.onerror = (event) => showError(`The emulation worker failed: ${event.message}`);
send({ type: "init", wasmUrl });

function showStatus(list: StationStatus[], stats: Stats) {
  const status = list.find((s) => s.station === selectedId);
  const lights = status?.lights ?? 0;
  $("light-caps").classList.toggle("on", (lights & Status.capsLock) !== 0);
  $("light-shift").classList.toggle("on", (lights & Status.shiftLock) !== 0);
  $("light-drive").classList.toggle("on", (lights & (Status.drive0 | Status.drive1)) !== 0);
  if (!paused && selected().powered) stateText.textContent = `Running at ${(stats.speed * 100).toFixed(0)}%`;
  const cycles = status?.cycles ?? 0;
  const rows: [string, string][] = [
    ["BBC time", `${(cycles / 2e6).toFixed(1)}s (${cycles.toLocaleString()} cycles)`],
    ["Speed", `${(stats.speed * 100).toFixed(1)}% of a real BBC`],
    ["Machines", String(list.length)],
    ["Cycles/s requested, run", `${Math.round(stats.requestedPerSecond).toLocaleString()}, ${Math.round(stats.executedPerSecond).toLocaleString()}`],
    ["BBC fields/s", stats.fieldsPerSecond.toFixed(1)],
    ["Frames drawn/s", stats.drawnPerSecond.toFixed(1)],
    ["Batch time, median / 95th", `${stats.runMedian.toFixed(2)}ms / ${stats.run95.toFixed(2)}ms`],
    ["Real time dropped", `${stats.droppedMs.toFixed(0)}ms`],
    ["Sound", stats.audioPerSecond ? `${Math.round(stats.audioPerSecond).toLocaleString()} samples/s` : "off"],
    ["WebAssembly memory", `${(stats.memoryBytes / 1048576).toFixed(1)}MB`],
    ["Module", readyInfo ? `${(readyInfo.wasmBytes / 1048576).toFixed(1)}MB, loaded in ${readyInfo.loadMs.toFixed(0)}ms` : ""],
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

addStation(1, stationsElement.querySelector<HTMLElement>("figure.station")!, "modelB", "station", 1);
send({ type: "select", station: 1 });

renderROMSlots();
// The ROMs: any the viewer chose before (and asked to be remembered), and
// MacBeeb's own for the rest. Then the Model B comes on by itself.
const romsLoaded = (async () => {
  const saved = await loadROMs();
  if (saved) {
    for (const [model, slots] of Object.entries(saved)) {
      for (const [key, bytes] of slots) roms[model as ModelName]?.set(String(key), bytes);
    }
    rememberROMs.checked = true;
  }
  for (const [model, set] of Object.entries(romSets)) {
    for (const slot of set.slots) {
      if (roms[model as ModelName].has(slot.key)) continue;
      const bytes = await bundledROM(slot.file);
      if (bytes) roms[model as ModelName].set(slot.key, bytes);
    }
  }
  renderROMSlots();
})();
let workerReady: () => void;
const workerStarted = new Promise<void>((resolve) => (workerReady = resolve));
Promise.all([romsLoaded, workerStarted]).then(() => {
  const s = selected();
  if (!s.powered && romsReady(s.model)) powerOn(s);
});

// For the browser tests: what the machines show, without scraping pixels.
declare global {
  interface Window {
    macbeeb: {
      screenText(station?: number): Promise<string | null>;
      cpu(station?: number): Promise<unknown>;
      status(): typeof lastStatus;
      powered(station?: number): boolean;
      room(): RoomSnapshot | null;
      audioPeak(): number;
    };
  }
}
const stationOr = (id?: number) => stations.get(id ?? selectedId) ?? selected();
window.macbeeb = {
  screenText: (id) => ask((reply) => ({ type: "query", ...target(stationOr(id)), id: reply, what: "screenText" })),
  cpu: (id) => ask((reply) => ({ type: "query", ...target(stationOr(id)), id: reply, what: "cpu" })),
  status: () => lastStatus,
  powered: (id) => stationOr(id).powered,
  room: () => roomSnapshot,
  audioPeak: () => audioPeak,
};
