# Changelog

## 2026-04-08
- Added Interface Options checkbox for “Auto route to instance on death”.
- Declared `autoRouteSavedInstanceOnDeath` explicitly in defaults.
- Wired death auto-route setting to interface panel (no slash command).
- Disabling the option now clears any pending death auto-route cycle.
- Enabling the option while dead/ghost immediately schedules a retry (`StartPendingDeathAutoRoute`).
- No changes to routing logic or pathfinding behavior (UI + config exposure only).

---

## 2026-03-31
- Fixed cross-continent transport routing bug caused by hard query-node walk gating in `BuildTransportLeg()`.
- Removed `maxWalkToPortalEntry` and `maxWalkToTaxiEntry` from routing tuning and UI.
- Query-node attachment is now cost-driven so Dijkstra can evaluate valid portal/taxi routes instead of losing them before pathfinding.
- Removed keyboard capture from top-level addon frames so Enter can open chat reliably again.
- Made portal discovery more robust against local indoor/building map swaps.
- Added known instance-location persistence inside learned transport registration (`previousTarget` = entrance, `lastTarget` = instance destination).
- Added instance-specific transport confirmation note for queue teleports.
- Added a Known Locations UI list with row selection, double-click routing, and a Route Selected action.
- Added addon-native keybinding support for opening Known Locations, with safe auto-bind to Ctrl+Shift+L only when that key is currently free.

## 2026-04-01
- Added addon-native `Save Here` keybinding command (`CW_SAVE_HERE`).
- Hardened Carbonite clear hook behavior (no unintended queue wipe).
- Added Known Locations export/import with union + dedup.
- Improved route deduplication (full chain comparison).
- Custom waypoint labels now override Carbonite hover text.
- Fixed ESC modal closing order.