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
local MAX_STUDS     = 100000  -- clamp, so a stray keystroke cannot fling you away

local STEP_SIZE     = 78      -- studs per frame (admin_v6_escape STEP_SIZE)
local RAMP_FRAMES   = 5       -- ease-in, so we never start with a wrong-way step
local RISE_STUDS    = 13      -- climb above the start Y during the ramp
local CRUISE_LEAD   = 120     -- shrink the step when this close to the target
local STEP_MIN      = 28      -- smallest shrunken step
local STOP_WITHIN   = 25      -- treat this as arrived
local DESCENT_FRAMES = 3      -- stepped descent, not one drop
local MAX_FLIGHT_S  = 2.5     -- hard bound on the whole flight

local ZERO_HORIZONTAL = true  -- THE trick: claim no sideways velocity
local FALL_VELOCITY   = -10   -- and claim a plausible falling one (admin: -10)

local NOCLIP        = true    -- CanCollide=false for the flight, then restored
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
	-- restore unconditionally: leaving noclip on after a crash would be worse
	-- than re-enabling collision on a part we never touched
	for part in pairs(savedCollisions) do
		pcall(function() part.CanCollide = savedCollisions[part] end)
		savedCollisions[part] = nil
	end
	setCollisions(true)
end

----------------------------------------------------------------
-- GROUND FINDER (for the stepped descent)
----------------------------------------------------------------

local function groundY(x, z)
	local ch = LocalPlayer.Character
	local ok, hit = pcall(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { ch }
		return workspace:Raycast(Vector3.new(x, 500, z), Vector3.new(0, -1000, 0), params)
	end)
	if ok and hit and hit.Position then return hit.Position.Y end
	return nil
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

	if f.elapsed > MAX_FLIGHT_S then
		stopFlight("timeout")
		return
	end

	-- ---- phase 1: ramp. Ease in so we never start with a wrong-way step ----
	if f.phase == "ramp" then
		local alpha = math.min(f.frame / RAMP_FRAMES, 1)
		f.traveled = math.min(f.traveled + STEP_SIZE, f.total)
		local xz = f.startPos + f.dir * f.traveled
		local y  = f.startPos.Y + RISE_STUDS * alpha
		f.lastPos = Vector3.new(xz.X, y, xz.Z)
		f.cruiseY = y

		r.CFrame = FACE_TRAVEL and CFrame.new(f.lastPos, f.lastPos + f.dir)
			or CFrame.new(f.lastPos)
		r.AssemblyLinearVelocity = Vector3.new(0, FALL_VELOCITY, 0)
		r.AssemblyAngularVelocity = Vector3.zero

		if f.frame >= RAMP_FRAMES then
			f.phase = "cruise"
			f.cruiseY = f.startPos.Y + RISE_STUDS
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
			f.groundY = groundY(cur.X, cur.Z)
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
		local destY = f.groundY and (f.groundY + 3) or (from.Y - 5)

		local x = from.X + (f.target.X - from.X) * alpha
		local z = from.Z + (f.target.Z - from.Z) * alpha
		local y = from.Y + (destY - from.Y) * alpha

		r.CFrame = CFrame.new(x, y, z)
		-- recompute the claimed fall while descending, same as the escape script
		local vy = f.groundY and -12 or 0
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
		cruiseY = r.Position.Y,
		lastPos = r.Position,
	}
	flightCount = flightCount + 1

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
frame.Size = UDim2.new(0, 250, 0, 216)
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

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -24, 0, 76)
status.Position = UDim2.new(0, 12, 0, 114)
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
	setStatus(("%s | %.0f/%.0f studs\n%.0f studs/s | Y %.1f | %.2fs")
		:format(f.phase, fromStart, f.total, spd, cur.Y, f.elapsed),
		Color3.fromRGB(200, 180, 255))
end

-- wrap the step so the readout refreshes without the flight code knowing about UI
local baseStep = flightStep
flightStep = function()
	baseStep()
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
setStatus(("ready | %d studs/frame | max %.1fs | %s")
	:format(STEP_SIZE, MAX_FLIGHT_S, DIR_MODE))
