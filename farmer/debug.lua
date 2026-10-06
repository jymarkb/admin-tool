local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ================================================================
-- CONFIG
-- ================================================================
local MAX_LOG_ENTRIES = 2000
local TRANSFORM_CAPTURE_DEFAULT = true
local TRANSFORM_JUMP_MIN_DISTANCE = 8.0
local TRANSFORM_JUMP_MIN_PSPEED = 750.0
local TRANSFORM_JUMP_RATIO = 3.0
local TRANSFORM_PROPERTY_DEDUPE_TIME = 0.006
local TRANSFORM_PROPERTY_DEDUPE_DISTANCE = 2.0

-- ================================================================
-- FORENSICS (V8) - the things this scanner could not see
-- ================================================================
-- Added after a long debugging session where several failures were invisible in
-- the log. Each one below is a specific blind spot that cost us a round trip:
--   * Health set to -1000 (the exploit handler) looked identical to fall damage,
--     because only the value 0 was ever treated as "dead".
--   * A flight could write 1978 studs of CFrame and be REVERTED by the server,
--     while the scanner reported it as a large move and the scripts believed they
--     had travelled. Nothing compared a big jump against what happened next.
--   * Humanoid.Died was never subscribed - death was only inferred from hp=0.
--   * Nothing watched Touched, so a kill brick was invisible.
--   * Nothing measured the rig itself, so joints tearing (Motor6D stretch) could
--     not be distinguished from the character simply moving.
local FORENSICS_DEFAULT     = true
local EXPLOIT_HP            = -1     -- Health below this = SET, not damaged away
local BIG_JUMP_STUDS        = 50     -- a displacement this large starts a reversion watch
local REVERT_MIN_STUDS      = 40     -- coming back this far = the write did not stick
local REVERT_WINDOW_S       = 2.0    -- how long after a big jump to keep watching
local NET_WINDOW_S          = 1.0    -- window for the periodic NET displacement line
local NET_MIN_SPEED         = 100    -- only report NET while moving this fast
local RIG_STRETCH_STUDS     = 2.5    -- limb offset beyond baseline = joints stretching
local NEAR_RADIUS           = 30     -- what was around us
local TOUCH_DEDUPE_S        = 0.5    -- do not repeat the same Touched part
local VOID_WARN_STUDS       = 50     -- warn this close to FallenPartsDestroyHeight
local OBSTACLE_AHEAD_STUDS  = 30     -- raycast this far ahead while moving fast

local RENDER_STEP_NAME = "ReferenceFreefallReplayV7"
local RENDER_STEP_PRIORITY = Enum.RenderPriority.Character.Value + 1
local REPLAY_CORRECTION_TOLERANCE = 25.0
local REPLAY_MIN_FREEFALL_Y = 100.0

-- ================================================================
-- EXACT PROFILE EXTRACTED FROM ld-p3.log
-- ================================================================
-- Launch (relative to start position). Two big PreRender jumps.
local LAUNCH_PROFILE = {
	{t = 0.000, dx = -254.7, dy = 25.4, dz = 0.3},
	{t = 0.057, dx = -421.2, dy = 42.0, dz = 0.5}, -- cumulative
}

-- Freefall X chunks (relative to freefall origin = launch end).
-- Y is forced fixed; only X/Z from these deltas are applied.
local FREEFALL_X_DELTAS = {
	-284.1, -137.1, -191.0, -191.1, -39.0, -421.2,
	-192.4, -179.0, -49.8, -194.4, -226.8, -212.2,
	-184.9, -24.1, -204.6, -195.5, -21.1, -230.9,
	-190.3, -242.6, -178.6, -421.2, -257.6, -163.5,
}

-- Approximate inter-chunk times observed in the log (seconds between PreRender jumps)
local FREEFALL_CHUNK_TIMES = {
	0.000, 0.045, 0.045, 0.046, 0.073, 0.129,
	0.043, 0.043, 0.046, 0.046, 0.072, 0.052,
	0.043, 0.044, 0.051, 0.044, 0.046, 0.055,
	0.058, 0.058, 0.046, 0.140, 0.061, 0.054,
}

local DROP_OFFSET_Y = -41.9

-- ================================================================
-- GUI
-- ================================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SpeedScanner"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "SpeedFrame"
frame.Size = UDim2.new(0, 360, 0, 520)
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
title.Size = UDim2.new(1, -40, 0, 26)
title.Position = UDim2.new(0, 12, 0, 6)
title.BackgroundTransparency = 1
title.Text = "REFERENCE TRANSFORM V7 (ld-p3)"
title.TextColor3 = Color3.fromRGB(0, 200, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -34, 0, 6)
closeBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 16
closeBtn.Parent = frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

local speedLabel = Instance.new("TextLabel")
speedLabel.Size = UDim2.new(1, -20, 0, 28)
speedLabel.Position = UDim2.new(0, 10, 0, 34)
speedLabel.BackgroundTransparency = 1
speedLabel.Text = "0.0 studs/s"
speedLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
speedLabel.Font = Enum.Font.GothamBold
speedLabel.TextSize = 22
speedLabel.TextXAlignment = Enum.TextXAlignment.Left
speedLabel.Parent = frame

local stateLabel = Instance.new("TextLabel")
stateLabel.Size = UDim2.new(1, -20, 0, 16)
stateLabel.Position = UDim2.new(0, 10, 0, 62)
stateLabel.BackgroundTransparency = 1
stateLabel.Text = "State: —"
stateLabel.TextColor3 = Color3.fromRGB(160, 160, 160)
stateLabel.Font = Enum.Font.Gotham
stateLabel.TextSize = 12
stateLabel.TextXAlignment = Enum.TextXAlignment.Left
stateLabel.Parent = frame

local phaseLabel = Instance.new("TextLabel")
phaseLabel.Size = UDim2.new(1, -20, 0, 16)
phaseLabel.Position = UDim2.new(0, 10, 0, 78)
phaseLabel.BackgroundTransparency = 1
phaseLabel.Text = "Phase: IDLE | HP: —"
phaseLabel.TextColor3 = Color3.fromRGB(100, 220, 255)
phaseLabel.Font = Enum.Font.Code
phaseLabel.TextSize = 11
phaseLabel.TextXAlignment = Enum.TextXAlignment.Left
phaseLabel.Parent = frame

local posLabel = Instance.new("TextLabel")
posLabel.Size = UDim2.new(1, -20, 0, 16)
posLabel.Position = UDim2.new(0, 10, 0, 94)
posLabel.BackgroundTransparency = 1
posLabel.Text = "Pos: 0, 0, 0"
posLabel.TextColor3 = Color3.fromRGB(140, 140, 160)
posLabel.Font = Enum.Font.Code
posLabel.TextSize = 11
posLabel.TextXAlignment = Enum.TextXAlignment.Left
posLabel.Parent = frame

local logTitle = Instance.new("TextLabel")
logTitle.Size = UDim2.new(1, -20, 0, 18)
logTitle.Position = UDim2.new(0, 10, 0, 112)
logTitle.BackgroundTransparency = 1
logTitle.Text = "DETAILED EVENT + FRAME TRACE"
logTitle.TextColor3 = Color3.fromRGB(0, 180, 220)
logTitle.Font = Enum.Font.GothamBold
logTitle.TextSize = 12
logTitle.TextXAlignment = Enum.TextXAlignment.Left
logTitle.Parent = frame

local logScroll = Instance.new("ScrollingFrame")
logScroll.Name = "LogScroll"
logScroll.Size = UDim2.new(1, -20, 0, 230)
logScroll.Position = UDim2.new(0, 10, 0, 132)
logScroll.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
logScroll.BackgroundTransparency = 0.3
logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 4
logScroll.ScrollBarImageColor3 = Color3.fromRGB(0, 180, 220)
logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
logScroll.Parent = frame
Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 8)

local logList = Instance.new("UIListLayout")
logList.SortOrder = Enum.SortOrder.LayoutOrder
logList.Padding = UDim.new(0, 2)
logList.Parent = logScroll

local buttonFrame = Instance.new("Frame")
buttonFrame.Size = UDim2.new(1, -20, 0, 102)
buttonFrame.Position = UDim2.new(0, 10, 1, -112)
buttonFrame.BackgroundTransparency = 1
buttonFrame.Parent = frame

local boostBtn = Instance.new("TextButton")
boostBtn.Size = UDim2.new(1, 0, 0, 32)
boostBtn.Position = UDim2.new(0, 0, 0, 0)
boostBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
boostBtn.Text = "REPLAY REFERENCE (ld-p3)"
boostBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
boostBtn.Font = Enum.Font.GothamBold
boostBtn.TextSize = 13
boostBtn.Parent = buttonFrame
Instance.new("UICorner", boostBtn).CornerRadius = UDim.new(0, 6)

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.new(0, 130, 0, 26)
copyBtn.Position = UDim2.new(0, 0, 0, 40)
copyBtn.BackgroundColor3 = Color3.fromRGB(0, 140, 180)
copyBtn.Text = "Copy Full Log"
copyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 12
copyBtn.Parent = buttonFrame
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 6)

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, 100, 0, 26)
clearBtn.Position = UDim2.new(0, 140, 0, 40)
clearBtn.BackgroundColor3 = Color3.fromRGB(80, 40, 40)
clearBtn.Text = "Clear Log"
clearBtn.TextColor3 = Color3.fromRGB(255, 180, 180)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 12
clearBtn.Parent = buttonFrame
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

local captureBtn = Instance.new("TextButton")
captureBtn.Size = UDim2.new(0, 80, 0, 26)
captureBtn.Position = UDim2.new(0, 250, 0, 40)
captureBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 70)
captureBtn.Text = "CAPTURE: ON"
captureBtn.TextColor3 = Color3.fromRGB(220, 255, 230)
captureBtn.Font = Enum.Font.GothamBold
captureBtn.TextSize = 11
captureBtn.Parent = buttonFrame
Instance.new("UICorner", captureBtn).CornerRadius = UDim.new(0, 6)

-- Row 3: turn the new forensics on and off, and take a manual snapshot when
-- something feels wrong but nothing has been logged yet.
local forensicsBtn = Instance.new("TextButton")
forensicsBtn.Size = UDim2.new(0, 170, 0, 26)
forensicsBtn.Position = UDim2.new(0, 0, 0, 70)
forensicsBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 70)
forensicsBtn.Text = "FORENSICS: ON"
forensicsBtn.TextColor3 = Color3.fromRGB(220, 255, 230)
forensicsBtn.Font = Enum.Font.GothamBold
forensicsBtn.TextSize = 11
forensicsBtn.Parent = buttonFrame
Instance.new("UICorner", forensicsBtn).CornerRadius = UDim.new(0, 6)

local snapshotBtn = Instance.new("TextButton")
snapshotBtn.Size = UDim2.new(0, 120, 0, 26)
snapshotBtn.Position = UDim2.new(0, 178, 0, 70)
snapshotBtn.BackgroundColor3 = Color3.fromRGB(60, 70, 120)
snapshotBtn.Text = "SNAPSHOT"
snapshotBtn.TextColor3 = Color3.fromRGB(225, 230, 255)
snapshotBtn.Font = Enum.Font.GothamBold
snapshotBtn.TextSize = 11
snapshotBtn.Parent = buttonFrame
Instance.new("UICorner", snapshotBtn).CornerRadius = UDim.new(0, 6)

local feedback = Instance.new("TextLabel")
feedback.Size = UDim2.new(0, 200, 0, 18)
feedback.Position = UDim2.new(0, 10, 1, -134)
feedback.BackgroundTransparency = 1
feedback.Text = ""
feedback.TextColor3 = Color3.fromRGB(100, 255, 150)
feedback.Font = Enum.Font.GothamBold
feedback.TextSize = 12
feedback.Visible = false
feedback.Parent = frame

-- ================================================================
-- DRAGGABLE
-- ================================================================
local dragging, dragStart, startPos = false, nil, nil
frame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = frame.Position
		frame.ZIndex = 10
	end
end)
frame.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
		frame.ZIndex = 1
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)

-- ================================================================
-- LOGGING
-- ================================================================
local logEntries = {}
local logLabels = {}
local activePhase = "IDLE"

local function timestamp()
	local ms = DateTime.now().UnixTimestampMillis % 1000
	return string.format("%s.%03d", os.date("%H:%M:%S"), ms)
end

local function formatPos(pos)
	return string.format("%.1f, %.1f, %.1f", pos.X, pos.Y, pos.Z)
end

local function formatVec3(v)
	return string.format("%.1f, %.1f, %.1f", v.X, v.Y, v.Z)
end

local function safeState(humanoid)
	local ok, state = pcall(function() return humanoid:GetState() end)
	return ok and tostring(state) or "<state-error>"
end

local function safeFloor(humanoid)
	local ok, floor = pcall(function() return humanoid.FloorMaterial end)
	return ok and tostring(floor) or "<floor-error>"
end

local function addLogEntry(entryText)
	table.insert(logEntries, entryText)
	pcall(function() print(entryText) end)
	if #logEntries > MAX_LOG_ENTRIES then table.remove(logEntries, 1) end

	local entry = Instance.new("TextLabel")
	entry.Size = UDim2.new(1, -8, 0, 16)
	entry.BackgroundTransparency = 1
	entry.Text = entryText
	entry.TextColor3 = Color3.fromRGB(200, 200, 200)
	entry.Font = Enum.Font.Code
	entry.TextSize = 10
	entry.TextXAlignment = Enum.TextXAlignment.Left
	entry.TextTruncate = Enum.TextTruncate.AtEnd
	entry.Parent = logScroll

	table.insert(logLabels, entry)
	while #logLabels > MAX_LOG_ENTRIES do
		if logLabels[1] then logLabels[1]:Destroy() end
		table.remove(logLabels, 1)
	end

	logScroll.CanvasSize = UDim2.new(0, 0, 0, logList.AbsoluteContentSize.Y + 10)
	logScroll.CanvasPosition = Vector2.new(0, math.max(0, logScroll.CanvasSize.Y.Offset))
end

-- ----------------------------------------------------------------
-- FORENSICS STATE (declared here on purpose)
-- clearLog() below resets this state, and the toggle buttons are built below
-- that, so these have to exist BEFORE the UI section. They used to be declared
-- down in the scanner section: every write from clearLog() then silently
-- created a GLOBAL instead of touching the real local, so CLEAR reset nothing.
-- ----------------------------------------------------------------
local pendingJump = nil            -- a big displacement we are watching for a reversal
local evaluatePendingJump          -- assigned in the forensics layer
local deathConnection, anchoredConnection, touchConnection
local lastTouchLogged = {}
local netSamples, lastNetLog, lastFastAt, lastVoidWarn = {}, 0, 0, 0
local lastRigWarn, rigBaseline = 0, nil
local restChecked = true

local function clearLog()
	logEntries = {}
	logLabels = {}
	for _, c in ipairs(logScroll:GetChildren()) do
		if c:IsA("TextLabel") then c:Destroy() end
	end
	logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	-- reset the forensics state too, so a cleared log does not carry a stale
	-- pendingJump / rig baseline into the next session
	pendingJump, rigBaseline, lastTouchLogged = nil, nil, {}
	netSamples, lastNetLog, lastFastAt, lastVoidWarn = {}, 0, 0, 0
	lastRigWarn, restChecked = 0, true
end

-- ================================================================
-- NOCLIP / PHASE
-- ================================================================
local function setNoclip(character, enabled)
	local changed = 0
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			local wanted = not enabled
			if part.CanCollide ~= wanted then
				part.CanCollide = wanted
				changed += 1
			end
		end
	end
	return changed
end

local function countNoCollide(character)
	local total, nocollide = 0, 0
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			total += 1
			if not part.CanCollide then nocollide += 1 end
		end
	end
	return total, nocollide
end

local function setPhase(newPhase, humanoid, root)
	local oldPhase = activePhase
	activePhase = tostring(newPhase or "IDLE")
	if phaseLabel and phaseLabel.Parent and humanoid and humanoid.Parent then
		phaseLabel.Text = string.format("Phase: %s | HP: %.1f", activePhase, humanoid.Health)
	end
	if oldPhase ~= activePhase and humanoid and humanoid.Parent and root and root.Parent then
		addLogEntry(string.format(
			"[%s] PHASE | %s -> %s | state=%s | pos=(%s) | vel=(%s)",
			timestamp(), oldPhase, activePhase, safeState(humanoid), formatPos(root.Position), formatVec3(root.AssemblyLinearVelocity)
		))
	end
end

-- ================================================================
-- TRANSFORM APPLICATION
-- ================================================================
local function applyReferenceTransform(character, root, requestedPos)
	if not character or not character.Parent or not root or not root.Parent then
		return false
	end
	local yaw = math.rad(root.Orientation.Y)
	character:PivotTo(CFrame.new(requestedPos) * CFrame.Angles(0, yaw, 0))
	return true
end

local function safeUnbind()
	pcall(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
end

-- ================================================================
-- REPLAY ENGINE (exact ld-p3 profile)
-- ================================================================
local replicationRunning = false
local lastReplicationStart = 0

local function replicateFreefall()
	if replicationRunning then return end

	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then return end
	if humanoid.Health <= 0 then
		addLogEntry(string.format("[%s] START ABORTED | already dead", timestamp()))
		return
	end

	replicationRunning = true
	lastReplicationStart = os.clock()
	local originalAutoRotate = humanoid.AutoRotate
	local startPos = root.Position
	local noclipChanged = setNoclip(character, true)
	local abortedReason = nil

	local launchEnd = startPos + Vector3.new(LAUNCH_PROFILE[#LAUNCH_PROFILE].dx, LAUNCH_PROFILE[#LAUNCH_PROFILE].dy, LAUNCH_PROFILE[#LAUNCH_PROFILE].dz)
	local freefallOrigin = launchEnd
	local fixedY = launchEnd.Y
	local fixedZ = launchEnd.Z

	addLogEntry(string.format(
		"[%s] REPLAY START V7.1 | start=(%s) | launchEnd=(%s) | chunks=%d | noclip=%d",
		timestamp(), formatPos(startPos), formatPos(launchEnd), #FREEFALL_X_DELTAS, noclipChanged
	))

	feedback.Text = "Replaying ld-p3 (sticky)..."
	feedback.TextColor3 = Color3.fromRGB(255, 160, 90)
	feedback.Visible = true

	setPhase("LAUNCH", humanoid, root)

	-- Force Freefall early so the humanoid fights less
	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	humanoid.AutoRotate = false

	local startClock = os.clock()
	local launchIndex = 0
	local freefallIndex = 0
	local freefallStarted = false
	local dropDone = false
	local currentTarget = startPos          -- sticky target
	local consecutiveErrors = 0
	local MAX_CONSECUTIVE_ERRORS = 8        -- only abort after sustained fight
	local freefallClock = 0

	local function forceTransform(pos)
		if not character.Parent or not root.Parent then return false end
		local yaw = math.rad(root.Orientation.Y)
		local cf = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
		character:PivotTo(cf)
		root.CFrame = cf
		-- Keep velocity near zero so physics doesn't drag us
		root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
		return true
	end

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_STEP_PRIORITY, function(dt)
		if abortedReason or dropDone then return end
		if not character.Parent or not humanoid.Parent or not root.Parent then
			abortedReason = "character disappeared"
			return
		end
		if humanoid.Health <= 0 or humanoid:GetState() == Enum.HumanoidStateType.Dead then
			abortedReason = "Humanoid Dead"
			return
		end

		local elapsed = os.clock() - startClock

		-- Always re-apply the current sticky target first
		if currentTarget then
			forceTransform(currentTarget)
		end

		-- Check for sustained correction
		if currentTarget then
			local err = (root.Position - currentTarget).Magnitude
			if err > REPLAY_CORRECTION_TOLERANCE then
				consecutiveErrors += 1
				if consecutiveErrors == 1 or consecutiveErrors % 4 == 0 then
					addLogEntry(string.format(
						"[%s] CORRECTION FIGHT | err=%.1f | frames=%d | actual=(%s) | target=(%s)",
						timestamp(), err, consecutiveErrors, formatPos(root.Position), formatPos(currentTarget)
					))
				end
				if consecutiveErrors >= MAX_CONSECUTIVE_ERRORS then
					abortedReason = string.format("sustained correction %.1f studs", err)
					return
				end
			else
				consecutiveErrors = 0
			end
		end

		-- ---------- LAUNCH PHASE ----------
		if not freefallStarted then
			local nextIdx = launchIndex + 1
			if nextIdx <= #LAUNCH_PROFILE and elapsed >= LAUNCH_PROFILE[nextIdx].t then
				local item = LAUNCH_PROFILE[nextIdx]
				currentTarget = startPos + Vector3.new(item.dx, item.dy, item.dz)
				forceTransform(currentTarget)
				launchIndex = nextIdx

				addLogEntry(string.format(
					"[%s] LAUNCH CHUNK | i=%d/%d | t=%.3f | target=(%s) | actual=(%s) | state=%s",
					timestamp(), launchIndex, #LAUNCH_PROFILE, item.t,
					formatPos(currentTarget), formatPos(root.Position), safeState(humanoid)
				))

				if launchIndex >= #LAUNCH_PROFILE then
					freefallStarted = true
					freefallClock = os.clock()
					setPhase("FREEFALL", humanoid, root)
					humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
					addLogEntry(string.format(
						"[%s] FREEFALL START | pos=(%s) | state=%s",
						timestamp(), formatPos(root.Position), safeState(humanoid)
					))
				end
			end
			return
		end

		-- ---------- FREEFALL CHUNKS ----------
		if freefallStarted and freefallIndex < #FREEFALL_X_DELTAS then
			local nextIdx = freefallIndex + 1
			local targetTime = 0
			for i = 1, nextIdx do
				targetTime += (FREEFALL_CHUNK_TIMES[i] or 0.045)
			end

			if (os.clock() - freefallClock) >= targetTime then
				local dx = FREEFALL_X_DELTAS[nextIdx]
				local prevX = currentTarget and currentTarget.X or freefallOrigin.X
				currentTarget = Vector3.new(prevX + dx, fixedY, fixedZ)
				forceTransform(currentTarget)
				freefallIndex = nextIdx

				addLogEntry(string.format(
					"[%s] FREEFALL CHUNK | i=%d/%d | dx=%.1f | target=(%s) | actual=(%s) | state=%s",
					timestamp(), freefallIndex, #FREEFALL_X_DELTAS, dx,
					formatPos(currentTarget), formatPos(root.Position), safeState(humanoid)
				))
			end
			return
		end

		-- ---------- FINAL DROP ----------
		if freefallIndex >= #FREEFALL_X_DELTAS and not dropDone then
			currentTarget = Vector3.new(currentTarget.X, fixedY + DROP_OFFSET_Y, fixedZ)
			forceTransform(currentTarget)
			dropDone = true
			setPhase("DROP", humanoid, root)
			addLogEntry(string.format(
				"[%s] DROP | target=(%s) | actual=(%s) | state=%s",
				timestamp(), formatPos(currentTarget), formatPos(root.Position), safeState(humanoid)
			))
		end
	end)

	-- Wait
	while not dropDone and not abortedReason and character.Parent and humanoid.Parent do
		RunService.Heartbeat:Wait()
	end

	safeUnbind()
	setNoclip(character, false)
	if humanoid and humanoid.Parent then
		humanoid.AutoRotate = originalAutoRotate
	end

	if abortedReason then
		feedback.Text = "ABORT: " .. tostring(abortedReason)
		feedback.TextColor3 = Color3.fromRGB(255, 90, 90)
		addLogEntry(string.format("[%s] ABORTED | %s | pos=(%s)", timestamp(), abortedReason, root and formatPos(root.Position) or "?"))
	else
		setPhase("LANDING_WATCH", humanoid, root)
		local watchStart = os.clock()
		local lastState = humanoid:GetState()
		while character.Parent and humanoid.Parent and (os.clock() - watchStart) < 3.0 do
			local st = humanoid:GetState()
			if st ~= lastState then
				addLogEntry(string.format(
					"[%s] LANDING STATE | %s -> %s | pos=(%s) | floor=%s",
					timestamp(), tostring(lastState), tostring(st), formatPos(root.Position), safeFloor(humanoid)
				))
				lastState = st
			end
			if st == Enum.HumanoidStateType.Landed or st == Enum.HumanoidStateType.Running then
				break
			end
			RunService.Heartbeat:Wait()
		end
		addLogEntry(string.format(
			"[%s] REPLAY FINISHED | total=%.2fs | final=(%s) | state=%s",
			timestamp(), os.clock() - lastReplicationStart, formatPos(root.Position), safeState(humanoid)
		))
		feedback.Text = "Replay finished"
		feedback.TextColor3 = Color3.fromRGB(100, 255, 150)
	end

	setPhase("IDLE", humanoid, root)
	replicationRunning = false
	task.delay(2.5, function()
		if feedback and feedback.Parent then feedback.Visible = false end
	end)
end

-- ================================================================
-- HIGH-RESOLUTION TRANSFORM SCANNER (kept from V5)
-- ================================================================
local connection, stateConnection, healthConnection
local preSimulationConnection, postSimulationConnection, preRenderConnection
local cframeConnection
local transformCaptureEnabled = TRANSFORM_CAPTURE_DEFAULT
local forensicsEnabled = FORENSICS_DEFAULT
-- PER-SOURCE previous samples. This used to be ONE table shared by all four
-- stage channels (Heartbeat, PreSimulation, PostSimulation, PreRender), so each
-- channel overwrote the others' previous sample. That made `dt` a gap between
-- two DIFFERENT channels rather than a frame delta (hence dt=40.53135 on an idle
-- character), and it made `src` close to arbitrary - the reason src=PreSimulation
-- effectively never appeared in the logs.
local transformStagePrevious = {}
local transformPropertyPrevious = nil
local lastTransformJumpLogTime = 0
local lastTransformJumpLogPos = nil

local function setCaptureButton()
	captureBtn.Text = transformCaptureEnabled and "CAPTURE: ON" or "CAPTURE: OFF"
	captureBtn.BackgroundColor3 = transformCaptureEnabled and Color3.fromRGB(35, 110, 70) or Color3.fromRGB(90, 55, 55)
	captureBtn.TextColor3 = transformCaptureEnabled and Color3.fromRGB(220, 255, 230) or Color3.fromRGB(255, 220, 220)
end

local function resetTransformTelemetry(root)
	local now = os.clock()
	local pos = root.Position
	transformStagePrevious = {}   -- each channel gets its own slot on first use
	transformPropertyPrevious = { time = now, position = pos, velocity = root.AssemblyLinearVelocity, cframe = root.CFrame }
	lastTransformJumpLogTime = 0
	lastTransformJumpLogPos = pos
end

local function maybeLogTransformJump(source, humanoid, root, now, previousTime, previousPos, previousVel)
	if not transformCaptureEnabled or not humanoid or not root then return end
	local pos = root.Position
	local vel = root.AssemblyLinearVelocity
	local dt = math.max(now - previousTime, 1e-5)
	local delta = pos - previousPos
	local dist = delta.Magnitude
	local pSpeed = dist / dt
	local vMag = vel.Magnitude
	local velocityRatio = pSpeed / math.max(vMag, 0.1)

	local isJump = dist >= TRANSFORM_JUMP_MIN_DISTANCE
	local isMismatch = dist > 2 and pSpeed >= TRANSFORM_JUMP_MIN_PSPEED and velocityRatio >= TRANSFORM_JUMP_RATIO
	if not (isJump or isMismatch) then return end

	-- Remember a big displacement so the forensics tick can see whether the
	-- server KEEPS it. This is the check that was missing: a write that does not
	-- stick is otherwise indistinguishable from one that does.
	if forensicsEnabled and dist >= BIG_JUMP_STUDS then
		-- Settle any jump we were still watching FIRST. A reversion arrives as a
		-- jump of its own (the server puts us back), so without this the new
		-- sample simply overwrote the pending one and the reversal was never
		-- seen - the sampler wiped the evidence before the tick could read it.
		if evaluatePendingJump then evaluatePendingJump(humanoid, root, now) end
		pendingJump = {
			from = previousPos, to = pos, time = now, dist = dist,
			dir = dist > 1e-6 and (1 / dist) * delta or Vector3.zero,
		}
	end

	if lastTransformJumpLogPos and (now - lastTransformJumpLogTime) <= TRANSFORM_PROPERTY_DEDUPE_TIME
		and (pos - lastTransformJumpLogPos).Magnitude <= TRANSFORM_PROPERTY_DEDUPE_DISTANCE then
		return
	end

	lastTransformJumpLogTime = now
	lastTransformJumpLogPos = pos

	local class = isMismatch and "TRANSFORM_JUMP" or "LARGE_MOVE"
	addLogEntry(string.format(
		"[%s] %s | src=%s | phase=%s | state=%s | dt=%.5f | dP=(%s) | dist=%.2f | pSpd=%.1f | vel=(%s) | vMag=%.1f | vRatio=%.1fx%s | pos=(%s)",
		timestamp(), class, source, activePhase, safeState(humanoid), dt, formatVec3(delta), dist, pSpeed, formatVec3(vel), vMag, velocityRatio,
		-- vRatio = pSpeed / max(vMag, 0.1) is meaningless when vMag is 0: the
		-- ratio then just reports the clamp, so flag it instead of letting a
		-- huge number imply a mismatch that was never measured.
		vMag < 0.1 and " | zeroVel=1 (vRatio is the clamp, not a real ratio)" or "",
		formatPos(pos)
	))
end

local function sampleTransformStage(source, humanoid, root)
	if not transformCaptureEnabled or not root then return end
	local now = os.clock()
	-- keyed by source: a per-channel previous sample, so dt is a real frame delta
	-- for that channel and `src` means what it says
	local prev = transformStagePrevious[source]
	if not prev then
		transformStagePrevious[source] = {
			time = now, position = root.Position, velocity = root.AssemblyLinearVelocity,
		}
		return
	end
	maybeLogTransformJump(source, humanoid, root, now, prev.time, prev.position, prev.velocity)
	transformStagePrevious[source] = {
		time = now,
		position = root.Position,
		velocity = root.AssemblyLinearVelocity,
	}
end

local function sampleTransformProperty(source, humanoid, root)
	if not transformCaptureEnabled or not root then return end
	local now = os.clock()
	if not transformPropertyPrevious then
		transformPropertyPrevious = { time = now, position = root.Position, velocity = root.AssemblyLinearVelocity, cframe = root.CFrame }
		return
	end
	local prev = transformPropertyPrevious
	maybeLogTransformJump(source, humanoid, root, now, prev.time, prev.position, prev.velocity or root.AssemblyLinearVelocity)
	transformPropertyPrevious = {
		time = now,
		position = root.Position,
		velocity = root.AssemblyLinearVelocity,
		cframe = root.CFrame,
	}
end

-- ================================================================
-- FORENSICS LAYER (V8)
-- ================================================================
local ForensicsWorkspace = game:GetService("Workspace")

local function isGuardNamed(name)
	local n = string.lower(tostring(name))
	return string.find(n, "guard", 1, true) ~= nil
		or string.find(n, "bounds", 1, true) ~= nil
		or string.find(n, "collision", 1, true) ~= nil
end

local function pointInsidePart(part, pos)
	local ok, lp = pcall(function() return part.CFrame:PointToObjectSpace(pos) end)
	if not ok or not lp then return false end
	local ok2, size = pcall(function() return part.Size end)
	if not ok2 or not size then return false end
	return math.abs(lp.X) <= size.X / 2
		and math.abs(lp.Y) <= size.Y / 2
		and math.abs(lp.Z) <= size.Z / 2
end

local function partsAround(pos, radius)
	local char = player.Character
	local ok, list = pcall(function()
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char }
		return ForensicsWorkspace:GetPartBoundsInRadius(pos, radius, params)
	end)
	if ok and list then return list end
	return {}
end

-- How far is the ground below? nil means nothing within maxDistance.
-- safeFloor() reports FloorMaterial (a string), so it can never be used as a
-- height - the first version of the void check compared Y against that string
-- and was dead code. Measure the gap with a ray instead.
local function groundGap(pos, maxDistance)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	local ok, hit = pcall(function()
		return ForensicsWorkspace:Raycast(pos - Vector3.new(0, 3, 0),
			Vector3.new(0, -1, 0) * maxDistance, params)
	end)
	if not ok or not hit then return nil, nil end
	return (hit.Distance or 0) + 3, hit.Instance
end

-- What is straight ahead? Straight-line, from the root, along the facing
-- direction - so "I am flying into something" is visible before the impact.
local function obstacleAhead(root, maxDistance)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	local ok, hit = pcall(function()
		return ForensicsWorkspace:Raycast(root.Position,
			root.CFrame.LookVector * maxDistance, params)
	end)
	if not ok then return "<raycast-error>" end
	if not hit then return string.format("clear for %.0f studs", maxDistance) end
	local inst = hit.Instance
	local name = inst and inst:GetFullName() or "?"
	return string.format("%s | class=%s | %.1f studs | collide=%s | material=%s%s",
		name, inst and inst.ClassName or "?", hit.Distance or -1,
		tostring(inst and inst.CanCollide), tostring(inst and inst.Material),
		isGuardNamed(name) and " | GUARD-NAMED" or "")
end

-- Name what is near a point. Guard-named parts are flagged: the guard volumes and
-- collision walls were the furniture around every failure so far, and they are
-- invisible in a position-only log.
local function logNearby(pos, radius, label)
	local seen, n = {}, 0
	for _, p in ipairs(partsAround(pos, radius)) do
		local name = p:GetFullName()
		if not seen[name] then
			seen[name] = true
			n += 1
			if n <= 10 then
				addLogEntry(string.format(
					"[%s] %s | %s | class=%s | dist=%.1f | collide=%s | material=%s%s",
					timestamp(), label, name, p.ClassName,
					(p.Position - pos).Magnitude, tostring(p.CanCollide),
					tostring(p.Material), isGuardNamed(name) and " | GUARD-NAMED" or ""))
			end
		end
	end
	return n
end

local function logDeath(reason, humanoid, root)
	local pos = root and root.Position
	local char = player.Character
	local parts, nocollide = 0, 0
	if char then parts, nocollide = countNoCollide(char) end
	addLogEntry(string.format("[%s] ================ DEATH ================", timestamp()))
	addLogEntry(string.format("[%s]   reason     | %s", timestamp(), reason))
	addLogEntry(string.format("[%s]   health     | %.1f / %.1f  %s",
		timestamp(), humanoid and humanoid.Health or -1, humanoid and humanoid.MaxHealth or -1,
		(humanoid and humanoid.Health <= EXPLOIT_HP) and "<-- EXPLOIT HANDLER, not damage" or ""))
	addLogEntry(string.format("[%s]   state      | %s | pos=(%s)", timestamp(),
		humanoid and safeState(humanoid) or "?", formatPos(pos)))
	addLogEntry(string.format("[%s]   phase      | %s | nc=%d/%d | floor=%s",
		timestamp(), activePhase, nocollide, parts, humanoid and safeFloor(humanoid) or "?"))
	if root then
		addLogEntry(string.format("[%s]   velocity   | (%s) | anchored=%s",
			timestamp(), formatVec3(root.AssemblyLinearVelocity), tostring(root.Anchored)))
	end
	if pos then logNearby(pos, NEAR_RADIUS, "  NEAR") end
	addLogEntry(string.format("[%s] =======================================", timestamp()))
end

-- A rig that has stretched is joints tearing, which is a different problem from
-- the character moving and would otherwise be invisible.
local function checkRigStretch(root)
	local char = player.Character
	if not char or not root then return end
	local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
	local head = char:FindFirstChild("Head")
	if not (torso and head) then return end
	local dT = (torso.Position - root.Position).Magnitude
	local dH = (head.Position - root.Position).Magnitude
	if not rigBaseline then
		rigBaseline = { t = dT, h = dH }
		return
	end
	local now = os.clock()
	local dt_, dh_ = math.abs(dT - rigBaseline.t), math.abs(dH - rigBaseline.h)
	if (dt_ > RIG_STRETCH_STUDS or dh_ > RIG_STRETCH_STUDS) and (now - lastRigWarn) > 0.5 then
		lastRigWarn = now
		addLogEntry(string.format(
			"[%s] RIG STRETCH | torso %+.1f | head %+.1f | limit %.1f | state=%s | pos=(%s)",
			timestamp(), dT - rigBaseline.t, dH - rigBaseline.h, RIG_STRETCH_STUDS,
			safeState(char:FindFirstChildOfClass("Humanoid")), formatPos(root.Position)))
	end
end

local function checkResting(root)
	local char = player.Character
	if not char then return end
	local inside = 0
	for _, p in ipairs(partsAround(root.Position, 8)) do
		if p.CanCollide and pointInsidePart(p, root.Position) then
			inside += 1
			addLogEntry(string.format("[%s] INSIDE SOLID | %s | class=%s | material=%s",
				timestamp(), p:GetFullName(), p.ClassName, tostring(p.Material)))
		end
	end
	if inside == 0 then
		addLogEntry(string.format("[%s] AT REST | clear of solid geometry | pos=(%s)",
			timestamp(), formatPos(root.Position)))
	end
end

local function onTouched(myPart, other)
	if not forensicsEnabled or not other then return end
	local now = os.clock()
	local name = other:GetFullName()
	local first = not lastTouchLogged[name]
	-- The floor we walk on fires Touched constantly, and logging every one of
	-- those would bury the log. Rule: any part is reported the FIRST time it is
	-- touched, and after that only if it is interesting (guard-named or
	-- non-collidable, i.e. a trigger volume), rate-limited by TOUCH_DEDUPE_S.
	if not (first or isGuardNamed(name) or not other.CanCollide) then
		lastTouchLogged[name] = now
		return
	end
	if not first and (now - lastTouchLogged[name]) < TOUCH_DEDUPE_S then return end
	lastTouchLogged[name] = now
	addLogEntry(string.format(
		"[%s] TOUCHED | %s | class=%s | collide=%s | material=%s | my part=%s%s",
		timestamp(), name, other.ClassName, tostring(other.CanCollide),
		tostring(other.Material), myPart.Name,
		isGuardNamed(name) and " | GUARD-NAMED" or ""))
end

local function subscribeTouches(character)
	if touchConnection then
		for _, c in ipairs(touchConnection) do c:Disconnect() end
	end
	touchConnection = {}
	for _, p in ipairs(character:GetDescendants()) do
		if p:IsA("BasePart") then
			touchConnection[#touchConnection + 1] = p.Touched:Connect(function(other)
				onTouched(p, other)
			end)
		end
	end
	addLogEntry(string.format("[%s] TOUCH WATCH | %d parts subscribed",
		timestamp(), #touchConnection))
end

-- One tick, called from the same Heartbeat as the transform sampler.
local function forensicsTick(humanoid, root)
	if not forensicsEnabled or not root then return end
	local now = os.clock()
	local pos = root.Position
	local speed = root.AssemblyLinearVelocity.Magnitude

	-- ---- did the last big jump STICK? ----------------------------------
	evaluatePendingJump(humanoid, root, now)

	-- ---- net displacement while moving fast ------------------------------
	netSamples[#netSamples + 1] = { t = now, p = pos }
	while #netSamples > 1 and (now - netSamples[1].t) > NET_WINDOW_S do
		table.remove(netSamples, 1)
	end
	if speed >= NET_MIN_SPEED then lastFastAt = now; restChecked = false end
	if #netSamples > 1 and speed >= NET_MIN_SPEED and (now - lastNetLog) > 0.35 then
		lastNetLog = now
		local a, b = netSamples[1], netSamples[#netSamples]
		local d = b.p - a.p
		addLogEntry(string.format(
			"[%s] NET | %.2fs | dP=(%s) | net=%.1f | speed=%.1f | state=%s",
			timestamp(), b.t - a.t, formatVec3(d), d.Magnitude, speed, safeState(humanoid)))
	end

	-- ---- rig health, every tick ------------------------------------------
	-- joints tear WHILE moving, so this cannot wait for the next rest: it is
	-- rate-limited inside checkRigStretch instead
	checkRigStretch(root)

	-- ---- once we come to rest, check where we actually ended up ----------
	if not restChecked and speed < 5 and (now - lastFastAt) > 0.15 then
		restChecked = true
		checkResting(root)
	end

	-- ---- void proximity --------------------------------------------------
	-- One ray per second at most: this runs inside the Heartbeat.
	if (now - lastVoidWarn) > 1.0 then
		local gap, surface = groundGap(pos, VOID_WARN_STUDS + 50)
		if gap and gap > VOID_WARN_STUDS then
			lastVoidWarn = now
			addLogEntry(string.format(
				"[%s] VOID WARNING | ground %.1f studs below | limit %.1f | surface=%s",
				timestamp(), gap, VOID_WARN_STUDS,
				surface and surface:GetFullName() or "?"))
		elseif not gap then
			lastVoidWarn = now
			addLogEntry(string.format(
				"[%s] VOID WARNING | no ground within %.0f studs below | pos=(%s)",
				timestamp(), VOID_WARN_STUDS + 50, formatPos(pos)))
		end
	end
end

-- Did the last big jump actually hold? Called both from the tick and from the
-- sampler (before it arms a new jump).
evaluatePendingJump = function(humanoid, root, now)
	if not pendingJump or not root then return end
	local age = now - pendingJump.time
	local back = -(root.Position - pendingJump.to):Dot(pendingJump.dir)
	if back >= REVERT_MIN_STUDS then
		addLogEntry(string.format(
			"[%s] REVERTED | %.0f studs back %.2fs after a +%.0f stud jump",
			timestamp(), back, age, pendingJump.dist))
		addLogEntry(string.format(
			"[%s]   wrote to (%s) | now at (%s) | the write did NOT stick",
			timestamp(), formatPos(pendingJump.to), formatPos(root.Position)))
		pendingJump = nil
	elseif age > REVERT_WINDOW_S then
		addLogEntry(string.format(
			"[%s] KEPT | +%.0f stud jump held for %.1fs | landed (%s) | speed=%.1f",
			timestamp(), pendingJump.dist, age, formatPos(pendingJump.to),
			root.AssemblyLinearVelocity.Magnitude))
		pendingJump = nil
	end
end

local function disconnectForensics()
	for _, conn in ipairs({deathConnection, anchoredConnection}) do
		if conn then conn:Disconnect() end
	end
	deathConnection, anchoredConnection = nil, nil
	if touchConnection then
		for _, c in ipairs(touchConnection) do c:Disconnect() end
		touchConnection = nil
	end
	pendingJump, lastTouchLogged = nil, {}
	netSamples, lastNetLog, lastFastAt, lastVoidWarn = {}, 0, 0, 0
	lastRigWarn, rigBaseline, restChecked = 0, nil, true
end

local function disconnectTelemetry()
	disconnectForensics()
	for _, conn in ipairs({connection, stateConnection, healthConnection, preSimulationConnection, postSimulationConnection, preRenderConnection, cframeConnection}) do
		if conn then conn:Disconnect() end
	end
	connection, stateConnection, healthConnection = nil, nil, nil
	preSimulationConnection, postSimulationConnection, preRenderConnection, cframeConnection = nil, nil, nil, nil
end

local function startTracking(character)
	disconnectTelemetry()
	local root = character:WaitForChild("HumanoidRootPart", 5)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not root or not humanoid then return end

	resetTransformTelemetry(root)

	connection = RunService.Heartbeat:Connect(function()
		if not root.Parent or not humanoid.Parent then return end
		sampleTransformStage("Heartbeat", humanoid, root)
		forensicsTick(humanoid, root)
		local speed = root.AssemblyLinearVelocity.Magnitude
		speedLabel.Text = string.format("%.1f studs/s", speed)
		posLabel.Text = "Pos: " .. formatPos(root.Position)
		stateLabel.Text = "State: " .. tostring(humanoid:GetState())
		phaseLabel.Text = string.format("Phase: %s | HP: %.1f", activePhase, humanoid.Health)
		if speed < 16 then speedLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
		elseif speed < 50 then speedLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
		elseif speed < 120 then speedLabel.TextColor3 = Color3.fromRGB(0, 200, 255)
		else speedLabel.TextColor3 = Color3.fromRGB(255, 80, 80) end
	end)

	preSimulationConnection = RunService.PreSimulation:Connect(function()
		if root.Parent and humanoid.Parent then sampleTransformStage("PreSimulation", humanoid, root) end
	end)
	postSimulationConnection = RunService.PostSimulation:Connect(function()
		if root.Parent and humanoid.Parent then sampleTransformStage("PostSimulation", humanoid, root) end
	end)
	if RunService.PreRender then
		preRenderConnection = RunService.PreRender:Connect(function()
			if root.Parent and humanoid.Parent then sampleTransformStage("PreRender", humanoid, root) end
		end)
	end
	cframeConnection = root:GetPropertyChangedSignal("CFrame"):Connect(function()
		if root.Parent and humanoid.Parent then sampleTransformProperty("CFrameChanged", humanoid, root) end
	end)

	stateConnection = humanoid.StateChanged:Connect(function(old, new)
		if not root.Parent then return end
		local total, nc = countNoCollide(character)
		addLogEntry(string.format(
			"[%s] STATE | phase=%s | %s -> %s | speed=%.1f | pos=(%s) | hp=%.1f | floor=%s | nc=%d/%d",
			timestamp(), activePhase, tostring(old), tostring(new), root.AssemblyLinearVelocity.Magnitude,
			formatPos(root.Position), humanoid.Health, safeFloor(humanoid), nc, total
		))
	end)

	healthConnection = humanoid.HealthChanged:Connect(function(hp)
		-- A normal death arrives at 0. A large NEGATIVE value means something SET
		-- it, and -1000 specifically is the server's lethal exploit handler. This
		-- distinction cost a whole debugging session, because hp=0 and hp=-1000
		-- were reported the same way.
		local external = hp <= EXPLOIT_HP
		addLogEntry(string.format(
			"[%s] HEALTH | phase=%s | hp=%.1f/%.1f | %s | state=%s | pos=(%s)",
			timestamp(), activePhase, hp, humanoid.MaxHealth,
			external and "EXTERNAL KILL - health was SET, this is not damage"
				or "normal change",
			safeState(humanoid), formatPos(root.Position)))
		if external then
			logNearby(root.Position, NEAR_RADIUS, "  NEAR AT KILL")
		end
	end)

	deathConnection = humanoid.Died:Connect(function()
		logDeath("Humanoid.Died fired", humanoid, root)
	end)

	-- being Anchored explains "I cannot move at all" and nothing else would show it
	anchoredConnection = root:GetPropertyChangedSignal("Anchored"):Connect(function()
		addLogEntry(string.format("[%s] ANCHORED | %s | pos=(%s)",
			timestamp(), tostring(root.Anchored), formatPos(root.Position)))
	end)

	subscribeTouches(character)

	addLogEntry(string.format(
		"[%s] SCANNER READY V8 | jumpMin=%.1f | pspeedMin=%.1f | ratioMin=%.1f | capture=%s | forensics=%s",
		timestamp(), TRANSFORM_JUMP_MIN_DISTANCE, TRANSFORM_JUMP_MIN_PSPEED,
		TRANSFORM_JUMP_RATIO, tostring(transformCaptureEnabled), tostring(forensicsEnabled)))
	addLogEntry(string.format(
		"[%s]   baseline | hp=%.1f/%.1f | floor=%s | state=%s | pos=(%s)",
		timestamp(), humanoid.Health, humanoid.MaxHealth, safeFloor(humanoid),
		safeState(humanoid), formatPos(root.Position)))
	addLogEntry(string.format(
		"[%s]   watches | bigJump=%.0f | revert=%.0f in %.1fs | rigStretch=%.1f | net=%.1fs @ %.0f+ studs/s",
		timestamp(), BIG_JUMP_STUDS, REVERT_MIN_STUDS, REVERT_WINDOW_S,
		RIG_STRETCH_STUDS, NET_WINDOW_S, NET_MIN_SPEED))
end

-- ================================================================
-- BUTTONS
-- ================================================================
closeBtn.MouseButton1Click:Connect(function()
	disconnectTelemetry()
	safeUnbind()
	screenGui:Destroy()
end)

boostBtn.MouseButton1Click:Connect(function()
	task.spawn(function()
		local ok, err = xpcall(replicateFreefall, function(e)
			return tostring(e) .. "\n" .. debug.traceback()
		end)
		if not ok then
			addLogEntry(string.format("[%s] SCRIPT ERROR | %s", timestamp(), tostring(err)))
			feedback.Text = "SCRIPT ERROR"
			feedback.TextColor3 = Color3.fromRGB(255, 90, 90)
			feedback.Visible = true
		end
	end)
end)

copyBtn.MouseButton1Click:Connect(function()
	local success = pcall(function()
		setclipboard(table.concat(logEntries, "\n"))
	end)
	feedback.Text = success and "Log Copied!" or "Copy failed"
	feedback.TextColor3 = success and Color3.fromRGB(100, 255, 150) or Color3.fromRGB(255, 100, 100)
	feedback.Visible = true
	task.delay(1.8, function() if feedback and feedback.Parent then feedback.Visible = false end end)
end)

clearBtn.MouseButton1Click:Connect(function()
	clearLog()
	feedback.Text = "Log Cleared"
	feedback.TextColor3 = Color3.fromRGB(255, 180, 80)
	feedback.Visible = true
	task.delay(1.5, function() if feedback and feedback.Parent then feedback.Visible = false end end)
end)

forensicsBtn.MouseButton1Click:Connect(function()
	forensicsEnabled = not forensicsEnabled
	forensicsBtn.Text = forensicsEnabled and "FORENSICS: ON" or "FORENSICS: OFF"
	forensicsBtn.BackgroundColor3 = forensicsEnabled
		and Color3.fromRGB(35, 110, 70) or Color3.fromRGB(90, 55, 55)
	addLogEntry(string.format(
		"[%s] FORENSICS | %s | bigJump=%.0f revert=%.0f/%.1fs rigStretch=%.1f",
		timestamp(), forensicsEnabled and "ON" or "OFF", BIG_JUMP_STUDS,
		REVERT_MIN_STUDS, REVERT_WINDOW_S, RIG_STRETCH_STUDS))
	if not forensicsEnabled then
		pendingJump, rigBaseline = nil, nil
	end
	feedback.Text = forensicsEnabled and "Forensics ON" or "Forensics OFF"
	feedback.TextColor3 = forensicsEnabled and Color3.fromRGB(100, 255, 150)
		or Color3.fromRGB(255, 180, 80)
	feedback.Visible = true
	task.delay(1.5, function() if feedback and feedback.Parent then feedback.Visible = false end end)
end)

snapshotBtn.MouseButton1Click:Connect(function()
	-- On-demand: what is around us right now, is the rig stretched, and did we
	-- end up inside anything. Press this the moment something feels wrong.
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local rt = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and rt) then return end
	addLogEntry(string.format("[%s] ---- SNAPSHOT --------------------------", timestamp()))
	addLogEntry(string.format("[%s]   state=%s | hp=%.1f/%.1f | phase=%s | pos=(%s)",
		timestamp(), safeState(hum), hum.Health, hum.MaxHealth, activePhase, formatPos(rt.Position)))
	local gap, surface = groundGap(rt.Position, VOID_WARN_STUDS + 50)
	addLogEntry(string.format("[%s]   vel=(%s) | speed=%.1f | anchored=%s | floor=%s",
		timestamp(), formatVec3(rt.AssemblyLinearVelocity),
		rt.AssemblyLinearVelocity.Magnitude, tostring(rt.Anchored), safeFloor(hum)))
	addLogEntry(string.format("[%s]   ground below | %s | %s",
		timestamp(),
		gap and string.format("%.1f studs", gap) or "none within 100 studs",
		surface and surface:GetFullName() or "?"))
	addLogEntry(string.format("[%s]   ahead | %s", timestamp(),
		obstacleAhead(rt, OBSTACLE_AHEAD_STUDS)))
	logNearby(rt.Position, NEAR_RADIUS, "  SNAP NEAR")
	checkRigStretch(rt)
	checkResting(rt)
	addLogEntry(string.format("[%s] ----------------------------------------", timestamp()))
	feedback.Text = "Snapshot logged"
	feedback.TextColor3 = Color3.fromRGB(100, 255, 150)
	feedback.Visible = true
	task.delay(1.5, function() if feedback and feedback.Parent then feedback.Visible = false end end)
end)

captureBtn.MouseButton1Click:Connect(function()
	transformCaptureEnabled = not transformCaptureEnabled
	setCaptureButton()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if transformCaptureEnabled and root then resetTransformTelemetry(root) end
	addLogEntry(string.format("[%s] TRANSFORM CAPTURE %s", timestamp(), transformCaptureEnabled and "ENABLED" or "DISABLED"))
end)

local function addHover(btn, normal, hover)
	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = hover}):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = normal}):Play()
	end)
end
addHover(closeBtn, Color3.fromRGB(40, 40, 50), Color3.fromRGB(70, 30, 30))
addHover(boostBtn, Color3.fromRGB(180, 40, 40), Color3.fromRGB(220, 60, 60))
addHover(copyBtn, Color3.fromRGB(0, 140, 180), Color3.fromRGB(0, 180, 220))
addHover(clearBtn, Color3.fromRGB(80, 40, 40), Color3.fromRGB(120, 50, 50))
addHover(captureBtn, Color3.fromRGB(35, 110, 70), Color3.fromRGB(45, 140, 90))
setCaptureButton()

addLogEntry(string.format("[%s] SCRIPT READY V7 | capture=%s", timestamp(), tostring(transformCaptureEnabled)))

player.CharacterAdded:Connect(startTracking)
if player.Character then
	startTracking(player.Character)
end