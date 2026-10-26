# Anti-Bloat & Modular Architecture Rules

Rules to prevent script bloat, performance degradation, and pipeline contention across automation scripts in this repository.

---

## 1. Single-Domain Isolation (Strict Scoping)
- **Every script must own exactly ONE domain:**
  - `EggGoToUI_v11.lua`: Egg navigation, velocity physics, Halloween farm engine, and auto-fishing.
  - `autosell.lua`: Satchel egg sales only. It must **never** query live field eggs (`AskLiveSnapshot`) or listen to field events (`FieldEggRaritiesShown`).
  - `auto-bat.lua`: Combat tool cycling and swinging only.
- **No Cross-Domain Feature Creep:**
  - Do not add features from other domains into a script just because it is convenient. Keep them separated as modular, standalone tools.

---

## 2. Zero-Crosstalk Network Budget (Push over Pull)
- **Prefer Push over Polling:**
  - If a system has real-time push events (`RemoteEvent` like `FieldEggShifted`, `FieldEggGone`), **never** poll `InvokeServer` in rapid loops.
- **Safety Sync Throttling:**
  - Background fallback sync loops must be throttled to **≥ 15s–30s** (never 1–3s).
  - Background syncs must **sleep immediately** if their target world/state is inactive (e.g. skip Overworld field sync while in Halloween Dimension).

---

## 3. Slicing & Execution Budget (Zero-Freeze Guarantee)
- **Profile / Satchel Slicing:**
  - Any loop iterating over hundreds or thousands of profile items must batch **≥ 64 items per yield** (staying under 4–5ms budget) so a full scan completes in **< 0.5s**.
  - **Never** slice at 8–16 records per frame, which creates 200+ frame yields (multi-second client freezes).
- **Idle Loop Efficiency:**
  - Standalone timer loops (e.g. autosell's 600s interval) must yield cleanly without CPU burning or redundant state checks while waiting.

---

## 4. Resource & State Governance
- **Root Locals Budget:**
  - Roblox Lua strictly limits root locals to 200. Keep root locals **≤ 190** in all monolithic or root files. Use module tables (`halloweenEngine`, `State`) for grouping.
- **Connection Leak Prevention:**
  - Every listener registered on dynamic game objects (e.g. folder children, character parts, night resets) must be tracked in a connection table and **disconnected cleanly** before reconnecting.
- **UI / DOM Recycling:**
  - Never instantiate and destroy UI frames in loops. Recycle existing card instances and update text/attributes in place.
