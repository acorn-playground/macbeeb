// Internet Econet end to end, with a real service: two module instances
// (two browsers, in effect), each a Model B with DNFS behind a gateway,
// meet in a room; station 2 listens and station 1 sends it a message,
// through both gateways and the room. The room client is web/src/room.ts.
//
// Needs a service: MACBEEB_ECONET_SERVICE=http://127.0.0.1:8787 (in
// cloudflare-econet: npm run dev). Skipped without one.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { Model, OS_SLOT, type BeebMachine, type BeebNetwork } from "../src/beeb-wasm.ts";
import { createRoom, joinRoom, RoomConnection, type RoomCredentials } from "../src/room.ts";
import { loadModule, repository } from "./module.ts";

const service = process.env.MACBEEB_ECONET_SERVICE;
const roms = path.join(repository, "Sources/BeebROMs/ROMs");

const receiver = `10 DIM B% 80,C% 20
20 C%?0=0:C%?1=&7F:C%?2=&77:C%?3=0:C%?4=0:C%!5=B%:C%!9=B%+80
30 X%=C%:Y%=C% DIV 256:A%=&11:CALL &FFF1
40 N%=C%?0:PRINT "OPEN ";N%
50 REPEAT:A%=&33:X%=N%:R%=USR(&FFF4):UNTIL (R% AND &8000)<>0
60 C%?0=N%:X%=C%:Y%=C% DIV 256:A%=&11:CALL &FFF1
70 PRINT "FROM ";C%?3;" GOT ";$B%
RUN
`;
const sender = (to: number) => `10 DIM B% 80,C% 20
20 $B%="HELLO ECONET"
30 C%?0=&80:C%?1=&77:C%?2=${to}:C%?3=0:C%!4=B%:C%!8=B%+LEN$B%+1
40 X%=C%:Y%=C% DIV 256:A%=&10:CALL &FFF1
50 REPEAT:A%=&32:R%=USR(&FFF4):UNTIL (R% AND &8000)=0
60 PRINT "RESULT ";(R% AND &FF00) DIV 256;" ";C%?0
RUN
`;

/** One browser's worth: a machine on a line with a gateway, in a room. */
class Side {
  machine!: BeebMachine;
  network!: BeebNetwork;
  room!: RoomConnection;

  static async make(station: number, credentials: RoomCredentials): Promise<Side> {
    const side = new Side();
    const module = await loadModule();
    const m = module.createMachine(Model.modelB);
    m.loadROM(OS_SLOT, fs.readFileSync(path.join(roms, "os12.rom")));
    m.loadROM(15, fs.readFileSync(path.join(roms, "basic2.rom")));
    m.loadROM(14, fs.readFileSync(path.join(roms, "dnfs.rom")));
    m.setEconetStation(station);
    m.powerOn();
    const net = module.createNetwork();
    net.add(m);
    net.attachGateway();
    net.setSharedStations(null);
    const room = new RoomConnection(credentials, [{ station, kind: "BBC Model B", label: `Station ${station}`, role: "station" }]);
    room.onTraffic = (message) => net.receive(message);
    room.onChange = () => net.setRemoteStations(room.remoteStations);
    room.start();
    Object.assign(side, { machine: m, network: net, room });
    return side;
  }

  /** Runs `ms` of BBC time and passes the gateway's messages on. */
  step(ms: number) {
    this.network.run(ms * 2000);
    for (const message of this.network.take()) this.room.send(message);
  }

  screen(): string {
    return this.machine.screenText();
  }
}

/** Both sides, in real time (the gateways wait on each other across the room). */
async function runUntil(sides: Side[], done: () => boolean, seconds: number) {
  const deadline = performance.now() + seconds * 1000;
  while (!done()) {
    if (performance.now() > deadline) return false;
    for (const side of sides) side.step(10);
    await new Promise((r) => setTimeout(r, 10));
  }
  return true;
}

test("two browsers' BBCs talk through an Internet Econet room", { skip: !service, timeout: 120_000 }, async () => {
  const hosted = await createRoom(service!, `Web test ${Date.now()}`, "Host");
  const joined = await joinRoom(service!, hosted.invite!.code, "Guest");
  assert.equal(joined.roomId, hosted.roomId);
  const one = await Side.make(1, hosted);
  const two = await Side.make(2, joined);
  try {
    const sides = [one, two];
    // Connected, and each sees the other's station.
    assert.ok(await runUntil(sides, () => one.room.remoteStations.includes(2) && two.room.remoteStations.includes(1), 20),
      `stations: ${JSON.stringify(one.room.snapshot.stations)}`);
    const state = () => sides.map((s) => `${s.screen().trim()}\n${JSON.stringify(s.network.gatewayStatus)} cycles ${s.machine.cycles}`).join("\n----\n");
    // At BASIC's prompt, then the receiver.
    assert.ok(await runUntil(sides, () => sides.every((s) => /BASIC\s*\n>\s*$/.test(s.screen())), 20), state());
    two.machine.type(receiver);
    assert.ok(await runUntil(sides, () => /^OPEN \d+/m.test(two.screen()), 60), state());
    one.machine.type(sender(2));
    assert.ok(await runUntil(sides, () => /^RESULT \d+ \d+/m.test(one.screen()), 60), state());
    assert.match(one.screen(), /RESULT 0 /);
    assert.ok(await runUntil(sides, () => /^FROM \d+ GOT/m.test(two.screen()), 20), state());
    assert.match(two.screen(), /FROM 1 GOT HELLO ECONET/);
    assert.ok(one.network.gatewayStatus.framesOut > 0 && two.network.gatewayStatus.framesIn > 0);
  } finally {
    one.room.stop();
    two.room.stop();
  }
});
