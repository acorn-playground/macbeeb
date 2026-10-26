// The browser version and MacBeeb in one Internet Econet room: this makes
// the room, and a WebAssembly Model B here (station 1) sends to a native
// one (station 2) that Tests/BeebCoreTests (InternetEconetLiveTests'
// listensForAnotherClient) runs, through the room.
//
// Needs a service (MACBEEB_ECONET_SERVICE=http://127.0.0.1:8787) and
// MACBEEB_MIXED=1; it runs `swift test` itself.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { Model, OS_SLOT } from "../src/beeb-wasm.ts";
import { createRoom, RoomConnection } from "../src/room.ts";
import { loadModule, repository } from "./module.ts";

const service = process.env.MACBEEB_ECONET_SERVICE;
const roms = path.join(repository, "Sources/BeebROMs/ROMs");

const sender = `10 DIM B% 80,C% 20
20 $B%="HELLO ECONET"
30 C%?0=&80:C%?1=&77:C%?2=2:C%?3=0:C%!4=B%:C%!8=B%+LEN$B%+1
40 X%=C%:Y%=C% DIV 256:A%=&10:CALL &FFF1
50 REPEAT:A%=&32:R%=USR(&FFF4):UNTIL (R% AND &8000)=0
60 PRINT "RESULT ";(R% AND &FF00) DIV 256;" ";C%?0
`;

test("a browser's BBC sends to MacBeeb's through a room", { skip: !service || process.env.MACBEEB_MIXED !== "1", timeout: 900_000 }, async () => {
  const hosted = await createRoom(service!, `Mixed test ${Date.now()}`, "Browser");
  const module = await loadModule();
  const m = module.createMachine(Model.modelB);
  m.loadROM(OS_SLOT, fs.readFileSync(path.join(roms, "os12.rom")));
  m.loadROM(15, fs.readFileSync(path.join(roms, "basic2.rom")));
  m.loadROM(14, fs.readFileSync(path.join(roms, "dnfs.rom")));
  m.setEconetStation(1);
  m.powerOn();
  const net = module.createNetwork();
  net.add(m);
  net.attachGateway();
  net.setSharedStations(null);
  const room = new RoomConnection(hosted, [{ station: 1, kind: "BBC Model B", label: "Browser's BBC", role: "station" }]);
  room.onTraffic = (message) => net.receive(message);
  room.onChange = () => net.setRemoteStations(room.remoteStations);
  room.start();

  // MacBeeb, joining with the room's code.
  let nativeLog = "";
  const native = spawn("swift", ["test", "-c", "release", "-Xswiftc", "-enable-testing", "--filter", "listensForAnotherClient"], {
    cwd: repository, env: { ...process.env, MACBEEB_ECONET_INVITE: hosted.invite!.code },
  });
  native.stdout.on("data", (d) => (nativeLog += d));
  native.stderr.on("data", (d) => (nativeLog += d));
  const nativeDone = new Promise<number>((resolve) => native.on("exit", (code) => resolve(code ?? 1)));

  // Progress, for when it's slow: MACBEEB_MIXED_LOG=file.
  let ticks = 0;
  const step = async () => {
    if (process.env.MACBEEB_MIXED_LOG && ticks++ % 500 === 0) {
      fs.writeFileSync(process.env.MACBEEB_MIXED_LOG, `remote ${room.remoteStations} state ${room.snapshot.state.kind}\n${m.screenText().trim()}\n${JSON.stringify(net.gatewayStatus)}\n---- MacBeeb (exit ${native.exitCode}):\n${nativeLog.slice(-2500)}`);
    }
    net.run(20_000);
    for (const message of net.take()) room.send(message);
    await new Promise((r) => setTimeout(r, 10));
  };
  const screen = () => m.screenText();
  /** The last few lines with anything on them. */
  const lastLines = () => screen().split("\n").filter((l) => l.trim()).slice(-3).join("\n");
  try {
    // Its station in the room (MacBeeb builds first), then the program.
    while (!room.remoteStations.includes(2)) {
      if (native.exitCode !== null) assert.fail(`MacBeeb's side ended:\n${nativeLog.slice(-3000)}`);
      await step();
    }
    m.type(sender);
    while (m.isTyping) await step();
    // Send until MacBeeb's station is listening (it's typing its program too).
    for (let attempt = 0; ; attempt++) {
      assert.ok(attempt < 30, screen());
      m.type("RUN\n");
      while (!/^RESULT \d+ \d+/m.test(lastLines())) await step();
      if (/^RESULT 0 /m.test(lastLines())) break;
      for (let i = 0; i < 200; i++) await step();
      m.type("CLS\n");
      while (m.isTyping) await step();
    }
    while (native.exitCode === null) await step();
    assert.equal(await nativeDone, 0, nativeLog.slice(-3000));
    assert.match(nativeLog, /MacBeeb heard: FROM 1 GOT HELLO ECONET/);
  } finally {
    room.stop();
    native.kill();
    // swift test's own runner can keep the pipes open after it's done.
    native.stdout.destroy();
    native.stderr.destroy();
  }
});
