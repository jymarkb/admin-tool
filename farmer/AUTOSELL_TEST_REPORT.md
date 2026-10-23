# `farmer/autosell.lua` — edge-case + long-run report

Script under test: `farmer/autosell.lua` (pulled from `origin/main`, unchanged by this test pass).
Harness: `farmer/tests/autosell_test.py` (scenario driver + assertions) on top of the existing
`farmer/tests/roblox_stub.lua` virtual-clock Roblox stub.

```
python3 farmer/tests/autosell_test.py                 # 60 simulated minutes (default)
python3 farmer/tests/autosell_test.py --minutes 180   # 3 h idle + 3 h stress + 3 h unconfirmed
python3 farmer/tests/autosell_test.py --verbose
```

The real script is loaded unmodified into a stubbed Roblox environment with a virtual clock, so
hours of loop time run in tens of seconds of wall clock. Every scenario is driven through the UI
the player actually uses (buttons and text boxes found by their label text).

## Result

**83 checks, 0 failures**, at `--minutes 180` (≈9 h simulated in total):

* 3 h at the default 600 s loop interval,
* 3 h at the 3 s interval floor (20 scans/min, the worst CPU/remote case),
* 3 h with a server that accepts `SellSelection` but never removes the eggs.

## Long-run performance

| run | CPU | FetchProfile | SellSelection | instances | handlers | heap |
|---|---|---|---|---|---|---|
| 600 s interval, 3 h | **0.01 ms/s** (0.01 % of one core) | 19 (0.1/min) | 1 | 73 → 73 | 21 → 21 | +6 KB |
| 3 s interval, 3 h | **1.35 ms/s** (~4 ms per scan) | 3601 (20.0/min) | 1 | 73 → 73 | 21 → 21 | +9 KB |
| unconfirmed, 3 h | — | 3600 (20.0/min) | 240 (1.3/min) | 73 → 73 | — | +140 KB |

* No instance growth, no handler growth, no coroutine growth (exactly one loop coroutine at all
  times, including after 15 START/STOP cycles). See the leak scaling evidence below — heap growth
  flattens instead of scaling with run time.
* CPU is 0.01 ms per simulated second when idle and ~4 ms per scan at the fastest allowed
  interval, which is well below one frame at 60 FPS.
* Remote traffic is bounded by the loop interval: one `FetchProfile` per scan, and `SellSelection`
  only when something is actually eligible. There is no polling, no heartbeat work and no timer
  per egg.
* Log box stays at 8 visible lines (`appendLog` ring of 80) for the whole run.

### Is it a leak? (scaling evidence)

Same code, three durations. A real leak grows linearly with time; this does not:

| mode | 1 h | 3 h | 6 h | 10 h |
|---|---|---|---|---|
| 600 s interval, heap Δ | −1 KB | +6 KB | +15 KB | — |
| 3 s interval, heap Δ | +3 KB | +9 KB | +19 KB | — |
| unconfirmed, heap Δ | +56 KB | +140 KB | +203 KB | — |
| unconfirmed, harness recording disabled, heap Δ | +40 KB | +88 KB | +97 KB | **+109 KB** |

The last row is the honest measurement: with the test harness no longer storing 480–800 payload
records, growth is +40 KB in hour 1 and +109 KB after 10 hours — it plateaus (roughly +2 KB/h at the
end), while instances, handlers and coroutines stay perfectly flat. The residual is the script's
80-line log ring and the string intern table filling up, not per-scan accumulation.

### Cost of one scan (bag size)

Each scan walks the whole profile exactly once. Measured (1000-record profiles, no fetch copies):

| eggs in bag | CPU per scan | CPU per egg |
|---|---|---|
| 100 | 33 ms | 0.30 ms |
| 200 | 60 ms | 0.30 ms |
| 300 | 89 ms | 0.30 ms |
| 1000 | 293 ms | 0.28 ms |
| 2000 | 557 ms | 0.28 ms |

So the cost is linear and predictable, with no super-linear term. At the default 600 s interval a
1000-egg bag costs 293 ms every 10 minutes (~0.05 % of one core). At the 3 s interval floor the same
bag costs ~293 ms out of every 3000 ms (~9 %) and the scan itself does not yield, so it is a single
~293 ms hitch per scan — the only place where bag size is visible. A bag of ~200 eggs (well above
average) costs ~60 ms per scan.

## Edge cases covered

**Safety — what may be sold** (`uid` must be present, non-empty and not `^unresolved_`; rarity must
be *verified*; name must not be a hard-keep name):

* kept: at/above the threshold (Secret, Divine), no rarity at all, conflicting rarity sources
  (`Rarity` vs `RarityId`), unrecognised rarity value (`SuperDuperRare`), plain/base names
  (`Egg`, `egg`, `EGG (12,345Kg)`, `Unknown Egg`), unknown species names, records without a uid,
  `unresolved_*` uids, eggs placed in the base (table `Placement`, `IsPlaced = true`, `Placed = 1`).
* sold: verified rarities below the threshold, including rarity only present in an `Attributes`
  sub-table, rarity only from an exact game-config module name, an empty `Placement = {}` table
  (correctly treated as *not* placed), an inventory-key uid, and duplicates (first record wins,
  uid sent once per payload).
* a config-only rarity is **not** sold when the `Data/Assets/Configs` folder is absent
  (fail closed), and a near-miss config name (`Penguin Egg EX`) never matches.
* an egg whose rarity only arrives through `RE/EggWorld/FieldEggRaritiesShown` becomes sellable,
  but a plain `Egg` with an event rarity still is not.

**Dedupe / confirmation:** with a profile that never confirms, no uid is re-sent before the 45 s
pending timeout and retries do happen after it; when the profile does drop sold eggs, each uid is
sold exactly once and the loop goes quiet instead of repeating.

**Threshold:** default is `Secret`; the dropdown lists every rarity, closes on pick, the preview
updates immediately, and at `Common` nothing is eligible (strict `<`).

**Failure handling:** `FetchProfile` returning `nil`, a string, a table without `EggInventory`, or
throwing outright all produce a log line, no sells, no crash, and the loop recovers on its own once
the profile is healthy. Retry delays follow `3, 6, 12, 24, 48, 60, 60 …` seconds and never exceed
60 s. A throwing `SellSelection` logs `SELL ERROR`, leaves no stuck pending uid, and retries.
`START` refuses to run (and does not enter the RUNNING state) when `SellSelection` is missing or is
not a `RemoteEvent`.

**Churn / cleanup / input:** 15 fast START/STOP cycles leave one loop and no duplicate sells; the
interval box clamps `0 → 3`, `999999 → 3600`, `-5 → 3` and keeps the previous value for garbage;
`X` destroys the GUI, clears `_G.StandaloneAutoSell_Cleanup`, drains the loop coroutine and stops
all remote traffic (0 calls in the following 30 s).

## FPS under combined load (v11 + autosell) — fixed

Reported symptom: with v11 (instant recovery, fast pickup, auto farm, auto fishing) plus autosell,
FPS decayed below 20. Reproduced with `farmer/tests/combined_test.py`, which runs both scripts in
one environment with a 60 FPS frame clock and reports the worst frame, the number of frames over the
16.7 ms budget, and CPU per simulated second.

Root cause: a scan resolved every satchel record in one synchronous pass, ~0.29 ms per egg. The bag
grows while you farm, so the stall grows with it — 29 ms at 100 eggs, 290 ms at 1000 — and at a
short loop interval it lands on a frame every few seconds. It is a spike, not a leak (heap,
instances and handlers were flat over 30 min), which is why it reads as "FPS drops over time" as the
satchel fills.

Fix (3 changes in `farmer/autosell.lua`, no behaviour change):

1. **Sliced scan.** The record loop now yields every ~2 ms (`task.wait()` after 8+ records, hard cap
   16 records), so no frame carries more than ~5 ms of scan work. A 1000-egg scan still costs the
   same ~290 ms of total CPU but is spread over ~60 frames instead of blocking one. Closing the
   window mid-scan aborts it quietly.
2. **Hard-keep name resolved once.** The plain-"Egg" name matcher ran again for every egg in the
   eligibility pass; it now runs inside the (sliced) scan and the result is stored on the record.
3. **Eligibility computed once per scan.** `applyScan`, `updatePreview` and the loop each asked for
   the sellable list; it is now memoised on (bag table, threshold), so a scan computes it once.
   `reconcilePendingSellUids` also skips its pass when nothing is pending.

Before/after, 1000-egg satchel, v11 farming at 60 FPS:

| case | worst frame | frames over 16.7 ms per min | CPU |
|---|---|---|---|
| before, 10 s loop | **289–318 ms** | 6–7 | 31 ms/s |
| before, 3 s loop | **280 ms** | 20–21 | 95 ms/s |
| after, 10 s loop | **8–9 ms** | **0** | 25–30 ms/s |
| after, 3 s loop | **8–11 ms** | **0** | 69 ms/s |

30-minute run at the 3 s floor with 1000 eggs: worst frame 15 ms, **0 frames over budget in 29
samples**, CPU 68.7 ms/s in the first quarter vs 70.6 ms/s in the last (1.03x, i.e. flat), instances
734 → 734, handlers 170 → 170. v11 alone is unchanged at 1.0 ms/s and 2 ms worst frame.

```
python3 farmer/tests/combined_test.py --minutes 30 --bag 1000 --interval 3
python3 farmer/tests/combined_test.py --no-autosell          # control
python3 farmer/tests/combined_test.py --idle                 # autosell loaded, loop stopped
```

## Observations (still by design — listed so they are not mistaken for bugs)

1. **Retry wait is `max(interval, backoff)`.** With the default 600 s interval a failing scan is
   retried every 600 s, not after 3 s: the 3/6/12/…/60 s ladder only becomes the binding delay when
   the interval is short. Good for remote load, but an outage of a few seconds costs up to 10 min
   of selling.
2. **Pending uids expire after 45 s regardless of the interval.** If the server accepts a sale but
   never removes the eggs, the same batch is re-sent about every 45 s (240 payloads in 3 h,
   1.3/min). Bounded and intentional, but it is the only recurring traffic in the script; a longer
   timeout would reduce it further.
3. **A purely numeric string inventory key is accepted as a uid** (`["7"] = {…}` sells as uid
   `"7"`). Only relevant if the profile ever ships array-style inventories with string keys; it
   cannot sell a real egg that the server still owns, but it would be gratuitous traffic. A
   `not uid:match("^%d+$")` guard would close it if that shape is ever seen.
