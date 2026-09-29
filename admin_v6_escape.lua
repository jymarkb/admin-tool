--[[=========================================================================
	STEAL AN EGG — ESCAPE FLIGHT v6.2
	+ Ground approach → confirmed target carry → immediate escape (no boss wait)
	+ Heading to Forest | Y=112.5 | zero horizontal physics velocity
	+ Bounded live-position steps; limited correction recovery, no landing snap
	+ Preserve PlatformStand and original part physics; walk to Safe Zone

	Log audit (scanner_v3.1.lua, other-script.log, normal-run-log-no-script.log):
	- Scripted returns cruise near Y=112.2–112.7, land near (612.2,70.7,-325).
	- Neither capture has a HOLDING → EMPTY transition. The scanner's broad
	  tool/name/rendered-asset heuristic cannot confirm pickup or delivery.
	- FLIGHT_START is delayed four samples; FLIGHT_END can split one flight.
	- LARGE_MOVE dt can be zero because ZERO_HORIZ updates its shared timer;
	  height variance includes takeoff/landing. Neither is a tuning target.
	- Follow-up 12:35:37: three 78-stud steps, then a 234-stud X/Z rollback
	  to takeoff. v6.1 would abort here; the later Physics impulse is not proof of
	  the rollback's cause. Retry only limited corrections, never catch up by
	  teleporting along the old path. Log recovery/abort reasons explicitly.
=========================================================================]]

local Players                = game:GetService("Players")
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
local FOREST_LANDING      = Vector3.new(612.2, 70.7, -325.0)

local CRUISE_Y            = 112.5
local STEP_SIZE           = 78
local MIN_FLIGHT_S        = 2.5
local MAX_FLIGHT_S        = 6.0 -- absolute cap, including recovery and descent
local LANDING_BUDGET_S    = 0.5
local MAX_CORRECTIONS     = 2
local CORRECTION_DISTANCE = 8
local MAX_CORRECTION_DIST = STEP_SIZE * 4
local FLIGHT_SPEED        = STEP_SIZE * 60 -- studs/s, capped at STEP_SIZE per frame
local VERTICAL_STEP      = 12
local ARRIVAL_RADIUS     = 5.5
local CARRY_TIMEOUT_S    = 3
local REMOTE_TIMEOUT_S   = 3
local FLIGHT_ANIM_ID      = "rbxassetid://102039335618606"

local GUI_NAME            = "GrokEscapeFlightV6"

local currentToken        = 0
local isRunning           = false
local isFlying            = false
local cachedSnapshot      = nil
local snapshotTried       = false
local runCharacter        = nil
local flightTrack         = nil

local zeroFriction = PhysicalProperties.new(0.7, 0, 0, 100, 100)
local originalPhysicalProperties = {}
local savedCollisions = {}
local savedMassless = {}

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local function cleanString(str)
	return string.lower(tostring(str or "")):gsub("[%s_%-]", "")
end

local function captureBaseSpeed()
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then dynamicBaseWalkSpeed = hum.WalkSpeed end
	return dynamicBaseWalkSpeed
end

local function restoreBaseSpeed()
	local hum = runCharacter and runCharacter:FindFirstChildOfClass("Humanoid")
	if hum then pcall(function() hum.WalkSpeed = dynamicBaseWalkSpeed end) end
end

local function getRunRig(myToken)
	if not isRunning or currentToken ~= myToken then return nil, nil, "Cancelled" end
	local char = LocalPlayer.Character
	if not char or char ~= runCharacter then return nil, nil, "Character changed" end
	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return nil, nil, "Character not ready" end
	return root, hum
end

local function horizontalDistance(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function hasTargetEggAttribute(uid)
	local carriedUid = LocalPlayer:GetAttribute("EggUid")
	return carriedUid ~= nil and tostring(carriedUid) == tostring(uid)
end

local function traceRun(tag, message)
	print(string.format("[Steal-Pipeline v6.2] t=%.3f %s | %s", os.clock(), tag, message))
end

----------------------------------------------------------------
-- REVERSIBLE FRICTION / COLLISION / EGG PHYSICS
----------------------------------------------------------------

local function setCharacterCollisions(enable)
	if enable then
		for part, original in pairs(savedCollisions) do
			pcall(function() part.CanCollide = original end)
			savedCollisions[part] = nil
		end
		return
	end
	local char = runCharacter
	if not char then return end
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") then
			if savedCollisions[part] == nil then savedCollisions[part] = part.CanCollide end
			part.CanCollide = false
		end
	end
end

local function setFrictionless(enable)
	if not enable then
		for part, original in pairs(originalPhysicalProperties) do
			pcall(function() part.CustomPhysicalProperties = original.value end)
			originalPhysicalProperties[part] = nil
		end
		for part, original in pairs(savedMassless) do
			pcall(function() part.Massless = original end)
			savedMassless[part] = nil
		end
		setCharacterCollisions(true)
		return
	end
	local char = runCharacter
	if not char then return end
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") then
			-- A wrapper preserves nil (Roblox's default material properties).
			if originalPhysicalProperties[part] == nil then
				originalPhysicalProperties[part] = { value = part.CustomPhysicalProperties }
			end
			part.CustomPhysicalProperties = zeroFriction
		end
	end
	setCharacterCollisions(false)
end

local function neutraliseEggPhysics(char)
	-- Only attached character parts, not unrelated models whose name happens
	-- to contain the user ID. Every change is reversible, even after reparenting.
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Parent ~= char then
			if savedMassless[part] == nil then savedMassless[part] = part.Massless end
			if savedCollisions[part] == nil then savedCollisions[part] = part.CanCollide end
			part.Massless = true
			part.CanCollide = false
		end
	end
end

local function cleanupRun()
	if flightTrack then
		pcall(function() flightTrack:Stop(0.1); flightTrack:Destroy() end)
		flightTrack = nil
	end
	isFlying = false
	setFrictionless(false)
	restoreBaseSpeed()
	local hum = runCharacter and runCharacter:FindFirstChildOfClass("Humanoid")
	local root = runCharacter and runCharacter:FindFirstChild("HumanoidRootPart")
	if hum and root then
		pcall(function() hum:Move(Vector3.zero); hum:MoveTo(root.Position) end)
	end
end

local function stopRun()
	currentToken += 1
	isRunning = false
	cleanupRun()
	runCharacter = nil
end

----------------------------------------------------------------
-- NETWORKING
----------------------------------------------------------------

local function getRemote(subPath)
	local ok, rem = pcall(function() return ReplicatedStorage.Packages.Networking[subPath] end)
	return ok and rem or nil
end

-- InvokeServer can yield indefinitely. Bound the wait and allow at most one
-- outstanding request per remote; late responses never change run state.
local pendingRemotes = {}
local function invokeRemote(subPath, payload, myToken, confirmedWhileWaiting)
	local rf = getRemote(subPath)
	if not rf or (myToken and not getRunRig(myToken)) then return false, nil end
	local request = pendingRemotes[subPath]
	if request and subPath ~= "RF/EggWorld/AskFieldEggSnapshot" then return false, nil end
	if not request then
		request = { done = false }
		pendingRemotes[subPath] = request
		task.spawn(function()
			if not myToken or getRunRig(myToken) then
				request.ok, request.result = pcall(function()
					if payload == nil then return rf:InvokeServer() end
					return rf:InvokeServer(payload)
				end)
			end
			request.done = true
			if pendingRemotes[subPath] == request then pendingRemotes[subPath] = nil end
		end)
	end
	local deadline = os.clock() + REMOTE_TIMEOUT_S
	while not request.done do
		if myToken and not getRunRig(myToken) then return false, nil end
		-- A replicated target UID can arrive before InvokeServer returns. Do not
		-- hold the character at the egg solely to wait for that late response.
		if confirmedWhileWaiting and confirmedWhileWaiting() then return true, nil end
		if os.clock() >= deadline then return false, nil end
		RunService.Heartbeat:Wait()
	end
	if myToken and not getRunRig(myToken) then return false, nil end
	return request.ok, request.result
end

local function carryEggRemote(uid, myToken)
	if not uid or not getRunRig(myToken) then return false end
	if hasTargetEggAttribute(uid) then return true end
	local ok, result = invokeRemote("RF/EggWorld/AskFieldEggCarry", { Uid = tostring(uid) }, myToken,
		function() return hasTargetEggAttribute(uid) end)
	return ok and result ~= false
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

local function fetchSnapshot(forceRefresh, myToken)
	if not forceRefresh and cachedSnapshot and #cachedSnapshot > 0 then return cachedSnapshot end
	local ok, res = invokeRemote("RF/EggWorld/AskFieldEggSnapshot", nil, myToken)
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

local function isHoldingEgg(uid, myToken)
	if not getRunRig(myToken) then return false end
	if hasTargetEggAttribute(uid) then return true end
	-- Generic Tools, IsCarrying and rendered model names do not identify the
	-- selected egg. Fall back to fresh, target-specific ownership evidence.
	for _, egg in ipairs(fetchSnapshot(true, myToken)) do
		if egg.Uid == tostring(uid) then
			return tonumber(egg.CarrierUserId) == LocalPlayer.UserId
		end
	end
	return false
end

local function confirmCarry(uid, myToken)
	local deadline = os.clock() + CARRY_TIMEOUT_S
	local probe = nil
	local nextProbeAt = 0
	while getRunRig(myToken) do
		-- Keep watching local replication while a snapshot is in flight instead
		-- of serially adding a full remote timeout to the pickup delay.
		if hasTargetEggAttribute(uid) then return true end
		if os.clock() >= deadline then break end
		if probe and probe.done then
			if probe.holding then return true end
			probe = nil
			nextProbeAt = os.clock() + 0.15
		end
		if not probe and os.clock() >= nextProbeAt then
			local request = { done = false }
			probe = request
			task.spawn(function()
				request.holding = isHoldingEgg(uid, myToken)
				request.done = true
			end)
		end
		RunService.Heartbeat:Wait()
	end
	return false
end

----------------------------------------------------------------
-- EGG LOCATORS
----------------------------------------------------------------

local function isEggAvailable(e)
	if typeof(e) ~= "table" then return false end
	local carrier = e.CarrierUserId
	return carrier == nil or carrier == 0 or carrier == "0" or carrier == "" or carrier == false
end

local function getTargetEgg(biome, forceRefresh, myToken)
	local eggs = fetchSnapshot(forceRefresh, myToken)
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
	local root, hum, reason = getRunRig(myToken)
	if not root then return false, reason end
	local distance = horizontalDistance(targetPos, root.Position)
	local timeoutS = math.clamp(distance / math.max(hum.WalkSpeed, 1) * 2 + 10, 25, 180)
	local t0, lastMoveToTime, lastProgressTime = os.clock(), 0, os.clock()
	local lastPosCheck = root.Position

	while os.clock() - t0 < timeoutS do
		RunService.Heartbeat:Wait()
		root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		if horizontalDistance(targetPos, root.Position) <= ARRIVAL_RADIUS
			and math.abs(targetPos.Y - root.Position.Y) <= 8
			and hum.FloorMaterial ~= Enum.Material.Air then
			hum:MoveTo(root.Position)
			return true
		end
		-- Measure progress over time, not <1 stud per frame (normal at 16 speed).
		if horizontalDistance(root.Position, lastPosCheck) >= 1 then
			lastPosCheck, lastProgressTime = root.Position, os.clock()
		elseif os.clock() - lastProgressTime >= 1 then
			if not root.Anchored and hum.FloorMaterial ~= Enum.Material.Air then hum.Jump = true end
			lastProgressTime = os.clock()
		end
		if not root.Anchored and os.clock() - lastMoveToTime >= 0.11 then
			lastMoveToTime = os.clock()
			hum:MoveTo(Vector3.new(targetPos.X, root.Position.Y, targetPos.Z))
		end
	end
	return false, "Ground approach timed out"
end

----------------------------------------------------------------
-- ESCAPE FLIGHT — bounded steps; never land from a timeout/failed approach
----------------------------------------------------------------

local function executeEscapeFlightToForest(myToken)
	local root, hum, reason = getRunRig(myToken)
	if not root then return false, reason end
	if root.Anchored then return false, "Character is anchored" end
	if horizontalDistance(root.Position, FOREST_LANDING) <= ARRIVAL_RADIUS
		and math.abs(root.Position.Y - FOREST_LANDING.Y) <= 3
		and hum.FloorMaterial ~= Enum.Material.Air then
		return true
	end
	isFlying = true
	setFrictionless(true)
	hum:Move(Vector3.zero)
	hum:MoveTo(root.Position)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero

	pcall(function()
		local animator = hum:FindFirstChildOfClass("Animator") or hum
		local anim = Instance.new("Animation")
		anim.AnimationId = FLIGHT_ANIM_ID
		local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
		anim:Destroy()
		if ok then
			flightTrack = track
			track.Priority = Enum.AnimationPriority.Movement
			track:Play()
		end
	end)

	local startPos = root.Position
	local totalDist = horizontalDistance(startPos, FOREST_LANDING)
	local expectedPos = startPos
	local heading = Vector3.new(-1, 0, 0)
	local corrections = 0
	local startedAt = os.clock()
	local hardDeadline = startedAt + MAX_FLIGHT_S
	local deadline = startedAt + MIN_FLIGHT_S
	traceRun("FLIGHT_START", string.format("pos=(%.1f,%.1f,%.1f) distance=%.1f",
		startPos.X, startPos.Y, startPos.Z, totalDist))

	while true do
		local dt = RunService.Heartbeat:Wait()
		root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		if os.clock() >= deadline then return false, "Flight timed out; no landing snap" end
		if root.Anchored then return false, "Character anchored during flight" end
		local state = hum:GetState()
		if state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.Ragdoll
			or state == Enum.HumanoidStateType.FallingDown then
			return false, "Flight interrupted by humanoid state " .. state.Name
		end

		local currentPos = root.Position
		local correction = horizontalDistance(currentPos, expectedPos)
		local verticalCorrection = math.abs(currentPos.Y - expectedPos.Y)
		if correction > CORRECTION_DISTANCE or verticalCorrection > VERTICAL_STEP * 2 then
			corrections += 1
			traceRun("FLIGHT_CORRECTION", string.format("attempt=%d/%d xz=%.1f dy=%.1f pos=(%.1f,%.1f,%.1f)",
				corrections, MAX_CORRECTIONS, correction, verticalCorrection, currentPos.X, currentPos.Y, currentPos.Z))
			if corrections > MAX_CORRECTIONS or math.max(correction, verticalCorrection) > MAX_CORRECTION_DIST + 0.01 then
				return false, "Repeated/large position corrections; flight stopped"
			end
			-- Rebase this step on the observed position, not the old traveled
			-- distance. A 234-stud rollback must not cause a 312-stud catch-up.
		end

		local offset = Vector3.new(FOREST_LANDING.X - currentPos.X, 0, FOREST_LANDING.Z - currentPos.Z)
		local remaining = offset.Magnitude
		-- The 78-stud cap reduces effective speed below 60 FPS. Budget for the
		-- remaining distance at that rate; recovery never resets the hard cap.
		local effectiveSpeed = math.min(FLIGHT_SPEED, STEP_SIZE / math.max(dt, 1 / 60))
		deadline = math.min(hardDeadline, math.max(deadline,
			os.clock() + remaining / effectiveSpeed + LANDING_BUDGET_S))
		if remaining <= 0.5 and math.abs(currentPos.Y - CRUISE_Y) <= 0.5 then break end

		setFrictionless(true)
		neutraliseEggPhysics(runCharacter)
		if remaining > 0.001 then heading = offset.Unit end
		local step = math.min(remaining, STEP_SIZE, FLIGHT_SPEED * math.max(dt, 0))
		local xz = currentPos + heading * step
		local dy = math.clamp(CRUISE_Y - currentPos.Y, -VERTICAL_STEP, VERTICAL_STEP)
		local nextPos = Vector3.new(xz.X, currentPos.Y + dy, xz.Z)
		root.CFrame = CFrame.new(nextPos, nextPos + heading)
		root.AssemblyLinearVelocity = Vector3.new(0, -8, 0)
		root.AssemblyAngularVelocity = Vector3.zero
		expectedPos = nextPos
	end

	-- Descent is vertical only, and is permitted only after actual X/Z arrival.
	while true do
		RunService.Heartbeat:Wait()
		root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		if root.Anchored then return false, "Character anchored during landing" end
		if os.clock() >= deadline then return false, "Landing timed out" end
		if horizontalDistance(root.Position, FOREST_LANDING) > ARRIVAL_RADIUS then
			return false, "Forest arrival not confirmed"
		end
		local dy = FOREST_LANDING.Y - root.Position.Y
		local y = root.Position.Y + math.clamp(dy, -VERTICAL_STEP, VERTICAL_STEP)
		local nextPos = Vector3.new(root.Position.X, y, root.Position.Z)
		root.CFrame = CFrame.new(nextPos, nextPos + heading)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		if math.abs(dy) <= VERTICAL_STEP then break end
	end
	traceRun("FLIGHT_LANDED", string.format("elapsed=%.3fs corrections=%d pos=(%.1f,%.1f,%.1f)",
		os.clock() - startedAt, corrections, root.Position.X, root.Position.Y, root.Position.Z))
	cleanupRun()
	return true
end

----------------------------------------------------------------
-- MAIN PIPELINE
----------------------------------------------------------------

local function executeTeleportPipeline(statusLabel)
	if isRunning then return end
	currentToken += 1
	local myToken = currentToken
	isRunning = true
	runCharacter = LocalPlayer.Character
	captureBaseSpeed()

	local function updateStatus(text, color)
		if currentToken ~= myToken then return end
		traceRun("STATUS", text)
		if statusLabel and statusLabel.Parent then
			statusLabel.Text = text
			statusLabel.TextColor3 = color
		end
	end

	task.spawn(function()
		local ok, completed, reason = xpcall(function()
			local root, _, rigError = getRunRig(myToken)
			if not root then return false, rigError end
			updateStatus("[1/5] Scanning egg in " .. selectedBiome .. "...", Color3.fromRGB(255, 200, 80))
			local targetEgg = getTargetEgg(selectedBiome, true, myToken)
			if not getRunRig(myToken) then return false, "Cancelled" end
			if not targetEgg then return false, "No available egg found" end

			traceRun("TARGET", string.format("uid=%s biome=%s pos=(%.1f,%.1f,%.1f)",
				targetEgg.Uid, targetEgg.AreaId, targetEgg.Position.X, targetEgg.Position.Y, targetEgg.Position.Z))
			updateStatus("[2/5] Walking to " .. targetEgg.AreaId .. "...", Color3.fromRGB(80, 210, 255))
			local reached, walkError = walkToTargetOnGround(targetEgg.Position, myToken)
			if not reached then return false, walkError end

			updateStatus("[3/5] Confirming target carry...", Color3.fromRGB(255, 160, 80))
			local carryStartedAt = os.clock()
			if not carryEggRemote(targetEgg.Uid, myToken) then return false, "Carry request failed or timed out" end
			if not confirmCarry(targetEgg.Uid, myToken) then return false, "Target carry not confirmed" end
			traceRun("CARRY_READY", string.format("uid=%s elapsed=%.3fs", targetEgg.Uid, os.clock() - carryStartedAt))

			updateStatus("[4/5] ESCAPE FLIGHT → Forest...", Color3.fromRGB(255, 180, 100))
			local arrived, flightError = executeEscapeFlightToForest(myToken)
			if not arrived then return false, flightError end
			local _, hum, forestError = getRunRig(myToken)
			if not hum then return false, forestError end
			hum.WalkSpeed = FOREST_WALK_SPEED

			-- The logs do not establish a need for drop/re-carry. Keep the egg
			-- attached instead of racing drop against background carry requests.
			if not confirmCarry(targetEgg.Uid, myToken) then return false, "Carry lost during escape" end
			updateStatus("[5/5] Forest → Safe Zone...", Color3.fromRGB(100, 255, 170))
			local safe, safeError = walkToTargetOnGround(SAFE_ZONE_POSITION, myToken)
			if not safe then return false, safeError end
			return true
		end, debug.traceback)

		-- A stopped/older coroutine must not clean up or overwrite a newer run.
		if currentToken ~= myToken then return end
		cleanupRun()
		isRunning = false
		runCharacter = nil
		if not ok then
			warn("[Steal-Pipeline v6.2] " .. tostring(completed))
			updateStatus("ERROR: Run stopped; physics restored.", Color3.fromRGB(255, 80, 80))
		elseif not completed then
			updateStatus("ABORTED: " .. tostring(reason), Color3.fromRGB(255, 80, 80))
		else
			-- No delivery acknowledgement is present in either reference log.
			updateStatus("Safe Zone reached. Verify egg delivery in-game.", Color3.fromRGB(100, 255, 170))
		end
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
title.Text = "STEAL AN EGG: ESCAPE FLIGHT v6.2"
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
statusLabel.Text = "Ready. Walk → Confirm carry → Escape → Safe Zone."
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
footer.Text = "v6.2: Walk → Confirm carry → Escape (Y=112.5 Horiz=0)\nNo boss wait | Forest land → Safe Zone walk"
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
	if targetLabel.Parent then targetLabel.Text = targetText end
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
	local refreshToken = currentToken
	task.spawn(function()
		fetchSnapshot()
		updateTargetDisplay()
		if currentToken == refreshToken and not isRunning and statusLabel.Parent then
			statusLabel.Text = "Snapshot refreshed."
		end
	end)
end)

stealBtn.MouseButton1Click:Connect(function()
	if isRunning then return end
	executeTeleportPipeline(statusLabel)
end)

stopBtn.MouseButton1Click:Connect(function()
	stopRun()
	statusLabel.Text = "Stopped. Physics restored; egg not dropped."
	statusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
end)

local isGuiClosed = false
local characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(function(char)
	if char == runCharacter then
		stopRun()
		statusLabel.Text = "Stopped: character removed."
	end
end)
local function handleClose()
	if isGuiClosed then return end
	isGuiClosed = true
	stopRun()
	characterRemovingConnection:Disconnect()
	gui:Destroy()
end
closeBtn.Activated:Connect(handleClose)
gui.Destroying:Connect(handleClose)

captureBaseSpeed()
requestSnapshotAsync()
task.defer(function()
	task.wait(0.2)
	updateTargetDisplay()
end)

print("[Steal-Pipeline v6.2] Escape flight ready. Walk→Grab→Forest→Safe.")
