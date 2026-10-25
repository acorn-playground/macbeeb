# Hello, Baron

The same program as hello-beebasm, for [Baron](https://github.com/waitingforvsync/baron).
MacBeeb assembles it itself (Baron is built into the app), so there's
nothing to install:

- In VS Code, with the MacBeeb extension: open this folder, set a breakpoint
  in hello.6502, press F5 (or choose a configuration in the Run view). It's
  assembled to a disc, put in drive 0, and *RUN.
- From an agent: `assemble_baron` with `sources: ["hello.6502"]`, then
  `set_breakpoint hello.6502:22` and `run_command *RUN HELLO`.

By hand: `baron hello.6502 -o hello.ssd`, then `*RUN HELLO`.

The section's `filename` is what saves it. Baron doesn't record which source
line made each byte, but its listing shows each statement's text, so
MacBeeb finds each one in the source.
