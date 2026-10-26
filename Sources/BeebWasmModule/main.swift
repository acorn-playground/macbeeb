// The WebAssembly module: BeebWasm's exports, linked as a WASI reactor
// (no main; the host calls _initialize, then the exports). See
// scripts/build-wasm.sh.

import BeebWasm

// Natively (where this is built as an ordinary executable along with the
// rest of the package) it just says what it is.
print("BeebWasm ABI \(beeb_abi_version()): build with scripts/build-wasm.sh")
