# perfect6502 (vendored)

Transistor-level NMOS 6502 simulation by Michael Steil, Brian Silverman and
Barry Silverman, from https://github.com/mist64/perfect6502 (commit 09fc542),
MIT licence (see LICENSE). Used only as a test oracle for BeebCore's 6502.

The upstream files are unmodified but for one line: `netlist_sim.c` allocates
its state with `calloc` rather than `malloc`, as upstream never sets
`groupcount` (zeroed memory on the Mac hid it; glibc's doesn't, and it
crashed on Linux). `shim.c` and `include/Perfect6502.h` add the small API
the Swift tests use.
