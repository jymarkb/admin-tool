# Boss-hit log analysis — 01:33:38 and 01:43:13 (scanner v3.1b)

**Attribution: both runs are boss hits (confirmed by the user).** That corrects the earlier reading of run 1: the
impulse at 01:33:42 was not the game's normal carry transport, it was a boss knockback. Raw logs are saved as
`01-33-38-run-v3.1b.log` and `01-43-13-run-v3.1b.log`; the reference runs from `main`
(`normal-run-log-no-script.log`, `other-script.log`) use the same scanner and are quoted for contrast.

## Boss-hit signature (reproduced twice, 10 minutes apart)

| | RUN 1 — 01:33:38 | RUN 2 — 01:43:13 |
|---|---|---|
| pickup position | (5660.0, 70.7, −332.8) | (5666.4, 70.7, −332.7) |
| pre-hit travel (4 s, no state change logged) | 414 studs ≈ 103 studs/s | 277 studs ≈ 69 studs/s |
| hit: `Running → Physics` | 01:33:42 (5246.6, 71.1, −344.3) | 01:43:17 (5389.2, 70.4, −332.8) |
| launch velocity | (−494.8, **+70.9**, −26.4) = **501** studs/s | (−449.5, **+13.3**, −3.5) = **450** studs/s |
| apex | Y 86.1 = **+15.0** above launch | Y 79.7 = **+9.3** above launch |
| airborne (launch → first ground contact) | 0.73 s | ~0.99 s |
| ground skid | 1.58 s, Horiz 500 → 410 | 1.14 s, Horiz 476 → 411 |
| skid deceleration | **−57 studs/s²** | **−57 studs/s²** |
| **ragdoll total (launch → control)** | **2.46 s** | **~2.4 s** |
| recovery (`Physics → GettingUp → Running`) | 01:33:44 at (4051.5, 70.1, −395.4) | 01:43:20 at (4454.1, 69.6, −321.7) |
| knockback distance (launch → recovery) | **1,196 studs** (ΔX −1195, ΔZ −51) | **935 studs** (ΔX −935, ΔZ +11) |
| pickup → recovery | 1,610 studs | 1,212 studs |
| distance from recovery point to forest egg slot (612.2, 70.7, −325.0) | 3,440 studs | 3,842 studs |
| egg held throughout | yes (`Egg=YES` every row) | yes (`Egg=YES` every row) |
| `CFRAME_BURST` / `ZERO_HORIZ` / `HARD_SNAP` / `ANCHOR_FLIP` | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| `Plat` / `Anch` / `Net` | false / false / nil on every row | false / false / nil on every row |

Same event class, same direction (almost pure −X: away from the far egg area, toward the forest side of the map),
same friction-limited skid, same ~2.4–2.5 s limp window. Run 1 was the stronger hit (bigger launch vector, higher
apex, longer skid).

## Run 2 timeline

| time | row | event |
|---|---|---|
| 01:43:13 | #0002–#0003 | `EGG_STATE EMPTY → HOLDING`, `ZONE none → EGG_AREA` at (5666.4, 70.7, −332.7) |
| 01:43:14–16 | #0004–#0009 | idle + run tracks, Core Spd 1.0 → 15.7; no humanoid state change |
| 01:43:17 | #0010–#0012 | run track restarts, `HUM_STATE Running → Physics` at (5389.2, 70.4, −332.8), velocity already (−449.5, +13.3, −3.5) |
| 01:43:17–18 | #0013–#0021 | ballistic rise to Y 79.7 (apex), horizontal steady 497–509 |
| 01:43:18 | #0022–#0026 | descent to ground; the two largest logging gaps of the run sit here (dt 0.248 s and 0.280 s) |
| 01:43:18–19 | #0027–#0047 | ground skid at Y 68.0–68.8, clearance 0.4–1.2 studs, Horiz 476 → 411 |
| 01:43:20 | #0048–#0050 | `ZONE EGG_AREA → TRANSIT` (scanner rule: `pos.X > 4500`), then `Physics → GettingUp → Running` |
| 01:43:20–21 | #0051–#0055 | run tracks stop; **recording ends 1 s after control returns, no COPY row** |

## Ragdoll duration (the number you asked for)

| | measured |
|---|---|
| RUN 1 | **2.46 s** (tiled from the scanner's own `dt` across rows #0011→#0049; clock 01:33:42 → 01:33:44) |
| RUN 2 | **≈ 2.4 s** (tiled 2.19 s across rows #0012→#0047 plus 0.22 s of remaining travel to the `GettingUp` point; clock 01:43:17 → 01:43:20) |
| both, split | ~0.7–1.0 s airborne + ~1.1–1.6 s skidding on the ground + <0.1 s getting up |

Note the clock resolution: 1 s timestamps mean run 2's clock span reads "3 s", but the frame-level tiling and the
kinematics (476 → 411 studs/s at −57 studs/s² = 1.14 s) both say ~2.4 s. The two runs agree.

For contrast, the **game's own transport ragdoll** in the unscripted run is sub-second
(`Physics → GettingUp` inside the same second at 11:43:10, 11:43:16, 11:43:38) and always comes with an
`ANCHOR_FLIP`. So: *sub-second ragdoll + anchor flip = transport; ≥2.4 s ragdoll, no anchor flip = boss hit.*

## What wrote the velocity: nothing after the hit

- **Airborne (run 1)**: vy `+70.9 → −69.5` = −198 then −188 studs/s². Roblox gravity is −196.2 → plain ballistics.
- **Airborne (run 2)**: vy fits come out at only −80 and −57 studs/s² (≈ ⅓ gravity), and the two biggest logging
  gaps of the whole session (0.248 s, 0.280 s) fall exactly in that window. Frames that long mean the frame rate
  collapsed during the hit burst, so those two rows are the least trustworthy in the file. Apex height is the more
  robust strength measure: **15.0 studs (run 1) vs 9.3 studs (run 2)**.
- **Ground skid (both runs)**: −57 studs/s² — matches Plastic friction μ 0.3 × 196.2 = **−58.9**. Identical in
  both runs, which is strong evidence the skid is friction-limited rather than script-driven.
- There is no constant-speed phase, no position/CFrame motion, no anchor flip, no network-owner change anywhere in
  either run. Nothing in this repo (grok-v3 waypoint chase, the auto-calc `distance/remaining` versions, the
  straight-line version in `simple_recovery_ui.lua`) writes velocity this way — so **neither run is evidence that
  your flight script ran**, in either direction. They are pure boss-knockback recordings.

## Why boss hits are the interesting case for your pipeline

1. **They happen while you are carrying** — `Egg=YES` on every row of both runs; the egg survives the hit.
2. **They land ~4 s after the pickup** in both runs, at the far end of the map (X ≈ 5.4–5.7 k), moving toward −X.
3. **They cost 2.4–2.5 s of control** — the game itself does not restore control before that. A recovery pulse
   firing at a few Hz (as `test-ragdoll-good-recovery.lua` does) would be in a position to cut that window short,
   unless the server re-asserts the ragdoll (the audit found the server window is what it is; that part is
   unproven either way).
4. **The knockback moves you 935–1,196 studs** and leaves you 1.2–1.6 k studs from the pickup point and
   3.4–3.8 k studs from the forest egg slot. That is the distance a post-hit flight has to cover:
   3.4–3.8 k studs in 1.6 s ⇒ 2,150–2,400 studs/s average. The current clamp
   (`max(1125, distance/1.6 × 1.5)`) yields 3,230–3,600 studs/s for that distance, so it clears it.
5. The boss hit is a *few hundred ms* event; a flight that re-asserts velocity every frame will simply overwrite
   the knockback. Nothing in the physics above suggests the knockback can out-write a per-frame controller.

## Still unknown / what to log next

1. **What happens in the 30–60 s after control returns.** Both recordings stop within 1–2 s of the get-up; the
   unscripted runs show `ANCHOR_FLIP` + a `Horiz=0` CFrame glide (up to ~4,400 studs/s) that returns the player to
   the forest slot (612.2, 70.7, −325.0). If the game does that after a boss hit too, it will fight your flight.
2. **`Humanoid.Health`** — damage on impact is the definitive boss-hit fingerprint and would timestamp the exact
   hit frame (the scanner currently has no health column).
3. **`Humanoid.WalkSpeed` and `MoveDirection`** — the pre-hit motion (69–103 studs/s for 4 s with no state change)
   can't be attributed without them; WalkSpeed also identifies *which* script is forcing movement.
4. **Orientation (`RootPart.CFrame.UpVector.Y`)** — the only way to actually prove/disprove rollover.
5. **Millisecond timestamps** — 1 s resolution cannot resolve a 1.6 s flight.
6. **A hit detector**: `state == Physics` + one-frame |Δv| > 400 studs/s + no anchor flip. That would fire
   `HIT` rows automatically in the next capture.

I will not modify `scanner_v3.1.lua` or `scanner-2.8.lua`; if you want these fields, they go into a new separate
scanner file.
