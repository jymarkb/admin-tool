#!/usr/bin/env python3
"""
Focused regression test: "Cast Failed (nil)" after a night reset (auto fishing).

Reproduces the reported sequence only:

    1. Auto Farm enabled, no matching eggs -> engine enters the fishing phase
    2. a night reset fires (Lighting day -> night) mid-fishing
    3. the server answers the next RF/Fishing/Cast with nil

and asserts the engine recovers instead of sticking on "Cast Failed (nil)".

Scenarios
    A. reset + server recovers immediately      -> recovery, no retry needed
    B. reset + first post-reset cast is nil     -> recovery + exactly one retry
    C. server refuses every cast for a while    -> failure is logged, loop keeps
                                                   cycling, fishing resumes once
                                                   the server answers again (no wedge)

This test does NOT modify the script under test. It reuses tests/roblox_stub.lua.

Usage:
    python3 farmer/tests/test_cast_after_reset.py
    python3 farmer/tests/test_cast_after_reset.py --script farmer/EggGoToUI_v11.lua --verbose

Requires `lupa` (pip install lupa). Exit code 0 = all checks passed.
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
    local Stub, SRC, opts = ...

    Stub.maxTime = opts.budget + 120
    local env = Stub.buildEnv()

    ------------------------------------------------------------------
    -- engine log capture (bounded) + event counters
    ------------------------------------------------------------------
    local ring, hits = {}, {}
    local COUNTED = {
        nightReset    = "Night Reset",
        nightRecovery = "resetting rod & remote state",
        castRetry     = "resetting rod state and retrying",
        castRefused   = "Cast refused by server",
        castClosed    = "Closing pending cast",
        castKept      = "kept pending for close",
        castFailed    = "Cast FAILED after retry",
        castOk        = "Cast OK ->",
        cycle         = "--- CYCLE #",
        phaseFishing  = "Auto Fishing phase started",
    }
    for key in pairs(COUNTED) do hits[key] = 0 end
    local function note(line)
        table.insert(ring, line)
        if #ring > 300 then table.remove(ring, 1) end
        for key, needle in pairs(COUNTED) do
            if line:find(needle, 1, true) then hits[key] = hits[key] + 1 end
        end
    end
    env.print = function(...) note(table.concat({ ... }, " ")) end

    local chunk, loadErr = load(SRC, "@EggGoToUI_v11.lua", "t", env)
    if not chunk then return { fatal = "load: " .. tostring(loadErr) } end
    local ok, runErr = pcall(chunk)
    if not ok then return { fatal = "runtime: " .. tostring(runErr) } end

    ------------------------------------------------------------------
    -- scripted fishing server: Cast answers nil while `castBlocked > 0`
    ------------------------------------------------------------------
    local castBlocked = 0
    local castSeq, casts, okCasts, refused = 0, 0, 0, 0
    local firstCastAt = nil

    -- Server session model: one open cast at a time. While a session is open
    -- every Cast is answered with nil + "Hold on..." (what the game did).
    local openSession = nil
    local rejectReels = {}          -- id -> remaining rejected reels
    local reelRejected, reelClosed = 0, 0
    local okCastsAfterFail = 0
    local failedOnce = false

    local castRemote = Stub.remotes["RF/Fishing/Cast"]
    castRemote.InvokeServer = function(_, _power, _target)
        casts = casts + 1
        if castBlocked > 0 then
            castBlocked = castBlocked - 1
            refused = refused + 1
            return nil, "Hold on..."        -- the reported "Cast Failed (nil)"
        end
        if openSession then
            refused = refused + 1
            return nil, "Hold on..."        -- pending session keeps the line busy
        end
        castSeq = castSeq + 1
        local id = "fish" .. castSeq
        openSession = id
        okCasts = okCasts + 1
        if failedOnce and okCastsAfterFail ~= nil then okCastsAfterFail = okCastsAfterFail + 1 end
        if not firstCastAt then firstCastAt = Stub.now end
        -- reproduce: one cast whose reel is rejected ("fish escaped")
        if opts.failReel and not failedOnce and Stub.now >= (opts.failReelAt or 60) then
            failedOnce = true
            rejectReels[id] = opts.reelFailures or 3
        end
        return { Id = id, Wait = 0.2 }
    end

    Stub.remotes["RF/Fishing/Reel"].InvokeServer = function(_, id, action)
        if id ~= openSession then return false, nil end   -- stale / already closed
        local remaining = rejectReels[id]
        if remaining and remaining > 0 then
            rejectReels[id] = remaining - 1
            reelRejected = reelRejected + 1
            return false, nil                             -- not caught, session stays open
        end
        openSession = nil
        reelClosed = reelClosed + 1
        return true, { Name = "Candy Corn", Rarity = "Common", Amount = 1 }
    end

    ------------------------------------------------------------------
    -- start auto farm (no eggs in the world -> straight into fishing)
    ------------------------------------------------------------------
    local farmBtn = Stub.registry["HwAutoFarmBtn"]
    local fishBtn = Stub.registry["HwAutoFishBtn"]
    local fishStatus = Stub.registry["LblFishStatus"]
    if farmBtn then Stub.fire(farmBtn, "MouseButton1Click") end

    local lighting = Stub.svc("Lighting")
    local runService = Stub.svc("RunService")
    local tick = 0.25
    local steps = math.floor(opts.budget / tick)

    local resets = 0
    local nextResetAt = opts.firstResetAt
    local perReset = {}          -- observations recorded around each reset
    local sawFishingBeforeReset = false

    local function snapshot(tag)
        return {
            tag = tag,
            fishBtn = fishBtn and fishBtn.Text or nil,
            fishStatus = fishStatus and fishStatus.Text or nil,
            at = Stub.now,
        }
    end

    for i = 1, steps do
        Stub.tick(tick)
        Stub.fire(runService, "Heartbeat")

        if firstCastAt and not sawFishingBeforeReset then sawFishingBeforeReset = true end

        if Stub.now >= nextResetAt and resets < opts.resets then
            resets = resets + 1
            nextResetAt = nextResetAt + opts.resetEvery

            castBlocked = opts.nilCastsPerReset      -- nil for the first N casts
            local before = snapshot("before")
            lighting.ClockTime = 19                   -- day -> night
            Stub.tick(tick)
            local after = snapshot("after")
            perReset[resets] = { before = before, after = after }
            lighting.ClockTime = 7                    -- back to day

            -- clear a persistent refusal later in the run (scenario C)
            if opts.clearAt and Stub.now >= opts.clearAt then castBlocked = 0 end
        end

        if opts.clearAt and Stub.now >= opts.clearAt and castBlocked > 0 then
            castBlocked = 0
        end
    end

    for _, line in ipairs(ring) do table.insert(hits, 0) end

    local out = {
        fatal = nil,
        resets = resets,
        perReset = perReset,
        hits = hits,
        casts = casts,
        okCasts = okCasts,
        okCastsAfterFail = okCastsAfterFail,
        reelRejected = reelRejected,
        reelClosed = reelClosed,
        refused = refused,
        fishBtnAfterResets = {},
        sawFishingBeforeReset = sawFishingBeforeReset,
        errors = #Stub.errors,
        errorList = {},
        log = table.concat(ring, "\n"),
    }
    for n = 1, resets do
        out.fishBtnAfterResets[n] = perReset[n] and perReset[n].after.fishBtn or nil
    end
    for _, e in ipairs(Stub.errors) do table.insert(out.errorList, e) end
    return out
    """
)


def run_scenario(lua, stub, script_src, *, resets, first_reset_at, reset_every,
                 nil_casts_per_reset, clear_at, budget, verbose,
                 fail_reel=False, reel_failures=3):
    driver = lua.eval("function(s) return assert(load(s, '@cast_driver.lua')) end")(DRIVER)
    opts = lua.table_from({
        "resets": resets,
        "firstResetAt": first_reset_at,
        "resetEvery": reset_every,
        "nilCastsPerReset": nil_casts_per_reset,
        "clearAt": clear_at,
        "budget": budget,
        "failReel": fail_reel,
        "failReelAt": 60,
        "reelFailures": reel_failures,
    })
    raw = driver(stub, script_src, opts)
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


def fresh(lua):
    stub_src = open(STUB_PATH, encoding="utf-8").read()
    return lua.eval("function(s) return assert(load(s, '@roblox_stub.lua'))() end")(stub_src)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", default=SCRIPT_PATH)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    try:
        from lupa import LuaRuntime
    except ImportError:
        sys.exit("lupa is required: pip install lupa")

    script_src = open(args.script, encoding="utf-8").read()
    failures = []

    def check(label, ok, detail=""):
        print(("PASS  " if ok else "FAIL  ") + label + ((" | " + detail) if detail else ""))
        if not ok:
            failures.append(label)

    scenarios = [
        dict(name="A: reset, server recovers at once", nil_casts=0, resets=3, clear_at=None),
        dict(name="B: reset, first post-reset cast is nil", nil_casts=1, resets=3, clear_at=None),
        dict(name="C: server refuses all casts, then recovers", nil_casts=500, resets=2, clear_at=260),
        dict(name="D: interrupted cast left open, server busy x3", nil_casts=3, resets=2, clear_at=None),
        dict(name="E: reel rejected, session left open (live log)", nil_casts=0, resets=1, clear_at=None,
             fail_reel=True, reel_failures=3),
    ]

    for sc in scenarios:
        print(f"\n=== {sc['name']} ===")
        lua = LuaRuntime(unpack_returned_tuples=True)
        stub = fresh(lua)
        res = run_scenario(
            lua, stub, script_src,
            resets=sc["resets"], first_reset_at=90, reset_every=70,
            nil_casts_per_reset=sc["nil_casts"], clear_at=sc["clear_at"],
            fail_reel=sc.get("fail_reel", False), reel_failures=sc.get("reel_failures", 3),
            budget=420, verbose=args.verbose,
        )

        if res.get("fatal"):
            check("script loads", False, str(res["fatal"]))
            continue

        hits = res.get("hits") or {}
        resets = int(res.get("resets") or 0)
        casts = int(res.get("casts") or 0)
        ok_casts = int(res.get("okCasts") or 0)

        check("fishing phase was reached before the first reset",
              bool(res.get("sawFishingBeforeReset")), f"casts={casts}")
        check("every night reset was detected",
              int(hits.get("nightReset") or 0) >= resets,
              f"resets={resets} nightReset={hits.get('nightReset')}")
        check("rod/remote state is reset once per night reset",
              int(hits.get("nightRecovery") or 0) == resets,
              f"nightRecovery={hits.get('nightRecovery')} resets={resets}")
        check("fish button stays AUTO after the reset",
              all(t == "AUTO" for t in (res.get("fishBtnAfterResets") or []) if t is not None)
              and bool(res.get("fishBtnAfterResets")),
              f"buttons={res.get('fishBtnAfterResets')}")
        check("no engine runtime errors",
              int(res.get("errors") or 0) == 0, str(res.get("errorList") or [])[:160])

        if sc.get("fail_reel"):
            check("rejected reel keeps the cast id for closing",
                  int(hits.get("castKept") or 0) >= 1,
                  f"reelRejected={res.get('reelRejected')} castKept={hits.get('castKept')}")
            check("orphaned cast is closed on a later attempt",
                  int(hits.get("castClosed") or 0) >= 1,
                  f"castClosed={hits.get('castClosed')} reelClosed={res.get('reelClosed')}")
            check("casting recovers after the rejected reel",
                  int(res.get("okCastsAfterFail") or 0) >= 3,
                  f"okCastsAfterFail={res.get('okCastsAfterFail')} refused={res.get('refused')}")
            check("no permanent 'Hold on...' spiral",
                  int(res.get("refused") or 0) <= 6 and int(hits.get("castFailed") or 0) <= 2,
                  f"refused={res.get('refused')} castFailed={hits.get('castFailed')}")
        elif sc["nil_casts"] == 0:
            check("nil cast never occurs (no recovery retry logged)",
                  int(hits.get("castRetry") or 0) == 0
                  and int(hits.get("castFailed") or 0) == 0,
                  f"castRetry={hits.get('castRetry')} castFailed={hits.get('castFailed')}")
        elif sc["nil_casts"] == 3:
            check("the interrupted cast is closed before re-casting",
                  int(hits.get("castClosed") or 0) >= 1,
                  f"castClosed={hits.get('castClosed')}")
            check("the server's refusal message is surfaced, not discarded",
                  int(hits.get("castRefused") or 0) >= 1,
                  f"castRefused={hits.get('castRefused')} refused={res.get('refused')}")
            check("engine keeps retrying inside the cycle until the cast lands",
                  ok_casts > 0 and int(hits.get("castFailed") or 0) <= resets,
                  f"okCasts={ok_casts} castFailed={hits.get('castFailed')} refused={res.get('refused')}")
        elif sc["nil_casts"] == 1:
            check("busy refusal (nil + message) is retried, not treated as terminal",
                  int(hits.get("castRefused") or 0) >= resets,
                  f"castRefused={hits.get('castRefused')} resets={resets}")
            check("recovered cast succeeds (no sticky 'Cast Failed')",
                  int(hits.get("castFailed") or 0) == 0 and ok_casts > 0,
                  f"castFailed={hits.get('castFailed')} okCasts={ok_casts}")
        else:
            check("persistent refusal is reported, not silently swallowed",
                  int(hits.get("castFailed") or 0) >= 1,
                  f"castFailed={hits.get('castFailed')}")
            check("fishing keeps cycling while the server refuses (no wedge)",
                  int(hits.get("cycle") or 0) >= 5 and casts >= 5,
                  f"cycles={hits.get('cycle')} casts={casts}")
            check("fishing resumes once the server answers again",
                  ok_casts >= 1 and int(hits.get("castOk") or 0) >= 1,
                  f"okCasts={ok_casts} castOk={hits.get('castOk')}")

        if args.verbose:
            print("  counters:", {k: hits.get(k) for k in ("nightReset", "nightRecovery", "castRetry", "castFailed", "castOk", "cycle")},
                  f"casts={casts} okCasts={ok_casts}")
            for line in (res.get("log") or "").splitlines():
                if any(k in line for k in ("Night reset detected", "resetting rod state", "Cast FAILED", "Cast OK")):
                    print("   ", line)

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
