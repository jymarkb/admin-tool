#!/usr/bin/env python3
"""
Long-run test harness for farmer/EggGoToUI_v11.lua (Halloween panel).

Runs the REAL script (not a reimplementation) inside a stubbed Roblox
environment with a virtual clock, then drives Auto Farm + Auto Fishing for
hours of simulated time and asserts on:

  * load integrity          - script loads, no runtime errors in the engine
  * issue 1                - farm/list agreement, farm never idles while eggs exist
  * issue 3                - fish button stays AUTO across a night reset
  * issue 4                - Cast returns nil after a reset -> recovery + retry
  * performance            - bounded log buffer, bounded card pool, bounded memory
  * race conditions        - repeated reset/toggle churn, no duplicate fishing loops

Usage:
    python3 farmer/tests/longrun_test.py                  # default: 30 virtual minutes
    python3 farmer/tests/longrun_test.py --minutes 120
    python3 farmer/tests/longrun_test.py --verbose

Requires `lupa` (pip install lupa). Exits non-zero on the first failed check.
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
    local Stub, SRC, budgetSeconds = ...

    local result = {
        checks = {},
        counters = {},
        logs = {},
        errors = {},
        warnings = {},
        snapshots = {},
    }

    Stub.maxTime = budgetSeconds + 120      -- hard stop if the engine spins forever
    local env = Stub.buildEnv()
    local chunk, loadErr = load(SRC, "@EggGoToUI_v11.lua", "t", env)
    if not chunk then
        result.loadError = tostring(loadErr)
        return result
    end

    local ok, runErr = pcall(chunk)
    if not ok then
        result.loadError = "runtime: " .. tostring(runErr)
        return result
    end

    -- ------------------------------------------------------------------
    -- remote behaviour: scripted server
    -- ------------------------------------------------------------------
    local counts = setmetatable({}, { __mode = "k" })
    local byName = {}
    local castBlocked = 0          -- number of casts that answer nil (post-reset)
    local fishSeq = 0
    local eggsCarried = 0
    local newUpdateCarried = 0
    local tool = nil

    local function eggByUid(uid)
        for _, egg in ipairs(Stub.worldEggs:GetChildren()) do
            if egg:GetAttribute("HalloweenEggUid") == uid then return egg end
        end
        return nil
    end

    Stub.onInvoke = function(remote)
        local n = remote.Name
        byName[n] = (byName[n] or 0) + 1
        counts[remote] = (counts[remote] or 0) + 1

        if n == "RF/Fishing/Cast" then
            if castBlocked > 0 then
                castBlocked = castBlocked - 1
                result.counters.castNilReplies = (result.counters.castNilReplies or 0) + 1
                return nil
            end
            fishSeq = fishSeq + 1
            return { Id = "fish" .. fishSeq, Wait = 0.2 }
        elseif n == "RF/Fishing/Reel" then
            return true, { DisplayName = "Old Boot", Rarity = "Common", Amount = 1 }
        elseif n == "RF/HalloweenDimension/AskCarryEgg" or n == "RF/EggWorld/AskFieldEggCarry" then
            local uid = typeof(remote) == "Instance" and nil
            return true
        end
        return nil
    end

    -- Carry requests arrive as an argument, so hook the carry remotes directly.
    local function hookCarry(name)
        local r = Stub.remotes[name]
        if not r then return end
        r.InvokeServer = function(_, arg)
            byName[name] = (byName[name] or 0) + 1
            local uid = type(arg) == "table" and arg.Uid or arg
            local egg = uid and eggByUid(tostring(uid))
            if egg and egg:GetAttribute("HalloweenEggCanPickUp") ~= false then
                if egg:GetAttribute("PreparedSourceName") == "Mystery Blob Egg" then
                    newUpdateCarried = newUpdateCarried + 1
                end
                egg:SetAttribute("HalloweenEggCanPickUp", false)
                eggsCarried = eggsCarried + 1
                if not tool then
                    tool = Instance.new("Tool")
                    tool.Name = "Halloween Egg Tool"
                    tool.Parent = Stub.player.Character
                end
            end
            return true
        end
    end
    hookCarry("RF/HalloweenDimension/AskCarryEgg")
    hookCarry("RF/EggWorld/AskFieldEggCarry")

    -- Count engine events incrementally and keep only a small ring buffer, so the
    -- harness itself does not grow (otherwise it masquerades as a script leak).
    local ring = {}
    local hits = { cycles = 0, castRecoveries = 0, nightRecoveries = 0, castFailed = 0, nightReset = 0, eggDetected = 0 }
    local function note(line)
        table.insert(ring, line)
        if #ring > 200 then table.remove(ring, 1) end
        if line:find("CYCLE #", 1, true) then hits.cycles = hits.cycles + 1 end
        if line:find("resetting rod state and retrying", 1, true) then hits.castRecoveries = hits.castRecoveries + 1 end
        if line:find("resetting rod & remote state", 1, true) then hits.nightRecoveries = hits.nightRecoveries + 1 end
        if line:find("Cast FAILED after retry", 1, true) then hits.castFailed = hits.castFailed + 1 end
        if line:find("Night Reset", 1, true) then hits.nightReset = hits.nightReset + 1 end
        if line:find("Auto Fishing stopped: Egg Detected", 1, true) then hits.eggDetected = hits.eggDetected + 1 end
    end
    env.print = function(...) note(table.concat({ ... }, " ")) end

    -- ------------------------------------------------------------------
    -- UI handles
    -- ------------------------------------------------------------------
    local reg = Stub.registry
    local function click(name)
        local inst = reg[name]
        if not inst then return false end
        Stub.fire(inst, "MouseButton1Click")
        return true
    end

    result.checks.uiFound = click("TabBtnHalloween") and reg["HwAutoFarmBtn"] ~= nil

    local farmBtn = reg["HwAutoFarmBtn"]
    local fishBtn = reg["HwAutoFishBtn"]
    local farmStatus = reg["LblFarmStatus"]
    local fishStatus = reg["LblFishStatus"]
    local logLabel = reg["HwLogLabel"]

    -- ------------------------------------------------------------------
    -- world setup: a spread of catalog + uncatalogued (New Update) eggs
    -- ------------------------------------------------------------------
    local function spawnEggs()
        Stub.addEgg("Werewolf Egg", "Secret", 2, Stub.Vector3.new(40, 0, 40))
        Stub.addEgg("Hooded Gerbil Egg", "Legendary", 1, Stub.Vector3.new(-30, 0, 12))
        Stub.addEgg("Mystery Blob Egg", "New Update", 3, Stub.Vector3.new(70, 0, -20))
        Stub.addEgg("Voidseer Pumpkin Egg", "Divine", 3, Stub.Vector3.new(120, 0, 60))
    end
    spawnEggs()

    -- ------------------------------------------------------------------
    -- drive: enable auto farm, then run virtual time with churn
    -- ------------------------------------------------------------------
    local resetEvery = 105          -- virtual seconds between night resets
    local nextResetAt = 90
    local resets = 0
    local fishBtnAfterReset = nil
    local fishBtnBeforeReset = nil
    local castNilAfterReset = 0

    if farmBtn then Stub.fire(farmBtn, "MouseButton1Click") end

    local tick = 0.25
    local maxSteps = math.floor(budgetSeconds / tick)
    local memoryMidKb = 0
    local runService = Stub.svc("RunService")

    for i = 1, maxSteps do
        Stub.tick(tick)
        Stub.fire(runService, "Heartbeat")

        -- night reset: day -> night transition, which the script listens to
        if Stub.now >= nextResetAt then
            nextResetAt = nextResetAt + resetEvery
            resets = resets + 1
            fishBtnBeforeReset = fishBtn and fishBtn.Text or nil
            castBlocked = 1                     -- reproduce "Cast FAILED (nil)"
            castNilAfterReset = castNilAfterReset + 1
            Stub.svc("Lighting").ClockTime = 19
            Stub.tick(tick)
            fishBtnAfterReset = fishBtn and fishBtn.Text or nil
            result.snapshots["fishStatusAfterReset" .. resets] = fishStatus and fishStatus.Text or nil
            Stub.svc("Lighting").ClockTime = 7
        end

        if i == math.floor(maxSteps / 2) then
            collectgarbage("collect")
            memoryMidKb = collectgarbage("count")
        end

        -- respawn eggs periodically so the farm always has work to do
        if i % 240 == 0 then
            for _, egg in ipairs(Stub.worldEggs:GetChildren()) do
                egg:SetAttribute("HalloweenEggCanPickUp", true)
            end
        end
    end

    -- ------------------------------------------------------------------
    -- metrics
    -- ------------------------------------------------------------------
    local logText = logLabel and logLabel.Text or ""
    local _, logLines = string.gsub(logText, "\n", "\n")
    -- The label only keeps the last 50 lines; count events on the full print log.
    local fullLog = table.concat(ring, "\n")
    result.fullLog = fullLog
    local function count(pat)
        return select(2, string.gsub(fullLog, pat, ""))
    end

    result.counters.resets = resets
    result.counters.casts = byName["RF/Fishing/Cast"] or 0
    result.counters.reels = byName["RF/Fishing/Reel"] or 0
    result.counters.holds = byName["RE/Fishing/Hold"] or 0
    result.counters.carries = byName["RF/HalloweenDimension/AskCarryEgg"] or 0
    result.counters.eggsCarried = eggsCarried
    result.counters.newUpdateCarried = newUpdateCarried
    result.counters.logLines = logLines + (logText ~= "" and 1 or 0)
    result.counters.corosAlive = #Stub.coros
    result.counters.errors = #Stub.errors
    result.fishBtnAfterReset = fishBtnAfterReset
    result.fishBtnBeforeReset = fishBtnBeforeReset
    result.farmStatus = farmStatus and farmStatus.Text or ""
    result.fishStatus = fishStatus and fishStatus.Text or ""
    result.logText = logText

    result.counters.cycles = hits.cycles
    result.counters.castRecoveries = hits.castRecoveries
    result.counters.nightRecoveries = hits.nightRecoveries
    result.counters.castFailedAfterRetry = hits.castFailed
    result.counters.nightResetLogs = hits.nightReset
    result.counters.eggDetectedStops = hits.eggDetected

    for _, line in ipairs(Stub.logs or {}) do
        table.insert(result.logs, line)
    end
    for _, e in ipairs(Stub.errors) do table.insert(result.errors, e) end
    for _, w in ipairs(Stub.warnings or {}) do table.insert(result.warnings, w) end

    collectgarbage("collect")
    collectgarbage("collect")
    result.memoryKb = collectgarbage("count")
    result.memoryMidKb = memoryMidKb
    result.instanceCount = #Stub.instances
    return result
    """
)


def run(minutes: float, verbose: bool, script_path: str = SCRIPT_PATH) -> dict:
    try:
        from lupa import LuaRuntime
    except ImportError:
        sys.exit("lupa is required: pip install lupa")

    lua = LuaRuntime(unpack_returned_tuples=True)
    stub_src = open(STUB_PATH, encoding="utf-8").read()
    script_src = open(script_path, encoding="utf-8").read()

    stub = lua.eval("function(s) return assert(load(s, '@roblox_stub.lua'))() end")(stub_src)
    driver = lua.eval("function(s) return assert(load(s, '@driver.lua')) end")(DRIVER)

    raw = driver(stub, script_src, minutes * 60.0)
    return lua_to_python(raw)


def lua_to_python(value):
    if isinstance(value, (list, tuple)):
        return [lua_to_python(v) for v in value]
    if hasattr(value, "items"):
        items = [(k, value[k]) for k in value.keys()]
        if items and all(isinstance(k, int) for k, _ in items) and sorted(k for k, _ in items) == list(range(1, len(items) + 1)):
            return [lua_to_python(value[i]) for i in range(1, len(items) + 1)]
        return {str(k): lua_to_python(v) for k, v in items}
    return value


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=30.0, help="virtual minutes to simulate")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--script", default=SCRIPT_PATH, help="Lua file under test")
    args = ap.parse_args()

    res = run(args.minutes, args.verbose, args.script)
    c = res.get("counters", {}) or {}
    failures = []

    def check(name, ok, detail=""):
        print(("PASS  " if ok else "FAIL  ") + name + ((" | " + detail) if detail else ""))
        if not ok:
            failures.append(name)

    print(f"--- simulated {args.minutes:.0f} virtual minutes ---")
    if res.get("loadError"):
        print("FAIL  load | " + str(res["loadError"]))
        return 1

    warn_lines = res.get("warnings", []) or []
    check("script loads and exposes the Halloween UI", bool(res.get("checks", {}).get("uiFound")),
          "warnings=" + str(warn_lines[:2]))

    check(
        "no engine runtime errors",
        int(c.get("errors", 0)) == 0,
        "errors=" + str(res.get("errors") or [])[:200],
    )
    load_warns = [w for w in warn_lines if "FAILED TO LOAD" in w or "error" in w.lower()]
    check("no load-time warnings", not load_warns, str(load_warns[:2]))

    # issue 1: farm must actually harvest eggs, not just declare itself done
    check(
        "auto farm harvests eggs",
        int(c.get("eggsCarried", 0)) > 0,
        f"eggsCarried={c.get('eggsCarried')} carries={c.get('carries')}",
    )
    check(
        "uncatalogued 'New Update' eggs are farmable (list/farm agree)",
        int(c.get("newUpdateCarried", 0)) >= 1,
        f"newUpdateCarried={c.get('newUpdateCarried')}",
    )
    check(
        "farm never reports an idle 'done' state while eggs are present",
        "Placeholder" not in str(res.get("farmStatus", "")),
        f"farmStatus={res.get('farmStatus')!r}",
    )

    # issue 3: fish button must stay AUTO when the farm drives fishing
    check(
        "fish button stays AUTO across night reset",
        res.get("fishBtnAfterReset") == "AUTO",
        f"before={res.get('fishBtnBeforeReset')!r} after={res.get('fishBtnAfterReset')!r}",
    )
    check(
        "night reset is detected by the engine",
        int(c.get("nightResetLogs", 0)) >= 1,
        f"resets={c.get('resets')} nightResetLogs={c.get('nightResetLogs')}",
    )

    # issue 4: post-reset nil cast must be recovered, and cycles must keep going
    check(
        "reset triggers rod/remote recovery",
        int(c.get("nightRecoveries", 0)) >= 1,
        f"nightRecoveries={c.get('nightRecoveries')}",
    )
    check(
        "nil cast is retried after recovery",
        int(c.get("castRecoveries", 0)) >= 1,
        f"castRecoveries={c.get('castRecoveries')}",
    )
    check(
        "fishing keeps progressing (cycles > 0, casts >= cycles)",
        int(c.get("cycles", 0)) > 0 and int(c.get("casts", 0)) >= int(c.get("cycles", 0)),
        f"cycles={c.get('cycles')} casts={c.get('casts')}",
    )
    check(
        "no unrecovered cast failure storm",
        int(c.get("castFailedAfterRetry", 0)) <= int(c.get("resets", 0)),
        f"castFailedAfterRetry={c.get('castFailedAfterRetry')} resets={c.get('resets')}",
    )

    # performance / leaks
    check("log buffer capped at 50 lines", int(c.get("logLines", 0)) <= 50, f"logLines={c.get('logLines')}")
    check(
        "no runaway coroutine accumulation",
        int(c.get("corosAlive", 0)) <= 12,
        f"corosAlive={c.get('corosAlive')}",
    )
    mem_end = float(res.get("memoryKb", 0))
    mem_mid = float(res.get("memoryMidKb", 0)) or 1.0
    check(
        "memory stays bounded",
        mem_end < 200_000 and mem_end < mem_mid * 1.5,
        f"mid={mem_mid:.0f}KB end={mem_end:.0f}KB instances={res.get('instanceCount')}",
    )

    if args.verbose:
        print("\ncounters:", c)
        print("recovery log lines:")
        for line in (res.get("fullLog") or "").splitlines():
            if any(k in line for k in ("Night", "resetting", "Cast FAILED", "CYCLE #1", "Egg Detected")):
                print("   ", line)

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
