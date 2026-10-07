# Memory — remembering what was built

The map design is long-running work over many sessions. Memory lives in two
synced places:

| Where | What | Tool |
|---|---|---|
| Repo: `map-memory/MAP_MEMORY.md` | Brief, palette, identity, zones, decisions, critique log, session log, TODO | Read/Edit tools |
| Repo: `map-memory/assets.json` | Every uploaded mesh/texture: name, family, sha1, Roblox assetId, size, date | `upload_to_roblox.py` writes it |
| Place: `ServerStorage.MapDesignMemory` | Brief copy, JSON build log, camera bookmarks | `memory.luau` |
| Place: attributes on built instances | `MD_Zone`, `MD_Step`, `MD_Session`, `MD_By`, `MD_Time`, `MD_AssetId` | `memory.luau tag`, `insert_assets.luau` |

The place-side memory travels with the .rbxl, so even if the repo isn't present,
opening the place tells you what was built. The repo-side memory is richer and
version-controlled.

## Start of every session (mandatory)
1. Read `map-memory/MAP_MEMORY.md` (create it from the template if missing).
2. Read `map-memory/assets.json` if present.
3. `run_code(memory.luau)` with `ACTION = "read"` — prints brief, recent log,
   camera bookmarks, and an inventory of tagged instances by zone.
4. If the two disagree (e.g. the place has zones the markdown doesn't know about),
   reconcile: trust the place for *what exists*, the markdown for *why*.
5. Tell the user in 2–3 lines where things stand and what's next.

## While building
- After each step that creates things: `memory.luau` with `ACTION = "tag"` on the new
  top-level instances (zone + step), then `ACTION = "log"` with a one-line summary and
  the audit result.
- Never rebuild something the memory says exists — modify it. Before creating a zone,
  check the inventory for it.
- Decisions with a reason ("moved the lighthouse to the east cliff so it's visible
  from spawn") go into MAP_MEMORY.md → Decisions.

## End of every session (mandatory)
1. Append to MAP_MEMORY.md → Session log: date, what changed, audit numbers, open
   issues. Update Zones table and TODO.
2. Make sure the place log has an entry for the session.
3. Remind the user to save/publish the place (Studio MCP can't always save files),
   and commit `map-memory/` if they use git.

## Rules
- Keep entries short and factual. Memory is for the next session, not a diary.
- Don't store secrets (API keys) anywhere in memory.
- If the user says to forget/redo something, update memory to match — stale memory
  is worse than none.
