#!/usr/bin/env python3
"""
Combined-load test: EggGoToUI_v11 (auto farm + instant recovery + fishing)
running *together* with the standalone autosell script.

Motivation: FPS that decays over a session when autosell runs next to v11.
The v11 perf suite and the autosell suite each measure one script in isolation,
so this harness runs both in the same environment and reports frame-level cost
over time:

  tick ms/s      CPU per simulated second spent in the 0.25 s driver step
                 (coroutines: farm, fishing, recovery, autosell loop)
  hb ms/frame    CPU of the RunService.Heartbeat handler (per-frame work)
  worst tick     slowest single step - this is the frame that stutters
  >16.7 ms       steps whose script cost would blow a 60 FPS frame budget
  instances / handlers / heap   growth over the run

Usage:
    python3 farmer/tests/combined_test.py                 # v11 + autosell, 30 min
    python3 farmer/tests/combined_test.py --minutes 60 --bag 800 --interval 10
    python3 farmer/tests/combined_test.py --no-autosell   # control run

Requires `lupa` (pip install lupa).
"""

import argparse
import os
import sys
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
V11 = os.path.join(ROOT, "farmer", "EggGoToUI_v11.lua")
AUTOSELL = os.path.join(ROOT, "farmer", "autosell.lua")
STUB_PATH = os.path.join(HERE, "roblox_stub.lua")

DRIVER = textwrap.dedent(
    r"""
    local Stub, V11_SRC, SELL_SRC, cfg = ...

    Stub.maxTime = cfg.budget + 300
    local env = Stub.buildEnv()

    local result = { errors = {}, samples = {}, sells = 0, scans = 0 }

    local logRing = {}
    env.print = function(...)
        table.insert(logRing, table.concat({ ... }, " "))
        if #logRing > 200 then table.remove(logRing, 1) end
    end
    env.warn = env.print

    ------------------------------------------------------------------
    -- world: eggs that the farm consumes and the server respawns
    ------------------------------------------------------------------
    local EGG_COUNT = cfg.eggs
    local RARITIES = { "Secret", "Legendary", "Divine", "Eternal", "New Update" }
    local seq = 0
    local function spawnEgg()
        seq = seq + 1
        local r = RARITIES[(seq % #RARITIES) + 1]
        local e = Stub.addEgg("Test Species " .. (seq % 7), r, (seq % 3) + 1,
            Stub.Vector3.new((seq * 17) % 200 - 100, 0, (seq * 13) % 200 - 100))
        e:SetAttribute("Rarity", r)
        return e
    end
    for _ = 1, EGG_COUNT do spawnEgg() end

    local function hookCarry(name)
        local r = Stub.remotes[name]
        if not r then return end
        r.InvokeServer = function(_, arg)
            local uid = type(arg) == "table" and arg.Uid or arg
            if not uid then return true end
            for _, egg in ipairs(Stub.worldEggs:GetChildren()) do
                if egg:GetAttribute("HalloweenEggUid") == tostring(uid) then
                    egg:SetAttribute("HalloweenEggCanPickUp", false)
                    Stub.schedule(function()
                        if egg and not rawget(egg, "_destroyed") then
                            egg:SetAttribute("HalloweenEggCanPickUp", true)
                        end
                    end, 4.0)
                    break
                end
            end
            return true
        end
    end
    hookCarry("RF/HalloweenDimension/AskCarryEgg")
    hookCarry("RF/EggWorld/AskFieldEggCarry")

    Stub.remotes["RF/Fishing/Cast"].InvokeServer = function()
        seq = seq + 1
        return { Id = "f" .. seq, Wait = 0.2 }
    end
    Stub.remotes["RF/Fishing/Reel"].InvokeServer = function()
        return true, { Name = "Candy Corn", Rarity = "Common", Amount = 1 }
    end

    ------------------------------------------------------------------
    -- a satchel that keeps refilling: the bag stays at cfg.bag size
    ------------------------------------------------------------------
    local BAG = cfg.bag
    local bagSeq = 0
    local function buildBag()
        bagSeq = bagSeq + 1
        local inv = {}
        for i = 1, BAG do
            -- every 5th egg is unverified (hard-kept), the rest are sellable
            local rec = {
                Uid = "bag-" .. bagSeq .. "-" .. i,
                EggName = "Satchel Egg " .. (i % 40),
            }
            if i % 5 ~= 0 then rec.Rarity = (i % 4 == 0) and "Legendary" or "Mythic" end
            inv[i] = rec
        end
        return inv
    end
    -- The real profile arrives already deserialised (network layer, not the
    -- script), so a cached table is the fair measure of the script's own cost.
    local cachedBag = nil
    Stub.remotes["RF/ProfileMirror/FetchProfile"].InvokeServer = function()
        result.scans = result.scans + 1
        if cfg.staticBag then
            if not cachedBag then cachedBag = buildBag() end
            return { EggInventory = cachedBag }
        end
        return { EggInventory = buildBag() }
    end
    Stub.remotes["RE/PetSatchel/SellSelection"].FireServer = function(_, payload)
        result.sells = result.sells + 1
    end
    Stub.remotes["RF/EggWorld/AskLiveSnapshot"].InvokeServer = function()
        return { RareSpawns = {} }
    end

    ------------------------------------------------------------------
    -- load v11 and start the farm
    ------------------------------------------------------------------
    local chunk, err = load(V11_SRC, "@EggGoToUI_v11.lua", "t", env)
    if not chunk then return { fatal = "v11 load: " .. tostring(err) } end
    local ok, runErr = pcall(chunk)
    if not ok then return { fatal = "v11 runtime: " .. tostring(runErr) } end

    local reg = Stub.registry
    local function click(name)
        local inst = reg[name]
        if inst then Stub.fire(inst, "MouseButton1Click") return true end
        return false
    end
    click("TabBtnHalloween")
    click("HwAutoFarmBtn")

    ------------------------------------------------------------------
    -- optionally load autosell and start its loop
    ------------------------------------------------------------------
    local sellGui = nil
    if cfg.autosell then
        local chunk2, err2 = load(SELL_SRC, "@autosell.lua", "t", env)
        if not chunk2 then return { fatal = "autosell load: " .. tostring(err2) } end
        local ok2, runErr2 = pcall(chunk2)
        if not ok2 then return { fatal = "autosell runtime: " .. tostring(runErr2) } end
        sellGui = Stub.registry["StandaloneAutoSellEggs"]
        sellGui = Stub.registry["Main"]
        -- set the loop interval, then press START
        local function walk(node, out)
            for _, c in ipairs((Stub.children or {})[node] or {}) do
                table.insert(out, c)
                walk(c, out)
            end
            return out
        end
        local root = Stub.registry["StandaloneAutoSellEggs"]
        local all = walk(root, {})
        for _, inst in ipairs(all) do
            if inst.ClassName == "TextBox" then inst.Text = tostring(cfg.interval) end
        end
        if not cfg.idle then
            for _, inst in ipairs(all) do
                if inst.ClassName == "TextButton" and type(inst.Text) == "string"
                    and inst.Text:find("START LOOP", 1, true) then
                    Stub.fire(inst, "MouseButton1Click")
                    break
                end
            end
        end
    end

    ------------------------------------------------------------------
    -- measurement
    ------------------------------------------------------------------
    local clock = os.clock
    local runService = Stub.svc("RunService")
    local TICK = 1 / 60            -- one frame at 60 FPS
    local steps = math.floor(cfg.budget / TICK)

    local tickMs, tickN, hbMs = 0, 0, 0
    local worstTick = 0
    local overBudget = 0
    local nextSampleAt = cfg.sampleEvery

    local function sample(tickAvg, hbAvg, worst, over)
        collectgarbage("collect")
        table.insert(result.samples, {
            minute = Stub.now / 60,
            tickMsPerSec = tickAvg,
            hbMsPerFrame = hbAvg,
            worstTick = worst,
            overBudget = over,
            instances = Stub.liveInstances(),
            handlers = Stub.handlerCount(),
            coros = #Stub.coros,
            kb = collectgarbage("count"),
            scans = result.scans,
        })
        tickMs, tickN, hbMs, worstTick, overBudget = 0, 0, 0, 0, 0
    end

    for _ = 1, steps do
        local a = clock()
        Stub.tick(TICK)
        local dt = clock() - a
        tickMs = tickMs + dt
        tickN = tickN + 1
        if dt > worstTick then worstTick = dt end
        if dt > 0.0167 then overBudget = overBudget + 1 end

        local b = clock()
        Stub.fire(runService, "Heartbeat")
        hbMs = hbMs + (clock() - b)

        if Stub.now >= nextSampleAt then
            nextSampleAt = nextSampleAt + cfg.sampleEvery
            local secs = math.max(1, tickN * TICK)
            sample(tickMs / secs * 1000, hbMs / math.max(1, tickN) * 1000,
                   worstTick * 1000, overBudget)
        end
    end

    result.logs = logRing
    result.finalInstances = Stub.liveInstances()
    result.finalHandlers = Stub.handlerCount()
    for _, e in ipairs(Stub.errors) do table.insert(result.errors, e) end
    return result
    """
)


def lua_to_python(value):
    if isinstance(value, (list, tuple)):
        return [lua_to_python(v) for v in value]
    if hasattr(value, "items"):
        items = [(k, value[k]) for k in value.keys()]
        if items and all(isinstance(k, int) for k, _ in items) and sorted(k for k, _ in items) == list(range(1, len(items) + 1)):
            return [lua_to_python(value[i]) for i in range(1, len(items) + 1)]
        return {str(k): lua_to_python(v) for k, v in items}
    return value


def run(lua, v11_src, sell_src, **cfg):
    stub_src = open(STUB_PATH, encoding="utf-8").read()
    stub = lua.eval("function(s) return assert(load(s, '@roblox_stub.lua'))() end")(stub_src)
    driver = lua.eval("function(s) return assert(load(s, '@combined_driver.lua')) end")(DRIVER)
    return lua_to_python(driver(stub, v11_src, sell_src, lua.table_from(cfg)))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=30.0)
    ap.add_argument("--eggs", type=int, default=40, help="eggs in the world")
    ap.add_argument("--bag", type=int, default=300, help="eggs in the satchel")
    ap.add_argument("--interval", type=float, default=10.0, help="autosell loop interval")
    ap.add_argument("--no-autosell", action="store_true", help="control run: v11 only")
    ap.add_argument("--fresh-bag", action="store_true",
                    help="rebuild the 1000-record profile on every fetch (adds harness cost)")
    ap.add_argument("--sell", default=AUTOSELL, help="autosell script to test")
    ap.add_argument("--idle", action="store_true",
                    help="load autosell but never start its loop")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    try:
        from lupa import LuaRuntime
    except ImportError:
        sys.exit("lupa is required: pip install lupa")

    v11_src = open(V11, encoding="utf-8").read()
    sell_src = open(args.sell, encoding="utf-8").read()

    lua = LuaRuntime(unpack_returned_tuples=True)
    r = run(lua, v11_src, sell_src,
            budget=int(args.minutes * 60), sampleEvery=60,
            eggs=args.eggs, bag=args.bag, interval=args.interval,
            autosell=not args.no_autosell, staticBag=not args.fresh_bag,
            idle=args.idle)

    if r.get("fatal"):
        print("FAIL  " + str(r["fatal"]))
        return 1

    label = "v11 only" if args.no_autosell else "v11 + autosell"
    print(f"=== {label} | {args.minutes:.0f} min simulated | {args.eggs} world eggs | "
          f"{args.bag} egg satchel | {args.interval:g}s loop ===")
    print(f"  {'minute':>6} {'tick ms/s':>10} {'hb ms/frame':>12} {'worst tick ms':>14}"
          f" {'>16.7ms':>8} {'inst':>6} {'handl':>6} {'coro':>5} {'KB':>7} {'scans':>6}")
    samples = r.get("samples") or []
    for s in samples:
        print(f"  {s['minute']:>6.0f} {s['tickMsPerSec']:>10.1f} {s['hbMsPerFrame']:>12.3f}"
              f" {s['worstTick']:>14.1f} {s['overBudget']:>8.0f} {s['instances']:>6}"
              f" {s['handlers']:>6} {s['coros']:>5} {s['kb']:>7.0f} {s['scans']:>6}")

    if samples:
        first, last = samples[0], samples[-1]
        print(f"\n  growth: instances {last['instances'] - first['instances']:+d}, "
              f"handlers {last['handlers'] - first['handlers']:+d}, "
              f"coroutines {last['coros'] - first['coros']:+d}, "
              f"heap {last['kb'] - first['kb']:+.0f} KB")
        early = [s["tickMsPerSec"] for s in samples[: len(samples) // 4 or 1]]
        late = [s["tickMsPerSec"] for s in samples[-max(1, len(samples) // 4):]]
        print(f"  first quarter {sum(early) / len(early):.1f} ms/s -> "
              f"last quarter {sum(late) / len(late):.1f} ms/s "
              f"({(sum(late) / len(late)) / max(0.01, sum(early) / len(early)):.2f}x)")
        slow = [s for s in samples if s["overBudget"] > 0]
        print(f"  samples with a step over the 16.7 ms budget: {len(slow)}/{len(samples)}")

    if r.get("errors"):
        print("\n  runtime errors:")
        for e in r["errors"][:5]:
            print("   ", e)

    if args.verbose:
        print("\n  last log lines:")
        for line in (r.get("logs") or [])[-12:]:
            print("   ", line)

    return 0


if __name__ == "__main__":
    sys.exit(main())
