--[[
    REPLICATE FREEFALL + NOCLIP — TRANSFORM TRACE V5
    LocalScript -> StarterPlayerScripts or StarterGui

    Purpose:
      Reproduce the observed sequence while collecting high-resolution
      transform telemetry to distinguish physics velocity from large
      position/replication jumps.

    V4 additions:
      - Samples PreSimulation / PostSimulation / Heartbeat / PreRender.
      - Detects large transform jumps and compares them with AssemblyLinearVelocity.
      - Watches HumanoidRootPart.CFrame changes directly.
      - Logs RunService Misprediction / Rollback when available.
      - Records jump distance, dt, positional speed, velocity magnitude,
        velocity ratio, and approximate velocity-predicted distance.
      - Keeps the actual replication test behavior unchanged; telemetry is diagnostic.

    Observed target sequence used as the reference:
      Ground:      X ~5669.9, Y ~70.7, Z ~-325.4
      Launch:      moves roughly -560 X while rising to Y ~112.4
      Freefall:    single Running -> Freefall transition
      Travel:      Freefall X ~5109.5 -> ~612.2, Z nearly unchanged
      Landing:     natural fall to Y ~70.7, then Landed -> Running

    Important differences from the previous version:
      - Does NOT force Freefall every Heartbeat.
      - Does NOT zero AssemblyLinearVelocity every Heartbeat.
      - Does NOT force Y=112.7 throughout the horizontal phase by default.
      - Stops immediately if the Humanoid actually becomes Dead.
      - Restores noclip on abort/finish.
      - Adds detailed phase/position/velocity/health/state diagnostics.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ================================================================
-- CONFIG — KEEP THESE EASY TO TUNE AFTER THE NEXT TEST
-- ================================================================
local DEBUG_SAMPLE_INTERVAL = 0.10
local MAX_LOG_ENTRIES = 500

-- High-resolution transform diagnostics. These are read-only observations.
local TRANSFORM_CAPTURE_DEFAULT = true
local TRANSFORM_JUMP_MIN_DISTANCE = 8.0
local TRANSFORM_JUMP_MIN_PSPEED = 750.0
local TRANSFORM_JUMP_RATIO = 3.0
local TRANSFORM_PROPERTY_DEDUPE_TIME = 0.006
local TRANSFORM_PROPERTY_DEDUPE_DISTANCE = 2.0

-- The movement test below is trace-driven. These legacy smooth-velocity
-- knobs are intentionally removed: the supplied trace does not look like
-- velocity-driven travel, so the replay uses discrete RenderStep chunks.

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
frame.Size = UDim2.new(0, 340, 0, 430)
frame.Position = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
frame.BackgroundTransparency = 0.12
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(0, 200, 255)
stroke.Thickness = 2
stroke.Transparency = 0.3
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 0, 26)
title.Position = UDim2.new(0, 12, 0, 6)
title.BackgroundTransparency = 1
title.Text = "REFERENCE TRANSFORM + DEBUG TRACE"
title.TextColor3 = Color3.fromRGB(0, 200, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
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
logTitle.Text = "DETAILED EVENT LOG"
logTitle.TextColor3 = Color3.fromRGB(0, 180, 220)
logTitle.Font = Enum.Font.GothamBold
logTitle.TextSize = 12
logTitle.TextXAlignment = Enum.TextXAlignment.Left
logTitle.Parent = frame

local logScroll = Instance.new("ScrollingFrame")
logScroll.Name = "LogScroll"
logScroll.Size = UDim2.new(1, -20, 0, 145)
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
buttonFrame.Size = UDim2.new(1, -20, 0, 70)
buttonFrame.Position = UDim2.new(0, 10, 1, -80)
buttonFrame.BackgroundTransparency = 1
buttonFrame.Parent = frame

local boostBtn = Instance.new("TextButton")
boostBtn.Size = UDim2.new(1, 0, 0, 32)
boostBtn.Position = UDim2.new(0, 0, 0, 0)
boostBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
boostBtn.Text = "REPLAY REFERENCE TRANSFORM"
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
captureBtn.Position = UDim2.new(0, 238, 0, 40)
captureBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 70)
captureBtn.Text = "CAPTURE: ON"
captureBtn.TextColor3 = Color3.fromRGB(220, 255, 230)
captureBtn.Font = Enum.Font.GothamBold
captureBtn.TextSize = 11
captureBtn.Parent = buttonFrame
Instance.new("UICorner", captureBtn).CornerRadius = UDim.new(0, 6)

local feedback = Instance.new("TextLabel")
feedback.Size = UDim2.new(0, 190, 0, 18)
feedback.Position = UDim2.new(1, -200, 1, -18)
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
		frame.Position = UDim2.new(
			startPos.X.Scale,
			startPos.X.Offset + delta.X,
			startPos.Y.Scale,
			startPos.Y.Offset + delta.Y
		)
	end
end)

-- ================================================================
-- LOGGING
-- ================================================================
local logEntries = {}
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
	local ok, state = pcall(function()
		return humanoid:GetState()
	end)
	return ok and tostring(state) or "<state-error>"
end

local function safeFloor(humanoid)
	local ok, floor = pcall(function()
		return humanoid.FloorMaterial
	end)
	return ok and tostring(floor) or "<floor-error>"
end

local function addLogEntry(entryText)
	table.insert(logEntries, entryText)
	pcall(function() print(entryText) end)
	if #logEntries > MAX_LOG_ENTRIES then
		table.remove(logEntries, 1)
	end

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

	local labels = {}
	for _, c in ipairs(logScroll:GetChildren()) do
		if c:IsA("TextLabel") then
			table.insert(labels, c)
		end
	end

	while #labels > MAX_LOG_ENTRIES do
		labels[1]:Destroy()
		table.remove(labels, 1)
	end

	logScroll.CanvasSize = UDim2.new(0, 0, 0, logList.AbsoluteContentSize.Y + 10)
	logScroll.CanvasPosition = Vector2.new(0, math.max(0, logScroll.CanvasSize.Y.Offset))
end

local function clearLog()
	logEntries = {}
	for _, c in ipairs(logScroll:GetChildren()) do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
end

-- ================================================================
-- NOCLIP
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
			if not part.CanCollide then
				nocollide += 1
			end
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
-- ================================================================
-- REFERENCE REPLAY / RENDER-STEP REPLICATION TEST
-- ================================================================
-- This version is deliberately based on the supplied trace rather than
-- treating the movement as ordinary velocity-based physics.
--
-- The reference trace showed:
--   • large CFrame/position jumps first visible at PreRender
--   • almost zero horizontal AssemblyLinearVelocity
--   • Running -> Freefall only after the launch transform sequence
--   • horizontal movement in discrete chunks while Y stays ~112.6
--   • natural gravity/landing after the final horizontal position
--
-- The replay therefore uses BindToRenderStep and a fixed, trace-derived
-- position profile. It still aborts on a large correction instead of trying
-- to fight the game's/server authority.

local replicationRunning = false
local lastReplicationStart = 0

-- RenderStep configuration.
local RENDER_STEP_NAME = "ReferenceFreefallReplay"
local RENDER_STEP_PRIORITY = Enum.RenderPriority.Character.Value + 1
local REPLAY_CORRECTION_TOLERANCE = 20.0
local REPLAY_MIN_FREEFALL_Y = 100.0
local REPLAY_USE_TRACE_PROFILE = true

-- The launch trace was approximately:
--   start      ~ (5661.7, 70.7, -324.9)
--   +0.361 sec  -> (-98.0, +9.8)
--   +0.384 sec  -> (-200.9, +20.1)
--   +0.419 sec  -> (-345.3, +34.5)
--   +0.457 sec  -> (-420.8, +42.0)
--
-- Values are stored as offsets so the test can start from the character's
-- current position.
local LAUNCH_TRACE_PROFILE = {
	{t = 0.000, dx = 0.0,   dy = 0.0,  dz = 0.0},
	{t = 0.361, dx = -98.0, dy = 9.8,  dz = 0.0},
	{t = 0.384, dx = -200.9,dy = 20.1, dz = 0.0},
	{t = 0.419, dx = -345.3,dy = 34.5, dz = 0.0},
	{t = 0.457, dx = -420.8,dy = 42.0, dz = 0.0},
}

-- Freefall horizontal trace reconstructed from the supplied log.
-- t=0 starts at the last launch point (~5240.9, 112.7, -324.9).
-- These are the actual observed X chunks, not a constant-speed model.
local FREEFALL_TRACE_PROFILE = {
	{t = 0.000, dx = 0.0,     dy = 0.0, dz = 0.0},
	{t = 0.047, dx = -205.5,  dy = -0.1, dz = 0.0},
	{t = 0.083, dx = -358.7,  dy = -0.1, dz = 0.0},
	{t = 0.116, dx = -420.8,  dy = -0.1, dz = 0.0},
	{t = 0.150, dx = -564.0,  dy = -0.1, dz = 0.0},
	{t = 0.190, dx = -725.5,  dy =  0.0, dz = 0.0},
	{t = 0.226, dx = -841.6,  dy =  0.0, dz = 0.0},
	{t = 0.262, dx = -993.7,  dy = -0.1, dz = 0.0},
	{t = 0.295, dx = -1133.1, dy = -0.1, dz = 0.0},
	{t = 0.331, dx = -1262.3, dy =  0.0, dz = 0.0},
	{t = 0.366, dx = -1410.9, dy = -0.1, dz = 0.0},
	{t = 0.506, dx = -1683.1, dy =  0.0, dz = 0.0},
	{t = 0.537, dx = -1813.5, dy = -0.1, dz = 0.0},
	{t = 0.562, dx = -1922.3, dy = -0.1, dz = 0.0},
	{t = 0.636, dx = -2103.9, dy = -0.1, dz = 0.0},
	{t = 0.703, dx = -2389.1, dy = -0.1, dz = 0.0},
	{t = 0.740, dx = -2524.7, dy = -0.1, dz = 0.0},
	{t = 0.779, dx = -2689.9, dy = -0.1, dz = 0.0},
	{t = 0.814, dx = -2832.8, dy = -0.1, dz = 0.0},
	{t = 0.848, dx = -2945.5, dy = -0.1, dz = 0.0},
	{t = 0.888, dx = -3106.7, dy = -0.1, dz = 0.0},
	{t = 0.921, dx = -3255.4, dy = -0.1, dz = 0.0},
	{t = 0.960, dx = -3366.3, dy = -0.1, dz = 0.0},
	{t = 0.999, dx = -3536.2, dy = -0.1, dz = 0.0},
	{t = 1.032, dx = -3680.3, dy =  0.0, dz = 0.0},
	{t = 1.073, dx = -3787.1, dy =  0.0, dz = 0.0},
	{t = 1.121, dx = -3970.6, dy = -0.1, dz = 0.0},
	{t = 1.155, dx = -4138.9, dy =  0.0, dz = 0.0},
	{t = 1.186, dx = -4207.9, dy =  0.0, dz = 0.0},
	{t = 1.223, dx = -4364.2, dy = -0.1, dz = 0.0},
	{t = 1.256, dx = -4501.7, dy =  0.0, dz = 0.0},
	{t = 1.290, dx = -4628.7, dy =  0.0, dz = 0.0},
}

-- Profile coordinates are relative to the launch/freefall transition so the
-- replay follows the same chunk pattern even when the character starts at a
-- slightly different absolute world X/Z.

local function safeUnbindReferenceReplay()
	pcall(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
end

local function applyReferenceTransform(character, root, requestedPos)
	if not character or not character.Parent or not root or not root.Parent then
		return false
	end

	local yaw = math.rad(root.Orientation.Y)
	character:PivotTo(CFrame.new(requestedPos) * CFrame.Angles(0, yaw, 0))
	return true
end

local function waitRenderProfile(character, humanoid, root, profile, origin, fixedY, phaseName, allowYFromProfile)
	local startClock = os.clock()
	local appliedIndex = 0
	local finished = false
	local abortedReason = nil
	local previousRequested = nil

	local function profilePosition(item)
		local y = fixedY
		if allowYFromProfile then
			y = origin.Y + item.dy
		end
		return Vector3.new(
			origin.X + item.dx,
			y,
			origin.Z + item.dz
		)
	end

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_STEP_PRIORITY, function()
		if finished or abortedReason then
			return
		end

		if not character.Parent or not humanoid.Parent or not root.Parent then
			abortedReason = "character/root/humanoid disappeared"
			return
		end

		if humanoid.Health <= 0 or humanoid:GetState() == Enum.HumanoidStateType.Dead then
			abortedReason = "Humanoid became Dead during " .. phaseName
			return
		end

		local elapsed = os.clock() - startClock
		local wantedIndex = appliedIndex + 1
		while wantedIndex <= #profile and elapsed >= profile[wantedIndex].t do
			local item = profile[wantedIndex]
			local requested = profilePosition(item)

			-- Before applying a new chunk, detect whether the previous requested
			-- transform survived. A large mismatch means the game's authority has
			-- corrected the character, so do not continue pushing.
			if previousRequested then
				local errorMag = (root.Position - previousRequested).Magnitude
				if errorMag > REPLAY_CORRECTION_TOLERANCE then
					addLogEntry(string.format(
						"[%s] RENDER REPLAY CORRECTION | phase=%s | req=(%s) | actual=(%s) | error=%.1f | state=%s | hp=%.1f",
						timestamp(), phaseName, formatPos(previousRequested), formatPos(root.Position), errorMag, safeState(humanoid), humanoid.Health
					))
					abortedReason = string.format("transform correction %.1f studs", errorMag)
					return
				end
			end

			if not applyReferenceTransform(character, root, requested) then
				abortedReason = "failed to apply render transform"
				return
			end

			appliedIndex = wantedIndex
			previousRequested = requested

			addLogEntry(string.format(
				"[%s] RENDER CHUNK | phase=%s | i=%d/%d | t=%.3f | req=(%s) | actual=(%s) | state=%s | vel=(%s)",
				timestamp(), phaseName, appliedIndex, #profile, item.t, formatPos(requested), formatPos(root.Position), safeState(humanoid), formatVec3(root.AssemblyLinearVelocity)
			))

			wantedIndex += 1
		end

		if appliedIndex >= #profile then
			finished = true
		end
	end)

	while not finished and not abortedReason and character.Parent and humanoid.Parent and root.Parent do
		RunService.Heartbeat:Wait()
	end

	safeUnbindReferenceReplay()
	return finished, abortedReason
end

local function replicateFreefall()
	if replicationRunning then
		return
	end

	local character = player.Character
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then return end

	if humanoid.Health <= 0 then
		addLogEntry(string.format("[%s] START ABORTED | humanoid already dead", timestamp()))
		return
	end

	replicationRunning = true
	lastReplicationStart = os.clock()

	local originalAutoRotate = humanoid.AutoRotate
	local startPos = root.Position
	local noclipChanged = setNoclip(character, true)

	-- The supplied trace is near these values. The profile below is relative
	-- so small differences in the starting position do not break the test.
	local launchTarget = startPos + Vector3.new(-420.8, 42.0, 0.0)
	local freefallStart = launchTarget
	local freefallEnd = freefallStart + Vector3.new(-4628.7, 0.0, 0.0)

	local abortedReason = nil
	
	addLogEntry(string.format(
		"[%s] REFERENCE REPLAY START | renderStep=%s | start=(%s) | launch=(%s) | end=(%s) | noclip=%d",
		timestamp(), RENDER_STEP_NAME, formatPos(startPos), formatPos(launchTarget), formatPos(freefallEnd), noclipChanged
	))

	addLogEntry(string.format(
		"[%s] REFERENCE REPLAY MODE | launchProfile=%d points | freefallProfile=%d points | correctionTol=%.1f | minFFY=%.1f",
		timestamp(), #LAUNCH_TRACE_PROFILE, #FREEFALL_TRACE_PROFILE, REPLAY_CORRECTION_TOLERANCE, REPLAY_MIN_FREEFALL_Y
	))

	feedback.Text = "Reference RenderStep replay..."
	feedback.TextColor3 = Color3.fromRGB(255, 160, 90)
	feedback.Visible = true

	local function abort(reason)
		if abortedReason then return end
		abortedReason = reason
		safeUnbindReferenceReplay()
		addLogEntry(string.format(
			"[%s] ABORT | reason=%s | phase=%s | state=%s | hp=%.1f | pos=(%s) | vel=(%s)",
			timestamp(), tostring(reason), activePhase, safeState(humanoid), humanoid.Health, formatPos(root.Position), formatVec3(root.AssemblyLinearVelocity)
		))
	end

	-- ============================================================
	-- PHASE 1: TRACE-DERIVED LAUNCH
	-- ============================================================
	activePhase = "LAUNCH_RENDER"
	setPhase("LAUNCH_RENDER", humanoid, root)

	local launchOrigin = startPos
	local launchProfile = {}
	for _, p in ipairs(LAUNCH_TRACE_PROFILE) do
		table.insert(launchProfile, {
			t = p.t,
			dx = p.dx,
			dy = p.dy,
			dz = p.dz,
		})
	end

	local launchOk, launchError = waitRenderProfile(
		character,
		humanoid,
		root,
		launchProfile,
		launchOrigin,
		startPos.Y,
		"LAUNCH_RENDER",
		true
	)

	if not launchOk then
		abort(launchError or "launch render profile failed")
	end

	if not abortedReason then
		local launchErrorMag = (root.Position - launchTarget).Magnitude
		addLogEntry(string.format(
			"[%s] LAUNCH PROFILE END | actual=(%s) | target=(%s) | error=%.1f | state=%s | vel=(%s)",
			timestamp(), formatPos(root.Position), formatPos(launchTarget), launchErrorMag, safeState(humanoid), formatVec3(root.AssemblyLinearVelocity)
		))

		if launchErrorMag > REPLAY_CORRECTION_TOLERANCE then
			abort(string.format("launch endpoint mismatch %.1f studs", launchErrorMag))
		end
	end

	-- ============================================================
	-- PHASE 2: SINGLE FREEFALL TRANSITION
	-- ============================================================
	if not abortedReason then
		activePhase = "FREEFALL_INIT"
		setPhase("FREEFALL_INIT", humanoid, root)

		addLogEntry(string.format(
			"[%s] FREEFALL TRANSITION | before=%s | pos=(%s) | floor=%s | vel=(%s)",
			timestamp(), safeState(humanoid), formatPos(root.Position), safeFloor(humanoid), formatVec3(root.AssemblyLinearVelocity)
		))

		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		RunService.Heartbeat:Wait()

		addLogEntry(string.format(
			"[%s] FREEFALL AFTER REQUEST | state=%s | pos=(%s) | vel=(%s) | y=%.1f",
			timestamp(), safeState(humanoid), formatPos(root.Position), formatVec3(root.AssemblyLinearVelocity), root.Position.Y
		))

		if humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
			abort("Freefall transition was not retained")
		elseif root.Position.Y < REPLAY_MIN_FREEFALL_Y then
			abort(string.format("Freefall started too low: Y=%.1f", root.Position.Y))
		end
	end

	-- ============================================================
	-- PHASE 3: TRACE-DERIVED FREEFALL CHUNKS
	-- ============================================================
	if not abortedReason then
		activePhase = "FREEFALL_RENDER"
		setPhase("FREEFALL_RENDER", humanoid, root)

		local travelOrigin = freefallStart
		local fixedY = freefallStart.Y

		-- Keep the observed reference Y around 112.6 while the physical
		-- AssemblyLinearVelocity remains whatever the engine reports.
		local travelOk, travelError = waitRenderProfile(
			character,
			humanoid,
			root,
			FREEFALL_TRACE_PROFILE,
			travelOrigin,
			fixedY,
			"FREEFALL_RENDER",
			false
		)

		if not travelOk then
			abort(travelError or "freefall render profile failed")
		end
	end

	-- ============================================================
	-- PHASE 4: RELEASE INTO NORMAL PHYSICS
	-- ============================================================
	if not abortedReason then
		activePhase = "RELEASE"
		setPhase("RELEASE", humanoid, root)

		-- One final position sample at the reference endpoint.
		applyReferenceTransform(character, root, freefallEnd)

		addLogEntry(string.format(
			"[%s] RELEASE | target=(%s) | actual=(%s) | state=%s | vel=(%s)",
			timestamp(), formatPos(freefallEnd), formatPos(root.Position), safeState(humanoid), formatVec3(root.AssemblyLinearVelocity)
		))

		local restored = setNoclip(character, false)
		addLogEntry(string.format(
			"[%s] NOCLIP RESTORED | changed=%d | state=%s | floor=%s",
			timestamp(), restored, safeState(humanoid), safeFloor(humanoid)
		))

		local landingWatchStart = os.clock()
		local lastState = humanoid:GetState()
		local landed = false

		while character.Parent and humanoid.Parent and root.Parent and (os.clock() - landingWatchStart) < 4.0 do
			if humanoid.Health <= 0 or humanoid:GetState() == Enum.HumanoidStateType.Dead then
				abort("Humanoid became Dead during RELEASE/LANDING")
				break
			end

			local stateNow = humanoid:GetState()
			if stateNow ~= lastState then
				addLogEntry(string.format(
					"[%s] LANDING STATE | %s -> %s | pos=(%s) | vel=(%s) | hp=%.1f | floor=%s",
					timestamp(), tostring(lastState), tostring(stateNow), formatPos(root.Position), formatVec3(root.AssemblyLinearVelocity), humanoid.Health, safeFloor(humanoid)
				))
				lastState = stateNow
			end

			if stateNow == Enum.HumanoidStateType.Landed then
				landed = true
				break
			end

			RunService.Heartbeat:Wait()
		end

		addLogEntry(string.format(
			"[%s] LANDING WATCH END | landed=%s | elapsed=%.2f | state=%s | hp=%.1f | pos=(%s)",
			timestamp(), tostring(landed), os.clock() - landingWatchStart, safeState(humanoid), humanoid.Health, formatPos(root.Position)
		))
	end

	-- ============================================================
	-- CLEANUP
	-- ============================================================
	safeUnbindReferenceReplay()

	if character and character.Parent then
		local restored = setNoclip(character, false)
		if restored > 0 then
			addLogEntry(string.format("[%s] CLEANUP NOCLIP | changed=%d", timestamp(), restored))
		end
	end

	if humanoid and humanoid.Parent then
		humanoid.AutoRotate = originalAutoRotate
	end

	if abortedReason then
		feedback.Text = "ABORT: " .. tostring(abortedReason)
		feedback.TextColor3 = Color3.fromRGB(255, 90, 90)
	else
		addLogEntry(string.format(
			"[%s] REFERENCE REPLAY FINISHED | total=%.2fs | state=%s | hp=%.1f | pos=(%s) | vel=(%s)",
			timestamp(), os.clock() - lastReplicationStart, safeState(humanoid), humanoid.Health, formatPos(root.Position), formatVec3(root.AssemblyLinearVelocity)
		))
		feedback.Text = "Reference replay finished"
		feedback.TextColor3 = Color3.fromRGB(100, 255, 150)
	end

	activePhase = "IDLE"
	phaseLabel.Text = string.format("Phase: IDLE | HP: %.1f", humanoid.Health)
	replicationRunning = false

	task.delay(2, function()
		if feedback and feedback.Parent then
			feedback.Visible = false
		end
	end)
end

-- TRACKING
-- ================================================================
local connection, stateConnection, healthConnection
local disconnectTelemetryConnections
local preSimulationConnection, postSimulationConnection, preRenderConnection
local cframeConnection, mispredictionConnection, rollbackConnection
local lastSpeed = 0
local SPEED_THRESHOLD = 6
local transformCaptureEnabled = TRANSFORM_CAPTURE_DEFAULT

local transformStagePrevious = nil
local transformPropertyPrevious = nil
local lastTransformJumpLogTime = 0
local lastTransformJumpLogPos = nil

local function setCaptureButton()
	captureBtn.Text = transformCaptureEnabled and "CAPTURE: ON" or "CAPTURE: OFF"
	captureBtn.BackgroundColor3 = transformCaptureEnabled
		and Color3.fromRGB(35, 110, 70)
		or Color3.fromRGB(90, 55, 55)
	captureBtn.TextColor3 = transformCaptureEnabled
		and Color3.fromRGB(220, 255, 230)
		or Color3.fromRGB(255, 220, 220)
end

local function resetTransformTelemetry(root)
	local now = os.clock()
	local pos = root.Position
	transformStagePrevious = {
		time = now,
		position = pos,
		velocity = root.AssemblyLinearVelocity,
		angularVelocity = root.AssemblyAngularVelocity,
		source = "RESET",
	}
	transformPropertyPrevious = {
		time = now,
		position = pos,
		velocity = root.AssemblyLinearVelocity,
		cframe = root.CFrame,
	}
	lastTransformJumpLogTime = 0
	lastTransformJumpLogPos = pos
end

local function safeCharacterMotionState(humanoid, root)
	return safeState(humanoid), root.Position, root.AssemblyLinearVelocity, root.AssemblyAngularVelocity
end

local function maybeLogTransformJump(source, humanoid, root, now, previousTime, previousPos, previousVel)
	if not transformCaptureEnabled or not humanoid or not humanoid.Parent or not root or not root.Parent then
		return
	end

	local pos = root.Position
	local vel = root.AssemblyLinearVelocity
	local ang = root.AssemblyAngularVelocity
	local dt = math.max(now - previousTime, 1 / 10000)
	local delta = pos - previousPos
	local dist = delta.Magnitude
	local pSpeed = dist / dt
	local vMag = vel.Magnitude
	local previousVMag = previousVel.Magnitude
	local avgVMag = (previousVMag + vMag) * 0.5
	local predictedDist = avgVMag * dt
	local velocityRatio = pSpeed / math.max(vMag, 0.1)
	local kinematicRatio = dist / math.max(predictedDist, 0.01)

	local isJump = dist >= TRANSFORM_JUMP_MIN_DISTANCE
	local isVelocityMismatch = dist > 2.0
		and pSpeed >= TRANSFORM_JUMP_MIN_PSPEED
		and velocityRatio >= TRANSFORM_JUMP_RATIO

	if not (isJump or isVelocityMismatch) then
		return
	end

	local duplicate = false
	if lastTransformJumpPos then
		duplicate = (now - lastTransformJumpLogTime) <= TRANSFORM_PROPERTY_DEDUPE_TIME
			and (pos - lastTransformJumpPos).Magnitude <= TRANSFORM_PROPERTY_DEDUPE_DISTANCE
	end

	if duplicate then
		return
	end

	lastTransformJumpLogTime = now
	lastTransformJumpLogPos = pos

	local class = isVelocityMismatch and "TRANSFORM_JUMP" or "LARGE_MOVE"
	addLogEntry(string.format(
		"[%s] %s | src=%s | phase=%s | state=%s | dt=%.5f | dP=(%s) | dist=%.2f | pSpd=%.1f | vel=(%s) | vMag=%.1f | vRatio=%.1fx | pred=%.2f | kRatio=%.1fx | ang=(%s) | pos=(%s)",
		timestamp(),
		class,
		source,
		activePhase,
		safeState(humanoid),
		dt,
		formatVec3(delta),
		dist,
		pSpeed,
		formatVec3(vel),
		vMag,
		velocityRatio,
		predictedDist,
		kinematicRatio,
		formatVec3(ang),
		formatPos(pos)
	))
end

local function sampleTransformStage(source, humanoid, root)
	if not transformCaptureEnabled or not root or not root.Parent then return end
	local now = os.clock()
	if not transformStagePrevious then
		resetTransformTelemetry(root)
		return
	end

	local prev = transformStagePrevious
	maybeLogTransformJump(source, humanoid, root, now, prev.time, prev.position, prev.velocity)

	transformStagePrevious = {
		time = now,
		position = root.Position,
		velocity = root.AssemblyLinearVelocity,
		angularVelocity = root.AssemblyAngularVelocity,
		source = source,
	}
end

local function sampleTransformProperty(source, humanoid, root)
	if not transformCaptureEnabled or not root or not root.Parent then return end
	local now = os.clock()
	local currentPos = root.Position
	local currentCFrame = root.CFrame

	if not transformPropertyPrevious then
		transformPropertyPrevious = {
			time = now,
			position = currentPos,
			velocity = root.AssemblyLinearVelocity,
			cframe = currentCFrame,
		}
		return
	end

	local prev = transformPropertyPrevious
	local previousVel = prev.velocity or root.AssemblyLinearVelocity
	maybeLogTransformJump(source, humanoid, root, now, prev.time, prev.position, previousVel)

	transformPropertyPrevious = {
		time = now,
		position = currentPos,
		velocity = root.AssemblyLinearVelocity,
		cframe = currentCFrame,
	}
end

disconnectTelemetryConnections = function()
	local connections = {
		connection,
		stateConnection,
		healthConnection,
		preSimulationConnection,
		postSimulationConnection,
		preRenderConnection,
		cframeConnection,
		mispredictionConnection,
		rollbackConnection,
	}

	for _, conn in ipairs(connections) do
		if conn then
			conn:Disconnect()
		end
	end

	connection = nil
	stateConnection = nil
	healthConnection = nil
	preSimulationConnection = nil
	postSimulationConnection = nil
	preRenderConnection = nil
	cframeConnection = nil
	mispredictionConnection = nil
	rollbackConnection = nil
end

local function startTracking(character)
	disconnectTelemetryConnections()

	local root = character:WaitForChild("HumanoidRootPart", 5)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not root or not humanoid then return end

	lastSpeed = 0
	local lastTrackPos = root.Position
	local lastTrackTime = os.clock()
	local periodicLogAccumulator = 0
	resetTransformTelemetry(root)

	connection = RunService.Heartbeat:Connect(function(dt)
		if not root or not root.Parent or not humanoid or not humanoid.Parent then return end

		sampleTransformStage("Heartbeat", humanoid, root)

		local speed = root.AssemblyLinearVelocity.Magnitude
		local pos = root.Position
		local vel = root.AssemblyLinearVelocity
		local delta = pos - lastTrackPos
		local actualPosSpeed = delta.Magnitude / math.max(os.clock() - lastTrackTime, 1 / 240)

		speedLabel.Text = string.format("%.1f studs/s", speed)
		posLabel.Text = "Pos: " .. formatPos(pos)
		stateLabel.Text = "State: " .. tostring(humanoid:GetState())
		phaseLabel.Text = string.format("Phase: %s | HP: %.1f", activePhase, humanoid.Health)

		if speed < 16 then
			speedLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
		elseif speed < 50 then
			speedLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
		elseif speed < 120 then
			speedLabel.TextColor3 = Color3.fromRGB(0, 200, 255)
		else
			speedLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
		end

		if math.abs(speed - lastSpeed) >= SPEED_THRESHOLD then
			lastSpeed = speed
			addLogEntry(string.format(
				"[%s] SPEED | phase=%s | %.1f s/s | vel=(%s) | pos=(%s) | dP=(%s) | pSpeed=%.1f | state=%s",
				timestamp(),
				activePhase,
				speed,
				formatVec3(vel),
				formatPos(pos),
				formatVec3(delta),
				actualPosSpeed,
				tostring(humanoid:GetState())
			))
		end

		periodicLogAccumulator += dt
		if replicationRunning and periodicLogAccumulator >= 0.50 then
			periodicLogAccumulator = 0
			local totalParts, noCollideParts = countNoCollide(character)
			addLogEntry(string.format(
				"[%s] HEARTBEAT | phase=%s | state=%s | hp=%.1f | pos=(%s) | vel=(%s) | pSpeed=%.1f | floor=%s | nc=%d/%d",
				timestamp(),
				activePhase,
				tostring(humanoid:GetState()),
				humanoid.Health,
				formatPos(pos),
				formatVec3(vel),
				actualPosSpeed,
				safeFloor(humanoid),
				noCollideParts,
				totalParts
			))
		end

		lastTrackPos = pos
		lastTrackTime = os.clock()
	end)

	preSimulationConnection = RunService.PreSimulation:Connect(function()
		if not root or not root.Parent or not humanoid or not humanoid.Parent then return end
		sampleTransformStage("PreSimulation", humanoid, root)
	end)

	postSimulationConnection = RunService.PostSimulation:Connect(function()
		if not root or not root.Parent or not humanoid or not humanoid.Parent then return end
		sampleTransformStage("PostSimulation", humanoid, root)
	end)

	if RunService.PreRender then
		preRenderConnection = RunService.PreRender:Connect(function()
			if not root or not root.Parent or not humanoid or not humanoid.Parent then return end
			sampleTransformStage("PreRender", humanoid, root)
		end)
	end

	cframeConnection = root:GetPropertyChangedSignal("CFrame"):Connect(function()
		if not root or not root.Parent or not humanoid or not humanoid.Parent then return end
		sampleTransformProperty("CFrameChanged", humanoid, root)
	end)

	if RunService.Misprediction then
		mispredictionConnection = RunService.Misprediction:Connect(function(timeValue, instances, stats)
			if not transformCaptureEnabled then return end

			local names = {}
			if type(instances) == "table" then
				for i = 1, math.min(#instances, 5) do
					local item = instances[i]
					local itemInstance = item
					if type(item) == "table" then
						itemInstance = item.instance or item.Instance
					end
					if typeof(itemInstance) == "Instance" then
						table.insert(names, itemInstance:GetFullName())
					else
						table.insert(names, tostring(itemInstance))
					end
				end
			end

			addLogEntry(string.format(
				"[%s] MIS PREDICTION | simTime=%.5f | phase=%s | instances=%d | sample=%s",
				timestamp(),
				timeValue,
				activePhase,
				type(instances) == "table" and #instances or 0,
				table.concat(names, " || ")
			))
		end)
	end

	if RunService.Rollback then
		rollbackConnection = RunService.Rollback:Connect(function(timeValue)
			if not transformCaptureEnabled then return end
			addLogEntry(string.format(
				"[%s] ROLLBACK | rollbackTime=%.5f | phase=%s | state=%s | pos=(%s) | vel=(%s)",
				timestamp(),
				timeValue,
				activePhase,
				safeState(humanoid),
				formatPos(root.Position),
				formatVec3(root.AssemblyLinearVelocity)
			))
		end)
	end

	stateConnection = humanoid.StateChanged:Connect(function(old, new)
		if not root or not root.Parent then return end

		local speed = root.AssemblyLinearVelocity.Magnitude
		local pos = root.Position
		local totalParts, noCollideParts = countNoCollide(character)

		addLogEntry(string.format(
			"[%s] STATE | phase=%s | %s -> %s | speed=%.1f | vel=(%s) | pos=(%s) | hp=%.1f | floor=%s | nc=%d/%d | platformStand=%s | autoRotate=%s",
			timestamp(),
			activePhase,
			tostring(old),
			tostring(new),
			speed,
			formatVec3(root.AssemblyLinearVelocity),
			formatPos(pos),
			humanoid.Health,
			safeFloor(humanoid),
			noCollideParts,
			totalParts,
			tostring(humanoid.PlatformStand),
			tostring(humanoid.AutoRotate)
		))

		lastSpeed = speed
	end)

	healthConnection = humanoid.HealthChanged:Connect(function(newHealth)
		addLogEntry(string.format(
			"[%s] HEALTH | phase=%s | hp=%.1f/%.1f | state=%s | pos=(%s) | vel=(%s)",
			timestamp(),
			activePhase,
			newHealth,
			humanoid.MaxHealth,
			safeState(humanoid),
			formatPos(root.Position),
			formatVec3(root.AssemblyLinearVelocity)
		))
	end)

	addLogEntry(string.format(
		"[%s] TRANSFORM CAPTURE READY | PreSimulation/PostSimulation/Heartbeat/PreRender + CFrameChanged | jumpMin=%.1f | pspeedMin=%.1f | ratioMin=%.1f",
		timestamp(),
		TRANSFORM_JUMP_MIN_DISTANCE,
		TRANSFORM_JUMP_MIN_PSPEED,
		TRANSFORM_JUMP_RATIO
	))
end

-- ================================================================
-- BUTTONS
-- ================================================================
closeBtn.MouseButton1Click:Connect(function()
	disconnectTelemetryConnections()
	screenGui:Destroy()
end)

local function runReplaySafely()
	local ok, err = xpcall(replicateFreefall, function(runtimeError)
		local trace = ""
		pcall(function()
			trace = " | trace=" .. debug.traceback()
		end)
		return tostring(runtimeError) .. trace
	end)

	if not ok then
		addLogEntry(string.format("[%s] SCRIPT ERROR | replicateFreefall failed | %s", timestamp(), tostring(err)))
		feedback.Text = "SCRIPT ERROR — check log/console"
		feedback.TextColor3 = Color3.fromRGB(255, 90, 90)
		feedback.Visible = true
	end
end

boostBtn.MouseButton1Click:Connect(runReplaySafely)

copyBtn.MouseButton1Click:Connect(function()
	if #logEntries == 0 then
		feedback.Text = "Log empty"
		feedback.TextColor3 = Color3.fromRGB(255, 180, 80)
	else
		local success = pcall(function()
			setclipboard(table.concat(logEntries, "\n"))
		end)

		feedback.Text = success and "Log Copied!" or "Copy failed"
		feedback.TextColor3 = success
			and Color3.fromRGB(100, 255, 150)
			or Color3.fromRGB(255, 100, 100)
	end

	feedback.Visible = true
	task.delay(1.8, function()
		if feedback and feedback.Parent then
			feedback.Visible = false
		end
	end)
end)

clearBtn.MouseButton1Click:Connect(function()
	clearLog()
	feedback.Text = "Log Cleared"
	feedback.TextColor3 = Color3.fromRGB(255, 180, 80)
	feedback.Visible = true

	task.delay(1.5, function()
		if feedback and feedback.Parent then
			feedback.Visible = false
		end
	end)
end)

captureBtn.MouseButton1Click:Connect(function()
	transformCaptureEnabled = not transformCaptureEnabled
	setCaptureButton()
	if transformCaptureEnabled then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			resetTransformTelemetry(root)
		end
		addLogEntry(string.format("[%s] TRANSFORM CAPTURE ENABLED", timestamp()))
	else
		addLogEntry(string.format("[%s] TRANSFORM CAPTURE DISABLED", timestamp()))
	end
end)

local function addHover(btn, normal, hover)
	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.15), {
			BackgroundColor3 = hover
		}):Play()
	end)

	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.15), {
			BackgroundColor3 = normal
		}):Play()
	end)
end

addHover(closeBtn, Color3.fromRGB(40, 40, 50), Color3.fromRGB(70, 30, 30))
addHover(boostBtn, Color3.fromRGB(180, 40, 40), Color3.fromRGB(220, 60, 60))
addHover(copyBtn, Color3.fromRGB(0, 140, 180), Color3.fromRGB(0, 180, 220))
addHover(clearBtn, Color3.fromRGB(80, 40, 40), Color3.fromRGB(120, 50, 50))
addHover(captureBtn, Color3.fromRGB(35, 110, 70), Color3.fromRGB(45, 140, 90))
setCaptureButton()
addLogEntry(string.format("[%s] SCRIPT READY | capture=%s | phase=%s", timestamp(), tostring(transformCaptureEnabled), activePhase))

player.CharacterAdded:Connect(startTracking)
if player.Character then
	startTracking(player.Character)
end
