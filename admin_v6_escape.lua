--[[=========================================================================
	STEAL AN EGG — ESCAPE FLIGHT v6.0
	+ Walk to egg on ground only
	+ Instant grab → immediate escape (NO boss wait)
	+ Locked dir → Forest | Y=112.5 | Horiz vel = 0
	+ Large steps ~78 | finish ≤ 2.5s
	+ PlatformStand left FALSE
	+ Drop + re-carry near Forest then walk to Safe Zone
=========================================================================]]

local Players                = game:GetService("Players")
local Workspace              = game:GetService("Workspace")
local RunService             = game:GetService("RunService")
local ReplicatedStorage      = game:GetService("ReplicatedStorage")
local UserInputService       = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
	task.wait(0.1)
	LocalPlayer = Players.LocalPlayer
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------

local TARGET_BIOMES = { "Light Dark", "Snow", "Jungle", "Desert", "Ocean", "Volcano", "Abyss Ocean", "Prehistoric", "Cosmic", "Cherry Blossom", "Titan", "Forest" }
local selectedBiomeIndex = 1
local selectedBiome = TARGET_BIOMES[selectedBiomeIndex]

local dynamicBaseWalkSpeed = 16.0
local FOREST_WALK_SPEED    = 16.0

local SAFE_ZONE_POSITION  = Vector3.new(427.6, 70.7, -423.4)
local FOREST_LANDING      = Vector3.new(612.0, 71.0, -325.0)

local CRUISE_Y            = 112.5
local STEP_SIZE           = 78
local MAX_FLIGHT_S        = 2.5
local FLIGHT_ANIM_ID      = "rbxassetid://102039335618606"

local GUI_NAME            = "GrokEscapeFlightV6"

local currentToken        = 0
local isRunning           = false
local isFlying            = false
local cachedSnapshot      = nil
local snapshotTried       = false

local zeroFriction = PhysicalProperties.new(0.7, 0, 0, 100, 100)
local originalPhysicalProperties = {}
local savedCollisions = {}

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local function cleanString(str)
	return string.lower(tostring(str or "")):gsub("[%s_%-]", "")
end

local function captureBaseSpeed()
	local char = LocalPlayer.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		dynamicBaseWalkSpeed = hum.WalkSpeed
	end
	return dynamicBaseWalkSpeed
end

local function restoreBaseSpeed()
	local char = LocalPlayer.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		pcall(function() hum.WalkSpeed = dynamicBaseWalkSpeed end)
	end
end

----------------------------------------------------------------
-- FRICTION / COLLISION / EGG
----------------------------------------------------------------

local function setCharacterCollisions(enable)
	local char = LocalPlayer.Character
	if not char then return end
	for _, desc in ipairs(char:GetDescendants()) do
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

local function setFrictionless(enable)
	local char = LocalPlayer.Character
	if not char then return end
	for _, desc in ipairs(char:GetDescendants()) do
		if desc:IsA("BasePart") then
			if enable then
				if originalPhysicalProperties[desc] == nil then
					originalPhysicalProperties[desc] = desc.CustomPhysicalProperties
				end
				pcall(function() desc.CustomPhysicalProperties = zeroFriction end)
			else
				local original = originalPhysicalProperties[desc]
				pcall(function() desc.CustomPhysicalProperties = original end)
				originalPhysicalProperties[desc] = nil
			end
		end
	end
	setCharacterCollisions(not enable)
end

local function neutraliseEggPhysics(char)
	char = char or LocalPlayer.Character
	if not char then return end
	for _, desc in ipairs(char:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" and desc.Parent ~= char then
			pcall(function()
				desc.Massless = true
				desc.CanCollide = false
			end)
		end
	end
	local cra = Workspace:FindFirstChild("ClientRenderedAssets")
	if cra then
		for _, model in ipairs(cra:GetChildren()) do
			if string.find(model.Name, tostring(LocalPlayer.UserId)) then
				for _, part in ipairs(model:GetDescendants()) do
					if part:IsA("BasePart") then
						pcall(function()
							part.Massless = true
							part.CanCollide = false
						end)
					end
				end
			end
		end
	end
end

----------------------------------------------------------------
-- NETWORKING
----------------------------------------------------------------

local function getRemote(subPath)
	local ok, rem = pcall(function() return ReplicatedStorage.Packages.Networking[subPath] end)
	return ok and rem or nil
end

local function carryEggRemote(uid)
	local rf = getRemote("RF/EggWorld/AskFieldEggCarry")
	if not rf or not uid then return false end
	task.spawn(function() pcall(function() rf:InvokeServer({ Uid = tostring(uid) }) end) end)
	return true
end

local function dropEggRemote()
	local rf = getRemote("RF/EggWorld/AskFieldEggDrop")
	if rf then pcall(function() rf:InvokeServer() end) end
end

local function extractTargetPosition(record)
	if typeof(record) ~= "table" then return nil end
	if typeof(record.BoundsCFrame) == "CFrame" then return record.BoundsCFrame.Position end
	if typeof(record.BottomCFrame) == "CFrame" then return record.BottomCFrame.Position end
	local p = record.Position or record.Pos or record.pos or record.P
	if typeof(p) == "Vector3" then return p end
	if typeof(p) == "table" and p.X and p.Y and p.Z then return Vector3.new(p.X, p.Y, p.Z) end
	return nil
end

local function parseSnapshotEggs(raw)
	local records = {}
	if typeof(raw) ~= "table" then return records end
	local source = raw.Records or raw.records
	if typeof(source) ~= "table" then return records end
	for _, rec in pairs(source) do
		if typeof(rec) == "table" then
			local pos = extractTargetPosition(rec)
			local uid = rec.Uid or rec.uid or rec.UID or rec.Id or rec.id
			local area = rec.AreaId or rec.areaId or rec.Area or rec.Biome or rec.biome
			local category = rec.AssetCategory or rec.assetCategory or rec.Category
			if uid and pos then
				table.insert(records, {
					Uid = tostring(uid),
					AreaId = tostring(area or "Unknown"),
					AssetCategory = tostring(category or "Egg"),
					Position = pos,
					CarrierUserId = rec.CarrierUserId or rec.carrierUserId,
				})
			end
		end
	end
	return records
end

local function fetchSnapshot(forceRefresh)
	if not forceRefresh and cachedSnapshot and #cachedSnapshot > 0 then return cachedSnapshot end
	local rf = getRemote("RF/EggWorld/AskFieldEggSnapshot")
	if not rf then return {} end
	local ok, res = pcall(function() return rf:InvokeServer() end)
	if ok and typeof(res) == "table" then
		cachedSnapshot = parseSnapshotEggs(res)
		return cachedSnapshot
	end
	return {}
end

local function requestSnapshotAsync()
	if snapshotTried then return end
	snapshotTried = true
	task.spawn(function() fetchSnapshot() end)
end

local function triggerEggPrompts()
	pcall(function()
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then return end
		local pPos = root.Position
		for _, desc in ipairs(Workspace:GetDescendants()) do
			if desc:IsA("ProximityPrompt") then
				local part = desc.Parent
				if part and part:IsA("BasePart") and (part.Position - pPos).Magnitude <= 20 then
					pcall(function() fireproximityprompt(desc, 0) end)
				end
			end
		end
	end)
end

local function touchEggHitbox(uid)
	pcall(function()
		local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if not root or typeof(firetouchinterest) ~= "function" then return end
		local area = Workspace:FindFirstChild("AreaEggSlotsClient")
		if area and uid then
			local eggModel = area:FindFirstChild(uid) or area:FindFirstChild(tostring(uid))
			if eggModel then
				local hb = eggModel:FindFirstChild("Hitbox") or eggModel:FindFirstChildWhichIsA("BasePart")
				if hb then
					firetouchinterest(root, hb, 0)
					task.defer(function() pcall(function() firetouchinterest(root, hb, 1) end) end)
				end
			end
		end
	end)
end

local function isHoldingEgg()
	local char = LocalPlayer.Character
	if char then
		for _, child in ipairs(char:GetChildren()) do
			local cName = string.lower(child.Name)
			if child:IsA("Tool") and not string.find(cName, "trap") then return true end
			if string.find(cName, "egg") or string.find(cName, "carried") then return true end
		end
		for _, desc in ipairs(char:GetDescendants()) do
			if desc:IsA("JointInstance") then
				local p1, p2 = desc.Part0, desc.Part1
				if p1 and p2 then
					local n1, n2 = string.lower(p1.Name), string.lower(p2.Name)
					if string.find(n1, "egg") or string.find(n2, "egg") then return true end
				end
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
		for _, model in ipairs(cra:GetChildren()) do
			if string.find(model.Name, tostring(LocalPlayer.UserId)) then return true end
		end
	end
	return false
end

----------------------------------------------------------------
-- EGG LOCATORS
----------------------------------------------------------------

local function isEggAvailable(e)
	if typeof(e) ~= "table" then return false end
	local carrier = e.CarrierUserId
	return carrier == nil or carrier == 0 or carrier == "" or carrier == false
end

local function getTargetEgg(biome, forceRefresh)
	local eggs = fetchSnapshot(forceRefresh)
	local cleanTarget = cleanString(biome)
	if cleanTarget ~= "any" and cleanTarget ~= "" then
		for _, e in ipairs(eggs) do
			local cleanArea = cleanString(e.AreaId)
			if (cleanArea == cleanTarget or cleanArea:find(cleanTarget) or cleanTarget:find(cleanArea)) and isEggAvailable(e) then
				return e
			end
		end
		return nil
	end
	for _, e in ipairs(eggs) do
		if isEggAvailable(e) then return e end
	end
	return nil
end

----------------------------------------------------------------
-- GROUND WALK
----------------------------------------------------------------

local function walkToTargetOnGround(targetPos, myToken)
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local startPos = root and root.Position or targetPos
	local totalDist = (targetPos - startPos).Magnitude

	local timeoutS = math.clamp(totalDist / 10, 25.0, 120.0)
	local t0 = os.clock()
	local lastMoveToTime = 0
	local stuckCounter = 0
	local lastPosCheck = startPos

	while isRunning and currentToken == myToken and (os.clock() - t0 < timeoutS) do
		RunService.Heartbeat:Wait()
		local c = LocalPlayer.Character
		local r = c and c:FindFirstChild("HumanoidRootPart")
		local hum = c and c:FindFirstChildOfClass("Humanoid")
		if not r or not hum or hum.Health <= 0 then break end

		local distH = math.sqrt((targetPos.X - r.Position.X)^2 + (targetPos.Z - r.Position.Z)^2)
		if distH <= 5.5 then
			hum:MoveTo(r.Position)
			break
		end

		if (r.Position - lastPosCheck).Magnitude < 1.0 and distH > 10 then
			stuckCounter += 1
			if stuckCounter > 12 then
				hum.Jump = true
				stuckCounter = 0
			end
		else
			stuckCounter = 0
		end
		lastPosCheck = r.Position

		if os.clock() - lastMoveToTime > 0.11 then
			lastMoveToTime = os.clock()
			hum:MoveTo(Vector3.new(targetPos.X, r.Position.Y, targetPos.Z))
		end
	end
end

----------------------------------------------------------------
-- ESCAPE FLIGHT v6 — Grab → immediate return to Forest
-- Locked dir | Y=112.5 | Horiz vel = 0 | large steps | ≤2.5s
----------------------------------------------------------------

local function executeEscapeFlightToForest(myToken)
	setFrictionless(true)
	isFlying = true

	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then
		isFlying = false
		return
	end

	hum:MoveTo(root.Position)

	local animTrack = nil
	pcall(function()
		local animator = hum:FindFirstChildOfClass("Animator") or hum
		local anim = Instance.new("Animation")
		anim.AnimationId = FLIGHT_ANIM_ID
		animTrack = animator:LoadAnimation(anim)
		animTrack.Priority = Enum.AnimationPriority.Movement
		animTrack:Play()
	end)

	-- Capture start AFTER stopping any residual walk velocity
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	task.wait()  -- one frame settle so position is stable

	local startPos = root.Position
	-- Force direction: always decrease X toward Forest from egg area
	local lockedDir = Vector3.new(-1, 0, 0)
	if startPos.X < FOREST_LANDING.X then
		-- already west of Forest — aim at it
		local to = Vector3.new(FOREST_LANDING.X - startPos.X, 0, FOREST_LANDING.Z - startPos.Z)
		if to.Magnitude > 1 then lockedDir = to.Unit end
	else
		-- from egg: go west, slight Z correction
		local dz = FOREST_LANDING.Z - startPos.Z
		local len = math.sqrt(1 + (dz / math.max(startPos.X - FOREST_LANDING.X, 1))^2)
		lockedDir = Vector3.new(-1 / len, 0, (dz / math.max(startPos.X - FOREST_LANDING.X, 1)) / len)
	end

	local totalDist = (Vector3.new(FOREST_LANDING.X, 0, FOREST_LANDING.Z)
		- Vector3.new(startPos.X, 0, startPos.Z)).Magnitude
	if totalDist < 10 then
		-- already close: soft drop only
		root.CFrame = CFrame.new(startPos.X, FOREST_LANDING.Y + 3, startPos.Z)
		root.AssemblyLinearVelocity = Vector3.zero
		isFlying = false
		return
	end

	local traveled = 0
	local t0 = os.clock()

	-- Ramp to cruise (no wrong-way first step)
	for i = 1, 5 do
		if not isRunning or currentToken ~= myToken then break end
		if os.clock() - t0 > MAX_FLIGHT_S then break end
		RunService.Heartbeat:Wait()

		local r = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if not r then break end
		neutraliseEggPhysics(LocalPlayer.Character)

		local alpha = i / 5
		traveled = math.min(traveled + STEP_SIZE, totalDist)
		local xz = startPos + lockedDir * traveled
		-- never increase X when leaving egg area
		if startPos.X > 2000 then
			xz = Vector3.new(math.min(xz.X, startPos.X - 1), xz.Y, xz.Z)
		end
		local y = startPos.Y + (CRUISE_Y - startPos.Y) * alpha
		local nextPos = Vector3.new(xz.X, y, xz.Z)

		r.CFrame = CFrame.new(nextPos, nextPos + lockedDir)
		r.AssemblyLinearVelocity = Vector3.new(0, -8, 0)
		r.AssemblyAngularVelocity = Vector3.zero
	end

	-- Main cruise — stop when near Forest, NO big final teleport
	while isRunning and currentToken == myToken do
		if os.clock() - t0 > MAX_FLIGHT_S then break end
		RunService.Heartbeat:Wait()

		local c = LocalPlayer.Character
		local r = c and c:FindFirstChild("HumanoidRootPart")
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if not r or not h or h.Health <= 0 then break end

		neutraliseEggPhysics(c)

		local cur = r.Position
		local remain = (Vector3.new(FOREST_LANDING.X, 0, FOREST_LANDING.Z)
			- Vector3.new(cur.X, 0, cur.Z)).Magnitude

		-- Arrive at Forest still at cruise height
		if remain <= 25 or cur.X <= (FOREST_LANDING.X + 30) then
			break
		end

		local step = STEP_SIZE
		if remain < 120 then
			step = math.clamp(remain * 0.5, 28, STEP_SIZE)
		end

		traveled = traveled + step
		if traveled > totalDist + 40 then break end

		local xz = startPos + lockedDir * traveled
		if startPos.X > 2000 then
			xz = Vector3.new(math.min(xz.X, cur.X - 1), xz.Y, xz.Z)
		end
		local nextPos = Vector3.new(xz.X, CRUISE_Y, xz.Z)

		r.CFrame = CFrame.new(nextPos, nextPos + lockedDir)
		r.AssemblyLinearVelocity = Vector3.new(0, -10, 0)
		r.AssemblyAngularVelocity = Vector3.zero
	end

	-- Soft descent at Forest (no 2000+ stud snap)
	do
		local r = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if r then
			local cur = r.Position
			-- step down in 3 frames instead of one big drop
			for i = 1, 3 do
				if not isRunning or currentToken ~= myToken then break end
				RunService.Heartbeat:Wait()
				r = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
				if not r then break end
				local alpha = i / 3
				local y = CRUISE_Y + (FOREST_LANDING.Y + 3 - CRUISE_Y) * alpha
				local x = cur.X + (FOREST_LANDING.X - cur.X) * alpha
				local z = cur.Z + (FOREST_LANDING.Z - cur.Z) * alpha
				r.CFrame = CFrame.new(x, y, z)
				r.AssemblyLinearVelocity = Vector3.new(0, -12, 0)
				r.AssemblyAngularVelocity = Vector3.zero
			end
			r = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			if r then
				r.CFrame = CFrame.new(FOREST_LANDING + Vector3.new(0, 3, 0))
				r.AssemblyLinearVelocity = Vector3.zero
				r.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end

	if animTrack and animTrack.IsPlaying then
		pcall(function() animTrack:Stop(0.1) end)
	end

	isFlying = false
end

----------------------------------------------------------------
-- RIG RECOVERY
----------------------------------------------------------------

local function recoverCharacterRig(char)
	char = char or LocalPlayer.Character
	if not char then return end
	setCharacterCollisions(true)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		pcall(function()
			hum.PlatformStand = false
			hum.Sit = false
			hum.AutoRotate = true
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end
end

----------------------------------------------------------------
-- MAIN PIPELINE
----------------------------------------------------------------

local function executeTeleportPipeline(statusLabel)
	currentToken = currentToken + 1
	local myToken = currentToken
	isRunning = true

	local function updateStatus(text, color)
		if statusLabel then
			statusLabel.Text = text
			if color then statusLabel.TextColor3 = color end
		end
	end

	task.spawn(function()
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum  = char and char:FindFirstChildOfClass("Humanoid")

		if not char or not root or not hum or hum.Health <= 0 then
			updateStatus("ERROR: Character not ready!", Color3.fromRGB(255, 80, 80))
			isRunning = false
			return
		end

		captureBaseSpeed()
		requestSnapshotAsync()

		-- 1. Find egg
		updateStatus("[1/5] Scanning egg in " .. selectedBiome .. "...", Color3.fromRGB(255, 200, 80))
		local targetEgg = getTargetEgg(selectedBiome, true)
		if not targetEgg then
			updateStatus("ABORTED: No egg found!", Color3.fromRGB(255, 80, 80))
			isRunning = false
			return
		end

		local targetPos = targetEgg.Position
		local targetName = string.format("%s (%s)", tostring(targetEgg.AreaId or selectedBiome), tostring(targetEgg.AssetCategory or "Egg"))

		-- 2. Walk to egg (ground only)
		updateStatus(string.format("[2/5] Moving to %s...", targetName), Color3.fromRGB(80, 210, 255))
		walkToTargetOnGround(targetPos, myToken)

		if not isRunning or currentToken ~= myToken then
			isRunning = false
			return
		end

		-- 3. Instant grab + immediate escape (NO boss wait)
		updateStatus("[3/5] Grab + ESCAPE...", Color3.fromRGB(255, 160, 80))

		local c = LocalPlayer.Character
		local r = c and c:FindFirstChild("HumanoidRootPart")
		if r then
			setFrictionless(true)
			neutraliseEggPhysics(c)
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
		end

		for i = 1, 8 do
			carryEggRemote(targetEgg.Uid)
			triggerEggPrompts()
			touchEggHitbox(targetEgg.Uid)
			task.wait(0.03)
		end

		-- Background carry while flying
		task.spawn(function()
			local t0 = os.clock()
			while isRunning and currentToken == myToken and (os.clock() - t0 < 6) do
				carryEggRemote(targetEgg.Uid)
				task.wait(0.1)
			end
		end)

		-- 4. Escape flight → Forest (immediate)
		updateStatus("[4/5] ESCAPE FLIGHT → Forest...", Color3.fromRGB(255, 180, 100))
		executeEscapeFlightToForest(myToken)

		-- Soft land
		setFrictionless(false)
		hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then
			pcall(function()
				hum.PlatformStand = false
				hum.WalkSpeed = FOREST_WALK_SPEED
				hum:ChangeState(Enum.HumanoidStateType.GettingUp)
			end)
		end
		task.wait(0.15)

		-- Drop + quick re-carry
		dropEggRemote()
		task.wait(0.12)
		for i = 1, 6 do
			carryEggRemote(targetEgg.Uid)
			task.wait(0.06)
		end

		-- 5. Ground walk Forest → Safe Zone
		updateStatus("[5/5] Forest → Safe Zone...", Color3.fromRGB(100, 255, 170))
		walkToTargetOnGround(SAFE_ZONE_POSITION, myToken)

		task.wait(0.12)
		dropEggRemote()
		restoreBaseSpeed()

		updateStatus("COMPLETED!", Color3.fromRGB(100, 255, 170))
		print("[Steal-Pipeline v6.0] Escape flight completed.")
		isRunning = false
	end)
end

----------------------------------------------------------------
-- GUI
----------------------------------------------------------------

local oldGui = PlayerGui:FindFirstChild(GUI_NAME)
if oldGui then pcall(function() oldGui:Destroy() end) end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.Parent = PlayerGui

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 460, 0, 300)
main.Position = UDim2.new(0.03, 0, 0.35, 0)
main.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
Instance.new("UIStroke", main).Color = Color3.fromRGB(70, 90, 140)

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 32)
titleBar.BackgroundColor3 = Color3.fromRGB(24, 30, 46)
titleBar.BorderSizePixel = 0
titleBar.Active = true
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 1, 0)
title.Position = UDim2.new(0, 10, 0, 0)
title.BackgroundTransparency = 1
title.Text = "STEAL AN EGG: ESCAPE FLIGHT v6.0"
title.TextColor3 = Color3.fromRGB(120, 220, 255)
title.TextSize = 11
title.Font = Enum.Font.GothamBold
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

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.Position = UDim2.new(1, -29, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1,1,1)
closeBtn.TextSize = 12
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = main
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

local statusBox = Instance.new("Frame")
statusBox.Size = UDim2.new(1, -20, 0, 48)
statusBox.Position = UDim2.new(0, 10, 0, 38)
statusBox.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
statusBox.BorderSizePixel = 0
statusBox.Parent = main
Instance.new("UICorner", statusBox).CornerRadius = UDim.new(0, 6)

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -16, 0, 38)
statusLabel.Position = UDim2.new(0, 8, 0, 5)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Ready. Walk→Grab→Escape (Y=112.5, Horiz=0). No boss wait."
statusLabel.TextColor3 = Color3.fromRGB(180, 220, 255)
statusLabel.TextSize = 10
statusLabel.Font = Enum.Font.Code
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.Parent = statusBox

local biomeBtn = Instance.new("TextButton")
biomeBtn.Size = UDim2.new(1, -20, 0, 26)
biomeBtn.Position = UDim2.new(0, 10, 0, 92)
biomeBtn.BackgroundColor3 = Color3.fromRGB(36, 56, 96)
biomeBtn.Text = "TARGET BIOME: [" .. selectedBiome .. "] (Click to switch)"
biomeBtn.TextColor3 = Color3.fromRGB(220, 240, 255)
biomeBtn.TextSize = 10
biomeBtn.Font = Enum.Font.GothamBold
biomeBtn.Parent = main
Instance.new("UICorner", biomeBtn).CornerRadius = UDim.new(0, 5)

local targetLabel = Instance.new("TextLabel")
targetLabel.Size = UDim2.new(1, -20, 0, 22)
targetLabel.Position = UDim2.new(0, 10, 0, 126)
targetLabel.BackgroundTransparency = 1
targetLabel.Text = "Target: scanning..."
targetLabel.TextColor3 = Color3.fromRGB(150, 180, 220)
targetLabel.TextSize = 9
targetLabel.Font = Enum.Font.Code
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.Parent = main

local stealBtn = Instance.new("TextButton")
stealBtn.Size = UDim2.new(1, -20, 0, 36)
stealBtn.Position = UDim2.new(0, 10, 0, 154)
stealBtn.BackgroundColor3 = Color3.fromRGB(30, 130, 75)
stealBtn.Text = "STEAL EGG → ESCAPE FLIGHT"
stealBtn.TextColor3 = Color3.new(1,1,1)
stealBtn.TextSize = 11
stealBtn.Font = Enum.Font.GothamBold
stealBtn.Parent = main
Instance.new("UICorner", stealBtn).CornerRadius = UDim.new(0, 6)

local refreshBtn = Instance.new("TextButton")
refreshBtn.Size = UDim2.new(0.48, -5, 0, 26)
refreshBtn.Position = UDim2.new(0, 10, 0, 198)
refreshBtn.BackgroundColor3 = Color3.fromRGB(50, 80, 130)
refreshBtn.Text = "Refresh Target"
refreshBtn.TextColor3 = Color3.new(1,1,1)
refreshBtn.TextSize = 10
refreshBtn.Font = Enum.Font.GothamBold
refreshBtn.Parent = main
Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, 5)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0.48, -5, 0, 26)
stopBtn.Position = UDim2.new(0.52, 0, 0, 198)
stopBtn.BackgroundColor3 = Color3.fromRGB(110, 40, 40)
stopBtn.Text = "Emergency Stop"
stopBtn.TextColor3 = Color3.new(1,1,1)
stopBtn.TextSize = 10
stopBtn.Font = Enum.Font.GothamBold
stopBtn.Parent = main
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 5)

local footer = Instance.new("TextLabel")
footer.Size = UDim2.new(1, -20, 0, 50)
footer.Position = UDim2.new(0, 10, 0, 234)
footer.BackgroundTransparency = 1
footer.Text = "v6.0: Walk to egg → Grab → Escape (Y=112.5 Horiz=0)\nNo boss wait | Forest land → Safe Zone walk"
footer.TextColor3 = Color3.fromRGB(120, 140, 175)
footer.TextSize = 9
footer.Font = Enum.Font.Code
footer.TextWrapped = true
footer.Parent = main

----------------------------------------------------------------
-- BINDINGS
----------------------------------------------------------------

local function updateTargetDisplay()
	local targetEgg = getTargetEgg(selectedBiome)
	local targetText = targetEgg
		and string.format("Target [%s]: %s | Pos: (%.0f, %.1f, %.0f)",
			tostring(targetEgg.AreaId or selectedBiome),
			tostring(targetEgg.AssetCategory or "Egg"),
			targetEgg.Position.X, targetEgg.Position.Y, targetEgg.Position.Z)
		or string.format("Target [%s]: NONE FOUND", selectedBiome)
	targetLabel.Text = targetText
end

biomeBtn.MouseButton1Click:Connect(function()
	if isRunning then return end
	selectedBiomeIndex = (selectedBiomeIndex % #TARGET_BIOMES) + 1
	selectedBiome = TARGET_BIOMES[selectedBiomeIndex]
	biomeBtn.Text = "TARGET BIOME: [" .. selectedBiome .. "] (Click to switch)"
	updateTargetDisplay()
end)

refreshBtn.MouseButton1Click:Connect(function()
	if isRunning then return end
	statusLabel.Text = "Refreshing..."
	cachedSnapshot = nil
	snapshotTried = false
	task.spawn(function()
		fetchSnapshot()
		updateTargetDisplay()
		statusLabel.Text = "Snapshot refreshed."
	end)
end)

stealBtn.MouseButton1Click:Connect(function()
	if isRunning then return end
	executeTeleportPipeline(statusLabel)
end)

stopBtn.MouseButton1Click:Connect(function()
	currentToken = currentToken + 1
	isRunning = false
	isFlying = false
	setFrictionless(false)
	dropEggRemote()
	restoreBaseSpeed()
	recoverCharacterRig(LocalPlayer.Character)
	statusLabel.Text = "Stopped."
	statusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
end)

local isGuiClosed = false
local function handleClose()
	if isGuiClosed then return end
	isGuiClosed = true
	currentToken = currentToken + 1
	isRunning = false
	isFlying = false
	pcall(function() gui:Destroy() end)
	task.spawn(function()
		setFrictionless(false)
		dropEggRemote()
		restoreBaseSpeed()
		recoverCharacterRig(LocalPlayer.Character)
	end)
end
closeBtn.Activated:Connect(handleClose)
closeBtn.MouseButton1Click:Connect(handleClose)

captureBaseSpeed()
requestSnapshotAsync()
task.defer(function()
	task.wait(0.2)
	updateTargetDisplay()
end)

print("[Steal-Pipeline v6.0] Escape flight ready. Walk→Grab→Forest→Safe.")
