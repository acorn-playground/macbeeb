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

That writes `.build-wasm/beeb.wasm`. It's optimised and stripped: 14.5MB, or 4.2MB gzipped.

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
MACBEEB_DEV_ROMS=1 npx vite       # also offers MacBeeb's own ROMs (development only)
npx vite build                    # dist/: the page, the module, no ROMs
```

Using it:

1. Choose the ROM images. A Model B needs OS 1.20, BASIC II and DFS 1.20; DFS is optional, but needed for discs. A Master 128 needs all eight parts of MOS 3.20.
2. Power on, then click the screen and type.

What it has:

- **Keyboard:**
  - Keys follow your keyboard's layout, as the Mac app's default does, so Shift-8 types `*`.
  - "Keys: where they are on a BBC" switches to the positional mapping instead.
  - F12 is BREAK, End is COPY, Alt is SHIFT LOCK and F10 is f0.
- **Discs:** a disc image (.ssd and .dsd, and on the Master .adf and .adl) goes in drive 0.
  - Boot disc presses Shift-Break.
  - Save disc downloads the disc as it is now, with anything the BBC wrote to it.
- **Controls:** Break, Ctrl-Break and power cycling; Pause; typing text; and save states (MacBeeb's `.beebstate` format, uncompressed).
- **Performance:** the panel shows the BBC's speed, cycles requested and run, fields, frames drawn, batch times, dropped time and memory.

How it runs:

- **The worker:** a Web Worker (`beeb-worker.ts`) owns the module and the clock, and the page only handles the UI. The worker draws to an OffscreenCanvas; without one, it sends the page the pixels.
- **Pacing:**
  - Every 5ms, the worker runs the machine for the real time that's passed: 2,000 cycles a millisecond, measured by `performance.now()`.
  - After a stall it catches up at most 100ms and drops the rest, so returning to the tab doesn't race through a backlog.
  - A hidden tab pauses.
  - Frames that would be drawn late are simply skipped. The machine's own timing never changes.
- **Input:** key events queue in order, and each is applied at a cycle between batches; a batch is split to reach it.
  - A release comes at least 40ms of BBC time after its press, and a press 20ms after the release before it, so the OS's keyboard scan sees every key, however fast the host sends them. Nothing is dropped.
  - When the screen loses focus, held keys are released.
- **Generations:** each power cycle or restored state starts a new generation, so keys and frames from the old machine are dropped.
- **ROMs:** they stay in the browser, in IndexedDB only if you tick "Remember". They're never uploaded or bundled.

## The ABI

Version 1, in `Sources/BeebWasm/Exports.swift`, wrapped by `web/src/beeb-wasm.ts`.

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
| `beeb_abi_version()` | 1 |
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
| `beeb_release(h)`, `beeb_machine_count()` | |

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
| Cloudflare proof | `make cloudflare-smoke` | `npm ci` in `cloudflare/` |
| Speed | `node web/bench.ts` and `swift run -c release beeb-bench` | |

About the parity tests:

- `Tests/BeebWasmTests/Fixtures/scenarios.json` describes the steps: running in various slices, typing, keys, resets, a disc that's booted and written to, save states restored into new machines, and two machines at once.
- The native test and the module both run the scenarios, and must reach the checkpoints in `expected.json`: cycles, registers, RAM, frame hash, frame count, lights, screen text and disc image.
- `MACBEEB_UPDATE_PARITY=1 swift test --filter BeebWasmTests` re-records `expected.json` after an intended change to the emulation; then the module must agree with it.
- **ROMs:**
  - The "synthetic" scenarios need no Acorn ROMs. They use `parity-rom.asm`, a 16K ROM of our own, which exercises the CPU, decimal mode, a VIA timer interrupt, and the CRTC and ULA in MODE 1. Its disc, `parity-disc.asm`, is ours too.
  - The Model B and Master 128 scenarios use MacBeeb's bundled Acorn ROMs. `MACBEEB_SKIP_LICENSED=1` skips them.
- `.github/workflows/wasm.yml` runs the module, browser and Cloudflare type checks on Linux. It's started by hand for now, and hasn't been run on GitHub yet.

## Results

Measured on 26 October 2026: an Apple M4 Max (Mac16,5) with macOS 27.0.1, Swift 6.4.1, Node 24.20 and Chrome 153, with the release module.

### Correctness

- **Parity:** every checkpoint matches between native and WebAssembly. That covers:
  - 19 checkpoints;
  - 7 scenarios, among them Model B BASIC, disc boot and write, save and restore, and a Master 128;
  - save states crossing native to WebAssembly and back.
- **Save states:** a restored machine equals an uninterrupted one (CPU, cycles, RAM and screen).
- **Bad input:** every kind of bad input is refused without a trap.
- **Leaks:** 100 rounds of create, run, save, restore and release don't grow memory.
- **Browser:** the Playwright tests pass.
  - BASIC boots, and typing `PRINT 2+2` on the keyboard shows 4.
  - A disc boots, runs and writes, and saving it gives back the disc with the new file.
  - Pause, Break and power cycling work, and a held key is released on blur.
  - A Model B can be swapped for a Master 128.

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

A browser runs a Model B in real time using about a quarter of one core. There was no need to optimise.

## Limitations

- **What the browser offers:**
  - Models B and Master 128. The core has every model and co-processor, but the page offers only those two, and their ROM sets.
  - No sound, joysticks, mouse, tape, printer or Econet in the page, and no debugger or MCP server.
- **The keyboard:**
  - In layout mode, symbols come from your layout, but keys with no BBC equivalent are ignored.
  - Some browser shortcuts can't be captured (Cmd keys, F11).
- **Host tooling:** symbol files, folder import and the Quick Look preview aren't in the WebAssembly build (see the audit).
- **Writes aren't saved by themselves:** a disc's writes stay in the machine (and in save states) until you save the disc.
- **States from the Mac app:** compressed with LZFSE, they can't be read by the WebAssembly build. Save a portable one from the ABI (or `SaveStateFile.portableData()`).
- **Size:** the module is 14.5MB (4.2MB gzipped). It could be smaller with Binaryen's `wasm-opt`, which isn't used yet, or with Embedded Swift, which would mean a rewrite.

## Econet later

BeebCore emulates Econet down to the ADLC and its timing, and nothing here changes that. A WebAssembly host that wants to put a machine on a network would need:

- **Incoming frames:** delivered as explicit, cycle-stamped events. MacBeeb's `EconetBus` already treats a machine's network port that way, with clock-stamped symbols delivered between quanta.
- **Outgoing frames:** collected by the host after each `beeb_run`, as `EconetGateway` does natively.
- **Machines that keep pace:** they must agree on time. Native MacBeeb runs a network in lockstep, 32 cycles at a time. Machines on different hosts, run on demand at different speeds, can't simply exchange packets: they'd need a virtual-clock coordinator, or an acceptance that the network isn't cycle-exact.

The ABI has no Econet functions yet. Adding them means exporting the existing bus port as functions, not a new network model.

## Troubleshooting

- **"isn't the swift.org Swift 6.4.1 toolchain":** Xcode's `swift` was found. Install 6.4.1 with swiftly, or set `SWIFT`.
- **"no such module 'Compression'", or Foundation errors, when building for WebAssembly:** a new BeebCore file imports Foundation directly. Use the `#if canImport(FoundationEssentials)` import, as the other files do.
- **A trap ("unreachable") in the module:** a Swift runtime failure, such as an overflow. The wrapper marks the module as failed, and it has to be loaded afresh. Build with `--names` to get a readable stack.
- **The page says the module didn't load:** run `make wasm`. The page imports `../.build-wasm/beeb.wasm`.
- **Keys don't type:** click the screen first; it needs the focus.
