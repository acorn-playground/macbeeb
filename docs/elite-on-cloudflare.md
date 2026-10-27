# Elite over Econet on Cloudflare

Hosting Elite over Econet's Level 3 file server and scoreboard on
Cloudflare, for players from MacBeeb on a Mac or in a browser, is its own
project: the `econet-elite` repository (`~/code/acorn-playground/econet-elite`),
whose `docs/plan.md` has the decisions, what's done and what's next. It
runs MacBeeb's WebAssembly engine (see [wasm.md](wasm.md)), copied in by
its `scripts/engine.sh`.

What MacBeeb gives it:

- **BeebWasm ABI 3:** hard discs on the Acorn SCSI interface, sideways RAM,
  and `beeb_network_run_until_holding`, for a host that runs a network only
  while there's work.
- **web/src/room.ts:** the room client, with invitations that never expire
  and the host's removing members.
- **Choosing how long an invitation lasts** in the Share sheet (a service
  with permanent invitations), so a Mac can host a standing game too.
