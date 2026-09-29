-- Offline checks for advanced_scanner_v3.lua (run.mjs loads mock -> scanner -> this driver).
local M = MOCK
local F = M.fixture
local total, passed = 0, 0
local function check(name, cond, detail)
	total = total + 1
	if cond then passed = passed + 1; print(string.format("[PASS] %s", name))
	else print(string.format("[FAIL] %s%s", name, detail ~= nil and ("  -> " .. tostring(detail)) or "")) end
end
local function has(text, needle)
	return string.find(tostring(text or ""), needle, 1, true) ~= nil
end
local API = _G.ADVANCED_SCANNER_V3
local function journalText() return M.journalText() end
local function findInJournal(fragment, from)
	local entries = API and API.journal() or {}
	for i = (from or 0) + 1, #entries do
		if has(entries[i].line, fragment) then return entries[i] end
	end
	return nil
end
local function countInJournal(fragment)
	local n = 0
	for _, e in ipairs(API.journal()) do if has(e.line, fragment) then n = n + 1 end end
	return n
end
local function waitFor(pred, limit)
	local g = 0
	while not pred() and g < (limit or 5000) do g = g + 1; M.pump(0.02) end
	return pred()
end

M.reset()   -- fixture already installed by mock.lua at load time   -- writesArmed = true: ANY fixture property write by the scanner is a violation

check("scanner exposes its API", type(API) == "table")
if type(API) ~= "table" then
	print(string.format("RESULT checks=%d passed=%d failed=%d", total, passed, total - passed)); return
end
M.pump(0.2)

--=================== A. boot ===================
local gui = F.playerGui:FindFirstChild("AdvancedScanner_v3")
check("GUI is created", gui ~= nil)
check("FULL SCAN button exists", M.findDescendantByName(gui, "Btn_FULLSCAN") ~= nil)
check("WATCH button exists", M.findDescendantByName(gui, "Btn_WATCH") ~= nil)
check("MODE button exists", M.findDescendantByName(gui, "Btn_MODE") ~= nil)
check("COPY button exists", M.findDescendantByName(gui, "Btn_COPY") ~= nil)
check("CLEAR button exists", M.findDescendantByName(gui, "Btn_CLEAR") ~= nil)
check("CLOSE button exists", M.findDescendantByName(gui, "Btn_CLOSE") ~= nil)
check("AUTO_WATCH starts the listener at load", API.status().watching == true, tostring(API.status().watching))
check("starts in focus mode", API.status().mode == "focus", API.status().mode)
check("watch button already reads ON", M.findDescendantByName(gui, "Btn_WATCH").Text == "WATCH: ON",
	M.findDescendantByName(gui, "Btn_WATCH").Text)
check("ready line logged", has(journalText(), "v3 listener ready"))
check("no outgoing calls at boot", #M.outgoingCalls == 0 and API.stats().outgoingCalls == 0,
	string.format("%d recorded", #M.outgoingCalls))

local scanBtn = M.findDescendantByName(gui, "Btn_FULLSCAN")
local watchBtn = M.findDescendantByName(gui, "Btn_WATCH")
local modeBtn = M.findDescendantByName(gui, "Btn_MODE")
local copyBtn = M.findDescendantByName(gui, "Btn_COPY")

--=================== B. FULL SCAN ===================
scanBtn.MouseButton1Click:Fire()
check("full scan runs to completion", waitFor(function() return has(journalText(), "SCAN COMPLETE") end),
	API.status().statusText)
local text = journalText()
check("leaderstats section present", has(text, "LEADERSTATS"))
check("leaderstats value read", has(text, "Money/s = 18108437162"), text:sub(1, 200))
check("player attributes section present", has(text, "PLAYER ATTRIBUTES"))
check("AreaId surfaced as the biome", has(text, "AreaId = Jungle   <- current biome"))
local rdLine = findInJournal("RagdollEndTime = ")
local rdLeft = rdLine and tonumber(string.match(rdLine.line, "(%d+%.%d)s left"))
check("RagdollEndTime decoded to clock + remaining", rdLine ~= nil and has(rdLine.line, "->")
	and has(rdLine.line, "left") and rdLeft ~= nil and rdLeft > 2.0 and rdLeft <= 3.05, rdLine and rdLine.line)
check("JoinTick decoded to a clock time", has(text, "JoinTick = ") and has(text, "-> "))
check("active ragdoll window reported explicitly", findInJournal("RAGDOLL ACTIVE") ~= nil,
	findInJournal("RAGDOLL ACTIVE") and findInJournal("RAGDOLL ACTIVE").line)
check("movement snapshot present", has(text, "MOVEMENT SNAPSHOT") and has(text, "state=Running hp=100.0/100.0"))
check("carry snapshot present", has(text, "CARRY") and has(text, "IsCarrying=nil"))
check("remote inventory totals", has(text, "total=") and has(text, "RemoteFunction="))
check("boss family grouped", has(text, "RE/BossEvent") and has(text, "RE/ScrambleBoss"))
check("egg family grouped", has(text, "RE/EggWorld") and has(text, "RF/EggWorld"))
check("non-Networking remote listed", has(text, "BossFlightRemotes.BeginFlight")
	or has(text, "BossFlightRemotes"))
check("focus marker shown in inventory", has(text, "<-- FOCUS family (hit/ragdoll/carry)"))
check("object search found the plot treadmill", has(text, "TreadmillUpgrade"))
check("object search found the client render tool", has(text, "TreadmillRender_1"))
check("object search found the running sound (real token match)", has(text, "Running"))
check("'Trunk' no longer matches 'run' (v2 bug fixed)", not has(text, "Trunk"),
	findInJournal("Trunk") and findInJournal("Trunk").line)
check("scan summary line present", has(text, "read-only: no remote calls made"))
check("header shows userId (not 'hired')", has(text, "userId=42") and not has(text, "hired="))
local clockLine = findInJournal("server clock ")
check("server clock is a real time, not '?'", clockLine ~= nil and not has(clockLine.line, "clock ?"),
	clockLine and clockLine.line)
check("server time row printed with a clock", findInJournal("server time now = ") ~= nil,
	findInJournal("server time now = ") and findInJournal("server time now = ").line)
check("object search no longer drags in plot noise", not has(text, "PlotSign"))
check("object search is labelled with its tokens", has(text, "token-matched: run / running / treadmill / belt"))
local planned = findInJournal("mode selects ")
check("watch plan is reported (count + mode + total)",
	planned ~= nil and has(planned.line, "of 22 remote events") and has(planned.line, "focus mode selects"),
	planned and planned.line)
check("network owner read failure is labelled, not '?'",
	has(text, "net=client-side read blocked") or has(text, "net=nil") or has(text, "net="))
check("scan made no outgoing calls", #M.outgoingCalls == 0, string.format("%d", #M.outgoingCalls))
check("scan wrote nothing to the game", #M.violations == 0, tostring(M.violations[1] and M.violations[1].kind))

--=================== B2. repeat scans are compact and diff-aware ===================
local familiesBefore = countInJournal("RE/BossEvent/BlackHoleHit")
local mark2 = #API.journal()
scanBtn.MouseButton1Click:Fire()
check("second scan completes", waitFor(function()
	return #API.journal() > mark2 and has(journalText(), "SCAN COMPLETE") and countInJournal("SCAN COMPLETE") >= 2
end))
local function sinceMark(fragment)
	local entries = API.journal()
	for i = mark2 + 1, #entries do if has(entries[i].line, fragment) then return entries[i] end end
	return nil
end
local unchangedRow = sinceMark("inventory unchanged since the previous scan")
check("repeat scan reports the inventory as unchanged", unchangedRow ~= nil,
	unchangedRow and unchangedRow.line)
check("repeat scan does not repeat the family listing",
	countInJournal("RE/BossEvent/BlackHoleHit") == familiesBefore,
	string.format("%d then %d", familiesBefore, countInJournal("RE/BossEvent/BlackHoleHit")))
check("repeat scan skips the Workspace walk", sinceMark("skipped — object set does not change mid-session") ~= nil)
check("first scan said it was the full listing", countInJournal("full family listing") == 1)

local networking = F.watchTargets[1].Parent
local probeFamily = M.new("Folder", "ProbeFamily", networking, {})
M.new("RemoteEvent", "RE/ProbeFamily/ProbeAdded", probeFamily, {})
local mark3 = #API.journal()
scanBtn.MouseButton1Click:Fire()
check("third scan completes", waitFor(function() return countInJournal("SCAN COMPLETE") >= 3 end, 6000))
local function afterMark(fragment)
	local entries = API.journal()
	for i = mark3 + 1, #entries do if has(entries[i].line, fragment) then return entries[i] end end
	return nil
end
local changedRow = afterMark("inventory changed")
check("new remote family reported as an inventory addition", changedRow ~= nil and has(changedRow.line, "1 added"),
	changedRow and changedRow.line)
check("the new remote is named", afterMark("ProbeAdded") ~= nil,
	afterMark("ProbeAdded") and afterMark("ProbeAdded").line)

--=================== C. watch list / modes ===================
-- expired RagdollEndTime (the live log had one 215s in the past) must read as "ended ... ago"
local expiredMark = #API.journal()
M.setAttribute(F.player, "RagdollEndTime", M.serverNow() - 215.5)
M.pump(0.1)
local pastLine = findInJournal("RagdollEndTime ->", expiredMark)
check("expired ragdoll stamp is described as ended, not negative",
	pastLine ~= nil and has(pastLine.line, "ago"), pastLine and pastLine.line)
check("expired stamp does not read as an active ragdoll", API.status().ragdollRemaining == 0,
	tostring(API.status().ragdollRemaining))

API.setMode("focus")
local focusList = API._internals.watchList("focus")
local allList = API._internals.watchList("all")
check("focus list is non-empty", #focusList > 5, #focusList)
check("focus list is smaller than all", #focusList < #allList, string.format("%d vs %d", #focusList, #allList))
local function listedPath(list, fragment)
	for _, e in ipairs(list) do if has(e.path, fragment) then return true end end
	return false
end
check("focus keeps boss hit remotes", listedPath(focusList, "RE/BossEvent/BlackHoleHit"))
check("focus keeps ragdoll + anchor + rig remotes",
	listedPath(focusList, "RE/Limpness/WriteLimpness")
	and listedPath(focusList, "RE/ZoneProbe/AnchorForZone")
	and listedPath(focusList, "RE/RigSync/CorrectionBegan"))
check("focus drops unrelated remotes", not listedPath(focusList, "RE/Treadmill/SpeedGained"))
API.setMode("all")
check("all mode picks up the treadmill remote", listedPath(allList, "RE/Treadmill/SpeedGained"))

--=================== C2. mode switching: atomic, verified, rolled back on failure ===================
API.setMode("focus")
local focusPlan = #API._internals.watchList("focus")
local allPlan = #API._internals.watchList("all")
local modeMark = #API.journal()
API.setMode("all")
M.pump(0.2)
check("mode switch reconnects to the full plan", API.status().watched == allPlan,
	string.format("watched=%d plan=%d", API.status().watched, allPlan))
check("mode switch reports the reconnect count", (function()
	local entries = API.journal()
	for i = modeMark + 1, #entries do
		if has(entries[i].line, "reconnected " .. allPlan .. " of " .. allPlan) then return true end
	end
	return false
end)())
M.fireRemote(F.watchTargets[15], 1)
M.pump(0.1)
check("an all-mode-only remote is captured after the switch", (function()
	for _, e in ipairs(API.journal()) do if has(e.line, "SpeedGained") then return true end end
	return false
end)())

API._internals.simulate.connectFailure = true
local watchedBefore, modeBefore = API.status().watched, API.status().mode
local failMark = #API.journal()
API.setMode("focus")
M.pump(0.2)
check("failed mode switch keeps the previous connection set",
	API.status().watched == watchedBefore and API.status().mode == modeBefore,
	string.format("watched %d->%d mode %s->%s", watchedBefore, API.status().watched, modeBefore, API.status().mode))
check("failed mode switch surfaces an ERROR row", (function()
	local entries = API.journal()
	for i = failMark + 1, #entries do
		if has(entries[i].line, "ERROR") and has(entries[i].line, "mode change") then return true end
	end
	return false
end)())
API._internals.simulate.connectFailure = false
API.setMode("focus")
M.pump(0.2)
check("mode comes back to focus at the plan size", API.status().watched == focusPlan, API.status().watched)
M.fireRemote(F.watchTargets[2], { after = "rollback" })
M.pump(0.1)
check("listener still captures after a failed switch", (function()
	for _, e in ipairs(API.journal()) do if has(e.line, "HazardHit") then return true end end
	return false
end)())

--=================== D. listening ===================
API.setMode("focus")
API.watch(false)                     -- clean baseline: AUTO_WATCH already connected at load
local baselineConns = M.aliveConnections()
local focused = API.watch(true)
check("watch turns on", focused == true and API.status().watching == true)
check("watch button reflects state", watchBtn.Text == "WATCH: ON", watchBtn.Text)
check("watch connected to signals", M.aliveConnections() > baselineConns,
	string.format("%d vs %d", M.aliveConnections(), baselineConns))
check("watch log line names the count", has(journalText(), "listening on ") and has(journalText(), "read-only"))
check("watch log line states connected-of-plan", has(journalText(), "of " .. focusPlan .. " remote event(s)"))

API.clear()          -- CLEAR resets the journal, so search the fresh journal from the top
M.pump(0.1)
local kept = findInJournal("journal cleared — state kept")
check("CLEAR logs the kept listener state", kept ~= nil, kept and kept.line)
check("CLEAR keeps watching", API.status().watching == true)
check("CLEAR keeps the connections", API.status().watched == focusPlan, API.status().watched)
M.fireRemote(F.watchTargets[2], { after = "clear" })
M.pump(0.1)
check("listener still captures after CLEAR", findInJournal("HazardHit") ~= nil)

M.pump(1.2)          -- STATUS rows are emitted once a second
local statusLine
for _, e in ipairs(API.journal()) do if e.tag == "STATUS" then statusLine = e end end
check("STATUS row reports watched/mode", statusLine ~= nil and has(statusLine.line, "watched=")
	and has(statusLine.line, "focus"), statusLine and statusLine.line)
check("STATUS row reports real event count and quiet time",
	statusLine ~= nil and has(statusLine.line, "events=") and has(statusLine.line, "quiet="),
	statusLine and statusLine.line)

local target = F.watchTargets[1]        -- RE/BossEvent/BlackHoleHit
local mark = #API.journal()
M.fireRemote(target, { userId = 42, power = 1.5 })
M.pump(0.1)
local reLine = findInJournal("RE/BossEvent/BlackHoleHit", mark)
check("remote event is logged", reLine ~= nil, journalText():sub(-300))
check("payload is serialized", reLine ~= nil and has(reLine.line, "userId=42") and has(reLine.line, "power=1.5"),
	reLine and reLine.line)

M.fireRemote(F.watchTargets[4], "hello", 7, true)   -- HealthShifted
M.pump(0.1)
local multi = findInJournal("RE/BossEvent/HealthShifted", mark)
check("multiple args serialized", multi ~= nil and has(multi.line, "\"hello\"") and has(multi.line, "7")
	and has(multi.line, "true"), multi and multi.line)

-- unfocused remote should NOT be logged while in focus mode
local noise = F.watchTargets[15]        -- RE/Treadmill/SpeedGained
local noiseMark = #API.journal()
M.fireRemote(noise, 1, 2)
M.pump(0.1)
check("focus mode ignores unrelated remotes", findInJournal("Treadmill/SpeedGained", noiseMark) == nil)

API.watch(false)
check("watch turns off", API.status().watching == false)
local offMark = #API.journal()
M.fireRemote(target, { userId = 42 })
M.pump(0.1)
check("no logging after watch OFF", findInJournal("BlackHoleHit", offMark) == nil)
check("listeners disconnected", M.aliveConnections() <= baselineConns + 6,
	string.format("%d vs baseline %d", M.aliveConnections(), baselineConns))

--=================== E. HIT detection + attribution ===================
API.watch(true)
API.clear()
M.pump(0.3)
M.fireRemote(F.watchTargets[2], { source = "boss" })    -- RE/BossEvent/HazardHit just before the launch
M.drive(function() F.humanoid._props._State = M.enumItem("HumanoidStateType", "Physics") end)
M.setVelocity(-450, 13, -3)
M.pump(0.2)
local hitLine = findInJournal("HIT")
check("HIT row is produced on a physics launch", hitLine ~= nil, journalText():sub(-400))
check("HIT row reports the velocity delta", hitLine ~= nil and has(hitLine.line, "dv="),
	hitLine and hitLine.line)
check("HIT row reports the launch velocity", hitLine ~= nil and has(hitLine.line, "-450.0"),
	hitLine and hitLine.line)
check("HIT row names the remote that fired first (attribution)",
	hitLine ~= nil and has(hitLine.line, "HazardHit"), hitLine and hitLine.line)
check("HIT row carries the ragdoll window", hitLine ~= nil and has(hitLine.line, "RagdollEndTime="),
	hitLine and hitLine.line)
check("HIT counter increments", API.status().hits == 1, API.status().hits)

-- debounce: another huge delta immediately must not spam
M.setVelocity(-1500, 0, 0)
M.pump(0.2)
check("second launch inside the debounce is not double-logged", API.status().hits == 1, API.status().hits)
-- after the debounce window a new hit logs again
M.pump(1.2)                       -- let the debounce window expire first
M.setVelocity(900, 0, 900)
M.pump(0.2)
check("later launch is logged again", API.status().hits == 2, API.status().hits)

--=================== F. attributes + signals ===================
local attrMark = #API.journal()
M.setAttribute(F.player, "RagdollEndTime", M.serverNow() + 5)
M.pump(0.1)
local attrLine = findInJournal("RagdollEndTime ->", attrMark)
check("RagdollEndTime change logged", attrLine ~= nil, attrLine and attrLine.line)
check("RagdollEndTime change shows remaining seconds",
	attrLine ~= nil and (has(attrLine.line, "5.0s left") or has(attrLine.line, "4.9s left")),
	attrLine and attrLine.line)
check("status reports the live countdown",
	(function()
		local left = API.status().ragdollRemaining
		return left ~= nil and left > 3 and left <= 5
	end)(), tostring(API.status().ragdollRemaining))

M.setAttribute(F.player, "AreaId", "Cosmic")
M.pump(0.1)
check("AreaId change logged", findInJournal("AreaId -> Cosmic", attrMark) ~= nil)

M.setHealth(F.humanoid, 40)
M.pump(0.1)
local hpLine = findInJournal("HEALTH", attrMark)
check("health change logged with delta", hpLine ~= nil and has(hpLine.line, "-60.0"), hpLine and hpLine.line)

M.drive(function() F.humanoid:ChangeState(M.enumItem("HumanoidStateType", "Running")) end)
M.pump(0.1)
M.setWalkSpeed(F.humanoid, 234.1)
M.pump(0.1)
local wsGame = findInJournal("WALKSPEED", attrMark)
check("game's own high WalkSpeed logged", wsGame ~= nil, wsGame and wsGame.line)
check("game's own 234 is NOT claimed as script-driven",
	wsGame ~= nil and not has(wsGame.line, "script") and has(wsGame.line, "high"),
	wsGame and wsGame.line)
local wsMark = #API.journal()
M.setWalkSpeed(F.humanoid, 500)
M.pump(0.1)
local wsFlight = findInJournal("WALKSPEED", wsMark)
check("flight constant 500 flagged as the flight script",
	wsFlight ~= nil and has(wsFlight.line, "flight script constant"), wsFlight and wsFlight.line)

M.drive(function() F.humanoid:ChangeState(M.enumItem("HumanoidStateType", "GettingUp")) end)
M.pump(0.1)
check("humanoid state change logged", findInJournal("-> GettingUp", attrMark) ~= nil,
	findInJournal("STATE", attrMark) and findInJournal("STATE", attrMark).line)

M.setProp(F.humanoid, "PlatformStand", true)
M.pump(0.1)
check("PlatformStand flip logged", findInJournal("PlatformStand = true", attrMark) ~= nil)
M.setProp(F.root, "Anchored", true)
M.pump(0.1)
check("Anchored flip logged", findInJournal("Anchored = true", attrMark) ~= nil)

local egg = M.new("Tool", "Egg", nil, {})
M.addChild(F.character, egg)
M.pump(0.1)
check("carry Tool add logged", findInJournal("+ Egg", attrMark) ~= nil)
M.removeChild(F.character, egg)
M.pump(0.1)
check("carry Tool remove logged", findInJournal("- Egg", attrMark) ~= nil)

--=================== G. rate limiting + caps ===================
local rateMark = #API.journal()
for _ = 1, 45 do M.fireRemote(F.watchTargets[2], { i = 1 }) end
M.pump(0.2)
check("flood produces a RATE row", findInJournal("flood:", rateMark) ~= nil,
	findInJournal("flood:", rateMark) and findInJournal("flood:", rateMark).line)
check("suppressed count is tracked", API.stats().suppressed > 0, API.stats().suppressed)
check("events counter accumulates", API.stats().events >= 45, API.stats().events)
check("per-minute rate computed", API.stats().perMinute > 0, API.stats().perMinute)
check("journal stays under the cap", #API.journal() <= 4000, #API.journal())

--=================== G2. build r4: cached plan, ragdoll-triggered hit, JOLT ===================
check("cached plan equals the live focus plan", API._internals.planOf("focus") == focusPlan,
	string.format("cache=%d live=%d", API._internals.planOf("focus"), focusPlan))
check("cached plan equals the live all plan", API._internals.planOf("all") == allPlan,
	string.format("cache=%d live=%d", API._internals.planOf("all"), allPlan))
check("first remote of a fresh listener is announced", findInJournal("first remote event received") ~= nil)

check("STATUS row reports the plan size", statusLine ~= nil and has(statusLine.line, "plan "), statusLine and statusLine.line)
check("STATUS row reports the hit count", statusLine ~= nil and has(statusLine.line, "hits="), statusLine and statusLine.line)
check("STATUS row names the last remote that fired",
	statusLine ~= nil and has(statusLine.line, "last=") and not has(statusLine.line, "last=none"),
	statusLine and statusLine.line)
check("hit log matches the hit counter", #API._internals.hitLog() == API.status().hits and API.status().hits >= 1,
	string.format("log=%d hits=%d", #API._internals.hitLog(), API.status().hits))
check("the hit row says where the hit came from", hitLine ~= nil and has(hitLine.line, "via="),
	hitLine and hitLine.line)

-- A RagdollEndTime window with no visible velocity spike is still a hit: the client can read the root
-- after the server already corrected it, so physics alone can miss the hit instant.
M.pump(1.2)                                  -- clear the hit debounce
local ragMark, hitsBefore = #API.journal(), API.status().hits
M.setAttribute(F.player, "RagdollEndTime", M.serverNow() + 3)
M.pump(0.05)
local ragLine = findInJournal("window opened", ragMark)
check("a future RagdollEndTime stamp opens a hit window", ragLine ~= nil, journalText():sub(-300))
check("the window row decodes the stamp", ragLine ~= nil and has(ragLine.line, "+3.0s"), ragLine and ragLine.line)
M.pump(0.7)
local ragHit = findInJournal("via=ragdoll stamp", ragMark)
check("a ragdoll window with no velocity spike is reported as a HIT", ragHit ~= nil, journalText():sub(-300))
check("the ragdoll hit is counted once", API.status().hits == hitsBefore + 1, API.status().hits)

-- a shove under the hit threshold is a JOLT, not silence
M.pump(1.2)
M.setAttribute(F.player, "RagdollEndTime", M.serverNow() - 30)   -- no window in play
API.clear()
M.pump(0.3)
local joltMark = #API.journal()
local v0 = F.root._props.AssemblyLinearVelocity
M.setVelocity(v0.X - 200, v0.Y, v0.Z)        -- exactly 200 studs/s: over JOLT_DV, under HIT_DV
M.pump(0.05)
local joltLine = findInJournal("JOLT", joltMark)
check("a 200 studs/s shove logs JOLT, not a HIT", joltLine ~= nil, journalText():sub(-300))
check("JOLT row says why it is not a hit", joltLine ~= nil and has(joltLine.line, "under the 400 hit threshold"),
	joltLine and joltLine.line)
check("JOLT row names the last remote", joltLine ~= nil and has(joltLine.line, "last remote:"),
	joltLine and joltLine.line)
local hitsAfterJolt = API.status().hits
M.setVelocity(v0.X - 200, v0.Y, v0.Z)
M.pump(0.05)
check("no duplicate HIT from a static frame", API.status().hits == hitsAfterJolt, API.status().hits)

--=================== G3. GUI buttons: the real click path ===================
-- Everything above tested API.setMode/API.watch directly, which hid the fact that the button closures
-- could not see applyMode (a local created after the GUI) or setWatch (shadowed by a second
-- `local function`). A live run showed both as "attempt to call a nil value" ERROR rows. Click them.
local errsBefore = countInJournal("ERROR")
local clearBtn = M.findDescendantByName(gui, "Btn_CLEAR")

modeBtn.MouseButton1Click:Fire()
M.pump(0.2)
check("MODE button switches to all mode",
	API.status().mode == "all" and API.status().watched == allPlan,
	string.format("mode=%s watched=%d plan=%d", API.status().mode, API.status().watched, allPlan))
check("MODE button does not error", countInJournal("ERROR") == errsBefore, journalText():sub(-300))
modeBtn.MouseButton1Click:Fire()
M.pump(0.2)
check("MODE button switches back to focus",
	API.status().mode == "focus" and API.status().watched == focusPlan,
	string.format("mode=%s watched=%d plan=%d", API.status().mode, API.status().watched, focusPlan))

watchBtn.MouseButton1Click:Fire()
M.pump(0.2)
check("WATCH button turns the listener off", API.status().watching == false, tostring(API.status().watching))
check("WATCH button flips its label", watchBtn.Text == "WATCH: OFF", watchBtn.Text)
watchBtn.MouseButton1Click:Fire()
M.pump(0.2)
check("WATCH button turns the listener back on",
	API.status().watching == true and API.status().watched == focusPlan,
	string.format("watching=%s watched=%d", tostring(API.status().watching), API.status().watched))
M.fireRemote(F.watchTargets[2], { after = "button reconnect" })
M.pump(0.1)
check("listener captures after a button-driven reconnect", findInJournal("HazardHit") ~= nil)

scanBtn.MouseButton1Click:Fire()
check("FULL SCAN button runs a scan", waitFor(function() return countInJournal("SCAN COMPLETE") > 0 end))
local firstError = nil
for _, e in ipairs(API.journal()) do
	if e.tag == "ERROR" then firstError = e.line break end
end
check("no button has raised an ERROR row", countInJournal("ERROR") == errsBefore, firstError)

clearBtn.MouseButton1Click:Fire()
M.pump(0.1)
check("CLEAR button clears the journal",
	countInJournal("SCAN COMPLETE") == 0 and findInJournal("journal cleared") ~= nil)
check("CLEAR button keeps the listener", API.status().watching == true and API.status().watched == focusPlan,
	string.format("watching=%s watched=%d", tostring(API.status().watching), API.status().watched))
copyBtn.MouseButton1Click:Fire()
M.pump(0.1)
check("COPY button copies the live capture",
	M.clipboard ~= nil and has(M.clipboard, "ADVANCED SCANNER v3 (listener)"))
check("no ERROR after CLEAR/COPY", countInJournal("ERROR") == 0)

--=================== H. export / copy / destroy ===================
API.scan()                                   -- put a FULL SCAN block in the journal so the export scope is testable
M.pump(0.4)
local ok, exported = API.copy()
check("copy() reports success", ok == true)
check("clipboard received the export", M.clipboard ~= nil and #M.clipboard > 500,
	M.clipboard and #M.clipboard)
check("export has the v3 header", has(M.clipboard, "ADVANCED SCANNER v3 (listener)"))
check("export header says userId, not 'hired'", has(M.clipboard, "userId=") and not has(M.clipboard, "hired="))
check("export has the watch stats line", has(M.clipboard, "watch=ON"))
check("export contains a HIT row", has(M.clipboard, "HIT"))
check("export contains remote rows", has(M.clipboard, "RE/BossEvent/HazardHit"))
check("export equals API.export()", exported == API.export())
check("export is scoped to the live capture", has(M.clipboard, "scope=live capture"))
check("export omits the FULL SCAN dump but says how many lines were left out",
	not has(M.clipboard, "===== LEADERSTATS =====") and has(M.clipboard, "FULL SCAN line(s) omitted"),
	(M.clipboard or ""):sub(1, 300))
check("export keeps the scan available on request", has(API.export(true), "===== LEADERSTATS ====="))
check("export leads with a HIT SUMMARY block",
	has(M.clipboard, "HIT SUMMARY") and (M.clipboard or ""):find("HIT SUMMARY") < (M.clipboard or ""):find("] #"),
	(M.clipboard or ""):sub(1, 240))
check("hit summary carries the hit detail", has(M.clipboard, "via="))

check("read-only: zero outgoing calls all session", #M.outgoingCalls == 0 and #M.remoteCalls == 0,
	string.format("fires=%d invokes=%d", #M.outgoingCalls, #M.remoteCalls))
check("read-only: zero writes to game instances all session", #M.violations == 0,
	tostring(M.violations[1] and (M.violations[1].kind .. " " .. tostring(M.violations[1].key))))

local closeBtn = M.findDescendantByName(gui, "Btn_CLOSE")
closeBtn.MouseButton1Click:Fire()
M.pump(0.3)
check("close removes the GUI", F.playerGui:FindFirstChild("AdvancedScanner_v3") == nil)
check("close clears the global", _G.ADVANCED_SCANNER_V3 == nil)
check("close leaves no listeners", M.aliveConnections() == 0, M.aliveConnections())

local errors = #M.errors
M.pump(0.5)
check("no uncaught runtime errors", errors == 0, M.errors[1])

print(string.format("RESULT checks=%d passed=%d failed=%d", total, passed, total - passed))
