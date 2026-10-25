# Debugging with VS Code

Write your program in [Visual Studio Code](https://code.visualstudio.com) and debug it on MacBeeb's BBC Micro: press F5 and it's assembled (or loaded), run in MacBeeb, and stopped at the breakpoints you set in your source. Step through it a line at a time, or backwards, watch the registers and memory change, and see where it goes wrong as it runs on the BBC in front of you.

It works for 6502 assembler (BeebAsm, Baron, or ca65 and ld65) and for BBC BASIC.

## Getting started

1. Install the **MacBeeb** extension: in VS Code's Extensions view, search for "MacBeeb", or get it from the [Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=AcornPlayground.macbeeb-debug).
2. Open the folder with your program in it, and open its source file.
3. Click in the margin beside a line to set a breakpoint (a red dot).
4. Press **F5**.

The extension starts MacBeeb if it isn't running. MacBeeb assembles your program, puts it on a disc in drive 0 and runs it, and stops at your breakpoint, with the line highlighted in VS Code.

MacBeeb listens for VS Code on port 6502. That's on unless you've turned it off in **MacBeeb ▸ Settings ▸ Debugging**, where you can also change the port.

## Your language

### BeebAsm

There's nothing to install: BeebAsm comes with MacBeeb. Press F5 in a `.asm` or `.6502` file. The source must `SAVE` what it builds, e.g. `SAVE "GAME", start, end`; the first file it saves is `*RUN`.

### Baron

[Baron](https://github.com/waitingforvsync/baron), BeebAsm's successor, comes with MacBeeb too. Press F5 in a Baron `.6502` file. Every `SECTION` with a `filename` goes on the disc, and the first file saved is `*RUN`, or the disc boots if you give it a boot option (`--opt 3`).

If you also use the Baron extension, MacBeeb uses its settings (the root source files, switches and defines). That extension takes F5 for its own Run in Emulator, so start debugging from VS Code's **Run ▸ Start Debugging** instead. (Or point Baron's Run in Emulator at MacBeeb: set `baron.emulatorPath` to `open` and `baron.emulatorArgs` to `["-a", "MacBeeb", "${image}"]`.)

### ca65 and ld65

Build with debug information, so MacBeeb knows which line made each byte:

```
ca65 -g hello.s -o hello.o
ld65 -C bbc.cfg -o hello.bin --dbgfile hello.dbg hello.o
```

Then add a launch configuration (below) with `"program"`: the binary is loaded into memory and `CALL`ed, and the `.dbg` file beside it is found automatically.

### BBC BASIC

Press F5 in a `.bas` file. It can be plain text, with or without line numbers (lines without are numbered on in tens, as `AUTO` would), or tokenised, as BASIC's `SAVE` writes it. The program is loaded at `PAGE` and `RUN`.

Breakpoints go on lines and can have conditions written in BASIC, such as `I%>10`. Stepping goes a statement at a time, into, over and out of `PROC`s, `FN`s and `GOSUB`s. The call stack is the program's `PROC` and `FN` calls, and the Variables view has its variables and arrays, `LOCAL`s first. **BASIC errors**, under Breakpoints, stops where an error happens (one no `ON ERROR` handles), rather than at the prompt; it's on to start with. **All BASIC errors** stops at every one, before `ON ERROR` sees it.

## While it's stopped

- **Step** with F10 (over), F11 (into) and Shift-F11 (out). **Step Back** and **Reverse Continue** in the debug toolbar go backwards, through the last minute or so of the machine's history.
- **Variables** shows the registers and flags (double-click one to change it) and the hardware: the video chips, VIAs, sound and the rest. For BASIC, it shows the program's variables.
- **Watch** and the **Debug Console** evaluate expressions: registers and flags (`A`, `X`, `C`), symbols from your program (`count`), memory (`[&70]` for a byte, `{&FFFE}` for a word) and arithmetic (`PC+3`). Hover over a symbol in your source to see its value.
- **Breakpoints** can have a condition, a hit count, or a log message that prints instead of stopping. You can also break on a symbol's name or an address (a function breakpoint), or on memory being read or written (a data breakpoint: add a symbol or address to Watch, right-click it and choose **Break on Value Change**).
- **Disassembly** and **memory**: **Open Disassembly View** (right-click in the call stack) steps through code with no source, and the memory button beside a value shows memory as hex (with VS Code's Hex Editor extension).
- The CPUs appear as threads: the BBC's own 6502, and the second processor if one is fitted.

## Launch configurations

F5 with no configuration works for most programs. For more control, add `.vscode/launch.json` to your folder. VS Code's **Run ▸ Add Configuration…** offers MacBeeb templates. For example:

```
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "macbeeb",
      "request": "launch",
      "name": "Run on a Master with a second processor",
      "source": "${workspaceFolder}/game.asm",
      "model": "master128",
      "secondProcessor": true,
      "stopOnEntry": true
    }
  ]
}
```

What you can put in a launch configuration:

- **What to run** (one of these):
  - `source`: a BeebAsm file.
  - `baron`: a Baron file, or a list of them, with `baronArgs` for switches such as `-D DEBUG=TRUE` or `--opt 3`.
  - `basic`: a BBC BASIC program.
  - `program`: an assembled binary, with `loadAddress` (default &2000) and `execAddress` (default the load address) and `symbols` (an ld65 `.dbg` file, or a list of labels).
  - `disc`: a disc image to boot.
- **The machine:** `model` (`modelB`, `bPlus`, `master128` or `masterCompact`) and `secondProcessor` (`true` to fit a 6502 Second Processor, where your program then runs).
- **Starting:** `stopOnEntry` stops at the first instruction (or, for BASIC, the first statement). `file` picks which saved file to `*RUN`.
- **Already running?** A configuration with `"request": "attach"` debugs whatever MacBeeb is running now, without restarting it.

## Examples

MacBeeb's [Examples](https://github.com/JamesRandall/macbeeb/tree/main/Examples) folder has small programs set up for VS Code, each with its launch configurations: `hello-beebasm`, `hello-baron`, `hello-ca65` and `hello-basic`. Open one of those folders in VS Code, set a breakpoint and press F5.

## MacBeeb's own debugger

MacBeeb has a debugger of its own too, in **Debug ▸ Show Debugger**: the same breakpoints, stepping and history, with a BASIC view. Use whichever suits you, or both at once: breakpoints set in VS Code appear in MacBeeb's debugger too.

## If it doesn't connect

- Check **Settings ▸ Debugging** in MacBeeb: debugging must be on, and the port must match the one VS Code uses (6502, unless you set `"port"` in your launch configuration). A change there takes effect when MacBeeb next starts.
- If VS Code says MacBeeb isn't listening, start MacBeeb yourself, then press F5 again.
- If assembling fails (a typo, or nothing saved), VS Code shows the assembler's errors when it stops the launch; the assembler's other messages are in the Debug Console.
