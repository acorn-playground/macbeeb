# Debugging BBC BASIC

`primes.bas` is a BBC BASIC program to debug, in VS Code (with the MacBeeb
extension, Tools/vscode-macbeeb) or in MacBeeb's own debugger.

In VS Code, open this folder and press F5 in `primes.bas`, or pick a launch
configuration: one stops at the first statement, the other runs on a 6502
Second Processor. The program is tokenised, loaded at PAGE and RUN. Set
breakpoints in the gutter (on lines without numbers, which are numbered on
in tens as BASIC would: `MODE 7` is line 20), with conditions in BASIC
(`n%>50`) or log messages (`n%={n%}`). F10, F11 and Shift-F11 step a statement
at a time over, into and out of PROCs and FNs. The Variables view shows
`FNprime`'s LOCALs `d%` and `prime%`, and the program's variables; hover over one, or
evaluate BASIC expressions in the debug console (`count%*2`). Errors stop
where they happen (the BASIC errors exception breakpoint): try changing
`d%=3` to `d%=0`.

In MacBeeb, type the program in (or paste it), open Debug > Show Debugger
(⌥⌘D), choose BASIC in the toolbar and click a line's gutter.
