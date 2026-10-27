# Credits

MacBeeb stands on forty years of other people's work: the engineers who designed the BBC Micro, the authors of its software, and the emulator writers, archivists and enthusiasts who worked out how every chip really behaves and kept it all alive. Their source, their research and their measurements on real machines are what MacBeeb is made from. Thank you.

## The emulators MacBeeb is built from

- **[b2](https://github.com/tom-seddon/b2)**, by Tom Seddon (GPLv3). Much of MacBeeb is a port of b2: the cycle-by-cycle 6502 and the generator that builds it, the machine's per-cycle loop and memory paging, the 6845 CRTC, the Video ULA and VideoNuLA, the SAA5050 teletext chip and its font, the TV output, the 6522 VIAs, the Tube, the 6502 Second Processor and the Master Turbo, the sound chip and the audio path, the ADC, the Master's CMOS clock and the Compact's EEPROM, the serial ULA and 6850 ACIA, fast paste, the disc drive noises and the SCSI hard disc interface. Many of the ROMs, and test suites and results recorded on real hardware, come by way of b2 too.
- **[jsbeeb](https://github.com/mattgodbolt/jsbeeb)**, by Matt Godbolt and its contributors (GPLv3): the disc image model, the drives, and the Intel 8271 and WD1770 disc controllers, the serial ULA's timing, Econet details, and timing tests and their results to check against.
- **[beebjit](https://github.com/scarybeasts/beebjit)**, by Chris Evans: jsbeeb's disc controllers are translated from it, the 8271 following Chris's reverse engineering of the chip's own microcode, and his VIA tests, with results from real BBCs, check MacBeeb's.
- **[BeebEm](https://github.com/stardot/beebem-windows)**, by Dave Gilbert, Mike Wyatt, Chris Needham, Jon Welch, Rob O'Donnell and many others over the years: how the Z80, Master 512 and ARM co-processors are wired to the BBC, the AMX mouse, the SCSI hard disc interface (Jon Welch and Y. Tanaka, by way of b2's port), Econet (with its annotated disassembly of Acorn's DNFS), the co-processors' system discs and Econet's file server discs.
- **[MAME](https://github.com/mamedev/mame)** and its contributors: the floppy drive recordings (CC0) that make MacBeeb's drive sounds, the expansion boards' details, the 6854 Econet chip (Antoine Mine), and the 80186 core by Bryan McPhail, Oliver Bergmann, Fabrice Frances and David Hedley that BeebEm's Master 512 is derived from.
- **[B-em](https://github.com/stardot/b-em)**: the Master Compact's EEPROM (by way of b2), and a reference for VideoNuLA.
- **Tarmac**, by David Sharp: the ARM Second Processor follows the semantics of its ARM core, as BeebEm uses it.

## Included in MacBeeb

- **[BeebAsm](https://github.com/stardot/beebasm)**, by Rich Talbot-Watkins and its contributors (GPLv3): the assembler MacBeeb assembles BeebAsm sources with.
- **[Baron](https://github.com/waitingforvsync/baron)**, by Rich Talbot-Watkins (MIT), BeebAsm's successor, built on his **[richc](https://github.com/waitingforvsync/richc)** library (MIT).
- **[Sparkle](https://sparkle-project.org)**, by Andy Matuschak, Kornel Lesiński, Mayur Pawashe, C.W. Betts and its contributors (MIT, with bsdiff by Colin Percival, sais-lite by Yuta Mori and ed25519 by Orson Peters): how MacBeeb updates itself.

Their licences are in the app, in Contents/Resources.

## The BBC Micro's own software

- The BBC Micro, its operating systems, BBC BASIC, the filing systems, the Tube, Econet and its file servers, and the Master's View, ViewSheet, Edit and Terminal: **Acorn Computers**, and the engineers and programmers who made them. The ROMs are copyright Acorn Computers and their successors.
- CP/M, DOS Plus and GEM, on the Z80 and Master 512 co-processors: **Digital Research**.
- **J.G. Harston**, for the Z80 client ROM 1.21 (his fixes to Acorn's 1.20), the mdfs.net archive of ROMs and documentation, and the UEF tape format specification.
- The Watford DDFS and 32K RAM board ROM (Ian Smith), **Watford Electronics**; the Opus DDOS, **Opus Supplies**; the Aries B32 ROM, **David Barnett and Chris Jordan**.
- **[Elite over Econet](https://elite.bbcelite.com/hacks/elite_over_econet/)**, by **Mark Moxon**: multiplayer Elite with its scoreboard, and the Level 3 file server hard disc he publishes for emulators, which MacBeeb includes. Elite itself is by **Ian Bell and David Braben** (Acornsoft, 1984).
- **VideoNuLA**, by RobC, and the [Bitshifters](https://github.com/bitshifters/bbc-nula) VideoNuLA gallery by Simon Morris.

## Games

- The Game Library's selection and its preservation links are courtesy of **[BBCMicro.co.uk](https://bbcmicro.co.uk)**, the BBC Micro Games Archive, whose contributors have spent years finding, restoring and preserving these games, and the **StarDot** community, whose nominations make its top 20.
- The games and their packaging belong to their authors and publishers: Acornsoft, A&F, Superior Software, Micro Power, Electric Dreams, Aardvark, Go-Dax, 4th Dimension, Melbourne House, Ultimate Play The Game and the programmers who wrote them.

## Testing against the real thing

MacBeeb is checked against suites written, and results measured, by:

- **Wolfgang Lorenz**, for his 6502 test suite (public domain).
- **Klaus Dormann**, for his 6502 and 65C02 functional tests.
- **Michael Steil, Brian Silverman and Barry Silverman**, for [perfect6502](https://github.com/mist64/perfect6502), a transistor-level 6502, from the [Visual 6502](http://www.visual6502.org) netlist by **Greg James, Brian Silverman and Barry Silverman**.
- **Tom Seddon**, for the 65C12's decimal arithmetic recorded on a real Master 128, b2's video tests and his 6502 timing tests.
- **dp111**, **Ed Spittles** and **hoglet** (David Banks), for 6502 timing and decimal mode test discs, gathered by jsbeeb.
- **Frank D. Cringle**, for the ZEXDOC and ZEXALL Z80 exercisers (by way of Andreas Gerlich's YAZE-AG).
- **Daniel Balsom**, for the [SingleStepTests](https://github.com/SingleStepTests/8086) 8086 suite.
- **Kevin Edwards**, for letting his protection decoders be used to test against.

## Knowledge

- **Sean Young**, **boo_boo**, **Vladimir Kladov**, **Patrik Rak** and **David Banks**, whose research documented the Z80's undocumented behaviour.
- **BeebMaster**, for the sideways RAM fitting instructions; **Chris's Acorns** (chrisacorns.computinghistory.org.uk), for the expansion boards' manuals; **zeridajh.org**, for the SN76489's noise generator.
- **PiEconetBridge**, for documenting the Econet printer server protocol.
- **Mark Adler**, whose puff (zlib's reference inflater) MacBeeb's own inflater for gzipped tapes follows, and **Yann Collet**, for the LZ4 format, which MacBeeb decodes where Apple's Compression framework isn't available (in its WebAssembly build).
- **[StarDot](https://stardot.org.uk)**, where so much of this knowledge was found, shared and kept.

MacBeeb itself is free software under the GNU GPL v3.
