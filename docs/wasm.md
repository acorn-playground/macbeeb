# MacBeeb in WebAssembly

MacBeeb's emulation core, BeebCore, also builds as a WebAssembly module. The browser demo in `web/` runs it, and so does the local Cloudflare proof in `cloudflare/`. In all three places (the Mac app, the browser and Cloudflare) the emulator is the same Swift code. There's no JavaScript emulator, and the browser has no emulation of its own.

```
                         Sources/BeebCore
       6502s, memory, VIAs, video, discs, Tube, save states
                                │
           ┌────────────────────┴───────────────────┐
     native Swift calls                  Sources/BeebWasm: a C ABI
           │                       (BeebWasmModule: a WASI reactor)
  BeebHost, the beeb CLI,                           │
  MacBeeb, the debugger              web/src/wasi.ts + beeb-wasm.ts
                                                     │
                                    ┌────────────────┴──────────────┐
                           browser: web/                cloudflare/: a Worker
                     (a Web Worker + canvas)           and a Durable Object
```

- `Sources/BeebWasm` holds the ABI: flat functions over opaque handles. It's ordinary Swift, so the native parity tests call the very functions the module exports.
- `Sources/BeebWasmModule` links those functions as a WASI reactor: there's no `main`, and the host calls `_initialize`, then the exports.
- `web/src/wasi.ts` provides the WASI that the module needs: no files, and stdout goes to callbacks.
- `web/src/beeb-wasm.ts` is the typed wrapper that every JavaScript host uses.

The [portability audit](wasm-portability-audit.md) records what had to change in BeebCore and why.

## Building

You need the swift.org Swift 6.4.1 toolchain and its WebAssembly SDK. Xcode's Swift won't do, because it has no WebAssembly linker. With [swiftly](https://www.swift.org/install):

```
swiftly install 6.4.1
swift sdk install https://download.swift.org/swift-6.4.1-release/wasm-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_wasm.artifactbundle.tar.gz \
  --checksum 783e6128d174d9f975b4eda68be02a5960681b723ef372e6876a7c2543a365d8
```

Then build the module:

```
scripts/build-wasm.sh            # or: make wasm
```

That writes `.build-wasm/beeb.wasm`. It's optimised and stripped: 14.5MB, or 4.2MB gzipped. It also runs `web-discs`, a small native tool, to write the Distributed Mandelbrot's discs into `.build-wasm/discs`. The tool uses the Mac app's own BeebNetwork code, which isn't in the module.

- `--names` keeps function names, for profiling.
- `--debug` builds it unoptimised.
- If `swift` on your PATH isn't the 6.4.1 toolchain, set `SWIFT=/path/to/usr/bin/swift`.

The Mac app, the CLI and the release scripts don't use any of this, and their builds are unchanged. `scripts/make-app.sh` builds only MacBeeb, macbeeb-mcp and the Quick Look extension, so nothing from `web/` or the module goes into the app.

The JavaScript tooling was verified with:

| Tool | Version |
|---|---|
| Node | 24.20 |
| TypeScript | 5.9.3 |
| Vite | 7.3.7 |
| Playwright | 1.64.1 |
| Wrangler | 4.152.0 |

Each folder has its own `package-lock.json`.

## The browser demo

```
make wasm
cd web && npm ci
npx vite                          # http://localhost:5173
npx vite build                    # dist/: the page, the module, and MacBeeb's ROMs
```

Using it:

1. It starts a Model B by itself, with the ROMs MacBeeb bundles (`web/src/bundled.ts` imports them from `Sources/BeebROMs`, as the Mac app does).
   - The Model B has OS 1.20, BASIC II and DFS 1.20; with Econet on, DNFS 3.60 takes DFS's place (MacBeeb's DFS 1.20 is in fact that DNFS image).
   - The Master 128 has all eight parts of MOS 3.20, and ANFS 4.25 for Econet.
   - The ROMs panel lets a viewer use their own images in place of any of them.
2. Click the screen and type.

What it has:

- **Keyboard:**
  - Keys follow your keyboard's layout, as the Mac app's default does, so Shift-8 types `*`.
  - "Keys: where they are on a BBC" switches to the positional mapping instead.
  - F12 is BREAK, End is COPY, Alt is SHIFT LOCK and F10 is f0.
- **Discs:** a disc image (.ssd and .dsd, and on the Master .adf and .adl) goes in drive 0.
  - Boot disc presses Shift-Break.
  - Save disc downloads the disc as it is now, with anything the BBC wrote to it.
- **Controls:** Break, Ctrl-Break and power cycling; Pause; typing text; and save states (MacBeeb's `.beebstate` format, uncompressed).
- **Sound:** "Sound off" turns it on (browsers only start sound when asked), with a volume control and a level meter.
  - It's the core's own sound chip and mixer, as the Mac app plays it, resampled to the browser's rate.
  - It comes from the selected BBC.
- **Joysticks:** up to two gamepads are the BBC's analogue joysticks 0 and 1.
  - The left stick or the D-pad steers, and the face buttons fire. There's a small dead zone.
  - They go to the selected BBC, and stay as set through power cycles.
- **Several BBCs:** "Add a BBC" (under Econet) adds another station, with its own screen. Click a screen to select it: the selected one is large, and it gets the keyboard, discs, typing, sound and the joysticks.
- **Econet:** with Econet on, every BBC has an Econet module, with a station number you choose, and they share one network.
  - The network runs in lockstep, 32 cycles at a time, as the Mac app's Network Studio runs it, with the line's clock at 200kHz.
  - "Add a file server" adds a Model B as station 254 with Acorn's Level 1 file server in its drive (the disc Network Studio uses). Start it with `CH."FS"` and answer its questions.
  - The panel counts the frames on the line, and collisions.
- **Internet Econet:** the BBCs can join a room on an Internet Econet service (by default econet.acornplayground.org) and talk to the stations of other people, in MacBeeb or in a browser.
  - Make a room (the page then shows its invitation code and link), or join one with a code or link.
  - The room's members and stations are listed, with the round trip.
  - Your credentials are kept in the browser's local storage, so "Rejoin" takes you back. Leaving forgets them; the host's leaving closes the room.
  - The service needs to allow browsers (cross-origin requests): see "Internet Econet" below.
- **Performance:** the panel shows the BBC's speed, cycles requested and run, fields, frames drawn, batch times, dropped time and memory.

### The Distributed Mandelbrot

`mandelbrot.html` (linked from the first page) is Network Studio's Distributed Mandelbrot. Ten Model Bs with DNFS share one Econet:

- the Guide, station 1;
- eight workers, stations 2-9 (or fewer: choose 2-8);
- a Level 2 file server, station 254, with a 6502 Second Processor.

The page starts it all as the Mac app does:

1. It powers them on.
2. It puts the server's disc in drive 0 and the Level 2 utilities in drive 1, and types the server's start-up answers. The date is today's, in 1988, because the server can't hold this century's years.
3. It boots the Guide's disc. The Guide logs on, trying again until the server's up, and shows what to do.

Its buttons type `*CLUSTER`, which starts the workers by remote control, and `*MANDEL` on the Guide; or click any screen and type there. The colour version uses MODE 2 on a Guide with VideoNuLA (`*MANDEL2`).

All ten machines run in one worker, in lockstep, at about real time on an M4 Max: the whole picture takes about 25 seconds of BBC time. A slower computer runs it slower, and the page shows the speed. Fewer workers make it lighter.

How it runs:

- **The worker:** a Web Worker (`beeb-worker.ts`) owns the module and the clock, and the page only handles the UI.
  - It runs every station: alone, or with Econet on, together on the module's network.
  - It draws each station to its own OffscreenCanvas; without one, it sends the page the pixels.
- **Sound:** the worker takes the selected station's samples after each batch and posts them through a MessagePort straight to an AudioWorklet (`audio-worklet.ts`), not through the page.
  - The worklet plays from a queue kept between about 40ms and 150ms (beyond that, the oldest is dropped), since the worker's clock and the sound card's differ slightly.
  - When the queue runs dry, it fades out rather than clicking.
- **Rooms:** the room client (`room.ts`, after BeebNetwork's `RoomAPI` and `RoomConnection`) runs in the worker. The room's binary messages go to and from the network's gateway with no stop in the page.
- **Pacing:**
  - Every 5ms, the worker runs the machine for the real time that's passed: 2,000 cycles a millisecond, measured by `performance.now()`.
  - After a stall it catches up at most 100ms and drops the rest, so returning to the tab doesn't race through a backlog.
  - A hidden tab pauses.
  - Frames that would be drawn late are simply skipped. The machine's own timing never changes.
- **Input:** key events queue in order, and each is applied at a cycle between batches; a batch is split to reach it.
  - A release comes at least 40ms of BBC time after its press, and a press 20ms after the release before it, so the OS's keyboard scan sees every key, however fast the host sends them. Nothing is dropped.
  - When the screen loses focus, held keys are released.
- **Generations:** each power cycle or restored state starts a new generation, so keys and frames from the old machine are dropped.
- **ROMs:** MacBeeb's are part of the build (12 ROMs and the Level 1 file server disc, about 400K). A viewer's own stay in their browser (in IndexedDB only if they tick "Remember") and are never uploaded.

## The ABI

Version 4, in `Sources/BeebWasm` (`Exports.swift`, `PeripheralExports.swift`, `NetworkExports.swift` and `HardDiscExports.swift`), wrapped by `web/src/beeb-wasm.ts`. Version 2 added sound, joysticks, Econet, the 6502 Second Processor and VideoNuLA to version 1. Version 3 added hard discs, sideways RAM and `beeb_network_run_until_holding`; version 4 adds raw RAM access and restoring a state as another Econet station. The rest is unchanged.

### Conventions

- **Statuses:** functions return an `int32`. A non-negative value is a success or a result. A negative one is an error:

  | Code | Meaning |
  |---|---|
  | -1 | invalid handle |
  | -2 | invalid argument |
  | -3 | not ready |
  | -4 | bad data |
  | -5 | unsupported |
  | -6 | limit reached |

  `beeb_error_ptr` and `beeb_error_len` give the last error's message.
- **Bad input:** handles, sizes, addresses, models, formats and save states are all checked, so bad input never traps.
- **Bytes in:** pass a pointer and a length. The module copies the bytes before it returns. `beeb_alloc` and `beeb_free` give you a buffer.
- **Bytes out:** these go in the result buffer. The call returns the length, `beeb_result_ptr` says where the bytes are, and they're valid until the next result.
- **Limits:**

  | Limit | Value |
  |---|---|
  | Machines per module | 16 |
  | ROM | 16K |
  | Disc image | 4MB |
  | Save state | 64MB |
  | Text | 64K |
  | One `beeb_run` | 20,000,000 cycles (10 seconds of BBC time) |

### Functions

| Function | |
|---|---|
| `beeb_abi_version()` | 4 |
| `beeb_create(model)` | A machine, with no ROMs yet. Models: 0 Model A, 1 Model B, 2 B+, 3 Master 128, 4 Master Compact. Returns the handle. |
| `beeb_load_rom(h, slot, p, n)` | Slot -1 is the OS (16K); 0-15 are sideways banks. A machine that's on is power cycled. |
| `beeb_set_rtc(h, yy, mm, dd, dow, h, m, s)` | The Master's clock at power on. The default is 2000-01-01 00:00:00, so runs repeat. |
| `beeb_power_on(h)`, `beeb_reset(h, kind)` | Kinds: 0 power cycle (the discs stay in), 1 Break, 2 Ctrl-Break, 3 Shift-Break. |
| `beeb_run(h, cycles)` | Runs that many 2MHz cycles and returns how many ran (fewer if the debugger stops it). The only way time passes. |
| `beeb_cycles(h)` | Cycles since power on, as a double (exact to 2⁵³). |
| `beeb_status(h)` | Bits: 1 on, 2 stopped by the debugger, 4 Caps Lock light, 8 Shift Lock light, 16 and 32 the drive lights, 64 the cassette motor. |
| `beeb_cpu_state(h, out)` | 8 bytes: PC (low, high), A, X, Y, S, P. |
| `beeb_read_memory(h, space, addr, n, out)` | Side-effect free. Space 0 is as the CPU sees memory; 1 is the RAM the video hardware reads. |
| `beeb_set_key(h, code, down)` | A matrix key (row << 4 \| column; 0x7F is Break), applied now, at the current cycle, before the next run. |
| `beeb_release_all_keys(h)`, `beeb_type(h, p, n)`, `beeb_is_typing(h)` | `beeb_type` takes UTF-8 and types it key by key in BBC time. |
| `beeb_insert_disc(h, drive, format, p, n)`, `beeb_eject_disc`, `beeb_export_disc(h, drive, format)` | Formats: 0 .ssd, 1 .dsd, 2 .adf, 3 .adl, 4 .img, 5 .dos. An export includes anything the BBC wrote. |
| `beeb_video_width()`, `beeb_video_height()` | 736 × 576. |
| `beeb_video_frame(h)` | The machine's RGBA8 buffer (see Video). |
| `beeb_video_frame_count(h)`, `beeb_video_frame_hash(h)` | The hash is FNV-1a over the frame. |
| `beeb_screen_text(h)` | BeebCore's `screenText()`: UTF-8 lines. |
| `beeb_save_state(h)`, `beeb_restore_state(h, p, n)` | The whole machine. A failed restore leaves the machine as it was. |
| `beeb_restore_state_station(h, p, n, station)` | As `beeb_restore_state`, but the machine's Econet module has `station` (1-254) in place of the state's. A program's own copy of its station number is left as it was. |
| `beeb_read_ram(h, region, offset, n, out)`, `beeb_write_ram(h, region, offset, p, n)` | RAM as stored, whatever's paged in: region 0 is main RAM, shadow, ANDY and HAZEL (offsets 0-&12FFF: shadow from &8000, ANDY from &10000, HAZEL from &11000); region 1 is the sideways banks (bank << 14 \| offset). Writes to sideways ROM fail. For tools that find and set what a program keeps, not for emulation. |
| `beeb_release(h)`, `beeb_machine_count()` | |
| `beeb_audio_start(h, rate)`, `beeb_audio_read(h, out, n)` | Mono float samples at `rate` (8,000-192,000; 0 stops it), from the core's mixer. Samples not read within two seconds are dropped. |
| `beeb_set_joystick(h, i, x, y, fire)` | Joystick 0 or 1: x and y from -1 (left, down) to 1 (right, up). It stays as set through power cycles. On a Master Compact, joystick 0 is its digital one. |
| `beeb_set_econet_station(h, n)` | Fits an Econet module as station n (1-254), or takes it out (0). A machine that's on is power cycled. |
| `beeb_set_second_processor(h, p, n)` | Fits a 6502 Second Processor with its client ROM (TUBE110), or takes it out (no ROM). A machine that's on is power cycled. |
| `beeb_set_video_nula(h, on)` | VideoNuLA in place of the Video ULA. A machine that's on is power cycled. |
| `beeb_set_sideways_ram(h, banks)` | Sideways RAM in the banks whose bits are set (bit n: bank n), in place of the model's own: `1 << 4` is a 16K board in bank 4, as Elite on a Model B wants. A machine that's on is power cycled. |
| `beeb_attach_hard_disc(h, drive, p, n, dsc, k)`, `beeb_detach_hard_disc(h, drive)` | A Winchester on the Acorn SCSI interface (&FC40), as SCSI drive 0-3: its image (256-byte sectors in order, at most 64MB; sectors past the end read as zeros) and its 22-byte `.dsc` parameters (or none, `k` 0, for the largest drive ADFS can use). It stays attached through power cycles and restores. |
| `beeb_hard_disc_take_written(h, drive)` | The sectors written since the last call, lowest first, in the result buffer: each a 4-byte little-endian sector number then its 256 bytes. A host keeping the disc stores just these. |
| `beeb_export_hard_disc(h, drive, which)` | The whole image (`which` 0), or its parameters (1). |

### Networks

Machines and networks share one numbering of handles.

| Function | |
|---|---|
| `beeb_network_create(clock)` | An Econet line, with a clock of `clock` bits a second (200,000 is usual; 0 is none). At most 8. |
| `beeb_network_add(n, h)`, `beeb_network_remove(n, h)` | Plugs a machine in, or takes it out. A machine's module, if it has one, joins the line. |
| `beeb_network_run(n, cycles)` | Runs every machine together, in quanta of the line's delay (32 cycles): each runs a quantum in turn, then the line delivers what they sent, as `NetworkHost` does. Returns the cycles run, a whole number of quanta. A machine on a network refuses `beeb_run`. |
| `beeb_network_run_until_holding(n, cycles)` | As `beeb_network_run`, but it stops at the end of a quantum in which the gateway is holding the line for an answer from the room. It always runs at least one, in which the gateway takes in what it's been given (perhaps the answer). |
| `beeb_network_count(n, which)` | 0: frames seen on the line. 1: byte-times spoiled by collisions. |
| `beeb_network_release(n)` | The machines carry on alone. |
| `beeb_gateway_attach(n, on)` | Puts BeebCore's Internet gateway (`EconetGateway`) on the line, or takes it off. |
| `beeb_gateway_set_remote(n, p, k)`, `beeb_gateway_set_shared(n, p, k, all)` | The stations elsewhere it answers for, and the local ones shared with the room (`all` 1: every one). |
| `beeb_gateway_receive(n, p, k)` | A binary message from the room: the protocol's wire format, version 1 (`EconetTraffic`, now in BeebCore so that both gateways share it). |
| `beeb_gateway_take(n)` | The gateway's messages for the room, in the result buffer, each a 4-byte big-endian length then the message. |
| `beeb_gateway_status(n, out)` | Seven counters (frames and broadcasts out and in, no replies, refused as busy, timeouts), and it returns its activity: 0 idle, 1 holding the line, 2 waiting on a local station. |

The host carries a room's messages. The gateway holds the line while a frame is answered elsewhere, for at most two seconds of BBC time, so a networked machine with a gateway runs in real time, as the browser runs it. Or it needn't run at all while it waits: a host that runs a network only when there's work (a server in the cloud) runs it with `beeb_network_run_until_holding`, stops while the gateway holds the line, and carries on when the room's answer arrives. BBC time stands still meanwhile, so the two seconds never pass. (It does need a limit of its own in real time, for a room that never answers: then it runs on, and the gateway gives up.)

### Video

The frame is BeebCore's own TV output, the b2 port the Mac app shows:

- 736 × 576 RGBA8 (bytes R, G, B, 255), top row first, with no padding;
- each PAL scanline doubled;
- interlaced fields woven as a real TV shows them.

A frame is complete at each vertical retrace, which is 50 a second. Display it at MacBeeb's aspect, (736 × 24/25) : 576.

`beeb_video_frame` converts the frame only when there's a new one. Its pointer stays valid until the machine is released, but the contents change on the next call. Copy them to keep them.

### Time and input

The host decides when time passes, and only `beeb_run` advances it. There's no clock, timer or thread in the core, so the same inputs at the same cycles give the same machine on every host. The parity tests prove this.

### Save states

A state is MacBeeb's `.beebstate` format: the configuration with its ROMs, every device, pending key events and the discs with their writes. Here it's uncompressed (a binary plist); the Mac app's own are LZFSE-compressed.

- A WebAssembly build reads the uncompressed kind. Every build reads states made by `beeb_save_state` on any other.
- The TV isn't part of a state: after a restore, the picture starts afresh.
- Because a state includes the ROMs, it shouldn't be shared where the ROMs can't be.

## Tests

| What | Command | Needs |
|---|---|---|
| Native suite (includes the ABI and parity tests) | `make test` | |
| Native/WebAssembly parity, states crossing both ways, the module's ABI and leak tests | `make wasm-test` (`scripts/test-wasm.sh`) | `npm ci` in `web/` |
| The module alone | `cd web && node --test tests/*.test.ts` | |
| Browser end to end | `make web-test`, or `PLAYWRIGHT_CHANNEL=chrome npx playwright test` to use the installed Chrome | Playwright's Chromium, or Chrome |
| 32-bit soak (37 minutes of BBC time) | `MACBEEB_SOAK=1 node --test tests/soak.test.ts` in `web/` | |
| Internet Econet: two module instances in a room, through `room.ts` | `MACBEEB_ECONET_SERVICE=http://127.0.0.1:8787 node --test tests/room.test.ts` in `web/` | an Internet Econet service (in cloudflare-econet: `npm run dev`) |
| Internet Econet: the browser version and MacBeeb in one room | `MACBEEB_MIXED=1 MACBEEB_ECONET_SERVICE=... node --test tests/room-mixed.test.ts` in `web/` (it runs the native side with `swift test`) | the same |
| Internet Econet: two browser pages in a room | `MACBEEB_ECONET_SERVICE=... npx playwright test tests/peripherals.spec.ts` | the same |
| Cloudflare proof | `make cloudflare-smoke` | `npm ci` in `cloudflare/` |
| Speed | `node web/bench.ts` and `swift run -c release beeb-bench` | |

About the parity tests:

- `Tests/BeebWasmTests/Fixtures/scenarios.json` describes the steps: running in various slices, typing, keys, resets, a disc that's booted and written to, save states restored into new machines, two machines at once, sound and a joystick, and two DNFS stations on an Econet sending a message from one to the other.
- The native test and the module both run the scenarios, and must reach the checkpoints in `expected.json`: cycles, registers, RAM, frame hash, frame count, lights, screen text, disc image and (where a machine makes sound) a hash of every sample.
- `MACBEEB_UPDATE_PARITY=1 swift test --filter BeebWasmTests` re-records `expected.json` after an intended change to the emulation; then the module must agree with it.
- **ROMs:**
  - The "synthetic" scenarios need no Acorn ROMs. They use `parity-rom.asm`, a 16K ROM of our own, which exercises the CPU, decimal mode, a VIA timer interrupt, and the CRTC and ULA in MODE 1. Its disc, `parity-disc.asm`, is ours too.
  - The Model B and Master 128 scenarios use MacBeeb's bundled Acorn ROMs. `MACBEEB_SKIP_LICENSED=1` skips them.
- `.github/workflows/wasm.yml` runs the module, browser and Cloudflare type checks on Linux. It's started by hand for now, and hasn't been run on GitHub yet.

## Results

Measured on 26 October 2026: an Apple M4 Max (Mac16,5) with macOS 27.0.1, Swift 6.4.1, Node 24.20 and Chrome 153, with the release module.

### Correctness

- **Parity:** every checkpoint matches between native and WebAssembly. That covers:
  - 25 checkpoints;
  - 10 scenarios, among them Model B BASIC, disc boot and write, save and restore, a Master 128, sound (every sample) and a joystick read by `ADVAL`, a message over Econet between two stations, and BASIC in a 6502 Second Processor;
  - save states crossing native to WebAssembly and back.
- **Save states:** a restored machine equals an uninterrupted one (CPU, cycles, RAM and screen).
- **Bad input:** every kind of bad input is refused without a trap.
- **Leaks:** 100 rounds of create, run, save, restore and release don't grow memory.
- **Browser:** the Playwright tests pass.
  - BASIC boots, and typing `PRINT 2+2` on the keyboard shows 4.
  - A disc boots, runs and writes, and saving it gives back the disc with the new file.
  - Pause, Break and power cycling work, and a held key is released on blur.
  - A Model B can be swapped for a Master 128.
  - Sound reaches the AudioWorklet (its level is measured), in a steady stream at the browser's rate.
  - A gamepad (faked in the page) is read by BASIC's `ADVAL`, with its fire button.
  - Two stations in one page send a message over their Econet.
  - Two browser pages, each a station, make and join a room on a local copy of the Internet Econet service and send a message through it.
  - The Distributed Mandelbrot page: the Level 2 server starts, `*CLUSTER` starts eight workers, `*MANDEL` has them draw all 320 tiles, and the Guide counts them.
- **Internet Econet:**
  - Two module instances in Node talk through a room on a local copy of the service.
  - The browser version's station sends to MacBeeb's own (the native build, running its Internet Econet client) through a room.
  - MacBeeb's own room tests still pass against the same service.

### Performance

The workload is beeb-bench's: a Model B with its TV, running a busy MODE 2 BASIC drawing loop for 20 seconds of BBC time.

| | |
|---|---|
| Native (`beeb-bench`, "with TV") | 15.4× real time (30.8MHz) |
| WebAssembly, in Node | 11.5× real time (23.1MHz), 75% of native |
| WebAssembly, a 20ms batch (40,000 cycles) | median 1.73ms, 95th percentile 1.81ms |
| Browser, interactive (5ms batches, about 10,000 cycles) | median 1.30ms, 95th percentile 1.60ms; 100% speed, 49.8 fields/s drawn, no dropped time |
| Start-up | module compile 14ms and instantiate 3ms (Node); create and power on 4ms; fetch and instantiate in the page 36ms |
| Memory | linear memory 9.3MB with one machine, 15.8MB with two |
| Save state | 184K for a Model B (1.2MB with a disc in, since the disc's tracks are included); 24ms to save, 80ms to restore into a new machine |
| An Econet network in lockstep (Node; Model Bs with DNFS) | one machine 10.6× real time (alone it's 11.1×), two 5.5×, three 3.7×, four 2.8× |

A browser runs a Model B in real time using about a quarter of one core. There was no need to optimise.

## Limitations

- **What the browser offers:**
  - Models B and Master 128. The core has every model and co-processor, but the page offers only those two, and their ROM sets.
  - No mouse, tape or printer in the page, and no debugger or MCP server.
  - No disc drive sounds (the Mac app's recordings are in BeebROMs, which the module doesn't include).
  - Only the selected BBC is heard, and only it takes the joysticks.
- **The keyboard:**
  - In layout mode, symbols come from your layout, but keys with no BBC equivalent are ignored.
  - Some browser shortcuts can't be captured (Cmd keys, F11).
- **Host tooling:** symbol files, folder import and the Quick Look preview aren't in the WebAssembly build (see the audit).
- **Writes aren't saved by themselves:** a disc's writes stay in the machine (and in save states) until you save the disc.
- **States from the Mac app:** compressed with LZFSE, they can't be read by the WebAssembly build. Save a portable one from the ABI (or `SaveStateFile.portableData()`).
- **Size:** the module is 14.5MB (4.2MB gzipped). It could be smaller with Binaryen's `wasm-opt`, which isn't used yet, or with Embedded Swift, which would mean a rewrite.

## Internet Econet

BeebCore emulates Econet down to the ADLC and its timing, and the WebAssembly build uses all of it.

**On one network**, the browser's stations run in lockstep on one line, as Network Studio's machines do natively.

**Between networks**, a room on an Internet Econet service (cloudflare-econet) carries the frames, as it does between Macs:

- the gateway (BeebCore's `EconetGateway`) on each line stands in for the stations elsewhere;
- the room's binary messages pass between gateways untouched, so a browser's station and a Mac's are the same to each other.

The gateway never answers for a station elsewhere itself. It holds the line, with flags, while a frame crosses the Internet and the real answer comes back, so each side must run in real time.

The service needs to let browsers call it: cross-origin requests (CORS) from any origin. That's safe there, because its credentials are bearer tokens in headers and it uses no cookies. cloudflare-econet's `browser-clients` branch adds it, with a test and a note in its `docs/security.md`. Until a service has it, the page can't join its rooms, though the Mac app can.

The client sends the app name "MacBeeb Web", so people in a room see who's in a browser.

## Troubleshooting

- **"isn't the swift.org Swift 6.4.1 toolchain":** Xcode's `swift` was found. Install 6.4.1 with swiftly, or set `SWIFT`.
- **"no such module 'Compression'", or Foundation errors, when building for WebAssembly:** a new BeebCore file imports Foundation directly. Use the `#if canImport(FoundationEssentials)` import, as the other files do.
- **A trap ("unreachable") in the module:** a Swift runtime failure, such as an overflow. The wrapper marks the module as failed, and it has to be loaded afresh. Build with `--names` to get a readable stack.
- **The page says the module didn't load:** run `make wasm`. The page imports `../.build-wasm/beeb.wasm`.
- **Keys don't type:** click the screen first; it needs the focus.
