# Scanner v2 dump — analysis (remote + attribute inventory)

Source: **Advanced Game Scanner v2** output (`FULL SCAN` → `COPY RESULTS`, pasted by the user). Single snapshot,
no timestamps, no motion data — this is an **inventory**, so everything below is either a hard fact from the dump
or an explicitly-labelled name-based hypothesis.

Note the scanner's header ("Wins / Treadmill / Aura / Trail games") is a leftover — the namespaces in the output
are the same ones this repo's scripts use (`ReplicatedStorage.Packages.Networking.RF/EggWorld/AskFieldEggCarry`,
`AskFieldEggSnapshot`, `AskFieldEggDrop`, plus `Workspace.World.Build…CherryBlossomZone`). Same game, same API.

---

## 1. The find that matters most: `RagdollEndTime` on the Player

```
PLAYER ATTRIBUTES
  JoinTick        = 1790689722.430765
  RagdollEndTime  = 1790704017.109265
  AreaId          = Jungle
```

Both are Unix-epoch timestamps (seconds, fractional):

| attribute | value | Manila time |
|---|---|---|
| `JoinTick` | 1790689722.43 | 2026-09-29 21:48:42 |
| `RagdollEndTime` | 1790704017.11 | **2026-09-30 01:46:57** |

- Δ = **3.97 h** — matches a long farming session (the two v3.1b logs at 01:33 and 01:43 Manila are ~3 h 45 m and
  ~3 h 55 m into it).
- `RagdollEndTime` is **3 min 37 s after log 2's get-up** (01:43:20), so this particular value belongs to a *later*
  ragdoll than either log — i.e. **there was at least a third hit after 01:43**, at ~01:46:5x.

**Why this is decisive for the snap-back problem:** the server publishes the exact wall-clock end of the current
limp window as a readable Player attribute. Anything that forces `GettingUp → Running` *before* that instant is
fighting a server-owned window, and the `RigSync/*` remotes (below) are the machinery that puts you back. This is
not speculation on my part — your own reference does the opposite of fighting it:

```lua
-- grok-v3-target-fix.lua, STEP 5 (main branch)
--   * Holds motionless until server RagdollEndTime has fully expired (+0.15s margin)
--   * Prevents server physics authority from rubberbanding avatar back to Forest!
local rEnd = LocalPlayer:GetAttribute("RagdollEndTime") or 0
local ragdollExpired = (rEnd == 0) or (serverNow() >= rEnd + 0.15)
```

and it aborts early on a hit for the same reason (line ~423: `if rEnd > serverNow() then standoff = true`).

So the correct order of operations for "on hit → fly" is: **read `RagdollEndTime`; if it's still in the future,
hold (velocity-zeroed, still) until it expires + ~0.15 s, then fly.** Our `test-ragdoll-good-recovery` pulse
forces state throughout the window instead — which is why the get-up visibly happens and then gets re-corrected.

## 2. The hit family — candidates for the launch in the 01:33 / 01:43 logs

Ranked by how well the name matches "instant → limp → knockback"; **all hypotheses until listened to**:

| remote | why it's a candidate | confidence |
|---|---|---|
| `RE/BossEvent/BlackHoleHit` | a "black hole" hit is exactly a pull/launch effect | **high** |
| `RE/BossEvent/HazardHit` | generic hazard strike; pairs with `BossEvent/Hazard*` | high |
| `RE/ScrambleBoss/HazardHit` | same, Scramble boss variant; **`Workspace.DrScrambleEvent.Brock` was live in the map at scan time** and the player attribute `ScrambleCountdownReturningPlayer = true` | high |
| `RE/GuardPatrol/ForestStrike` | a strike by forest guards; both hits landed while carrying, right where the run heads toward the forest | medium |
| `RE/SammyEvent/ElephantCharge` | a charge = knockback (different event boss) | low–medium |
| `RE/SharedFx/JoltOnce` | "one-shot jolt" — name fits; probably client VFX only | low (VFX) |
| `RE/BossEvent/BossDamaged`, `HealthShifted`, `StateShifted`, `Vfx` | boss-side bookkeeping, not the player impulse | reference |

Both v3.1b logs show the same shape (instant 450–500 studs/s launch, ballistic arc, ~2.4 s limp, no anchor flip),
so whichever of these fires, it fires twice — that's testable in one session.

## 3. The snap-back / correction family (explains the `ANCHOR_FLIP` + `Horiz=0` glide)

| remote | reading |
|---|---|
| `RE/ZoneProbe/AnchorForZone` | anchors the rig for a zone transition — matches the `ANCHOR_FLIP false→true` rows in `normal-run-log-no-script.log` and the `Horiz=0` CFrame glide that ends exactly on the forest slot (612.2, 70.7, −325.0) |
| `RE/RigSync/CorrectionBegan` (+ `Primed`, `Refresh`) | "correction began" — the rig state is being corrected/snapped (client position or pose put back) |
| `RE/Limpness/WriteLimpness` | the limp/ragdoll write channel (the state your pulse is fighting) |
| `RE/SharedFx/JoltOnce` | one-off impulse/jolt presentation |

Read together: **zone anchoring + rig correction + limpness write** is the whole server-side grip on the body.
None of them are things to fight; the flight should start after the window closes.

## 4. Carrying & egg cycle — listen instead of guessing

We currently *request* carry and then infer everything. The dump shows the server tells us:

| remote | use |
|---|---|
| `RE/EggWorld/FieldEggCarry` | server-side carry confirmation (we only invoke `RF/.../AskFieldEggCarry`) |
| `RE/EggWorld/OwnerShifted` / `OwnerDropped` | carrier changed / carrier released (would catch a server-side drop) |
| `RE/EggWorld/FieldEggGone` / `FieldEggRedeemVerdict` | egg taken / redeemed verdict |
| `RE/EggWorld/FieldEggCycleCountdown` | ⭐ a **countdown event** — this is the periodic recycle you suspected, timestamped by the server |
| `RE/EggWorld/FieldEggBatchShifted` / `FieldEggShifted` | the actual reshuffles |
| `RE/EggCapture/CutsceneBegan`, `StandingsRefreshed` | capture flow (hatching/capture cutscene) |

Unused API we never touch (`RF/EggWorld/`): `AskLiveSnapshot`, `AskEggRecord`, `AskWearTool`, `AskDoffTool`,
`AskPlaceEgg`, `AskHatch`, `AskFinishHatch`, `AskFieldEggRarityShows`. `AskLiveSnapshot` in particular sounds like
a lighter-weight alternative to `AskFieldEggSnapshot` for the flight's target lookup.

## 5. Speed-related remotes — read carefully, don't over-claim

```
RE/StaffConsole/WriteWalkSpeed      RF/... (staff console family)
RE/StaffConsole/WriteSpeedPower
RE/StaffConsole/SpeedPowerVerdict
```

This is an **admin/staff** channel, and "Speed" here is the game's progression stat
(`leaderstats.Speed = 3,830,785,622`, plus `Money/s = 18,108,437,162`). `SpeedPowerVerdict` shows the server does
have *a* verdict path for "speed power", but that is a progression feature — it is **not** proof of movement
anti-cheat, and nothing in the dump validates or invalidates flight velocity. Keep the earlier position: no
evidence of a per-egg speed cap; this dump doesn't change that either way.

## 6. Scanner noise / bugs visible in the output

1. **"TREADMILL OBJECTS" is ~90 % false positives.** The search is `string.find(name, "run")`, and **"Trunk"
   contains "run"** (t-**run**-k) — so every `…Zone10Props.Trees.Tree2.Trunk` row is a tree. The genuine hits are
   `Workspace.Plots.1…7.TreadmillUpgrade` / `TreadmillBottom` and `Workspace.__ClientTreadmillRenders.TreadmillRender_N`
   (client-rendered, the same pattern as `ClientRenderedAssets`). Also matched: `Animate.run` StringValues and
   `HumanoidRootPart.Running` sounds — real "run" matches, irrelevant to hitting.
2. **Character attributes = `(none)`** → carry/ragdoll flags do **not** live on the character; they're on the Player
   (`RagdollEndTime`) and in remotes. Our Tool-based carry check is the right call.
3. **No `IsCarrying` attribute at scan time** — consistent with it existing only while carrying (we check it
   *or* a `Tool`).
4. `IsOnTreadmill right now: nil` — that attribute belongs to the other game the scanner was written for; ignore.
5. `RemoteEvent`-only scan: if the game ships anything as `UnreliableRemoteEvent`, it would not appear here at all
   (class check is `IsA("RemoteEvent")`). Can't tell from this dump — worth one `IsA("BaseRemoteEvent")` run.

## 7. What to do next (one capture answers the remaining questions)

A **listener-only** scanner (new file; `scanner_v3.1.lua` and `scanner-2.8.lua` stay untouched):

1. Hooks the candidate REs read-only — `BossEvent/BlackHoleHit`, `BossEvent/HazardHit`, `ScrambleBoss/HazardHit`,
   `SharedFx/JoltOnce`, `GuardPatrol/ForestStrike`, `Limpness/WriteLimpness`, `ZoneProbe/AnchorForZone`,
   `RigSync/CorrectionBegan`, `EggWorld/FieldEggCarry`, `EggWorld/FieldEggCycleCountdown` — logging **name + payload
   + millisecond timestamp** on every firing (never `:FireServer`, never invoked).
2. Logs `RagdollEndTime` / `AreaId` / `Humanoid.Health` / `WalkSpeed` transitions with ms timestamps.
3. Emits a `HIT` row on the first frame where `state == Physics` and |Δv| > 400 studs/s.

That gives: which remote fires on the hit, the exact server limp window for that hit, and whether `Health` moves —
the three things the two v3.1b logs could not show.
