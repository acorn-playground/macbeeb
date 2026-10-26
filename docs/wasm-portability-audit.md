# BeebCore and WebAssembly: the portability audit

This is what stood between BeebCore and WebAssembly, what was done about each item, and how it was checked. It records the state of the code on 26 October 2026, on the `wasm` branch.

## Toolchain (verified)

- **Compiler:** the swift.org Swift 6.4.1 toolchain (`swift-6.4.1-RELEASE`). Xcode's Swift 6.4 can't be used, because it has no WebAssembly linker (`wasm-ld`).
- **SDK:** `swift-6.4.1-RELEASE_wasm`, the "full Swift" Swift SDK for WebAssembly.
  - Installed with `swift sdk install https://download.swift.org/swift-6.4.1-release/wasm-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_wasm.artifactbundle.tar.gz --checksum 783e6128d174d9f975b4eda68be02a5960681b723ef372e6876a7c2543a365d8`.
  - It targets `wasm32-unknown-wasip1`.
  - The Embedded Swift SDK that comes with it wasn't needed.
- **Build:** `swift build --swift-sdk swift-6.4.1-RELEASE_wasm -c release --product BeebWasmModule --scratch-path .build-wasm` (this is what `scripts/build-wasm.sh` runs).
- **Stripping:** `llvm-objcopy --strip-all`, from the same toolchain.

## The module strategy: a WASI reactor with a C ABI

Before BeebCore was touched, a ten-line Swift module was tried, with `add(a, b)` exported. The module was:

- built with `-Xclang-linker -mexec-model=reactor`;
- exported with `@_expose(wasm, "add") @_cdecl("add")`.

It worked in each of these hosts:

- **Node 24:** it instantiated (with `_initialize` called first), and `add(2, 2)` returned 4.
- **The browser:** the full module, rather than the ten-line one, was run in Chrome under Playwright once it existed.
- **workerd under `wrangler dev` (Wrangler 4.152.0):** the same, in a Worker that imports the module as a precompiled `WebAssembly.Module`.

It needed 14 WASI preview 1 imports: args, environ, `fd_*`, `path_open`, `proc_exit` and `random_get`. A JavaScript shim of about 150 lines, with no dependencies, satisfies them (`web/src/wasi.ts`). The same shim is used in all three hosts, so:

- there's one build of the module for every host;
- there's no JavaScriptKit dependency;
- there are no host-specific entry points.

The ABI is plain C functions over integers and linear-memory pointers (`Sources/BeebWasm/Exports.swift`). The same functions compile natively, so native tests call exactly the code the module exports.

## What needed changing in BeebCore

| Finding | Where | What was done |
|---|---|---|
| Apple's Compression framework isn't available | `Tape/UEF.swift` (gunzipping UEF and CSW tapes) | Replaced with a Swift inflater, `Tape/Inflate.swift`, on every platform. It's tested against Foundation's deflate, with the existing gzip tests. |
| Compression framework | `Machine/Master512.swift` (the RAM in a state, as LZ4) | Unchanged on the Mac. Without the framework the RAM is stored as it is, and Apple's LZ4 container is decoded in Swift (`State/LZ4.swift`, tested against Apple's encoder), so the Mac's states still restore. |
| Compression framework | `State/SaveStateFile.swift` (`.beebstate` is an LZFSE-compressed binary plist) | Unchanged on the Mac. `portableData()` writes the same plist uncompressed, and every build reads both kinds (LZFSE only where the framework is). The ABI saves the uncompressed form. |
| **On wasm32, `Int` is 32 bits** | The disc controllers' and drives' microsecond clocks (`Intel8271`, `WD1770`, `DiscDrive`), with `Int.max` "never" sentinels | Made `Int64`. As `Int`, they'd trap on overflow after 35 minutes of BBC time, and a state from the Mac (holding `Int.max`) wouldn't decode. JSON and plist states are unchanged, because a number is a number. |
| 32-bit `Int` | `TVOutput.totalUnits`, the count of 2MHz video units | Made `Int64`; it would have trapped after 18 minutes. |
| 32-bit `Int` | The debugger's `CYCLES` expression | `Int(truncatingIfNeeded:)`. |
| Full Foundation pulls in ICU: a 67MB module, 36MB of it ICU data | Every file's `import Foundation` | `#if canImport(FoundationEssentials)` imports FoundationEssentials instead, which is only true off the Mac. The module is now 14.5MB stripped (4.2MB gzipped). |
| APIs that FoundationEssentials lacks | `NSString` path methods (in symbol files and disc names) | `String` helpers (`Portability/Paths.swift`) that call NSString on the Mac, so the Mac behaves exactly as before. |
| APIs FoundationEssentials lacks | `trimmingCharacters`, `components(separatedBy: CharacterSet)`, `replacingOccurrences`, `padding`, `String(format:)` (debugger and disc text), `NSLock` (the Econet gateway) | A shim, `Portability/FoundationShims.swift`, compiled only without full Foundation. `String(format:)` goes through `vsnprintf`, and `NSLock` is a no-op, because wasip1 has no threads. |
| Host tooling with no use in WebAssembly | `NSRegularExpression` (BeebAsm and text symbol files), `JSONSerialization` (Baron's symbols), URL resource values (importing Mac folders onto discs), `ByteCountFormatter` (the Quick Look preview) | Left out of builds without full Foundation: the parsers return nothing, and `MacFile.read` throws. Nothing in the ABI reaches them. |
| The wall clock enters the emulation | The Master's RTC is set from `Date()` at power on | Unchanged in BeebCore. The adapter always sets the RTC afterwards, to a time the host gives or to 2000-01-01 00:00:00, so runs repeat exactly. |
| Randomness | Swift's per-process hash seed; `BlankDisc` and the ADFS disc ID use `random` | The WASI shim's environment sets `SWIFT_DETERMINISTIC_HASHING=1`. New-disc randomness doesn't affect running machines. |
| Threads, `Dispatch`, timers | None in BeebCore's emulation | Nothing to do. |
| Global mutable emulation state | None found | Two machines run interleaved in one module and match one alone (a parity scenario checks this). |

The emulation itself wasn't changed. That covers the 6502 and its generated state machine, cycle stretching, the CRTC, ULA, teletext and VideoNuLA, the VIAs, the disc controllers, paging and interrupts. The `-enforce-exclusivity=unchecked` setting applies to the WebAssembly build as it does to the native one.

## Imports the final module needs

There are 35 WASI preview 1 functions, which are the Swift runtime's and wasi-libc's:

| Group | Functions |
|---|---|
| Arguments and environment | `args_get`, `args_sizes_get`, `environ_get`, `environ_sizes_get` |
| Clocks | `clock_res_get`, `clock_time_get` |
| File descriptors | `fd_close`, `fd_fdstat_get`, `fd_fdstat_set_flags`, `fd_filestat_get`, `fd_filestat_set_times`, `fd_pread`, `fd_prestat_get`, `fd_prestat_dir_name`, `fd_read`, `fd_readdir`, `fd_seek`, `fd_sync`, `fd_write` |
| Paths | `path_create_directory`, `path_filestat_get`, `path_filestat_set_times`, `path_link`, `path_open`, `path_readlink`, `path_remove_directory`, `path_rename`, `path_symlink`, `path_unlink_file` |
| Other | `poll_oneoff`, `proc_exit`, `random_get` |

In use, only the arguments and environment, `clock_time_get` (`Date()` for a save state's creation time), `random_get`, the stdio checks, `fd_write` and `fd_prestat_get` are called. The shim refuses the rest with ENOSYS or EBADF, and there are no preopened directories, so no file can be opened.

## How it's checked

- **Native:** `make test`, the whole native suite, which now includes the BeebWasm ABI and parity tests.
- **Parity (`scripts/test-wasm.sh`):** the same scenarios run natively and in the module, and both must match the recorded checkpoints. Save states cross from one host to the other, in both directions.
- **32-bit soak:** `MACBEEB_SOAK=1 node --test web/tests/soak.test.ts` runs 37 minutes of BBC time, past every 32-bit limit, then uses the disc and BASIC.
- **Browser:** the Playwright tests (`make web-test`).
- **Cloudflare:** `make cloudflare-smoke`.

`docs/wasm.md` has the commands and results.
