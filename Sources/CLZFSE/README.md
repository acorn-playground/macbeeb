# LZFSE (vendored)

Apple's reference implementation of LZFSE, from https://github.com/lzfse/lzfse
(commit e634ca5), BSD 3-clause licence (see LICENSE). The files are
unmodified; `lzfse_main.c` (its command-line tool) is left out.

It's the Compression framework's format, so save states (`.beebstate`) are
the same on Linux as on the Mac: compressed with LZFSE, and readable on
either. Only Linux builds it; the Mac uses the Compression framework.
