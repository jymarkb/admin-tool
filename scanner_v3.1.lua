--[[
	CHARACTER DEEP SCANNER v3.1b – FAILURE-FOCUSED (compact + auto flight)
	- Auto-detects flight start (no manual mark needed)
	- Compact UI – mainly for copying the log
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local CoreGui           = game:GetService("CoreGui")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

local getHui = gethui or function() return CoreGui end
local uiParent = (pcall(function() return getHui() end) and getHui()) or LocalPlayer:WaitForChild("PlayerGui")

local GUI_NAME = "CharacterDeepScanner_v31"
local HUD_HZ = 8
local MAX_LOG = 8000
local DISPLAY_LINES = 28

local LARGE_MOVE_STUDS      = 12
local ZERO_HORIZ_THRESHOLD  = 2.5
local PENETRATION_H         = 4.0
local HIGH_Y_THRESHOLD      = 90
local DIR_FLIP_DOT          = -0.3
local HEIGHT_JUMP_STUDS     = 18
local FLIGHT_DETECT_STREAK  = 4

local FOREST_POS = Vector3.new(612, 70, -325)
local SAFE_POS   = Vector3.new(427.6, 70.7, -423.4)

local running = true
local recording = false

local log = {}
local eventN = 0
local dirty = false
local lastRender = 0
local sampleCount = 0

local lastSample = {
	t = 0, pos = nil,
	physVel = Vector3.zero, posVel = Vector3.zero,
	physSpeed = 0, posSpeed = 0, horizSpeed = 0,
	anchored = false, platformStand = false, networkOwner = "nil",
	holdingEgg = false, clearance = 0, humState = "Unknown"
}

local knownTracks = {}
local lastHolding = false
local lastZone = "none"
local lastDir = nil
local lastY = nil
local lastLargeMoveT = 0
local heightSamples = {}
local maxHeightSamples = 30
local consecutiveZeroHoriz = 0
local consecutivePenetration = 0
local flightMarked = false
local flightStartPos = nil
local flightStartT = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function now() return os.clock() end

local function fmtV(v, d)
	d = d or 1
	if typeof(v) ~= "Vector3" then return "(?)" end
	return string.format("(%."..d.."f, %."..d.."f, %."..d.."f)", v.X, v.Y, v.Z)
end

local function say(tag, msg)
	eventN += 1
	local line = string.format("%s #%04d %-18s %s", os.date("%H:%M:%S"), eventN, tag, tostring(msg))
	log[#log + 1] = line
	if #log > MAX_LOG then table.remove(log, 1) end
	dirty = true
	print("[scanner-v3.1] " .. line)
end

local function getRoot()
	local c = LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local c = LocalPlayer.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function getClearance(root)
	if not root then return 0 end
	local char = LocalPlayer.Character
	if char then rayParams.FilterDescendantsInstances = {char} end
	local res = Workspace:Raycast(root.Position, Vector3.new(0, -200, 0), rayParams)
	if res then return root.Position.Y - res.Position.Y end
	return 3
end

local function isHoldingEgg()
	local char = LocalPlayer.Character
	if not char then return false end
	for _, child in ipairs(char:GetChildren()) do
		local n = string.lower(child.Name)
		if child:IsA("Tool") and not string.find(n, "trap") then return true end
		if string.find(n, "egg") or string.find(n, "carried") then return true end
	end
	for _, desc in ipairs(char:GetDescendants()) do
		if desc:IsA("JointInstance") then
			local p0, p1 = desc.Part0, desc.Part1
			if p0 and p1 then
				local n0, n1 = string.lower(p0.Name), string.lower(p1.Name)
				if string.find(n0, "egg") or string.find(n1, "egg") then return true end
			end
		end
	end
	if LocalPlayer:GetAttribute("IsCarrying") == true
		or LocalPlayer:GetAttribute("Carrying") == true
		or LocalPlayer:GetAttribute("EggUid") ~= nil then
		return true
	end
	local cra = Workspace:FindFirstChild("ClientRenderedAssets")
	if cra then
		for _, m in ipairs(cra:GetChildren()) do
			if string.find(m.Name, tostring(LocalPlayer.UserId)) then return true end
		end
	end
	return false
end

local function getZone(pos)
	local dForest = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(FOREST_POS.X, 0, FOREST_POS.Z)).Magnitude
	local dSafe   = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(SAFE_POS.X, 0, SAFE_POS.Z)).Magnitude
	if dForest < 90 then return "FOREST"
	elseif dSafe < 90 then return "SAFEZONE"
	elseif pos.X > 4500 then return "EGG_AREA"
	else return "TRANSIT" end
end

local function heightVariance()
	if #heightSamples < 5 then return 0 end
	local sum, sumSq = 0, 0
	for _, y in ipairs(heightSamples) do
		sum += y
		sumSq += y * y
	end
	local n = #heightSamples
	local mean = sum / n
	return math.sqrt(math.max(0, sumSq / n - mean * mean))
end

----------------------------------------------------------------
-- COMPACT GUI
----------------------------------------------------------------

local existing = uiParent:FindFirstChild(GUI_NAME)
if existing then pcall(function() existing:Destroy() end) end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.DisplayOrder = 999999
gui.Parent = uiParent

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(420, 280)
main.Position = UDim2.new(0.01, 0, 0.55, 0)
main.BackgroundColor3 = Color3.fromRGB(12, 16, 24)
main.Active = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 26)
titleBar.BackgroundColor3 = Color3.fromRGB(20, 28, 42)
titleBar.Active = true
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -8, 1, 0)
title.Position = UDim2.fromOffset(8, 0)
title.BackgroundTransparency = 1
title.Text = "SCANNER v3.1b  (auto-flight)"
title.TextColor3 = Color3.fromRGB(120, 220, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 11
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar

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

local hudLabel = Instance.new("TextLabel")
hudLabel.Size = UDim2.new(1, -12, 0, 52)
hudLabel.Position = UDim2.fromOffset(6, 28)
hudLabel.BackgroundColor3 = Color3.fromRGB(8, 12, 18)
hudLabel.TextColor3 = Color3.fromRGB(170, 220, 255)
hudLabel.TextSize = 10
hudLabel.Font = Enum.Font.Code
hudLabel.TextXAlignment = Enum.TextXAlignment.Left
hudLabel.TextYAlignment = Enum.TextYAlignment.Top
hudLabel.Text = "Ready"
hudLabel.Parent = main
Instance.new("UICorner", hudLabel).CornerRadius = UDim.new(0, 4)

local logBox = Instance.new("TextBox")
logBox.Size = UDim2.new(1, -12, 0, 150)
logBox.Position = UDim2.fromOffset(6, 84)
logBox.BackgroundColor3 = Color3.fromRGB(7, 10, 15)
logBox.TextColor3 = Color3.fromRGB(200, 220, 240)
logBox.TextSize = 9
logBox.Font = Enum.Font.Code
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.MultiLine = true
logBox.ClearTextOnFocus = false
logBox.TextEditable = false
logBox.Parent = main
Instance.new("UICorner", logBox).CornerRadius = UDim.new(0, 4)

local function refreshLogBox()
	if not logBox then return end
	local from = math.max(1, #log - DISPLAY_LINES + 1)
	local shown = {}
	for i = from, #log do shown[#shown+1] = log[i] end
	logBox.Text = table.concat(shown, "\n")
end

local function makeBtn(text, x, w)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, 26)
	b.Position = UDim2.new(x, 0, 1, -32)
	b.BackgroundColor3 = Color3.fromRGB(40, 100, 160)
	b.Text = text
	b.TextColor3 = Color3.new(1,1,1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 10
	b.Parent = main
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
	return b
end

local startBtn = makeBtn("START", 0.02, 90)
local copyBtn  = makeBtn("COPY LOG", 0.28, 100)
local stopBtn  = makeBtn("STOP", 0.58, 80)

startBtn.MouseButton1Click:Connect(function()
	log = {}
	eventN = 0
	recording = true
	knownTracks = {}
	lastHolding = false
	lastZone = "none"
	lastDir = nil
	lastY = nil
	lastLargeMoveT = 0
	heightSamples = {}
	consecutiveZeroHoriz = 0
	consecutivePenetration = 0
	flightMarked = false
	flightStartPos = nil
	flightStartT = nil
	say("START", "v3.1b failure-focused (auto-flight) recording")
	refreshLogBox()
end)

copyBtn.MouseButton1Click:Connect(function()
	local text = table.concat(log, "\n")
	if setclipboard then setclipboard(text)
	elseif toclipboard then toclipboard(text) end
	say("COPY", "Log copied")
	refreshLogBox()
end)

stopBtn.MouseButton1Click:Connect(function()
	recording = false
	say("STOP", "Recording stopped")
	refreshLogBox()
end)

----------------------------------------------------------------
-- MAIN LOOP
----------------------------------------------------------------

RunService.Heartbeat:Connect(function(dt)
	if not running or dt <= 0 then return end

	local root = getRoot()
	local hum = getHumanoid()
	if not root or not hum then return end

	local t = now()
	local pos = root.Position
	local physVel = root.AssemblyLinearVelocity
	local physSpeed = physVel.Magnitude
	local horizSpeed = Vector3.new(physVel.X, 0, physVel.Z).Magnitude

	local displacement = 0
	local posSpeed = 0
	local posVel = Vector3.zero
	local liveDir = nil
	if lastSample.pos then
		displacement = (pos - lastSample.pos).Magnitude
		posVel = (pos - lastSample.pos) / math.max(dt, 1e-4)
		posSpeed = posVel.Magnitude
		local horizDelta = Vector3.new(pos.X - lastSample.pos.X, 0, pos.Z - lastSample.pos.Z)
		if horizDelta.Magnitude > 0.5 then
			liveDir = horizDelta.Unit
		end
	end

	local anchored = root.Anchored
	local platformStand = hum.PlatformStand
	local netOwner = "nil"
	pcall(function()
		local o = root:GetNetworkOwner()
		netOwner = o and o.Name or "nil"
	end)

	local clearance = getClearance(root)
	local holding = isHoldingEgg()
	local zone = getZone(pos)
	local humState = tostring(hum:GetState()):gsub("Enum.HumanoidStateType.", "")

	table.insert(heightSamples, pos.Y)
	if #heightSamples > maxHeightSamples then table.remove(heightSamples, 1) end
	local hVar = heightVariance()

	if recording then

		if holding ~= lastHolding then
			say("EGG_STATE", string.format("%s → %s | Pos=%s | Zone=%s",
				lastHolding and "HOLDING" or "EMPTY",
				holding and "HOLDING" or "EMPTY",
				fmtV(pos), zone))
			lastHolding = holding
		end

		if zone ~= lastZone then
			say("ZONE", string.format("%s → %s | Pos=%s | Holding=%s",
				lastZone, zone, fmtV(pos), tostring(holding)))
			lastZone = zone
		end

		if humState ~= lastSample.humState and lastSample.humState ~= "Unknown" then
			say("HUM_STATE", string.format("%s → %s | Pos=%s", lastSample.humState, humState, fmtV(pos)))
		end

		if anchored ~= lastSample.anchored then
			say("ANCHOR_FLIP", string.format("%s → %s | Pos=%s Y=%.1f",
				tostring(lastSample.anchored), tostring(anchored), fmtV(pos), pos.Y))
		end
		if platformStand ~= lastSample.platformStand then
			say("PLAT_FLIP", string.format("%s → %s | Pos=%s",
				tostring(lastSample.platformStand), tostring(platformStand), fmtV(pos)))
		end
		if netOwner ~= lastSample.networkOwner then
			say("NET_OWNER", string.format("%s → %s | Pos=%s",
				lastSample.networkOwner, netOwner, fmtV(pos)))
		end

		if lastY and math.abs(pos.Y - lastY) >= HEIGHT_JUMP_STUDS then
			say("HEIGHT_JUMP", string.format("Y %.1f → %.1f (Δ%.1f) | H=%.1f | Pos=%s | Zone=%s",
				lastY, pos.Y, pos.Y - lastY, clearance, fmtV(pos), zone))
		end
		lastY = pos.Y

		if pos.Y > HIGH_Y_THRESHOLD and clearance < PENETRATION_H then
			consecutivePenetration += 1
			if consecutivePenetration <= 3 or consecutivePenetration % 8 == 0 then
				say("PENETRATION", string.format("Y=%.1f H=%.1f | Pos=%s | Zone=%s | Egg=%s",
					pos.Y, clearance, fmtV(pos), zone, holding and "YES" or "NO"))
			end
		else
			consecutivePenetration = 0
		end

		if liveDir and lastDir then
			local dot = liveDir:Dot(lastDir)
			if dot < DIR_FLIP_DOT and displacement > 8 then
				say("DIR_FLIP", string.format("Dot=%.2f moved=%.1f | Pos=%s | Zone=%s",
					dot, displacement, fmtV(pos), zone))
			end
		end
		if liveDir then lastDir = liveDir end

		if horizSpeed < ZERO_HORIZ_THRESHOLD and displacement >= 10 then
			consecutiveZeroHoriz += 1

			if not flightMarked and consecutiveZeroHoriz >= FLIGHT_DETECT_STREAK then
				flightMarked = true
				flightStartT = t
				flightStartPos = pos
				say("FLIGHT_START", string.format("AUTO | Pos=%s | Y=%.1f H=%.1f | Egg=%s Zone=%s",
					fmtV(pos), pos.Y, clearance, holding and "YES" or "NO", zone))
			end

			local interval = lastLargeMoveT > 0 and (t - lastLargeMoveT) or 0
			say("ZERO_HORIZ", string.format("Horiz=%.1f moved=%.1f | CF=%.0f Phys=%.0f | Vel=%s | Y=%.1f H=%.1f | Plat=%s Egg=%s | dt=%.3f | streak=%d",
				horizSpeed, displacement, posSpeed, physSpeed, fmtV(physVel,1),
				pos.Y, clearance, tostring(platformStand), holding and "YES" or "NO",
				interval, consecutiveZeroHoriz))
			lastLargeMoveT = t
		else
			if consecutiveZeroHoriz > 5 then
				say("ZERO_HORIZ_END", string.format("Streak ended after %d | Pos=%s", consecutiveZeroHoriz, fmtV(pos)))
				if flightMarked then
					local dur = flightStartT and (t - flightStartT) or 0
					local dist = flightStartPos and (pos - flightStartPos).Magnitude or 0
					say("FLIGHT_END", string.format("dur=%.1fs dist=%.0f | Pos=%s | Zone=%s",
						dur, dist, fmtV(pos), zone))
					flightMarked = false
				end
			end
			consecutiveZeroHoriz = 0
		end

		if displacement >= LARGE_MOVE_STUDS then
			local interval = lastLargeMoveT > 0 and (t - lastLargeMoveT) or 0
			say("LARGE_MOVE", string.format("%.1f studs | CF=%.0f Phys=%.0f Horiz=%.1f | Pos=%s | Y=%.1f H=%.1f | Plat=%s Anch=%s Net=%s | Egg=%s Zone=%s | Vel=%s | dt=%.3f | hVar=%.1f",
				displacement, posSpeed, physSpeed, horizSpeed, fmtV(pos), pos.Y, clearance,
				tostring(platformStand), tostring(anchored), netOwner,
				holding and "YES" or "NO", zone, fmtV(physVel,1), interval, hVar))
			lastLargeMoveT = t
		end

		if displacement >= 400 then
			say("HARD_SNAP", string.format("%.0f studs | → %s | Zone=%s | Egg=%s | Y=%.1f H=%.1f | Anch=%s",
				displacement, fmtV(pos), zone, holding and "YES" or "NO", pos.Y, clearance, tostring(anchored)))
		end

		if posSpeed > 50 and posSpeed > physSpeed * 2.5 + 15 then
			say("CFRAME_BURST", string.format("CF=%.0f >> Phys=%.0f Horiz=%.1f | Y=%.1f H=%.1f | Plat=%s Egg=%s",
				posSpeed, physSpeed, horizSpeed, pos.Y, clearance, tostring(platformStand), holding and "YES" or "NO"))
		end

		if consecutiveZeroHoriz > 3 and hVar > 8 then
			say("HEIGHT_UNSTABLE", string.format("hVar=%.1f | Y=%.1f H=%.1f | Pos=%s",
				hVar, pos.Y, clearance, fmtV(pos)))
		end
	end

	if sampleCount % 12 == 0 then
		local tracks = {}
		pcall(function()
			local anim = hum:FindFirstChildOfClass("Animator")
			tracks = anim and anim:GetPlayingAnimationTracks() or hum:GetPlayingAnimationTracks()
		end)
		local current = {}
		for _, tr in ipairs(tracks) do
			local id = tr.Animation and tr.Animation.AnimationId or "unknown"
			current[id] = true
			if not knownTracks[id] then
				knownTracks[id] = true
				if recording then
					say("ANIM_START", string.format("%s | %s Spd:%.1f", id, tr.Priority.Name, tr.Speed))
				end
			end
		end
		for id in pairs(knownTracks) do
			if not current[id] then
				knownTracks[id] = nil
				if recording then say("ANIM_STOP", id) end
			end
		end
	end

	lastSample.t = t
	lastSample.pos = pos
	lastSample.physVel = physVel
	lastSample.posVel = posVel
	lastSample.physSpeed = physSpeed
	lastSample.posSpeed = posSpeed
	lastSample.horizSpeed = horizSpeed
	lastSample.anchored = anchored
	lastSample.platformStand = platformStand
	lastSample.networkOwner = netOwner
	lastSample.holdingEgg = holding
	lastSample.clearance = clearance
	lastSample.humState = humState

	sampleCount += 1

	if (t - lastRender) >= (1 / HUD_HZ) then
		lastRender = t
		local flags = {}
		if consecutivePenetration > 0 then table.insert(flags, "PENETRATE") end
		if hVar > 10 then table.insert(flags, "H_UNSTABLE") end
		if flightMarked then table.insert(flags, "FLIGHT") end
		local flagStr = #flags > 0 and table.concat(flags, " ") or "-"

		hudLabel.Text = string.format(
			"Y=%.0f H=%.0f | CF=%.0f Phys=%.0f Horiz=%.0f | %s\nEgg=%s Zone=%s | Events=%d | %s",
			pos.Y, clearance, posSpeed, physSpeed, horizSpeed, humState,
			holding and "YES" or "NO", zone, eventN, flagStr
		)
		if dirty then
			refreshLogBox()
			dirty = false
		end
	end
end)

say("INIT", "Scanner v3.1b compact + auto-flight ready")
