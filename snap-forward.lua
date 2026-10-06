--[[=========================================================================
	SNAP FORWARD + LOCK VELOCITY

	Two ways to move forward, both portable standalones.

	------------------------------------------------------------------
	1) SNAP  — instant CFrame travel
	------------------------------------------------------------------
	Ported from farmer/EggGoToUI_v9_9.lua walkTo():

	    h:Move(Vector3.zero)
	    X.markTeleport()
	    r.AssemblyLinearVelocity = Vector3.zero
	    local yPos = dest.Y
	    if math.abs(rp.Y - dest.Y) <= 4 then yPos = rp.Y end
	    r.CFrame = CFrame.new(dest.X, yPos, dest.Z) * (r.CFrame - r.CFrame.Position)

	The last line is the crux: CFrame.new(x,y,z) * (r.CFrame - r.CFrame.Position) is a
	ROTATION-ONLY CFrame (a CFrame minus its own position is pure rotation), so it
	repositions the root while preserving its facing exactly. That is why walkTo's
	snap never spins the character.

	Type a total, press SNAP: you travel that many studs in chunks of <= MAX_STEP.
	Negative travels backwards. Chunking matters — admin_v6_escape deliberately
	avoids a single multi-thousand-stud write ("no 2000+ stud snap").

	------------------------------------------------------------------
	2) LOCK VELOCITY — continuous forced-speed travel
	------------------------------------------------------------------
	Ported from EggGoToUI's applyVelocity() (line 3323) + detectRubberband() (3372).

	    if h.WalkSpeed ~= targetVelocity then h.WalkSpeed = targetVelocity end
	    if h.MoveDirection.Magnitude > 0.05 then
	        local d = h.MoveDirection.Unit
	        r.AssemblyLinearVelocity = Vector3.new(d.X*targetVelocity, Y, d.Z*targetVelocity)
	    end

	The catch in the original: that write ONLY happens while MoveDirection is
	non-zero, so it needs real movement input. A Humanoid-relative Move() call is
	what supplies it (the farm does this itself at line 1827: h:Move(d, false)).
	So each frame we do all three: set MoveDirection, match WalkSpeed, and force the
	velocity. Raise the speed box, press LOCK VELOCITY, press again to release.

	This is the mode that DOES rubberband, and that is not a bug — forcing a velocity
	the server disagrees with is exactly what a rubberband is. The detector counts
	each pull-back and drops the speed by VELOCITY_STEP (down to MIN_SPEED), which is
	the farm's own adaptive strategy. The status line shows the speed and RB count.

	NOTE the detector is skipped for the RB_GUARD window after a SNAP, so our own
	teleports are never mistaken for a server pull-back. That is X.markTeleport()'s
	job in the original.

	UI: stud box + SNAP, speed box + LOCK VELOCITY, X to destroy. No dependencies —
	this does not require EggGoToUI to be running.
=========================================================================]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local playerGui   = LocalPlayer:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- CONFIG — SNAP
----------------------------------------------------------------

local MAX_STEP      = 35      -- largest single CFrame write, studs (walkTo hop = 35)
local STEP_INTERVAL = 0.05    -- extra gap between chunks, seconds
local SETTLE_TIME   = 0.08    -- task.wait(0.08) after each snap, same as walkTo
local Y_TOLERANCE   = 4       -- walkTo: keep current Y when |dY| <= 4, else use dest Y
local KEEP_ANGULAR  = false   -- true also zeroes AssemblyAngularVelocity
local MIN_TOTAL     = 0       -- studs; below this the button refuses
local MAX_TOTAL     = 10000   -- clamp, so a stray keystroke cannot fling you off the map
local DEFAULT_TOTAL = 35
local LOCK_DIRECTION = true   -- lock the heading once, like admin_v6_escape's lockedDir

----------------------------------------------------------------
-- CONFIG — LOCK VELOCITY (defaults mirror the farm)
----------------------------------------------------------------

local DEFAULT_SPEED = 330     -- X.baseVelocity
local MIN_SPEED     = 100     -- X.MIN_VELOCITY
local MAX_SPEED     = 1000    -- our own ceiling; nothing upstream bounds it
local VELOCITY_STEP = 10      -- X.VELOCITY_STEP: drop per rubberband
local RUBBER_BACK   = 6       -- X.RUBBER_BACK: studs pulled back in one frame
local RB_COOLDOWN   = 0.5     -- one pull-back can span frames; count it once
local RB_GUARD      = 0.35    -- X.ignoreJumpUntil: ignore pull-backs after our snap
local HOVER         = false   -- true forces Y velocity to 0 (level flight, no gravity)
local RESTORE_WALK  = true    -- restore the old WalkSpeed on release

----------------------------------------------------------------
-- CONFIG — direction
----------------------------------------------------------------

--   "facing"  character's own look direction  (default; keeps facing stable)
--   "camera"  where the camera is pointing
--   "move"    Humanoid.MoveDirection, falling back to facing
local DIR_MODE = "facing"

local GUI_NAME = "SnapForwardV1"

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

local lastSnapAt = -math.huge  -- X.ignoreJumpUntil stand-in; -inf, not 0 (see below)
local busy       = false       -- one snap run at a time

local runCount   = 0
local totalStuds = 0

local velocityLockEnabled = false
local lockSpeed      = DEFAULT_SPEED
local rbCount        = 0
local lastLockPos    = nil
local rbCooldownUntil = 0
local savedWalkSpeed = nil
local lastLockText   = 0
local lastEventAt    = -math.huge  -- don't let the readout clobber an event flash

-- Forward-declared on purpose. A `local` introduced LATER in this chunk is not
-- visible to functions defined above it — the reference would silently resolve to
-- a global instead, so `if onProgress then ... end` would just never fire.
--   onProgress reads snapTotal()'s progress; assigned in the wiring section.
--   dragConn   is disconnected by the X handler, which is defined before it.
local onProgress
local dragConn

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

-- walkTo bails out while ragdolled (Physics) or dead. Those are the two states
-- where a CFrame write fights the ragdoll system, so we refuse instead.
local function canSnap(h)
	if not h then return false, "no humanoid" end
	if h.Health <= 0 then return false, "dead" end
	local st = h:GetState()
	if st == Enum.HumanoidStateType.Physics then return false, "ragdolled" end
	return true, nil
end

-- Flatten to the XZ plane, exactly like the rest of the script does
-- (dir = Vector3.new(dest.X - rp.X, 0, dest.Z - rp.Z).Unit at walkTo L1779).
local function flatten(v)
	if not v then return nil end
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 0.05 then return nil end   -- looking straight up/down
	return flat.Unit
end

local function facingDir(r)
	return flatten(r.CFrame.LookVector)
end

local function forwardDir(r)
	if DIR_MODE == "camera" then
		local cam = workspace.CurrentCamera
		return flatten(cam and cam.CFrame.LookVector) or facingDir(r)
	elseif DIR_MODE == "move" then
		local _, h = getState()
		return flatten(h and h.MoveDirection) or facingDir(r)
	end
	return facingDir(r)
end

----------------------------------------------------------------
-- SNAP LOGIC (ported from walkTo)
----------------------------------------------------------------

-- X.markTeleport() parity: opens a short window in which our own CFrame write
-- must not be mistaken for a server rubberband. EggGoToUI keeps its own copy of
-- this; ours is local, so the two stay independent.
local function markTeleport()
	lastSnapAt = os.clock()
end

-- dest may be any Vector3. Returns ok, moved (or reason).
local function snapTo(dest)
	local ch, h, r = getState()
	if not (ch and h and r) then return false, "no character" end
	if not dest then return false, "no destination" end

	local ok, why = canSnap(h)
	if not ok then return false, why end

	-- walkTo does the same on arrival ("Close enough: hop onto target"):
	-- cancel locomotion input first so the humanoid is not still pushing us.
	h:Move(Vector3.zero)
	markTeleport()

	local srcX, srcZ
	local wrote = pcall(function()
		r.AssemblyLinearVelocity = Vector3.zero
		if KEEP_ANGULAR then r.AssemblyAngularVelocity = Vector3.zero end

		-- walkTo reads rp once, then works off that read
		local rp = r.Position
		srcX, srcZ = rp.X, rp.Z

		local yPos = dest.Y
		if math.abs(rp.Y - dest.Y) <= Y_TOLERANCE then yPos = rp.Y end

		r.CFrame = CFrame.new(dest.X, yPos, dest.Z) * (r.CFrame - r.CFrame.Position)
	end)

	task.wait(SETTLE_TIME)
	if not wrote then return false, "CFrame write failed" end

	-- measure what actually happened rather than trusting the request
	local _, _, r2 = getState()
	local moved = 0
	if r2 and srcX then
		moved = (Vector3.new(r2.Position.X, 0, r2.Position.Z)
			- Vector3.new(srcX, 0, srcZ)).Magnitude
	end
	return true, moved
end

----------------------------------------------------------------
-- CHUNKED TRAVEL
----------------------------------------------------------------

-- Travel `requested` studs along the forward direction, in MAX_STEP chunks.
-- Negative goes backwards. Returns ok, studs actually moved, note.
local function snapTotal(requested)
	if busy then return false, 0, "busy" end
	if type(requested) ~= "number" or requested ~= requested then
		return false, 0, "not a number"
	end

	local want = math.abs(requested)
	local clampNote = nil
	if want > MAX_TOTAL then
		want = MAX_TOTAL
		clampNote = ("clamped to %d"):format(MAX_TOTAL)
	end
	if want < MIN_TOTAL then return false, 0, "below minimum" end

	local _, h, r = getState()
	if not (h and r) then return false, 0, "no character" end

	local ok, why = canSnap(h)
	if not ok then return false, 0, why end

	local baseDir = forwardDir(r)
	if not baseDir then return false, 0, "no forward direction" end
	if requested < 0 then baseDir = baseDir * -1 end

	-- swallow accidental double-clicks: walkTo waits the same SETTLE_TIME after a
	-- snap, so a second run inside that window would stack two teleports at once.
	if os.clock() - lastSnapAt < SETTLE_TIME then return false, 0, "settling" end

	busy = true

	-- wrapped in pcall so `busy` is ALWAYS cleared, including on a mid-run refusal
	-- or an unexpected error. (An early return that skipped the reset would leave
	-- the button permanently dead.)
	local okRun, runOk, runMoved, runNote = pcall(function()
		local dir       = baseDir
		local moved     = 0
		local remaining = want

		while remaining > 0.5 do
			local _, h2, r2 = getState()
			if not r2 then return false, moved, "lost character" end

			local okNow, whyNow = canSnap(h2)
			if not okNow then return false, moved, whyNow end

			-- re-read the facing only if the caller asked for it
			if not LOCK_DIRECTION then
				local d2 = forwardDir(r2)
				if d2 then
					if requested < 0 then d2 = d2 * -1 end
					dir = d2
				end
			end

			local step = math.min(remaining, MAX_STEP)
			local okStep, res = snapTo(r2.Position + dir * step)
			if not okStep then return false, moved, res end

			moved = moved + res
			remaining = remaining - step

			if onProgress then onProgress(moved, want) end
			if remaining > 0.5 then task.wait(STEP_INTERVAL) end
		end

		return true, moved, clampNote
	end)

	busy = false

	if not okRun then
		return false, 0, "error: " .. tostring(runOk)
	end
	return runOk, runMoved or 0, runNote
end

----------------------------------------------------------------
-- LOCK VELOCITY
----------------------------------------------------------------

local setStatus         -- forward-declared; assigned in the UI section
local updateLockButton  -- ditto: releaseLock/engageLock run before it is defined
local lockTick          -- ditto: engageLock applies one tick immediately

local function releaseLock(silent)
	if not velocityLockEnabled then return end
	velocityLockEnabled = false
	lastLockPos = nil

	local _, h = getState()
	if h then
		pcall(function() h:Move(Vector3.zero) end)
		if RESTORE_WALK and savedWalkSpeed then
			pcall(function() h.WalkSpeed = savedWalkSpeed end)
		end
	end
	savedWalkSpeed = nil

	if not silent and setStatus then
		setStatus(("lock released | %d speed (RB %d)"):format(lockSpeed, rbCount),
			Color3.fromRGB(200, 200, 200))
	end
	if updateLockButton then updateLockButton() end
end

local function engageLock(speed)
	local _, h, r = getState()
	if not (h and r) then return false, "no character" end
	local ok, why = canSnap(h)
	if not ok then return false, why end

	local n = tonumber(speed)
	if n == nil or n ~= n then return false, "bad speed" end
	if n < MIN_SPEED then n = MIN_SPEED end
	if n > MAX_SPEED then n = MAX_SPEED end

	lockSpeed = n
	rbCount = 0
	lastLockPos = r.Position
	rbCooldownUntil = 0
	savedWalkSpeed = h.WalkSpeed

	velocityLockEnabled = true
	if updateLockButton then updateLockButton() end
	-- apply on this frame rather than waiting for the next Heartbeat, so the
	-- velocity is already live when the click handler returns
	if lockTick then lockTick(0) end
	return true, n
end

-- Runs every Heartbeat while enabled. Mirrors applyVelocity() + detectRubberband().
lockTick = function(dt)
	if not velocityLockEnabled then return end

	local _, h, r = getState()
	if not (h and r) then return end

	-- paused, not released: walkTo also pauses rather than aborting while ragdolled
	local ok = canSnap(h)
	if not ok then
		lastLockPos = nil
		return
	end

	-- for "move" mode this reads whatever Move() last set, which is what keeps us
	-- travelling; forwardDir falls back to facing so the first frame can start.
	local dir = forwardDir(r)
	if not dir then return end

	local now = os.clock()
	local pos = r.Position

	-- ---- rubberband: yanked backwards against our own direction ----------
	-- `back` is the component of this frame's displacement that points AWAY from
	-- travel, so a server pull-back shows up as a large positive number.
	if lastLockPos and (now - lastSnapAt) > RB_GUARD and now >= rbCooldownUntil then
		local disp = Vector3.new(pos.X - lastLockPos.X, 0, pos.Z - lastLockPos.Z)
		local back = -disp:Dot(dir)
		if back >= RUBBER_BACK then
			local before = lockSpeed
			lockSpeed = math.max(MIN_SPEED, lockSpeed - VELOCITY_STEP)
			rbCount = rbCount + 1
			rbCooldownUntil = now + RB_COOLDOWN
			lastEventAt = now
			if setStatus and lockSpeed ~= before then
				setStatus(("RUBBERBAND #%d  %.0f -> %.0f studs/s\n(%.1f studs back)")
					:format(rbCount, before, lockSpeed, back),
					Color3.fromRGB(255, 200, 120))
			end
		end
	end
	lastLockPos = pos

	-- ---- the three writes: MoveDirection, WalkSpeed, linear velocity -----
	if h.WalkSpeed ~= lockSpeed then
		pcall(function() h.WalkSpeed = lockSpeed end)
	end
	pcall(function() h:Move(dir) end)

	local yVel = HOVER and 0 or r.AssemblyLinearVelocity.Y
	pcall(function()
		r.AssemblyLinearVelocity = Vector3.new(dir.X * lockSpeed, yVel, dir.Z * lockSpeed)
	end)

	-- throttle the readout; this runs every frame
	if setStatus and (now - lastLockText) > 0.25 and (now - lastEventAt) > 0.6 then
		lastLockText = now
		local live = r.AssemblyLinearVelocity
		setStatus(("LOCKED %d studs/s%s | RB %d\nlive %.0f | vMag %.0f | %s")
			:format(lockSpeed, HOVER and " (hover)" or "", rbCount,
				math.sqrt(live.X^2 + live.Z^2),
				r.AssemblyLinearVelocity.Magnitude, DIR_MODE),
			Color3.fromRGB(120, 255, 150))
	end
end

RunService.Heartbeat:Connect(lockTick)

----------------------------------------------------------------
-- UI
----------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = GUI_NAME
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 250, 0, 300)
frame.Position = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
frame.BackgroundTransparency = 0.12
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(0, 200, 255)
stroke.Thickness = 2
stroke.Transparency = 0.3
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 0, 22)
title.Position = UDim2.new(0, 12, 0, 6)
title.BackgroundTransparency = 1
title.Text = "SNAP FORWARD"
title.TextColor3 = Color3.fromRGB(0, 200, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

-- X: destroys the GUI and unsubscribes
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
	l.Size = UDim2.new(1, -24, 0, 14)
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

local function mkBox(y, value)
	local b = Instance.new("TextBox")
	b.Size = UDim2.new(1, -24, 0, 28)
	b.Position = UDim2.new(0, 12, 0, y)
	b.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
	b.BorderSizePixel = 0
	b.Text = tostring(value)
	b.PlaceholderText = tostring(value)
	b.ClearTextOnFocus = false
	b.TextColor3 = Color3.fromRGB(235, 245, 255)
	b.Font = Enum.Font.Code
	b.TextSize = 15
	b.TextXAlignment = Enum.TextXAlignment.Center
	b.Parent = frame
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	return b
end

local function mkButton(y, text, r, g, b)
	local bt = Instance.new("TextButton")
	bt.Size = UDim2.new(1, -24, 0, 34)
	bt.Position = UDim2.new(0, 12, 0, y)
	bt.BackgroundColor3 = Color3.fromRGB(r, g, b)
	bt.Text = text
	bt.TextColor3 = Color3.fromRGB(235, 245, 255)
	bt.Font = Enum.Font.GothamBold
	bt.TextSize = 14
	bt.AutoButtonColor = true
	bt.Parent = frame
	Instance.new("UICorner", bt).CornerRadius = UDim.new(0, 8)
	return bt
end

mkLabel(30, "TOTAL STUDS  (negative = back)")
local inputBox = mkBox(44, DEFAULT_TOTAL)
local snapBtn  = mkButton(76, "SNAP", 35, 110, 170)

mkLabel(114, "LOCK SPEED  (studs/s)")
local speedBox = mkBox(128, DEFAULT_SPEED)
local lockBtn  = mkButton(160, "LOCK VELOCITY", 60, 60, 72)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -24, 0, 96)
status.Position = UDim2.new(0, 12, 0, 198)
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

----------------------------------------------------------------
-- INPUT HANDLING
----------------------------------------------------------------

-- Keep the field numeric while typing: digits, at most one dot, and a leading
-- minus only. Character-by-character so a half-typed value is never wiped.
local function sanitise(text, allowNegative)
	local out, seenDot, seenMinus = {}, false, false
	for i = 1, #text do
		local c = text:sub(i, i)
		if c:match("%d") then
			out[#out + 1] = c
		elseif c == "." and not seenDot then
			seenDot = true
			out[#out + 1] = c
		elseif allowNegative and c == "-" and not seenMinus and #out == 0 then
			seenMinus = true
			out[#out + 1] = c
		end
	end
	return table.concat(out)
end

local function parseInput(box)
	local n = tonumber(box.Text)
	if n == nil then return nil, "enter a number" end
	if n ~= n then return nil, "not a number" end
	if n == math.huge or n == -math.huge then return nil, "out of range" end
	return n, nil
end

local function refreshButton()
	local n = parseInput(inputBox)
	if n == nil then
		snapBtn.Text = "SNAP"
		snapBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
	elseif math.abs(n) > MAX_TOTAL then
		snapBtn.Text = ("SNAP  %d  (max)"):format(MAX_TOTAL)
		snapBtn.BackgroundColor3 = Color3.fromRGB(120, 90, 40)
	else
		snapBtn.Text = ("SNAP  %g studs"):format(n)
		snapBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 170)
	end
end

----------------------------------------------------------------
-- WIRING
----------------------------------------------------------------

onProgress = function(moved, want)
	setStatus(("moving  %.0f / %.0f studs..."):format(moved, want),
		Color3.fromRGB(160, 200, 255))
end

updateLockButton = function()
	if velocityLockEnabled then
		lockBtn.Text = ("RELEASE  (%d studs/s)"):format(lockSpeed)
		lockBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
	else
		lockBtn.Text = "LOCK VELOCITY"
		lockBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 72)
	end
end

local function doMove()
	if busy then return end
	local n, err = parseInput(inputBox)
	if n == nil then
		setStatus("invalid: " .. tostring(err), Color3.fromRGB(255, 120, 120))
		return
	end

	snapBtn.Text = "..."
	task.spawn(function()
		-- a snap mid-lock would be flagged as a rubberband without the guard,
		-- so markTeleport() inside snapTo() covers it (X.markTeleport parity)
		local ok, moved, note = snapTotal(n)
		totalStuds = totalStuds + moved
		if ok then
			runCount = runCount + 1
			local msg = ("%s #%d  moved %.1f studs\nrequested %g | total %.1f")
				:format(DIR_MODE, runCount, moved, n, totalStuds)
			if note then msg = msg .. "\n(" .. note .. ")" end
			setStatus(msg, Color3.fromRGB(120, 255, 150))
		else
			-- moved may be non-zero: the run can stop part-way (ragdoll, lost
			-- character) after covering some of the distance.
			setStatus(("stopped after %.1f studs: %s"):format(moved, tostring(note)),
				Color3.fromRGB(255, 120, 120))
		end
		refreshButton()
	end)
end

local function doLockToggle()
	if velocityLockEnabled then
		releaseLock()
		return
	end
	local n, err = parseInput(speedBox)
	if n == nil then
		setStatus("speed invalid: " .. tostring(err), Color3.fromRGB(255, 120, 120))
		return
	end
	local ok, res = engageLock(n)
	if ok then
		setStatus(("LOCKED %d studs/s | RB 0\n%s | facing preserved"):format(res, DIR_MODE),
			Color3.fromRGB(120, 255, 150))
	else
		setStatus("lock refused: " .. tostring(res), Color3.fromRGB(255, 120, 120))
	end
end

snapBtn.MouseButton1Click:Connect(doMove)
lockBtn.MouseButton1Click:Connect(doLockToggle)

inputBox:GetPropertyChangedSignal("Text"):Connect(function()
	local s = sanitise(inputBox.Text, true)
	if s ~= inputBox.Text then inputBox.Text = s end
	refreshButton()
end)

speedBox:GetPropertyChangedSignal("Text"):Connect(function()
	local s = sanitise(speedBox.Text, false)
	if s ~= speedBox.Text then speedBox.Text = s end
	if velocityLockEnabled then
		local n = tonumber(s)
		if n then
			-- live speed change while locked, clamped like engageLock
			lockSpeed = math.clamp(n, MIN_SPEED, MAX_SPEED)
		end
	end
	updateLockButton()
end)

inputBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then doMove() end
end)
speedBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then doLockToggle() end
end)

closeBtn.MouseButton1Click:Connect(function()
	releaseLock(true)          -- never leave a forced velocity running
	if dragConn then dragConn:Disconnect() end
	screenGui:Destroy()
end)

-- drag to move the frame (same pattern as debug.lua)
local dragging, dragStart, startPos = false, nil, nil
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
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
			startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)

refreshButton()
updateLockButton()
setStatus(("ready | %s | step %d | RB -%d to %d"):format(
	DIR_MODE, MAX_STEP, VELOCITY_STEP, MIN_SPEED))
