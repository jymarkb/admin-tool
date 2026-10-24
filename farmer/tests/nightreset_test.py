#!/usr/bin/env python3
"""
Night-reset recovery test for farmer/EggGoToUI_v11.lua.

Reported symptom: with Auto Farm running, the engine gets stuck at a night
reset and never picks another egg until OFF/ON.

The farm is a self-rescheduling chain: runNextCycle -> tpAction -> (walk /
drop / safezone) -> onComplete -> runNextCycle. Any link that never calls its
callback stops the chain forever. This harness reproduces the realistic reset
situations that can break a link and asserts the farm always resumes:

  dead         the character exists but the Humanoid is at 0 health, so every
               walk waits on a corpse until its 45 s safety timeout
  pinned       the client cannot move (spawn lock / freeze), so the safe-zone
               walk can never arrive and hits the same timeout
  respawn      the character is respawned by the game during the safe-zone
               walk (night reset = "Spawning ..."), so HumanoidRootPart is
               gone for longer than the walk's own safety timeout
  carrydeath   the reset kills the player mid-carry, during the safe-zone walk
  pickup       a night reset destroys the target egg between scan and pickup
  grace        reset fires while the farm waits out the grace period
  cycle        a full night cycle: eggs vanish, respawn 16 s later
  fishing      reset fires while Auto Fishing owns the loop
  soak         four night cycles that respawn the player and hide the eggs
  watchdog     an injected chain link that never calls back (safety net)

Every scenario ends with "did the farm pick an egg again?" - a stuck farm
answers 0.

Usage:
    python3 farmer/tests/nightreset_test.py
    python3 farmer/tests/nightreset_test.py --verbose
    python3 farmer/tests/nightreset_test.py --script /tmp/older_v11.lua   # control

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

    Stub.maxTime = cfg.budget + 300
    local env = Stub.buildEnv()

    local Instance = Stub.Instance
    local Vector3 = Stub.Vector3
    local CFrame = Stub.CFrame
    local logs = {}
    env.print = function(...)
        table.insert(logs, table.concat({ ... }, " "))
        if #logs > 300 then table.remove(logs, 1) end
    end
    env.warn = env.print

    local result = { pickups = {}, errors = {}, phases = {} }

    ------------------------------------------------------------------
    -- world
    ------------------------------------------------------------------
    local seq = 0
    local function spawnEgg(zone)
        seq = seq + 1
        local egg = Stub.addEgg("Test Species " .. (seq % 5), "Secret", zone or 2,
            Stub.Vector3.new((seq * 11) % 100, 0, (seq * 7) % 100))
        egg:SetAttribute("Zone", zone or 2)
        return egg
    end
    for _ = 1, cfg.eggs or 4 do spawnEgg() end

    local worldFrozen = false
    ------------------------------------------------------------------
    -- miniature carry server: carrying is a Tool on the character, the egg
    -- leaves the world, the drop puts it back on the ground at dropPos, and
    -- walking into the safe zone delivers it (the tool disappears).
    ------------------------------------------------------------------
    local SAFE = Vector3.new(-5963.824, -203.718, -7274.822)
    local DROP = Vector3.new(-5959.698, -203.718, -7126.994)
    local carryingTool, carryingUid = nil, nil
    result.deliveries = 0

    local function giveEgg(uid, name)
        local ch = Stub.players.LocalPlayer.Character
        if not ch then return false end
        local tool = Instance.new("Tool")
        tool.Name = tostring(name or "Egg")
        tool:SetAttribute("IsEgg", true)
        tool:SetAttribute("HalloweenEggUid", tostring(uid))
        tool.Parent = ch
        carryingTool, carryingUid = tool, tostring(uid)
        return true
    end

    local function spawnEggAt(uid, name, pos)
        local egg = Stub.addEgg(name or "Test Species", "Secret", 2, pos)
        egg:SetAttribute("Zone", 2)
        egg:SetAttribute("HalloweenEggUid", tostring(uid))
        return egg
    end

    local function serviceDelivery()
        if not carryingTool then return end
        local root = Stub.root
        local p = root and root.Position
        if not p then return end
        if Vector3.new(p.X - SAFE.X, 0, p.Z - SAFE.Z).Magnitude <= 12 then
            carryingTool.Parent = nil
            carryingTool, carryingUid = nil, nil
            result.deliveries = result.deliveries + 1
        end
    end

    local function hookCarry(name)
        local r = Stub.remotes[name]
        if not r then return end
        r.InvokeServer = function(_, arg)
            local uid = type(arg) == "table" and arg.Uid or arg
            if not uid then return true end
            if carryingUid == tostring(uid) then return true end   -- already carrying it
            for _, egg in ipairs(Stub.worldEggs:GetChildren()) do
                if egg:GetAttribute("HalloweenEggUid") == tostring(uid) then
                    local species = egg:GetAttribute("PreparedSourceName")
                    if not giveEgg(uid, species) then return false end
                    egg:SetAttribute("HalloweenEggCanPickUp", false)
                    table.insert(result.pickups, { at = Stub.now, uid = tostring(uid) })
                    egg:Destroy()
                    if not cfg.keepEggs then
                        -- the server puts a fresh egg back after a short delay,
                        -- unless the world is frozen by a night reset
                        Stub.schedule(function()
                            if not worldFrozen then spawnEgg() end
                        end, 3.0)
                    end
                    break
                end
            end
            return true
        end
    end
    hookCarry("RF/HalloweenDimension/AskCarryEgg")
    hookCarry("RF/EggWorld/AskFieldEggCarry")

    -- dropping puts the carried egg back on the ground at the drop position so
    -- the safe-zone re-pick has something to pick up
    Stub.remotes["RF/HalloweenDimension/AskDropEgg"].InvokeServer = function()
        if carryingUid then
            spawnEggAt(carryingUid, "Dropped Egg", DROP)
            carryingTool.Parent = nil
            carryingTool, carryingUid = nil, nil
        end
        return true
    end
    Stub.remotes["RF/Fishing/Cast"].InvokeServer = function()
        seq = seq + 1
        return { Id = "f" .. seq, Wait = 0.2 }
    end
    Stub.remotes["RF/Fishing/Reel"].InvokeServer = function()
        return true, { Name = "Candy Corn", Rarity = "Common", Amount = 1 }
    end

    ------------------------------------------------------------------
    -- character helpers (the game respawns you on a night reset)
    ------------------------------------------------------------------
    local player = Stub.players.LocalPlayer
    Stub.pinned = Stub.pinned or {}
    local function pinCharacter(on)
        local root = Stub.root
        if root then Stub.pinned[root] = on and true or nil end
    end
    local function killCharacter()
        player.Character = nil
        Stub.humanoid.Health = 0
    end
    local function newCharacter()
        local model = Instance.new("Model")
        model.Name = "Character"
        local hum = Instance.new("Humanoid")
        hum.Name = "Humanoid"
        hum.Health = 100
        hum.WalkSpeed = 16
        hum.Parent = model
        local root = Instance.new("Part")
        root.Name = "HumanoidRootPart"
        root.Parent = model
        root.Position = Vector3.new(-5963, -203, -7274)   -- spawn / safe zone
        model.Parent = Stub.workspace
        player.Character = model
        Stub.humanoid = hum
        Stub.root = root
        return model
    end

    ------------------------------------------------------------------
    -- load and start auto farm
    ------------------------------------------------------------------
    local chunk, err = load(SRC, "@EggGoToUI_v11.lua", "t", env)
    if not chunk then return { fatal = "load: " .. tostring(err) } end
    local ok, runErr = pcall(chunk)
    if not ok then return { fatal = "runtime: " .. tostring(runErr) } end

    local function click(name)
        local inst = Stub.registry[name]
        if inst then Stub.fire(inst, "MouseButton1Click") return true end
        return false
    end
    click("TabBtnHalloween")
    click("HwAutoFarmBtn")

    ------------------------------------------------------------------
    -- driver
    ------------------------------------------------------------------
    local runService = Stub.svc("RunService")
    local lighting = Stub.svc("Lighting")
    local countdown = Stub.remotes["RE/EggWorld/FieldEggCycleCountdown"]

    local function advance(seconds)
        local n = math.floor(seconds / 0.25 + 0.5)
        for _ = 1, n do
            Stub.tick(0.25)
            Stub.fire(runService, "Heartbeat")
            serviceDelivery()
        end
    end

    local function farmStatus()
        local lbl = Stub.registry["LblFarmStatus"]
        if lbl and type(lbl.Text) == "string" then return lbl.Text end
        -- fall back: any TextLabel whose text starts with "Status:"
        for _, inst in pairs(Stub.registry) do
            if inst.ClassName == "TextLabel" and type(inst.Text) == "string"
                and inst.Text:find("^Status:") then
                return inst.Text
            end
        end
        return nil
    end

    local function pickupsInWindow(fromAt, toAt)
        local n = 0
        for _, p in ipairs(result.pickups) do
            if p.at >= fromAt and p.at < toAt then n = n + 1 end
        end
        return n
    end

    local function snapshotStop(name)
        result.phases[#result.phases + 1] = {
            name = name,
            at = Stub.now,
            status = farmStatus(),
            pickups = #result.pickups,
        }
    end

    advance(cfg.warmup or 12)
    snapshotStop("after warmup")

    local scenario = cfg.scenario

    if scenario == "respawn" then
        -- a pickup is in flight; the reset respawns the character mid-walk
        advance(4)
        snapshotStop("before respawn")
        killCharacter()
        advance(cfg.deadFor or 50)          -- longer than the walk's 45 s timeout
        newCharacter()
        advance(2)
        snapshotStop("character back")
        result.recoveryFrom = Stub.now
        advance(cfg.settle or 90)
        result.recovered = pickupsInWindow(result.recoveryFrom, Stub.now) > 0
        result.recoveredIn = pickupsInWindow(result.recoveryFrom, Stub.now)

    elseif scenario == "pinned" then
        -- the client cannot move (spawn lock / anticheat freeze right after a
        -- reset), so the safe-zone walk can never reach its target
        advance(4)
        pinCharacter(true)
        result.posTrace = {}
        for _ = 1, 6 do
            advance(10)
            local p = Stub.root.Position
            table.insert(result.posTrace,
                string.format("t=%.0f x=%.0f z=%.0f pickups=%d", Stub.now, p.X, p.Z, #result.pickups))
        end
        snapshotStop("pinned")
        advance(cfg.pinnedFor or 60)        -- well past the walk's 45 s timeout
        pinCharacter(false)
        result.recoveryFrom = Stub.now
        snapshotStop("unpinned")
        advance(cfg.settle or 90)
        result.recovered = pickupsInWindow(result.recoveryFrom, Stub.now) > 0
        result.recoveredIn = pickupsInWindow(result.recoveryFrom, Stub.now)

    elseif scenario == "carrydeath" then
        -- the precise reported shape: the reset lands while the farm is carrying
        -- an egg (drop + safe-zone walk in flight) and the respawn kills the
        -- character, so the walk has no body to drive
        local waited = 0
        while not carryingTool and waited < 60 do
            advance(0.5)
            waited = waited + 0.5
        end
        advance(0.5)                     -- inside STEP 2/3/4
        result.wasCarrying = carryingTool ~= nil
        killCharacter()
        Stub.fire(countdown, "OnClientEvent", 1)
        result.stallFrom = Stub.now
        Stub.schedule(function() newCharacter() end, cfg.respawnAfter or 16)
        advance(cfg.deadFor or 60)
        snapshotStop("character back")
        result.recoveryFrom = Stub.now
        advance(cfg.settle or 90)
        result.afterStall = {}
        for _, p in ipairs(result.pickups) do
            if p.at > result.recoveryFrom then table.insert(result.afterStall, p.at - result.recoveryFrom) end
        end
        result.recovered = #result.afterStall > 0
        result.recoveredIn = #result.afterStall
        result.watchdogFired = false
        for _, line in ipairs(logs) do
            if line:find("watchdog", 1, true) then result.watchdogFired = true end
        end

    elseif scenario == "soak" then
        -- the reported situation, four times over: the reset respawns the player
        -- (dead, then a new character), hides the eggs for 16 s, and lands at a
        -- random point of the carry cycle because the walk takes time
        result.cycles = {}
        for cycle = 1, cfg.cycles or 4 do
            advance(cfg.cycleEvery or 300)
            worldFrozen = true
            for _, egg in ipairs(Stub.worldEggs:GetChildren()) do egg:Destroy() end
            killCharacter()
            Stub.fire(countdown, "OnClientEvent", 1)
            local resetAt = Stub.now
            Stub.schedule(function() newCharacter() end, cfg.respawnAfter or 16)
            Stub.schedule(function()
                worldFrozen = false
                for _ = 1, cfg.eggs or 4 do spawnEgg() end
            end, 16.0)
            advance(120)
            local after = 0
            for _, p in ipairs(result.pickups) do
                if p.at > resetAt then after = after + 1 end
            end
            table.insert(result.cycles, { cycle = cycle, pickups = after, status = farmStatus() })
        end
        result.afterReset = result.cycles
        result.recovered = (result.cycles[#result.cycles] or {}).pickups > 0
        result.recoveredIn = (result.cycles[#result.cycles] or {}).pickups
        result.watchdogFired = false
        for _, line in ipairs(logs) do
            if line:find("watchdog", 1, true) then result.watchdogFired = true end
        end

    elseif scenario == "watchdog" then
        -- Simulate an unknown way of stranding the chain: tpAction silently stops
        -- completing, so runNextCycle is never rescheduled.
        advance(6)
        env.__chaosStall = true          -- injected fault (see run())
        advance(20)
        env.__chaosStall = false
        result.stallFrom = Stub.now
        snapshotStop("chain stranded")
        advance(cfg.settle or 160)
        result.afterStall = {}
        for _, p in ipairs(result.pickups) do
            if p.at > result.stallFrom then table.insert(result.afterStall, p.at - result.stallFrom) end
        end
        result.recovered = #result.afterStall > 0
        result.recoveredIn = #result.afterStall
        result.watchdogFired = false
        for _, line in ipairs(logs) do
            if line:find("watchdog", 1, true) then result.watchdogFired = true end
        end

    elseif scenario == "cycle" then
        -- realistic night cycle: every egg vanishes at the reset and the server
        -- only respawns them cfg.spawnDelay seconds later
        advance(4)
        worldFrozen = true
        for _, egg in ipairs(Stub.worldEggs:GetChildren()) do egg:Destroy() end
        Stub.fire(countdown, "OnClientEvent", 1)
        result.resetAt = Stub.now
        Stub.schedule(function()
            worldFrozen = false
            for _ = 1, cfg.eggs or 4 do spawnEgg() end
        end, cfg.spawnDelay or 16)
        local trace, nextTrace = {}, result.resetAt
        while Stub.now < result.resetAt + (cfg.settle or 240) do
            advance(2)
            if Stub.now >= nextTrace then
                nextTrace = Stub.now + 10
                table.insert(trace, { t = Stub.now - result.resetAt, s = farmStatus() })
            end
        end
        result.trace = trace
        result.afterReset = {}
        for _, p in ipairs(result.pickups) do
            if p.at > result.resetAt then
                table.insert(result.afterReset, p.at - result.resetAt)
            end
        end
        result.firstPickupAfterReset = result.afterReset[1]
        result.pickupsAfterReset = #result.afterReset
        result.recovered = (result.firstPickupAfterReset or 1e9) <= (cfg.recoverWithin or 60)
        result.recoveredIn = result.pickupsAfterReset
        result.deliveriesAfterReset = result.deliveries

    elseif scenario == "dead" then
        advance(4)
        Stub.humanoid.Health = 0            -- dead but the model stays
        snapshotStop("dead")
        advance(cfg.deadFor or 60)
        Stub.humanoid.Health = 100
        result.recoveryFrom = Stub.now
        advance(cfg.settle or 90)
        result.recovered = pickupsInWindow(result.recoveryFrom, Stub.now) > 0
        result.recoveredIn = pickupsInWindow(result.recoveryFrom, Stub.now)

    elseif scenario == "pickup" then
        -- the reset wipes the world between the scan and the pickup
        advance(1)
        for _, egg in ipairs(Stub.worldEggs:GetChildren()) do egg:Destroy() end
        snapshotStop("world cleared")
        advance(8)
        for _ = 1, 3 do spawnEgg() end
        result.recoveryFrom = Stub.now
        advance(cfg.settle or 90)
        result.recovered = pickupsInWindow(result.recoveryFrom, Stub.now) > 0
        result.recoveredIn = pickupsInWindow(result.recoveryFrom, Stub.now)

    elseif scenario == "grace" then
        -- reset fires while the farm waits out the grace window
        Stub.fire(countdown, "OnClientEvent", 1)
        snapshotStop("grace started")
        advance(20)
        result.recoveryFrom = Stub.now
        advance(cfg.settle or 90)
        result.recovered = pickupsInWindow(result.recoveryFrom, Stub.now) > 0
        result.recoveredIn = pickupsInWindow(result.recoveryFrom, Stub.now)

    elseif scenario == "fishing" then
        -- no eggs at all -> the farm hands over to Auto Fishing; then a reset
        for _, egg in ipairs(Stub.worldEggs:GetChildren()) do egg:Destroy() end
        advance(20)
        snapshotStop("fishing phase")
        Stub.fire(countdown, "OnClientEvent", 1)
        advance(20)
        for _ = 1, 3 do spawnEgg() end
        result.recoveryFrom = Stub.now
        advance(cfg.settle or 90)
        result.recovered = pickupsInWindow(result.recoveryFrom, Stub.now) > 0
        result.recoveredIn = pickupsInWindow(result.recoveryFrom, Stub.now)
    end

    result.scenario = scenario
    result.finalStatus = farmStatus()
    result.totalPickups = #result.pickups
    result.deliveries = result.deliveries
    result.logs = logs
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


FAULT_HOOK = 'halloweenEngine.tpAction = function(eggData, onComplete)'


def run(lua, script_src, **cfg):
    if cfg.get("injectFault"):
        # Fault injection for the watchdog scenario: make one chain link return
        # without ever calling its callback, i.e. the exact shape of the bug the
        # watchdog exists for. The shipped script has no such branch.
        assert FAULT_HOOK in script_src
        script_src = script_src.replace(
            FAULT_HOOK,
            FAULT_HOOK + '\n    if _G.__chaosStall then return end', 1)
    stub_src = open(STUB_PATH, encoding="utf-8").read()
    stub = lua.eval("function(s) return assert(load(s, '@roblox_stub.lua'))() end")(stub_src)
    driver = lua.eval("function(s) return assert(load(s, '@nightreset_driver.lua')) end")(DRIVER)
    return lua_to_python(driver(stub, script_src, lua.table_from(cfg)))


SCENARIOS = [
    ("pinned", "client cannot move, so the safe-zone walk times out"),
    ("respawn", "character respawned mid safe-zone walk (50 s without a root)"),
    ("cycle", "eggs respawn 16 s after the reset (real night cycle)"),
    ("watchdog", "chain stranded by a link that never completes"),
    ("carrydeath", "reset kills the player mid-carry, during the safe-zone walk"),
    ("soak", "4 night cycles that respawn the player and hide the eggs"),
    ("dead", "humanoid at 0 health for 60 s"),
    ("pickup", "target egg destroyed between scan and pickup"),
    ("grace", "reset fires while the grace period is being waited out"),
    ("fishing", "reset fires while Auto Fishing owns the loop"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", default=SCRIPT_PATH)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    try:
        from lupa import LuaRuntime
    except ImportError:
        sys.exit("lupa is required: pip install lupa")

    src = open(args.script, encoding="utf-8").read()
    failures = []

    def check(label, ok, detail=""):
        print(("PASS  " if ok else "FAIL  ") + label + ((" | " + detail) if detail else ""))
        if not ok:
            failures.append(label)

    print("=== night-reset recovery ===\n")
    for name, desc in SCENARIOS:
        lua = LuaRuntime(unpack_returned_tuples=True)
        budget = 2400 if name == "soak" else 400
        r = run(lua, src, scenario=name, budget=budget, settle=90,
                injectFault=(name == "watchdog"))
        if r.get("fatal"):
            print(f"FAIL  {name} | {r['fatal']}")
            failures.append(name)
            continue
        phases = r.get("phases") or []
        status = r.get("finalStatus") or ""
        pickups = r.get("recoveredIn") or 0
        print(f"  {name:9} {desc}")
        for p in phases:
            print(f"            {p['at']:>7.1f}s  pickups={p['pickups']:<3} status={p['status']}")
        print(f"            final     pickups={r.get('totalPickups')} status={status}")
        check(f"{name}: farm keeps farming after the reset", bool(r.get("recovered")),
              f"{pickups} pickup(s) in the {90} s after recovery")
        if name == "soak":
            for c in r.get("cycles") or []:
                print(f"            cycle {c['cycle']}: {c['pickups']} pickup(s) "
                      f"after the reset, status={c['status']}")
            check("soak: no stall needed the watchdog", not r.get("watchdogFired"),
                  "watchdog had to restart the farm")
        if name == "watchdog":
            check("watchdog restarts a stranded farm chain", bool(r.get("watchdogFired")),
                  "no 'watchdog' log line")
        check(f"{name}: no runtime errors", not r.get("errors"), str(r.get("errors"))[:160])
        if args.verbose:
            for line in (r.get("logs") or [])[-12:]:
                print("             |", line)
        print()

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
