--[[=========================================================================
	LIGHTDARK PATH FLIGHT  -  the lightdark route, walked slowly

	It flies the SAME PATH the working lightdark escape flies, from the
	lightdark zone pad all the way to the forest landing pad, at a pace slow
	enough that every write can be judged on its own:

	    35 studs every 0.5s

	The route was read off the working logs, not invented:

	    lightdark pad    (5666.3,  70.7, -331.9)   where the flight starts
	    cruise start     (5245.1, 112.7, -331.5)   +42.0 climb, ~421 studs in
	    cruise end       ( 671.6, 112.7, -325.4)   the long straight at altitude
	    forest landing   ( 612.2,  70.7, -325.0)   -42.0 drop onto the pad

	    launch  423.3 studs | cruise 4573.5 | drop 72.8  = 5069.5 studs
	    145 steps of 35 studs, the last one 29.5 -> 72.5 seconds
	    the straight-line distance 5666.3 -> 612.2 = 5054.1, the reference's own

	The character walks the path point by point: each write lands 35 studs
	further along it, and 0.5s later the position is read back. That read is
	the whole test:

	    HELD      still where the write put it
	    REVERTED  the server put us back - it says from where, to where, how far
	    MOVED     something else moved us, so a physics step is not mistaken
	              for a server correction

	Because the next target is measured from where the character ACTUALLY is
	(found by projecting onto the path), a reverted step is retried rather
	than skipped, and the flight cannot run away from itself.

	Mechanism, unchanged from the lightdark log: ONE direct root.CFrame write
	per step. No ChangeState(Freefall), no AutoRotate = false - that pair is
	the -1000 trigger - and no velocity writes.

	Run it (paste into the executor and execute). It counts down, walks the
	path for 72.5s, then prints a summary. Send the printout back, or the
	"check" lines alone if it is too long. Stop it early with
	_G.LIGHTDARK_FLIGHT_STOP = true
=========================================================================]]

-- ================================================================
-- CONFIG
-- ================================================================
local STEP_STUDS       = 35      -- studs written per step
local STEP_INTERVAL    = 0.5     -- seconds between writes
local SNAP_TO_START    = true    -- if we are not at the pad, write ourselves there first
local START_SNAP_STUDS = 60      -- further than this from the pad counts as "not there"
local NOCLIP           = true    -- parts non-collidable for the flight, restored after
local AUTO_START_DELAY = 3       -- seconds before the first write
local TOLERANCE        = 3.0     -- studs: within this of a position counts as "there"
local ABORT_AFTER_REVERTS = 5    -- consecutive undone writes before giving up
local PROGRESS_EVERY   = 20      -- steps between progress lines

-- The route, as measured. Names are for the log only.
local PATH = {
	{ name = "lightdark pad",  pos = Vector3.new(5666.3,  70.7, -331.9) },
	{ name = "cruise start",   pos = Vector3.new(5245.1, 112.7, -331.5) },
	{ name = "cruise end",     pos = Vector3.new( 671.6, 112.7, -325.4) },
	{ name = "forest landing", pos = Vector3.new( 612.2,  70.7, -325.0) },
}

-- ================================================================
-- LOGGING
-- ================================================================
local startClock = os.clock()
local LOG = {}

local function stamp()
	local t = os.clock() - startClock
	local m = math.floor(t / 60)
	local s = t - m * 60
	return string.format("[%02d:%06.3f]", m, s)
end

local function log(line, ...)
	if select("#", ...) > 0 then line = string.format(line, ...) end
	LOG[#LOG + 1] = line
	print(line)
end

local function fmtPos(p) return string.format("(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z) end
local function fmtVec(v) return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z) end
local function dash(v) if type(v) ~= "number" then return "-" end return string.format("%.1f", v) end

-- Declared HERE, above every function that reads it. The first version declared
-- `player` further down with the rig, so ownerName() read a GLOBAL `player` (nil)
-- and every readout printed "table: 0x..." instead of "you" - the same
-- undeclared-global trap that has bitten debug.lua six times.
local Players = game:GetService("Players")
local player = Players.LocalPlayer

-- nil from GetNetworkOwner() means the SERVER owns the part, and a client CFrame
-- write on a server-owned assembly is only a request. Worth a readout per step.
local function ownerName(part)
	if not part then return "?" end
	local owner
	local ok = pcall(function() owner = part:GetNetworkOwner() end)
	if not ok then return "<no-ownership-api>" end
	if owner == nil then return "server" end
	return owner == player and "you" or tostring(owner)
end

local function xzDist(a, b)
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- ================================================================
-- RIG
-- ================================================================
local RunService = game:GetService("RunService")

if _G.LIGHTDARK_FLIGHT_RUNNING then
	warn("LIGHTDARK PATH: an earlier run is still going - stopping it first")
	_G.LIGHTDARK_FLIGHT_STOP = true
	task.wait(0.2)
end
_G.LIGHTDARK_FLIGHT_RUNNING = true
_G.LIGHTDARK_FLIGHT_STOP = false

local character = player.Character
local humanoid = character and character:FindFirstChildOfClass("Humanoid")
local root = character and character:FindFirstChild("HumanoidRootPart")
if not (character and humanoid and root) then
	warn("LIGHTDARK PATH: no character/humanoid/HumanoidRootPart - respawn and run again")
	return
end

-- ================================================================
-- THE PATH AS A POLYLINE - segment lengths, and where a point sits along it
-- ================================================================
local segments, TOTAL = {}, 0
for i = 1, #PATH - 1 do
	local a, b = PATH[i].pos, PATH[i + 1].pos
	local len = (b - a).Magnitude
	segments[i] = { a = a, b = b, len = len, start = TOTAL, name = PATH[i].name, to = PATH[i + 1].name }
	TOTAL += len
end
local STEPS = math.ceil(TOTAL / STEP_STUDS)

-- Where along the path is this position? Returns distance-along and how far the
-- position is off the path. Projecting instead of trusting the last write is
-- what lets a reverted step be retried from the truth.
local function projectToPath(p)
	local bestS, bestD = 0, math.huge
	for _, seg in ipairs(segments) do
		local ab = seg.b - seg.a
		local t = 0
		if seg.len > 1e-6 then
			t = ((p - seg.a):Dot(ab)) / (seg.len * seg.len)
			t = math.max(0, math.min(1, t))     -- math.clamp is Roblox-only
		end
		local c = seg.a + ab * t
		local d = (p - c).Magnitude
		if d < bestD then
			bestD = d
			bestS = seg.start + t * seg.len
		end
	end
	return bestS, bestD
end

-- The point that is s studs along the path.
local function samplePath(s)
	s = math.max(0, math.min(TOTAL, s))
	for _, seg in ipairs(segments) do
		if s <= seg.start + seg.len or seg == segments[#segments] then
			local t = seg.len > 1e-6 and (s - seg.start) / seg.len or 0
			return seg.a + (seg.b - seg.a) * t
		end
	end
	return PATH[#PATH].pos
end

local function segmentNameAt(s)
	for _, seg in ipairs(segments) do
		if s <= seg.start + seg.len then return seg.to end
	end
	return PATH[#PATH].name
end

-- ================================================================
-- NOCLIP - explicit, tracked, and restored. It never leaks.
-- ================================================================
local noclipSaved = {}

local function applyNoclip()
	if not NOCLIP then return 0 end
	local n = 0
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			noclipSaved[part] = part.CanCollide
			part.CanCollide = false
			n += 1
		end
	end
	return n
end

local function restoreNoclip()
	local n = 0
	for part, was in pairs(noclipSaved) do
		if part and part.Parent then
			part.CanCollide = was
			n += 1
		end
	end
	noclipSaved = {}
	return n
end

-- ================================================================
-- FLIGHT STATE
-- ================================================================
local flight = {
	step = 0,                 -- writes done
	s = 0,                    -- studs along the path we have reached
	startPos = nil,
	pending = nil,            -- the write we are still watching
	held = 0, reverted = 0, elsewhere = 0,
	revertStreak = 0,
	offPath = 0,
	arrived = false,
	hp = nil, state = nil,
	stopReason = nil,
	conn = nil,
	nextAt = 0,
}
local summaryDone = false

local function worldLine()
	local floor = humanoid.FloorMaterial
	local floorName = floor and tostring(floor) or "?"
	local grounded = floorName ~= "Enum.Material.Air" and floorName ~= "Air"
	return string.format(
		"state=%s | grounded=%s | floor=%s | vel=%s | hp=%s | owner=%s",
		tostring(humanoid:GetState()), tostring(grounded), floorName,
		fmtVec(root.AssemblyLinearVelocity), dash(humanoid.Health), ownerName(root))
end

-- ---- the check: did the previous write survive the interval? ------------
local function checkPending(now)
	local p = flight.pending
	if not p then return end
	flight.pending = nil

	local here = root.Position
	local fromWrite = xzDist(here, p.wroteTo)      -- 0 = still where we put it
	local fromBefore = xzDist(here, p.before)      -- 0 = back where we started
	local age = now - p.at
	local verdict
	if fromWrite <= TOLERANCE then
		verdict = "HELD"
		flight.held += 1
		flight.revertStreak = 0
	elseif fromBefore <= TOLERANCE then
		verdict = "REVERTED - the server put us back"
		flight.reverted += 1
		flight.revertStreak += 1
	else
		verdict = "MOVED ELSEWHERE - neither where we wrote nor where we were"
		flight.elsewhere += 1
		flight.revertStreak += 1
	end

	log("%s check %03d | %.3fs after the write | now %s | %.1f studs from where it was written, %.1f from where it started | %s",
		stamp(), p.step, age, fmtPos(here), fromWrite, fromBefore, verdict)
	if verdict ~= "HELD" then
		log("%s           | wrote %s then %s | path s=%.1f/%.1f",
			stamp(), fmtPos(p.wroteTo), fmtPos(p.before), p.s, TOTAL)
	end

	if flight.revertStreak >= ABORT_AFTER_REVERTS then
		flight.stopReason = string.format(
			"%d writes in a row were undone - the server is not keeping them", ABORT_AFTER_REVERTS)
	end
end

-- ---- the write: the next 35 studs of the path ---------------------------
local function doStep(now)
	checkPending(now)
	if flight.stopReason or flight.arrived then return end

	-- Where are we really? If a previous write did not hold, this is behind
	-- where we thought, and the next step is measured from the truth.
	local before = root.Position
	local here, offPath = projectToPath(before)
	if flight.step == 0 then
		flight.startPos = root.Position
		flight.offPath = offPath
	elseif here < flight.s - 1 then
		log("%s LAGGING   | s=%.1f but the character is at s=%.1f | last write did not hold - retrying from where it is",
			stamp(), flight.s, here)
	end
	flight.s = here
	if offPath > 60 then
		log("%s DRIFT      | %.1f studs off the path - the next write pulls back onto it",
			stamp(), offPath)
	end

	local fromS = flight.s
	local targetS = math.min(flight.s + STEP_STUDS, TOTAL)
	local target = samplePath(targetS)

	-- THE WRITE. One direct root.CFrame assignment - the mechanism the working
	-- lightdark log shows. No PivotTo, no velocity, no state call. The yaw is
	-- carried over: a bare CFrame.new() resets the facing, which yanks the
	-- character round and is not what the reference does.
	local yaw = root.Orientation.Y
	root.CFrame = CFrame.new(target) * CFrame.Angles(0, math.rad(yaw), 0)

	local landed = root.Position
	local off = (landed - target).Magnitude
	flight.step += 1
	flight.s = targetS
	flight.pending = { step = flight.step, before = before, wroteTo = target, at = now, s = targetS }

	log("%s step %03d | s=%.1f -> %.1f of %.1f (%d%%) | asked %s | landed %s | off by %.2f | %s",
		stamp(), flight.step, fromS, targetS, TOTAL, math.floor((targetS / TOTAL) * 100),
		fmtPos(target), fmtPos(landed), off, segmentNameAt(targetS))
	log("%s          | %s", stamp(), worldLine())

	if targetS >= TOTAL - 0.001 then
		flight.arrived = true
	end
end

-- ================================================================
-- SUMMARY
-- ================================================================
local function finish(reason)
	if summaryDone then return end
	summaryDone = true
	flight.stopReason = flight.stopReason or reason

	if flight.conn then
		flight.conn:Disconnect()
		flight.conn = nil
	end

	-- one last read: the final write deserves the same verdict as the rest
	if flight.pending then
		local p = flight.pending
		flight.pending = nil
		local here = root.Position
		local fromWrite = xzDist(here, p.wroteTo)
		local fromBefore = xzDist(here, p.before)
		local verdict
		if fromWrite <= TOLERANCE then
			verdict = "HELD"
			flight.held += 1
		elseif fromBefore <= TOLERANCE then
			verdict = "REVERTED - the server put us back"
			flight.reverted += 1
		else
			verdict = "MOVED ELSEWHERE"
			flight.elsewhere += 1
		end
		log("%s check %03d | FINAL | now %s | %.1f from the write, %.1f from where it started | %s",
			stamp(), p.step, fmtPos(here), fromWrite, fromBefore, verdict)
	end

	local here = root.Position
	local pad = PATH[#PATH].pos
	local padDist = (here - pad).Magnitude
	local xzNet = flight.startPos and xzDist(here, flight.startPos) or 0
	local restored = restoreNoclip()

	log("============ PATH FLIGHT SUMMARY ============")
	log("route     | %s -> %s", PATH[1].name, PATH[#PATH].name)
	log("asked     | %d steps x %.1f studs = %.1f studs of path over %.1fs",
		flight.step, STEP_STUDS, math.min(flight.step * STEP_STUDS, TOTAL),
		flight.step * STEP_INTERVAL)
	log("walked    | %.1f of %.1f studs of path (%.0f%%)",
		math.min(flight.s, TOTAL), TOTAL, (math.min(flight.s, TOTAL) / TOTAL) * 100)
	log("position  | start %s -> end %s",
		flight.startPos and fmtPos(flight.startPos) or "?", fmtPos(here))
	log("net       | %.1f studs across the ground (%.1f to the pad in a straight line, %.1f left)",
		xzNet, (flight.startPos and xzDist(flight.startPos, pad)) or 0, padDist)
	if flight.arrived then
		log("LANDED    | at the %s %s | %.1f studs from the pad | floor=%s | hp=%s",
			PATH[#PATH].name, fmtPos(pad), padDist, tostring(humanoid.FloorMaterial), dash(humanoid.Health))
	else
		log("not landed| %.1f studs short of the pad | s=%.1f/%.1f",
			padDist, math.min(flight.s, TOTAL), TOTAL)
	end
	log("steps     | %d HELD | %d REVERTED | %d moved elsewhere",
		flight.held, flight.reverted, flight.elsewhere)
	log("health    | hp=%s | state=%s | floor=%s",
		dash(humanoid.Health), tostring(humanoid:GetState()), tostring(humanoid.FloorMaterial))
	if NOCLIP then log("noclip    | restored CanCollide on %d part(s) - nothing leaked", restored) end

	local verdict
	if flight.reverted > 0 and flight.held == 0 then
		verdict = "THE SERVER IS UNDOING THEM - not one write survived"
	elseif flight.reverted > 0 then
		verdict = string.format("PARTIAL - %d of %d writes survived, %d were undone",
			flight.held, flight.held + flight.reverted, flight.reverted)
	elseif flight.step > 0 and flight.held == flight.step then
		verdict = "THE WRITES STICK - the server kept every step"
	else
		verdict = "INCONCLUSIVE - reads did not match either position"
	end
	log("verdict   | %s", verdict)
	log("stopped   | %s", flight.stopReason)
	log("=============================================")
	_G.LIGHTDARK_FLIGHT_RUNNING = false
end

-- ================================================================
-- RUN
-- ================================================================
log("============ LIGHTDARK PATH FLIGHT ============")
log("%s route     | %s -> %s | %s",
	stamp(), PATH[1].name, PATH[#PATH].name, fmtPos(PATH[#PATH].pos))
log("%s config    | %.1f studs every %.2fs x %d steps = %.1fs",
	stamp(), STEP_STUDS, STEP_INTERVAL, STEPS, STEPS * STEP_INTERVAL)
log("%s path      | launch %.1f | cruise %.1f | drop %.1f | total %.1f studs",
	stamp(), segments[1] and segments[1].len or 0,
	segments[2] and segments[2].len or 0, segments[3] and segments[3].len or 0, TOTAL)
log("%s start     | %s | hp=%s | state=%s",
	stamp(), fmtPos(root.Position), dash(humanoid.Health), tostring(humanoid:GetState()))
log("%s not called| ChangeState(Freefall) and AutoRotate stay untouched - the -1000 pair",
	stamp())

local here0, off0 = projectToPath(root.Position)
log("%s position  | s=%.1f of %.1f along the path | %.1f studs off it",
	stamp(), here0, TOTAL, off0)

if SNAP_TO_START then
	local pad = PATH[1].pos
	local d = (root.Position - pad).Magnitude
	if d > START_SNAP_STUDS then
		log("%s snap      | %.1f studs from the %s - one write to the start line",
			stamp(), d, PATH[1].name)
		local yaw = root.Orientation.Y
		root.CFrame = CFrame.new(pad) * CFrame.Angles(0, math.rad(yaw), 0)
		local after = (root.Position - pad).Magnitude
		log("%s snap      | wrote %s | now %s | %.2f studs off the pad | %s",
			stamp(), fmtPos(pad), fmtPos(root.Position), after, worldLine())
		if after > TOLERANCE then
			log("%s snap      | DID NOT HOLD - the write to the start line was undone. Flying from wherever the character is instead",
				stamp())
		end
	else
		log("%s snap      | already at the %s (%.1f studs) - flying from here", stamp(), PATH[1].name, d)
	end
end

local nc = applyNoclip()
if NOCLIP then log("%s noclip    | %d part(s) set non-collidable for the flight", stamp(), nc) end

for i = AUTO_START_DELAY, 1, -1 do
	log("%s countdown | flying in %d...", stamp(), i)
	task.wait(1)
end

-- seed the state/health so the first tick does not report a change from "?"
flight.state = tostring(humanoid:GetState())
flight.hp = humanoid.Health
flight.baseAt = os.clock()
flight.nextAt = flight.baseAt + STEP_INTERVAL
log("%s FLYING     | the first write is now", stamp())

-- The first write happens HERE, not on the next frame. Waiting for the first
-- frame puts every step one frame behind its own schedule, and the cadence then
-- reads slower than the 0.5s this script claims to fly.
doStep(flight.baseAt)

flight.conn = RunService.Heartbeat:Connect(function()
	if _G.LIGHTDARK_FLIGHT_STOP then
		finish("stopped by _G.LIGHTDARK_FLIGHT_STOP")
		return
	end
	if humanoid.Health <= 0 then
		log("%s DEATH      | hp=%s - the flight is over | %s",
			stamp(), dash(humanoid.Health),
			humanoid.Health < 0 and "EXTERNAL KILL: hp was SET, this is not damage"
				or "normal death")
		finish("the character died at step " .. flight.step)
		return
	end

	local now = os.clock()

	-- report state and health changes as they happen: they are clues, not noise
	local state = tostring(humanoid:GetState())
	if state ~= flight.state then
		log("%s STATE      | %s -> %s | %s", stamp(), flight.state or "?", state, worldLine())
		flight.state = state
	end
	if humanoid.Health ~= flight.hp then
		if flight.hp ~= nil then
			log("%s HEALTH     | %s -> %s", stamp(), dash(flight.hp), dash(humanoid.Health))
		end
		flight.hp = humanoid.Health
	end

	-- 1e-6: 30 frames of 1/60 sum to 0.49999999999999994, which is not >= 0.5,
	-- so an exact scheduler would run one frame late every step.
	if not flight.arrived and now >= flight.nextAt - 1e-6 then
		flight.nextAt += STEP_INTERVAL
		if flight.nextAt < now then flight.nextAt = now + STEP_INTERVAL end
		doStep(now)
		if flight.step > 0 and flight.step % PROGRESS_EVERY == 0 and not flight.arrived then
			log("%s PROGRESS   | step %d of %d | %.1f of %.1f studs | %d%% | %s",
				stamp(), flight.step, STEPS, math.min(flight.s, TOTAL), TOTAL,
				math.floor((math.min(flight.s, TOTAL) / TOTAL) * 100), segmentNameAt(flight.s))
		end
	end

	-- the landing gets one more read, then the summary
	if flight.arrived and now >= flight.nextAt - 1e-6 then
		finish("landed at the " .. PATH[#PATH].name)
	elseif flight.stopReason then
		finish(flight.stopReason)
	end
end)
