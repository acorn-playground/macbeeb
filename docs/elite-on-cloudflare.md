# Elite over Econet's servers on Cloudflare: an exploration

Written 27 October 2026. Nothing here is built or deployed yet: this is what
it would take, what it would cost, and what has to be decided first.

The goal: a permanent Elite over Econet game on the Internet. Its file
server (and scoreboard) live on Cloudflare; anyone joins from MacBeeb, on a
Mac or in a browser, with a commander of their own.

## What already exists

- **Internet Econet rooms** (cloudflare-econet, deployed): a Durable Object
  per room relays Econet frames between members' gateways. Each member runs
  their own machines and their own Econet line, clock included.
- **The gateway** (BeebCore's `EconetGateway`): stands in on a local line for
  the room's stations. It holds the line with flags while a frame crosses
  the Internet, and only ever passes on real stations' answers.
- **The WebAssembly BeebCore**: the same emulator in a browser and in
  workerd. It has networks (`beeb_network_*`) and the gateway
  (`beeb_gateway_*`). It runs a Model B at about 11 times real time.
- **A local proof** (`cloudflare/`): a machine in a Durable Object, run in
  bounded bursts, saved to and restored from storage.
- **Elite over Econet** in the Network Studio: Mark Moxon's Level 3 server
  (a Master 128 with a 6502 Second Processor and a SCSI hard disc), his
  scoreboard, and startup scripts that set players up. A Mac can already
  host a game and others can join it (File ▸ Add Remote Elite).

## What "the server components" are

- **The file server**: the one thing everyone needs. Acorn's Level 3 server
  on an emulated Master, serving the game and keeping commanders. Its state
  is its hard disc (about 10MB, 0.6MB of it used) and its memory.
- **The scoreboard**: one station that every ship reports to (port 100).
  Optional: a player can run it themselves.
- **The clock**: there's nothing to host. An Econet clock belongs to a line,
  and every member's line has its own; the room joins them with gateways.
  The cloud's machines would be on a line of their own, with its own clock,
  like everybody else's.

## How a cloud server would run: event-driven, not real-time

A Mac or browser runs its machines in real time, because its gateway holds
the line in real time while frames cross the Internet. A cloud server
needn't, and shouldn't:

1. **Waiting**: with nothing happening, the machines don't run at all. The
   Durable Object can hibernate; time stands still for the BBCs.
2. **A frame arrives** from the room: the gateway puts it on the line, and
   the machines run until the server answers. That's a few milliseconds of
   BBC time, computed as fast as the CPU allows.
3. **The server sends**: the gateway holds the line while its frame crosses
   the Internet, and the machines stop until the answer comes back (or
   doesn't). The gateway's two-second limit is in BBC time, which isn't
   passing.
4. **Settling**: after a transaction, run on until the line has been quiet
   for a while (say a second of BBC time) and nothing is due, then stop.

Measured natively, the Level 3 server's Master and Second Processor run at
about 10 times real time on one core. In WebAssembly, expect roughly 7
times. Serving one player's load of Elite is perhaps 10 to 20 seconds of BBC
time, so roughly 2 to 3 seconds of CPU. An idle server costs nothing.

What this needs in BeebCore and the WebAssembly ABI:
- **Hard discs**: attach one, and get the sectors written since a given
  point (for storage).
- **A way to drive the gateway event by event**: report when it's waiting on
  the room (it already reports "holding the line"), and when the line is
  quiet.
- **The Master with a 6502 Second Processor** in the page's machine set-up
  (the core has it).

The server's clock (the dates on files) only moves while it's working. It
could be put right whenever it wakes, or left as it is.

## Where it would live

**Recommended: a "hosted machines" Worker in this repository**
(`cloudflare/`, beside the proof). It joins rooms through the service's
public API, as any member does, and leases stations 254 and 1.
- It keeps cloudflare-econet independent of MacBeeb: the service still never
  runs guest code.
- It's one Durable Object per hosted network, with the Level 3 server and
  the scoreboard on one line, running the WebAssembly BeebCore.
- It's a member like any other, so Macs and browsers need no changes to
  join it.

The catch is the connection. The host's WebSocket to the room is an outgoing
one, and outgoing sockets don't hibernate. The object stays awake while it's
in the room: about 324,000 GB-s a month. That fits in the Paid plan's
400,000 GB-s allowance if little else uses it, and costs about $4 a month
if it doesn't. That's fine for one
permanent game, but it's the reason not to host many this way.

**The alternative** is to teach the room service about hosted stations:
the room's object hands their frames to a machine object by RPC, with no
socket, so idle costs nothing. It's cheaper at scale, but it ties the
service to MacBeeb's emulator. That's against how the service was built.

## The scoreboard, seen from the web

The scoreboard is a BBC in MODE 7, so its screen is text. The host could:
- serve it as a page (the teletext screen as HTML), so anyone sees the
  standings without joining;
- or share it as a room screen, as Macs do now (a JPEG about once a second),
  though that means drawing frames in the object.

## Joining

- **From the Mac app**: works today. File ▸ Add Remote Elite, with the
  game's code or link. A permanent game would want a permanent invitation
  (today's last 24 hours, for 20 people): a change in the service, or a host
  that renews its invitation and publishes the current one.
- **From the browser**: the page joins rooms already, once the service
  allows browsers (CORS is on cloudflare-econet's `browser-clients` branch,
  not deployed). For Elite it also needs:
  - a Model B with sideways RAM (or a Master) in the page;
  - the startup script, or a "Play Elite" button that does what it does.
    The script runner is Swift in BeebNetwork, so it would either move into
    BeebCore and the ABI, or be rewritten in TypeScript (about 150 lines).
  - Without the script, a player types `*NET`, `*I AM 0.254 ELITE` and
    `*ELITE`, and follows Mark's steps.

## Risks and unknowns

- **ROMs on Cloudflare**: the server runs Acorn's MOS 3.20, ANFS, ADFS and
  Tube ROMs, and the Level 3 server software, all copyright Acorn's
  successors. MacBeeb bundles them, and the browser build does too. Running
  them on a public service is a further step.
- **Real-network measurements**: start-up (compiling a 14.5MB module within
  the one-second limit), and CPU while serving, are unmeasured on
  Cloudflare itself (see [cloudflare-feasibility.md](cloudflare-feasibility.md)).
- **Durability**: commanders are saved on the hard disc. Written sectors
  must reach storage (after each transaction that wrote some), and the
  machine's memory before it sleeps (the server caches the disc's map).
- **Abuse**: a public server is public. Every player logs on as ELITE and
  shares one directory, so anyone can delete commanders. Mark's disc has no
  passwords. A game for invited people is simpler to run than an open one.
- **Elite's reports**: a docked ship reports to the scoreboard once and
  doesn't try again, so a busy scoreboard misses some (seen locally). Over
  the Internet, each report is one transaction among others.
- **Scale**: one room is fine for tens of players. Its frames all pass
  through one object, and one Level 3 server serves them one at a time (as
  it did in a school).

## A plan, if we go ahead

1. **Event-driven driving, natively first**: a `HostedNetwork` in
   BeebNetwork that runs a line event by event behind a gateway. Test it
   against an Internet room with the local service, as the self-tests do:
   a Mac joins and plays.
2. **The ABI**: hard discs, the event-driven gateway, and the Master with a
   Second Processor, in the WebAssembly build. Parity tests as now.
3. **The hosted Worker**: a Durable Object per hosted network, joining a
   room as a member. Storage for the disc's sectors and the machine. A local
   end-to-end test: the cloud server in `wrangler dev`, a Mac player.
4. **Scoreboard page** and a permanent invitation.
5. **Browser players**: CORS deployed, the Elite machine and the play
   button.
6. **One private deployment** to measure start-up and CPU, then decide on
   opening it up.

## Decisions needed

- On-demand hosting (event-driven, sleeps when idle) is the recommendation.
  The alternative is a server that runs all the time.
- Where it lives: a member Worker here, or hosted stations in the service.
- Running Acorn's ROMs and the Level 3 server on a public service.
- Who can play: invited people (a room with invitations, as now), or
  anyone, with a permanent public code.
