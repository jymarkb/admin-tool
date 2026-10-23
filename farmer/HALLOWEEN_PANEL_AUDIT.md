# Halloween Panel — Full Feature Audit

**Scope:** `farmer/EggGoToUI_v11.lua` only (6,637 lines). Everything below is inside that file.
**Panel entry point:** sidebar `🎃` → `tabBtnHalloween` (line 732) → `tabHalloween` frame (line 778).
**Method:** full read of the panel UI block (778–1300), the Halloween egg resolver (4008–4175), the
Halloween engine (4176–5157), the card renderer + TP/Get actions (5500–5805), the auto-pickup module
(5806–6083), and the shared event/loop/cleanup tail (6441–6637). Structure was also syntax-checked
(Luau `continue` neutralised for the parser); the file is structurally sound, so every issue below is
behavioural, not a parse error.

---

## 1. Feature inventory (what the panel actually contains)

| # | Feature | UI location | Engine code | Status |
|---|---------|-------------|-------------|--------|
| F1 | Auto Farm Engine toggle | row y=6 | `halloweenEngine.autoFarm` (4218–4490) | Works, but see H1/H3/M5 |
| F2 | Auto Fishing toggle | row y=46 | `halloweenEngine.fishing` (4491–5076) | Works, rod-name brittle (M9) |
| F3 | Auto Pick [E] toggle | y=86 | `startHalloweenAutoPickup` (6032) + `[E]` handler (3754) | Arms a 1.2 s burst only (H7) |
| F4 | Rarity filter dropdown | y=114 | `selectedHwRarities` (795, 1030–1185) | Works, drift vs farm/targeting (M2) |
| F5 | Live Halloween egg list | scroll y=144 | `renderHalloweenEggs` (5632) | Works, expensive (L1) |
| F6 | Per-egg **TP** button | card | `halloweenEngine.tpAction` (5158) | Works, no retry/backoff (M5/M8) |
| F7 | Per-egg **Get** button | card | `walkToTarget` + `pickupHwEgg` + safe-zone walk (5587–5625) | Works, token collisions (M4) |
| F8 | Activity & Fishing log (COPY) | bottom 110 px | `fishing.log` (4515) | Works |
| F9 | Status line ("In Dimension (N Live) / Deliv") | — | `hwStatusLabel` (788, 5769) | **Never rendered — dead** (M1) |
| F10 | Night-reset detector | none | `triggerNightReset` (4186) | Fire-prone (H2) |
| F11 | Dimension gate ("are you in Halloween?") | none | — | **Missing** (H3) |
| F12 | Continuous auto-pickup loop | none | — | **Missing** (F3 is keypress-only) |
| F13 | Panic / stop-all control | none | — | **Missing** (B1) |

Cross-feature wiring worth knowing: `[E]` picks **either** the Halloween burst (`hwAutoPickEnabled`) **or**
the Utility fast-pickup (`PICKUP_CONFIG.Enabled`) — the two toggles are mutually exclusive by design
(988–999 and 2372–2395), so exactly one path is always armed.

---

## 2. Findings

### BLOCKER

**B1 — Closing the window does not stop Auto Farm / Auto Fishing.**
`fullCleanup` (6596) only flips `_G.EggGoToUI_Stop` (which stops the two `task.spawn` loops at 6474 and
6511), disconnects tracked connections and destroys the GUI. It never touches
`halloweenEngine.autoFarmEnabled`, `autoFarmToken`, `fishing.enabled/token`, `hwAutoPickEnabled` or
`hwPickupToken`.
Repro: enable **Auto Farm**, click `✕`. The farm token stays valid, so `runNextCycle` → `tpAction` keeps
teleporting and picking eggs forever with no UI, no log and no way to stop it short of re-executing or
resetting. Same for the fishing loop.
Fix (inside `fullCleanup`, before `disconnectAll()`):
```lua
pcall(function()
    if halloweenEngine then
        halloweenEngine.autoFarmEnabled = false
        halloweenEngine.autoFarmToken   = (halloweenEngine.autoFarmToken or 0) + 1
        if halloweenEngine.fishing then
            halloweenEngine.fishing.enabled  = false
            halloweenEngine.fishing.running  = false
            halloweenEngine.fishing.token    = (halloweenEngine.fishing.token or 0) + 1
            halloweenEngine.fishing.autoCycleActive = false
        end
    end
    hwPickupToken = (hwPickupToken or 0) + 1
    autoPickupToken = (autoPickupToken or 0) + 1
    stopWalking()
end)
```

---

### HIGH

**H1 — Once fishing starts, egg farming never resumes until a "night reset".**
`runNextCycle` (4391) polls `findTarget()` only *before* and *during the 3 s wait*. It then calls
`fishing.runAutoCycle(farmToken)`, whose loop (4967) exits **only** on night reset or farm-off.
Consequence: after the first moment with no matching egg, the bot fishes indefinitely and only farms eggs
again if/when `triggerNightReset` fires. On a dimension with a static night or a missing
`RE/EggWorld/FieldEggCycleCountdown` remote (A2), that is *never* → the "Auto Farm" feature degrades into
"Auto Fish".
Fix — re-poll inside the fishing loop:
```lua
while halloweenEngine.autoFarmEnabled and halloweenEngine.autoFarmToken == farmToken do
    local inGrace = halloweenEngine.isNightResetActive()
    if inGrace then break end
    if halloweenEngine.autoFarm.findTarget() then
        halloweenEngine.fishing.log("Matching egg spawned -> back to farm phase.")
        break
    end
    halloweenEngine.fishing.executeSingleCycle(shouldAbort)
    ...
end
```

**H2 — Night-reset detector fires outside Halloween and on unrelated events.**
Two independent triggers, neither gated on the dimension:
* `RE/EggWorld/FieldEggCycleCountdown` with `cd <= 1` (6397–6406) — that is an egg-world cycle countdown, not
  necessarily the Halloween night cycle.
* `Lighting.ClockTime` day→night transition (6454–6473) — true in every map, every dusk.
Each hit stops fishing, resets `cachedWorldEggs` and parks the farm in a 15 s grace (`triggerNightReset`,
4186; 45 s debounce only limits repeats). A false reset mid-cycle costs a fishing cycle and can abort a
carry (`fishing.stop` → the walk keeps running, see M11).
Fix: bail out early unless the player is in the dimension, e.g.
```lua
local inHw = (LocalPlayer:GetAttribute("InHalloweenDimension") == true)
    or (Workspace:FindFirstChild("HalloweenDimension") ~= nil)
if not inHw then return end
```

**H3 — No "not in the Halloween dimension" guard on Auto Farm.**
`findTarget` returns nil, the state machine goes "waiting 3 s → fishing", `runAutoCycle` then walks the
player toward the hard-coded `fishing.spotPos = (-5695.6, -203.7, -7370.9)`, defined at 4500; walk at 4936–4966) — up to 45 s of
auto-walking in the wrong map — and repeats forever. Nothing in the panel says why.
Fix: at the top of `autoFarm.start()` / `runNextCycle`, if the dimension is absent, set
`lblFarmStatus = "Status: Enter Halloween Portal"` and `return` (keep the button ON so it auto-starts on
entry, but do not burn cycles).

**H4 — `isHoldingEgg()` reads a stale *global* `hwCarryState`.**
`isHoldingEgg` is defined at 2599 and references `hwCarryState` at 2608; the `local hwCarryState = {...}`
declaration is at 2637 — *after* it. Lua therefore compiles that reference as a **global** lookup
(always nil), so:
* `or (hwCarryState and hwCarryState.active)` is dead code today, and
* if anything ever sets a global `hwCarryState`, **any** equipped `Tool` (including `Haunted Rod [X1]`)
  would be reported as "carrying an egg" — which short-circuits `tpAction` step 1, `pickupHwEgg` and the
  `[E]` burst.
Fix: declare the `hwCarryState` table above `isHoldingEgg` (or forward-declare `local hwCarryState` at the
top with the other Halloween locals at 788–801) and drop the clause.

**H5 — "Secured" detection accepts *any* egg-named Tool, then force-equips it.**
`tpAction`'s `checkReSecured` (5324–5380) treats a Tool in `Character` **or `Backpack`** as success when
`name:find("egg")`, `IsEgg`, `HalloweenEggUid ~= nil`, or the name merely *contains* `eggData.Name`. It then
`h:EquipTool(t)` it. With eggs parked in the player's base or backpack, the flow reports a false success,
walks to the drop zone carrying nothing, and can swap the player's held tool mid-route.
Fix: match on `Uid`/`HalloweenEggUid` equality against `eggData.Uid` only; never equip from `Backpack`.

**H6 — Prompt fallback can fire a prompt for a *different* egg.**
`findBestHwPickupTarget` (5888–5900) and `executeHwPickupSpam` (5937–5942) fall back to "first carry prompt
anywhere under `Workspace.SmartPromptPart`" when the target model has no own prompt. Since scoring accepts
targets up to 45 studs away and prompts live in one shared holder, the fired prompt need not belong to the
scored egg → wrong egg grabbed, or the intended one missed.
Fix: only use a `SmartPromptPart` prompt when its `Parent` chain / attributes reference the target uid or
model, and cap the fallback distance (~10 studs).

**H7 — Auto Pick [E] ignores the rarity filter directly above it.**
`findBestHwPickupTarget` scores by camera/character facing and distance only; `startHalloweenAutoPickup`
(6032) never consults `selectedHwRarities`. A user who filters to `Divine` and presses `[E]` will still
grab a Common `Mummy Egg` in front of them.
Fix: compute `getHwEggName(egg)` → rarity in the scoring loop and skip non-matching rarities (mirror the
`All` / `New Update` rules from `renderHalloweenEggs`).

---

### MEDIUM

**M1 — `hwStatusLabel` is dead: the status line never exists.**
Declared at 788, written at 5769–5773 ("In Dimension (N Live) | Deliv: X" / "Outside Dimension (Portal
Ready)") — but no `Instance.new` anywhere assigns it. The panel therefore has **no** dimension/live-count/
delivered readout, which is exactly the information the empty-state text tries to convey.
Fix: add a 16 px `TextLabel` under the Auto Pick row (or into the log header) and assign `hwStatusLabel`.

**M2 — "New Update" eggs are listed but can never be farmed.**
`renderHalloweenEggs` force-shows uncatalogued eggs regardless of filter (5728–5730), while
`autoFarm.findTarget` requires `selectedHwRarities[rarName]` to be true (4291–4294) and **`New Update` has
no row in the dropdown** (1030–1185). So the list advertises eggs the farm will never touch, and their
`Rank = 99` (1386) sorts them above `Divine` in the visible list. Add a `New Update` row to
`RARITY_ORDER`/dropdown, or hide these eggs behind an explicit "Show uncatalogued" switch.

**M3 — The Auto Pick / Fast Pickup reciprocal coupling is surprising and asymmetric.**
`setHwAutoPick(false)` silently *enables* Utility Fast Pickup (998) and `setUtilityAutoPick(false)`
silently *enables* Halloween Auto Pick (2388). Because `PICKUP_CONFIG.Enabled` starts `true` (1337) and
`hwAutoPickEnabled` starts `false`, a user who turns the Halloween toggle **off** hands `[E]` to the
utility engine (which scans `AreaEggSlotsClient`/`Workspace.Eggs` in *any* map) with no indication in the
Halloween tab.
Fix: single shared `pickupMode` state, reflected on both rows, or a radio-style "Halloween / Utility / Off".

**M4 — One pickup token shared by three flows.**
`hwPickupToken` is bumped by `tpAction` (5180), `pickupHwEgg` (5953) and `startHalloweenAutoPickup` (6036).
Pressing `[E]` during a farm TP, or clicking **Get** on another card while a TP is in flight, cancels the
first flow at its next checkpoint — potentially after the egg was dropped at the drop point but before the
re-pickup walk, i.e. the egg is left on the ground.
Fix: separate tokens (`tpToken`, `pickupToken`, `autoPickToken`) or refuse `[E]` while a TP action's token
is live.

**M5 — No failure backoff in the farm loop.**
`tpAction(onComplete(false))` → `runNextCycle` retries the **same** egg 0.5 s later (4442–4468), forever, if
the egg is unreachable / owned by another player / the server refuses. Every retry is 3 s of 35 ms CFrame
teleports plus ~85 remote invokes → log spam and a real chance of a rate-limit.
Fix: per-uid failure counter, skip for 15–30 s after 2 failures, and skip uids whose
`HalloweenEggCanPickUp == false`.

**M6 — `reSecured` can be set by a *rejected* invoke.**
In `tpAction` step 3 (5395–5399) `local ok = pcall(function() return hwRf:InvokeServer(uid) end)` sets
`reSecured = true` whenever the call did not throw — including a server reply of `false/nil`. The code then
walks to the safe zone believing it holds the egg.
Fix: `local ok, accepted = pcall(...); if ok and accepted ~= false and accepted ~= nil then reSecured = true end`
(preferably the same truthiness contract the server actually returns).

**M7 — Remote fire rate is very high.**
`executeHwPickupSpam` fires **2 parallel** `RF/HalloweenDimension/AskCarryEgg` invokes every 35 ms
(~57/s sustained for up to 3 s in TP) plus a prompt fire, plus — in step 3 — 4 more invokes and an
`RF/EggWorld/AskFieldEggCarry` per attempt (5395–5414). The utility engine, by contrast, uses a fixed
8-burst per target (`carryEgg`). Consider a burst-per-target model and a global cooldown.

**M8 — Movement is teleport-first with no distance/collision validation.**
`tpAction.setPlayerPos` (5185) writes `hrp.CFrame` to the egg position every 35 ms; `applyReachAssist`
(3486) does the same from up to 35 studs. Only `walkToTarget` is physics-based. Expect anti-cheat flags /
rubber-banding, and no fallback if a teleport is rejected (the loop just retries).
Fix: detect "teleport did not take effect" (position delta < some epsilon after 0.15 s) and fall back to
`walkToTarget` for that egg.

**M9 — The fishing rod must match `"Haunted Rod [X1]"` exactly.**
`fishing.rodName` (4502) + exact `:lower() ==` match in `findRod` (4567). If the player owns a different
variant (or the tool is renamed by the game), `ensureRodEquipped` returns false every cycle and the loop
keeps retrying with a 0.4 s pause **forever** (4590, loop 4967–4985), writing one log line per cycle and never telling
the user in the status line (it only writes `lblFishStatus` inside the cycle).
Fix: fuzzy match (`name:find("haunted rod")`), and stop with
`"Status: Rod '...' not in inventory"` after 3 consecutive failures.

**M10 — Equipping the rod is not guarded against carrying an egg.**
`ensureRodEquipped` (4590) calls `hum:EquipTool(rod)` with no `isHoldingEgg()` check. Swapping a held tool
in most egg games drops the carried egg; the farm phase drops deliberately via `AskDropEgg`, but the manual
Auto Fishing button path (`fishing.start`, 4990) can be pressed while a Halloween egg is in hand.
Fix: refuse to start / unequip-and-drop-first, and log why.

**M11 — Fish button UI lies after any auto stop.**
`fishing.stop()` (5059) always resets `hwAutoFishBtn` to `OFF`, and it is called by `triggerNightReset`
(4198) and `autoFarm.stop` (4388) — but during a farm-driven fishing phase the button previously read
`AUTO`. After one night reset the button stays `OFF` while the engine is still farm-managing fishing.
Fix: in `stop()`, if `autoFarmEnabled` then show `AUTO` (blue) instead of `OFF`.

**M12 — Placeholder copy left in the shipped UI.**
Initial `lblFarmStatus = "Status: Idle (Placeholder)"` (835) and `autoFarm.stop` writes
`"Status: Idle (Placeholder)"` (4375). `triggerNightReset` formats `"%.1fs/16s"` (4201) while `start`
formats `"/15s"` (4352). Cosmetic but it reads unfinished.

**M13 — `target` used before its `local` in `startHalloweenAutoPickup`.**
Line 6049 `hwCarryState.name = target and target.Name or "Halloween Egg"`, while
`local target = findBestHwPickupTarget()` appears at 6055. The reference resolves to a global → always nil
→ the log/status name is always the generic fallback. Move the `local` above the loop.

**M14 — Egg naming trusts arbitrary child strings and fabricates names.**
`getHwEggName` step 2 (4060) accepts **any** child `StringValue` and step 3 any child `Model` name;
`resolveCanonicalHwName` (4022) appends `" Egg"` to any unrecognised string. A `Uid`/`Owner` StringValue
child yields a display name like `"3f2a91c0e4… Egg"` and forces the egg into the "New Update" bucket
(where it sorts to the top, see M2).
Fix: skip hex-32 / numeric / known metadata keys before calling `resolveCanonicalHwName`.

**M15 — Prompt-species inference is O(descendants × species) and non-deterministic.**
`getHwEggName` step 4 (4088–4110) iterates every descendant and every key of `SPECIES_INFO` (≈250 entries)
and `break`s on the *first* `pairs()` hit. For a prompt reading "Halloween Egg" a short alias can beat the
specific species, and the cost is paid per egg per render tick (see L1).
Fix: build one lowercase `name → record` index at load, precompute the egg's name once per model and cache
it on the model (or in a weak table keyed by model + `PreparedSourceName`).

---

### LOW / polish

* **L1 — Full list rebuild every 0.3 s.** The render loop (6474) calls `renderHalloweenEggs` whenever the
  tab is visible, with no dirty flag (contrast the Eggs tab's `listDirty`, 3745). Each tick re-collects
  `GetTagged` + `WorldEggs:GetChildren`, resolves every egg name (M15), builds a table per egg and sorts.
  Recommend: `hwListDirty` flag set by attribute/`ChildAdded`/`ChildRemoved` + a 0.4–0.5 s throttle, and a
  name cache.
* **L2 — Untracked connections.** `hwAutoPickBtn` (1002), the rarity row buttons (1142), `All`/`None`
  (1164/1171) and the log `COPY` button (1265) bypass `addConnection`, unlike every other handler in the
  file. Harmless after `screenGui:Destroy()` but inconsistent and it keeps closures alive.
* **L3 — Dead store:** `hwPickupToken = 0` at 5807 re-assigns an upvalue that later functions already
  captured; no runtime effect, leftover from refactoring.
* **L4 — Unused hook:** `halloweenEngine.other` (5078) is never read.
* **L5 — Dropdown overlaps the log box.** `hwRarityDropList` spans y≈140–396 while `hwLogFrame` starts at
  y≈368; rows 9–10 (`Eternal`, `Divine`) render over the log. ZIndex 50 keeps them clickable, but it looks
  broken. Open the list upward or shrink to 18 px rows.
* **L6 — Misleading empty-state.** With `All` selected and zero eggs the text says "All Halloween eggs
  currently collected or respawning" — fine — but the *filter-empty* branch triggers for any non-`All`
  selection, including `None`, where the advice "adjust rarity filter" is unhelpful; `None` should say "no
  rarity selected".
* **L7 — Duplicated clipboard helper.** The log `COPY` button rolls its own `setclipboard`/`toclipboard`
  (1265–1288) while `copyToClipboard` already exists (6089).
* **L8 — Duplicate comment:** `-- 3. Wait Bite` twice (4806 and 4812) in `_executeSingleCycle`.
* **L9 — No state persistence.** `selectedHwRarities`, `hwAutoPickEnabled` and both engine states reset on
  re-execute; the panel is rebuilt from scratch every load.
* **L10 — Stats not surfaced.** `fishing.catchCount` / `cycleCount` are maintained but only printed into the
  log; there is no catch counter in the panel.
* **L11 — Farm row doesn't state the priority.** `findTarget` sorts `Rank` desc → `Distance` asc
  (4300–4310), i.e. Divine → Eternal → Secret → ... then nearest. The row subtitle never says this, and
  with the default filter `{Divine, Eternal, Secret}` (795) a user cannot tell why a `Mythic` is ignored.

---

## 3. Two behaviours worth confirming in-game (assumptions baked into the code)

**A1 — Zone-1 heuristic.** `tpAction` decides "Zone 1" from `eggData.Zone == 1`,
`model:GetAttribute("Zone") == 1`, **or** `targetPos.Z < -6500 and targetPos.Z > -7050` (5271–5274).
Zone 1 eggs are routed through `walkViaDropZoneToSafeZone` instead of the drop remote. If the real zone
geometry differs, eggs silently take the wrong branch: either an un-droppable egg keeps being teleported to
`dropPos` and re-picked (loop of failing TP attempts), or a droppable egg is carried manually the whole way.
Verify the Z window against the live map before trusting Auto Farm on Zone 1.

**A2 — Night reset exists at all.** The whole farm↔fish cycle pivots on `triggerNightReset`. If the
dimension has a static night and `RE/EggWorld/FieldEggCycleCountdown` is absent or unrelated, H1 means the
bot will fish forever. Add a manual "Back to farming" action or the H1 poll regardless.

**A3 — Hard-coded coordinates.** `dropPos (-5959.7, -203.7, -7127.0)`, `safeZone (-5963.8, -203.7,
-7274.8)` (4177–4179) and `spotPos (-5695.6,-203.7,-7370.9)` / `castPos (-5668.5,-206.5,-7368.9)` (4500–4501)
are all fixed. Any map revision breaks the panel with no error message, only endless walking.

---

## 4. Suggested fix order

1. **B1** (stop engines on close) — one function, biggest safety win.
2. **H1** (re-poll eggs while fishing) — restores the documented "farm → 3 s → fish → farm" contract.
3. **H3 + H2 gating** (dimension guard, night-reset guard) — eliminates the "walking to a spot in the wrong
   map forever" and the false resets, and makes the panel honest about why it is idle.
4. **M1** (`hwStatusLabel` creation) — gives the above states somewhere to be visible.
5. **H4 / H5 / M6** (carry detection correctness, uid-only matching, accepted-reply check) — prevents false
   successes and stray "deliveries".
6. **H6 / H7 / M2** (targeting respects the seed egg and the rarity filter; add a `New Update` row).
7. **M5 / M9 / M11** (failure backoff, rod fuzzy-match + stop, `AUTO` button state).
8. **L1 / M15** (dirty-flag rendering + name cache) — cheap and removes the only real per-frame cost.
