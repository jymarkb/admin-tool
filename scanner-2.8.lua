--[[
    CHARACTER DEEP SCANNER v2.8
    + Extra logging: Anchored, NetworkOwner, PlatformStand, full velocity vectors
    + Better high-speed capture
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

local getHui = gethui or function() return CoreGui end
local uiParent = (pcall(function() return getHui() end) and getHui()) or LocalPlayer:WaitForChild("PlayerGui")

local GUI_NAME = "CharacterDeepMovementScanner"
local HUD_HZ = 6
local MAX_LOG = 4000
local DISPLAY_LINES = 36
local BLACKBOX_CAP = 400

local LARGE_MOVE_STUDS = 18
local STILL_DISTANCE = 0.6
local STILL_TIME_EVENT = 0.6
local STAGE_REVERSAL_DOT = -0.45
local INTRA_FRAME_STOMP_THRESHOLD = 1.2

local running = true
local recording = false

local log = {}
local eventN = 0
local dirty = false
local lastRender = 0

local hbConn, renderConn
local gui, main, titleBar, hudLabel, logBox
local character, humanoid, root

local sampleCount = 0

local renderPhaseCache = { frame = 0, pos = nil, cf = nil, t = 0 }

local lastSample = {
	t = nil, dt = nil, pos = nil, cf = nil,
	velocity = Vector3.zero, posVelocity = Vector3.zero,
	localVelocity = Vector3.zero, speed = 0, posSpeed = 0,
	state = nil, groundY = 0, clearance = 0,
	anchored = false, platformStand = false, networkOwner = nil
}

local movement = {
	totalDistance = 0,
	stillStarted = nil,
	currentStill = 0,
	primaryBurstVector = nil,
	returnDetected = false,
}

local animFreezeDetector = {
	playingTracksCount = 0,
	activeActionTracks = {},
	trackStates = {},
}

local stats = {
	animDesyncEvents = 0,
	returnEvents = 0,
	cframeBurstEvents = 0,
	intraFrameStomps = 0,
	floorClips = 0,
	vectorMisalignments = 0,
}

local blackbox = {}
local knownTracksMap = {}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function now() return os.clock() end

local function fmtVector(v, decimals)
	if typeof(v) ~= "Vector3" then return "(?)" end
	local d = decimals or 2
	return string.format("(%."..d.."f, %."..d.."f, %."..d.."f)", v.X, v.Y, v.Z)
end

local function safeGet(fn, fallback)
	local ok, value = pcall(fn)
	return ok and value or fallback
end

local function getCharacter() return LocalPlayer.Character end
local function getHumanoid()
	local c = getCharacter()
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function getRoot()
	local c = getCharacter()
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function getStateName(h)
	if not h then return "none" end
	local ok, state = pcall(function() return h:GetState() end)
	return ok and tostring(state):gsub("Enum%.HumanoidStateType%.", "") or "?"
end

local function getGroundInfo(rootPart)
	if not rootPart then return 0, 0 end
	character = getCharacter()
	if character then
		rayParams.FilterDescendantsInstances = {character}
	end
	local origin = rootPart.Position
	local result = Workspace:Raycast(origin, Vector3.new(0, -200, 0), rayParams)
	if result then
		return result.Position.Y, origin.Y - result.Position.Y
	end
	return origin.Y - 3, 3
end

local function render(force)
	if not logBox or (not force and not dirty) then return end
	local t = now()
	if not force and (t - lastRender) < 0.12 then return end
	lastRender = t
	dirty = false

	local count = #log
	local from = math.max(1, count - DISPLAY_LINES + 1)
	local shown = {}
	for i = from, count do shown[#shown + 1] = log[i] end
	logBox.Text = (#shown > 0) and table.concat(shown, "\n") or "(no events)"
end

local function say(tag, message)
	eventN += 1
	local line = string.format("%s #%04d %-18s %s", os.date("%H:%M:%S"), eventN, tag, tostring(message))
	log[#log + 1] = line
	if #log > MAX_LOG then table.remove(log, 1) end
	dirty = true
	print("[deep-scanner-v2.8] " .. line)
	render(true)
end

local function pushBlackbox(snapshot)
	blackbox[#blackbox + 1] = snapshot
	if #blackbox > BLACKBOX_CAP then table.remove(blackbox, 1) end
end

local function scanAnimationsDetailed()
	humanoid = getHumanoid()
	character = getCharacter()
	if not humanoid or not character then return end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	local tracks = safeGet(function()
		return animator and animator:GetPlayingAnimationTracks() or humanoid:GetPlayingAnimationTracks()
	end, {})

	animFreezeDetector.playingTracksCount = #tracks
	local currentTrackIds = {}
	local actionTracks = {}

	for _, track in ipairs(tracks) do
		local animId = track.Animation and track.Animation.AnimationId or "unknown"
		local prio = track.Priority.Name
		local shortId = animId:match("(%d+)$") or animId
		currentTrackIds[animId] = true

		local timePos = safeGet(function() return track.TimePosition end, 0)
		local weight = safeGet(function() return track.WeightCurrent end, 0)
		local length = safeGet(function() return track.Length end, 0)

		if prio:find("Action") then
			actionTracks[#actionTracks + 1] = shortId
		end

		local lastTrackState = animFreezeDetector.trackStates[animId]
		if lastTrackState and recording then
			local dtAnim = timePos - lastTrackState.timePos
			if dtAnim < -0.25 and track.IsPlaying and length > 0.4 then
				say("ANIM_SCRUB_REWIND", string.format("Track %s rewound: %.2fs -> %.2fs", shortId, lastTrackState.timePos, timePos))
			end
		end

		animFreezeDetector.trackStates[animId] = { timePos = timePos, weight = weight }

		if not knownTracksMap[animId] then
			knownTracksMap[animId] = true
			if recording then
				say("ANIM_START", string.format("%s | Prio:%s Spd:%.1f Wgt:%.2f", animId, prio, track.Speed, weight))
			end
		end
	end

	for animId in pairs(knownTracksMap) do
		if not currentTrackIds[animId] then
			knownTracksMap[animId] = nil
			animFreezeDetector.trackStates[animId] = nil
			if recording then
				say("ANIM_STOP", animId)
			end
		end
	end

	animFreezeDetector.activeActionTracks = actionTracks
end

local function analyzeMovement(dt)
	humanoid = getHumanoid()
	root = getRoot()
	character = getCharacter()
	if not humanoid or not root or not character then return end

	local t = now()
	local pos = root.Position
	local cf = root.CFrame
	local physVelocity = root.AssemblyLinearVelocity
	local physSpeed = physVelocity.Magnitude
	local state = getStateName(humanoid)
	local grounded, clearance = getGroundInfo(root)

	local anchored = root.Anchored
	local platformStand = humanoid.PlatformStand
	local networkOwner = safeGet(function() return root:GetNetworkOwner() end, nil)
	local networkOwnerName = networkOwner and networkOwner.Name or "nil"

	-- Intra-frame stomp
	if renderPhaseCache.pos and renderPhaseCache.t == t then
		local intraShift = (pos - renderPhaseCache.pos).Magnitude
		if intraShift >= INTRA_FRAME_STOMP_THRESHOLD then
			stats.intraFrameStomps += 1
			if recording then
				say("DUAL_FRAME_STOMP", string.format("%.2f studs | Render=%s Phys=%s", intraShift, fmtVector(renderPhaseCache.pos,1), fmtVector(pos,1)))
			end
		end
	end

	local displacement = 0
	local posVelocity = Vector3.zero
	local posSpeed = 0

	if lastSample.pos then
		displacement = (pos - lastSample.pos).Magnitude
		posVelocity = (pos - lastSample.pos) / math.max(dt, 0.0001)
		posSpeed = posVelocity.Magnitude
		movement.totalDistance += displacement
	end

	local effectiveVelocity = (posSpeed > physSpeed * 1.4 and posSpeed > 8) and posVelocity or physVelocity
	local localVel = cf:VectorToObjectSpace(effectiveVelocity)

	local moveDirection = "IDLE"
	if localVel.Z < -4 then moveDirection = "FORWARD"
	elseif localVel.Z > 4 then moveDirection = "BACKWARD"
	elseif math.abs(localVel.X) > 4 then moveDirection = localVel.X > 0 and "STRAFE_R" or "STRAFE_L" end

	if lastSample.pos then
		if clearance < -1.2 and recording then
			stats.floorClips += 1
			say("FLOOR_CLIP", string.format("Y=%.1f Floor=%.1f Clear=%.1f", pos.Y, grounded, clearance))
		end

		if posSpeed > 25 and physSpeed > 25 then
			local velDot = posVelocity.Unit:Dot(physVelocity.Unit)
			if velDot < 0.25 and recording then
				stats.vectorMisalignments += 1
				say("VECTOR_MISALIGN", string.format("Dot=%.2f CF=%.0f Phys=%.0f", velDot, posSpeed, physSpeed))
			end
		end

		if posSpeed > 35 and posSpeed > (physSpeed * 2.2 + 15) then
			stats.cframeBurstEvents += 1
			if recording and sampleCount % 6 == 0 then
				say("CFRAME_BURST", string.format("CF=%.0f >> Phys=%.0f | %s", posSpeed, physSpeed, moveDirection))
			end
		end

		if math.max(posSpeed, physSpeed) > 35 then
			local currentDir = effectiveVelocity.Unit
			if not movement.primaryBurstVector then
				movement.primaryBurstVector = currentDir
				if recording then
					say("BURST_START", string.format("%s | %s", fmtVector(currentDir,2), moveDirection))
				end
			else
				local dot = currentDir:Dot(movement.primaryBurstVector)
				if dot < STAGE_REVERSAL_DOT and not movement.returnDetected then
					movement.returnDetected = true
					stats.returnEvents += 1
					if recording then
						say("RETURN_JOURNEY", string.format("Dot=%.2f | %s | %s", dot, fmtVector(localVel,1), moveDirection))
					end
				elseif dot > 0.55 then
					movement.returnDetected = false
				end
			end
		end

		if displacement <= STILL_DISTANCE then
			if not movement.stillStarted then movement.stillStarted = t end
			movement.currentStill = t - movement.stillStarted
		else
			if movement.currentStill >= STILL_TIME_EVENT and recording then
				say("MOTION_RESUMED", string.format("%.2fs | %s", movement.currentStill, moveDirection))
			end
			movement.stillStarted = nil
			movement.currentStill = 0
		end

		if displacement >= LARGE_MOVE_STUDS and recording then
			say("LARGE_MOVE", string.format("%.1f studs | CF=%.0f Phys=%.0f | %s | Pos=%s | H=%.1f | Anch=%s Plat=%s Net=%s",
				displacement, posSpeed, physSpeed, moveDirection, fmtVector(pos,1), clearance,
				tostring(anchored), tostring(platformStand), networkOwnerName))
		end
	end

	pushBlackbox({
		t = t, dt = dt, pos = pos, velocity = physVelocity, posVelocity = posVelocity,
		localVel = localVel, physSpeed = physSpeed, posSpeed = posSpeed, state = state,
		moveDir = moveDirection, clearance = clearance,
		anchored = anchored, platformStand = platformStand, networkOwner = networkOwnerName
	})

	lastSample.t = t
	lastSample.dt = dt
	lastSample.pos = pos
	lastSample.cf = cf
	lastSample.velocity = physVelocity
	lastSample.posVelocity = posVelocity
	lastSample.localVelocity = localVel
	lastSample.speed = physSpeed
	lastSample.posSpeed = posSpeed
	lastSample.state = state
	lastSample.groundY = grounded
	lastSample.clearance = clearance
	lastSample.anchored = anchored
	lastSample.platformStand = platformStand
	lastSample.networkOwner = networkOwnerName

	sampleCount += 1
end

-- GUI
local existingGui = uiParent:FindFirstChild(GUI_NAME)
if existingGui then pcall(function() existingGui:Destroy() end) end

gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.DisplayOrder = 999999
gui.Parent = uiParent

main = Instance.new("Frame")
main.Size = UDim2.fromOffset(760, 580)
main.Position = UDim2.new(0.02, 0, 0.08, 0)
main.BackgroundColor3 = Color3.fromRGB(14, 18, 26)
main.Active = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 30)
titleBar.BackgroundColor3 = Color3.fromRGB(22, 28, 42)
titleBar.Active = true
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -16, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Text = "CHARACTER DEEP SCANNER v2.8 [DETAILED]"
title.TextColor3 = Color3.fromRGB(125, 220, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 12
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar

-- Drag
local dragging, dragInput, dragStart, startPos = false, nil, nil, nil
titleBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = main.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then dragging = false end
		end)
	end
end)
titleBar.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
		dragInput = input
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if input == dragInput and dragging then
		local delta = input.Position - dragStart
		main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)

hudLabel = Instance.new("TextLabel")
hudLabel.Size = UDim2.new(1, -20, 0, 190)
hudLabel.Position = UDim2.fromOffset(10, 38)
hudLabel.BackgroundColor3 = Color3.fromRGB(9, 13, 20)
hudLabel.TextColor3 = Color3.fromRGB(175, 220, 255)
hudLabel.TextSize = 11
hudLabel.Font = Enum.Font.Code
hudLabel.TextXAlignment = Enum.TextXAlignment.Left
hudLabel.TextYAlignment = Enum.TextYAlignment.Top
hudLabel.Text = "Scanner v2.8 ready."
hudLabel.Parent = main
Instance.new("UICorner", hudLabel).CornerRadius = UDim.new(0, 6)

logBox = Instance.new("TextBox")
logBox.Size = UDim2.new(1, -20, 0, 280)
logBox.Position = UDim2.fromOffset(10, 238)
logBox.BackgroundColor3 = Color3.fromRGB(8, 11, 17)
logBox.TextColor3 = Color3.fromRGB(205, 220, 240)
logBox.TextSize = 10
logBox.Font = Enum.Font.Code
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.MultiLine = true
logBox.ClearTextOnFocus = false
logBox.TextEditable = false
logBox.Parent = main
Instance.new("UICorner", logBox).CornerRadius = UDim.new(0, 6)

local function makeButton(text, x, width)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(width, 32)
	b.Position = UDim2.new(x, 0, 1, -42)
	b.BackgroundColor3 = Color3.fromRGB(40, 95, 145)
	b.Text = text
	b.TextColor3 = Color3.new(1,1,1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 11
	b.Parent = main
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
	return b
end

local startButton = makeButton("START / RESET", 0.015, 160)
local copyButton = makeButton("COPY LOG", 0.42, 160)

startButton.MouseButton1Click:Connect(function()
	log = {}
	eventN = 0
	recording = true
	movement.primaryBurstVector = nil
	movement.returnDetected = false
	stats.intraFrameStomps = 0
	stats.floorClips = 0
	stats.vectorMisalignments = 0
	say("START", "Detailed diagnostic recording active.")
end)

copyButton.MouseButton1Click:Connect(function()
	local text = table.concat(log, "\n")
	if setclipboard then setclipboard(text)
	elseif toclipboard then toclipboard(text) end
	say("COPY", "Log copied!")
end)

-- Loops
renderConn = RunService.RenderStepped:Connect(function()
	root = getRoot()
	if root then
		renderPhaseCache.frame += 1
		renderPhaseCache.pos = root.Position
		renderPhaseCache.cf = root.CFrame
		renderPhaseCache.t = now()
	end
end)

hbConn = RunService.Heartbeat:Connect(function(dt)
	if not running or dt <= 0 then return end
	character = getCharacter()
	humanoid = getHumanoid()
	root = getRoot()
	if not humanoid or not root then return end

	pcall(function() analyzeMovement(dt) end)
	if sampleCount % 10 == 0 then pcall(scanAnimationsDetailed) end

	local t = now()
	if (t - lastRender) >= (1 / HUD_HZ) then
		lastRender = t
		local localV = lastSample.localVelocity or Vector3.zero
		hudLabel.Text = table.concat({
			string.format("STATE      %s | Clearance: %.1f | FloorY: %.1f", getStateName(humanoid), lastSample.clearance or 0, lastSample.groundY or 0),
			string.format("POSITION   %s", fmtVector(root.Position, 1)),
			string.format("PHYS SPEED %.1f | CFRAME SPEED %.1f", lastSample.speed or 0, lastSample.posSpeed or 0),
			string.format("LOCAL VEL  %s", fmtVector(localV, 1)),
			string.format("ANCHORED   %s | PlatformStand: %s | NetOwner: %s", tostring(lastSample.anchored), tostring(lastSample.platformStand), tostring(lastSample.networkOwner)),
			string.format("ANOMALIES  Stomps:%d Clips:%d Misalign:%d Bursts:%d", stats.intraFrameStomps, stats.floorClips, stats.vectorMisalignments, stats.cframeBurstEvents),
			string.format("BURST VEC  %s | Return: %s", fmtVector(movement.primaryBurstVector or Vector3.zero, 2), movement.returnDetected and "YES" or "NO"),
		}, "\n")
	end
end)

say("INIT", "Character Deep Scanner v2.8 ready.")