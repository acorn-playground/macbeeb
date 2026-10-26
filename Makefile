.PHONY: build test test-debug bench generate beebasm baron wasm wasm-test web-dev web-test cloudflare-smoke

BEEBASM := .build/beebasm/beebasm
BARON := .build/baron/baron

build:
	swift build

# The CPU suites run billions of cycles, so test optimised. BeebAsm and
# Baron are built for the assembler tests.
test: $(BEEBASM) $(BARON)
	MACBEEB_BEEBASM=$(abspath $(BEEBASM)) MACBEEB_BARON=$(abspath $(BARON)) swift test -c release -Xswiftc -enable-testing

test-debug:
	swift test

bench:
	swift run -c release beeb-bench

# Regenerate the 6502 state machine after changing Sources/M6502GenKit.
generate:
	swift run m6502-gen

# BeebAsm (ThirdParty/beebasm, a git submodule), for the app and tests.
# UNIVERSAL=1 builds for Intel too.
beebasm: $(BEEBASM)

$(BEEBASM): $(wildcard ThirdParty/beebasm/src/*.cpp ThirdParty/beebasm/src/*.h)
	@test -f ThirdParty/beebasm/src/main.cpp || git submodule update --init ThirdParty/beebasm
	mkdir -p $(dir $(BEEBASM))
	c++ -std=c++11 -O2 -w $(if $(UNIVERSAL),-arch arm64 -arch x86_64) -o $(BEEBASM) ThirdParty/beebasm/src/*.cpp

# Baron (ThirdParty/baron, a git submodule, with richc inside it), for the
# app and tests. UNIVERSAL=1 builds for Intel too.
baron: $(BARON)

$(BARON): $(wildcard ThirdParty/baron/src/*.c ThirdParty/baron/src/*.h)
	@test -f ThirdParty/baron/extern/richc/src/core/src/arena.c || git submodule update --init --recursive ThirdParty/baron
	mkdir -p $(dir $(BARON))
	cc -std=c17 -O2 -w $(if $(UNIVERSAL),-arch arm64 -arch x86_64) -IThirdParty/baron/src -IThirdParty/baron/extern/richc/src/core/include \
		-o $(BARON) $(filter-out %/fuzz_assemble.c,$(wildcard ThirdParty/baron/src/*.c)) \
		$(shell find ThirdParty/baron/extern/richc/src/core/src -name '*.c')

# WebAssembly (docs/wasm.md): the module, native/WebAssembly parity (with
# states crossing both ways) and the module's own tests, the browser demo,
# its browser tests, and the local Cloudflare proof. They need the swift.org
# toolchain and its WebAssembly SDK, and `npm ci` in web/ and cloudflare/.
wasm:
	scripts/build-wasm.sh

wasm-test: wasm
	scripts/test-wasm.sh

web-dev: wasm
	cd web && npx vite

web-test: wasm
	cd web && npx tsc --noEmit && npx playwright test

cloudflare-smoke: wasm
	cd cloudflare && npx tsc --noEmit && node smoke.ts
