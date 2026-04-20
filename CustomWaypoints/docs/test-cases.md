# Manual regression tests

Run these after touching **capture**, **queue**, **sync**, **routing**, **import/export**, or **undo**.

## Capture

- Add a waypoint while **looking at** a map different from your current zone — stored `maI` / name should match the **displayed** map.  
- Spot-check coords vs **`/cw probe`** (enable **`debug`** if you need the dump).

## Queue

- Add three stops; **`/cw list`** shows all three.  
- After **sync**, queue length unchanged (no silent drops).  
- **`/cw export`:** between markers you should see **N** data lines for **N** stops.

## Clear behaviour

- **`/cw clear`** → empty queue + Carbonite cleared.  
- User hits **Clear Goto** in Carbonite → CW queue clears (hook).  
- During **CW sync**, internal Carbonite clears must **not** empty the queue.

## Routes

- Ironforge ↔ Stormwind (tram corridor).  
- Cross-continent with multiple stops.  
- Adjacent maps in the same region.  
- Edge cases you’ve hit before (Quel’Danas, Wetlands hops, etc.).

## Drawing

- Walk legs still path “normally” where you expect.  
- Transports that should be **straight** stay straight.  
- No sticky **synthetic start** pins.  
- Labels don’t explode Carbonite UI.

## Import / export

- Export → copy **full** log block → Import → queue matches **`/cw list`**.  
- Single-line **`/cw import …`** works.  
- Paste with **`CW:`** noise still parses when normalization applies.  
- Bad row → **`import: rejected (reason): …`** — save that line for bug reports.

## Undo / redo

- Add A → add B → **undo** → only A.  
- **Redo** brings B back until you edit again.  
- **Clear** → **undo** restores (when snapshots exist).  
- **`/reload`** with queue loaded → first **undo** clears; **redo** restores.

## Login vs autosync

- Saved non-empty queue: after login, Carbonite should show the plan shortly after the map wakes up.  
- Turn **autosync OFF**, relog with a queue: you should **still** get that one login sync.  
- Turn **autosync ON** from slash/UI: expect an **immediate** sync if the map is ready.

## Debug

- **`debug` off:** chat stays mostly short lines; **`/cw probe`** is shallow.  
- **`debug` on:** `dbg()` spam; **`/cw probe`** verbose; **`/cw route`** prints every expanded point.

## UI

- **`/cw ui`:** Escape closes.  
- Import paste + button works.  
- After **`pr()`**, log scrolls to newest lines at the bottom.  
- **`/cw options`** opens the Interface category when the API allows.
