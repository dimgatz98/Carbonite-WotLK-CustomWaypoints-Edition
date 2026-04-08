# Invariants — CustomWaypoints

These are NON-NEGOTIABLE behaviors.
If any of these break, the addon is considered broken.

---

## 1. Queue Ownership

- The waypoint queue is owned ONLY by CustomWaypoints.
- Carbonite must NEVER be the source of truth.
- Carbonite is a rendering/output layer only.

---

## 2. Sync Contract

- Sync pushes a REDUCED route into Carbonite.
- Carbonite clears must NOT wipe the CW queue during sync.
- User-initiated clear MUST wipe the queue.

---

## 3. Routing Modes

- Minimal mode:
  - No unnecessary intermediate walk nodes
  - Delegates routing to Carbonite

- Deep mode:
  - Full explicit route (graph-based)
  - CW controls path construction
  - Carbonite must NOT override routing decisions

---

## 4. Known Locations

- Single source of truth for:
  - instances
  - transports
  - saved routes
- No parallel "transport management" systems allowed
- Import must MERGE (union), not replace

---

## 5. Transport Discovery

- Must:
  - avoid duplicates
  - avoid spam confirmations
- “No” decision must suppress repeats
- Missing map data must NOT block detection

---

## 6. Death Auto Route

- Must be OPTIONAL (user-controlled)
- Must NOT trigger instantly (requires delay/retry)
- Must NOT spam or loop infinitely
- Must use safe retry mechanism:
  - pending state
  - pulse loop

---

## 7. UI Behavior

- ESC closes most recent CW frame only
- UI must NOT block player movement (WASD)
- Frames must not leak or stack incorrectly

---

## 8. Persistence

- SavedVariables = single source of persistence
- Reload must:
  - restore queue
  - restore known locations
- No hidden in-memory-only state should override saved data

---

## 9. Import/Export

- Export format must remain stable
- Import must:
  - validate input
  - fail safely
- Known Locations import must deduplicate correctly

---

## 10. No Hidden Logic

- Routing behavior must be controlled by:
  - tuning parameters
  - explicit settings
- No hidden biases or hardcoded magic numbers
