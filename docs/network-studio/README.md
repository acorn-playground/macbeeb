# Network Studio

In the 1980s, schools linked their BBC Micros with **Econet**: every machine
in the room on one cable, sharing a file server's discs and a printer.
MacBeeb's Network Studio builds networks like that on your Mac. Each machine
is a real, complete MacBeeb BBC Micro, running all the time, not a picture
of one.

## Quick start

1. Choose **File ▸ New Network…** (⇧⌘N).
2. Click **School Classroom**. MacBeeb makes the network and saves it in
   **Documents ▸ MacBeeb Networks**.
3. The network opens on the **canvas**: four BBC Micros, a file server, a
   printer server and the network's clock, all switched on, their screens
   live.
4. Double-click **BBC 1** to open it in its own window, and type into it as
   into any MacBeeb.

## Templates

| Template | What's in it |
| --- | --- |
| Econet Demo | A classroom ready to try: a Welcome machine with instructions, two Model Bs, a Master, and demo programs on the file server |
| The Econet Times | A newsroom: an Editor and three reporters' BBCs, a file server for the stories and a printer server for the paper |
| Distributed Mandelbrot | Eight worker BBCs and a Guide machine draw the Mandelbrot set between them over Econet |
| Mandelbrot in Colour | The same in MODE 2, the Guide's VideoNuLA giving it sixteen colours, which cycle when it's done |
| Two BBCs | Two Model Bs, stations 1 and 2, and a clock: the smallest network |
| School Classroom | Four Model Bs (stations 1–4), a file server (254), a printer server (235) and a clock |
| BBC and Master | A Model B and a Master 128, a file server and a clock |
| Empty Network | Just the clock |

## The Econet Demo

The quickest way to see what a network does. **File ▸ New Network…**, then
**Econet Demo**. The **Welcome** machine (station 1) boots into a screen of
instructions. On any machine, type `*NET`, then:

| Program | What it shows |
| --- | --- |
| `CHAIN "HELLO"` | A program loaded over the network from the file server |
| `CHAIN "CHAT"` | Two BBCs talking: run it on two machines, give each the other's station number, and type. It uses the network filing system's own transmit and receive calls (OSWORD &10 and &11) on port &77 |
| `CHAIN "GUESTS"` | A visitors' book kept in a file on the server: sign it on one BBC, and the name's there on another |
| `CHAIN "PRINTME"` | A page printed on the network printer (station 235): see it with the printer button in the toolbar |
| `CHAIN "WELCOME"` | The instructions again |

Watch the **Traffic** view while they run to see the frames each one sends.

## The Econet Times

A newspaper, written on three BBCs and printed from a fourth. **File ▸ New
Network…**, then **The Econet Times**:
- an **Editor** (station 1), whose screen is the editor's desk;
- three **reporters** (stations 2–4, the last a Master 128), each at a
  reporter's desk;
- a file server (254) for the stories, and a printer server (235) for the
  paper.

On a reporter's BBC:
1. Choose a desk: News, Sport, Weather or Clubs.
2. Type a headline, or press RETURN to keep the one written for that desk.
3. Type your name.
4. Type the story, a paragraph at a time, with RETURN on its own to end it.
   Or press RETURN straight away for the desk's own story.

The story is filed with the file server, as a file named for its desk.
Press **P** to print a proof of it on the printer server, or any other key
to write another.

The Editor's desk checks the file server every few seconds and lists what
has been filed. Press **P** to print the edition, then open **Window ▸
Print Centre** (or click the printer button in the toolbar). The paper has the masthead drawn in the BBC's own
characters (read from its font with OSWORD 10), then the stories in two
columns, with headlines in Epson bold and underline. **N** starts the next
edition: the desks are cleared, and the edition number goes up.

Things to try:
- **Print from two BBCs at once**: a proof on a reporter's BBC while the
  Editor prints. The printer server prints one job at a time, so one of
  them gets "No reply" from its network software. Once the printer's free,
  press a key on the reporter's BBC to try again, or P again on the Editor.
- Watch the **Traffic** view: the Editor's LOADs as it checks the desks,
  then the paper going to station 235 on port &D1, a packet at a time, each
  acknowledged.
- **LIST the programs**: they're plain BBC BASIC II, on the file server as
  REPORT and EDITOR, using the network filing system's own calls.

## The Distributed Mandelbrot

Ten machines in the 1980s, working together on one picture. **File ▸ New
Network…**, then **Distributed Mandelbrot**:
- eight **workers** (stations 2–9);
- a **Guide** (station 1) whose screen says what to do;
- a Level 2 file server (254) with the programs.

The workers are only switched on: each sits at BASIC with nothing loaded.
The Guide logs on to the file server as GUEST.

On the Guide, type:

1. `*CLUSTER`. It takes the workers over by **remote control**. For each
   BBC it finds, it uses Econet's own immediate operations, which the
   network filing system answers whatever the BBC's doing: it POKEs a few
   bytes of code into the BBC's memory, then JSRs to them. The code types
   `*NET`, `*I AM GUEST` and `*WORKER` on that BBC, and you see them
   appear on its screen. Each worker loads WORKER from the file server
   and says it's running.
2. `*MANDEL`. The Guide becomes the **coordinator**. It hands out the
   picture in 320 tiles of 16 × 8 pixels, and each worker works its tile
   out in its own 6502 and sends it back. The picture builds on the Guide's
   MODE 5 screen as the tiles come in, and each worker's screen shows its
   tile, its progress and how many it has done.
3. When it's complete, press a key on the Guide for a summary: how long it
   took and what each worker did.

Any BBC can be the coordinator: press Break on it, type `*NET` and
`*I AM GUEST`, then `*CLUSTER` and `*MANDEL`. `*WORKERS` lists the
workers, and `*STOPWK` sends them back to BASIC.

Things to try:
- **Switch a worker off part way.** Its tile is given to another after 20
  seconds (emulated), and the picture still comes out right. Switch it back
  on: MANDEL finds it at BASIC, starts it again by remote control, and it
  joins in.
- **Pause one worker.** It stalls, and the others carry on.
- **Pause the whole network.** Everything stops together.
- Watch the **Traffic** view: the remote control's machine type, POKE and
  JSR, then every ASSIGN, RESULT and ACK, decoded, beside the Econet
  frames that carried them.

Everything is real. Every pixel is worked out by an emulated BBC, and every
message goes through Acorn's network software and the emulated Econet chip.
The programs are 6502 assembly in `Examples/distributed-mandelbrot`, with
the protocol they speak.

The programs are in the server's `$.LIBRARY`, so any station that's logged
on can run them as `*` commands.

### Mandelbrot in Colour

The same network, but the Guide has a **VideoNuLA** and the picture is in
MODE 2: sixteen colours chosen from VideoNuLA's 4,096. Type `*CLUSTER`, then
`*MANDEL2`. When the picture's complete its colours **cycle**, the bands
flowing outwards from the set, until you press a key. (`*MANDEL2` on a BBC
without VideoNuLA draws in the wrong colours, as a real one would.)

### The Mandelbrot view

Click **Mandelbrot** in the toolbar to follow a render from the traffic:
- the picture so far, made only from tiles the coordinator has
  acknowledged, so a missing tile stays missing;
- the tiles in flight, outlined in each worker's colour;
- each worker's state and counts;
- the time taken.

**Authentic MODE 5 palette** shows it in the coordinator's own four colours.

## The canvas

- **Add a machine**: drag one from the **Add** palette onto the canvas, or
  click it to add it in the middle. New machines take the next free station
  number and are switched on.
- **Add one of your machines**: machine configurations you've saved (see
  Help ▸ Hardware Expansion Guide ▸ ROMs, Cartridges and Saved Machines)
  are under **My Machines**, below the palette. A station's inspector has a
  **Configuration** menu to set it up as one, or save it as one.
- **Arrange**: drag machines around. Hold ⌘ or ⇧ and click to select more
  than one, and drag them together. **Snap to grid** is in the inspector.
- **Move round**: drag the background, or scroll. Pinch, or ⌘-scroll, to
  zoom. The buttons at the bottom right zoom, and the last shows the whole
  network.
- **Open a machine**: double-click it. Its window has all of MacBeeb's menus,
  the debugger and the Hardware window. Closing the window doesn't stop the
  machine: it carries on, on the canvas.
- **Right-click a machine** for Power On/Off, Cold Boot, Break, Suspend,
  Open Window, the debugger, Hardware, discs, Duplicate and
  Remove.
- The line along the middle is the network's shared cable. A machine that's
  on joins it with a solid line; one that's off, with a dashed line.
- **Problems** show at the top of the canvas, for example two machines with
  the same station number, or a network without a clock.

## Econet

Every machine on a network has an Econet module, with its station number,
and Acorn's network filing system: DNFS on a Model B (it's DFS 1.20 as
well), ANFS 4.25 on a Master. It's the real hardware, emulated: the
machines' own network software does everything, just as on a 1980s
network.

- **The clock**: an Econet carries nothing without one. Every template has
  one. Take it away and the machines' network software reports "No clock".
- **The file server**: Acorn's Level 1 file server, running on its BBC
  (station 254), from its disc. It starts itself when the network's
  switched on: its console (on its card, or in its window) says `Ready`.
  Every other machine shares its directory, A.
- **Using it**: on any machine, type `*NET` to change to the network
  filing system. Then `SAVE "PROG"`, `LOAD "PROG"`, `CHAIN "PROG"`, `*CAT`,
  `*SAVE` and `*LOAD` work over the network. Save on one machine and load
  on another.
- **Traffic**: a machine sending on the network glows green on the canvas,
  with a radio-wave sign on its card.
- **When things go wrong**: the network software's own messages, as on a
  real network. With the file server off, `*CAT` says "Not listening".
  Switch it back on and it starts again, with its files still on its disc.

To start the server by hand (after Break, for example), choose **Start File
Server** in its inspector or right-click menu.

**A Level 2 file server**: add **Level 2 File Server** from the palette
(station 254, or 253 if that's taken), or switch a file server's
**Server** to Level 2 in its inspector. Acorn's Level 2 server runs in a
Model B with a 6502 Second Processor, serving its own disc in drive 0, with
the server's utilities disc in drive 1. Unlike Level 1, it has users with
passwords, each with their own directory (and directories inside it), and
boot options:

- Its disc starts with users **SYST** (system privileged: `*NEWUSER` makes
  others), **BOOT** and **GUEST**, none with a password, and a library,
  `$.LIBRARY`, everyone's library at log-on.
- On a station: `*NET`, then `*I AM GUEST` (or `*I AM name password`).
  `*CAT`, `*CDIR`, `*DIR`, `*LIB`, `*ACCESS`, `*PASS`, `SAVE`, `LOAD` and
  `CHAIN` work as Acorn's user guide says. `*CAT $` shows everyone's
  directories, and `$.name.file` loads another user's file if its access
  allows (`*ACCESS file WR/R`).
- **Boot options**: `*OPT 4,3` makes logging on `*EXEC` your `!BOOT`
  (1 loads it, 2 runs it). BOOT's option is 3, and its `!BOOT` is a `*CAT`.
  **Shift-Break** logs on as BOOT and runs it when the network is the
  filing system: on a Model B, hold N as well (Shift+N+Break); on a
  Master, after `*NET`.
- **Files from the Mac** go in `$.LIBRARY`, readable by everyone (`CHAIN
  "$.LIBRARY.PROG"`, or `*PROG` for machine code), and folders become
  directories. Switch the server off first: it keeps its disc's map and
  directories in memory while it serves.
- Switching a server between Level 1 and Level 2 restarts it with a fresh
  disc of its own kind: the other kind's disc comes out.

**Files from the Mac**: drag files onto the file server's card, or choose
**Add Files…** in its inspector. They go on the server's disc in directory
A, where every station can load them, while it serves. A BASIC listing
saved as text (`.bas`) becomes a BASIC program; other files take their
BBC name and addresses from a `.inf` file beside them, as in Disc Contents.
**Show Files** opens the server's disc in Disc Contents, to rename, delete
or drag files back out. The server's disc holds about 190K, in up to 31
files (DFS's limit), the server's own included.

## Printing

**Window ▸ Print Centre** (⌥⌘P), or the printer button in the toolbar of a
network with a printer server, shows everything the BBCs have printed, on
paper as the printer would have put it, and keeps it after MacBeeb quits.
A new job is shown as soon as it starts, following its pages as they print.

- **On a network**: the printer server (station 235) runs MacBeeb's printer
  server on its BBC, with a printer on its printer port. On any other
  machine, `*FX5,4` chooses the network printer; then `VDU 2` starts
  printing and `VDU 3` stops, and `CTRL-B` and `CTRL-C` do the same. In
  between, whatever the BBC prints goes to the printer server, and from it
  to its printer. The job appears in the Print Centre as it prints.
- **On its own**: every MacBeeb BBC has a printer on its printer port.
  `*FX5,1` chooses it (it's the default on a Model B), then `VDU 2` and
  `VDU 3`.
- **One job at a time**: the printer server prints one station's job at a
  time. Another station printing at once gets its network filing system's
  "No reply", as with a real server; print again when the first is done.
- **A job ends** when the printer's been quiet for three seconds of BBC
  time.
- **On paper**: Clean or Dot Matrix (the dots in the BBC's own characters),
  on A4, US Letter or fanfold. 66 lines a page, 10 characters an inch.
  Carriage returns, line feeds, tabs, form feeds, and Epson's bold and
  underline are understood. Other printer codes are kept in the job, but not
  drawn: the Print Centre lists them.
- **Export PDF**, **Print** (on the Mac's printer) and **Raw Bytes** (exactly
  what the BBC sent) are in the toolbar. PDFs have their text, so they can
  be searched.

MacBeeb's printer server is a BBC BASIC program (on the printer server's
disc, `PSERV`), written for MacBeeb because Acorn's own printer server
isn't included. It speaks the printer server protocol Acorn's network
filing systems use: status enquiries on port &9F, answered on &9E, and the
job's data on port &D1.

## Over the Internet

Share a network with someone on another Mac, and your BBC Micros and theirs
are on one Econet: their machines appear on your canvas, yours on theirs,
and they talk with Acorn's own network software. `*I AM` on their BBC logs
on to your file server; `*FX5,4` and `VDU 2` print on your printer server.

**To share**: click **Share Over Internet** (the globe) in the toolbar, or
**File ▸ Share Network Over Internet…**. Name the network, choose which
machines to share, and click **Create Private Network**. File and printer
servers start unshared: share one and whoever joins can log on to it and
read and write whatever its accounts allow, or print on it. Then send the
**invitation link**, or read out the **join code** (`ACRN-…`). Both work for
24 hours, for up to 20 people; **New Invitation** makes another and
**Withdraw** stops one working.

**To join**: **File ▸ Join Econet Network…** (⇧⌘J), or **Join with a Code**
on the welcome screen, or open the invitation link. Type or paste the code
or link: you see the network's name and machines before anything happens.
Join with a new network (a Model B or a Master 128, at a free station
number), or one you have open.

**Archimedes too**: MacArch, the Archimedes emulator, shares and joins the
same networks. Its Archimedes appear on your canvas beside your BBCs
(labelled "Archimedes, in MacArch"), and they talk across: a BBC can log on
to an Archimedes' Level 4 file server, and an Archimedes to a BBC's Level 2
server. An invitation from MacArch joins from MacBeeb like any other, and
yours from MacArch.

**In the network**: other people's machines are on your canvas as dashed
teal cards, joined to your cable: whose they are, whether they're online,
and the round trip to them. The globe button shows who's there; the host
can stop new people joining, remove someone, or **Stop Sharing**, which
closes the network for everyone. A guest can **Leave Network**. If the
connection drops, MacBeeb reconnects by itself, and when you open the
network again it goes back into its room.

**Screens**: the host can **Let people share their machines' screens**, when
sharing or later. Then each person chooses whether to **Show my machines'
screens** (when joining, or from the globe button), and theirs appear live on
everyone's canvas, about once a second. Screens travel apart from Econet, on
a connection of their own, and never slow it down. Both are off unless
turned on, and the host turning sharing off stops everyone's at once.

**What's shared**: only Econet, and screens if you choose. Nobody can type
into your machines, use their debuggers, or reach anything on your Mac. Station
numbers must be different across the network: if someone else has one of
yours, the globe button says which, so you can change it.

**Speed**: each frame of Econet's handshake crosses the Internet and back,
so a file server command takes a few tenths of a second, depending on the
distance. While a frame's crossing, your network's line is held, and your
other machines wait, as they would for a slow station.

**Your own service**: rooms live on a service on Cloudflare: by default
econet.acornplayground.org. Anyone can run their own
([cloudflare-econet](https://github.com/acorn-playground/cloudflare-econet), open source); choose it in **Settings ▸ Networking**. An invitation link
from another service says so before you join, and doesn't change your
setting. A code is looked up on your service, so a code from someone on
another service needs that service set.

## Tiles

Click **Tiles** in the toolbar to see the machines that are on side by
side, each big enough to use. Click a tile to type into it: it gets a blue
ring, and it's the one you hear. ⌥⌘] and ⌥⌘[ move the keyboard to the next
or previous machine. **Show** chooses which machines have tiles, and
**Columns** how they're laid out.

## Focus

Click **Focus** in the toolbar to use one machine large, with every machine
that's on in a strip down the left, live. The large one is outlined in the
strip, has the keyboard and is the one you hear.
- **Click** a machine in the strip to bring it into the large view. It's selected too, so the inspector shows it.
- ⌥⌘] and ⌥⌘[ step through the machines.

The network remembers which machine was large.

## Traffic

Click **Traffic** in the toolbar to see every frame that's crossed the
network, newest first. Econet sends everything as a **four-way handshake**:
a **scout** asking to send (who it's for, a control byte and a port), an
**acknowledgement**, the **data**, and another acknowledgement. The
Traffic view reads frames that way, numbers each transaction, and names the
well-known ports (the file server's, the printer server's).

- Choose a frame to see its bytes and what they mean. The machines it's
  between are selected on the canvas too.
- **Station**, **Problems only** (collided or abandoned frames) and the
  search box (text or hex) narrow the list.
- **Recording** stops and starts the capture; **Clear** empties it. The
  last 4,096 frames are kept.
- **Export…** saves the frames as JSON: MacBeeb's own format (`format`,
  `network`, `cyclesPerSecond`, and `frames`, each with its `start` and
  `end` in 2MHz cycles, `transmitter`, `bytes`, `status`, `kind` and
  `transaction`). It isn't PCAP.

## AI agents (MCP)

Agents connected to MacBeeb (**MCP ▸ Connect an AI Agent…**) can work with
networks too:

- Every tool takes a `machine`: a station's name ("BBC 2"), number ("2") or
  id, or "Network/name" when two networks have one alike. Without it, a
  tool drives the standalone window's machine, as before. A tool that runs
  a station (such as `run_command`) runs its whole network with it, so the
  other machines don't miss what it sends.
- `list_machines`, `network_status`, `network_power` (on, off, cold boot,
  Break, suspend, resume, start a server), `network_pause`,
  `network_trace` (frames, decoded, with `after` for polling),
  `econet_status` (a station's ADLC registers and NMI state),
  `print_jobs`, `print_job` and `export_print_job_pdf`, and
  `network_create` and `network_open`.
- Errors say what's wrong: `not_found:`, `ambiguous_machine:`,
  `powered_off:`, `no_machine:`.

## The inspector

With nothing selected, the inspector shows the network: its name, how many
machines are on, its speed, and any problems. Select a machine to change:

- its **name** and **station number** (1 to 254, one each);
- its **role**: an ordinary station, the file server or the printer server;
- its **model**;
- its **power**, and whether it's **suspended**;
- its **discs**.

Select the clock to set the network's speed.

## Power, pausing and suspending

- **Power On All**, **Power Off All** and **Break All** are in the
  toolbar. Switching a machine off loses what's in its memory, as on a
  real BBC; its discs are kept.
- **Pause Network** stops time on every machine at once. Nothing on the
  network can time out while it's paused.
- **Suspend** (in the inspector or the right-click menu) stops one machine
  where it is while the others carry on. To the others it's as if it had
  hung, so a machine waiting for an answer from it gives up.
- When a machine stops in its **debugger**, the whole network pauses with it,
  so the others don't time out while you look. Turn this off under
  Debugging in the inspector.

## Discs

A network keeps its **own copies** of its discs, inside the network file.
When you put a disc in a network machine (from its window, the inspector,
or by dragging one onto its window), MacBeeb copies it into the network, and
the machine writes to the copy. **Your original disc file is never
changed.**

## Saving

Networks save themselves as you work: what's on the network, each
machine's hardware, station number, discs and place on the canvas, and the
tiles. A network file (`.macbeebnet`) is a package.

A new network is a draft until you keep it. When you close its window,
MacBeeb asks, as for a new document: **Save** it, with a name and a place
(Documents ▸ MacBeeb Networks unless you choose another), or **Delete** it
(it goes in the Trash). **Cancel** leaves it open.

To rename a network, change its **Name** in the inspector (with nothing
selected on the canvas) and press Return: its file is renamed to match. To
keep a copy somewhere else, use **File ▸ Save Network As…**. **File ▸ Open Recent
Network** and **Window ▸ Network Studio** (⌥⌘0) bring back the last ones.

What's in the machines' memory isn't saved: when you open a network again,
its machines start up afresh, as when they're switched on.

## Performance

A network's machines run together, in step: every 16 microseconds of BBC
time each one runs, and then the network passes on what they sent. One
core runs about 14 Model Bs at full speed (fewer Masters or busy servers).
When a network needs more than that, MacBeeb spreads its machines over
more cores, adding one at a time while it helps (up to one fewer than the
Mac's performance cores), and gives them back when they're not needed. The
window's subtitle shows the network's speed, and how many cores it's
using when it's more than one. Which core runs which machine never changes
what they do.
