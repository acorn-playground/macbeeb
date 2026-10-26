# BeebCore in Cloudflare's runtime (local proof)

An investigation, not a service. This proves that the WebAssembly BeebCore, the same module the browser demo runs, works in Cloudflare's runtime (workerd). It runs locally under `wrangler dev`. There's no second emulator here, and nothing is deployed.

`src/index.ts` has a Worker that routes to one Durable Object per machine. That object:

- runs the machine in bounded bursts, at most 10,000,000 cycles (5 seconds of BBC time) per request, and only when asked;
- keeps the machine's save state (MacBeeb's own format, the whole machine) in Durable Object storage;
- restores the machine from storage after the object is evicted or the runtime restarts.

It answers only on localhost, has no authentication, and has no routes or account in `wrangler.jsonc`. Don't deploy it.

## Running it

```
scripts/build-wasm.sh          # from the repository root: .build-wasm/beeb.wasm
cd cloudflare
npm ci
node smoke.ts                  # the whole proof, with measurements
```

`smoke.ts` starts `wrangler dev` and does the following:

1. Creates a machine and runs it, checking each checkpoint against the native build's (`Tests/BeebWasmTests/Fixtures/expected.json`).
2. Persists the state, evicts the object, and restores the state into a new instance.
3. Stops workerd, starts it again, and restores the state from disk.
4. Boots BBC BASIC and types `PRINT 2+2`.

The machine in steps 1 to 3 uses MacBeeb's own test ROM. Step 4 sends Acorn's ROMs from `Sources/BeebROMs/ROMs` to the local runtime only; `MACBEEB_SKIP_LICENSED=1` leaves it out.

By hand:

```
npm run dev
curl -X POST localhost:8787/local/machines/m1/create
curl -X POST localhost:8787/local/machines/m1/run -H 'content-type: application/json' -d '{"cycles": 2000000}'
curl -X POST localhost:8787/local/machines/m1/snapshot
curl -X POST localhost:8787/local/machines/m1/evict
curl -X POST localhost:8787/local/machines/m1/restore
curl localhost:8787/local/machines/m1/status
```

The actions are:

- `create`: power on. The body can be `{"model": 1, "roms": {"-1": base64, "15": ...}}`; without one, the machine uses the parity ROM.
- `run`: `{"cycles": n}`, where n is from 1 to 10,000,000.
- `type`: `{"text": "..."}`.
- `key`: `{"code": matrix code, "down": true}`.
- `screen`, `status`, `snapshot`, `restore` and `evict`.

What it found, measured, and would need before it could ever be a service is in [docs/cloudflare-feasibility.md](../docs/cloudflare-feasibility.md).
