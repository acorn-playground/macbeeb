#!/bin/bash
# Native/WebAssembly parity, with save states crossing between them:
#
#   1. the native build runs the parity scenarios, writing its states;
#   2. the WebAssembly module runs them, restoring the native states (and
#      writing its own), then the ABI tests;
#   3. the native build runs them again, restoring the WebAssembly states.
#
# Every checkpoint must match Tests/BeebWasmTests/Fixtures/expected.json
# each time. Build the module first (scripts/build-wasm.sh) and install
# web/'s packages (npm ci in web). MACBEEB_SKIP_LICENSED=1 leaves out the
# scenarios that need Acorn's ROMs.

set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .build-wasm/beeb.wasm ] || { echo "error: no .build-wasm/beeb.wasm: run scripts/build-wasm.sh" >&2; exit 1; }

export MACBEEB_PARITY_STATES="$PWD/.build-wasm/parity-states"
rm -rf "$MACBEEB_PARITY_STATES"

native() {
    # The same flags as make test, so they share a build.
    swift test -c release -Xswiftc -enable-testing --filter BeebWasmTests
}

echo "== native"
native
echo "== WebAssembly (restoring native states)"
(cd web && node --test tests/*.test.ts)
echo "== native (restoring WebAssembly states)"
native
echo "parity: native and WebAssembly agree, and their states cross both ways"
