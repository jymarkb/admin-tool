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

**76 checks, 0 failures**, at `--minutes 180` (≈9 h simulated in total):

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
  times, including after 15 START/STOP cycles), no heap growth beyond GC noise — the unconfirmed
  run's +140 KB over 3 h is sublinear (it is +203 KB after 6 h, i.e. it does not scale with time;
  it is the 80-line log ring and its strings settling).
* CPU is 0.01 ms per simulated second when idle and ~4 ms per scan at the fastest allowed
  interval, which is well below one frame at 60 FPS.
* Remote traffic is bounded by the loop interval: one `FetchProfile` per scan, and `SellSelection`
  only when something is actually eligible. There is no polling, no heartbeat work and no timer
  per egg.
* Log box stays at 8 visible lines (`appendLog` ring of 80) for the whole run.

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

## Observations (no code changed — these are by design, listed so they are not mistaken for bugs)

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
