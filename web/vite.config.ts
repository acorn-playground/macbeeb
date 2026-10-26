// The browser demo. `npm run dev` serves it; `npm run build` writes dist/,
// with the WebAssembly module (from ../.build-wasm, built by
// scripts/build-wasm.sh) and MacBeeb's ROMs and file server disc (from
// ../Sources/BeebROMs), which src/bundled.ts imports.

import path from "node:path";
import { defineConfig } from "vite";

const repository = path.resolve(import.meta.dirname, "..");

export default defineConfig({
  // So that relative paths work wherever dist/ is served from.
  base: "./",
  server: {
    fs: { allow: [repository] },
  },
  worker: { format: "es" },
  build: {
    target: "es2022",
    // The module is 14MB; it's fetched, not inlined.
    assetsInlineLimit: 0,
  },
});
