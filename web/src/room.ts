// Internet Econet rooms (the service is cloudflare-econet; its
// econet/docs/protocol.md is the reference): the HTTP API for making and
// joining rooms, and a room's connection, which carries the gateway's
// traffic both ways. After BeebNetwork's RoomAPI and RoomConnection (the
// Mac app's), in TypeScript with only fetch, WebSocket and timers, so it
// runs in a worker, a page or Node.

export const OFFICIAL_SERVICE = "https://econet.acornplayground.org";
export const PROTOCOL_VERSION = 1;
export const CLIENT = { app: "MacBeeb Web", version: "1" };

export interface RoomView {
  id: string;
  name: string;
  description: string;
  locked: boolean;
  screenSharing?: boolean;
}

export interface ParticipantView {
  id: string;
  name: string;
  app: string;
  owner: boolean;
  online: boolean;
  rttMs?: number;
}

export interface StationView {
  station: number;
  participantId: string;
  kind: string;
  label: string;
  role: string;
  online: boolean;
}

export interface Invite {
  id: string;
  code: string;
  url: string;
  /** Null: it never expires. */
  expiresAt: string | null;
  /** Null: any number of people can use it. */
  maxUses: number | null;
}

export interface InvitePreview {
  roomId: string;
  room: RoomView;
  participants: number;
  stations: { station: number; kind: string; label: string; role: string }[];
  /** Null: it never expires. */
  inviteExpiresAt: string | null;
}

/** What a member keeps to come back to a room. */
export interface RoomCredentials {
  service: string;
  roomId: string;
  roomName: string;
  participantId: string;
  memberToken: string;
  /** The host's, if this member made the room. */
  ownerToken?: string;
  /** The invitation the room was made with (for the host to pass on). */
  invite?: Invite;
}

/** A station of this browser's, as the room's told of it. */
export interface StationClaim {
  station: number;
  kind: string;
  label: string;
  /** "station", "fileServer" or "printServer". */
  role: string;
}

/** What went wrong, as the service said it (fit to show). */
export class RoomAPIError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/**
 * A service's address, typed: https, or http for localhost (a developer's
 * own service). Returns its origin, or throws a message to show.
 */
export function serviceOrigin(typed: string): string {
  let text = typed.trim();
  if (!text.includes("://")) text = `https://${text}`;
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    throw new Error("That isn't a web address. It should look like https://econet.example.org");
  }
  if (url.pathname !== "/" && url.pathname !== "") throw new Error("Just the service's address, without a path");
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local)) {
    throw new Error("The service must use https (http only for localhost, while developing)");
  }
  return url.origin;
}

/**
 * An invitation as typed or pasted: a code (as the host read it out), or a
 * link (https://service/join/TOKEN), which also says the service.
 */
export function parseInvitation(typed: string): { code?: string; token?: string; service?: string } {
  const text = typed.trim();
  const link = /^(https?:\/\/[^/]+)\/join\/([A-Za-z0-9_.-]+)\/?$/.exec(text);
  if (link) return { service: link[1], token: link[2] };
  return { code: text };
}

export class RoomAPI {
  readonly service: string;

  constructor(service: string) {
    this.service = service.replace(/\/+$/, "");
  }

  private async request<T>(method: string, path: string, body?: object, token?: string): Promise<T> {
    const headers: Record<string, string> = {};
    if (token) headers.Authorization = `Bearer ${token}`;
    if (body) headers["Content-Type"] = "application/json";
    let response: Response;
    try {
      response = await fetch(`${this.service}/${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    } catch {
      throw new RoomAPIError(0, "unreachable", "Can't reach the Internet Econet service");
    }
    const text = await response.text();
    if (!response.ok) {
      try {
        const problem = JSON.parse(text).error;
        throw new RoomAPIError(response.status, problem.code, problem.message);
      } catch (error) {
        if (error instanceof RoomAPIError) throw error;
        throw new RoomAPIError(response.status, `http${response.status}`, `The service answered ${response.status}`);
      }
    }
    return (text ? JSON.parse(text) : {}) as T;
  }

  serviceInfo() {
    return this.request<{ service: string; name: string; protocolVersions: number[]; minimumProtocolVersion: number }>(
      "GET", ".well-known/acorn-econet");
  }

  /** A room, with its first invitation for `invite`'s time and uses (null: no limit; left out: the service's default). */
  createRoom(name: string, displayName: string, invite?: { ttlSeconds?: number | null; maxUses?: number | null }) {
    return this.request<{ roomId: string; participantId: string; ownerToken: string; memberToken: string; invite: Invite }>(
      "POST", "v1/rooms", { name, description: "", displayName, client: CLIENT, screenSharing: false, ...(invite ? { invite } : {}) });
  }

  resolve(invitation: { code?: string; token?: string }) {
    return this.request<InvitePreview>("POST", "v1/invites/resolve", invitation);
  }

  join(roomId: string, invitation: { code?: string; token?: string }, displayName: string) {
    return this.request<{ participantId: string; memberToken: string; room: RoomView }>(
      "POST", `v1/rooms/${roomId}/join`, { ...invitation, displayName, client: CLIENT });
  }

  async ticket(roomId: string, memberToken: string): Promise<string> {
    return (await this.request<{ ticket: string }>("POST", `v1/rooms/${roomId}/tickets`, undefined, memberToken)).ticket;
  }

  /** An invitation for `ttlSeconds` and `maxUses` (null: no limit). */
  newInvite(roomId: string, ownerToken: string, ttlSeconds: number | null = 86_400, maxUses: number | null = 20) {
    return this.request<Invite>("POST", `v1/rooms/${roomId}/invites`, { ttlSeconds, maxUses }, ownerToken);
  }

  leave(roomId: string, memberToken: string) {
    return this.request<object>("POST", `v1/rooms/${roomId}/leave`, undefined, memberToken);
  }

  /** The host removes someone (they're disconnected, and must be invited again). */
  remove(roomId: string, ownerToken: string, participantId: string) {
    return this.request<object>("DELETE", `v1/rooms/${roomId}/participants/${participantId}`, undefined, ownerToken);
  }

  close(roomId: string, ownerToken: string) {
    return this.request<object>("DELETE", `v1/rooms/${roomId}`, undefined, ownerToken);
  }

  connectURL(roomId: string, ticket: string): string {
    const url = new URL(`${this.service}/v1/rooms/${roomId}/connect`);
    url.protocol = url.protocol === "http:" ? "ws:" : "wss:";
    url.searchParams.set("ticket", ticket);
    return url.toString();
  }
}

/** Makes a room, as its host. */
export async function createRoom(service: string, name: string, displayName: string,
                                 invite?: { ttlSeconds?: number | null; maxUses?: number | null }): Promise<RoomCredentials> {
  const made = await new RoomAPI(service).createRoom(name, displayName, invite);
  return { service, roomId: made.roomId, roomName: name, participantId: made.participantId, memberToken: made.memberToken,
           ownerToken: made.ownerToken, invite: made.invite };
}

/** Joins a room with an invitation (a code, or a link, which names the service too). */
export async function joinRoom(service: string, invitation: string, displayName: string): Promise<RoomCredentials> {
  const parsed = parseInvitation(invitation);
  const origin = parsed.service ? serviceOrigin(parsed.service) : service;
  const api = new RoomAPI(origin);
  const by = parsed.token ? { token: parsed.token } : { code: parsed.code };
  const preview = await api.resolve(by);
  const joined = await api.join(preview.roomId, by, displayName);
  return { service: origin, roomId: preview.roomId, roomName: joined.room.name, participantId: joined.participantId,
           memberToken: joined.memberToken };
}

export type RoomState =
  | { kind: "connecting" }
  | { kind: "connected" }
  /** Lost: trying again in a few seconds. */
  | { kind: "reconnecting"; attempt: number }
  /** Over: the room closed, this member was removed, or the client's too old. Not retried. */
  | { kind: "ended"; reason: string }
  | { kind: "stopped" };

export interface RoomSnapshot {
  state: RoomState;
  room: RoomView | null;
  participantId: string | null;
  owner: boolean;
  participants: ParticipantView[];
  stations: StationView[];
  rttMs: number | null;
  /** Stations the room refused (another member has the number). */
  refused: Record<number, string>;
  problem: string | null;
}

/**
 * A room's connection: hello, this browser's stations' leases, the
 * gateway's traffic both ways, round-trip times, and reconnecting (with
 * backoff and jitter) when it's lost.
 */
export class RoomConnection {
  readonly api: RoomAPI;
  readonly credentials: RoomCredentials;
  onChange: (snapshot: RoomSnapshot) => void = () => {};
  /** A binary message from the room, for the gateway. */
  onTraffic: (message: Uint8Array) => void = () => {};

  private claims: StationClaim[];
  private socket: WebSocket | null = null;
  private stopped = false;
  private attempt = 0;
  private pingSent: number | null = null;
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  snapshot: RoomSnapshot = {
    state: { kind: "connecting" }, room: null, participantId: null, owner: false, participants: [], stations: [],
    rttMs: null, refused: {}, problem: null,
  };

  constructor(credentials: RoomCredentials, claims: StationClaim[]) {
    this.credentials = credentials;
    this.api = new RoomAPI(credentials.service);
    this.claims = claims;
  }

  start() {
    this.connect();
  }

  stop() {
    this.stopped = true;
    this.clearTimers();
    this.socket?.close(1000);
    this.socket = null;
    this.update((s) => (s.state = { kind: "stopped" }));
  }

  /** The gateway's traffic, out to the room. */
  send(message: Uint8Array) {
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(message);
  }

  /** This browser's stations changed: lease new ones, give up old ones. */
  setClaims(claims: StationClaim[]) {
    const old = this.claims;
    this.claims = claims;
    if (this.snapshot.state.kind !== "connected") return;
    const same = (a: StationClaim, b: StationClaim) =>
      a.station === b.station && a.kind === b.kind && a.label === b.label && a.role === b.role;
    for (const claim of claims) if (!old.some((o) => same(o, claim))) this.sendClaim(claim);
    for (const claim of old) {
      if (!claims.some((c) => c.station === claim.station)) this.sendJSON({ type: "release", station: claim.station });
    }
    this.update((s) => {
      for (const station of Object.keys(s.refused).map(Number)) {
        if (!claims.some((c) => c.station === station)) delete s.refused[station];
      }
    });
  }

  /** The stations elsewhere, online: the ones the gateway answers for. */
  get remoteStations(): number[] {
    return this.snapshot.stations.filter((s) => s.participantId !== this.snapshot.participantId && s.online).map((s) => s.station);
  }

  private async connect() {
    if (this.stopped) return;
    this.update((s) => (s.state = this.attempt === 0 ? { kind: "connecting" } : { kind: "reconnecting", attempt: this.attempt }));
    let ticket: string;
    try {
      ticket = await this.api.ticket(this.credentials.roomId, this.credentials.memberToken);
    } catch (error) {
      if (error instanceof RoomAPIError && (error.status === 403 || error.status === 404)) {
        this.end(error.status === 404 ? "The room has closed" : "You're no longer a member of this room");
      } else {
        this.retry("Can't reach the Internet Econet service");
      }
      return;
    }
    if (this.stopped) return;
    const socket = new WebSocket(this.api.connectURL(this.credentials.roomId, ticket));
    socket.binaryType = "arraybuffer";
    this.socket = socket;
    // (Listeners rather than onopen and the like, which Cloudflare's
    // runtime's WebSocket doesn't have.)
    socket.addEventListener("open", () => this.sendJSON({ type: "hello", protocolVersion: PROTOCOL_VERSION, client: CLIENT }));
    socket.addEventListener("message", (event: MessageEvent) => {
      if (this.socket !== socket) return;
      if (typeof event.data === "string") this.control(event.data);
      else this.onTraffic(new Uint8Array(event.data as ArrayBuffer));
    });
    socket.addEventListener("close", (event: CloseEvent) => {
      if (this.socket !== socket) return;
      this.socket = null;
      this.clearTimers();
      switch (event.code) {
        case 4001: return this.end("The room's host removed you");
        case 4002: return this.end("The room has closed");
        case 4003: return this.end("This room was opened somewhere else");
        case 4004: return this.end("This version is too old for the service");
        default: return this.retry("Lost the connection to the room");
      }
    });
  }

  private retry(problem: string) {
    if (this.stopped) return;
    this.attempt += 1;
    // 1, 2, 4… up to 30 seconds, give or take a fifth.
    const base = Math.min(30, 2 ** (Math.min(this.attempt, 6) - 1));
    const delay = base * (0.8 + Math.random() * 0.4) * 1000;
    this.update((s) => {
      s.state = { kind: "reconnecting", attempt: this.attempt };
      s.problem = problem;
    });
    this.retryTimer = setTimeout(() => this.connect(), delay);
  }

  private end(reason: string) {
    this.stopped = true;
    this.clearTimers();
    this.socket?.close(1000);
    this.socket = null;
    this.update((s) => (s.state = { kind: "ended", reason }));
  }

  private clearTimers() {
    if (this.heartbeat) clearInterval(this.heartbeat);
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.heartbeat = this.retryTimer = null;
  }

  private control(text: string) {
    if (text === "pong") {
      if (this.pingSent !== null) {
        const rtt = Math.round(performance.now() - this.pingSent);
        this.pingSent = null;
        this.update((s) => (s.rttMs = rtt));
        this.sendJSON({ type: "status", rttMs: rtt });
      }
      return;
    }
    let message: any;
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    switch (message.type) {
      case "welcome":
        this.attempt = 0;
        this.update((s) => {
          s.state = { kind: "connected" };
          s.problem = null;
          s.participantId = message.participantId ?? null;
          s.owner = message.owner ?? false;
          s.room = message.room ?? null;
          s.participants = message.participants ?? [];
          s.stations = message.stations ?? [];
          s.refused = {};
        });
        for (const claim of this.claims) this.sendClaim(claim);
        this.startHeartbeat();
        break;
      case "room":
        if (message.room) this.update((s) => (s.room = message.room));
        break;
      case "participants":
        if (message.participants) this.update((s) => (s.participants = message.participants));
        break;
      case "stations":
        if (message.stations) this.update((s) => (s.stations = message.stations));
        break;
      case "claimed":
        if (typeof message.station === "number") this.update((s) => delete s.refused[message.station]);
        break;
      case "error":
        if (typeof message.station === "number") {
          this.update((s) => (s.refused[message.station] = message.message ?? "Refused"));
        } else {
          this.update((s) => (s.problem = message.message ?? "The service refused something"));
        }
        break;
      case "closing":
        this.end(message.reason === "removed" ? "The room's host removed you"
          : message.reason === "replaced" ? "This room was opened somewhere else" : "The room has closed");
        break;
    }
  }

  private sendClaim(claim: StationClaim) {
    this.sendJSON({ type: "claim", ...claim });
  }

  private sendJSON(object: object) {
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify(object));
  }

  /** A ping every 20 seconds (answered by the service without waking the room), timed for the latency display. */
  private startHeartbeat() {
    if (this.heartbeat) clearInterval(this.heartbeat);
    const ping = () => {
      if (this.socket?.readyState !== WebSocket.OPEN) return;
      this.pingSent = performance.now();
      this.socket.send("ping");
    };
    setTimeout(ping, 1000);
    this.heartbeat = setInterval(ping, 20_000);
  }

  private update(change: (snapshot: RoomSnapshot) => void) {
    change(this.snapshot);
    this.onChange(structuredClone(this.snapshot));
  }
}
