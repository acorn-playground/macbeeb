// The browser demo. `npm run dev` serves it; `npm run build` writes dist/,
// with the WebAssembly module (from ../.build-wasm, built by
// scripts/build-wasm.sh) and no ROMs.
//
// For local development only, MACBEEB_DEV_ROMS=1 npm run dev also serves
// MacBeeb's own ROMs (Sources/BeebROMs/ROMs, Acorn's copyright) at
// /__dev-roms/, so they needn't be chosen each time. It's never part of a
// build.

import fs from "node:fs";
import path from "node:path";
import { defineConfig, type Plugin } from "vite";

const repository = path.resolve(import.meta.dirname, "..");
const romFolder = path.join(repository, "Sources/BeebROMs/ROMs");

function devROMs(): Plugin {
  return {
    name: "macbeeb-dev-roms",
    apply: "serve",
    configureServer(server) {
      if (process.env.MACBEEB_DEV_ROMS !== "1") return;
      server.middlewares.use("/__dev-roms/", (request, response) => {
        const name = decodeURIComponent((request.url ?? "/").slice(1));
        if (name === "") {
          response.end("MacBeeb's ROMs, for local development");
          return;
        }
        if (!/^[a-z0-9.-]+\.rom$/.test(name) || !fs.existsSync(path.join(romFolder, name))) {
          response.statusCode = 404;
          response.end();
          return;
        }
        response.setHeader("Content-Type", "application/octet-stream");
        response.end(fs.readFileSync(path.join(romFolder, name)));
      });
    },
  };
}

export default defineConfig({
  plugins: [devROMs()],
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
