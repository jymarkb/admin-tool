--[[=========================================================================
	LIGHTDARK FLIGHT  -  the escape's flight mode, slowed down until it can be
	                     watched one step at a time

	The working lightdark flight threw 24 direct root.CFrame writes, 5054 studs,
	and the server kept every one of them. This script flies the same mechanism
	and nothing else, at a cadence slow enough that each write can be checked on
	its own:

	    35 studs every 0.5s          (70 studs/s, against the reference's ~3400)

	Why slow: at 3400 studs/s the writes are 130-360 studs apart and several land
	in the same frame, so a log cannot answer "did THIS write stick". At 35 studs
	every 0.5s each write is alone in its own half second, and the script reads
	the position back BEFORE the next write. That read is the test:

	    HELD      the character is still where the write put it
	    REVERTED  the server put us back - it says from where, to where, how far
	    MOVED     neither: something else moved us - it says where, so a physics
	              step can be told apart from a server correction

	What it deliberately does NOT do, because the working log never does it:
	  * no humanoid:ChangeState(Freefall), no AutoRotate = false. That pair is
	    the -1000 trigger: every flight that called it died in 1.1-1.2s, every
	    flight without it landed with hp 100.
	  * no velocity writes. The reference claims ZERO horizontal velocity and
	    holds its position with the CFrame write alone.

	Run it (paste into the executor and execute). It counts down, flies
	STEP_COUNT steps, then prints a summary. Send the whole printout back - or if
	that is too much, the "check" lines alone carry the verdict.
=========================================================================]]

-- ================================================================
-- CONFIG - every number the test depends on, in one place
-- ================================================================
local STEP_STUDS       = 35      -- studs written per step
local STEP_INTERVAL    = 0.5     -- seconds between writes
local STEP_COUNT       = 40      -- steps before it stops (40 x 35 = 1400 studs, 20s)
local HOLD_ALTITUDE    = true    -- pin Y to the altitude we started at
local LIFT_STUDS       = 0       -- teleport up first (the reference launch climbed +42)
local NOCLIP           = true    -- parts non-collidable for the flight, restored after
local AUTO_START_DELAY = 3       -- seconds to get into position before it flies
local TOLERANCE        = 3.0     -- studs: within this of a position counts as "there"
local DIRECTION        = nil     -- nil = fly the way the character is facing

-- ================================================================
-- LOGGING - same shape as debug.lua's, so the paste reads the same way
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
local function dash(v, fmt) if type(v) ~= "number" then return "-" end return string.format(fmt or "%.1f", v) end

-- nil from GetNetworkOwner() MEANS the server owns the part, and a client CFrame
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
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if _G.LIGHTDARK_FLIGHT_RUNNING then
	warn("LIGHTDARK FLIGHT: an earlier run is still going - stopping it first")
	_G.LIGHTDARK_FLIGHT_STOP = true
	task.wait(0.2)
end
_G.LIGHTDARK_FLIGHT_RUNNING = true
_G.LIGHTDARK_FLIGHT_STOP = false

local character = player.Character
local humanoid = character and character:FindFirstChildOfClass("Humanoid")
local root = character and character:FindFirstChild("HumanoidRootPart")
if not (character and humanoid and root) then
	warn("LIGHTDARK FLIGHT: no character/humanoid/HumanoidRootPart - respawn and run again")
	return
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
	startPos = nil,
	altitude = 0,
	dir = nil,
	askedStuds = 0,
	held = 0, reverted = 0, elsewhere = 0,
	pending = nil,            -- the write we are still watching
	hp = nil,
	state = nil,
	stopReason = nil,
	conn = nil,
	nextAt = 0,
}
local summaryDone = false

-- ---- per-step environment line ------------------------------------------
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
	elseif fromBefore <= TOLERANCE then
		verdict = "REVERTED - the server put us back"
		flight.reverted += 1
	else
		verdict = "MOVED ELSEWHERE - neither where we wrote nor where we were"
		flight.elsewhere += 1
	end

	log("%s check %02d | %.3fs after the write | now %s | %.1f studs from where it was written, %.1f from where it started",
		stamp(), p.step, age, fmtPos(here), fromWrite, fromBefore)
	if verdict ~= "HELD" then
		log("%s          | wrote=%s then=%s | %s",
			stamp(), fmtPos(p.wroteTo), fmtPos(p.before), verdict)
	end
	log("%s          | %s", stamp(), verdict)
end

-- ---- the write: 35 studs along the flight direction ---------------------
local function doStep(now)
	checkPending(now)

	if flight.step >= STEP_COUNT then
		flight.stopReason = "all " .. STEP_COUNT .. " steps flown"
		return
	end

	local before = root.Position
	if flight.step == 0 then
		flight.startPos = before
		flight.altitude = before.Y
		if not flight.dir then
			local look = root.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			flight.dir = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(-1, 0, 0)
			log("%s DIRECTION | %s | from the character's facing (LookVector flattened), 35 studs per step",
				stamp(), fmtVec(flight.dir))
		end
	end

	local target = Vector3.new(
		before.X + flight.dir.X * STEP_STUDS,
		HOLD_ALTITUDE and flight.altitude or before.Y,
		before.Z + flight.dir.Z * STEP_STUDS)

	-- THE WRITE. One direct root.CFrame assignment - the mechanism the working
	-- lightdark log shows (`24 direct root.CFrame write(s)`). No PivotTo, no
	-- velocity, no state call.
	root.CFrame = CFrame.new(target)

	local landed = root.Position
	local off = (landed - target).Magnitude
	flight.step += 1
	flight.askedStuds += STEP_STUDS
	flight.pending = { step = flight.step, before = before, wroteTo = target, at = now }

	local net = xzDist(landed, flight.startPos)
	log("%s step %02d | wrote %s | asked %s | landed %s | off by %.2f | net %.1f studs so far",
		stamp(), flight.step, fmtVec(flight.dir), fmtPos(target), fmtPos(landed), off, net)
	log("%s         | %s", stamp(), worldLine())
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
		local verdict = fromWrite <= TOLERANCE and "HELD"
			or (fromBefore <= TOLERANCE and "REVERTED - the server put us back"
				or "MOVED ELSEWHERE")
		if fromWrite <= TOLERANCE then flight.held += 1
		elseif fromBefore <= TOLERANCE then flight.reverted += 1
		else flight.elsewhere += 1 end
		log("%s check %02d | FINAL | now %s | %.1f from the write, %.1f from where it started | %s",
			stamp(), p.step, fmtPos(here), fromWrite, fromBefore, verdict)
	end

	local here = root.Position
	local net = flight.startPos and xzDist(here, flight.startPos) or 0
	local along = 0
	if flight.startPos and flight.dir then
		local d = Vector3.new(here.X - flight.startPos.X, 0, here.Z - flight.startPos.Z)
		along = d:Dot(flight.dir)
	end
	local restored = restoreNoclip()

	log("============ FLIGHT SUMMARY ============")
	log("asked     | %d steps x %.1f studs = %.1f studs over %.1fs",
		flight.step, STEP_STUDS, flight.askedStuds,
		flight.step * STEP_INTERVAL)
	log("achieved  | %.1f studs along the flight (%.1f of %.1f asked, %.0f%%)",
		along, net, flight.askedStuds,
		flight.askedStuds > 0 and (net / flight.askedStuds) * 100 or 0)
	log("position  | start %s -> end %s",
		flight.startPos and fmtPos(flight.startPos) or "?", fmtPos(here))
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
	log("========================================")
	_G.LIGHTDARK_FLIGHT_RUNNING = false
end

-- ================================================================
-- RUN
-- ================================================================
log("============ LIGHTDARK FLIGHT ============")
log("%s config    | %d studs every %.2fs x %d steps = %.0f studs over %.1fs",
	stamp(), STEP_STUDS, STEP_INTERVAL, STEP_COUNT, STEP_STUDS * STEP_COUNT,
	STEP_COUNT * STEP_INTERVAL)
log("%s setup     | holdAltitude=%s | lift=%d | noclip=%s | tolerance=%.1f",
	stamp(), tostring(HOLD_ALTITUDE), LIFT_STUDS, tostring(NOCLIP), TOLERANCE)
log("%s start     | %s | hp=%s | state=%s",
	stamp(), fmtPos(root.Position), dash(humanoid.Health), tostring(humanoid:GetState()))
log("%s not called| ChangeState(Freefall) and AutoRotate stay untouched - the -1000 pair",
	stamp())

if LIFT_STUDS > 0 then
	local p = root.Position
	root.CFrame = CFrame.new(Vector3.new(p.X, p.Y + LIFT_STUDS, p.Z))
	log("%s launch    | lifted %.1f studs to %s", stamp(), LIFT_STUDS, fmtPos(root.Position))
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
-- reads 0.517s per step instead of the 0.5s this script claims to fly.
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

	-- report prop/state changes as they happen: they are clues, not noise
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
	-- so an exact scheduler would run one frame late - and one frame late on
	-- every step is a 3% slower flight than the one this script claims to fly.
	if now >= flight.nextAt - 1e-6 then
		-- advance from the SCHEDULE, and never fire twice in one frame
		flight.nextAt += STEP_INTERVAL
		if flight.nextAt < now then flight.nextAt = now + STEP_INTERVAL end
		doStep(now)
		if flight.stopReason then finish(flight.stopReason) end
	end
end)
