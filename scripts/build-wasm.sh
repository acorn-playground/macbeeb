#!/bin/bash
# Builds BeebCore as a WebAssembly module (Sources/BeebWasmModule: the
# BeebWasm ABI, a WASI reactor) into .build-wasm/beeb.wasm.
#
#   scripts/build-wasm.sh [--debug] [--names]
#
# --debug builds unoptimised; --names keeps function names (for profiling
# and stack traces). Otherwise it's optimised and stripped.
#
# It needs the swift.org toolchain and its matching Swift SDK for
# WebAssembly (Xcode's Swift has no WebAssembly linker): see docs/wasm.md.
# Set SWIFT to the toolchain's swift if it isn't first on the PATH (with
# swiftly: `swiftly install 6.4.1 && swiftly use 6.4.1`).

set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT_VERSION=6.4.1
SDK="swift-${SWIFT_VERSION}-RELEASE_wasm"
SDK_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/wasm-sdk/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE_wasm.artifactbundle.tar.gz"
SDK_CHECKSUM=783e6128d174d9f975b4eda68be02a5960681b723ef372e6876a7c2543a365d8

CONFIGURATION=release
STRIP=--strip-all
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIGURATION=debug; STRIP= ;;
        --names) STRIP=--strip-debug ;;
        *) echo "usage: $0 [--debug] [--names]" >&2; exit 2 ;;
    esac
done

if [ -z "${SWIFT:-}" ]; then
    if [ -x "$HOME/.swiftly/bin/swift" ]; then SWIFT="$HOME/.swiftly/bin/swift"; else SWIFT=swift; fi
fi
if ! "$SWIFT" --version 2>/dev/null | grep -q "swift-${SWIFT_VERSION}-RELEASE"; then
    echo "error: $SWIFT isn't the swift.org Swift ${SWIFT_VERSION} toolchain (Xcode's can't link WebAssembly)." >&2
    echo "  Install it with swiftly (https://www.swift.org/install): swiftly install ${SWIFT_VERSION}" >&2
    echo "  or set SWIFT=/path/to/toolchain/usr/bin/swift" >&2
    exit 1
fi
if ! "$SWIFT" sdk list 2>/dev/null | grep -qx "$SDK"; then
    echo "error: the Swift SDK for WebAssembly isn't installed. Install it with:" >&2
    echo "  $SWIFT sdk install $SDK_URL --checksum $SDK_CHECKSUM" >&2
    exit 1
fi

"$SWIFT" build --swift-sdk "$SDK" -c "$CONFIGURATION" --product BeebWasmModule --scratch-path .build-wasm

OUT=.build-wasm/beeb.wasm
OBJCOPY="$(dirname "$(command -v "$SWIFT")")/llvm-objcopy"
[ -x "$OBJCOPY" ] || OBJCOPY="$(command -v llvm-objcopy || true)"
if [ -n "$STRIP" ] && [ -n "$OBJCOPY" ]; then
    "$OBJCOPY" "$STRIP" ".build-wasm/$CONFIGURATION/BeebWasmModule.wasm" "$OUT"
else
    [ -n "$STRIP" ] && echo "warning: no llvm-objcopy, so the module isn't stripped" >&2
    cp ".build-wasm/$CONFIGURATION/BeebWasmModule.wasm" "$OUT"
fi
echo "$OUT: $(wc -c < "$OUT" | tr -d ' ') bytes"

# The discs web/'s Distributed Mandelbrot page boots, made natively (by
# the Mac app's own code, with Xcode's Swift: the module's toolchain is
# for WebAssembly).
xcrun swift run -c release --scratch-path .build web-discs .build-wasm/discs
