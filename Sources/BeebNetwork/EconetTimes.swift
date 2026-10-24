import BeebCore
import Foundation

/// The Econet Times network's programs: reporters file stories to the file
/// server from their own BBCs, and the editor prints them as a newspaper on
/// the printer server, with a masthead drawn in the BBC's own characters
/// and the stories in two columns, in Epson bold and underline. All BBC
/// BASIC II and the network filing system's own calls.
///
/// A story is a file in the server's shared directory, named for its desk:
/// CR-terminated strings (the headline, the reporter, their station, then
/// the paragraphs) and an empty one to end. Acorn's Level 1 server can't
/// say whether a file exists (no OSFILE 5 or OPENIN), so the programs
/// *LOAD and take "Not found" (error 214) for no.
public enum EconetTimes {
    /// The desks: their names and their stories' files. The same DATA in
    /// both programs.
    static let desks = """
    9000 DATA News,NEWS,Sport,SPORT,Weather,WEATHER,Clubs,CLUBS
    """

    /// A reporter's desk: choose a desk, write a headline and a story (or
    /// keep the one written for it), and file it. On the reporters' own
    /// discs (they boot it), and on the file server.
    public static let report = """
    10 REM The Econet Times: a reporter's desk
    20 MODE 7:DIM B% 1300,O% 20,D$(4),F$(4)
    30 *FX6,10
    40 RESTORE 9000:FOR I%=1 TO 4:READ D$(I%),F$(I%):NEXT
    50 ON ERROR GOTO 900
    60 Z$="net":*NET
    70 *FX5,4
    80 O%?0=8:O%?1=0:A%=&13:X%=O% MOD 256:Y%=O% DIV 256:CALL &FFF1:S%=O%?1
    100 Z$="":CLS
    110 FOR I%=1 TO 2:PRINT CHR$141;CHR$131;"     The Econet Times":NEXT
    120 PRINT CHR$134;"     Reporter's desk";:IF S% PRINT CHR$135;"station ";S% ELSE PRINT
    130 PRINT
    140 PRINT CHR$131;"Which desk are you writing for?"
    150 FOR I%=1 TO 4:PRINT CHR$130;" ";I%;CHR$135;D$(I%):NEXT
    160 REPEAT D%=GET-48:UNTIL D%>0 AND D%<5
    170 PRINT:PRINT CHR$134;"The ";D$(D%);" desk"
    180 RESTORE 9100:IF D%>1 FOR I%=2 TO D%:REPEAT READ A$:UNTIL A$="":NEXT
    190 READ H$
    200 PRINT CHR$131;"Headline (RETURN keeps ours):"
    210 PRINT CHR$135;H$
    220 INPUT LINE "" A$:IF A$<>"" H$=A$
    230 INPUT LINE "Your name: " N$:IF N$="" N$="Our reporter"
    240 P%=B%:PROCput(H$):PROCput(N$):PROCput(STR$ S%)
    250 PRINT CHR$131;"Your story, a paragraph at a time."
    260 PRINT CHR$131;"RETURN on its own ends it (now, for"
    270 PRINT CHR$131;"the one we've written)."
    280 C%=0
    290 REPEAT INPUT LINE "" A$:IF A$<>"" PROCput(A$):C%=C%+1
    300 UNTIL A$="" OR P%>B%+1000
    310 IF C%=0 PROCours
    320 PROCput("")
    330 Z$="file":PRINT CHR$134;"Filing it with the file server..."
    340 OSCLI "SAVE "+F$(D%)+" "+STR$~B%+" "+STR$~P%
    350 Z$="":PRINT CHR$130;"Filed! The editor (station 1) prints"
    360 PRINT CHR$130;"it in the next edition."
    370 PRINT
    380 PRINT CHR$131;"P";CHR$135;"print a proof on the printer"
    390 PRINT CHR$131;"  ";CHR$135;"server; any other key, another story"
    400 K$=GET$:IF K$="P" OR K$="p" PROCproof
    410 GOTO 100
    500 DEF PROCput(A$)
    510 $P%=A$:P%=P%+LEN A$+1
    520 ENDPROC
    530 DEF PROCours
    540 REPEAT READ A$:IF A$<>"" PROCput(A$)
    550 UNTIL A$=""
    560 ENDPROC
    570 DEF PROCproof
    580 Z$="proof":PRINT CHR$134;"Printing a proof..."
    590 VDU 2:*FX3,10
    600 G%=B%:PRINT "PROOF: The ";D$(D%);" desk"
    610 PRINT STRING$(60,"-")
    620 VDU 27,69,27,45,1:R$=FNnext:PROCwrap(60):VDU 27,45,0,27,70
    630 R$="By "+FNnext:T$=FNnext:IF T$<>"0" R$=R$+", station "+T$
    640 PROCwrap(60)
    650 REPEAT P$=FNnext:IF P$<>"" R$=P$:PRINT:PROCwrap(60)
    660 UNTIL P$=""
    670 PRINT STRING$(60,"-"):PRINT
    680 *FX3,0
    690 VDU 3:Z$=""
    700 PRINT CHR$130;"Printed: see Window > Print Centre."
    710 ENDPROC
    720 DEF FNnext
    730 T$=$G%:G%=G%+LEN T$+1:=T$
    740 DEF PROCwrap(W%)
    750 REPEAT PRINT FNcut(W%):UNTIL R$=""
    760 ENDPROC
    770 DEF FNcut(W%)
    780 IF LEN R$<=W% L$=R$:R$="":=L$
    790 I%=W%+1
    800 REPEAT I%=I%-1:UNTIL I%=1 OR MID$(R$,I%,1)=" "
    810 IF I%=1 L$=LEFT$(R$,W%):R$=MID$(R$,W%+1):=L$
    820 L$=LEFT$(R$,I%-1):R$=MID$(R$,I%+1):=L$
    900 IF ERR=17 *FX3,0
    910 IF ERR=17 VDU 3:PRINT:END
    920 *FX3,0
    930 VDU 3:PRINT:PRINT CHR$129;:REPORT:PRINT
    940 IF Z$="net" OR Z$="file" PRINT CHR$131;"(The file server may be starting.)"
    950 IF Z$="proof" PRINT CHR$131;"(The printer may be busy.)"
    960 PRINT CHR$131;"Press a key to try again."
    970 K%=GET
    980 IF Z$="net" GOTO 60
    990 IF Z$="file" GOTO 330
    995 IF Z$="proof" PROCproof:GOTO 370
    999 GOTO 100
    \(desks)
    9100 DATA Ten BBCs Join Hands
    9110 DATA "Every machine in the computer room is now on one network. A single cable runs from desk to desk, and the file server keeps everyone's work safe on its discs."
    9120 DATA "Teachers say nobody queues for the disc drive any more. The printer, on the other hand, has never been so busy."
    9130 DATA ""
    9200 DATA Staff Lose Chess Cup To Station 3
    9210 DATA "The staff against pupils chess match was played over Econet this year, every move sent from one BBC to another in a four-way handshake."
    9220 DATA "The staff blamed a slow reply from the file server. The referee, a BBC Micro, said the handshake was perfectly fair."
    9230 DATA ""
    9300 DATA "Fine, With Scattered Packets"
    9310 DATA "A ridge of high pressure over the computer room brings settled conditions. Expect light traffic in the morning, and heavier after lunch, when the printer warms up."
    9320 DATA "Outlook: dry and bright. The clock station keeps the whole network in step."
    9330 DATA ""
    9400 DATA Printer Club Meets On Thursdays
    9410 DATA "Anyone who can type VDU 2 is welcome. This week: banners, calendars, and why the printer only ever prints one station's job at a time."
    9420 DATA "Bring your own fanfold paper. The club's motto: if it can be printed, it will be."
    9430 DATA ""
    """

    /// The editor's desk: a board of what's been filed, checked every few
    /// seconds, and the paper printed on the printer server. On the
    /// editor's own disc (it boots it), and on the file server.
    public static let editor = """
    10 REM The Econet Times: the editor's desk
    20 MODE 7:VDU 23,1,0;0;0;0;
    30 DIM S% 1300,H% 5200,O% 20,Z% 20,D$(4),F$(4),U%(4),W%(4),L$(1,60),K%(1,60),N%(1)
    40 *FX6,10
    50 RESTORE 9000:FOR I%=1 TO 4:READ D$(I%),F$(I%):NEXT
    60 ON ERROR GOTO 500
    70 Z$="net":*NET
    80 *FX5,4
    90 Z$="edition":E%=1:OSCLI "LOAD EDITION "+STR$~S%:E%=VAL $S%
    100 Z$="":CLS
    110 FOR I%=1 TO 2:PRINT CHR$141;CHR$131;"     The Econet Times":NEXT
    120 PRINT CHR$134;"     Editor's desk";CHR$135;"edition ";E%
    200 REM The board: each desk's story, if it's been filed
    210 PRINT TAB(0,4);:C%=0:F%=0
    220 C%=C%+1:IF C%>4 GOTO 300
    230 U%(C%)=0:Z$="desk":OSCLI "LOAD "+F$(C%)+" "+STR$~S%
    240 Z$="":U%(C%)=1:F%=F%+1
    250 PROCline(CHR$130+LEFT$(D$(C%)+"       ",8)+CHR$135+$S%)
    260 GOTO 220
    270 PROCline(CHR$129+LEFT$(D$(C%)+"       ",8)+CHR$135+"waiting for a story")
    280 GOTO 220
    300 PROCline("")
    310 PROCline(CHR$134+"The reporters' BBCs file stories with")
    320 PROCline(CHR$134+"the file server (station 254). This")
    330 PROCline(CHR$134+"board looks for them every few seconds.")
    340 PROCline("")
    350 IF F% PROCline(CHR$131+"P"+CHR$135+"print this edition on the printer") ELSE PROCline(CHR$135+"Nothing to print yet.")
    360 IF F% PROCline(CHR$131+" "+CHR$135+"server (station 235)") ELSE PROCline("")
    370 PROCline(CHR$131+"N"+CHR$135+"start the next edition")
    380 T%=TIME:REPEAT K$=INKEY$(10):UNTIL K$<>"" OR TIME-T%>400
    390 IF F%>0 AND (K$="P" OR K$="p") PROCprint
    400 IF K$="N" OR K$="n" PROCnext:GOTO 100
    410 GOTO 210
    500 IF ERR=214 AND Z$="desk" GOTO 270
    510 IF ERR=214 AND Z$="edition" GOTO 100
    520 *FX3,0
    530 VDU 3:IF ERR=17 CLS:VDU 23,1,1;0;0;0;:END
    540 PRINT TAB(0,21);:PROCline(CHR$129+"The network says:")
    550 PRINT CHR$135;:REPORT:PRINT SPC(10)
    560 IF Z$="print" PROCline(CHR$131+"(The printer may be busy.)") ELSE PROCline(CHR$131+"Trying again...")
    570 T%=TIME:REPEAT UNTIL TIME-T%>300
    580 PRINT TAB(0,21);:PROCline(""):PROCline(""):PROCline("")
    590 IF Z$="net" GOTO 70
    600 IF Z$="edition" GOTO 90
    610 GOTO 100
    1000 DEF PROCline(A$)
    1010 PRINT LEFT$(A$+STRING$(39," "),39)
    1020 ENDPROC
    1100 DEF PROCprint
    1110 PRINT TAB(0,21);:PROCline(CHR$134+"Printing edition "+STR$ E%+"...")
    1120 Z$="print":C%=0
    1130 FOR I%=1 TO 4:IF U%(I%) C%=C%+1:W%(C%)=I%:OSCLI "LOAD "+F$(I%)+" "+STR$~(H%+(I%-1)*1300)
    1140 NEXT
    1150 VDU 2:*FX3,10
    1160 PROCmasthead
    1170 FOR J%=1 TO C% STEP 2
    1180 PROCcolumn(0,W%(J%)):N%(1)=0:IF J%<C% PROCcolumn(1,W%(J%+1))
    1190 PROCrows
    1200 NEXT
    1210 PRINT STRING$(77,"=")
    1220 PRINT "Filed from the reporters' BBCs to the file server, station 254, and printed"
    1230 PRINT "by the printer server, station 235: every byte of it over Econet."
    1240 PRINT
    1250 *FX3,0
    1260 VDU 3:Z$=""
    1270 PRINT TAB(0,21);:PROCline(CHR$130+"Printed: see Window > Print Centre.")
    1280 ENDPROC
    1300 DEF PROCmasthead
    1310 PRINT SPC(36);"T H E":PRINT
    1320 T$="ECONET":FOR V%=1 TO 8:L$=""
    1330 FOR Q%=1 TO LEN T$
    1340 ?Z%=ASC MID$(T$,Q%,1):X%=Z% MOD 256:Y%=Z% DIV 256:A%=10:CALL &FFF1
    1350 B%=Z%?V%:FOR I%=1 TO 8
    1360 IF B% AND 128 L$=L$+"#" ELSE L$=L$+" "
    1370 B%=(B%*2) AND 255:NEXT
    1380 NEXT
    1390 PRINT SPC(14);L$:NEXT
    1400 PRINT:PRINT SPC(32);"T  I  M  E  S"
    1410 PRINT STRING$(77,"=")
    1420 L$="No. "+STR$ E%:R$="Price: one packet"
    1430 PRINT L$;SPC(29-LEN L$);"PRINTED OVER ECONET";SPC(29-LEN R$);R$
    1440 PRINT STRING$(77,"="):PRINT
    1450 ENDPROC
    1500 DEF PROCcolumn(S,D)
    1510 REM (Loaded before printing began: the printer mustn't wait.)
    1520 N%(S)=0:G%=H%+(D-1)*1300
    1530 PROCadd(S,F$(D)+" "+STRING$(36-LEN F$(D),"-"),3)
    1540 PROCadd(S,"",0)
    1550 R$=FNnext:REPEAT PROCadd(S,FNcut(37),1):UNTIL R$=""
    1560 R$="By "+FNnext:T$=FNnext:IF T$<>"0" R$=R$+", station "+T$
    1570 REPEAT PROCadd(S,FNcut(37),2):UNTIL R$=""
    1580 REPEAT P$=FNnext:IF P$<>"" PROCadd(S,"",0):R$=P$:REPEAT PROCadd(S,FNcut(37),0):UNTIL R$=""
    1590 UNTIL P$=""
    1600 ENDPROC
    1700 DEF PROCadd(S,T$,K)
    1710 IF N%(S)<60 N%(S)=N%(S)+1:L$(S,N%(S))=T$:K%(S,N%(S))=K
    1720 ENDPROC
    1800 DEF PROCrows
    1810 M%=N%(0):IF N%(1)>M% M%=N%(1)
    1820 FOR R%=1 TO M%:PROCcell(0,R%):PRINT " | ";:PROCcell(1,R%):PRINT:NEXT
    1830 PRINT
    1840 ENDPROC
    1900 DEF PROCcell(S,R)
    1910 IF R>N%(S) T$="":K=0 ELSE T$=L$(S,R):K=K%(S,R)
    1920 IF K=1 OR K=3 VDU 27,69
    1930 IF K=1 VDU 27,45,1
    1940 PRINT T$;
    1950 IF K=1 VDU 27,45,0
    1960 IF K=1 OR K=3 VDU 27,70
    1970 IF S=0 AND LEN T$<37 PRINT SPC(37-LEN T$);
    1980 ENDPROC
    2000 DEF PROCnext
    2010 Z$="next"
    2020 FOR I%=1 TO 4:IF U%(I%) OSCLI "DELETE "+F$(I%)
    2030 NEXT
    2040 E%=E%+1:$S%=STR$ E%:OSCLI "SAVE EDITION "+STR$~S%+" "+STR$~(S%+LEN $S%+1)
    2050 Z$="":ENDPROC
    2100 DEF FNnext
    2110 T$=$G%:G%=G%+LEN T$+1:=T$
    2200 DEF FNcut(W%)
    2210 IF LEN R$<=W% L$=R$:R$="":=L$
    2220 I%=W%+1
    2230 REPEAT I%=I%-1:UNTIL I%=1 OR MID$(R$,I%,1)=" "
    2240 IF I%=1 L$=LEFT$(R$,W%):R$=MID$(R$,W%+1):=L$
    2250 L$=LEFT$(R$,I%-1):R$=MID$(R$,I%+1):=L$
    \(desks)
    """

    /// The programs on the file server, by name (to LIST, or run on any
    /// machine).
    public static let serverPrograms: [(name: String, text: String)] = [("REPORT", report), ("EDITOR", editor)]

    /// The file server's disc: Level 1, with the programs in directory A,
    /// where the stories go too.
    public static func fileServerDisc() throws -> [UInt8] {
        var volume = try DiscVolume(disc: Disc.fromImage(FileServerDisc.image(), format: .ssd))
        for (name, text) in serverPrograms {
            try volume.save(at: .init(), name: "\(FileServerDisc.sharedDirectory).\(name)", loadAddress: 0xFFFF_1900,
                            executionAddress: 0xFFFF_8023, contents: BBCBasic.tokenise(text))
        }
        return volume.image
    }

    /// The editor's disc: it boots into the editor's desk.
    public static func editorDisc() throws -> [UInt8] {
        try bootingDisc(title: "EDITOR", program: "EDITOR", text: editor)
    }

    /// A reporter's disc: it boots into the reporter's desk.
    public static func reporterDisc() throws -> [UInt8] {
        try bootingDisc(title: "REPORTER", program: "REPORT", text: report)
    }

    static func bootingDisc(title: String, program: String, text: String) throws -> [UInt8] {
        var volume = try DiscVolume(disc: Disc.fromImage(BlankDisc.dfs40.image(title: title), format: .ssd))
        try volume.save(at: .init(), name: program, loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023,
                        contents: BBCBasic.tokenise(text))
        try volume.save(at: .init(), name: "!BOOT", loadAddress: 0, executionAddress: 0, contents: Array("CHAIN \"\(program)\"\r".utf8))
        volume.setBootOption(3)
        return volume.image
    }
}
