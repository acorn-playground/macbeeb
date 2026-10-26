# BeebCore on Cloudflare: what's proven, and what isn't

Measured on 26 October 2026, locally with Wrangler 4.152.0 and its workerd, on an Apple M4 Max with macOS 27.0.1. Nothing was deployed, and no account was used. The proof is in `cloudflare/`, and `make cloudflare-smoke` runs it.

## The answer

**Yes, locally.** The same WebAssembly module the browser runs can do all of this in workerd:

- instantiate (with our own small WASI shim: workerd's own WASI isn't needed);
- run a real BBC Micro in bounded bursts inside a Durable Object;
- persist the whole machine to Durable Object storage;
- restore the machine after the object is evicted, and after workerd itself is stopped and started again.

At every checkpoint the machine matches the native build exactly: cycles, registers and a hash of RAM, compared with `Tests/BeebWasmTests/Fixtures/expected.json`. With BBC BASIC loaded, `PRINT 2+2` prints 4.

What isn't proven is anything about Cloudflare's real network: start-up, memory accounting and CPU limits there. Those can only be measured by deploying, which this delivery doesn't do.

## How it works

- **Routing:** the Worker (`src/index.ts`) routes `/local/machines/:id/:action` to a Durable Object per machine. It answers only on localhost, and only while `MACBEEB_LOCAL_ONLY` is set. It has no routes and no `workers_dev`.
- **The module:** it's imported as a precompiled `WebAssembly.Module` (a `CompiledWasm` module rule), as Workers require; Workers can't compile WebAssembly from bytes at run time. `web/src/beeb-wasm.ts` loads it the same way it does in the browser.
- **Running:** a `run` request asks for at most 10,000,000 cycles (5 seconds of BBC time). The machine only runs when it's asked to; nothing runs in the background.
- **Persisting:** a `snapshot` writes MacBeeb's save state to the object's SQLite-backed storage. A value can be at most 2MB, and a state with a disc in is about 1.2MB, so the state is written in 1MB pieces plus a hash. `restore` checks the hash and rebuilds the machine.
- **One at a time:** a Durable Object takes one request at a time, so commands to a machine are a serial queue.

## Measurements (local workerd)

| | |
|---|---|
| Imports | the 35 WASI preview 1 functions listed in the [audit](wasm-portability-audit.md), all supplied by `web/src/wasi.ts` |
| Module | 14.5MB uncompressed, 4.2MB gzipped |
| `wrangler dev` ready | 0.8s |
| First request (instantiate and power on) | 37ms |
| Running | 3,000,000 cycles (1.5s of BBC time) in 136ms: 22MHz, 11 times a real BBC |
| Memory | linear memory 9.7MB with one machine |
| Save state | 117K for the test ROM's machine (a Model B is 184K, and 1.2MB with a disc in); writing it 24ms, restoring it 39ms |
| First request after workerd restarts | restore 52ms |

All times are round trips from the test script. Inside a Worker the clock stands still while code runs, so a Worker can't time itself.

## Against Cloudflare's published limits (checked 26 October 2026)

- **Bundle:** 64MiB uncompressed on both plans, with no compressed limit. 14.5MB fits.
- **Memory:** 128MB per isolate, WebAssembly included. One machine uses about 10MB, so several machines could share an isolate, and a Durable Object needs only one.
- **Start-up:** 1 second, for the global scope (including compiling the module). Locally, the first request took 37ms. Compiling a 14.5MB module on the real network is the biggest unknown. `wasm-opt` or a smaller build would lower the risk.
- **CPU per request:**
  - On the Free plan, 10ms buys only about 200,000 cycles, or 0.1s of BBC time, a request. That's enough to step a machine, not to run one.
  - On the Paid plan, the default is 30 seconds, up to 5 minutes. 30 seconds of CPU at 22MHz is about 5 minutes of BBC time.
- **Storage:** values up to 2MB, so states are split into pieces. There's 1GB per object on Free and 10GB on Paid.
- **Eviction:** an object that computes for more than 30 seconds between requests is more likely to be evicted and reset. Keep bursts short.

## Running on demand versus in real time

This proof runs a machine only on demand: a request runs a bounded burst and then stops. That's the default, and the right one: a machine that nobody's using costs nothing, and its state waits in storage.

A machine that runs in real time on Cloudflare is a different thing, with a different cost.

- **Cost:**
  - A Durable Object that stays awake is billed for 128MB whether it uses it or not. That's 0.125GB × 86,400s, or 10,800 GB-s a day: about 324,000 GB-s a month for one machine.
  - The Paid plan includes 400,000 GB-s a month, and charges $12.50 per million after that. So each machine running all the time costs about $4 a month in duration, plus requests or alarms to drive it.
  - Driving it with an alarm every 20ms would mean about 130 million alarms a month. Every second would be about 2.6 million, but then it isn't interactive.
- **Showing it:** a frame is 1.7MB, 50 times a second, so streaming the picture from a Durable Object isn't sensible. The browser runs the same machine itself, at a quarter of one core.
- **Keeping time:** a Durable Object's clock isn't the BBC's. To keep pace, it would run from alarms or a WebSocket and catch up by the clock, as the browser's worker does, within the CPU limits above.

## Econet between cloud machines

A Durable Object that only wakes for requests is not, by itself, enough for live Econet. BeebCore's Econet is cycle-exact: the ADLC, the clock and collisions. Native MacBeeb keeps a network's machines in lockstep, 32 cycles at a time. Machines in separate Durable Objects, each running when asked, at whatever speed its host gives it, have no shared timeline.

Linking them would need one of these:

- a coordinator that hands out virtual time, so that the machines advance together, and frames go between them stamped with the cycle they arrive at;
- or a looser network, with each frame delivered at the receiver's current time, which works for file serving but isn't cycle-exact.

The [WebAssembly notes](wasm.md#econet-later) describe the shape of the interface that either would use. None of it is built yet.

## Before anything is deployed

- **Access:** authentication and per-user authorisation for every endpoint, with no anonymous control surface.
- **Limits:** quotas and rate limits, a maximum of cycles per request and per day, and a cap on the number of machines per user.
- **Isolation:** one Durable Object per machine (as here), with no shared module state.
- **ROMs:** Acorn's ROMs can't be bundled or kept on Cloudflare without permission. The proof's own machine uses MacBeeb's test ROM. Its BBC BASIC step sends Acorn's ROMs to the local runtime only.
- **Storage policy:** discs written to between snapshots need one (snapshot after writes, or periodically, rather than on every write).
- **Measurements:** start-up and CPU on Cloudflare itself, after a first, private, deployment.

## Next steps

1. Run `.github/workflows/wasm.yml` on GitHub.
2. Try `wasm-opt -O3` on the module, for size and start-up.
3. With an account, make one private deployment to measure start-up and CPU on the real network.
4. Decide between an on-demand programmable BBC and live networked machines before building either: they're different products with different costs.
