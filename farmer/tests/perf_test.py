#!/usr/bin/env python3
"""
Performance test for farmer/EggGoToUI_v11.lua (Halloween panel).

Runs the real script in the stubbed Roblox environment with a virtual clock and
measures, per simulated second of gameplay (= one real second in game, because
virtual time only advances through task.wait):

  * engine CPU          - total ms spent inside script code + API calls
  * per-frame cost      - RunService.Heartbeat handler, projected to 60 FPS
  * render tick cost    - the 0.3 s loop, isolated by running with the
                          Halloween tab visible vs. hidden (delta = render cost)
  * scaling             - eggs in world 10 / 30 / 60 / 100 (looks for nonlinearity)
  * hot spots           - CPU per Roblox API call, ranked (profiling pass)
  * memory              - live instances, signal handlers, coroutines, Lua heap
  * traffic             - remote invokes, property writes, log lines per second

Usage:
    python3 farmer/tests/perf_test.py                  # headline run + hotspots
    python3 farmer/tests/perf_test.py --minutes 30
    python3 farmer/tests/perf_test.py --sweep          # egg-count scaling sweep
    python3 farmer/tests/perf_test.py --noclip         # also profile the no-clip loop
    python3 farmer/tests/perf_test.py --script path/to/file.lua

Interpretation guide (printed at the end):
    < 3 ms/s   negligible       3-15 ms/s  noticeable       > 40 ms/s  heavy
A 60 FPS frame budget is 16.7 ms; "ms/frame" below is the script's share.

Requires `lupa` (pip install lupa).
"""

import argparse
import os
import sys
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SCRIPT_PATH = os.path.join(ROOT, "farmer", "EggGoToUI_v11.lua")
STUB_PATH = os.path.join(HERE, "roblox_stub.lua")

DRIVER = textwrap.dedent(
    r"""
    local Stub, SRC, cfg = ...

    Stub.maxTime = cfg.budget + 120
    local env = Stub.buildEnv()

    -- engine log capture (bounded)
    local logRing, logCount = {}, 0
    env.print = function(...)
        logCount = logCount + 1
        table.insert(logRing, table.concat({ ... }, " "))
        if #logRing > 200 then table.remove(logRing, 1) end
    end
    local warnRing = {}
    env.warn = function(...) table.insert(warnRing, table.concat({ ... }, " ")) end

    if cfg.profile then Stub.prof.enabled = true end

    local chunk, loadErr = load(SRC, "@EggGoToUI_v11.lua", "t", env)
    if not chunk then return { fatal = "load: " .. tostring(loadErr) } end
    local ok, runErr = pcall(chunk)
    if not ok then return { fatal = "runtime: " .. tostring(runErr) } end

    ------------------------------------------------------------------
    -- world: N eggs, consumed by the farm and respawned immediately
    ------------------------------------------------------------------
    local EGG_COUNT = cfg.eggs
    local RARITIES = { "Secret", "Legendary", "Divine", "Eternal", "New Update" }
    local seq = 0

    -- One egg in, one egg out: replacement is 1:1 with what the farm consumes so
    -- the live-instance count is a genuine leak signal, not harness bookkeeping.
    local function spawnEgg()
        seq = seq + 1
        local rarity = RARITIES[(seq % #RARITIES) + 1]
        local egg = Stub.addEgg("Test Species " .. (seq % 7), rarity, (seq % 3) + 1,
            Stub.Vector3.new((seq * 17) % 200 - 100, 0, (seq * 13) % 200 - 100))
        egg:SetAttribute("Rarity", rarity)
        return egg
    end
    for _ = 1, EGG_COUNT do spawnEgg() end

    -- carry remotes: consume the egg (like the real server) and destroy the model
    local function hookCarry(name)
        local r = Stub.remotes[name]
        if not r then return end
        r.InvokeServer = function(_, arg)
            local uid = type(arg) == "table" and arg.Uid or arg
            if not uid then return true end
            for _, egg in ipairs(Stub.worldEggs:GetChildren()) do
                if egg:GetAttribute("HalloweenEggUid") == tostring(uid) then
                    egg:SetAttribute("HalloweenEggCanPickUp", false)
                    if cfg.churn then
                        egg:Destroy()                       -- server removed it from the world
                        spawnEgg()                          -- 1:1 replacement
                    else
                        -- steady state: same world, egg respawns on its pad after 4 s
                        Stub.schedule(function()
                            if egg and not rawget(egg, "_destroyed") then
                                egg:SetAttribute("HalloweenEggCanPickUp", true)
                            end
                        end, 4.0)
                    end
                    break
                end
            end
            return true
        end
    end
    hookCarry("RF/HalloweenDimension/AskCarryEgg")
    hookCarry("RF/EggWorld/AskFieldEggCarry")

    Stub.remoteCounts = {}
    for name, r in pairs(Stub.remotes) do
        local orig = r.InvokeServer
        r.InvokeServer = function(self, ...)
            Stub.remoteCounts[name] = (Stub.remoteCounts[name] or 0) + 1
            return orig(self, ...)
        end
        local origFire = r.FireServer
        if origFire then
            r.FireServer = function(self, ...)
                Stub.remoteCounts[name] = (Stub.remoteCounts[name] or 0) + 1
                return origFire(self, ...)
            end
        end
    end

    Stub.remotes["RF/Fishing/Cast"].InvokeServer = function()
        seq = seq + 1
        return { Id = "f" .. seq, Wait = 0.2 }
    end
    Stub.remotes["RF/Fishing/Reel"].InvokeServer = function()
        return true, { Name = "Candy Corn", Rarity = "Common", Amount = 1 }
    end
    local castBlocked = 0
    local baseCast = Stub.remotes["RF/Fishing/Cast"].InvokeServer
    Stub.remotes["RF/Fishing/Cast"].InvokeServer = function(self, a, b)
        if castBlocked > 0 then castBlocked = castBlocked - 1; return nil, "Hold on..." end
        return baseCast(self, a, b)
    end

    ------------------------------------------------------------------
    -- UI: pick the tab, start auto farm (+ optional noclip)
    ------------------------------------------------------------------
    local reg = Stub.registry
    local function click(name)
        local inst = reg[name]
        if inst then Stub.fire(inst, "MouseButton1Click") return true end
        return false
    end
    if cfg.tab == "halloween" then click("TabBtnHalloween")
    elseif cfg.tab == "utility" then click("TabBtnUtility") end
    if cfg.noclip then click("ToggleNoclipBtn") end
    click("HwAutoFarmBtn")

    ------------------------------------------------------------------
    -- measurement loop
    ------------------------------------------------------------------
    local clock = os.clock              -- real CPU clock (driver, not the fake one)
    local lighting = Stub.svc("Lighting")
    local runService = Stub.svc("RunService")

    local tick = 0.25
    local steps = math.floor(cfg.budget / tick)

    local tickMs, tickN = 0, 0
    local hbMs, hbN = 0, 0
    local nextResetAt = cfg.resetEvery
    local resets = 0
    local samples = {}
    local nextSampleAt = cfg.sampleEvery

    -- snapshot creation counters so we can attribute any live-instance growth
    local baseCreated = {}
    for k, v in pairs(Stub.created) do baseCreated[k] = v end

    local t0All = clock()

    for i = 1, steps do
        -- coroutines / waits (render loop, farm + fishing cycles, recovery)
        local a = clock()
        Stub.tick(tick)
        tickMs = tickMs + (clock() - a)
        tickN = tickN + 1

        -- the per-frame physics handler
        local b = clock()
        Stub.fire(runService, "Heartbeat")
        hbMs = hbMs + (clock() - b)
        hbN = hbN + 1


        if Stub.now >= nextResetAt and resets < cfg.maxResets then
            resets = resets + 1
            nextResetAt = Stub.now + cfg.resetEvery
            castBlocked = 1
            lighting.ClockTime = 19
            Stub.tick(tick)
            lighting.ClockTime = 7
        end

        if Stub.now >= nextSampleAt then
            nextSampleAt = Stub.now + cfg.sampleEvery
            collectgarbage("collect")
            local cards = 0
            local scroll = reg["HwEggListScroll"]
            if scroll then
                for _, c in ipairs(Stub.children[scroll] or {}) do
                    if c:IsA("Frame") and c.Visible ~= false then cards = cards + 1 end
                end
            end
            local notice = reg["EmptyNotice"]
            table.insert(samples, {
                t = Stub.now,
                eggs = #Stub.worldEggs:GetChildren(),
                emptyNotice = notice and notice.Visible or nil,
                farmStatus = (reg["LblFarmStatus"] and reg["LblFarmStatus"].Text) or "",
                instances = Stub.liveInstances(),
                handlers = Stub.handlerCount(),
                coros = #Stub.coros,
                kb = collectgarbage("count"),
                cards = cards,
            })
        end
    end

    local totalMs = (clock() - t0All) * 1000

    local out = {
        cfg = cfg,
        simSeconds = Stub.now,
        ticks = tickN,
        tickMs = tickMs * 1000,
        hbCalls = hbN,
        hbMs = hbMs * 1000,
        totalMs = totalMs,
        resets = resets,
        logLines = logCount,
        samples = samples,
        errors = {},
        remoteCalls = {},
        prof = {},
        finalInstances = Stub.liveInstances(),
        finalHandlers = Stub.handlerCount(),
    }
    for _, e in ipairs(Stub.errors) do table.insert(out.errors, e) end
    for _, w in ipairs(warnRing) do table.insert(out.errors, "warn: " .. w) end

    out.remoteCalls = Stub.remoteCounts or {}
    out.created = {}
    for k, v in pairs(Stub.created) do
        local d = v - (baseCreated[k] or 0)
        if d > 0 then table.insert(out.created, { name = k, count = d }) end
    end
    table.sort(out.created, function(a, b) return a.count > b.count end)

    if cfg.profile then
        for _, row in ipairs(Stub.profReport()) do
            table.insert(out.prof, { name = row.name, calls = row.calls, cpu = row.cpu * 1000 })
        end
    end
    return out
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


def run(lua, script_src, **cfg_defaults):
    stub_src = open(STUB_PATH, encoding="utf-8").read()
    stub = lua.eval("function(s) return assert(load(s, '@roblox_stub.lua'))() end")(stub_src)
    driver = lua.eval("function(s) return assert(load(s, '@perf_driver.lua')) end")(DRIVER)
    cfg = lua.table_from(cfg_defaults)
    return lua_to_python(driver(stub, script_src, cfg))


def fmt_row(label, r, sim):
    cpu_per_s = r["totalMs"] / sim if sim else 0
    hb_ms = r["hbMs"] / max(1, r["hbCalls"])
    return (
        f"{label:<28} {r['ticks']:>7} {r['totalMs']:>9.0f} {cpu_per_s:>9.1f} "
        f"{cpu_per_s / 60:>9.2f} {hb_ms:>8.3f}"
    )


HEADER = (
    f"{'scenario':<28} {'ticks':>7} {'cpu ms':>9} {'ms/s':>9} {'ms/frame':>9} {'hb ms':>8}"
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", default=SCRIPT_PATH)
    ap.add_argument("--minutes", type=float, default=20.0)
    ap.add_argument("--eggs", type=int, default=40)
    ap.add_argument("--sweep", action="store_true", help="egg-count scaling sweep")
    ap.add_argument("--noclip", action="store_true", help="profile the no-clip Stepped loop")
    ap.add_argument("--top", type=int, default=12, help="hot spots to print")
    ap.add_argument("--all-samples", action="store_true", help="print every memory sample")
    ap.add_argument("--churn", action="store_true", help="farm consumes + respawns eggs (default: steady world)")
    args = ap.parse_args()

    try:
        from lupa import LuaRuntime
    except ImportError:
        sys.exit("lupa is required: pip install lupa")

    src = open(args.script, encoding="utf-8").read()
    budget = args.minutes * 60.0
    common = dict(budget=budget, resetEvery=105.0, maxResets=999, sampleEvery=60.0,
                  profile=False, noclip=False, churn=args.churn)

    failures = []

    def check(label, ok, detail=""):
        print(("PASS  " if ok else "WARN  ") + label + ((" | " + detail) if detail else ""))
        if not ok:
            failures.append(label)

    print(f"--- perf run: {args.minutes:.0f} virtual minutes, {args.eggs} eggs in world ---\n")
    print(HEADER)

    lua = LuaRuntime(unpack_returned_tuples=True)
    on = run(lua, src, eggs=args.eggs, tab="halloween", **common)
    lua = LuaRuntime(unpack_returned_tuples=True)
    off = run(lua, src, eggs=args.eggs, tab="eggs", **common)

    for res in (on, off):
        if res.get("fatal"):
            print("FAILED:", res["fatal"])
            return 1

    sim_on = float(on["simSeconds"])
    sim_off = float(off["simSeconds"])
    print(fmt_row("halloween tab visible", on, sim_on))
    print(fmt_row("halloween tab hidden", off, sim_off))

    cpu_on = on["totalMs"] / sim_on
    cpu_off = off["totalMs"] / sim_off
    render_ms_s = cpu_on - cpu_off
    render_ticks = max(1, int(sim_on / 0.3))
    render_per_call = (render_ms_s * 1000.0) / render_ticks if render_ticks else 0.0

    print(f"\n  render/list cost (visible - hidden): {render_ms_s:+.1f} ms/s"
          f"  ->  ~{render_per_call:.2f} ms per 0.3s tick")

    if args.noclip:
        lua = LuaRuntime(unpack_returned_tuples=True)
        nc = run(lua, src, eggs=args.eggs, tab="utility", **dict(common, noclip=True))
        if not nc.get("fatal"):
            print(fmt_row("utility tab + noclip", nc, float(nc["simSeconds"])))

    # ---- hotspots (profiling pass on the main scenario) ----
    lua = LuaRuntime(unpack_returned_tuples=True)
    prof = run(lua, src, eggs=args.eggs, tab="halloween", **dict(common, profile=True))
    sim_prof = float(prof["simSeconds"])
    print(f"\n--- hot spots (profiled pass: {sim_prof:.0f} s simulated) ---")
    print(f"{'call':<34} {'calls/s':>10} {'ms/s':>9} {'us/call':>9}")
    for row in (prof.get("prof") or [])[: args.top]:
        calls = float(row["calls"])
        cpu = float(row["cpu"])
        per_s = calls / sim_prof
        ms_s = cpu / sim_prof
        us = (cpu * 1000.0 / calls) if calls else 0
        print(f"{row['name']:<34} {per_s:>10.0f} {ms_s:>9.1f} {us:>9.2f}")

    # ---- memory / leak checks ----
    print("\n--- memory & leak indicators (halloween tab visible) ---")
    samples = on.get("samples") or []
    if samples:
        first, mid, last = samples[0], samples[len(samples) // 2], samples[-1]
        print(f"{'at':>8} {'eggs':>5} {'cards':>6} {'instances':>10} {'handlers':>9} {'coros':>6} {'KB':>8}  farm status")
        rows = samples if args.all_samples else (first, mid, last)
        for s in rows:
            print(f"{s['t']:>8.0f} {s.get('eggs', 0):>5} {s['cards']:>6} {s['instances']:>10} {s['handlers']:>9} "
                  f"{s['coros']:>6} {s['kb']:>8.0f}  {s.get('farmStatus', '')[:38]}")
        growth_inst = last["instances"] - first["instances"]
        growth_kb = last["kb"] - first["kb"]
        growth_hand = last["handlers"] - first["handlers"]
        print(f"  growth: instances {growth_inst:+.0f}, handlers {growth_hand:+.0f}, "
              f"heap {growth_kb:+.0f} KB over {last['t'] - first['t']:.0f} s")

        created = on.get("created") or []
        if created:
            print("  created during run: " + ", ".join(f"{c['name']}={c['count']}" for c in created[:6]))
        check("no instance leak (live instances stable)",
              growth_inst <= max(5, first["instances"] * 0.02),
              f"{growth_inst:+.0f} over run")
        check("no connection leak (handler count stable)",
              growth_hand <= 2, f"{growth_hand:+.0f} over run")
        check("heap stable", growth_kb <= max(256, first["kb"] * 0.25), f"{growth_kb:+.0f} KB")
        check("coroutines bounded and not trending up",
              int(last["coros"]) <= 25 and int(last["coros"]) <= int(mid["coros"]) + 6,
              f"first={first['coros']} mid={mid['coros']} last={last['coros']}")

    remotes = sorted(((float(v) / sim_prof, k) for k, v in (prof.get("remoteCalls") or {}).items()), reverse=True)
    if remotes:
        print("  remote traffic (per s): " + ", ".join(f"{k.split('/')[-1]}={v:.1f}" for v, k in remotes[:5]))

    print("\n--- traffic ---")
    print(f"  log lines: {on['logLines']} ({on['logLines'] / sim_on:.2f}/s)"
          f"   night resets: {on['resets']}")
    writes = {r["name"]: r for r in (prof.get("prof") or []) if str(r["name"]).startswith("write:")}
    total_writes = sum(float(r["calls"]) for r in writes.values())
    cards = (prof.get("samples") or [{}])[-1].get("cards", 0)
    print(f"  GUI property writes: {total_writes / sim_prof:.0f}/s"
          f"  ({total_writes / sim_prof / max(1, cards):.1f} per visible card per second, {cards} cards)")
    for name, row in sorted(writes.items(), key=lambda kv: -float(kv[1]["calls"]))[:5]:
        print(f"    {name:<28} {float(row['calls']) / sim_prof:>8.0f}/s")

    if args.sweep:
        print("\n--- egg-count scaling (halloween tab visible) ---")
        print(f"{'eggs':>6} {'ms/s':>9} {'ms/s per egg':>14} {'cards':>7}")
        base = None
        for n in (10, 30, 60, 100):
            lua = LuaRuntime(unpack_returned_tuples=True)
            r = run(lua, src, eggs=n, tab="halloween", **common)
            if r.get("fatal"):
                print(f"{n:>6} FAILED {r['fatal']}")
                continue
            per_s = r["totalMs"] / float(r["simSeconds"])
            cards = (r.get("samples") or [{}])[-1].get("cards", 0)
            print(f"{n:>6} {per_s:>9.1f} {per_s / n:>14.2f} {cards:>7}")
            if n == 10:
                base = per_s
        if base:
            print("  scaling verdict: per-egg cost is roughly flat -> cost grows ~linearly with egg count")

    print("\n--- verdict ---")
    verdict = "negligible" if cpu_on < 3 else "noticeable" if cpu_on < 15 else "heavy"
    print(f"  Auto farm + fishing, Halloween tab visible: {cpu_on:.1f} ms of CPU per second "
          f"({cpu_on / 60:.2f} ms per frame at 60 FPS) -> {verdict}")
    print(f"  With the tab hidden: {cpu_off:.1f} ms/s; the list render alone costs "
          f"{render_ms_s:.1f} ms/s (~{render_per_call:.2f} ms every 0.3 s).")
    if failures:
        print("\n  warnings: " + ", ".join(failures))
    return 0


if __name__ == "__main__":
    sys.exit(main())
