--[[=========================================================================
	FREE FALL TRAVEL v3  —  matches debug.lua's replicateFreefall (V7.1)

	v1 flew partway then the character died. This version is rebuilt to follow
	debug.lua's `replicateFreefall` on main - the reference that produced the
	cosmic / lightdark / titan logs - instead of my own guesses. The six things
	that differed, all of which matter:

	  1. character:PivotTo(cf) - moves the WHOLE model. v1 wrote root.CFrame
	     only, leaving the limbs behind for the physics engine to snap back.
	     That is a sustained physics fight, and it is the most likely killer.
	  2. RunService:BindToRenderStep at RenderPriority.Character.Value + 1 -
	     runs immediately after the character's own render step, so our write
	     lands last and wins the frame. v1 used Heartbeat, so the humanoid and
	     the animator reasserted after us every single frame.
	  3. humanoid:ChangeState(Freefall) - the reference DOES force it ("so the
	     humanoid fights less"), plus AutoRotate = false. v1 forced nothing.
	  4. velocity: ZERO X/Z but PRESERVE Y - Vector3.new(0, v.Y, 0). v1 wrote a
	     constant -10/-12, which is a claim gravity never makes. The logs show Y
	     climbing -8.2, -13.1, -19.6, -24.5: that is accumulated gravity, and
	     overwriting it is a lie the server corrects.
	  5. a STICKY target re-applied every frame, with err measured against it,
	     aborting after 8 consecutive frames outside 25 studs.
	  6. yaw preserved from root.Orientation.Y rather than LookVector.

	It also RECORDS the things that were missing when we tried to work out why
	the character died: health trail, humanoid state changes, solid obstacles
	ahead, and the parts near the body at the moment of death. Press COPY LOG
	and paste the output back.

	Kept from v2 because they are genuine safety, not guesses:
	  * the path scan (refuse to fly where the ground runs out),
	  * cruise altitude clearing the highest terrain on the route,
	  * the void guard against FallenPartsDestroyHeight,
	  * noclip as an explicit toggle, OFF by default, never leaked.

	The core trick is unchanged and is what stops rubberbanding: we write a
	POSITION and claim NO horizontal velocity.
=========================================================================]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local playerGui   = LocalPlayer:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------

local DEFAULT_STUDS = 2000
local MIN_STUDS     = 10
local MAX_STUDS     = 20000

-- ----------------------------------------------------------------
-- THE LAUNCH WINDOW
-- ----------------------------------------------------------------
-- Both -1000 HP kills were 0.03-0.04s in, in phase=launch, state=Running, on a
-- flight started 1-2s after the previous one. The launch phase teleported 78
-- studs HORIZONTALLY per frame while the humanoid was only ~9 studs up and still
-- in a WALKING state. A walking character cannot cross 78 studs in one frame -
-- that is unambiguous to a server, whereas a high airborne freefall teleport is
-- not. So: climb vertically first, and do not move horizontally until the
-- humanoid is genuinely off the ground.
local CLIMB_FRAMES   = 6        -- vertical-only ascent to cruise altitude
local AIRBORNE_WAIT  = 12       -- frames to wait for an airborne state before travelling

-- Back-to-back flights: the kills came on consecutive runs 1-2s apart, while
-- runs spaced 4.5s and 14.1s survived. Space them out.
local COOLDOWN_AFTER_FLIGHT = 12   -- seconds before another flight is allowed

local STEP_SIZE      = 78
local MAX_FLIGHT_S   = 2.5
local CRUISE_LEAD    = 120
local STEP_MIN       = 28
local STOP_WITHIN    = 25
local DESCENT_FRAMES = 3

-- render step, exactly as the reference does it
local RENDER_STEP_NAME     = "FreeFallTravelV3"
local RENDER_STEP_PRIORITY = Enum.RenderPriority.Character.Value + 1

-- correction-fight detection, from the reference
local CORRECTION_TOLERANCE   = 25.0
local MAX_CONSECUTIVE_ERRORS = 8

-- path scan
-- Do not fly high. The field deaths cluster at the top of the range: the runs
-- that survived cruised at 93 / 104 / 131, and the one that died at 4000 studs
-- was pushed to 209 by a scanned maxGround of 184. Cap the climb instead.
local MAX_CRUISE_RISE = 60      -- studs above the start Y
local HIGH_TERRAIN    = "stop_short"  -- "stop_short" | "refuse" | "ignore"

-- Never drop into solid geometry. The 4000-stud run landed INSIDE
-- COLL GUARD.WALL LEFT and died there, at Health 0 - a real death, not the
-- -1000 exploit handler. Check the landing point before descending, and look
-- around it for a clear spot rather than committing to a wall.
local LANDING_CLEAR   = true
local LANDING_TRIES   = 5       -- offsets to try on each of 4 sides
local LANDING_OFFSET  = 7       -- studs between those offsets

local SCAN_STEP    = 39
local SCAN_UP      = 200
local SCAN_DOWN    = 1000
local CLEARANCE    = 25
local ALLOW_VOID   = false
local VOID_MARGIN  = 100

-- The death in the field log happened in the SAME SECOND as DONE, and we used to
-- unbind right at landing - i.e. we stopped looking exactly when it mattered. So
-- keep watching for a few seconds after arrival.
local POST_WATCH_S = 4.0
local TRAIL_MAX    = 600        -- rolling (time, pos, hp, state) history
local TRAIL_PRINT  = 18         -- how many entries to print on death

-- Barrier / guarded-region detection. The field logs land inside
-- Workspace.World.Areas.GuardAreas.* and touch COLLISIONS.COLL GUARD.* parts,
-- and one log showed FrozenWallRight / GUARD NO COLLIDE walls 42 studs ahead.
-- Report them by default; STOP_AT_BARRIER makes the flight end short instead.
local SCAN_BARRIER    = true
local STOP_AT_BARRIER = false   -- false = report only, still fly the full distance
local BARRIER_MARGIN  = 25
local PROBE_LEN       = 30      -- studs between forward probes at cruise altitude

-- ----------------------------------------------------------------
-- THE -1000 HP EXPLOIT HANDLER
-- ----------------------------------------------------------------
-- A field run died with Humanoid.Health = -1000 exactly. That is not a fall,
-- not a kill brick and not the void - it is the server's lethal exploit handler.
-- grok-v3-target-fix.lua names it three times (see its L11, L812, L908):
--
--   L11  "the server's lethal exploit handler (-1000 HP damage)"
--   L812 "without tampering with Motor6D or HumanoidState (avoids -1000 HP death!)"
--   L908 "Does NOT touch Motor6D or ChangeState (avoids -1000 HP anti-cheat death!)"
--
-- Both of the left-hand switches below are therefore OFF. They were copied from
-- debug.lua's replicateFreefall, which calls ChangeState(Freefall) - i.e. we
-- added the exact operation the working notes say to avoid.
local TOUCH_HUMANOID_STATE = false  -- never ChangeState: named as a trigger
local TOUCH_AUTOROTATE     = false  -- also humanoid state, so also left alone

local NOCLIP       = false      -- explicit toggle, OFF by default
local DIR_MODE     = "facing"
local GUI_NAME     = "FreeFallTravelV3"

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

local flying     = false
local token      = 0
local flight     = nil
local lastRun    = {studs = 0, secs = 0}
local lastFlightEndAt = nil     -- to surface rapid repetition in the log
local cooldownShown   = false   -- so the button label is not rewritten every frame

local function cooldownRemaining()
	if not lastFlightEndAt then return 0 end
	local left = COOLDOWN_AFTER_FLIGHT - (os.clock() - lastFlightEndAt)
	return left > 0 and left or 0
end
local flightCount = 0

local savedCollisions  = {}
local diedConn, healthConn, stateConn
local deathRecorded = false   -- record only the first death, not one per watcher

local logLines = {}
local MAX_LOG  = 400

local trail      = {}           -- rolling history: the thing that was missing
local touchConns = {}           -- character part Touched watchers
local touchLog   = {}           -- what has been touching us
local watchUntil = nil          -- post-flight watch deadline
local endPos     = nil          -- where the flight actually finished

-- Declared HERE, above the watchers. The Died / Health handlers below reference
-- stopFlight, and a `local` introduced after them would not be visible inside
-- those closures - it would resolve to a global, so the death handler would
-- throw a nil-call at exactly the moment it matters and leave noclip on.
local stopFlight

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local function timestamp()
	local t = os.date("*t")
	return ("%02d:%02d:%02d"):format(t.hour, t.min, t.sec)
end

local function fmt(v)
	if not v then return "?" end
	return ("%.1f, %.1f, %.1f"):format(v.X, v.Y, v.Z)
end

local function logLine(text)
	logLines[#logLines + 1] = ("[%s] %s"):format(timestamp(), text)
	while #logLines > MAX_LOG do table.remove(logLines, 1) end
end

local function getState()
	local ch = LocalPlayer.Character
	if not ch then return nil, nil, nil end
	local h = ch:FindFirstChildOfClass("Humanoid")
	local r = ch:FindFirstChild("HumanoidRootPart")
	return ch, h, r
end

local function flatten(v)
	if not v then return nil end
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 0.05 then return nil end
	return flat.Unit
end

local function travelDir(r, h)
	if DIR_MODE == "move" and h then
		local d = flatten(h.MoveDirection)
		if d then return d end
	end
	if DIR_MODE == "camera" then
		local cam = workspace.CurrentCamera
		return flatten(cam and cam.CFrame.LookVector) or flatten(r.CFrame.LookVector)
	end
	return flatten(r.CFrame.LookVector)
end

local function deathFloor()
	local ok, v = pcall(function() return workspace.FallenPartsDestroyHeight end)
	if ok and type(v) == "number" then return v end
	return -500
end

----------------------------------------------------------------
-- NOCLIP
----------------------------------------------------------------

local function setCollisions(enable)
	local ch = LocalPlayer.Character
	if not ch then return 0 end
	local changed = 0
	for _, part in ipairs(ch:GetDescendants()) do
		if part:IsA("BasePart") then
			if not enable then
				if savedCollisions[part] == nil then
					savedCollisions[part] = part.CanCollide
				end
				if part.CanCollide then part.CanCollide = false; changed = changed + 1 end
			else
				if savedCollisions[part] ~= nil then
					part.CanCollide = savedCollisions[part]
					savedCollisions[part] = nil
					changed = changed + 1
				end
			end
		end
	end
	return changed
end

local function restoreCollisions()
	-- no-op when noclip was never used, so we cannot force CanCollide = true on
	-- parts that are legitimately non-collidable
	if next(savedCollisions) == nil then return end
	for part, was in pairs(savedCollisions) do
		pcall(function() part.CanCollide = was end)
		savedCollisions[part] = nil
	end
end

----------------------------------------------------------------
-- GROUND SCAN
----------------------------------------------------------------

local function groundY(x, z, fromY)
	local ch = LocalPlayer.Character
	local top = (fromY or 0) + SCAN_UP
	local ok, hit = pcall(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { ch }
		return workspace:Raycast(Vector3.new(x, top, z),
			Vector3.new(0, -(SCAN_UP + SCAN_DOWN), 0), params)
	end)
	if ok and hit and hit.Position then return hit.Position.Y end
	return nil
end

local function scanPath(startPos, dir, total)
	local samples, maxGround, missingAt = {}, nil, nil
	local step = math.min(SCAN_STEP, math.max(10, total / 4))
	local d = 0
	while d <= total + 0.001 do
		local x = startPos.X + dir.X * d
		local z = startPos.Z + dir.Z * d
		local g = groundY(x, z, startPos.Y)
		samples[#samples + 1] = {d = d, g = g}
		if g then
			if not maxGround or g > maxGround then maxGround = g end
		elseif not missingAt then
			missingAt = d
		end
		d = d + step
	end
	return {samples = samples, maxGround = maxGround, missingAt = missingAt,
		destGround = samples[#samples] and samples[#samples].g or nil}
end

----------------------------------------------------------------
-- DIAGNOSTICS  (the things that were missing when it died)
----------------------------------------------------------------

-- is anything solid in the way? A kill brick or a wall is invisible in a log
-- that only records position.
local lastObstacle = nil
local function checkAhead(pos, dir)
	local ch = LocalPlayer.Character
	local ok, hit = pcall(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { ch }
		return workspace:Raycast(pos, dir * (STEP_SIZE + 20), params)
	end)
	if not ok or not hit or not hit.Instance then return end
	local key = hit.Instance:GetFullName()
	if key == lastObstacle then return end
	lastObstacle = key
	local inst = hit.Instance
	logLine(("OBSTACLE ahead | %s | class=%s | dist=%.1f | collide=%s | material=%s")
		:format(key, inst.ClassName, (hit.Position - pos).Magnitude,
			tostring(inst.CanCollide), tostring(inst.Material)))
end

-- ---------------------------------------------------------------
-- ROLLING TRAIL
-- ---------------------------------------------------------------
-- The field log reported the death at the SPAWN, 2000 studs from where the
-- flight ended, because by the time Died fires the character has already been
-- respawned or moved. Sampling once at death is therefore useless: we need the
-- history. This records every frame and prints the tail on death.
local function recordTrail(h, r)
	if not (h and r) then return end
	local p = r.Position
	trail[#trail + 1] = {
		t = os.clock(), x = p.X, y = p.Y, z = p.Z,
		hp = h.Health, st = tostring(h:GetState()),
	}
	while #trail > TRAIL_MAX do table.remove(trail, 1) end
end

local function clearTrail() trail = {} end

local function dumpTrail()
	logLine(("TRAIL last %d frames (oldest first):"):format(math.min(#trail, TRAIL_PRINT)))
	local from = math.max(1, #trail - TRAIL_PRINT + 1)
	local t0 = trail[from] and trail[from].t or 0
	for i = from, #trail do
		local e = trail[i]
		logLine(("  +%.2fs | %.1f, %.1f, %.1f | hp %.1f | %s")
			:format(e.t - t0, e.x, e.y, e.z, e.hp, e.st))
	end
end

-- ---------------------------------------------------------------
-- TOUCH WATCHERS
-- ---------------------------------------------------------------
-- A kill brick deals damage on touch, and nothing in the log would name it.
-- Connect every part of the character and record what hits us.
local function clearTouches()
	for _, c in ipairs(touchConns) do pcall(function() c:Disconnect() end) end
	touchConns = {}
end

local function watchTouches(ch)
	clearTouches()
	if not ch then return end
	for _, part in ipairs(ch:GetDescendants()) do
		if part:IsA("BasePart") then
			local conn = part.Touched:Connect(function(other)
				if not other or not other.Parent then return end
				local last = touchLog[#touchLog]
				if last and last.name == other:GetFullName() then return end  -- dedupe
				touchLog[#touchLog + 1] = {name = other:GetFullName(),
					class = other.ClassName}
				while #touchLog > 40 do table.remove(touchLog, 1) end
				logLine(("TOUCHED | %s | class=%s | collide=%s | material=%s | my part=%s")
					:format(other:GetFullName(), other.ClassName,
						tostring(other.CanCollide), tostring(other.Material),
						part.Name))
			end)
			touchConns[#touchConns + 1] = conn
		end
	end
end

-- Is this point genuinely INSIDE a part? The first version used
-- GetPartBoundsInRadius and printed the distance to each part's CENTRE, which
-- for a huge world slab is 70+ studs - so it claimed "LANDING INSIDE SOLID |
-- dist=70.5" for a character standing normally on the floor. Bounds may overlap
-- a small sphere while the point is nowhere near the part; only a real
-- containment test answers the question.
local function pointInsidePart(p, pos)
	local ok, localPos = pcall(function() return p.CFrame:PointToObjectSpace(pos) end)
	if not ok or not localPos then return false end
	local ok2, size = pcall(function() return p.Size end)
	if not ok2 or not size then return false end
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	return math.abs(localPos.X) <= hx
		and math.abs(localPos.Y) <= hy
		and math.abs(localPos.Z) <= hz
end

-- is this point inside ANY collidable part? (used for the landing check)
local function pointInsideAnySolid(pos)
	local ch = LocalPlayer.Character
	local ok, parts = pcall(function()
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { ch }
		return workspace:GetPartBoundsInRadius(pos, 12, params)
	end)
	if not ok or not parts then return false end
	for _, p in ipairs(parts) do
		if p.CanCollide and pointInsidePart(p, pos) then return true, p end
	end
	return false
end

-- Find a spot near (x,z) that is standing room, not wall. Tries straight down
-- first, then a ring of offsets, nearest first.
local function findLandingSpot(x, z, fromY)
	local function try(cx, cz)
		local g = groundY(cx, cz, fromY)
		if not g then return nil end
		local probe = Vector3.new(cx, g + 3, cz)
		local inside, part = pointInsideAnySolid(probe)
		if not inside then return cx, cz, g end
		return nil, part
	end

	-- straight down first
	local cx, cz, g = try(x, z)
	if cx then return cx, cz, g, 0 end

	-- then outward, nearest ring first
	for ring = 1, LANDING_TRIES do
		local d = LANDING_OFFSET * ring
		local options = {
			{x + d, z}, {x - d, z}, {x, z + d}, {x, z - d},
			{x + d, z + d}, {x - d, z + d}, {x + d, z - d}, {x - d, z - d},
		}
		for _, o in ipairs(options) do
			local sx, sz, sg = try(o[1], o[2])
			if sx then return sx, sz, sg, ring * LANDING_OFFSET end
		end
	end
	return nil
end

local function isGuardNamed(name)
	local n = tostring(name):lower()
	return n:find("guard", 1, true) ~= nil or n:find("bounds", 1, true) ~= nil
end

local function checkLandingInside(pos)
	local ch = LocalPlayer.Character
	local ok, parts = pcall(function()
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { ch }
		return workspace:GetPartBoundsInRadius(pos, 8, params)
	end)
	if not ok or not parts then return end

	local inside, guards, seen = 0, 0, {}
	for _, p in ipairs(parts) do
		local name = p:GetFullName()
		if not seen[name] then
			seen[name] = true
			if p.CanCollide and pointInsidePart(p, pos) then
				inside = inside + 1
				logLine(("LANDING INSIDE SOLID | %s | class=%s | material=%s")
					:format(name, p.ClassName, tostring(p.Material)))
			end
			if isGuardNamed(name) then
				guards = guards + 1
				logLine(("GUARD REGION | %s | class=%s | collide=%s | dist=%.1f")
					:format(name, p.ClassName, tostring(p.CanCollide),
						(p.Position - pos).Magnitude))
			end
		end
	end
	if inside == 0 then
		logLine("LANDING CLEAR | not inside any collidable part")
	end
	if guards > 0 then
		logLine(("GUARD WARNING | landing is inside/next to %d guarded volume(s). ")
			:format(guards) .. "Guarded areas are plausibly where a kill or "
			.. "teleport-back comes from - try STOP_AT_BARRIER, or a shorter run.")
	end
end

-- Probe forward along the route at cruise altitude. A collidable part crossing
-- the path at cruise height is a wall, not terrain - and flying through it (with
-- or without noclip) is exactly the sort of thing an anti-cheat reacts to.
local function findBarriers(startPos, dir, total, cruiseY)
	local found, seen = {}, {}
	local d = 0
	while d < total do
		local from = Vector3.new(startPos.X + dir.X * d, cruiseY, startPos.Z + dir.Z * d)
		local ok, hit = pcall(function()
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { LocalPlayer.Character }
			return workspace:Raycast(from, dir * PROBE_LEN, params)
		end)
		if ok and hit and hit.Instance then
			local key = hit.Instance:GetFullName()
			if not seen[key] then
				seen[key] = true
				found[#found + 1] = {
					at = d + (hit.Position - from).Magnitude,
					name = key, class = hit.Instance.ClassName,
					collide = hit.Instance.CanCollide,
				}
			end
		end
		d = d + PROBE_LEN
	end
	return found
end

-- what is around the body when it dies
local function nearbyParts(pos, radius)
	local ch = LocalPlayer.Character
	local ok, parts = pcall(function()
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { ch }
		return workspace:GetPartBoundsInRadius(pos, radius, params)
	end)
	if not ok or not parts then return end
	local n = 0
	for _, p in ipairs(parts) do
		if n >= 8 then break end
		-- anything that can damage on touch is worth naming explicitly
		local touches = 0
		pcall(function() touches = #p:GetConnectedParts(false) end)
		logLine(("  NEAR | %s | class=%s | dist=%.1f | collide=%s | material=%s | parts=%d")
			:format(p:GetFullName(), p.ClassName, (p.Position - pos).Magnitude,
				tostring(p.CanCollide), tostring(p.Material), touches))
		n = n + 1
	end
	if n == 0 then logLine(("  NEAR | nothing within %d studs"):format(radius)) end
end

local function recordDeath(reason)
	if deathRecorded then return end
	deathRecorded = true
	local ch, h, r = getState()
	local pos = r and r.Position
	logLine("================ DEATH ================")
	logLine(("reason      | %s"):format(reason))
	logLine(("health      | %s"):format(h and h.Health or "no humanoid"))
	logLine(("position    | %s"):format(fmt(pos)))
	logLine(("velocity    | %s"):format(r and fmt(r.AssemblyLinearVelocity)))
	logLine(("state       | %s"):format(h and tostring(h:GetState()) or "?"))
	logLine(("floor of pt | %s"):format(deathFloor()))
	if flight then
		logLine(("phase       | %s | target %s"):format(flight.phase, fmt(flight.currentTarget)))
		logLine(("progress    | %.0f / %.0f studs | %.2fs"):format(
			flight.traveled, flight.total, flight.elapsed or 0))
	end
	-- the field log reported the death at the SPAWN, 2000 studs from where the
	-- flight finished. Make that discrepancy explicit instead of having to diff
	-- timestamps to notice it.
	if endPos and pos then
		local delta = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(endPos.X, 0, endPos.Z)).Magnitude
		logLine(("flight end  | %s"):format(fmt(endPos)))
		logLine(("end->death  | %.0f studs%s"):format(delta,
			delta > 200 and "  <- MOVED before we sampled: this is not the death site" or ""))
	end
	if pos then nearbyParts(pos, 30) end
	logLine(("touches seen| %d"):format(#touchLog))
	for i = math.max(1, #touchLog - 5), #touchLog do
		logLine(("  TOUCHED | %s | class=%s"):format(touchLog[i].name, touchLog[i].class))
	end
	logLine("--- last frames before death ----------------")
	dumpTrail()
	logLine("=======================================")
end

----------------------------------------------------------------
-- WATCHERS
----------------------------------------------------------------

local function watch(h)
	local function drop(c)
		if c then c:Disconnect() end
	end
	drop(diedConn); drop(healthConn); drop(stateConn)
	diedConn, healthConn, stateConn = nil, nil, nil
	if not h then return end

	diedConn = h.Died:Connect(function()
		recordDeath("Humanoid.Died fired")
		if flying then stopFlight("DIED") else restoreCollisions() end
	end)

	healthConn = h:GetPropertyChangedSignal("Health"):Connect(function()
		local hp = h.Health
		local _, _, hr = getState()

		-- A normal death arrives at 0: fall damage, the void, a kill brick. A
		-- large NEGATIVE value is a script SETTING it, and -1000 specifically is
		-- the documented exploit handler. Name it, so the next log is unambiguous.
		local external = hp <= -1
		if external then
			logLine(("EXTERNAL KILL | Health set to %s (not damage) - this is the "
				.. "-1000 HP exploit handler, per grok-v3-target-fix.lua L11/L812/L908")
				:format(tostring(hp)))
			logLine(("  maxHealth=%.0f | state=%s | pos=%s | was flying=%s")
				:format(h.MaxHealth, tostring(h:GetState()),
					fmt(hr and hr.Position), tostring(flying)))
		else
			logLine(("HP | %.1f | pos=%s | state=%s"):format(hp,
				fmt(hr and hr.Position), tostring(h:GetState())))
		end

		if hp <= 0 and flying then
			recordDeath(external and ("EXTERNAL KILL: Health set to %s"):format(hp)
				or "health reached zero")
			stopFlight("DIED")
		end
	end)

	stateConn = h.StateChanged:Connect(function(_, new)
		logLine(("STATE | -> %s | pos=%s"):format(tostring(new),
			select(3, getState()) and fmt(getState().Position) or "?"))
	end)
end

pcall(function()
	LocalPlayer.CharacterAdded:Connect(function()
		restoreCollisions()
		if flying then stopFlight("respawned") end
	end)
end)

----------------------------------------------------------------
-- FLIGHT ENGINE  (mirrors replicateFreefall)
----------------------------------------------------------------

local setStatus
local updateButtons

local function forceTransform(f, pos)
	local ch, _, r = getState()
	if not (ch and ch.Parent and r and r.Parent) then return false end
	-- yaw preserved from Orientation, as the reference does
	local yaw = math.rad(r.Orientation.Y)
	local cf = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
	-- PivotTo the WHOLE model first, then pin the root. Moving only the root
	-- leaves the limbs behind for physics to snap back - a sustained fight.
	pcall(function() ch:PivotTo(cf) end)
	r.CFrame = cf
	-- zero horizontal, PRESERVE vertical: the logs show Y climbing under
	-- gravity (-8.2, -13.1, -19.6, -24.5), so overwriting it is a lie
	pcall(function()
		r.AssemblyLinearVelocity = Vector3.new(0, r.AssemblyLinearVelocity.Y, 0)
	end)
	return true
end

local function unbind()
	pcall(function() RunService:UnbindFromRenderStep(RENDER_STEP_NAME) end)
end

stopFlight = function(reason)
	local f = flight
	if not flying and not f then return end
	flying = false
	flight = nil
	restoreCollisions()

	local ch, h, r = getState()
	if h and f and f.touchedAutoRotate then
		-- only restore what we actually changed
		pcall(function() h.AutoRotate = f.autoRotate end)
	end
	if r then
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
		end)
	end

	if reason then
		if reason ~= "cancelled" then logLine(("ABORTED | %s"):format(reason)) end
		if setStatus then
			setStatus("ABORTED: " .. tostring(reason), Color3.fromRGB(255, 120, 120))
		end
	elseif f then
		local landed, finalY = 0, f.startPos.Y
		if r then
			local p = r.Position
			landed = (Vector3.new(p.X - f.startPos.X, 0, p.Z - f.startPos.Z)).Magnitude
			finalY = p.Y
			endPos = p
		end
		lastRun = {studs = landed, secs = f.elapsed or 0}
		logLine(("DONE | %.0f studs | %.2fs | Y %.1f"):format(landed, f.elapsed or 0, finalY))
		if r then checkLandingInside(r.Position) end
		-- keep watching: the field death came in the same second as DONE, and we
		-- used to unbind exactly here
		watchUntil = os.clock() + POST_WATCH_S
		logLine(("post-flight watch | %s | %.1fs"):format(fmt(r and r.Position), POST_WATCH_S))
		if setStatus then
			setStatus(("landed #%d | %.0f studs | watching %.0fs")
				:format(flightCount, landed, POST_WATCH_S),
				Color3.fromRGB(120, 255, 150))
		end
	end
	lastFlightEndAt = os.clock()
	logLine(("cooldown | %.0fs before the next flight (back-to-back flights are when "
		.. "the kills happened)"):format(COOLDOWN_AFTER_FLIGHT))

	-- on a clean landing the render step stays bound for the watch window; on any
	-- abort or death we stop immediately
	if reason or not f then
		unbind()
		clearTouches()
		watchUntil = nil
	end
	if updateButtons then updateButtons() end
end

-- one render frame. Mirrors the reference's structure: sticky target first,
-- then correction-fight check, then the phase machine.
local function renderStep(dt)
	local f = flight

	-- ---- post-flight watch ------------------------------------------
	-- The field log's death landed in the same second as DONE, 2000 studs from
	-- where the flight finished. Sampling once at Died is therefore useless, so
	-- keep recording after arrival and print the trail if anything goes wrong.
	if not flying then
		if watchUntil then
			local _, wh, wr = getState()
			if wh and wr then
				recordTrail(wh, wr)
				if wh.Health <= 0 then
					recordDeath("died during the post-flight watch")
					watchUntil = nil
					clearTouches()
					unbind()
					return
				end
			end
			if os.clock() >= watchUntil then
				logLine("post-flight watch ended | nothing happened")
				watchUntil = nil
				clearTouches()
				unbind()
			end
		end
		return
	end

	if not f or f.token ~= token then return end

	local ch, h, r = getState()
	if not (ch and ch.Parent and h and h.Parent and r and r.Parent) then
		stopFlight("character disappeared")
		return
	end
	if h.Health <= 0 or h:GetState() == Enum.HumanoidStateType.Dead then
		recordDeath("render step saw a dead humanoid")
		stopFlight("Humanoid Dead")
		return
	end

	f.elapsed = os.clock() - f.t0
	recordTrail(h, r)

	-- void guard
	local curY = r.Position.Y
	if curY < deathFloor() + VOID_MARGIN then
		stopFlight("hit the void guard")
		return
	end

	-- 1. always re-apply the sticky target first, exactly like the reference
	if f.currentTarget then
		forceTransform(f, f.currentTarget)

		local err = (r.Position - f.currentTarget).Magnitude
		if err > CORRECTION_TOLERANCE then
			f.errors = f.errors + 1
			if f.errors == 1 or f.errors % 4 == 0 then
				logLine(("CORRECTION FIGHT | err=%.1f | frames=%d | actual=%s | target=%s")
					:format(err, f.errors, fmt(r.Position), fmt(f.currentTarget)))
			end
			if f.errors >= MAX_CONSECUTIVE_ERRORS then
				recordDeath(("sustained correction %.1f studs - physics is winning"):format(err))
				stopFlight(("sustained correction %.1f studs"):format(err))
				return
			end
		else
			f.errors = 0
		end
	end

	if f.elapsed > MAX_FLIGHT_S then
		stopFlight("timeout")
		return
	end

	-- 2. phase machine

	-- ---- phase 1: CLIMB. Vertical only - no horizontal teleport at ground level.
	-- Both -1000 kills happened in the old combined launch, teleporting 78 studs
	-- sideways per frame at ~9 studs altitude while the humanoid was still in a
	-- WALKING state.
	if f.phase == "climb" then
		f.frame = f.frame + 1
		local alpha = math.min(f.frame / CLIMB_FRAMES, 1)
		local y = f.startPos.Y + (f.cruiseY - f.startPos.Y) * alpha
		f.currentTarget = Vector3.new(f.startPos.X, y, f.startPos.Z)
		forceTransform(f, f.currentTarget)

		if f.frame >= CLIMB_FRAMES then
			local st = h:GetState()
			local airborne = (st == Enum.HumanoidStateType.Freefall)
				or (st == Enum.HumanoidStateType.Jumping)
				or (st == Enum.HumanoidStateType.FallingDown)
			if not airborne and (f.airWait or 0) < AIRBORNE_WAIT then
				-- hold at cruise until the humanoid is genuinely off the ground;
				-- travelling horizontally while it thinks it is walking is the
				-- window that got us killed
				f.airWait = (f.airWait or 0) + 1
				if f.airWait == 1 then
					logLine(("WAIT AIRBORNE | state=%s | holding at Y=%.1f (max %d frames)")
						:format(tostring(st), f.cruiseY, AIRBORNE_WAIT))
				end
				return
			end
			if not airborne then
				logLine(("WARNING | still %s after %d frames - travelling anyway")
					:format(tostring(st), AIRBORNE_WAIT))
			else
				logLine(("AIRBORNE | state=%s | Y=%.1f | starting horizontal travel")
					:format(tostring(st), r.Position.Y))
			end
			f.phase = "launch"
			f.frame = 0
		end
		return
	end

	-- ---- phase 2: LAUNCH ramp, now that the humanoid is airborne.
	if f.phase == "launch" then
		f.frame = f.frame + 1
		local alpha = math.min(f.frame / f.rampFrames, 1)
		f.traveled = math.min(f.traveled + STEP_SIZE, f.total)
		local xz = f.startPos + f.dir * f.traveled
		local y  = f.cruiseY
		f.currentTarget = Vector3.new(xz.X, y, xz.Z)
		forceTransform(f, f.currentTarget)
		if f.frame >= f.rampFrames then
			f.phase = "freefall"
			f.freefallClock = os.clock()
			-- OFF by default. debug.lua's reference does ChangeState(Freefall) here,
			-- but grok-v3-target-fix.lua names ChangeState as one of the two things
			-- that provoke the -1000 HP exploit handler, and we were killed with
			-- exactly -1000. Let the humanoid reach Freefall on its own.
			if TOUCH_HUMANOID_STATE then
				pcall(function() h:ChangeState(Enum.HumanoidStateType.Freefall) end)
			end
			logLine(("FREEFALL START | pos=%s | state=%s | ChangeState=%s")
				:format(fmt(r.Position), tostring(h:GetState()),
					tostring(TOUCH_HUMANOID_STATE)))
		end
		return
	end

	if f.phase == "freefall" then
		checkAhead(r.Position, f.dir)
		local cur = r.Position
		local remain = (Vector3.new(f.target.X, 0, f.target.Z)
			- Vector3.new(cur.X, 0, cur.Z)).Magnitude

		if remain <= STOP_WITHIN or f.traveled >= f.total then
			f.phase = "drop"
			f.descent = 0
			f.descentFrom = cur

			-- Where exactly are we putting down? The 4000-stud run landed INSIDE
			-- a guard wall and died there, so look before dropping: straight down
			-- first, then a ring of nearby clear spots.
			local lx, lz, lg, shifted = cur.X, cur.Z, groundY(cur.X, cur.Z, cur.Y), 0
			if LANDING_CLEAR then
				local sx, sz, sg, sh = findLandingSpot(cur.X, cur.Z, cur.Y)
				if sx then
					lx, lz, lg, shifted = sx, sz, sg, sh or 0
					if shifted > 0 then
						logLine(("LANDING SHIFT | straight down is solid; moving %.0f studs "
							.. "to %s (clear)"):format(shifted, fmt(Vector3.new(sx, sg, sz))))
					end
				else
					-- nowhere clear. Do NOT drop: landing in a wall is what killed
					-- us. Hold altitude and report.
					logLine(("LANDING BLOCKED | solid geometry straight down and for "
						.. "%d studs around, no clear ground - holding altitude, not dropping")
						:format(LANDING_OFFSET * LANDING_TRIES))
					f.phase = "hold"
					return
				end
			end

			f.landX, f.landZ, f.landGround = lx, lz, lg
			f.destGround = lg
			logLine(("DROP | from=%s | groundUnder=%s | target=%s")
				:format(fmt(cur), lg and ("%.1f"):format(lg) or "NONE",
					fmt(Vector3.new(lx, (lg or cur.Y) + 3, lz))))
			return
		end

		local step = STEP_SIZE
		if remain < CRUISE_LEAD then
			step = math.clamp(remain * 0.5, STEP_MIN, STEP_SIZE)
		end
		f.traveled = f.traveled + step
		local xz = f.startPos + f.dir * f.traveled
		f.currentTarget = Vector3.new(xz.X, f.cruiseY, xz.Z)
		forceTransform(f, f.currentTarget)
		return
	end

	-- destination is solid: hold altitude rather than embed the character in it
	if f.phase == "hold" then
		f.currentTarget = Vector3.new(r.Position.X, f.cruiseY, r.Position.Z)
		forceTransform(f, f.currentTarget)
		f.holdFrames = (f.holdFrames or 0) + 1
		if f.holdFrames >= 3 then
			stopFlight("landing was blocked by solid geometry - held altitude")
		end
		return
	end

	if f.phase == "drop" then
		if not f.destGround then
			-- do NOT let go with nothing underneath: that is how v1 killed people
			logLine("no ground under the destination - holding position, not dropping")
			stopFlight(nil)
			return
		end
		f.descent = f.descent + 1
		local alpha = math.min(f.descent / DESCENT_FRAMES, 1)
		local from, destY = f.descentFrom, f.destGround + 3
		local tx = f.landX or f.target.X
		local tz = f.landZ or f.target.Z
		f.currentTarget = Vector3.new(
			from.X + (tx - from.X) * alpha,
			from.Y + (destY - from.Y) * alpha,
			from.Z + (tz - from.Z) * alpha)
		forceTransform(f, f.currentTarget)
		if f.descent >= DESCENT_FRAMES then
			logLine(("LANDING WATCH start | pos=%s"):format(fmt(select(3, getState()).Position)))
			stopFlight(nil)
		end
		return
	end
end

----------------------------------------------------------------
-- START
----------------------------------------------------------------

local function startFlight(requested)
	if flying then return false, "already flying" end

	-- rate limit: back-to-back flights are when the kills happened
	local cd = cooldownRemaining()
	if cd > 0 then
		logLine(("REFUSED | rate limit - %.0fs left before another flight")
			:format(cd))
		return false, ("rate limit: %.0fs remaining"):format(cd)
	end

	local ch, h, r = getState()
	if not (ch and h and r) then return false, "no character" end
	if h.Health <= 0 then return false, "dead" end
	if h:GetState() == Enum.HumanoidStateType.Physics then return false, "ragdolled" end

	local total = tonumber(requested)
	if total == nil or total ~= total then return false, "enter a number" end
	if total < MIN_STUDS then return false, ("needs at least %d studs"):format(MIN_STUDS) end
	if total > MAX_STUDS then total = MAX_STUDS end

	local dir = travelDir(r, h)
	if not dir then return false, "no travel direction" end

	local scan = scanPath(r.Position, dir, total)
	if scan.missingAt and not ALLOW_VOID then
		return false, ("no ground %d studs that way - refused"):format(math.floor(scan.missingAt))
	end
	if not scan.maxGround and not ALLOW_VOID then
		return false, "no ground anywhere on that heading - refused"
	end

	local cruiseY = r.Position.Y + 13
	if scan.maxGround then
		cruiseY = math.max(scan.maxGround + CLEARANCE, r.Position.Y + 13)
	end

	-- ---- the altitude cap -------------------------------------------------
	-- "do not fly too high". Every survival so far cruised at 93-131; the run
	-- that died was pushed to 209 by tall ground on the route.
	local cap = r.Position.Y + MAX_CRUISE_RISE
	local cappedTo = nil
	if cruiseY > cap then
		local limit = cap - CLEARANCE
		local blockedAt = nil
		for _, smp in ipairs(scan.samples) do
			if smp.g and smp.g > limit then blockedAt = smp.d break end
		end

		if HIGH_TERRAIN == "refuse" and blockedAt then
			return false, ("would need to climb to %.0f but MAX_CRUISE_RISE caps it at %.0f - refused")
				:format(cruiseY, cap)
		elseif HIGH_TERRAIN == "stop_short" and blockedAt then
			local newTotal = math.max(MIN_STUDS, blockedAt - SCAN_STEP)
			logLine(("HIGH TERRAIN | ground reaches %.1f at %.0f studs; the cap is %.0f.")
				:format(scan.maxGround, blockedAt, cap))
			logLine(("  stopping short at %.0f studs instead of climbing to %.0f")
				:format(newTotal, cruiseY))
			total = math.min(total, newTotal)
			-- re-scan the shortened route so the landing target is right
			scan = scanPath(r.Position, dir, total)
			cappedTo = newTotal
		elseif HIGH_TERRAIN == "ignore" then
			-- fly the original altitude, knowingly above the cap
		else
			cruiseY = cap
		end
		cruiseY = math.min(cruiseY, cap)
	end

	-- anything solid crossing the route at cruise altitude?
	local barriers = {}
	if SCAN_BARRIER then
		barriers = findBarriers(r.Position, dir, total, cruiseY)
	end
	local stoppedShort = nil
	if STOP_AT_BARRIER then
		local nearest = nil
		for _, b in ipairs(barriers) do
			if b.collide and (not nearest or b.at < nearest.at) then nearest = b end
		end
		if nearest and nearest.at > BARRIER_MARGIN then
			stoppedShort = nearest.at - BARRIER_MARGIN
			total = math.min(total, stoppedShort)
		end
	end

	local startPos = r.Position
	local autoRotate = h.AutoRotate
	if TOUCH_AUTOROTATE then
		pcall(function() h.AutoRotate = false end)
	end
	if NOCLIP then setCollisions(false) end

	token = token + 1
	flying = true
	flight = {
		token = token, frame = 0, phase = "climb", airWait = 0,
		dir = dir, startPos = startPos, target = startPos + dir * total,
		total = total, traveled = 0, t0 = os.clock(), elapsed = 0,
		cruiseY = cruiseY, rampFrames = 5,
		currentTarget = startPos, errors = 0, lowestY = startPos.Y,
		autoRotate = autoRotate, destGround = scan.destGround, scan = scan,
		barriers = barriers, touchedAutoRotate = TOUCH_AUTOROTATE,
	}
	flightCount = flightCount + 1
	lastObstacle = nil
	deathRecorded = false

	local gap = lastFlightEndAt and (os.clock() - lastFlightEndAt) or nil
	logLine(("START #%d | %s | total=%.0f | start=%s | cruiseY=%.1f | noclip=%s | dir=(%.2f, %.2f)")
		:format(flightCount, DIR_MODE, total, fmt(startPos), cruiseY, tostring(NOCLIP), dir.X, dir.Z))
	if gap then
		logLine(("  gap since last flight | %.1fs%s"):format(gap,
			gap < 10 and "  <- back-to-back; the exploit handler may count repeats" or ""))
	end
	logLine(("  maxHealth=%.0f | state-tampering: ChangeState=%s AutoRotate=%s")
		:format(h.MaxHealth, tostring(TOUCH_HUMANOID_STATE), tostring(TOUCH_AUTOROTATE)))
	logLine(("  altitude | startY=%.1f | cruiseY=%.1f | rise=%.1f | cap=%.0f%s")
		:format(startPos.Y, cruiseY, cruiseY - startPos.Y, cap,
			cappedTo and ("  (high terrain: shortened to %.0f studs)"):format(cappedTo) or ""))
	if scan.maxGround then
		logLine(("  scanned | maxGround=%.1f | clearance=%.1f | destGround=%s")
			:format(scan.maxGround, cruiseY - scan.maxGround,
				scan.destGround and ("%.1f"):format(scan.destGround) or "NONE"))
	end
	if #barriers > 0 then
		logLine(("  barriers | %d crossing the route at cruise altitude:"):format(#barriers))
		for _, b in ipairs(barriers) do
			logLine(("    BARRIER | %s | class=%s | collide=%s | at ~%.0f studs")
				:format(b.name, b.class, tostring(b.collide), b.at))
		end
		if stoppedShort then
			logLine(("  stopping short at %.0f studs to stay clear"):format(total))
		else
			logLine("  (report only - flying through them anyway; set STOP_AT_BARRIER = true to stop)")
		end
	elseif SCAN_BARRIER then
		logLine("  barriers | none crossing the route at cruise altitude")
	end
	logLine(("  void floor=%.1f | guard at %.1f"):format(deathFloor(), deathFloor() + VOID_MARGIN))

	watch(h)
	watchTouches(ch)
	clearTrail()
	endPos = nil
	watchUntil = nil
	unbind()
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_STEP_PRIORITY, renderStep)
	return true, total
end

----------------------------------------------------------------
-- UI
----------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = GUI_NAME
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 250, 0, 262)
frame.Position = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
frame.BackgroundTransparency = 0.12
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(150, 90, 255)
stroke.Thickness = 2
stroke.Transparency = 0.3
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 0, 22)
title.Position = UDim2.new(0, 12, 0, 6)
title.BackgroundTransparency = 1
title.Text = "FREE FALL TRAVEL v3"
title.TextColor3 = Color3.fromRGB(170, 120, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 26)
closeBtn.Position = UDim2.new(1, -32, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 15
closeBtn.Parent = frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

local function mkLabel(y, text)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -24, 0, 13)
	l.Position = UDim2.new(0, 12, 0, y)
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Color3.fromRGB(150, 155, 165)
	l.Font = Enum.Font.Gotham
	l.TextSize = 10
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = frame
	return l
end

mkLabel(28, "DISTANCE  (studs)")
local inputBox = Instance.new("TextBox")
inputBox.Size = UDim2.new(1, -24, 0, 26)
inputBox.Position = UDim2.new(0, 12, 0, 42)
inputBox.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
inputBox.BorderSizePixel = 0
inputBox.Text = tostring(DEFAULT_STUDS)
inputBox.PlaceholderText = tostring(DEFAULT_STUDS)
inputBox.ClearTextOnFocus = false
inputBox.TextColor3 = Color3.fromRGB(235, 245, 255)
inputBox.Font = Enum.Font.Code
inputBox.TextSize = 15
inputBox.TextXAlignment = Enum.TextXAlignment.Center
inputBox.Parent = frame
Instance.new("UICorner", inputBox).CornerRadius = UDim.new(0, 6)

local flyBtn = Instance.new("TextButton")
flyBtn.Size = UDim2.new(1, -24, 0, 32)
flyBtn.Position = UDim2.new(0, 12, 0, 72)
flyBtn.BackgroundColor3 = Color3.fromRGB(95, 55, 170)
flyBtn.Text = "FLY"
flyBtn.TextColor3 = Color3.fromRGB(235, 245, 255)
flyBtn.Font = Enum.Font.GothamBold
flyBtn.TextSize = 14
flyBtn.Parent = frame
Instance.new("UICorner", flyBtn).CornerRadius = UDim.new(0, 8)

local noclipBtn = Instance.new("TextButton")
noclipBtn.Size = UDim2.new(0, 86, 0, 24)
noclipBtn.Position = UDim2.new(0, 12, 0, 108)
noclipBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
noclipBtn.Text = "NOCLIP: OFF"
noclipBtn.TextColor3 = Color3.fromRGB(190, 190, 200)
noclipBtn.Font = Enum.Font.GothamBold
noclipBtn.TextSize = 11
noclipBtn.Parent = frame
Instance.new("UICorner", noclipBtn).CornerRadius = UDim.new(0, 6)

-- CLEAR matters: the log accumulates across flights, so a pasted log can carry
-- stale lines from an earlier run and mislead whoever reads it.
local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, 58, 0, 24)
clearBtn.Position = UDim2.new(0, 102, 0, 108)
clearBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 60)
clearBtn.Text = "CLEAR"
clearBtn.TextColor3 = Color3.fromRGB(230, 220, 190)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 11
clearBtn.Parent = frame
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.new(0, 74, 0, 24)
copyBtn.Position = UDim2.new(1, -86, 0, 108)
copyBtn.BackgroundColor3 = Color3.fromRGB(50, 70, 110)
copyBtn.Text = "COPY LOG"
copyBtn.TextColor3 = Color3.fromRGB(210, 225, 255)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 11
copyBtn.Parent = frame
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 6)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -24, 0, 118)
status.Position = UDim2.new(0, 12, 0, 138)
status.BackgroundTransparency = 1
status.Text = "ready"
status.TextColor3 = Color3.fromRGB(160, 160, 160)
status.Font = Enum.Font.Code
status.TextSize = 10
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = frame

setStatus = function(text, color)
	status.Text = text
	status.TextColor3 = color or Color3.fromRGB(160, 160, 160)
end

local readoutAt = 0
local function readout(f)
	local _, _, r = getState()
	if not r then return end
	local cur = r.Position
	local fromStart = (Vector3.new(cur.X - f.startPos.X, 0, cur.Z - f.startPos.Z)).Magnitude
	local spd = f.elapsed > 0 and (fromStart / f.elapsed) or 0
	local gy = groundY(cur.X, cur.Z, cur.Y)
	local clr = gy and ("+%.0f"):format(cur.Y - gy) or "--"
	setStatus(("%s | %.0f/%.0f | err %d\n%.0f studs/s | Y %.1f | clr %s")
		:format(f.phase, fromStart, f.total, f.errors, spd, cur.Y, clr),
		Color3.fromRGB(200, 180, 255))
end

-- wrap the render step for the readout and so an error can never leave the
-- loop bound with noclip still applied
local baseStep = renderStep
renderStep = function(dt)
	local ok, err = pcall(baseStep, dt)
	if not ok then
		logLine("SCRIPT ERROR in render step: " .. tostring(err))
		stopFlight("error: " .. tostring(err))
		return
	end
	local f = flight
	if not f then return end
	local now = os.clock()
	if now - readoutAt > 0.1 then
		readoutAt = now
		readout(f)
	end
end

----------------------------------------------------------------
-- WIRING
----------------------------------------------------------------

local function sanitise(text)
	local out, dot = {}, false
	for i = 1, #text do
		local c = text:sub(i, i)
		if c:match("%d") then out[#out + 1] = c
		elseif c == "." and not dot then dot = true; out[#out + 1] = c end
	end
	return table.concat(out)
end

-- Permanent, cheap: only rewrites the button when the cooldown state changes, so
-- the player can see the rate limit rather than wondering why a click did nothing.
RunService.Heartbeat:Connect(function()
	if flying then return end
	local cd = cooldownRemaining()
	if cd > 0 then
		flyBtn.Text = ("COOLDOWN %.0fs"):format(cd)
		flyBtn.BackgroundColor3 = Color3.fromRGB(70, 60, 40)
		cooldownShown = true
	elseif cooldownShown then
		cooldownShown = false
		updateButtons()
	end
end)

updateButtons = function()
	local n = tonumber(inputBox.Text)
	if flying then
		flyBtn.Text = "CANCEL"
		flyBtn.BackgroundColor3 = Color3.fromRGB(150, 60, 60)
	elseif n == nil then
		flyBtn.Text = "FLY"
		flyBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
	elseif n > MAX_STUDS then
		flyBtn.Text = ("FLY  %d  (max)"):format(MAX_STUDS)
		flyBtn.BackgroundColor3 = Color3.fromRGB(120, 90, 40)
	else
		flyBtn.Text = ("FLY  %g studs"):format(n)
		flyBtn.BackgroundColor3 = Color3.fromRGB(95, 55, 170)
	end
	if NOCLIP then
		noclipBtn.Text = "NOCLIP: ON"
		noclipBtn.BackgroundColor3 = Color3.fromRGB(120, 70, 40)
	else
		noclipBtn.Text = "NOCLIP: OFF"
		noclipBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	end
end

local function doFly()
	if flying then stopFlight("cancelled"); return end
	local n = tonumber(inputBox.Text)
	if n == nil then
		setStatus("invalid: enter a number", Color3.fromRGB(255, 120, 120))
		return
	end
	local ok, res = startFlight(n)
	if ok then
		setStatus(("flying %g studs..."):format(res), Color3.fromRGB(200, 180, 255))
	else
		logLine("REFUSED | " .. tostring(res))
		setStatus("refused: " .. tostring(res), Color3.fromRGB(255, 120, 120))
	end
	updateButtons()
end

flyBtn.MouseButton1Click:Connect(doFly)

noclipBtn.MouseButton1Click:Connect(function()
	if flying then
		setStatus("cannot change noclip mid-flight", Color3.fromRGB(255, 200, 120))
		return
	end
	NOCLIP = not NOCLIP
	if not NOCLIP then restoreCollisions() end
	updateButtons()
end)

clearBtn.MouseButton1Click:Connect(function()
	logLines = {}
	logLine("log cleared")
	setStatus("log cleared", Color3.fromRGB(230, 220, 190))
end)

copyBtn.MouseButton1Click:Connect(function()
	local payload = table.concat(logLines, "\n")
	local ok = pcall(function() setclipboard(payload) end)
	setStatus(ok and ("copied %d log lines - paste them back"):format(#logLines)
		or "copy failed; log is in the box below", Color3.fromRGB(120, 255, 150))
	if not ok then
		status.Text = payload:sub(-900)
	end
end)

inputBox:GetPropertyChangedSignal("Text"):Connect(function()
	local s = sanitise(inputBox.Text)
	if s ~= inputBox.Text then inputBox.Text = s end
	updateButtons()
end)

inputBox.FocusLost:Connect(function(enter) if enter then doFly() end end)

closeBtn.MouseButton1Click:Connect(function()
	token = token + 1
	stopFlight("gui closed")
	unbind()
	if diedConn then diedConn:Disconnect() end
	if healthConn then healthConn:Disconnect() end
	if stateConn then stateConn:Disconnect() end
	screenGui:Destroy()
end)

local dragging, dragStart, startPos, dragConn = false, nil, nil, nil
frame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true; dragStart = input.Position; startPos = frame.Position
	end
end)
frame.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)
dragConn = UserInputService.InputChanged:Connect(function(input)
	if dragging and dragConn and (input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
			startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)

updateButtons()
logLine("LOADED v3 | render step priority " .. tostring(RENDER_STEP_PRIORITY))
setStatus(("ready | %d/frame | pivot+renderstep\nclears terrain by %d | void guard %d")
	:format(STEP_SIZE, CLEARANCE, VOID_MARGIN))
