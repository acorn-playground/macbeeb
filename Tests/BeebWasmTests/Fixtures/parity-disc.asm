\ The parity tests' disc (no Acorn code): HELLO, a BASIC program that
\ prints, adds up and writes a file back to the disc, and a !BOOT that
\ CHAINs it.
\
\ Build with: beebasm -i parity-disc.asm -do parity.ssd -opt 3

PUTBASIC "hello.bas", "HELLO"
PUTTEXT "boot.txt", "!BOOT", 0
