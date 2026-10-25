# macbeeb

A cycle-exact BBC Micro emulator for the Mac, written in Swift.

![MacBeeb](screenshot.png)

Licensed under the GNU GPL v3 (see [LICENSE](LICENSE)). Parts are derived from
[b2](https://github.com/tom-seddon/b2) (Tom Seddon, GPLv3); see the file
headers.

## Download

Get `MacBeeb-VERSION.dmg` from the
[latest release](https://github.com/acorn-playground/macbeeb/releases/latest)
and drag MacBeeb to Applications. It needs macOS 26, runs natively on Apple
silicon and Intel, is notarised, and updates itself (MacBeeb > Check for
Updates…). The ROMs it needs, and the Z80's and Master 512's system discs,
are built in.

For AI agents, the app includes an MCP server that attaches to the running
app and drives its BBC Micro as you watch. MCP > Connect an AI Agent… gives
the command to add it to Claude Code or Codex, for wherever the app is, and
MCP > Activity Log shows every tool call agents make. For an app in
Applications:
`claude mcp add macbeeb -- /Applications/MacBeeb.app/Contents/MacOS/macbeeb-mcp --attach`.

## Built on the work of others

MacBeeb wouldn't exist without three emulators, and the people who wrote
them did the hard work. Their source, their research into how the real
hardware behaves, and their test results are what this is made from. Thank
you.

- **[b2](https://github.com/tom-seddon/b2)**, by Tom Seddon: the
  cycle-by-cycle 6502 and the machine built around it, the video, the
  VIAs, the sound, paging on the B+ and the Master, the 6502 Second
  Processor and the Master Turbo, and the disc drive noises. Much of
  MacBeeb is a port of b2.
- **[BeebEm](https://github.com/stardot/beebem-windows)**, by Dave Gilbert,
  Mike Wyatt, Chris Needham and many others over the years: the Z80, Master
  512 and ARM co-processors and their system discs, the AMX mouse, and a
  great deal of what's known about the more unusual hardware.
- **[jsbeeb](https://github.com/mattgodbolt/jsbeeb)**, by Matt Godbolt and
  its contributors: the disc drives and the 8271 and 1770 disc controllers
  (themselves from Chris Evans's [beebjit](https://github.com/scarybeasts/beebjit)),
  and timing results to test against.

The drive noises are [MAME](https://github.com/mamedev/mame)'s recordings.
[CREDITS.md](CREDITS.md) (Help ▸ Credits in the app) thanks everyone else
whose work MacBeeb builds on and includes.

## Layout

| Path | What |
| --- | --- |
| `Sources/BeebCore` | The emulation core: pure Swift, no UI frameworks |
| `Sources/BeebROMs` | Bundled ROM images (Acorn copyright, not GPL) |
| `Sources/BeebCapture` | Screenshots and video recording |
| `Sources/BeebLibrary` | The BBC Micro Classics catalogue and covers, the library of imported games, and quick saves |
| `Sources/BeebHost` | Runs a machine on its own thread, paced by audio |
| `Sources/BeebAgentKit`, `Sources/macbeeb-mcp` | Agent tools and the MCP server |
| `Sources/BeebDAP` | The Debug Adapter Protocol server (the VS Code extension is [its own repository](https://github.com/acorn-playground/vscode-macbeeb)) |
| `ThirdParty/beebasm` | BeebAsm (submodule), built into the app |
| `ThirdParty/baron` | Baron (submodule, with richc inside), built into the app |
| `Sources/MacBeeb` | The Mac app |
| `Sources/beeb` | Headless command-line BBC Micro |
| `Sources/M6502GenKit`, `Sources/m6502-gen` | Generator for the 6502's per-cycle state machine |
| `Sources/beeb-bench` | Core speed benchmark |
| `Tests/BeebCoreTests` | CPU suites (Lorenz, Dormann, CMOS ADC/SBC from real hardware, datasheet timings), VIA and timing tests against real-hardware results |
| `Tests/Oracle6502Tests` | Cycle-by-cycle comparison with [perfect6502](https://github.com/mist64/perfect6502) |

## Building and testing

```
scripts/make-app.sh   # builds and signs .build/app/MacBeeb.app
make build
make test      # optimised; the CPU suites run billions of cycles
make bench
```

### Releases

`scripts/release.sh 1.0` builds a universal app signed with the Developer
ID, notarises and staples it and a DMG, and makes the Sparkle update zip and
`appcast.xml` (keeping earlier releases listed). `--publish` then tags the
commit and creates the GitHub release with all three. The app checks
`https://github.com/acorn-playground/macbeeb/releases/latest/download/appcast.xml`,
so updates reach users only once the repo's releases are public.

Before a release, add a `## 1.0` section to `WHATSNEW.md` (newest first: an
optional line of introduction, then `- ` bullets with inline Markdown); the
release script won't build without it. The section becomes the GitHub
release's notes and is embedded in the appcast, so Sparkle's update window
shows it. The app bundles the whole file: on the first launch after an
update it opens What's New, with the releases since the version last run
marked New, and Help > What's New in MacBeeb opens it any time.

It reads `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` and
`CSC_NAME` from `.env.local` (ignored by git). The Sparkle EdDSA key is in
the login keychain under the account `macbeeb`; create it once with
`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account macbeeb`, and
keep a backup (`-x FILE` exports it): losing it means existing installs
can't verify new updates.

`Sources/BeebCore/CPU/M6502+Generated.swift` is generated. After changing
`Sources/M6502GenKit`, run `make generate`; a test fails if it's stale.

## The command line

```
swift run -c release beeb --type 'PRINT 1+1\n' --text
swift run -c release beeb --type 'MODE 2\nDRAW 640,512\n' --screenshot out.png
swift run -c release beeb --load disc.ssd:PROGRAM --type 'RUN\n' --seconds 5 --text
swift run -c release beeb --master --type '*ROMS\n' --text
```

`--pcs` and `--trace N` show where the CPU is spending its time.

## AI agents (MCP)

`macbeeb-mcp` is a Model Context Protocol server that lets agents such as
Claude Code drive a BBC Micro: boot discs, type, run BASIC, read the screen
as text, take screenshots, peek and poke memory, disassemble, record video.
Time is emulated time, so waits are exact and run faster than real time.

```
swift build -c release --product macbeeb-mcp
claude mcp add macbeeb -- "$(pwd)/.build/release/macbeeb-mcp"            # its own headless BBC (--master for a Master 128)
claude mcp add macbeeb -- "$(pwd)/.build/release/macbeeb-mcp" --attach   # the app's BBC, as you watch
```

The app bundle includes it too, at `MacBeeb.app/Contents/MacOS/macbeeb-mcp`.
`--attach` talks to the app over a user-only socket in
`~/Library/Application Support/MacBeeb/`.

Tools: `run_command`, `type_text`, `press_keys`, `key_sequence` (keys down
and up on a timeline, for repeatable scripted play), `load_disc`, `eject_disc`,
`load_tape`, `rewind_tape`,
`load_program`, `run`, `run_until_idle`, `run_until_address`,
`read_screen_text`, `screenshot`, `peek`, `poke`, `disassemble`,
`get_status`, `get_hardware`, `press_break`, `power_cycle` (which can switch
model and fit a Model B expansion board), `load_sideways_bank`,
`save_sideways_bank`,
`save_snapshot`, `restore_snapshot`, `save_state`, `load_state`,
`start_recording`, `stop_recording`; and for debugging, `set_breakpoint`,
`list_breakpoints`, `delete_breakpoint`, `continue`, `step` (including
back), `reverse_continue`, `rewind`, `registers`,
`set_register`, `memory_regions`, `trace`, `debug_log`, `load_symbols`,
`lookup_symbol`, `assemble`, `profile`, `measure_cycles` (a stopwatch
between two addresses) (with `peek`, `poke` and `disassemble` taking a CPU
and address space), and `set_real_time`. `screenshot` can show the last
field, the field so far up to the beam (frame-exact at a breakpoint), or
screen memory as it is now; `peek` can write up to 64K to a file instead
of returning it.

BBC BASIC programs can be debugged as BASIC: `basic_set_breakpoint` (a
line, or one statement in it, with a condition in BASIC such as `I%>10`, a
hit count, or a log message), `basic_list_breakpoints`,
`basic_delete_breakpoint`, `basic_stop_on_errors` (stop where an error
happens, with the calls and variables as they were), `basic_step` (into,
over or out of PROCs, FNs and GOSUBs), `basic_where` (the line, the error,
the PROC/FN calls and their LOCALs), `basic_list`, `basic_variables`,
`basic_evaluate` and `basic_set_variable`. They work with BASIC 2 and 4,
found by the code in the ROM, so whichever BASIC is in which socket.

Agents can set up what they need and rely on it. Breakpoints and symbols
survive `restore_snapshot`, `load_state` and `power_cycle`
(`keep_debugger: false` to start afresh). Tools that run the machine carry on
from a debugger stop (`resume: false` leaves it stopped). In the app the
machine runs in real time between tool calls, so you can watch and play;
`set_real_time` with `on: false` holds it still between calls, for exact
replays, and the window says so until the agent lets go or disconnects (or
you press Resume).

## Assembling with BeebAsm

MacBeeb comes with [BeebAsm](https://github.com/stardot/beebasm) (GPLv3,
built from the `ThirdParty/beebasm` submodule into the app), and assembles
with it for you: in VS Code (F5 in a `.asm` or `.6502` file, or a launch
configuration with `"source"`) and for agents (`assemble`). The source is
assembled to a disc, which goes in drive 0, and the first file it SAVEs is
*RUN, with its symbols and source lines loaded so breakpoints can be
`game.asm:42`. BeebAsm doesn't record which line made each byte, so MacBeeb
lines its `-v` listing up with the source, following INCLUDEs, macros and
FOR loops. `Examples/hello-beebasm` is a program to try. After cloning:
`git submodule update --init --recursive`.

## Assembling with Baron

MacBeeb also comes with [Baron](https://github.com/waitingforvsync/baron)
(MIT, built from the `ThirdParty/baron` submodule into the app), BeebAsm's
successor, and assembles with it the same way: in VS Code (F5 in a Baron
`.6502` file, or a launch configuration with `"baron"`, one source file or
several, and `"baronArgs"` for switches such as `-D` and `--opt`) and for
agents (`assemble_baron`). Every section with a filename goes on one disc in
drive 0, with the symbols (labels, zero-page variables, constants) and
source lines loaded, and the first file saved is *RUN, or the disc boots if
it has a boot option. Baron lists each statement's own text against its
address, so MacBeeb finds each in the source, into macros and included
files and round FOR loops (as many times as Baron's symbols say each ran).
`Examples/hello-baron` is a program to try.

## Source-level debugging (VS Code)

MacBeeb serves the Debug Adapter Protocol on localhost port 6502 (Settings >
Debugging). The MacBeeb extension for VS Code
([Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=AcornPlayground.macbeeb-debug),
[source](https://github.com/acorn-playground/vscode-macbeeb)) connects VS Code to it:
breakpoints in assembler source (from ld65 `--dbgfile` debug info, which
maps every byte to its line), conditions, hit counts and log points;
stepping over, into, out and back, reverse continue; call stacks from the
6502 stack; registers and flags to edit; memory and disassembly; data
breakpoints on any address; and the hardware state. The CPUs are threads.
`Examples/hello-ca65` is a program to try it on.

BBC BASIC programs debug the same way: launch with `"basic":
"${workspaceFolder}/game.bas"` (or press F5 in a `.bas` file), and the
program (text, with or without line numbers, or tokenised as SAVE writes
it) is loaded at PAGE and RUN. Breakpoints go on its lines, with
conditions in BASIC; steps go a statement at a time; the call stack is its
PROCs and FNs; the variables are BASIC's (LOCALs, the rest, arrays, @% to
Z%), to change too; the debug console and hovers evaluate BASIC; and BASIC
errors are exceptions, stopping where they happen. It works on a 6502
Second Processor too (`"secondProcessor": true`). `Examples/hello-basic`
is a program to try.

[Debugging with VS Code](docs/hardware-expansions/vscode.md) (Help ▸
Debugging with VS Code Guide in the app) walks through it all.

Symbols (ld65 debug info, or label files from ld65 `-Ln`, VICE or
`name = $1234` lists) work in the app's debugger and the agent tools too:
`load_symbols`, then names in addresses and expressions, `hello.s:19` as a
breakpoint address, and labelled disassembly. The OS entry points and
hardware registers are always known.

## Profiling

The profiler counts the cycles spent at every address (stretched cycles
included), how often each instruction ran, time in interrupt handlers and
frames, for either CPU. The debugger's Profile tab lists routines (grouped by
symbol) and the busiest instructions, and colours the disassembly by heat;
agents use `profile`. It costs nothing when off.

## Rewind

The machine keeps the last minute: a snapshot every quarter second (with a
thumbnail), and every key and joystick change with the cycle it arrived on.
Anything else from outside (typing, loading, poking, discs, tapes, the
debugger) takes a fresh snapshot. Emulation is deterministic, so restoring
the nearest snapshot and replaying the inputs reaches any cycle exactly;
tests check this against random input on a Master with a second processor.
Machine > Rewind 5 Seconds (⌥⌘←), the toolbar's Rewind button, and the
timeline (⇧⌥⌘←) go back; running on replaces what came after. It costs
nothing measurable, and about 30MB (65MB for a Master with a second
processor).

The debugger uses it to step back (⇧F7) and reverse-continue (⇧⌃⌘Y: back to
the last time a breakpoint hit, e.g. "who wrote this byte?").

## Debugging

Debug > Show Debugger (⌥⌘D) opens the debugger for a machine window. It has
disassembly with a breakpoint gutter, a memory editor for every address
space with changes highlighted, registers and flags you can edit, the
stack, breakpoints (ranges, watchpoints, conditions, log points), every
device's state, the instruction trace and log output, for either CPU.
Continue/pause is ⌃⌘Y, step over/into/out are F6/F7/F8, and the Step By
menu goes by cycle, scanline, frame or interrupt. While it's open, the
machine window shows the screen address under the mouse.

Drop a BASIC program (`.bas`: text, with or without line numbers, or
tokenised) on a machine window, or open one with MacBeeb, and it's loaded
at PAGE and RUN, on a second processor too, as long as BASIC is at its
prompt.

Its BASIC view (the toolbar's Machine Code / BASIC switch; it switches
itself when a BASIC breakpoint or error stops the program) debugs a BBC
BASIC program by its lines: the listing with a breakpoint gutter
(Control-click a line for a condition, a statement or a log message), the
line and statement it's stopped at, the variables (LOCALs first, arrays
opened to their elements, double-click to change one), the PROC and FN
calls, watched expressions, and stopping on errors where they happen.
There, F6/F7/F8 step a statement at a time over, into or out of PROCs, FNs
and GOSUBs, and Pause stops at the next statement.

`Debugger` (in BeebCore) does breakpoints on execute, read or write, over
ranges, with conditions (`A == &41 && [&70] > 3`), hit counts, ROM bank
qualifiers and log points; stepping by instruction, over, out, cycle,
scanline, frame and interrupt; register editing; and instruction traces.
It works on the host CPU and the second processor, stops on the exact
cycle, and costs one test per cycle when nothing is set. Memory can be
read and written in each address space (the CPU's view, or main, shadow,
ANDY, HAZEL, each sideways bank, the OS ROM, parasite RAM) without side
effects.

## The machines

`BBCMicro` follows b2's per-cycle machine loop: CPU with 1MHz cycle
stretching, system and user VIAs, 6845 CRTC, Video ULA, SAA5050, keyboard
matrix, addressable latch and uPD7002 ADC. The video stream feeds a
simulated TV (`TVOutput`) that locks to sync like a real monitor.

Checked against real hardware with scarybeasts' VIA tests, dp111's and Tom
Seddon's timing suites, RMW and BCD tests, jsbeeb's IRQ timing results, and
an IRQ-load test where real Model Bs give 1066-1072 (macbeeb: 1070).

Sound is the SN76489 through b2's filter model; discs are an Intel 8271
(ported from jsbeeb/beebjit) with DFS 1.20. Analogue joysticks come from
game controllers.

The Model A is a Model B with 16K (mirrored into the upper 16K, as A14
isn't decoded) and no user VIA, disc interface, ADC or Tube.

The Model B can have a 1770 board instead of its 8271 (Machine > Disc
Interface): Acorn's (DFS 2.26), Watford's DDB2 (DDFS 1.53) or DDB3 (DDFS
1.54T), or Opus's (DDOS 3.45), with their latch layouts as b2 has them.

The Model B can also have a memory expansion board fitted (Machine >
Hardware Expansions…): a 16K or 32K sideways RAM module, wired as
BeebMaster's; Watford Electronics' 32K Shadow RAM board; or the Aries B32
(32K shared between shadow and sideways RAM), with or without the B12 ROM
board. The shadow RAM boards come with their real ROMs (Shadow RAM OS 2.40,
ARIES-B32 1.00), whose own commands and self-tests work. Any model can have
VideoNuLA instead of its Video ULA (b2's, whose NuLA picture tests pass):
sixteen colours of 4,096, which agents can program and inspect too
(`video_nula`, `set_video_nula_palette`, `bus_write`). The [Hardware Expansion Guide](docs/hardware-expansions/README.md)
(also Help > Hardware Expansion Guide in the app) explains them, and agents
can fit and load them over MCP (`get_hardware`, `power_cycle` with
`memory_board`, `load_sideways_bank`).

The B+ 128K adds shadow RAM, its 12K of paged RAM, sideways RAM in banks 0,
1, 12 and 13, and an Acorn 1770 (DFS 2.26).

The Master 128 (Machine > Model) adds the 65C12, MOS 3.20 and its ROMs,
b2's paging (shadow RAM, ANDY, HAZEL, the VDU driver's view of shadow RAM),
sideways RAM in banks 4-7, the MC146818 clock and CMOS RAM, the keypad, and
a WD1770 (ported from jsbeeb/beebjit) with DFS 2.24 and ADFS.

The keyboard goes by key position (the BBC's layout on the Mac's keys) or,
in Settings > Keyboard, by the character the Mac's layout types, with the
BBC's Shift pressed or released per key as needed. Custom mappings put any
BBC key on any Mac key, in either mode. A disc image can have keys of its
own, a game's controls say (Machine > Controls for This Disc…), which apply
while it's in drive 0, on top of the keys for all discs.

Game controllers are the BBC's analogue joysticks (the d-pad or left stick,
with A or the right trigger to fire), with their other buttons on keys, or,
in Settings > Gamepad, keys altogether: each button and direction presses
the key you give it. As with the keyboard, a disc image can have settings of
its own.

The Master Compact is a Master without the Tube, analogue port, keypad,
cassette or clock: MOS 5.10 with ADFS, BASIC 4 and Utils, a 1772 with
3.5" drives, a digital joystick (on the user VIA), and its settings in a
PCD8572 EEPROM. It boots ADFS, so it wants .adf/.adl discs; ADFS images work
on any 1770 machine, and writes go back to the file as with DFS discs.

Or the Acorn Z80 Second Processor, for CP/M (Machine > Model > Second
Processor, `--z80`): a 6MHz Z80 with 64K, client ROM 1.21, wired as BeebEm
has it. It starts with the bundled CP/M 2.2 system disc (Acorn's CP/M
Utilities disc) in drive 0 and boots to `A>`. The Z80 core passes ZEXDOC and
ZEXALL in full, undocumented flags included.

Or, on a Master 128, the Acorn Master 512 (`--master --512`): an 80186 with
1MB, its BIOS, the Tube on I/O ports and disc transfers by DMA, wired as
BeebEm has it. It starts with the bundled DOS Plus 1.2 boot disc in drive 0
and boots to `A>`, which takes about 40 seconds, as on the real machine. A
disc of your own in drive 0 takes its place; across a power cycle that changes
co-processor, the system disc changes with it.
The Master 512's other discs are bundled too (File > Insert Bundled Disc, or
`load_disc` with `bundled` for agents), in its 800K DOS format (`.img`, as
BeebEm has it; 720K PC `.dos` discs work as well). With GEM Applications in
drive 1, `B:` then `GEM` starts GEM's desktop.

An AMX mouse is on the user port of every machine but the Compact (wired
for the Master 512's mouse when that's fitted, as BeebEm does): its
quadrature signals go to CB1/CB2 and port B, so the VIA sees real edges. Once
software is reading it (its interrupts enabled), clicking the screen hands
the Mac's mouse over; Machine > Capture or Release Mouse (⌃⌘M) takes it
back. Agents use the `mouse` tool.

Or the Acorn ARM Second Processor, the ARM Evaluation System (`--arm`): an
8MHz ARM1 with 4MB, supervisor ROM 1.00, wired as BeebEm has it, with an ARM
core following the semantics of BeebEm's (David Sharp's Tarmac). It boots to
the `A*` prompt; with ARM BASIC's disc (BeebEm's `armdisc3.adl`) in an ADFS
machine, `*ADFS`, `*MOUNT 4` and `*AB` start ARM BBC BASIC V.

Any of them except the Compact can have a 6502 Second Processor (Machine > Model, `--tube`):
a 3MHz 65C02 with 64K on the Tube, booting Tube OS 1.10, following b2.

Or the Master Turbo (`--turbo`): a Master 128 with the 65C102 Co-Processor,
the same 65C02 and 64K at 4MHz on the Master's internal Tube (seen while
ACCCON's ITU bit is set), booting its Tube OS 1.20, as b2 has it.

File > New Disc… (⌘N) makes a blank disc image, formatted as DFS's *FORM
or ADFS's FORM leaves one: DFS on 40 or 80 tracks, single or double sided
(.ssd/.dsd), or ADFS S, M or L (.adf/.adl). It has the title you give it
(or the file's name), and goes in the drive you choose, ready to save to.

File > Show Disc Contents (⇧⌘I) lists the files on the discs in the
drives, DFS (both sides of a double-sided disc, as the BBC's drives 2 and 3)
or ADFS (with its directories). Files drag out to Finder, each with a .inf
file holding its BBC name, addresses and lock, and Mac files and folders drag
in (named and addressed by their .inf files if they have them; without one,
a .bas file of text is tokenised as BBC BASIC 2 would, and a .txt file's
lines end in CRs for *TYPE and *EXEC). A BASIC program can be exported as
text (Export as Text…, in the file's menu). Files can be
renamed, readdressed, locked and deleted, ADFS directories made, and the
title and boot option set, with undo. A change waits until the drive's been
idle a few seconds, then goes in as if the disc were swapped for one with the
change made, and back to its file: ADFS remembers the disc it last used for
about 4 seconds, and after that sees a new disc ID and says "Disc changed"
until *MOUNT, as with a real disc swapped.

In Finder, Quick Look (space) shows a disc image's catalogue: its title,
boot option and files, both sides of a double-sided DFS disc and every ADFS
directory. It's an app extension in MacBeeb.app (Sources/MacBeebQuickLook,
bundled by `scripts/make-app.sh`), which macOS picks up once the app has
been opened; it covers BeebEm's type for these files too, which BeebEm
claims where it's installed.

The drives sound as they work: the motor spinning up, running and down,
the head stepping and seeking, from MAME's recordings of 5.25" drives (3.5"
on the Compact), mixed in at the sound chip's rate as b2 does. Machine >
Disc Drive Sounds turns them off; `beeb --drive-sounds` puts them in a
recording.

Save states (`.beebstate`) and snapshots capture everything, discs and disc
controllers included, so a restored machine carries on cycle for cycle.

File > Quick Save (⇧⌘F6) and Quick Load (⇧⌘F5) keep the last five save
states of the disc in drive 0 (or drive 1, if drive 0 has none), in
Application Support/MacBeeb/Snapshots. They belong to the disc, not its
name or contents: a library game's disc by its library ID, and any other
disc file by an ID MacBeeb gives it when it's first opened (Media.json),
which follows it through the BBC's writes and renames. A save is written
aside, read back and checked, and only then replaces the oldest; a load is
checked and built into a new machine before the running one is replaced.
Restoring a library game puts its disc file back as it was in the snapshot;
other disc files aren't rewound on disc, and the restored disc stays in
memory. F5 and F6 without ⌘⇧ go to the BBC, and ⌘F5 is left to VoiceOver.
Each save keeps a screenshot of the frame and its time. The Game Library
shows a game's snapshots in its details as screenshots to click, under a
Resume button that loads the newest; a game's tile has a Resume link
instead of "Ready to play" once it has one.

File > Game Library (⇧⌘K) has three tabs. BBC Micro Classics is BBCMicro.co.uk's top 20
games (`Sources/BeebLibrary/Data/classics.json`) and a book for the
archive. Author's Picks is twenty more chosen by MacBeeb's author, also from the
archive; seven are in the top 20 too, and are the same games, installed once. MacBeeb doesn't download or include any game: Get opens the game's
page on BBCMicro.co.uk in the default browser, and, if the user agrees,
MacBeeb watches Downloads (or a folder chosen in Settings > Games) while
it's open, for a finished .ssd or .dsd. A disc is recognised only by its
SHA-256 matching the catalogue; an unknown disc that turns up while a
download is awaited is offered for the user to identify. Recognised discs
are copied into Application Support/MacBeeb/Library (the original is only
read), and Play runs a working copy on the machine the game needs: a Model
B, with a 6502 Second Processor for Elite, or a Master 128 for Repton Infinity's
enhanced Master version and games that need sideways RAM, such as Exile (its
disc boots to the game's menu there; whether its loader picks the enhanced
version on a Master hasn't been confirmed). `Sources/BeebLibrary/COVERS.md` records
where the covers came from and how the fingerprints were made.
`MACBEEB_CLASSICS_DISCS=/folder/of/discs make test` boots each game's real
disc (kept outside the repository) as Play does. My Games, the third tab, are the user's own: a disc image of any
format MacBeeb reads and/or a cover picture, dropped on the bookshelf in
either order or together (a disc and a picture with the same name pair up),
with a title, machine and start method (Shift-Break, a typed command, or
just inserting the disc) filled in on a sheet. Dropping a disc or picture
on a game gives it one later. Copies live in Library/MyGames; a disc that
matches a Classic's fingerprint goes to the Classics instead. Settings > Games > When
MacBeeb opens can make the bookshelf the only window at launch; a machine
window opens to play a game, or from File > New BBC Micro Window (⌥⌘N).

Cassettes (.uef, including gzipped, and .csw) play through a 6850 ACIA and
serial ULA that decode the tape's tones as the real hardware does, so
`*TAPE` and `CHAIN ""` load at real speed on both models (File > Load Tape,
or `--tape` for `beeb`). b2 doesn't emulate tape; this design follows the
datasheet, with carrier detect timing from jsbeeb's and BeebEm's
measurements. Nothing is attached to RS423.

## The 6502

`M6502` is a port of b2's simulator: each `tick()` runs one bus cycle and
leaves the next access on `abus`/`access`/`dbus` for the host to perform, so
the machine sees every cycle (for 1MHz stretching and device timing).
Variants: NMOS with undocumented instructions (Model B), CMOS 65C12 (Master),
and Rockwell 65C02 (6502 Second Processor).

It's checked against:

- Wolfgang Lorenz's test suite (all 222 tests, including undocumented NMOS
  instructions).
- Klaus Dormann's functional and decimal tests, on every variant.
- Every ADC/SBC input on a real Master 128's 65C12.
- WDC/Rockwell datasheet cycle counts for CMOS-specific timings.
- perfect6502, a simulation of the NMOS chip's transistors: every stable
  opcode with random operands, flags and memory, IRQ/NMI at every cycle
  offset, NMI hijacking BRK/IRQ, and random code under random interrupts,
  compared on every cycle. This found three interrupt-timing differences
  from b2, now fixed (see `M6502+Special.swift`).
