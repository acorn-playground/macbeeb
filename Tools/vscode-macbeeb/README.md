# MacBeeb debugger for VS Code

Debug 6502 programs running on MacBeeb's BBC Micro from VS Code: breakpoints
in your assembler source (from ld65 debug info), conditional breakpoints and
log points, stepping over, into, out of and back, registers you can edit,
memory, disassembly, and watchpoints (data breakpoints) on any address. It
talks to MacBeeb over the Debug Adapter Protocol on localhost port 6502
(Settings > Debugging in MacBeeb).

## Install

    cd Tools/vscode-macbeeb
    npx @vscode/vsce package
    code --install-extension macbeeb-debug-0.1.0.vsix

Or, to try it, open this folder in VS Code and press F5 (Extension
Development Host).

## Use

With BeebAsm, there's nothing to build: MacBeeb assembles it. Press F5 in a
`.asm` or `.6502` file, or use:

    {
      "type": "macbeeb",
      "request": "launch",
      "name": "Assemble and run",
      "source": "${workspaceFolder}/game.asm"
    }

The source is assembled (it must SAVE what it builds) to a disc in drive 0,
and the first file it SAVEs is *RUN (`file` picks another); breakpoints go
in the source.

With ca65/ld65, build and ask for debug info (see Examples/hello-ca65):

    ca65 -g hello.s -o hello.o
    ld65 -C bbc.cfg -o hello.bin --dbgfile hello.dbg hello.o

Then in `.vscode/launch.json`:

    {
      "type": "macbeeb",
      "request": "launch",
      "name": "Run on the BBC Micro",
      "program": "${workspaceFolder}/hello.bin",
      "loadAddress": 8192
    }

The program is loaded (at `loadAddress`, default 0x2000) and CALLed from
BASIC; `hello.dbg` beside it is picked up automatically. `model`
(`modelB`, `bPlus`, `master128`) and `secondProcessor` choose the machine;
`disc` boots a disc instead. `attach` debugs whatever's running.

For BBC BASIC, press F5 in a `.bas` file, or:

    {
      "type": "macbeeb",
      "request": "launch",
      "name": "Run BASIC on the BBC Micro",
      "basic": "${workspaceFolder}/game.bas"
    }

The program can be text, with or without line numbers (lines without are
numbered on in tens), or tokenised as SAVE writes it (it's listed to a file
to show). It's loaded at PAGE and RUN. Breakpoints go on its lines, with
conditions in BASIC (`I%>10`); F10/F11/Shift-F11 step a statement at a time
over, into and out of PROCs, FNs and GOSUBs; the call stack is the PROC and
FN calls; the Variables view has BASIC's variables, LOCALs first; the debug
console and hovers evaluate BASIC expressions. Turn on the BASIC errors
exception breakpoint to stop where an error happens. `stopOnEntry` stops
at the first statement. With `secondProcessor`, BASIC runs there and is
debugged there. See Examples/hello-basic.

The CPUs appear as threads (the host, and the second processor if fitted).
In the debug console, expressions use registers, flags, symbols and memory:
`A`, `[&70]`, `{&FFFE}`, `count`, `PC+3`.
