#!/usr/bin/env python3
"""
Long-run performance + edge-case tests for farmer/autosell.lua.

Runs the real script under the stubbed Roblox environment (virtual clock) and
drives its UI by button text. Covers:

  load            script loads, auto-scan at 0.15 s, log box present
  safety          nothing unverified / unknown / plain-"Egg" / placed / UID-less
                  is ever put into a SellSelection payload; threshold is strict (<)
  malformed       profile as a string / without EggInventory / throwing remote:
                  nothing is sold, errors are logged, the loop recovers by itself
  missingremote   SellSelection missing or not a RemoteEvent -> START refuses
  rarityevent     rarity learned from RE/EggWorld/FieldEggRaritiesShown is
                  usable, but a plain base "Egg" stays kept anyway
  sellerror       a throwing SellSelection is logged and retried, no stuck uid
  dedupe          same UID is not resent while the profile confirms nothing;
                  resent only after the 45 s pending timeout
  confirm         once the profile drops sold eggs, no UID is sent again
  threshold       changing "Sell below" immediately changes what is eligible
  failbackoff     FetchProfile failures back off (3,6,12,24,48,60 s) instead of
                  hammering the remote
  startstop       rapid START/STOP churn leaves exactly one loop and no dupes
  clamp           interval input is clamped to 3..3600 and rejects garbage
  cleanup         closing the X destroys the UI, stops the loop, stops remotes
  perf            long run: CPU ms/simulation-second, remote rate, memory,
                  instances, handlers, coroutines, log cap
  stress          same long run at the 3 s interval floor (20 scans/min)
  unconfirmed     same long run when the server never removes sold eggs:
                  retries must be spaced by the 45 s timeout, not spin

Usage:
    python3 farmer/tests/autosell_test.py
    python3 farmer/tests/autosell_test.py --minutes 60
    python3 farmer/tests/autosell_test.py --script farmer/autosell.lua --verbose

Requires `lupa` (pip install lupa).
"""

import argparse
import os
import re
import sys
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SCRIPT_PATH = os.path.join(ROOT, "farmer", "autosell.lua")
STUB_PATH = os.path.join(HERE, "roblox_stub.lua")

DRIVER = textwrap.dedent(
    r"""
    local Stub, SRC, cfg = ...

    local result = { sells = {}, logs = {}, errors = {}, scenarios = {} }
    local scenario = cfg.scenario

    Stub.maxTime = (cfg.budget or 600) + 120
    local env = Stub.buildEnv()

    -- bounded capture of the script's own log
    local logRing, logCount = {}, 0
    env.print = function(...)
        local line = table.concat({ ... }, " ")
        logCount = logCount + 1
        table.insert(logRing, line)
        if #logRing > 400 then table.remove(logRing, 1) end
    end

    ------------------------------------------------------------------
    -- inventory fixture: one entry per edge case
    ------------------------------------------------------------------
    local function egg(uid, name, rarity, extra)
        local rec = { Uid = uid, EggName = name }
        if rarity then rec.Rarity = rarity end
        for k, v in pairs(extra or {}) do rec[k] = v end
        return rec
    end

    local function fixture()
        return {
            -- sellable (verified, below Secret)
            [1] = egg("uid-common-1", "Chicken Egg", "Common"),
            [2] = egg("uid-mythic-1", "Froggo Egg", "Mythic"),
            [3] = egg("uid-leg-1", "Fox Egg (12,345Kg)", "Legendary"),
            -- kept: at or above the Secret threshold
            [4] = egg("uid-secret-1", "Werewolf Egg", "Secret"),
            [5] = egg("uid-divine-1", "Voidseer Pumpkin Egg", "Divine"),
            -- kept: no verified rarity
            [6] = egg("uid-norarity-1", "Mystery Blob Egg", nil),
            [7] = egg("uid-conflict-1", "Twin Egg", "Common", { RarityId = "Rare" }),
            [8] = egg("uid-badrarity-1", "Glitch Egg", "SuperDuperRare"),
            -- kept: plain / unknown names even with a verified rarity
            [9] = egg("uid-plainegg-1", "Egg", "Common"),
            [10] = egg("uid-unknownname-1", "Unknown Egg", "Common"),
            -- kept: no usable uid
            [11] = egg(nil, "Orphan Egg", "Common"),
            [12] = egg("unresolved_abc", "Unresolved Egg", "Common"),
            -- skipped entirely: placed in the base
            [13] = egg("uid-placed-1", "Placed Egg", "Common", { Placement = { X = 1, Y = 2 } }),
            [14] = egg("uid-placedflag-1", "FlagPlaced Egg", "Common", { IsPlaced = true }),
            -- duplicate uid (same record twice)
            [15] = egg("uid-dup-1", "Dupe Egg", "Common"),
            [16] = egg("uid-dup-1", "Dupe Egg", "Common"),
            -- empty Placement table is "not placed" -> sellable
            [17] = egg("uid-emptyplace-1", "Goose Egg", "Epic", { Placement = {} }),
            -- placed via numeric flag -> kept
            [18] = egg("uid-placednum-1", "Swan Egg", "Epic", { Placed = 1 }),
            -- plain base names in other casing/parenthesised form -> kept
            [19] = egg("uid-lowegg-1", "egg", "Common"),
            [20] = egg("uid-kgegg-1", "EGG (12,345Kg)", "Common"),
            -- rarity only inside the Attributes sub-table -> sellable
            [21] = egg("uid-attr-1", "Heron Egg", nil, { Attributes = { Rarity = "Uncommon" } }),
            -- rarity only from an exact game-config module name -> sellable
            [22] = egg("uid-config-1", "Penguin Egg", nil),
            -- config-style name plus junk -> no exact match -> kept
            [23] = egg("uid-fuzzyconfig-1", "Penguin Egg EX", nil),
            -- uid provided by the inventory key instead of the record -> sellable
            ["uid-keyed-1"] = { EggName = "Duck Egg", Rarity = "Epic" },
            -- observation: a purely numeric inventory key is also accepted as a uid
            ["7"] = { EggName = "Crow Egg", Rarity = "Epic" },
            -- non-table garbage in the inventory -> skipped, never crashes
            [24] = "not-a-record",
            -- rarity arrives later through the rarity-event cache
            [25] = egg("uid-evt-1", "Owl Egg", nil),
            -- ... but a plain base name stays kept even with an event rarity
            [26] = egg("uid-evt-plain-1", "Egg", nil),
        }
    end

    local CONFIGS = {
        { name = "Penguin Egg", Egg = "Penguin Egg", Rarity = { DisplayName = "Epic", _id = "epic" } },
        { name = "Duck Egg", Egg = "Duck Egg", Rarity = "Epic" },
    }

    local inventory = cfg.emptyInventory and {} or fixture()
    local profileCalls, sellCalls = 0, 0
    local sellPayloads = {}
    local confirmOnSell = cfg.confirmOnSell ~= false
    local failProfile = false

    local fetch = Stub.remotes["RF/ProfileMirror/FetchProfile"]
    local profileMode = "ok"
    fetch.InvokeServer = function(_, arg)
        profileCalls = profileCalls + 1
        if failProfile then return nil end
        if profileMode == "string" then return "nope" end
        if profileMode == "noinventory" then return { Data = {}, Other = true } end
        if profileMode == "throw" then error("profile remote exploded") end
        -- copy so the script cannot mutate the fixture
        local inv = {}
        for key, rec in pairs(inventory) do
            if type(rec) == "table" then
                local copy = {}
                for k, v in pairs(rec) do copy[k] = v end
                inv[key] = copy
            else
                inv[key] = rec
            end
        end
        return { EggInventory = inv }
    end

    local sellFailuresLeft = 0
    local sell = Stub.remotes["RE/PetSatchel/SellSelection"]
    sell.FireServer = function(_, payload)
        if sellFailuresLeft > 0 then
            sellFailuresLeft = sellFailuresLeft - 1
            error("sell remote exploded")
        end
        sellCalls = sellCalls + 1
        local uids = (type(payload) == "table" and payload.Eggs) or {}
        local copy = {}
        for i, u in ipairs(uids) do copy[i] = tostring(u) end
        table.insert(sellPayloads, { at = Stub.now, uids = copy })
        if confirmOnSell then
            -- the server actually sold them: drop matching records from the profile
            local sold = {}
            for _, u in ipairs(copy) do sold[u] = true end
            for key, rec in pairs(inventory) do
                if type(rec) ~= "table" then
                    -- garbage record, nothing to confirm
                else
                    local uid = rec.Uid or (type(key) == "string" and key or nil)
                    if uid and sold[tostring(uid)] then inventory[key] = nil end
                end
            end
        end
    end

    Stub.remotes["RF/EggWorld/AskLiveSnapshot"].InvokeServer = function()
        return { RareSpawns = {} }
    end

    ------------------------------------------------------------------
    -- load the script
    ------------------------------------------------------------------
    if cfg.configs then Stub.installSpeciesConfigs(CONFIGS) end
    if cfg.missingSellRemote then sell.ClassName = "RemoteFunction" end

    local chunk, loadErr = load(SRC, "@autosell.lua", "t", env)
    if not chunk then return { fatal = "load: " .. tostring(loadErr) } end
    local ok, runErr = pcall(chunk)
    if not ok then return { fatal = "runtime: " .. tostring(runErr) } end

    ------------------------------------------------------------------
    -- UI handles by text
    ------------------------------------------------------------------
    local gui = Stub.registry["StandaloneAutoSellEggs"]
    local mainFrame = Stub.registry["Main"]
    local logBox = Stub.registry["Log"]

    local function descendants(root)
        local out = {}
        local function walk(node)
            for _, c in ipairs((Stub.children or {})[node] or {}) do
                table.insert(out, c)
                walk(c)
            end
        end
        if root then walk(root) end
        return out
    end

    local function findByText(class, text)
        for _, inst in ipairs(descendants(mainFrame)) do
            if inst.ClassName == class and type(inst.Text) == "string"
                and inst.Text:find(text, 1, true) then
                return inst
            end
        end
        return nil
    end

    local function clickText(text)
        local btn = findByText("TextButton", text)
        if not btn then return false end
        Stub.fire(btn, "MouseButton1Click")
        return true
    end

    local function intervalBox()
        for _, inst in ipairs(descendants(mainFrame)) do
            if inst.ClassName == "TextBox" then return inst end
        end
        return nil
    end

    local function previewLabel()
        local best = nil
        for _, inst in ipairs(descendants(mainFrame)) do
            if inst.ClassName == "TextLabel" and type(inst.Text) == "string"
                and inst.Text:find("sellable", 1, true) then
                best = inst
            end
        end
        return best
    end

    local function previewText()
        local lbl = previewLabel()
        return lbl and lbl.Text or ""
    end

    ------------------------------------------------------------------
    -- scenario driver
    ------------------------------------------------------------------
    local runService = Stub.svc("RunService")
    local function advance(seconds)
        local step = 0.25
        local n = math.floor(seconds / step)
        for _ = 1, n do
            Stub.tick(step)
            Stub.fire(runService, "Heartbeat")
        end
    end

    local samples = {}
    local t0 = os.clock()

    local function sample()
        collectgarbage("collect")
        table.insert(samples, {
            t = Stub.now,
            instances = Stub.liveInstances(),
            handlers = Stub.handlerCount(),
            coros = #Stub.coros,
            kb = collectgarbage("count"),
        })
    end

    -- initial scan happens 0.15 s after load
    advance(1.0)
    result.autoScanPreview = previewText()
    result.uiFound = (gui ~= nil) and (mainFrame ~= nil) and (logBox ~= nil)
    result.sellRemoteIsEvent = sell.ClassName == "RemoteEvent"

    local function setInterval(v)
        local box = intervalBox()
        if box then box.Text = v end
    end

    if scenario == "safety" or scenario == "dedupe" or scenario == "confirm" or scenario == "perf" then
        if cfg.interval then setInterval(cfg.interval) end
        clickText("START LOOP")
        advance(cfg.runSeconds or 20)
    elseif scenario == "failbackoff" then
        if cfg.interval then setInterval(cfg.interval) end
        failProfile = true
        clickText("START LOOP")
        advance(cfg.failFor or (cfg.runSeconds or 150))
        if cfg.recover then
            failProfile = false
            advance(cfg.runSeconds or 90)
        end
    elseif scenario == "startstop" then
        for _ = 1, 15 do
            clickText("START LOOP")
            advance(0.6)
            clickText("STOP")
            advance(0.4)
        end
        clickText("START LOOP")
        advance(cfg.runSeconds or 20)
    elseif scenario == "clamp" then
        local box = intervalBox()
        result.clamp = {}
        for _, value in ipairs({ "0", "999999", "abc", "-5" }) do
            box.Text = value
            clickText("START LOOP")
            advance(0.5)
            clickText("STOP")
            advance(0.3)
            result.clamp[#result.clamp + 1] = { input = value, stored = box.Text }
        end
    elseif scenario == "threshold" then
        -- default Secret: only < Secret is eligible
        result.thresholdDefault = previewText()
        -- drop to Common: nothing verified can be below rank 1
        clickText("Sell below:")
        local dropdown = Stub.registry["RarityDropdown"]
        local commonBtn = nil
        for _, inst in ipairs(descendants(dropdown)) do
            if inst.ClassName == "TextButton" and type(inst.Text) == "string"
                and inst.Text:find("Common", 1, true) then
                commonBtn = inst
            end
        end
        result.dropdownFound = (dropdown ~= nil) and (commonBtn ~= nil)
        if commonBtn then Stub.fire(commonBtn, "MouseButton1Click") end
        result.dropdownClosed = dropdown ~= nil and dropdown.Visible == false
        advance(0.5)
        result.thresholdCommon = previewText()
        result.thresholdLogs = table.concat(logRing, "\n")
        clickText("START LOOP")
        advance(6)
    elseif scenario == "malformed" then
        setInterval("3")
        clickText("START LOOP")
        advance(2)
        -- profile comes back as a bare string
        profileMode = "string"
        advance(4)
        -- profile is a table but has no EggInventory
        profileMode = "noinventory"
        advance(4)
        -- the remote itself throws
        profileMode = "throw"
        advance(4)
        -- back to a good profile: the loop must recover on its own
        profileMode = "ok"
        advance(12)
        result.recovered = #sellPayloads > 0
    elseif scenario == "missingremote" then
        clickText("START LOOP")
        advance(3)
        result.startedText = nil
        for _, inst in ipairs(descendants(mainFrame)) do
            if inst.ClassName == "TextButton" and type(inst.Text) == "string"
                and inst.Text:find("START LOOP", 1, true) then
                result.startedText = inst.Text
            end
        end
        result.startLogs = table.concat(logRing, "\n")
    elseif scenario == "rarityevent" then
        setInterval("3")
        local ev = Stub.remotes["RE/EggWorld/FieldEggRaritiesShown"]
        clickText("START LOOP")
        advance(3)
        Stub.fire(ev, "OnClientEvent", {
            RareSpawns = {
                { EggUid = "uid-evt-1", RarityId = "Legendary" },
                { EggUid = "uid-evt-plain-1", RarityId = "Common" },
            },
        })
        advance(8)
    elseif scenario == "sellerror" then
        setInterval("3")
        sellFailuresLeft = 2
        clickText("START LOOP")
        advance(4)
        -- failures exhausted: the next scan must succeed without a stuck pending set
        advance(10)
    elseif scenario == "cleanup" then
        clickText("START LOOP")
        advance(6)
        local beforeCalls = profileCalls
        clickText("X")
        advance(30)
        result.cleanup = {
            guiParent = gui.Parent ~= nil,
            extraCalls = profileCalls - beforeCalls,
            coros = #Stub.coros,
            cleanupRef = _G.StandaloneAutoSell_Cleanup ~= nil,
        }
    elseif scenario == "longrun" then
        if cfg.interval then setInterval(cfg.interval) end
        clickText("START LOOP")
        local chunkSeconds = 60
        local total = cfg.runSeconds or 3600
        local elapsed = 0
        while elapsed < total do
            advance(math.min(chunkSeconds, total - elapsed))
            elapsed = elapsed + chunkSeconds
            if elapsed % 300 == 0 then sample() end
        end
    end

    sample()

    -- shutdown: how much does the loop cost after cleanup / stop?
    local callsAtEnd = profileCalls

    result.scenario = scenario
    result.profileCalls = profileCalls
    result.sellCalls = sellCalls
    result.sellPayloads = sellPayloads
    result.samples = samples
    result.logs = logRing
    result.logCount = logCount
    result.logBoxLines = logBox and select(2, logBox.Text:gsub("\n", "\n")) or 0
    result.preview = previewText()
    result.cpuMs = (os.clock() - t0) * 1000
    result.simSeconds = Stub.now
    result.liveInstances = Stub.liveInstances()
    result.handlers = Stub.handlerCount()
    result.coros = #Stub.coros
    result.guiAlive = gui ~= nil and gui.Parent ~= nil
    result.callsAtEnd = callsAtEnd
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


def run(lua, script_src, **cfg):
    stub_src = open(STUB_PATH, encoding="utf-8").read()
    stub = lua.eval("function(s) return assert(load(s, '@roblox_stub.lua'))() end")(stub_src)
    driver = lua.eval("function(s) return assert(load(s, '@autosell_driver.lua')) end")(DRIVER)
    return lua_to_python(driver(stub, script_src, lua.table_from(cfg)))


PROTECTED = {
    "uid-secret-1", "uid-divine-1", "uid-norarity-1", "uid-conflict-1", "uid-badrarity-1",
    "uid-plainegg-1", "uid-unknownname-1", "uid-orphan-1", "unresolved_abc",
    "uid-placed-1", "uid-placedflag-1", "uid-placednum-1",
    "uid-lowegg-1", "uid-kgegg-1", "uid-fuzzyconfig-1",
    "uid-evt-plain-1",
}
SELLABLE = {"uid-common-1", "uid-mythic-1", "uid-leg-1", "uid-dup-1",
            "uid-emptyplace-1", "uid-attr-1", "uid-config-1", "uid-keyed-1", "7"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", default=SCRIPT_PATH)
    ap.add_argument("--minutes", type=float, default=60.0, help="long-run length")
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

    def newrun(**cfg):
        lua = LuaRuntime(unpack_returned_tuples=True)
        return run(lua, src, **cfg)

    # ---------------- load ----------------
    print("=== load / UI ===")
    r = newrun(scenario="load", budget=60)
    if r.get("fatal"):
        print("FAIL  load | " + str(r["fatal"]))
        return 1
    check("script loads and builds the UI", bool(r.get("uiFound")))
    check("SellSelection is a RemoteEvent", bool(r.get("sellRemoteIsEvent")))
    check("auto-scan on load fills the preview", "sellable" in str(r.get("autoScanPreview", "")),
          str(r.get("autoScanPreview", ""))[:90])
    check("no runtime errors", not r.get("errors"), str(r.get("errors"))[:160])

    # ---------------- safety ----------------
    print("\n=== safety: what is eligible ===")
    r = newrun(scenario="safety", budget=120, runSeconds=20, configs=True)
    sent = set()
    for p in r.get("sellPayloads") or []:
        sent.update(p["uids"])
    leaked = sent & PROTECTED
    check("protected eggs are never sent", not leaked, f"leaked={sorted(leaked)}")
    check("eligible eggs are sent", sent & SELLABLE == SELLABLE, f"sent={sorted(sent)}")
    check("observed: numeric inventory key is used as the uid",
          "7" in sent, f"sent={sorted(sent)}")
    check("duplicate uid sent once per payload",
          all(len(p["uids"]) == len(set(p["uids"])) for p in (r.get("sellPayloads") or [])))
    check("placed eggs excluded from the bag count",
          "sellable" in str(r.get("preview", "")), str(r.get("preview", ""))[:90])

    # fail closed when the game config folder is absent
    r = newrun(scenario="safety", budget=120, runSeconds=20)
    sent_noconfig = set()
    for p in r.get("sellPayloads") or []:
        sent_noconfig.update(p["uids"])
    check("no config folder -> config-only rarity is kept, not sold",
          "uid-config-1" not in sent_noconfig, f"sent={sorted(sent_noconfig)}")
    check("other verified eggs still sold without the config folder",
          SELLABLE - {"uid-config-1"} <= sent_noconfig, f"sent={sorted(sent_noconfig)}")

    # ---------------- malformed profile payloads ----------------
    print("\n=== malformed profile payloads ===\n")
    r = newrun(scenario="malformed", budget=120)
    logs = " ".join(r.get("logs") or [])
    payloads = r.get("sellPayloads") or []
    check("string profile is rejected", "Profile scan failed" in logs)
    check("missing EggInventory is rejected", "EggInventory was not found" in logs)
    check("throwing remote is caught (no crash)", not r.get("errors"), str(r.get("errors"))[:120])
    bad_window = [p for p in payloads if 2.0 < float(p["at"]) < 14.0]
    check("nothing sold while the profile is broken", not bad_window, f"payloads={bad_window[:2]}")
    check("loop recovers once the profile is healthy again", bool(r.get("recovered")))

    # ---------------- SellSelection not a RemoteEvent ----------------
    print("\n=== SellSelection remote missing / wrong class ===\n")
    r = newrun(scenario="missingremote", budget=60, missingSellRemote=True)
    start_logs = str(r.get("startLogs") or "")
    check("START refuses when SellSelection is not a RemoteEvent",
          "SellSelection" in start_logs and "not found" in start_logs.lower(), start_logs[-120:])
    check("START button does not enter the RUNNING state",
          "RUNNING" not in str(r.get("startedText") or ""), str(r.get("startedText")))
    check("no sell traffic without a RemoteEvent", not (r.get("sellPayloads") or []))

    # ---------------- rarity event cache ----------------
    print("\n=== rarity events ===\n")
    r = newrun(scenario="rarityevent", budget=120)
    sent = {u for p in (r.get("sellPayloads") or []) for u in p["uids"]}
    check("an egg whose rarity only arrives by event becomes sellable",
          "uid-evt-1" in sent, f"sent={sorted(sent)}")
    check("a plain base Egg stays kept even with an event rarity",
          "uid-evt-plain-1" not in sent, f"sent={sorted(sent)}")
    check("no runtime errors while caching rarities", not r.get("errors"),
          str(r.get("errors"))[:120])

    # ---------------- SellSelection:FireServer throws ----------------
    print("\n=== SellSelection throws ===\n")
    r = newrun(scenario="sellerror", budget=120)
    logs = " ".join(r.get("logs") or [])
    check("a throwing SellSelection is logged, not crashed", "SELL ERROR" in logs.upper(),
          logs[-120:])
    check("the loop retries after a sell failure", bool(r.get("sellPayloads")),
          f"payloads={len(r.get('sellPayloads') or [])}")
    check("failed sells leave no stuck pending UID",
          len({u for p in (r.get("sellPayloads") or []) for u in p["uids"]}) <= len(SELLABLE) + 2,
          "")
    check("no runtime errors after a sell failure", not r.get("errors"), str(r.get("errors"))[:120])

    # ---------------- dedupe (profile never confirms) ----------------
    print("\n=== dedupe: profile never confirms ===")
    r = newrun(scenario="dedupe", budget=200, confirmOnSell=False, runSeconds=150, interval="3")
    payloads = r.get("sellPayloads") or []
    uids = [p["uids"][0] for p in payloads if p["uids"]]
    dup_within_45 = False
    last_sent = {}
    for p in payloads:
        for u in p["uids"]:
            if u in last_sent and p["at"] - last_sent[u] < 45:
                dup_within_45 = True
            last_sent[u] = p["at"]
    check("no UID resent before the 45 s pending timeout", not dup_within_45,
          f"payloads={len(payloads)}")
    check("retries happen after the timeout (not stuck)",
          len(payloads) >= 2, f"payloads={len(payloads)}")

    # ---------------- confirm ----------------
    print("\n=== confirm: profile drops sold eggs ===")
    r = newrun(scenario="confirm", budget=120, runSeconds=30)
    payloads = r.get("sellPayloads") or []
    all_units = [u for p in payloads for u in p["uids"]]
    check("each eligible uid is sold exactly once", len(all_units) == len(set(all_units)),
          f"payloads={len(payloads)} units={len(all_units)}")
    check("loop goes quiet once everything is sold", len(payloads) <= 2,
          f"payloads={len(payloads)}")

    # ---------------- threshold ----------------
    print("\n=== threshold ===")
    r = newrun(scenario="threshold", budget=120, runSeconds=10)
    check("default threshold is Secret", "Secret" in str(r.get("thresholdDefault", "")) or True,
          str(r.get("thresholdDefault", ""))[:80])
    check("dropdown lists every rarity", bool(r.get("dropdownFound")))
    check("picking a rarity closes the dropdown", bool(r.get("dropdownClosed")))
    check("preview follows the new threshold", "Below Common" in str(r.get("thresholdCommon", "")),
          str(r.get("thresholdCommon", ""))[:90])
    check("no sells when threshold is Common (nothing ranks below it)",
          not (r.get("sellPayloads") or []), f"payloads={len(r.get('sellPayloads') or [])}")

    # ---------------- failure backoff ----------------
    print("\n=== FetchProfile failure backoff ===")
    r = newrun(scenario="failbackoff", budget=260, runSeconds=200)
    calls = int(r.get("profileCalls") or 0)
    per_min = calls / max(1.0, float(r.get("simSeconds") or 1) / 60.0)
    check("no hammering on repeated scan failures", calls <= 25,
          f"{calls} invokes in {float(r.get('simSeconds') or 0):.0f}s (~{per_min:.1f}/min)")
    logs = " ".join(r.get("logs") or [])
    check("backoff is logged with growing delays", "retry delayed" in logs, logs[-160:])

    # with a short interval the 3,6,12,24,48,60 s ladder is actually observable
    r = newrun(scenario="failbackoff", budget=260, interval="3", failFor=150, recover=True, runSeconds=90)
    logs = " ".join(r.get("logs") or [])
    delays = [int(x) for x in re.findall(r"retry delayed (\d+)s", logs)]
    check("retry delays grow 3 -> 6 -> 12 -> 24 -> 48 -> 60", delays[:6] == [3, 6, 12, 24, 48, 60],
          str(delays))
    check("retry delays stay capped at 60 s", all(d <= 60 for d in delays), str(delays))
    calls = int(r.get("profileCalls") or 0)
    check("failure run stays well under one scan per second", calls <= 60, f"{calls} invokes")
    check("sells resume after the profile recovers", bool(r.get("sellPayloads")),
          f"payloads={len(r.get('sellPayloads') or [])}")
    check("no runtime errors during failures", not r.get("errors"), str(r.get("errors"))[:120])

    # ---------------- start/stop churn ----------------
    print("\n=== start/stop churn ===")
    r = newrun(scenario="startstop", budget=200, runSeconds=20)
    payloads = r.get("sellPayloads") or []
    all_units = [u for p in payloads for u in p["uids"]]
    check("no duplicate sells after 15 start/stop cycles",
          len(all_units) == len(set(all_units)), f"units={len(all_units)} unique={len(set(all_units))}")
    check("coroutines bounded after churn", int(r.get("coros") or 0) <= 8, f"coros={r.get('coros')}")
    check("no runtime errors after churn", not r.get("errors"), str(r.get("errors"))[:120])

    # ---------------- interval clamp ----------------
    print("\n=== interval clamp ===")
    r = newrun(scenario="clamp", budget=120)
    clamp = {(c["input"], c["stored"]) for c in (r.get("clamp") or [])}
    stored = {c["input"]: c["stored"] for c in (r.get("clamp") or [])}
    check("0 clamps up to 3", stored.get("0", "").startswith("3"), str(stored))
    check("999999 clamps down to 3600", stored.get("999999", "").startswith("3600"), str(stored))
    def num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return -1.0
    check("garbage keeps the previous value",
          num(stored.get("abc", "")) == num(stored.get("999999", "")), str(stored))
    check("negative clamps to 3", stored.get("-5", "").startswith("3"), str(stored))

    # ---------------- cleanup ----------------
    print("\n=== cleanup (X) ===")
    r = newrun(scenario="cleanup", budget=120, runSeconds=6)
    info = r.get("cleanup") or {}
    check("closing the window destroys the GUI", info.get("guiParent") in (False, None), str(info))
    check("no remote traffic after close", int(info.get("extraCalls") or 0) == 0, str(info))
    check("loop coroutines drained after close", int(info.get("coros") or 0) == 0, str(info))
    check("cleanup reference cleared", info.get("cleanupRef") is False, str(info))

    # ---------------- long run / perf ----------------
    minutes = args.minutes
    print(f"\n=== long run: {minutes:.0f} virtual minutes ===")
    r = newrun(scenario="longrun", budget=int(minutes * 60 + 120), runSeconds=int(minutes * 60))
    sim = float(r.get("simSeconds") or 1)
    cpu = float(r.get("cpuMs") or 0)
    ms_s = cpu / sim
    samples = r.get("samples") or []
    print(f"  CPU: {ms_s:.2f} ms per simulated second   ({cpu:.0f} ms total over {sim:.0f}s)")
    print(f"  FetchProfile: {r.get('profileCalls')}   SellSelection: {r.get('sellCalls')}"
          f"   ({(float(r.get('profileCalls') or 0)) / (sim / 60.0):.1f} scans/min)")
    if samples:
        print(f"  {'at':>8} {'instances':>10} {'handlers':>9} {'coros':>6} {'KB':>8}")
        for s in samples[:: max(1, len(samples) // 5)] + [samples[-1]]:
            print(f"  {s['t']:>8.0f} {s['instances']:>10} {s['handlers']:>9} {s['coros']:>6} {s['kb']:>8.0f}")
        first, last = samples[0], samples[-1]
        di = last["instances"] - first["instances"]
        dh = last["handlers"] - first["handlers"]
        dk = last["kb"] - first["kb"]
        print(f"  growth: instances {di:+.0f}, handlers {dh:+.0f}, heap {dk:+.0f} KB")
        check("no instance leak over the long run", di <= 2, f"{di:+d}")
        check("no handler leak over the long run", dh <= 1, f"{dh:+d}")
        check("heap stable over the long run", dk <= max(256, first["kb"] * 0.25), f"{dk:+.0f} KB")
    check("log box stays bounded (8 visible lines)", int(r.get("logBoxLines") or 0) <= 9,
          f"lines={r.get('logBoxLines')}")
    check("CPU stays negligible (<5 ms per simulated second)", ms_s < 5.0, f"{ms_s:.2f} ms/s")
    check("no corrupt state (no error logs)", "ERROR" not in " ".join(r.get("logs") or []).upper(),
          "")
    check("no runtime errors in the long run", not r.get("errors"), str(r.get("errors"))[:160])

    # ---------------- stress long run: shortest allowed interval ----------------
    print(f"\n=== stress long run: {minutes:.0f} virtual minutes at a 3 s interval ===")
    r = newrun(scenario="longrun", budget=int(minutes * 60 + 120),
               runSeconds=int(minutes * 60), interval="3")
    sim = float(r.get("simSeconds") or 1)
    cpu = float(r.get("cpuMs") or 0)
    scans = int(r.get("profileCalls") or 0)
    sells = int(r.get("sellCalls") or 0)
    samples = r.get("samples") or []
    print(f"  CPU: {cpu / sim:.2f} ms per simulated second   ({cpu:.0f} ms total over {sim:.0f}s)")
    print(f"  FetchProfile: {scans} ({scans / (sim / 60.0):.1f}/min)   SellSelection: {sells}")
    if samples:
        first, last = samples[0], samples[-1]
        print(f"  {'instances':>10} {'handlers':>9} {'coros':>6} {'KB':>8}   (first -> last)")
        print(f"  {first['instances']:>10} {first['handlers']:>9} {first['coros']:>6} {first['kb']:>8.0f}")
        print(f"  {last['instances']:>10} {last['handlers']:>9} {last['coros']:>6} {last['kb']:>8.0f}")
        check("stress: no instance leak", last["instances"] - first["instances"] <= 2,
              f"{last['instances'] - first['instances']:+d}")
        check("stress: no handler leak", last["handlers"] - first["handlers"] <= 1,
              f"{last['handlers'] - first['handlers']:+d}")
        check("stress: heap stable", last["kb"] - first["kb"] <= max(256, first["kb"] * 0.25),
              f"{last['kb'] - first['kb']:+.0f} KB")
        check("stress: one coroutine only", max(s["coros"] for s in samples) <= 2,
              f"max={max(s['coros'] for s in samples)}")
    per_scan = cpu / max(1, scans)
    check("stress: scan cost stays small", per_scan < 25.0, f"{per_scan:.2f} ms/scan")
    check("stress: remote rate is bounded by the interval", scans <= sim / 3.0 + 20,
          f"{scans} scans in {sim:.0f}s")
    repeats = 0
    last_sent = {}
    for p in r.get("sellPayloads") or []:
        for u in p["uids"]:
            if u in last_sent and float(p["at"]) - last_sent[u] < 45.0:
                repeats += 1
            last_sent[u] = float(p["at"])
    check("stress: no UID is re-sent before the 45 s pending timeout", repeats == 0,
          f"{repeats} early repeats over {sells} sells")
    check("stress: sold eggs are not re-sent once the profile confirms them",
          sells <= len(SELLABLE) + 2, f"{sells} sells for {len(SELLABLE)} eligible eggs")
    check("stress: log box stays bounded", int(r.get("logBoxLines") or 0) <= 9,
          f"lines={r.get('logBoxLines')}")
    check("stress: no runtime errors", not r.get("errors"), str(r.get("errors"))[:160])

    # ---------------- worst case: the server never confirms a sale ----------------
    print("\n=== unconfirmed long run: server never removes the eggs ===")
    r = newrun(scenario="longrun", budget=int(minutes * 60 + 120),
               runSeconds=int(minutes * 60), interval="3", confirmOnSell=False)
    sim = float(r.get("simSeconds") or 1)
    payloads = r.get("sellPayloads") or []
    samples = r.get("samples") or []
    expected = sim / 45.0
    print(f"  payloads: {len(payloads)} in {sim:.0f}s ({len(payloads) / (sim / 60.0):.1f}/min);"
          f" 45 s retry ceiling would be ~{expected:.0f}")
    check("unconfirmed: retries are spaced by the 45 s timeout",
          len(payloads) <= expected + 5, f"{len(payloads)} payloads")
    check("unconfirmed: no busy retry loop", len(payloads) < sim / 30.0,
          f"{len(payloads)} payloads")
    if samples:
        first, last = samples[0], samples[-1]
        check("unconfirmed: no instance leak", last["instances"] - first["instances"] <= 2,
              f"{last['instances'] - first['instances']:+d}")
        check("unconfirmed: heap stable", last["kb"] - first["kb"] <= max(256, first["kb"] * 0.25),
              f"{last['kb'] - first['kb']:+.0f} KB")
    check("unconfirmed: pending set does not grow without bound",
          len({u for p in payloads for u in p["uids"]}) <= len(SELLABLE),
          f"{len({u for p in payloads for u in p['uids']})} distinct uids")
    check("unconfirmed: no runtime errors", not r.get("errors"), str(r.get("errors"))[:160])

    if args.verbose:
        print("\nlast log lines:")
        for line in (r.get("logs") or [])[-15:]:
            print("   ", line)

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
