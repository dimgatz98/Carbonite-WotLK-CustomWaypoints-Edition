## Core Capabilities

- Waypoint capture from Carbonite world map
- Persistent waypoint queue (`STATE.db.destinations`)
- Queue-based routing (minimal + deep modes)
- Transport-aware routing (portals, taxi, boats, etc.)
- Known Locations system:
  - instances
  - learned transports
  - saved routes
- Import/export:
  - queue export
  - known locations export (union-based import)
- Undo/redo system (`STATE.history`, `STATE.future`)
- Login recovery:
  - queue auto-syncs when map becomes available

---

## UI / UX

- Main UI window
- Known Locations window (single source of truth)
- Routing tuning window
- Interface Options panel:
  - autosync
  - autoadvance
  - deep routing
  - autodiscovery
  - auto route to instance on death

---

## Death Auto Route

- Automatically routes to saved instance entrance after death
- Controlled by:
  - `autoRouteSavedInstanceOnDeath` (persisted setting)
- Uses delayed retry mechanism:
  - `StartPendingDeathAutoRoute`
  - `PulsePendingDeathAutoRoute`
- Safe against:
  - map not ready
  - instance transitions
  - missing coordinates

---

## Do NOT Break These

- Queue persistence across reload
- Carbonite sync isolation (no accidental queue wipe)
- Minimal vs Deep routing separation
- Known Locations = single source of truth (no duplicate systems)
- Import/export must remain backward compatible
- Death auto-route must be:
  - safe (no spam)
  - retry-based (not instant)

---

## Known Limitations

- Routing is heuristic (not exact travel-time optimal)
- Depends on Carbonite graph quality
- Instance detection can be noisy in edge cases
- Import is strict (invalid rows rejected)
- Undo history is capped

---

## Sanity Test Before Release

1. Add waypoint → sync works
2. Multi-waypoint route works
3. Known Locations:
   - add
   - delete
   - route
4. Import/export works
5. Death inside instance:
   - ON → routes
   - OFF → does nothing