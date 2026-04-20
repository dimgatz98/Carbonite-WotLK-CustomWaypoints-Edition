# CustomWaypoints

Small companion addon for **WoW 3.3.5a** that sits **next to** Carbonite: it doesn’t patch Carbonite files, it just talks to the same map APIs.

**In plain terms:** you click the Carbonite map (with a modifier), you build an ordered list of stops, and CustomWaypoints figures out a route and pushes the important bits back into Carbonite so you still get arrows, lines, and the usual HUD behaviour. Carbonite keeps doing the actual drawing; this addon is the “what should we visit, in what order?” layer.

Rough breakdown:

| Piece | What it does |
|--------|----------------|
| **Capture** | Reads the **map you’re looking at** in Carbonite (not necessarily the zone your character is standing in). |
| **Queue** | Ordered list in `CustomWaypointsDB.destinations` — saved between sessions. |
| **Routing** | Walks the queue, can use transports / deep graph / optional flight masters — all configurable. |
| **Sync** | Writes a **filtered** set of route nodes into Carbonite as targets. |
| **UI** | Optional window (`/cw ui`), import area, scrolling log, plus a Blizzard **Interface → AddOns** panel. |

If you want the longer technical picture, see [`docs/architecture.md`](docs/architecture.md). For “please don’t break this” maintenance notes, see [`CHECKPOINT.md`](CHECKPOINT.md). The repo-wide engineering doc is [`../CustomWaypoints_Developer_Reference.md`](../CustomWaypoints_Developer_Reference.md).

---

## Install

Put folders side by side:

```text
Interface/AddOns/Carbonite
Interface/AddOns/CustomWaypoints
```

Usually Carbonite loads first automatically because it’s a separate addon; if anything’s weird, load order is worth a quick check.

---

## Mouse clicks

Defaults (change in saved vars / future options if you customize):

| Input | Effect |
|--------|--------|
| **Shift + left-click** on the Carbonite map | Add waypoint (main binding) |
| **Ctrl + right-click** on the Carbonite map | Add waypoint (alternate binding) |

---

## Slash commands (`/cw …`)

`/cw` or `/cw help` prints a compact list. Here’s what everything does in practice:

| Command | What you get |
|---------|----------------|
| `help` | Short command list in chat |
| `ui` / `panel` / `window` | Show or hide the CW window |
| `options` / `config` | Opens **Interface → AddOns → CustomWaypoints** (if the client supports it) |
| `add` | Same as “capture here” — uses current cursor on the Carbonite map |
| `list` | Dump the queue to chat |
| `export` | Writes the **copy/paste** block into the **CW log** (markers + one `|` line per stop) |
| `import` | Opens the UI and focuses the import box; paste the block and hit **Import** |
| `import <one line>` | Import a single data line from chat |
| `sync` | Rebuild route and push targets into Carbonite (always runs a full sync when called) |
| `route` | Short summary in chat; turn **`debug`** on for per-point spam |
| `graph` | Node/edge counts (more detail with **`debug`**) |
| `probe` | Map / cursor diagnostics — **full dump only with `debug`** |
| `clear` | Empty the queue and clear Carbonite targets |
| `pop` | Remove only the **first** stop |
| `undo` / `redo` | Step through snapshot history (add / clear / pop / import), see below |
| `autosync` | Toggle “after each queue change, sync automatically”; **when you turn it on**, it syncs once immediately |
| `autoadvance` | Toggle auto-removing the first stop when you’re close enough |
| `hasflying` | Toggle “I have a flying mount” for routing (aliases: `toggleflying`, `flymode`) |
| `flightmasters` | Toggle using flight masters in deep mode (aliases: `taxi`) |
| `deep` / `minimal` | Force deep vs minimal transit mode |
| `simplify` | Toggle simplified transit waypoints (`simplifytransit` is the same) |
| `debug` | Toggle verbose output (`dbg` messages mirror to chat; `pr` is always the short user-facing line) |
| `legend` | Toggles saved flag `showLegend` — the on-screen legend in the main frame is **currently hidden** in code, so this is mostly for future / consistency |

---

## Export / import format

Each queue stop is one line:

```text
index|mapId|mapName|zx|zy|wx|wy|timestamp
```

**Seven** columns without a timestamp still work. If the map name contained a `|`, export swaps it to `/` so the row stays parseable. Pasted chat junk (colour codes, BOM, etc.) is cleaned up when the parser can manage it.

**Workflow:** `/cw export` → select everything in the log between **COPY FROM HERE** and **COPY TO HERE** → paste into **Import** → **Import**.

**Important:** export is **only your queue stops**, not every intermediate dot Carbonite draws after a sync. If you need the full expanded path, use `/cw route` with debug on.

---

## Undo / redo

Snapshots are taken **before** add, clear, pop, and import. Undo walks that stack back; redo walks forward until you do something new.

After **`/reload`**, memory snapshots are gone. If the queue was restored from **SavedVariables** and you hit undo with an empty history, the addon **clears** the queue on purpose (and you can **redo** to bring it back).

Optional keys: **Ctrl+Shift+Z** / **Ctrl+Shift+Y** if those bindings aren’t taken — same as the UI buttons.

---

## Login behaviour

If you log in with a **non-empty saved queue**, CustomWaypoints schedules **one** sync as soon as Carbonite’s map object exists (retries on `OnUpdate`). That’s so you don’t stare at an empty map after a relog.

That login push **does not** look at the autosync toggle — autosync only controls whether **day‑to‑day edits** (add, import, undo, etc.) trigger sync immediately. If you turn autosync **off**, you still get the login catch‑up; after that, use **`/cw sync`** when you want Carbonite updated.

---

## Waypoint “vanished” by itself?

Usually one of these:

1. **Auto advance** (`autoadvance` on by default) removes stop **#1** when you’re within **`reachDistanceYards`** (default 10) **on the same map id** as that stop. You’ll see **`CW: completed #1 => …`** in chat if that happened. Turn it off: **`/cw autoadvance`** or uncheck in the UI / Interface panel.  
2. **Carbonite cleared targets** (right-click clear, another route addon, etc.). CustomW’s queue follows that — you now get a clear **`queue cleared (Carbonite Goto / targets were cleared in-game)`** message so it’s obvious.  
3. After an update, **`debug` off** hides diagnostics — turn **`/cw debug`** on once if you’re chasing this.

---

## Debugging

- **`/cw list`** — queue  
- **`/cw route`** — route length / cost (details need `debug`)  
- **`/cw probe`** — cursor / map sanity (`debug` for walls of text)

**Heads-up:** fresh installs default to **`debug = true`** in `DEFAULTS`, so you’ll see more noise until you flip it off (slash, UI checkbox, or Interface panel).

With **`debug` on**, **`/cw export`** can also dump the **whole block** through `dbg` to chat — the **log panel** is still the nice place to copy from.

---

## Design rules (don’t “fix” these accidentally)

1. The **queue** is authoritative; Carbonite targets are derived.  
2. Capture uses the **displayed** map, not “whatever zone the API thinks you’re in”.  
3. Internal sync must not look like the user hit “clear goto” — there’s a suppression window for that.  
4. When the **user** clears Carbonite’s goto, the CW queue should empty too.  
5. Synthetic **start** nodes are for routing math, not permanent pins.  
6. Some transport legs stay **straight** targets on purpose.  
7. WoW’s Lua is 5.1-style: keep **forward declarations** for things UI closures capture early (`ImportWaypointsFromText`, undo helpers, etc.).

---

## Other files here

| File | Why open it |
|------|-------------|
| [`CHECKPOINT.md`](CHECKPOINT.md) | What “done” means + regression bullets |
| [`docs/architecture.md`](docs/architecture.md) | Data flow |
| [`docs/routing-notes.md`](docs/routing-notes.md) | Policy / transport notes |
| [`docs/known-issues.md`](docs/known-issues.md) | Honest limitations |
| [`docs/test-cases.md`](docs/test-cases.md) | Manual QA list |

---

## License

Carbonite’s own license files still apply to Carbonite; this integration layer follows whatever license the remaster repo declares for the fork.


## ⚠️ Deep Routing Status (Work in Progress)

Deep routing is currently under active development and **not yet fully reliable**.

While it enables advanced pathfinding across:
- portals
- transports (boats, zeppelins, trams)
- flight masters
- intercontinental routes

it may still:
- miss valid optimal routes
- behave inconsistently depending on discovered nodes or FM nodes

### Recommendation
For stable behavior and to avoid small lags:
- use **minimal routing mode** (Carbonite-driven)

Use deep routing only for:
- smart experimental routing / path validation
- data gathering
- contributing feedback / debugging
- If you are willing to sacrifice performance for precision

### Notes
- transport graph and heuristics are still evolving
- routing correctness is prioritized over completeness at this stage
