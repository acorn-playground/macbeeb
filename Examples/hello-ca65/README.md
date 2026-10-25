# Hello, ca65

A tiny program for trying MacBeeb's debugger. `make` (with cc65 installed:
`brew install cc65`) builds `hello.bin` and `hello.dbg`, ld65's debug info,
which maps every byte back to its source line; both are included, built.

- In VS Code, with the MacBeeb extension
  (https://github.com/acorn-playground/vscode-macbeeb): open this folder,
  set a breakpoint in hello.s, press F5.
- From an agent: `load_symbols hello.dbg`, `poke` hello.bin at &2000,
  `set_breakpoint hello.s:19`, `run_command CALL &2000`.
- In the app: load it with the agent tools or `beeb --load`, then Debug >
  Show Debugger.
