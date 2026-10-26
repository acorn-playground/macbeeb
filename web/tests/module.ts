// Loading the module for Node tests: .build-wasm/beeb.wasm (from
// scripts/build-wasm.sh), or $MACBEEB_WASM.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { BeebModule } from "../src/beeb-wasm.ts";

export const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const wasmPath = process.env.MACBEEB_WASM ?? path.join(repository, ".build-wasm/beeb.wasm");

let compiled: WebAssembly.Module | null = null;

/** A fresh instance of the module (compiled once). */
export async function loadModule(): Promise<BeebModule> {
  if (!fs.existsSync(wasmPath)) throw new Error(`no ${wasmPath}: run scripts/build-wasm.sh`);
  compiled ??= new WebAssembly.Module(fs.readFileSync(wasmPath));
  return BeebModule.load(compiled, { stdout: () => {}, stderr: (t) => console.error(t) });
}
