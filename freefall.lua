--[[=========================================================================
	FREE FALL TRAVEL  —  position-driven flight, 2000 studs by default

	Replicates the mechanism in logs/cosmic.log, lightdark.log and titan.log
	(produced by admin_v6_escape.lua). Those three runs covered 3,683 / 14,764 /
	6,676 studs at an apparent 3,824 / 4,519 / 4,810 studs/s and were never
	pulled back. This script is the same trick, generalised.

	------------------------------------------------------------------
	WHY IT DOES NOT RUBBERBAND
	------------------------------------------------------------------
	Every frame it writes a POSITION and claims NO horizontal velocity:

	    r.CFrame = CFrame.new(nextPos, nextPos + dir)     -- I am 78 studs over there
	    r.AssemblyLinearVelocity = Vector3.new(0, -10, 0) -- ...and I have no
	                                                        --    sideways velocity
	    r.AssemblyAngularVelocity = Vector3.zero

	The horizontal components are literally 0, which is what the logs show:

	    dP=(-122.8, 13.1, -0.1)  dist=123.54  pSpd=12095.1
	    vel=(0.0, -8.2, 0.0)     vMag=8.2     vRatio=1479.5x

	It moved 123 studs sideways in one frame while claiming 0.0 horizontal
	velocity. The huge vRatio is the measurement of that gap.

	The -8/-10/-12 downward claim is deliberate: it matches what gravity actually
	produces (the logs show -8.2, -13.1, -19.6, -24.5), so the server sees an
	ordinary FALLING character. The Humanoid's Freefall state then explains the
	downward velocity by itself, and a falling character with no sideways velocity
	is completely unremarkable — so there is nothing to correct.

	Rubberbanding is a function of the VELOCITY CLAIM, not the distance. Claim 330
	studs/s horizontally and the server reconciles every frame; claim 0 and it
	never has anything to reconcile. That is the whole difference, and it is why
	this travels 2,000 studs where a forced-velocity run backs off to MIN_SPEED.

	------------------------------------------------------------------
	SAFETY (v2 - this is what killed the first run)
	------------------------------------------------------------------
	The escape script had TWO properties that the first version of this file
	dropped, and either one can kill you:

	  1. a FIXED HIGH cruise altitude (CRUISE_Y = 112.5), so it flew OVER the
	     terrain rather than through it. The first version used start Y + 13.
	  2. a KNOWN landing pad (FOREST_LANDING, Y = 71). The first version aimed at
	     an arbitrary point 2000 studs away, and if that point had no ground it
	     left the character floating at cruise altitude, zeroed its velocity and
	     let it fall out of the world.

	So before flying, this version SCANS the whole path with a downward raycast:
	  * if the ground runs out anywhere on the route it REFUSES, and says where;
	  * cruise altitude is max(ground) + CLEARANCE, so it always clears terrain;
	  * the descent lands on the ground that was found at the destination.
	Noclip is now OFF by default - flying over the terrain does not need it.

	------------------------------------------------------------------
	WHAT ELSE THE LOGS SHOWED
	------------------------------------------------------------------
	* Speed is just STEP_SIZE x framerate: 78 * 60 = 4,680 studs/s theoretical vs
	  4,519 observed on lightdark (0.97 of one step per frame).
	* Y is held at cruise (logs: 112.5) while the velocity claims falling — a
	  disguised fall. Freefall is a CONSEQUENCE, never forced: this script never
	  calls ChangeState. PlatformStand is left false, as the escape script's
	  header requires.
	* Collisions are off for the flight (every BasePart CanCollide=false, originals
	  saved and restored) so terrain cannot snag a 78-stud step.
	* The approach shrinks so it does not overshoot:
	      if remain < 120 then step = math.clamp(remain * 0.5, 28, STEP_SIZE) end
	* The descent is stepped over 3 frames — the escape script's comment is
	  "Soft descent at Forest (no 2000+ stud snap)", i.e. a single huge snap was
	  tried once and evidently failed.
	* MAX_FLIGHT_S bounds the whole thing.

	UI: distance box (default 2000) + FLY button + X to destroy. X also aborts a
	flight in progress and restores collisions — never leave noclip on.
	No dependencies; does not require EggGoToUI.
=========================================================================]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local playerGui   = LocalPlayer:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------

local DEFAULT_STUDS = 2000    -- the target
local MIN_STUDS     = 10      -- below this there is nothing to do
local MAX_STUDS     = 20000   -- clamp, so a stray keystroke cannot fling you away

local STEP_SIZE     = 78      -- studs per frame (admin_v6_escape STEP_SIZE)
local RAMP_FRAMES   = 5       -- ease-in, so we never start with a wrong-way step
local RISE_STUDS    = 13      -- minimum climb above the start Y during the ramp
local CRUISE_LEAD   = 120     -- shrink the step when this close to the target
local STEP_MIN      = 28      -- smallest shrunken step
local STOP_WITHIN   = 25      -- treat this as arrived
local DESCENT_FRAMES = 3      -- stepped descent, not one drop
local MAX_FLIGHT_S  = 2.5     -- hard bound on the whole flight

-- path scan: the thing that stops us flying off the edge of the world
local SCAN_STEP      = 39     -- studs between samples (half a flight step)
local SCAN_UP        = 200    -- raycast starts this far above the start position
local SCAN_DOWN      = 1000   -- and looks this far down
local CLEARANCE      = 25     -- cruise this far above the HIGHEST ground on the route
local ALLOW_VOID     = false  -- true = fly even if the ground runs out (dangerous)
local VOID_MARGIN    = 100    -- abort if we get this close to FallenPartsDestroyHeight

local ZERO_HORIZONTAL = true  -- THE trick: claim no sideways velocity
local FALL_VELOCITY   = -10   -- and claim a plausible falling one (admin: -10)

local NOCLIP        = false   -- OFF by default: we fly OVER terrain now, and a
                              -- forgotten noclip is how you fall through the world
local FACE_TRAVEL   = true    -- CFrame.new(pos, pos+dir) — face the way we go

--   "facing"  the character's look direction (default)
--   "camera"  where the camera points
local DIR_MODE = "facing"

local GUI_NAME = "FreeFallTravelV1"

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

local flying    = false
local token     = 0            -- bumping this aborts any in-flight run
local flight    = nil          -- per-run state table
local flightConn = nil         -- Heartbeat connection while flying

local savedCollisions = {}     -- [part] = original CanCollide
local diedConn  = nil          -- Humanoid.Died watcher for the current character
local lastDeath = nil          -- where a death happened, for the status line
local flightCount = 0
local totalStuds  = 0
local lastRun = {studs = 0, secs = 0}  -- declared here: stopFlight reads it

-- Forward-declared on purpose: a `local` introduced LATER in this chunk is not
-- visible to functions defined above it, and the reference would silently become
-- a global instead.
local setStatus
local stopFlight

----------------------------------------------------------------
-- CHARACTER HELPERS
----------------------------------------------------------------

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

local function travelDir(r)
	if DIR_MODE == "camera" then
		local cam = workspace.CurrentCamera
		return flatten(cam and cam.CFrame.LookVector) or flatten(r.CFrame.LookVector)
	end
	return flatten(r.CFrame.LookVector)
end

----------------------------------------------------------------
-- NOCLIP (setCharacterCollisions, admin_v6_escape L85)
----------------------------------------------------------------

local function setCollisions(enable)
	local ch = LocalPlayer.Character
	if not ch then return end
	for _, desc in ipairs(ch:GetDescendants()) do
		if desc:IsA("BasePart") then
			if not enable then
				if savedCollisions[desc] == nil then
					savedCollisions[desc] = desc.CanCollide
				end
				desc.CanCollide = false
			else
				if savedCollisions[desc] ~= nil then
					desc.CanCollide = savedCollisions[desc]
					savedCollisions[desc] = nil
				else
					desc.CanCollide = true
				end
			end
		end
	end
end

local function restoreCollisions()
	-- nothing was ever changed: do not touch collision at all. (Forcing
	-- CanCollide = true on parts we never saved would break things like
	-- accessories that are legitimately non-collidable.)
	if next(savedCollisions) == nil then return end
	for part in pairs(savedCollisions) do
		pcall(function() part.CanCollide = savedCollisions[part] end)
		savedCollisions[part] = nil
	end
	setCollisions(true)
end

----------------------------------------------------------------
-- GROUND FINDER (for the stepped descent)
----------------------------------------------------------------

-- Downward raycast at (x, z). fromY is where the ray starts looking; it scans
-- SCAN_UP above that and SCAN_DOWN below. Returns the ground height or nil when
-- there is nothing there at all - which is the condition that killed the first
-- version, so it is treated as a hard stop rather than a shrug.
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

local function deathFloor()
	local ok, v = pcall(function() return workspace.FallenPartsDestroyHeight end)
	if ok and type(v) == "number" then return v end
	return -500
end

-- Walk the whole route before committing. Returns the scan table.
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
	local dest = samples[#samples]
	return {
		samples   = samples,
		maxGround = maxGround,
		missingAt = missingAt,
		destGround = dest and dest.g or nil,
	}
end

----------------------------------------------------------------
-- FLIGHT
----------------------------------------------------------------

-- One frame of the run. Called from a Heartbeat connection so it is naturally
-- non-blocking and cancellable between frames.
local function flightStep()
	local f = flight
	if not f or not flying then return end
	if f.token ~= token then return end

	local ch, h, r = getState()
	if not (ch and h and r) then
		stopFlight("lost character")
		return
	end
	if h.Health <= 0 then
		stopFlight("died")
		return
	end

	f.frame = f.frame + 1
	local now = os.clock()
	f.elapsed = now - f.t0

	-- void guard: FallenPartsDestroyHeight is what actually kills you, so never
	-- get near it. This is the net under the path scan.
	local curY = r.Position.Y
	if curY < deathFloor() + VOID_MARGIN then
		stopFlight("hit the void guard")
		return
	end
	if f.lowestY == nil or curY < f.lowestY then f.lowestY = curY end

	if f.elapsed > MAX_FLIGHT_S then
		stopFlight("timeout")
		return
	end

	-- ---- phase 1: ramp. Ease in so we never start with a wrong-way step ----
	if f.phase == "ramp" then
		local alpha = math.min(f.frame / RAMP_FRAMES, 1)
		f.traveled = math.min(f.traveled + STEP_SIZE, f.total)
		local xz = f.startPos + f.dir * f.traveled
		-- climb toward the scanned cruise altitude, exactly as the escape script
		-- does with CRUISE_Y: y = startPos.Y + (CRUISE_Y - startPos.Y) * alpha
		local y  = f.startPos.Y + (f.cruiseY - f.startPos.Y) * alpha
		f.lastPos = Vector3.new(xz.X, y, xz.Z)
		-- NOTE: do NOT write back to f.cruiseY here. That made the ramp target
		-- its own current height each frame, so the climb collapsed back toward
		-- the start altitude and the cruise never cleared the terrain.

		r.CFrame = FACE_TRAVEL and CFrame.new(f.lastPos, f.lastPos + f.dir)
			or CFrame.new(f.lastPos)
		r.AssemblyLinearVelocity = Vector3.new(0, FALL_VELOCITY, 0)
		r.AssemblyAngularVelocity = Vector3.zero

		if f.frame >= RAMP_FRAMES then
			f.phase = "cruise"
		end
		return
	end

	-- ---- phase 2: cruise ----
	if f.phase == "cruise" then
		local cur = r.Position
		local remain = (Vector3.new(f.target.X, 0, f.target.Z)
			- Vector3.new(cur.X, 0, cur.Z)).Magnitude

		if remain <= STOP_WITHIN or f.traveled >= f.total then
			f.phase = "descend"
			f.descent = 0
			f.descentFrom = cur
			-- re-check the ground now we are actually there; the scan was a
			-- prediction, this is the fact
			f.destGround = groundY(cur.X, cur.Z, cur.Y)
			return
		end

		-- shrink the approach so we land on the target instead of sailing past
		local step = STEP_SIZE
		if remain < CRUISE_LEAD then
			step = math.clamp(remain * 0.5, STEP_MIN, STEP_SIZE)
		end

		f.traveled = f.traveled + step
		local xz = f.startPos + f.dir * f.traveled
		f.lastPos = Vector3.new(xz.X, f.cruiseY, xz.Z)

		r.CFrame = FACE_TRAVEL and CFrame.new(f.lastPos, f.lastPos + f.dir)
			or CFrame.new(f.lastPos)
		r.AssemblyLinearVelocity = Vector3.new(0, FALL_VELOCITY, 0)
		r.AssemblyAngularVelocity = Vector3.zero
		return
	end

	-- ---- phase 3: stepped descent (no 2000+ stud snap) ----
	if f.phase == "descend" then
		f.descent = f.descent + 1
		local alpha = math.min(f.descent / DESCENT_FRAMES, 1)
		local from  = f.descentFrom
		-- nil here only happens with ALLOW_VOID = true. Without a known ground we
		-- do NOT drop the character: falling with nothing under it is exactly how
		-- the first version killed people.
		if not f.destGround then
			setStatus("no ground under the destination - holding position\n(ALLOW_VOID is on; drop in is unsafe)",
				Color3.fromRGB(255, 200, 120))
			stopFlight(nil)
			return
		end
		local destY = f.destGround + 3

		local x = from.X + (f.target.X - from.X) * alpha
		local z = from.Z + (f.target.Z - from.Z) * alpha
		local y = from.Y + (destY - from.Y) * alpha

		r.CFrame = CFrame.new(x, y, z)
		-- recompute the claimed fall while descending, same as the escape script
		local vy = -12
		r.AssemblyLinearVelocity = Vector3.new(0, vy, 0)
		r.AssemblyAngularVelocity = Vector3.zero

		if f.descent >= DESCENT_FRAMES then
			stopFlight(nil)
		end
		return
	end
end

-- reason nil means "arrived cleanly"
stopFlight = function(reason)
	local f = flight
	if not flying and not f then return end
	flying = false
	flight = nil

	if flightConn then
		flightConn:Disconnect()
		flightConn = nil
	end

	restoreCollisions()

	local ch, h, r = getState()
	if r then
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
		end)
	end

	if reason then
		if tostring(reason):find("DIED") then lastDeath = reason end
		if setStatus then
			setStatus("ABORTED: " .. tostring(reason), Color3.fromRGB(255, 120, 120))
		end
	elseif f then
		local _, _, r2 = getState()
		local landed, finalY = 0, f.startPos.Y
		if r2 then
			local p = r2.Position
			landed = (Vector3.new(p.X - f.startPos.X, 0, p.Z - f.startPos.Z)).Magnitude
			finalY = p.Y
		end
		totalStuds = totalStuds + landed
		lastRun = {studs = landed, secs = f.elapsed}
		if setStatus then
			local spd = f.elapsed > 0 and (landed / f.elapsed) or 0
			setStatus(("landed #%d | %.0f studs | %.2fs\n%.0f studs/s | Y %.1f")
				:format(flightCount, landed, f.elapsed, spd, finalY),
				Color3.fromRGB(120, 255, 150))
		end
	end
end

----------------------------------------------------------------
-- DEATH / RESPAWN SAFETY NET
----------------------------------------------------------------

-- If the character dies mid-flight we must stop and put collisions back. A
-- leaked noclip plus a corpse is how you end up falling through the world.
local function watchDeath(h)
	if diedConn then diedConn:Disconnect(); diedConn = nil end
	if not h then return end
	diedConn = h.Died:Connect(function()
		if flying then
			local _, _, r = getState()
			local where = r and ("%.0f, %.0f, %.0f")
				:format(r.Position.X, r.Position.Y, r.Position.Z) or "?"
			stopFlight("DIED at " .. where)
		else
			-- even outside a flight, never leave noclip behind
			restoreCollisions()
		end
	end)
end

pcall(function()
	LocalPlayer.CharacterAdded:Connect(function()
		restoreCollisions()
		if flying then stopFlight("respawned") end
		lastDeath = nil
	end)
end)

----------------------------------------------------------------
-- START
----------------------------------------------------------------

local function startFlight(requested)
	if flying then return false, "already flying" end

	local ch, h, r = getState()
	if not (ch and h and r) then return false, "no character" end
	if h.Health <= 0 then return false, "dead" end
	if h:GetState() == Enum.HumanoidStateType.Physics then return false, "ragdolled" end

	local total = tonumber(requested)
	if total == nil or total ~= total then return false, "enter a number" end
	if total < MIN_STUDS then return false, ("needs at least %d studs"):format(MIN_STUDS) end
	if total > MAX_STUDS then total = MAX_STUDS end

	local dir = travelDir(r)
	if not dir then return false, "no travel direction" end

	-- ---- SCAN THE ROUTE BEFORE MOVING ANYTHING --------------------------
	-- This is the check the first version was missing. The escape script always
	-- flew to a known landing pad at a fixed altitude; aiming at an arbitrary
	-- point meant the destination could be empty air.
	local scan = scanPath(r.Position, dir, total)
	if scan.missingAt and not ALLOW_VOID then
		return false, ("no ground %d studs that way - refused")
			:format(math.floor(scan.missingAt))
	end
	if not scan.maxGround and not ALLOW_VOID then
		return false, "no ground anywhere on that heading - refused"
	end

	-- cruise above the HIGHEST ground on the route, so we clear terrain instead
	-- of relying on noclip to pass through it
	local cruiseY = r.Position.Y + RISE_STUDS
	if scan.maxGround then
		cruiseY = math.max(scan.maxGround + CLEARANCE, r.Position.Y + RISE_STUDS)
	end

	-- zero any leftover velocity and let the position settle for one frame, the
	-- same as admin_v6_escape L401-403, so the captured start is stable
	pcall(function()
		r.AssemblyLinearVelocity = Vector3.zero
		r.AssemblyAngularVelocity = Vector3.zero
	end)

	if NOCLIP then setCollisions(false) end

	token = token + 1
	flying = true
	flight = {
		token   = token,
		frame   = 0,
		phase   = "ramp",
		dir     = dir,
		startPos = r.Position,
		target  = r.Position + dir * total,
		total   = total,
		traveled = 0,
		t0      = os.clock(),
		elapsed = 0,
		cruiseY = cruiseY,
		lastPos = r.Position,
		destGround = scan.destGround,
		lowestY = r.Position.Y,
		scan    = scan,
	}
	flightCount = flightCount + 1

	watchDeath(h)

	if flightConn then flightConn:Disconnect() end
	flightConn = RunService.Heartbeat:Connect(flightStep)

	-- the first Heartbeat arrives on the next frame, which is the settle frame:
	-- velocities are already zeroed and the start position is captured
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
frame.Size = UDim2.new(0, 250, 0, 226)
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
title.Text = "FREE FALL TRAVEL"
title.TextColor3 = Color3.fromRGB(170, 120, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
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

local label = Instance.new("TextLabel")
label.Size = UDim2.new(1, -24, 0, 14)
label.Position = UDim2.new(0, 12, 0, 30)
label.BackgroundTransparency = 1
label.Text = "DISTANCE  (studs)"
label.TextColor3 = Color3.fromRGB(150, 155, 165)
label.Font = Enum.Font.Gotham
label.TextSize = 10
label.TextXAlignment = Enum.TextXAlignment.Left
label.Parent = frame

local inputBox = Instance.new("TextBox")
inputBox.Size = UDim2.new(1, -24, 0, 28)
inputBox.Position = UDim2.new(0, 12, 0, 44)
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
flyBtn.Size = UDim2.new(1, -24, 0, 34)
flyBtn.Position = UDim2.new(0, 12, 0, 76)
flyBtn.BackgroundColor3 = Color3.fromRGB(95, 55, 170)
flyBtn.Text = "FLY"
flyBtn.TextColor3 = Color3.fromRGB(235, 245, 255)
flyBtn.Font = Enum.Font.GothamBold
flyBtn.TextSize = 14
flyBtn.Parent = frame
Instance.new("UICorner", flyBtn).CornerRadius = UDim.new(0, 8)

-- Noclip is a toggle now, and OFF by default. Flying over the terrain is the
-- safe path; this is here for when something is genuinely in the way.
local noclipBtn = Instance.new("TextButton")
noclipBtn.Size = UDim2.new(1, -24, 0, 24)
noclipBtn.Position = UDim2.new(0, 12, 0, 114)
noclipBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
noclipBtn.Text = "NOCLIP: OFF"
noclipBtn.TextColor3 = Color3.fromRGB(190, 190, 200)
noclipBtn.Font = Enum.Font.GothamBold
noclipBtn.TextSize = 11
noclipBtn.Parent = frame
Instance.new("UICorner", noclipBtn).CornerRadius = UDim.new(0, 6)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -24, 0, 72)
status.Position = UDim2.new(0, 12, 0, 144)
status.BackgroundTransparency = 1
status.Text = "ready"
status.TextColor3 = Color3.fromRGB(160, 160, 160)
status.Font = Enum.Font.Code
status.TextSize = 11
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = frame

setStatus = function(text, color)
	status.Text = text
	status.TextColor3 = color or Color3.fromRGB(160, 160, 160)
end

-- live readout while flying, so it can be compared against the logs
local readoutAcc = 0
local function readout(f)
	local _, _, r = getState()
	if not r then return end
	local cur = r.Position
	local fromStart = (Vector3.new(cur.X - f.startPos.X, 0, cur.Z - f.startPos.Z)).Magnitude
	local spd = f.elapsed > 0 and (fromStart / f.elapsed) or 0
	-- clearance is the number that tells you whether you are about to fly into
	-- terrain: "--" means no ground under you at all
	local gy = groundY(cur.X, cur.Z, cur.Y)
	local clr = gy and ("+%.0f"):format(cur.Y - gy) or "--"
	setStatus(("%s | %.0f/%.0f studs\n%.0f studs/s | Y %.1f | clr %s | %.2fs")
		:format(f.phase, fromStart, f.total, spd, cur.Y, clr, f.elapsed),
		Color3.fromRGB(200, 180, 255))
end

-- wrap the step so the readout refreshes without the flight code knowing about UI
local baseStep = flightStep
flightStep = function()
	-- pcall: an error inside the flight must not leave the loop running with
	-- noclip still on. Same bug class as a stuck `busy` flag.
	local ok, err = pcall(baseStep)
	if not ok then
		stopFlight("error: " .. tostring(err))
		return
	end
	local f = flight
	if not f then return end
	local now = os.clock()
	if now - readoutAcc > 0.1 then
		readoutAcc = now
		readout(f)
	end
end

----------------------------------------------------------------
-- INPUT
----------------------------------------------------------------

local function sanitise(text)
	local out, dot = {}, false
	for i = 1, #text do
		local c = text:sub(i, i)
		if c:match("%d") then
			out[#out + 1] = c
		elseif c == "." and not dot then
			dot = true
			out[#out + 1] = c
		end
	end
	return table.concat(out)
end

local function refreshButton()
	local n = tonumber(inputBox.Text)
	if n == nil then
		flyBtn.Text = "FLY"
		flyBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
	elseif n > MAX_STUDS then
		flyBtn.Text = ("FLY  %d  (max)"):format(MAX_STUDS)
		flyBtn.BackgroundColor3 = Color3.fromRGB(120, 90, 40)
	else
		flyBtn.Text = ("FLY  %g studs"):format(n)
		flyBtn.BackgroundColor3 = Color3.fromRGB(95, 55, 170)
	end
end

local function doFly()
	if flying then
		stopFlight("cancelled")
		return
	end
	local n = tonumber(inputBox.Text)
	if n == nil then
		setStatus("invalid: enter a number", Color3.fromRGB(255, 120, 120))
		return
	end

	local ok, res = startFlight(n)
	if ok then
		lastRun.studs = res
		lastRun.secs  = 0
		setStatus(("flying %g studs..."):format(res), Color3.fromRGB(200, 180, 255))
	else
		setStatus("refused: " .. tostring(res), Color3.fromRGB(255, 120, 120))
	end
end

flyBtn.MouseButton1Click:Connect(doFly)

local function refreshNoclip()
	if NOCLIP then
		noclipBtn.Text = "NOCLIP: ON  (fly through things)"
		noclipBtn.BackgroundColor3 = Color3.fromRGB(120, 70, 40)
	else
		noclipBtn.Text = "NOCLIP: OFF  (fly over things)"
		noclipBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	end
end

noclipBtn.MouseButton1Click:Connect(function()
	if flying then
		setStatus("cannot change noclip mid-flight", Color3.fromRGB(255, 200, 120))
		return
	end
	NOCLIP = not NOCLIP
	if not NOCLIP then restoreCollisions() end   -- turning it off must actually undo it
	refreshNoclip()
end)

inputBox:GetPropertyChangedSignal("Text"):Connect(function()
	local s = sanitise(inputBox.Text)
	if s ~= inputBox.Text then inputBox.Text = s end
	refreshButton()
end)

inputBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then doFly() end
end)

closeBtn.MouseButton1Click:Connect(function()
	-- never leave a flight or noclip running behind a destroyed GUI
	token = token + 1
	stopFlight("gui closed")
	if flightConn then flightConn:Disconnect() end
	screenGui:Destroy()
end)

-- drag to move the frame
local dragging, dragStart, startPos = false, nil, nil
local dragConn
frame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = frame.Position
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

refreshButton()
refreshNoclip()
setStatus(("ready | %d studs/frame | scan %d-stud steps\nclears terrain by %d | void guard %d")
	:format(STEP_SIZE, SCAN_STEP, CLEARANCE, VOID_MARGIN))
