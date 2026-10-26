\ A 16K "OS ROM" for the parity tests (no Acorn code): it exercises the
\ 6502 (binary and decimal arithmetic, the stack, indirect addressing),
\ main RAM, a system VIA timer interrupt, and the CRTC and Video ULA
\ (MODE 1's timings, with a pattern in screen memory), so that native and
\ WebAssembly builds can be compared without licensed ROMs.
\
\ Build with: beebasm -i parity-rom.asm  (writes parity.rom)

ORG &C000

.reset
    SEI
    CLD
    LDX #&FF
    TXS

    \ Decimal mode: 45 + 38 = 83, 83 - 19 = 64 (BCD).
    SED
    CLC
    LDA #&45
    ADC #&38
    STA &70
    SEC
    SBC #&19
    STA &71
    CLD

    \ The sum of 0-255, 16 bits, in &72-&73.
    LDA #0
    STA &72
    STA &73
    LDX #0
.sum
    TXA
    CLC
    ADC &72
    STA &72
    BCC sum_next
    INC &73
.sum_next
    INX
    BNE sum

    \ MODE 1: the CRTC's registers, the ULA's control and palette.
    LDX #0
.crtc
    STX &FE00
    LDA crtc_mode1,X
    STA &FE01
    INX
    CPX #14
    BNE crtc
    LDA #&D8
    STA &FE20
    LDX #15
.palette
    TXA
    ASL A:ASL A:ASL A:ASL A
    STA &74
    TXA
    AND #7
    EOR #7
    ORA &74
    STA &FE21
    DEX
    BPL palette

    \ The screen (&3000-&7FFF): each byte its address's low byte EOR high.
    LDA #&30
    STA &01
    LDA #0
    STA &00
    LDY #0
.fill
    TYA
    EOR &01
    STA (&00),Y
    INY
    BNE fill
    INC &01
    LDA &01
    CMP #&80
    BNE fill

    \ System VIA timer 1, free running every 10,000us, interrupting.
    LDA #&7F
    STA &FE4E
    LDA #&40
    STA &FE4B
    LDA #&10
    STA &FE44
    LDA #&27
    STA &FE45
    LDA #&C0
    STA &FE4E
    CLI

    \ Count, forever; the interrupt counts too.
.main
    INC &80
    BNE main
    INC &81
    \ Every 256 turns, change a byte of the screen.
    LDA &81
    STA &5000
    JMP main

.irq
    PHA
    LDA &FE44            \ clears timer 1's interrupt
    INC &82
    BNE irq_done
    INC &83
.irq_done
    PLA
    RTI

.nmi
    RTI

.crtc_mode1
    EQUB &7F, &50, &62, &28, &26, &00, &20, &22, &01, &07, &67, &08, &06, &00

ORG &FFFA
    EQUW nmi
    EQUW reset
    EQUW irq

SAVE "parity.rom", &C000, &10000
