# Performance report — Halloween panel (auto farm + auto fishing)

**Script:** `farmer/EggGoToUI_v11.lua` — measured at `6e59b82` (before) and after the fixes below
**Harness:** `farmer/tests/perf_test.py` (+ `roblox_stub.lua`), real script, virtual clock, profiled Roblox API
**Question:** long-run FPS / CPU / RAM use during auto farm + auto fishing.

---

## Before / after the optimizations

All five recommended fixes are now in `EggGoToUI_v11.lua`. Same harness, same world (40 eggs,
10–20 virtual minutes):

| Metric | Before | After | Change |
|---|---|---|---|
| CPU, Halloween tab visible | 2.4 ms/s | **1.0 ms/s** | −58 % |
| List render cost (visible − hidden) | 1.7 ms/s | **0.5 ms/s** | −71 % |
| `GetAttribute` calls | 1521 /s | **664 /s** | −56 % |
| `FindFirstChild` calls | 204 /s | **126 /s** | −38 % |
| GUI property writes | 272 /s | **82 /s** | −70 % |
| CPU at 100 eggs | 5.5 ms/s | **2.4 ms/s** | −56 % |
| Live instances / handlers / heap | flat | flat | unchanged |

Behaviour is unchanged: same cards, same order, same filters — `longrun_test.py` and
`test_cast_after_reset.py` still pass.

What changed in the script:

1. **List render is event-driven** — `WorldEggs.ChildAdded/ChildRemoved` set `hwListDirty`;
   otherwise the list refreshes at 1 Hz (`hwRenderEvery`) instead of every 0.3 s tick.
2. **Only changed GUI properties are written** — name/sub-label/accent colour/visibility are
   compared against the previous value per card.
3. **Egg names are cached per model** (`halloweenEngine.nameCache`, weak keys, invalidated by
   `PreparedSourceName`) so the attribute/child/descendant resolver runs once per egg instead of
   on every render *and* every farm scan.
4. **Card pool is capped at 150** — a one-off 100-egg burst no longer pins ~700 instances.
5. **Log label refreshes are coalesced** to ~4/s instead of per log line.

Remaining after the fixes (fine, but visible if egg counts grow):
render still scales ~linearly with eggs (0.02 ms/s per egg), and distances update at 1 Hz.

---

## How to reproduce

```bash
pip install lupa
python3 farmer/tests/perf_test.py                    # 20 min, 40 eggs, steady world
python3 farmer/tests/perf_test.py --minutes 30
python3 farmer/tests/perf_test.py --eggs 0           # fishing-only (farm has nothing to do)
python3 farmer/tests/perf_test.py --sweep            # 10 / 30 / 60 / 100 eggs
python3 farmer/tests/perf_test.py --noclip           # also profile the no-clip Stepped loop
python3 farmer/tests/perf_test.py --churn            # farm consumes + respawns eggs
python3 farmer/tests/perf_test.py --all-samples      # every 60 s memory sample
```

**Read the numbers with this in mind.** The stub's `Instance`/attribute operations are ~1 µs,
while the real engine charges roughly 5–50× more for the same call (C++ boundary, property
change notification, GUI layout invalidation). So the absolute `ms/s` figures below are a
**lower bound**. The transferable facts are the **call rates** (`calls/s`), the **shape** of the
cost (linear in eggs, bursty every 0.3 s) and the **absence of growth** (leaks).

---

## Headline result

| Scenario | CPU ms / simulated second | ms per 60 FPS frame | Verdict |
|---|---|---|---|
| Halloween tab **visible** (list live), 40 eggs | **2.4** | 0.04 | negligible |
| Halloween tab **hidden**, 40 eggs | 0.7 | 0.01 | negligible |
| Fishing only, 0 eggs | 0.1 | 0.002 | negligible |
| Utility tab + **no-clip ON** | 0.5 | 0.01 | negligible |
| Per-frame `Heartbeat` handler | 0.006 ms/call → 0.36 ms/s at 60 FPS | — | negligible |

**No leak, no runaway CPU.** 30 virtual minutes of farming + fishing:

```
      at  eggs  cards  instances  handlers  coros       KB   farm status
      60    40     30        691       142     15     1948   [Divine] Test Species 3 Egg
     960    40     31        691       142      5     1995   [Divine] Test Species 2 Egg
    1800    40     31        691       142      5     2046   [Divine] Test Species 2 Egg
growth: instances +0, handlers +0, coroutines bounded, heap +98 KB over 29 min
```

- **Instances: +0** — the card pool is allocated once and reused; nothing is created per cycle.
- **Signal handlers: +0** — no connection leak (142 constant).
- **Coroutines: 5–15, no upward trend** — `task.spawn` bursts all finish.
- **Heap: +98 KB / 29 min** ≈ 3 KB/min, i.e. allocator noise from the log label, not a leak
  (collected between samples).

So the RAM complaint is not a leak in this script. What it *does* do continuously is churn GUI
properties — that is where the cost is.

---

## What actually costs money

### 1. The live list is rebuilt 3.3× per second with no change detection

`renderHalloweenEggs` is called from the 0.3 s loop whenever the Halloween tab is visible. It
re-collects every egg, re-resolves every name, re-sorts the list, and rewrites every card.

```
render/list cost (visible − hidden): +1.7 ms/s  →  ~0.9 ms per 0.3 s tick   (stub)
GUI property writes: 272/s   (Text 131/s, Visible 66/s, BackgroundColor3 61/s, TextColor3 9/s)
```

272 property writes per second, ~9 per visible card per second, **even when nothing changed**.
In the real client each of those is a property-change notification and (for `Text`/`Visible`) a
GUI layout invalidation. That is the most plausible source of the *felt* FPS dip: not sustained
CPU, but a **1–5 ms burst ~3×/s** while the tab is open.

### 2. API read traffic is high and redundant

```
GetAttribute            1521/s
FindFirstChild           204/s
IsA                      120/s
FindFirstChildOfClass    101/s
GetChildren               19/s
GetTagged                  2/s
```

`GetAttribute` at ~1.5 k/s comes from the per-egg classification running in *both* the render
and `autoFarm.findTarget`, several reads per egg per pass, with no caching.

### 3. Cost scales linearly with eggs — no cliff

| Eggs | CPU ms/s | ms/s per egg | Visible cards |
|---|---|---|---|
| 10 | 0.7 | 0.07 | 6 |
| 30 | 1.8 | 0.06 | 22 |
| 60 | 3.2 | 0.05 | 46 |
| 100 | 5.5 | 0.06 | 78 |

Flat per-egg cost → **linear**, ~0.055 ms/s per egg in the stub. At 100 eggs the render pass
does ~700 property writes in one tick. Extrapolated to real engine costs that is the difference
between "fine" and "noticeable hitch" — worth bounding before egg counts grow.

### 4. Remote traffic (expected, not a problem)

```
AskCarryEgg 2.3/s · AskDropEgg 0.4/s · AskFieldEggCarry 0.4/s · AskFieldEggSnapshot 0.2/s
```

The pickup burst is the only spiky one (`2 invokes / 35 ms` while a TP is in progress); it is
bounded by the pickup loop's own timeouts.

### 5. Fishing loop churn is small

Fishing-only run: 0.1 ms/s, **1.47 log lines/s**. Each log line rebuilds the whole 50-line label
(`table.concat` of 50 lines) and resets `CanvasPosition` — ~1.5 allocations/s of a few hundred
bytes. Harmless, but easy to reduce.

---

## Recommendations, ranked by impact per line changed

| # | Change | Expected effect |
|---|---|---|
| 1 | **Dirty flag for the list render** — rebuild only when eggs appear/disappear or a pickability/rarity attribute changes, otherwise refresh at ~1 Hz. | Removes most of the 272 writes/s and the 3×/s hitch; ~3–10× less render work. |
| 2 | **Skip unchanged property writes** — remember last `Text`/`Color`/`Visible` per card and only write on change. | ~250 of the 272 writes/s disappear when the list is stable. |
| 3 | **Cache the resolved egg name per model** (weak table, invalidated by `PreparedSourceName`). | Cuts the 1521 `GetAttribute`/s and the `SPECIES_INFO` scans that run on every render *and* every farm scan. |
| 4 | **Cap the card pool** — destroy cards unused for a while. The pool never shrinks, so one 100-egg burst pins ~800 extra instances for the session. | Bounded memory after spikes. |
| 5 | **Throttle the log label** — update at most ~4×/s (or only when the panel is visible). | Removes the per-line 50-line `concat`. |
| 6 | *(optional)* Window the list (render only visible rows) if >60 eggs becomes common. | Keeps the render pass O(visible) instead of O(total). |

None of these touch farm/fishing behaviour — they are all inside the list render and the log.

---

## Verified healthy

- No instance, handler, or coroutine growth across 30 simulated minutes (steady and churn modes).
- Memory flat after warm-up; the log buffer is capped at 50 lines; `eggCacheByUid` is bounded by
  server snapshots.
- `Heartbeat` physics handler is cheap (0.006 ms/call in the stub).
- No-clip `Stepped` loop is cheap while off; with it **on** it touches every character part every
  frame — fine at 0.5 ms/s here, but on a real client it is the one per-frame loop that scales
  with character complexity, so leave it off unless needed.
- Fishing CPU is effectively free (0.1 ms/s); only the log label allocates.

## Caveats

- Absolute ms are stub numbers (lower bound), see the note at the top.
- The stub executes the script's real control flow and timers, but it cannot model GPU cost,
  Roblox GUI layout passes, or network latency.
- A production profile would still be worth one session with the Roblox **MicroProfiler** while
  the Halloween tab is open; the numbers here predict what to look for: a repeating ~0.3 s spike
  in the render/UI category, flat otherwise.
