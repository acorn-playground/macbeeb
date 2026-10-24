REM Primes: a BBC BASIC program to debug
MODE 7
PRINT "Primes below 100:"
count%=0
FOR n%=2 TO 99
  IF FNprime(n%) THEN PROCshow(n%)
NEXT
PRINT '"Found ";count%;" primes"
END

DEF FNprime(n%)
LOCAL d%,prime%
IF n% < 4 THEN =TRUE
IF n% MOD 2 = 0 THEN =FALSE
prime%=TRUE
d%=3
REPEAT
  IF n% MOD d% = 0 THEN prime%=FALSE
  d%=d%+2
UNTIL d%*d% > n% OR NOT prime%
=prime%

DEF PROCshow(p%)
count%=count%+1
PRINT ;p%;" ";
ENDPROC
