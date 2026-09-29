# Log analysis — run `01:33:38` (scanner v3.1b, 8 s window)

Source log saved verbatim as `01-33-38-run-v3.1b.log`. Compared against the two reference runs that use the
**same scanner version** and the same post-pickup stage: `normal-run-log-no-script.log` (11:42) and
`other-script.log` (09:30).

## Bottom line

1. **The egg pickup was at the far end of the map, not at the forest.** `EGG_STATE EMPTY → HOLDING` fires at
   **(5660.0, 70.7, −332.8)** — 5,048 studs from the forest slot (612, 70, −325) that both reference runs pick up at.
2. **4 s later the character is launched and ragdolled in one shot**: `Running → Physics` at
   (5246.6, 71.1, −344.3) with an instantaneous velocity of **(−495, +71, −26)** studs/s.
3. **Nothing re-wrote the velocity after that impulse.** The vertical component decays at **−194 studs/s²**
   (Roblox gravity is 196.2), and once the character touches down the horizontal speed decays at
   **−55.6 studs/s²** (Plastic friction 0.3 × gravity = 58.9). Both are textbook free physics — a scripted
   flight re-writes `AssemblyLinearVelocity` every frame, so it would show neither.
4. **No position/CFrame movement at all**: 0 `CFRAME_BURST`, 0 `ZERO_HORIZ`, 0 `HARD_SNAP`, and `Anch=false`
   on every row. This is a pure velocity+gravity event, not a teleport/glide.
5. **Travel: 1,594 studs in the −X direction** (ΔX = −1,593, ΔZ = −62) from the pickup point, ending at
   (4051.5, 70.1, −395.4) — **36 studs from the exact spot where the unscripted runs get anchored + ragdolled**
   ((4016.0, 70.5, −391.4) and (3980.8, 70.7, −387.7)).
6. **The egg survived** — `Egg=YES` on every row, no second `EGG_STATE`, no drop.
7. **Recovery happened at the end**: `Physics → GettingUp → Running` in the same second (01:33:44). The
   unscripted run shows the identical transition (without any script), so **this log does not prove your
   recovery pulse fired** — the scanner doesn't log Motor6D / `SetStateEnabled` activity.
8. **The log was cut 2 s after landing.** In both reference runs the interesting part (anchor flip, ragdoll,
   and the zero-velocity glide back to the forest slot) happens *after* this point.

## Timeline

| time | event | what it means |
|---|---|---|
| 01:33:38 | `START`, `EGG_STATE EMPTY→HOLDING`, `ZONE none→EGG_AREA` at (5660, 70.7, −333) | pickup already happened at the far end (X > 4500 = the scanner's hard-coded `EGG_AREA` rule) |
| 01:33:38–40 | `ANIM_START` idle + run tracks, Core Spd 12.1 | humanoid alive and running (reference runs show 6.5 / 7.7 at the same point) |
| 01:33:42 | `HUM_STATE Running → Physics` at (5246.6, 71.1, −344.3) | ragdoll starts, velocity already ≈ 500 horizontal + 71 up |
| 01:33:42–43 | 15 `LARGE_MOVE` rows, Y 71→86→68, vy +71→−78 | single ballistic arc: launch, apex, fall — gravity only |
| 01:33:43 | Y settles at 68.0–68.6, clearance H 0.3–0.9; `ZONE EGG_AREA → TRANSIT` at X=4497.9 | touching the ground, sliding; the zone flip is only the scanner's `pos.X > 4500` rule (not a game event) |
| 01:33:44 | `Physics → GettingUp` at (4066.8, 69.9, −394.4), then `GettingUp → Running` at (4051.5, 70.1, −395.4) | ragdoll over after ~2.4 s, humanoid back in control, still holding the egg |
| 01:33:44–46 | anim tracks stop/restart, `COPY` | recording stopped 2 s after landing |

Per-second digest (Horiz = horizontal component of `AssemblyLinearVelocity`):

```
+0s  START,EGG_STATE,ZONE,ANIM    pos=(  5660, 70.7,  -333)
+2s  ANIM only                    (no movement logged)
+4s  HUM_STATE(→Physics),MOVE     pos=(  4865, 73.5,  -362)   Horiz 496-535   vy  -69.5..+70.9  (15 rows)
+5s  MOVE,ZONE                    pos=(  4498, 68.0,  -377)   Horiz 470-530   vy  -78.5.. +4.1  (13 rows)
+6s  MOVE,HUM_STATE(→Running)     pos=(  4052, 70.1,  -395)   Horiz 410-443   vy   -8.0.. -0.5  ( 8 rows)
+7s  ANIM only
+8s  COPY
```

## The physics fit (the important part)

| phase | measurement | expected from plain physics |
|---|---|---|
| airborne, frames #0011→#0026 (0.725 s) | vy `+70.9 → −69.5` = **−194 studs/s²** | Roblox gravity **−196.2** |
| ground contact, frames #0028→#0049 (1.603 s) | Horiz `500 → 410` = **−55.6 studs/s²** | Plastic friction μ=0.3 × 196.2 = **−58.9** |

Both phases match free physics within ~1–6 %. That is only possible if **no script was writing velocity during
the window**: the launch was a one-shot impulse, after which gravity (in the air) and ground friction (after
touchdown) did all the work. Every flight implementation in this repo re-asserts velocity each frame
(grok-v3 waypoint chase with its 1125 clamp; the auto-calc `distance/remaining` versions; the straight-line
version in `simple_recovery_ui.lua`), so none of them produced this motion.

Also absent: `PlatformStand` never flipped, `Anchored` never flipped, no network-owner change was observed
(`Net=nil` on every row — the scanner's `GetNetworkOwner` pcall returns nothing client-side, so this field is
inconclusive rather than evidence of anything).

## Compared to the two reference runs (same scanner)

| signature | 01:33 run (this log) | `normal-run-log-no-script.log` | `other-script.log` |
|---|---|---|---|
| horizontal speed | **496–535 studs/s** (≈2×) | 232.6 / 250 studs/s | 0 / 223.3 / 232.6 studs/s |
| movement type | one ballistic impulse, Physics for 2.4 s | hop-flap: 146 `HUM_STATE` rows, `Running→Jumping→Freefall→Landed` (~1 s cycle) | 77 `ZERO_HORIZ` + 82 `CFRAME_BURST` (position-driven glide, Horiz = 0) |
| anchor flips | 0 | 6 (`ANCHOR_FLIP true` + Physics→GettingUp→Running) | 0 |
| `HARD_SNAP` / teleports | 0 | 0 | 0 |
| `HEIGHT_UNSTABLE` / `HEIGHT_JUMP` | 0 / 0 | 0 / 0 | 58 / 7 |
| `FLIGHT_START`/`END` | 0 (see below) | 0 | 6 |

So the game itself moves a carrying player around at **~233–250 studs/s** (velocity-driven, hopping) or by
**position/CFrame glide** (`Horiz=0`, CF up to 4,400 studs/s — that is the "snap-back" family, and it lands
exactly on the forest slot (612.2, 70.7, −325.0)). The 01:33 event is neither: it is **2× faster, arc-shaped,
and ragdolled**, which makes it a hit/launch rather than the normal carry transport.

## What this log canNOT tell you (scanner blind spots)

1. **`FLIGHT_START`/`FLIGHT_END` never fire here** because the detector needs `Horiz < 2.5` for 4 samples
   (`FLIGHT_DETECT_STREAK`) — it was written for the *zero-velocity CFrame glide*, not for a velocity-driven
   flight. A horizontal flight at 500 studs/s is invisible to it (the 09:30 run did trigger it, and those rows
   are the glide).
2. **No `WalkSpeed`, no `MoveDirection`, no orientation** in the log. WalkSpeed alone would identify the writer
   (500 = `simple_recovery_ui.lua`'s flight, a grok-style run speed = grok's, etc.), and orientation is the only
   way to prove/disprove **rollover**.
3. **Second-resolution timestamps** — a 1.6 s flight cannot be measured to better than ±1 s from this log.
4. **`LARGE_MOVE` has a 12-stud threshold**, so it logs only part of the trajectory: the 36 rows cover 591 studs
   of the 1,181-stud displacement (the rest was moved in sub-12-stud frames). Counts of "how far" from
   `LARGE_MOVE` rows alone under-report.
5. `dt=0.000` on row #0011 is an artifact (first `LARGE_MOVE` in the session), not a zero-length frame.
6. `ZONE EGG_AREA → TRANSIT` is the scanner's `pos.X > 4500` rule — no game-side transition happened.

## Suggested next measurements

- **Keep the recording running 30–60 s past the landing.** Both reference runs anchor/ragdoll the character
  around X≈4000, Z≈−390 and then glide it home with `Horiz=0`; this log stopped 2 s after arriving there.
- **Add three columns** to a *new* scanner file (I won't touch your v3.1/2.8 files): `Humanoid.WalkSpeed`,
  `Humanoid.MoveDirection`, and `RootPart.CFrame.UpVector.Y` (rollover), plus millisecond timestamps and a
  horizontal-flight detector (`Horiz > 200 && moved > 12`).
- **Run the flight script's own log next to the scanner** so the two can be lined up by second — that is the
  only way to attribute a ~500 studs/s launch to a script instead of to a server event.

## Practical read for your goal ("on hit → fly straight to the biome egg")

In this window the client flight did not win and probably never ran: the character was ragdolled and carried
1.6 k studs **away** from the egg area by a single impulse, with no velocity re-assertion anywhere in the 8 s,
and the only recovery visible is the same `Physics → GettingUp → Running` the unscripted run performs on its
own. If the pulse/flight did fire, it fired outside this window — and the next data point to capture is the
30 s *after* the landing, where the anchor-flip + glide sequence lives.
