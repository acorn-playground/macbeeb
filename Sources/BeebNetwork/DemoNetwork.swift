import BeebCore
import Foundation

/// The Econet Demo network's programs: a welcome screen and a handful that
/// show what a network does, on the file server for any machine to run.
/// All plain BBC BASIC II and the network filing system's own calls.
public enum DemoNetwork {
    /// MODE 7 instructions. On the Welcome machine's own disc (it boots
    /// it), and on the file server.
    public static let welcome = """
    10 REM Econet demo: what to try
    20 MODE 7:VDU 23,1,0;0;0;0;
    30 Y$=CHR$131:C$=CHR$134:G$=CHR$130:W$=CHR$135:M$=CHR$133
    40 FOR I%=1 TO 2:PRINT CHR$132;CHR$157;CHR$141;Y$;"   ECONET DEMONSTRATION":NEXT
    50 PRINT
    60 PRINT C$;"A network of BBC Micros, each one"
    70 PRINT C$;"real. They share a file server"
    80 PRINT C$;"(station 254) and a printer (235)."
    90 PRINT
    100 PRINT Y$;"On any machine, type:"
    110 PRINT G$;"*NET";W$;"      use the network"
    120 PRINT G$;"*CAT";W$;"      the files on the server"
    130 PRINT G$;"CHAIN";M$;CHR$34;"HELLO";CHR$34;W$;" a program over Econet"
    140 PRINT G$;"CHAIN";M$;CHR$34;"CHAT";CHR$34;W$;"  talk to another BBC"
    150 PRINT G$;"CHAIN";M$;CHR$34;"GUESTS";CHR$34;W$;" sign the visitors' book"
    160 PRINT G$;"CHAIN";M$;CHR$34;"PRINTME";CHR$34;W$;" print on the printer"
    170 PRINT
    180 PRINT Y$;"On the Mac:"
    190 PRINT C$;"Traffic shows every frame sent."
    200 PRINT C$;"The printer button above shows what's"
    210 PRINT C$;"printed. Drop files on the file"
    220 PRINT C$;"server's card to share them."
    230 PRINT
    240 PRINT CHR$129;CHR$157;W$;"This machine is station 1     ";CHR$156
    250 *NET
    260 VDU 23,1,1;0;0;0;
    """

    /// A program arriving over the network says hello.
    public static let hello = """
    10 REM Econet demo: hello
    20 MODE 7
    30 FOR I%=1 TO 2:PRINT CHR$141;CHR$130;"Hello from the file server!":NEXT
    40 PRINT
    50 PRINT CHR$134;"This program wasn't on this BBC: it"
    60 PRINT CHR$134;"came over Econet from station 254"
    70 PRINT CHR$134;"when you typed CHAIN ";CHR$34;"HELLO";CHR$34;"."
    80 PRINT
    90 PRINT CHR$131;"It went as a scout, an acknowledge-"
    100 PRINT CHR$131;"ment, the data and another acknow-"
    110 PRINT CHR$131;"ledgement: the four-way handshake."
    120 PRINT CHR$131;"See them in the Studio's Traffic view."
    """

    /// Two machines talking: each line typed goes to the station chosen,
    /// with OSWORD &10 (transmit) on port &77, and what arrives on that
    /// port (OSWORD &11, an open receive block) is shown.
    public static let chat = """
    10 REM Econet demo: chat between two BBCs
    20 MODE 7:DIM B% 80,R% 80,C% 20,T% 20
    30 FOR I%=1 TO 2:PRINT CHR$141;CHR$131;"Econet chat":NEXT
    40 PRINT CHR$134;"Run CHAT on another BBC too."
    50 INPUT "Chat to station ",S%
    60 PRINT CHR$130;"Type, then RETURN. ESCAPE stops."
    70 PROCopen:L$=""
    80 REPEAT
    90 K%=INKEY(0)
    100 IF K%=13 AND L$<>"" PROCsend:L$=""
    110 IF K%>31 AND K%<127 AND LEN L$<70 L$=L$+CHR$K%:VDU K%
    120 IF K%=127 AND L$<>"" L$=LEFT$(L$,LEN L$-1):VDU 127
    130 A%=&33:X%=N%:U%=USR(&FFF4):IF U% AND &8000 PROCshow
    140 UNTIL FALSE
    150 DEF PROCopen
    160 C%?0=0:C%?1=&7F:C%?2=&77:C%?3=0:C%?4=0:C%!5=R%:C%!9=R%+80
    170 X%=C%:Y%=C% DIV 256:A%=&11:CALL &FFF1:N%=C%?0
    180 ENDPROC
    190 DEF PROCshow
    200 C%?0=N%:X%=C%:Y%=C% DIV 256:A%=&11:CALL &FFF1
    210 PRINT:PRINT CHR$133;"Station ";C%?3;":";CHR$135;$R%
    220 PRINT L$;:PROCopen
    230 ENDPROC
    240 DEF PROCsend
    250 $B%=L$:T%?0=&80:T%?1=&77:T%?2=S%:T%?3=0:T%!4=B%:T%!8=B%+LEN L$+1
    260 X%=T%:Y%=T% DIV 256:A%=&10:CALL &FFF1
    270 REPEAT:A%=&32:U%=USR(&FFF4):UNTIL (U% AND &8000)=0
    280 PRINT:IF U% AND &FF00 PRINT CHR$129;"(Station ";S%;" isn't running CHAT)" ELSE PRINT CHR$130;"(sent)"
    290 ENDPROC
    """

    /// A visitors' book kept on the file server: everyone who runs it
    /// sees the names signed on every BBC.
    public static let guests = """
    10 REM Econet demo: a visitors' book on the file server
    20 MODE 7:DIM M% 3000:?M%=0
    30 FOR I%=1 TO 2:PRINT CHR$141;CHR$131;"Visitors' book":NEXT
    40 ON ERROR GOTO 60
    50 OSCLI "LOAD BOOK "+STR$~M%
    60 ON ERROR OFF
    70 Q%=M%:N%=0
    80 IF ?Q%<>0 PRINT CHR$134;$Q%:Q%=Q%+LEN$Q%+1:N%=N%+1:GOTO 80
    90 PRINT CHR$130;N%;" so far, on the file server."
    100 INPUT "Your name: "N$
    110 IF N$="" END
    120 IF Q%+LEN N$+2>M%+2990 PRINT "The book's full.":END
    130 $Q%=N$:Q%=Q%+LEN N$+1:?Q%=0
    140 OSCLI "SAVE BOOK "+STR$~M%+" "+STR$~(Q%+1)
    150 PRINT CHR$131;"Thank you! Run GUESTS on another"
    160 PRINT CHR$131;"BBC: your name will be there."
    """

    /// Prints on the network's printer, through the printer server.
    public static let printMe = """
    10 REM Econet demo: print on the network printer
    20 MODE 7
    30 FOR I%=1 TO 2:PRINT CHR$141;CHR$131;"Printing":NEXT
    40 PRINT CHR$134;"Sending a page to the printer server"
    50 PRINT CHR$134;"(station 235)..."
    60 *FX5,4
    70 VDU 2
    80 PRINT "========================================"
    90 PRINT "   PRINTED OVER ECONET"
    100 PRINT "========================================"
    110 PRINT
    120 PRINT "This page went from a BBC Micro to the"
    130 PRINT "printer server, station 235, across the"
    140 PRINT "network, and from there to its printer."
    150 PRINT
    160 FOR I%=1 TO 8:PRINT STRING$(I%*4,"*"):NEXT
    170 VDU 3
    180 PRINT CHR$130;"Done. To see it, click the printer"
    190 PRINT CHR$130;"button at the top of the Studio."
    """

    /// The programs on the file server, by name.
    public static let serverPrograms: [(name: String, text: String)] = [
        ("WELCOME", welcome), ("HELLO", hello), ("CHAT", chat), ("GUESTS", guests), ("PRINTME", printMe),
    ]

    /// The file server's disc: Level 1 with the programs in directory A.
    public static func fileServerDisc() throws -> [UInt8] {
        var volume = try DiscVolume(disc: Disc.fromImage(FileServerDisc.image(), format: .ssd))
        for (name, text) in serverPrograms {
            try volume.save(at: .init(), name: "\(FileServerDisc.sharedDirectory).\(name)", loadAddress: 0xFFFF_1900,
                            executionAddress: 0xFFFF_8023, contents: BBCBasic.tokenise(text))
        }
        return volume.image
    }

    /// The Welcome machine's disc: it boots into the welcome screen.
    public static func welcomeDisc() throws -> [UInt8] {
        var volume = try DiscVolume(disc: Disc.fromImage(BlankDisc.dfs40.image(title: "WELCOME"), format: .ssd))
        try volume.save(at: .init(), name: "WELCOME", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023,
                        contents: BBCBasic.tokenise(welcome))
        try volume.save(at: .init(), name: "!BOOT", loadAddress: 0, executionAddress: 0, contents: Array("CHAIN \"WELCOME\"\r".utf8))
        volume.setBootOption(3)
        return volume.image
    }
}
