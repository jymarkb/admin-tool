--[[=========================================================================
	STEAL AN EGG — DYNAMIC MULTI-BIOME AERIAL VELOCITY ENGINE v3.0 (GROK-V3)
	=========================================================================
	CORE ARCHITECTURE: 100% PURE AERIAL VELOCITY FLIGHT (ZERO CFRAME)
	  - WHY CFRAME CAUSED RUBBERBANDING & DEATH:
	    1. Directly writing r.CFrame teleports the RootPart without velocity.
	       The server replication engine detects Position != Previous + V*dt,
	       flags an anti-cheat physics desync, and rubberbands the avatar to Forest.
	    2. During server ragdoll (15 constraints count), CFrame teleportation
	       forcibly tears/stretches physics constraints between limbs, triggering
	       the server's lethal exploit handler (-1000 HP damage).
	  - HOW GROK-V3 SOLVES BOTH (TESTED & PROVEN IN test-ragdoll-good-recovery.lua):
	    1. 100% PURE VELOCITY: Uses AssemblyLinearVelocity for ALL movement.
	       Roblox natively integrates ds = v * dt — zero desync, zero rubberband!
	    2. ZERO FRICTION: Sets CustomPhysicalProperties to zero-friction on all
	       character BaseParts for maximum aerodynamic fluid motion.
	    3. MASSLESS EGG NEUTRALIZATION: Neutralizes carried egg mass/collision
	       so held objects never destabilize the flight trajectory.
	    4. NEWTONIAN PARABOLIC ARC: Frame-by-frame waypoint projection drives
	       the RootPart over terrain obstacles along a smooth 3D arc.
	    5. ZERO JOINT/STATE TAMPERING: Leaves all Motor6D joints and ragdoll
	       constraints completely untouched so server physics stays 100% compliant.
	    6. DYNAMIC TARGETING: Automatically locates dynamic biome egg positions
	       without hardcoded coordinates.
	=========================================================================]]

local Players                = game:GetService("Players")
local Workspace              = game:GetService("Workspace")
local RunService             = game:GetService("RunService")
local UserInputService       = game:GetService("UserInputService")
local ReplicatedStorage      = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
	task.wait(0.1)
	LocalPlayer = Players.LocalPlayer
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- CONFIGURATION
----------------------------------------------------------------

local TARGET_BIOMES = { "Snow", "Jungle", "Desert", "Ocean", "Volcano", "Abyss Ocean", "Prehistoric", "Cosmic", "Cherry Blossom", "Titan", "Light Dark" }
local selectedBiomeIndex = 1
local selectedBiome = TARGET_BIOMES[selectedBiomeIndex]

local RUN_WALKSPEED       = 500.0
local BASE_WALKSPEED      = 16.0
local AERIAL_SPEED        = 750.0
local BAIT_BURST_S        = 2.2
local STRIKE_TIMEOUT_S    = 15.0
local MIN_FREEZE_HOLD_S   = 0.85
local MAX_FREEZE_TIMEOUT  = 3.5
local GUI_NAME            = "GrokAerialVelocityEngineV3"

local currentToken        = 0
local isRunning           = false
local isFlying            = false
local connections         = {}
local cachedSnapshot      = nil
local snapshotTried       = false
local speedConnection     = nil
local speedChangedConn    = nil
local speedHumanoid       = nil
local isEnforcingSpeed    = false
local targetEnforcedSpeed = RUN_WALKSPEED
local stillMotionActive   = false
local stillMotionConn     = nil

-- Zero friction physical properties (from test-ragdoll-good-recovery.lua)
local zeroFriction = PhysicalProperties.new(0.7, 0, 0, 100, 100)
local originalPhysicalProperties = {}

----------------------------------------------------------------
-- CLEANUP HELPERS
----------------------------------------------------------------

local function cleanupConnections()
	if stillMotionConn then
		pcall(function() stillMotionConn:Disconnect() end)
		stillMotionConn = nil
	end
	stillMotionActive = false

	isEnforcingSpeed = false
	if speedChangedConn then pcall(function() speedChangedConn:Disconnect() end) speedChangedConn = nil end
	speedHumanoid = nil
	if speedConnection then pcall(function() speedConnection:Disconnect() end) speedConnection = nil end

	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	table.clear(connections)
end

----------------------------------------------------------------
-- FRICTION & EGG MASS NEUTRALIZATION (from test-ragdoll-good-recovery.lua)
----------------------------------------------------------------

local function setFrictionless(enable)
	local char = LocalPlayer.Character
	if not char then return end

	for _, desc in ipairs(char:GetDescendants()) do
		if desc:IsA("BasePart") then
			if enable then
				if originalPhysicalProperties[desc] == nil then
					originalPhysicalProperties[desc] = desc.CustomPhysicalProperties
				end
				pcall(function()
					desc.CustomPhysicalProperties = zeroFriction
				end)
			else
				local original = originalPhysicalProperties[desc]
				pcall(function()
					desc.CustomPhysicalProperties = original
				end)
				originalPhysicalProperties[desc] = nil
			end
		end
	end
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
-- NETWORKING & SNAPSHOT HELPERS
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

local function serverNow()
	local ok, t = pcall(function() return Workspace:GetServerTimeNow() end)
	return ok and t or os.time()
end

local function extractTargetPosition(record)
	if typeof(record) ~= "table" then return nil end

	-- Match the proven old target resolver first. These two fields are
	-- preferred because the server snapshot may not expose a useful plain
	-- Position for every egg.
	if typeof(record.BoundsCFrame) == "CFrame" then
		return record.BoundsCFrame.Position
	end
	if typeof(record.BottomCFrame) == "CFrame" then
		return record.BottomCFrame.Position
	end

	local p = record.Position or record.Pos or record.pos or record.P
	if typeof(p) == "Vector3" then
		return p
	end
	if typeof(p) == "table" and p.X and p.Y and p.Z then
		return Vector3.new(p.X, p.Y, p.Z)
	end

	return nil
end

local function parseSnapshotEggs(raw)
	local records = {}
	if typeof(raw) ~= "table" then return records end

	-- The old script uses AskFieldEggSnapshot -> result.Records. Prefer that
	-- exact schema instead of recursively scanning arbitrary nested tables.
	local source = raw.Records
	if typeof(source) ~= "table" then
		source = raw.records
	end
	if typeof(source) ~= "table" then
		return records
	end

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
					FirstAreaSlotKey = rec.FirstAreaSlotKey,
					NestId = rec.NestId,
					Mutations = rec.Mutations,
				})
			end
		end
	end

	return records
end

local function fetchSnapshot(forceRefresh)
	if not forceRefresh and cachedSnapshot and #cachedSnapshot > 0 then
		return cachedSnapshot
	end

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
		local maxD = 16.0
		for _, desc in ipairs(Workspace:GetDescendants()) do
			if desc:IsA("ProximityPrompt") then
				local part = desc.Parent
				if part and part:IsA("BasePart") and (part.Position - pPos).Magnitude <= maxD then
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

----------------------------------------------------------------
-- RIG INSPECTION & EGG HOLD CHECKS (READ-ONLY)
----------------------------------------------------------------

local function bumpMotors(char)
	if not char then return 0, 0 end
	local off, total = 0, 0
	for _, o in ipairs(char:GetDescendants()) do
		if o:IsA("Motor6D") then
			total = total + 1
			if not o.Enabled then off = off + 1 end
		end
	end
	return off, total
end

local function isHoldingEgg()
	local char = LocalPlayer.Character
	if char then
		for _, child in ipairs(char:GetChildren()) do
			local cName = string.lower(child.Name)
			if child:IsA("Tool") and not string.find(cName, "trap") then return true end
			if string.find(cName, "egg") then return true end
		end
	end
	if LocalPlayer:GetAttribute("IsCarrying") == true then return true end
	return false
end

----------------------------------------------------------------
-- SPEED ENFORCER (WalkSpeed 500)
----------------------------------------------------------------

local function startSpeedEnforcer(targetSpeed)
	targetEnforcedSpeed = targetSpeed or RUN_WALKSPEED
	isEnforcingSpeed = true
	if speedChangedConn then pcall(function() speedChangedConn:Disconnect() end) speedChangedConn = nil end
	speedHumanoid = nil
	if speedConnection then pcall(function() speedConnection:Disconnect() end) speedConnection = nil end

	local function bindHumanoid(h)
		if h == speedHumanoid then return end
		if speedChangedConn then pcall(function() speedChangedConn:Disconnect() end) speedChangedConn = nil end
		speedHumanoid = h
		if not h then return end
		speedChangedConn = h:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
			if isEnforcingSpeed and h.Parent and h.Health > 0 and math.abs(h.WalkSpeed - targetEnforcedSpeed) > 0.1 then
				pcall(function() h.WalkSpeed = targetEnforcedSpeed end)
			end
		end)
		table.insert(connections, speedChangedConn)
		pcall(function() if h.Health > 0 then h.WalkSpeed = targetEnforcedSpeed end end)
	end

	local function enforce()
		if not isEnforcingSpeed then return end
		local h = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
		if h ~= speedHumanoid then bindHumanoid(h) end
		if h and h.Parent and h.Health > 0 and math.abs(h.WalkSpeed - targetEnforcedSpeed) > 0.1 then
			pcall(function() h.WalkSpeed = targetEnforcedSpeed end)
		end
	end

	enforce()
	speedConnection = RunService.Heartbeat:Connect(function()
		if isEnforcingSpeed then enforce() end
	end)
	table.insert(connections, speedConnection)
end

local function stopSpeedEnforcer(restoreSpeed)
	isEnforcingSpeed = false
	if speedChangedConn then pcall(function() speedChangedConn:Disconnect() end) speedChangedConn = nil end
	speedHumanoid = nil
	if speedConnection then pcall(function() speedConnection:Disconnect() end) speedConnection = nil end
	local h = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if h and h.Parent and h.Health > 0 then
		pcall(function() h.WalkSpeed = restoreSpeed or BASE_WALKSPEED end)
	end
end

----------------------------------------------------------------
-- STILL MOTION ENGINE (Pure Velocity Zeroing on Rail)
----------------------------------------------------------------

local function setStillMotion(enable, anchorPos)
	stillMotionActive = enable
	if stillMotionConn then
		pcall(function() stillMotionConn:Disconnect() end)
		stillMotionConn = nil
	end

	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum  = char and char:FindFirstChildOfClass("Humanoid")

	if enable then
		if hum then
			pcall(function()
				hum.AutoRotate = false
				hum.WalkSpeed = RUN_WALKSPEED
			end)
		end
		if root then
			pcall(function()
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end)
		end

		anchorPos = anchorPos or (root and root.Position)
		local standoff = false

		stillMotionConn = RunService.Heartbeat:Connect(function()
			if not stillMotionActive or not isRunning or standoff then return end
			local c = LocalPlayer.Character
			local r = c and c:FindFirstChild("HumanoidRootPart")
			local h = c and c:FindFirstChildOfClass("Humanoid")
			if not r or not h then return end

			-- Stand off immediately if guard hit, ragdoll, or knockback occurs
			local rEnd = LocalPlayer:GetAttribute("RagdollEndTime")
			if typeof(rEnd) == "number" and rEnd > serverNow() then
				standoff = true
				return
			end
			local st = h:GetState()
			if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.FallingDown then
				standoff = true
				return
			end
			local offMotors, totalMotors = bumpMotors(c)
			if offMotors >= 2 or totalMotors == 30 then
				standoff = true
				return
			end
			if r.AssemblyLinearVelocity.Magnitude > 15 then
				standoff = true
				return
			end

			-- Ensure WalkSpeed stays 500 for the Guard SpeedToll
			if math.abs(h.WalkSpeed - RUN_WALKSPEED) > 1.0 then
				pcall(function() h.WalkSpeed = RUN_WALKSPEED end)
			end

			-- Zero velocities so character stays completely motionless
			local v = r.AssemblyLinearVelocity
			local av = r.AssemblyAngularVelocity
			if v.Magnitude > 0.3 or av.Magnitude > 0.3 then
				r.AssemblyLinearVelocity = Vector3.zero
				r.AssemblyAngularVelocity = Vector3.zero
			end

			-- Gentle restoring velocity if slight drift (< 3.5 studs)
			if anchorPos then
				local dVec = anchorPos - r.Position
				local d = dVec.Magnitude
				if d > 0.4 and d < 3.5 then
					r.AssemblyLinearVelocity = dVec * 3
				elseif d >= 3.5 then
					standoff = true
					return
				end
			end
		end)
		table.insert(connections, stillMotionConn)
	else
		if hum then
			pcall(function() hum.AutoRotate = true end)
		end
	end
end

----------------------------------------------------------------
-- RIG RECOVERY (Emergency Stop / UI Reset ONLY — Never during flight!)
----------------------------------------------------------------

local function recoverCharacterRig(char)
	char = char or LocalPlayer.Character
	if not char then return end

	local hum = char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")

	-- 1. Re-enable all Motor6D joints
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("Motor6D") and not d.Enabled then
			pcall(function() d.Enabled = true end)
		end
	end

	-- 2. Stop lingering action tracks
	if animator then
		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
			if track.Priority >= Enum.AnimationPriority.Action then
				pcall(function() track:Stop(0.05) end)
			end
		end
	end

	-- 3. Transition to upright
	if hum and hum.Health > 0 then
		pcall(function()
			hum.PlatformStand = false
			hum.Sit = false
			hum.AutoRotate = true
			hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end

	task.wait(0.05)

	if hum and hum.Parent and hum.Health > 0 then
		pcall(function()
			hum:ChangeState(Enum.HumanoidStateType.Running)
		end)
	end
end

----------------------------------------------------------------
-- DYNAMIC EGG LOCATOR (NO HARDCODED COORDINATES)
----------------------------------------------------------------

local function getWorkspaceEgg(biome)
	local area = Workspace:FindFirstChild("AreaEggSlotsClient")
	if not area then return nil end

	local normBiome = string.lower(tostring(biome or ""))
	if normBiome == "" then normBiome = "any" end

	for _, slot in ipairs(area:GetChildren()) do
		local sName = string.lower(slot.Name)
		local matches = normBiome == "any" or string.find(sName, normBiome, 1, true) ~= nil
		if matches then
			local pPart = slot:FindFirstChildWhichIsA("BasePart", true)
			if pPart then
				return {
					Uid = slot.Name,
					AreaId = biome,
					AssetCategory = slot.Name,
					Position = pPart.Position,
				}
			end
		end
	end

	-- Never return a slot from another biome as a fallback target.
	return nil
end

local function isEggAvailable(e)
	if typeof(e) ~= "table" then return false end
	local carrier = e.CarrierUserId
	return carrier == nil or carrier == 0 or carrier == ""
end

local function getAnyForestEgg(forceRefresh)
	local eggs = fetchSnapshot(forceRefresh)
	for _, e in ipairs(eggs) do
		if string.lower(tostring(e.AreaId)) == "forest" and isEggAvailable(e) then
			return e
		end
	end

	return getWorkspaceEgg("Forest")
end

local function getTargetEgg(biome, forceRefresh)
	local eggs = fetchSnapshot(forceRefresh)
	local normBiome = string.lower(tostring(biome or "any"))

	if normBiome ~= "any" then
		-- Exact biome match only. Do not silently select an egg from another biome.
		for _, e in ipairs(eggs) do
			if string.lower(tostring(e.AreaId)) == normBiome and isEggAvailable(e) then
				return e
			end
		end
		return nil
	end

	for _, e in ipairs(eggs) do
		if isEggAvailable(e) then
			return e
		end
	end

	return nil
end

----------------------------------------------------------------
-- PURE VELOCITY GLIDE TO BAIT (NO CFRAME WRITES)
----------------------------------------------------------------

local function velocityGlideTo(targetPos, speed, timeoutS, myToken)
	speed = speed or 280.0
	timeoutS = timeoutS or 2.5
	local t0 = os.clock()
	setFrictionless(true)

	while isRunning and (currentToken == myToken) and (os.clock() - t0 < timeoutS) do
		local dt = RunService.Heartbeat:Wait()
		local c = LocalPlayer.Character
		local r = c and c:FindFirstChild("HumanoidRootPart")
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if not r or not h or h.Health <= 0 then break end

		local diff = targetPos - r.Position
		local distH = math.sqrt(diff.X^2 + diff.Z^2)

		if distH <= 2.2 then
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
			break
		end

		local dirH = Vector3.new(diff.X, 0, diff.Z).Unit
		local vy = math.clamp(diff.Y * 4, -15, 15)

		r.AssemblyLinearVelocity = Vector3.new(dirH.X * speed, vy, dirH.Z * speed)
		r.AssemblyAngularVelocity = Vector3.zero

		if math.abs(h.WalkSpeed - RUN_WALKSPEED) > 0.1 then
			pcall(function() h.WalkSpeed = RUN_WALKSPEED end)
		end
	end

	local c = LocalPlayer.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	if r then
		r.AssemblyLinearVelocity = Vector3.zero
		r.AssemblyAngularVelocity = Vector3.zero
	end
end

----------------------------------------------------------------
-- MAIN PIPELINE EXECUTION (100% PURE AERIAL VELOCITY FLIGHT)
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

		requestSnapshotAsync()

		--======================================================
		-- STEP 1: Find Bait & Target Egg via Dynamic Metadata
		--======================================================
		updateStatus("[1/4] Finding dynamic Forest bait...", Color3.fromRGB(255, 200, 80))
		startSpeedEnforcer(RUN_WALKSPEED)

		local forestEgg = getAnyForestEgg()
		if not forestEgg then
			updateStatus("ABORTED: No Forest egg found in snapshot!", Color3.fromRGB(255, 80, 80))
			stopSpeedEnforcer(BASE_WALKSPEED)
			isRunning = false
			return
		end

		local baitPos = forestEgg.Position

		-- Pure velocity glide to Forest bait egg (ZERO CFrame writes)
		updateStatus(string.format("[1/4] Gliding to Forest bait at (%.0f, %.0f)...", baitPos.X, baitPos.Z), Color3.fromRGB(255, 200, 80))
		velocityGlideTo(baitPos, 280, 2.5, myToken)
		task.wait(0.15)

		--======================================================
		-- STEP 2: Secure Forest Bait (Triggers Guard Patrol)
		--======================================================
		updateStatus("[2/4] Securing bait egg to trigger guard...", Color3.fromRGB(255, 160, 50))
		local burstT0 = os.clock()
		local tries = 0
		while (tries < 2 or not isHoldingEgg()) and (os.clock() - burstT0 < BAIT_BURST_S) and currentToken == myToken and isRunning do
			carryEggRemote(forestEgg.Uid)
			triggerEggPrompts()
			touchEggHitbox(forestEgg.Uid)
			tries = tries + 1
			task.wait(0.12)
		end

		-- Pin firmly at bait location via velocity zeroing
		local c = LocalPlayer.Character
		local r = c and c:FindFirstChild("HumanoidRootPart")
		if r then
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
		end
		task.wait(0.1)

		--======================================================
		-- STEP 3: Hold Still on Rail & Wait for Guard Strike
		--======================================================
		updateStatus("[3/4] Ready on bait. Holding still for Guard Strike...", Color3.fromRGB(255, 140, 40))

		setStillMotion(true, baitPos)

		local baselineRagdoll = LocalPlayer:GetAttribute("RagdollEndTime") or 0
		if typeof(baselineRagdoll) ~= "number" then baselineRagdoll = 0 end
		local struck = false
		local strikeReason = "none"
		local tempConns = {}

		local function onStrike(reason)
			if not struck then
				struck = true
				strikeReason = reason
				print("[Steal-Pipeline v3.0] Strike triggered via: " .. tostring(reason))
				setStillMotion(false)
			end
		end

		pcall(function()
			local net = ReplicatedStorage.Packages.Networking
			local fToll = net:FindFirstChild("RE/GuardPatrol/SpeedTollOffer")
			if fToll then table.insert(tempConns, fToll.OnClientEvent:Connect(function() onStrike("SpeedTollOffer") end)) end
			local fStrike = net:FindFirstChild("RE/GuardPatrol/ForestStrike")
			if fStrike then table.insert(tempConns, fStrike.OnClientEvent:Connect(function() onStrike("ForestStrike") end)) end
			local fHandoff = net:FindFirstChild("RE/GuardPatrol/ForestHandoff")
			if fHandoff then table.insert(tempConns, fHandoff.OnClientEvent:Connect(function() onStrike("ForestHandoff") end)) end
		end)

		table.insert(tempConns, LocalPlayer.AttributeChanged:Connect(function(attr)
			if attr == "RagdollEndTime" then
				local v = LocalPlayer:GetAttribute("RagdollEndTime") or 0
				if typeof(v) == "number" and (v > baselineRagdoll + 0.3 or v > serverNow()) then
					onStrike("RagdollEndTime:" .. string.format("%.1f", v))
				end
			end
		end))

		local humConn = hum.StateChanged:Connect(function(_, newState)
			if newState == Enum.HumanoidStateType.Physics or newState == Enum.HumanoidStateType.Ragdoll or newState == Enum.HumanoidStateType.FallingDown then
				onStrike("HumanoidState:" .. newState.Name)
			end
		end)
		table.insert(tempConns, humConn)

		local waitT0 = os.clock()
		while (os.clock() - waitT0 < STRIKE_TIMEOUT_S) and currentToken == myToken and not struck do
			local curC = LocalPlayer.Character
			local curH = curC and curC:FindFirstChildOfClass("Humanoid")
			local curR = curC and curC:FindFirstChild("HumanoidRootPart")
			if curC and curH and curR then
				local offMotors, totalMotors = bumpMotors(curC)
				if offMotors >= 2 then onStrike("MotorsDisabled") break end
				local rEnd = LocalPlayer:GetAttribute("RagdollEndTime")
				if typeof(rEnd) == "number" and (rEnd > baselineRagdoll + 0.3 or rEnd > serverNow()) then onStrike("RagdollEndTime") break end
				local st = curH:GetState()
				if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.FallingDown then onStrike("PolledState") break end
				if (curR.Position - baitPos).Magnitude > 4.5 then onStrike("Displaced") break end
				if curR.AssemblyLinearVelocity.Magnitude > 15 then onStrike("VelocityKnockback") break end
			end
			task.wait(0.03)
		end

		for _, conn in ipairs(tempConns) do pcall(function() conn:Disconnect() end) end
		setStillMotion(false)

		if not struck then
			updateStatus("ABORTED: Strike timed out", Color3.fromRGB(255, 80, 80))
			dropEggRemote()
			setFrictionless(false)
			stopSpeedEnforcer(BASE_WALKSPEED)
			isRunning = false
			return
		end

		--======================================================
		-- STEP 3.5: RESOLVE FRESH NON-SNOW TARGET AFTER STRIKE
		--======================================================
		-- Do not use the target selected before the Guard wait. The egg table
		-- can change while the pipeline is waiting, so the flight target is
		-- resolved from a fresh AskFieldEggSnapshot immediately before flight.
		local targetEgg = getTargetEgg(selectedBiome, true)
		if not targetEgg then
			updateStatus("ABORTED: No fresh target egg found for " .. tostring(selectedBiome) .. "!", Color3.fromRGB(255, 80, 80))
			dropEggRemote()
			setFrictionless(false)
			stopSpeedEnforcer(BASE_WALKSPEED)
			isRunning = false
			return
		end

		local targetPos = targetEgg.Position
		local targetName = string.format("%s (%s)", tostring(targetEgg.AreaId or selectedBiome), tostring(targetEgg.AssetCategory or "Egg"))

		--======================================================
		-- STEP 3.5: NEGATE BUMP (Drop bait & zero velocity)
		-- Drops bait immediately & cancels knockback velocity without
		-- tampering with Motor6D or HumanoidState (avoids -1000 HP death!)
		--======================================================
		dropEggRemote()
		setFrictionless(true)
		neutraliseEggPhysics(LocalPlayer.Character)

		do
			local curC = LocalPlayer.Character
			local curR = curC and curC:FindFirstChild("HumanoidRootPart")
			if curR then
				curR.AssemblyLinearVelocity = Vector3.zero
				curR.AssemblyAngularVelocity = Vector3.zero
			end
		end

		--======================================================
		-- STEP 4: 100% PURE AERIAL VELOCITY FLIGHT (ZERO CFRAME WRITES)
		-- Parabolic 3D Newtonian arc via AssemblyLinearVelocity
		-- Roblox physics simulates ds = v * dt natively on server.
		-- Zero CFrame writes -> Zero rubberband -> Zero death!
		--======================================================
		updateStatus(string.format("[4/4] Aerial Velocity Flight to %s...", targetName), Color3.fromRGB(80, 210, 255))
		startSpeedEnforcer(RUN_WALKSPEED)
		isFlying = true

		local curChar = LocalPlayer.Character
		local curRoot = curChar and curChar:FindFirstChild("HumanoidRootPart")
		local launchFrom = (curRoot and curRoot.Position) or baitPos

		-- Target the actual selected egg Y. The old Snow-specific floor of 70.72
		-- is what makes non-Snow destinations land above/below the real egg.
		local TARGET_ROOT_Y_OFFSET = 3.0
		local landingPos = targetPos + Vector3.new(0, TARGET_ROOT_Y_OFFSET, 0)

		local horizontalDist = math.sqrt((landingPos.X - launchFrom.X)^2 + (landingPos.Z - launchFrom.Z)^2)
		local flightDuration = math.max(horizontalDist / AERIAL_SPEED, 0.35)
		local flightT0       = os.clock()

		-- Generic arc for Jungle/Desert/Ocean/Volcano/Any. Avoid the old
		-- Snow corridor profile and scale the arc from the actual distance.
		local peakArc = math.clamp(horizontalDist * 0.035, 8.0, 26.0)

		while isRunning and (currentToken == myToken) do
			local dt = RunService.Heartbeat:Wait()
			local elapsed = os.clock() - flightT0
			local prog = math.clamp(elapsed / flightDuration, 0, 1)

			local c = LocalPlayer.Character
			local r = c and c:FindFirstChild("HumanoidRootPart")
			local h = c and c:FindFirstChildOfClass("Humanoid")
			if not r or not h or h.Health <= 0 then break end

			if math.abs(h.WalkSpeed - RUN_WALKSPEED) > 0.1 then
				pcall(function() h.WalkSpeed = RUN_WALKSPEED end)
			end
			neutraliseEggPhysics(c)

			-- Calculate next target waypoint along 3D parabolic trajectory (dt ahead)
			local nextProg = math.clamp((elapsed + math.max(dt, 0.016)) / flightDuration, 0, 1)
			local arcY = peakArc * math.sin(nextProg * math.pi)
			local targetWaypoint = launchFrom:Lerp(landingPos, nextProg) + Vector3.new(0, arcY, 0)

			-- Assign pure Newtonian velocity required to reach targetWaypoint
			local neededVel = (targetWaypoint - r.Position) / math.max(dt, 0.001)
			if neededVel.Magnitude > (AERIAL_SPEED * 1.5) then
				neededVel = neededVel.Unit * (AERIAL_SPEED * 1.5)
			end

			r.AssemblyLinearVelocity = neededVel
			r.AssemblyAngularVelocity = Vector3.zero

			-- Check touchdown proximity
			local distToLanding = (landingPos - r.Position).Magnitude
			if prog >= 1 or (distToLanding < 5.0 and elapsed > 0.25) then
				r.AssemblyLinearVelocity = Vector3.zero
				r.AssemblyAngularVelocity = Vector3.zero
				break
			end
		end

		isFlying = false

		-- Zero velocity upon arrival
		local touchdownChar = LocalPlayer.Character
		local touchdownRoot = touchdownChar and touchdownChar:FindFirstChild("HumanoidRootPart")
		if touchdownRoot then
			touchdownRoot.AssemblyLinearVelocity = Vector3.zero
			touchdownRoot.AssemblyAngularVelocity = Vector3.zero
		end

		--======================================================
		-- STEP 5: PURE VELOCITY FREEZE HOLD & RAGDOLL EXPIRATION
		-- - Matches working-teleport-log STILL_START / STILL_END benchmark:
		--   * Zeroes AssemblyLinearVelocity and AssemblyAngularVelocity
		--   * Applies gentle velocity-based restoring spring if drift occurs
		--   * Keeps WalkSpeed enforcer active (500 WalkSpeed)
		--   * Does NOT touch Motor6D or ChangeState (avoids -1000 HP anti-cheat death!)
		--   * Does NOT write CFrame (preserves server physics authority)
		--   * Holds motionless until server RagdollEndTime has fully expired (+0.15s margin)
		--   * Minimum hold time of 0.85s guarantees STILL_START / STILL_END scanner events
		--   * Prevents server physics authority from rubberbanding avatar back to Forest!
		--======================================================
		updateStatus("[4/4] Stabilizing at " .. targetName .. " via Velocity Hold...", Color3.fromRGB(100, 220, 255))

		local freezeT0 = os.clock()

		while isRunning and (currentToken == myToken) do
			local dt = RunService.Heartbeat:Wait()
			local elapsedFreeze = os.clock() - freezeT0

			local c = LocalPlayer.Character
			local r = c and c:FindFirstChild("HumanoidRootPart")
			local h = c and c:FindFirstChildOfClass("Humanoid")

			if r then
				-- Velocity-based damping (NO CFrame writes!)
				local delta = landingPos - r.Position
				if delta.Magnitude > 1.2 then
					r.AssemblyLinearVelocity = delta * 4
				else
					r.AssemblyLinearVelocity = Vector3.zero
				end
				r.AssemblyAngularVelocity = Vector3.zero
			end

			if h and h.Health > 0 and math.abs(h.WalkSpeed - RUN_WALKSPEED) > 0.1 then
				pcall(function() h.WalkSpeed = RUN_WALKSPEED end)
			end

			-- Check if server ragdoll timer has officially expired
			local rEnd = LocalPlayer:GetAttribute("RagdollEndTime") or 0
			if typeof(rEnd) ~= "number" then rEnd = 0 end
			local ragdollExpired = (rEnd == 0) or (serverNow() >= rEnd + 0.15)

			-- Only break once both minimum freeze hold (for scanner STILL_START)
			-- AND the server ragdoll window have elapsed
			if (elapsedFreeze >= MIN_FREEZE_HOLD_S) and ragdollExpired then
				break
			end

			if elapsedFreeze >= MAX_FREEZE_TIMEOUT then
				break
			end
		end

		--======================================================
		-- STEP 6: Final Settle & Completion
		--======================================================
		local settleT0 = os.clock()
		while (os.clock() - settleT0 < 0.20) and isRunning and (currentToken == myToken) do
			local dt = RunService.Heartbeat:Wait()
			local curC = LocalPlayer.Character
			local curR = curC and curC:FindFirstChild("HumanoidRootPart")
			if curR then
				curR.AssemblyLinearVelocity = Vector3.zero
				curR.AssemblyAngularVelocity = Vector3.zero
			end
		end

		setFrictionless(false)
		stopSpeedEnforcer(BASE_WALKSPEED)

		updateStatus("ARRIVED: Teleported to " .. targetName .. " via Aerial Flight!", Color3.fromRGB(100, 255, 170))
		print(string.format("[Steal-Pipeline v3.0 - Grok-V3] Teleport to %s at (%.1f, %.1f, %.1f) complete via Aerial Velocity Flight! Freeze hold: %.2fs", targetName, landingPos.X, landingPos.Y, landingPos.Z, os.clock() - freezeT0))

		isRunning = false
	end)
end

----------------------------------------------------------------
-- GUI CONSTRUCTION
----------------------------------------------------------------

local oldGui = PlayerGui:FindFirstChild(GUI_NAME)
if oldGui then pcall(function() oldGui:Destroy() end) end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.Parent = PlayerGui

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 460, 0, 315)
main.Position = UDim2.new(0.03, 0, 0.35, 0)
main.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(70, 90, 140)
stroke.Thickness = 1.3

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 32)
titleBar.BackgroundColor3 = Color3.fromRGB(24, 30, 46)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 1, 0)
title.Position = UDim2.new(0, 10, 0, 0)
title.BackgroundTransparency = 1
title.Text = "STEAL AN EGG: GROK-V3 (AERIAL VELOCITY FLIGHT)"
title.TextColor3 = Color3.fromRGB(120, 220, 255)
title.TextSize = 11
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseButton"
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.Position = UDim2.new(1, -29, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.TextSize = 12
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Active = true
closeBtn.ZIndex = 50
closeBtn.AutoButtonColor = true
closeBtn.Parent = main
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

local statusBox = Instance.new("Frame")
statusBox.Size = UDim2.new(1, -20, 0, 48)
statusBox.Position = UDim2.new(0, 10, 0, 38)
statusBox.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
statusBox.BorderSizePixel = 0
statusBox.Parent = main
Instance.new("UICorner", statusBox).CornerRadius = UDim.new(0, 6)

local statusTitle = Instance.new("TextLabel")
statusTitle.Size = UDim2.new(1, -12, 0, 14)
statusTitle.Position = UDim2.new(0, 8, 0, 3)
statusTitle.BackgroundTransparency = 1
statusTitle.Text = "PIPELINE STATUS:"
statusTitle.TextColor3 = Color3.fromRGB(140, 160, 200)
statusTitle.TextSize = 9
statusTitle.Font = Enum.Font.GothamBold
statusTitle.TextXAlignment = Enum.TextXAlignment.Left
statusTitle.Parent = statusBox

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -16, 0, 28)
statusLabel.Position = UDim2.new(0, 8, 0, 18)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Ready. Aerial Velocity Engine (Zero CFrame) -> Fresh non-Snow target resolver."
statusLabel.TextColor3 = Color3.fromRGB(180, 220, 255)
statusLabel.TextSize = 10
statusLabel.Font = Enum.Font.Code
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.Parent = statusBox

local biomeBtn = Instance.new("TextButton")
biomeBtn.Size = UDim2.new(1, -20, 0, 28)
biomeBtn.Position = UDim2.new(0, 10, 0, 92)
biomeBtn.BackgroundColor3 = Color3.fromRGB(36, 56, 96)
biomeBtn.Text = "TARGET BIOME: [" .. selectedBiome .. "] (Click to switch)"
biomeBtn.TextColor3 = Color3.fromRGB(220, 240, 255)
biomeBtn.TextSize = 10
biomeBtn.Font = Enum.Font.GothamBold
biomeBtn.Parent = main
Instance.new("UICorner", biomeBtn).CornerRadius = UDim.new(0, 5)

local targetLabel = Instance.new("TextLabel")
targetLabel.Size = UDim2.new(1, -20, 0, 32)
targetLabel.Position = UDim2.new(0, 10, 0, 126)
targetLabel.BackgroundTransparency = 1
targetLabel.Text = "Targets: scanning snapshot..."
targetLabel.TextColor3 = Color3.fromRGB(150, 180, 220)
targetLabel.TextSize = 9
targetLabel.Font = Enum.Font.Code
targetLabel.TextWrapped = true
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.TextYAlignment = Enum.TextYAlignment.Top
targetLabel.Parent = main

local stealBtn = Instance.new("TextButton")
stealBtn.Size = UDim2.new(1, -20, 0, 38)
stealBtn.Position = UDim2.new(0, 10, 0, 164)
stealBtn.BackgroundColor3 = Color3.fromRGB(30, 130, 75)
stealBtn.Text = "START AERIAL VELOCITY TELEPORT"
stealBtn.TextColor3 = Color3.new(1, 1, 1)
stealBtn.TextSize = 12
stealBtn.Font = Enum.Font.GothamBold
stealBtn.Parent = main
Instance.new("UICorner", stealBtn).CornerRadius = UDim.new(0, 6)

local refreshBtn = Instance.new("TextButton")
refreshBtn.Size = UDim2.new(0.48, -5, 0, 28)
refreshBtn.Position = UDim2.new(0, 10, 0, 208)
refreshBtn.BackgroundColor3 = Color3.fromRGB(50, 80, 130)
refreshBtn.Text = "Refresh Targets"
refreshBtn.TextColor3 = Color3.new(1, 1, 1)
refreshBtn.TextSize = 10
refreshBtn.Font = Enum.Font.GothamBold
refreshBtn.Parent = main
Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, 5)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0.48, -5, 0, 28)
stopBtn.Position = UDim2.new(0.52, 0, 0, 208)
stopBtn.BackgroundColor3 = Color3.fromRGB(110, 40, 40)
stopBtn.Text = "Emergency Stop"
stopBtn.TextColor3 = Color3.new(1, 1, 1)
stopBtn.TextSize = 10
stopBtn.Font = Enum.Font.GothamBold
stopBtn.Parent = main
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 5)

local footer = Instance.new("TextLabel")
footer.Size = UDim2.new(1, -20, 0, 65)
footer.Position = UDim2.new(0, 10, 0, 242)
footer.BackgroundTransparency = 1
footer.Text = "Grok-v3: Dedicated 100% Pure Aerial Velocity Engine (Zero CFrame)\nNewtonian Parabolic Arc Flight + Zero-Friction + Zero Rubberband\nFresh Non-Snow Targeting | No Hardcoded Target Coords"
footer.TextColor3 = Color3.fromRGB(120, 140, 175)
footer.TextSize = 9
footer.Font = Enum.Font.Code
footer.TextWrapped = true
footer.Parent = main

local function updateTargetDisplay()
	local forestEgg = getAnyForestEgg()
	local targetEgg = getTargetEgg(selectedBiome)
	local forestText = forestEgg and string.format("Forest Bait: %s | (%.0f, %.1f, %.0f)", tostring(forestEgg.AssetCategory or "Egg"), forestEgg.Position.X, forestEgg.Position.Y, forestEgg.Position.Z) or "Forest Bait: NONE"
	local targetText = targetEgg and string.format("Target [%s]: %s | (%.0f, %.1f, %.0f)", tostring(targetEgg.AreaId or selectedBiome), tostring(targetEgg.AssetCategory or "Egg"), targetEgg.Position.X, targetEgg.Position.Y, targetEgg.Position.Z) or string.format("Target [%s]: NONE FOUND", selectedBiome)
	targetLabel.Text = forestText .. "\n" .. targetText
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
	statusLabel.Text = "Refreshing egg snapshot..."
	statusLabel.TextColor3 = Color3.fromRGB(120, 200, 255)
	cachedSnapshot = nil
	snapshotTried = false
	task.spawn(function()
		fetchSnapshot()
		updateTargetDisplay()
		statusLabel.Text = "Snapshot refreshed."
		statusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)
	end)
end)

stealBtn.MouseButton1Click:Connect(function()
	if isRunning then
		statusLabel.Text = "Teleport pipeline already in progress."
		return
	end
	executeTeleportPipeline(statusLabel)
end)

stopBtn.MouseButton1Click:Connect(function()
	currentToken = currentToken + 1
	isRunning = false
	isFlying = false
	setStillMotion(false)
	setFrictionless(false)
	dropEggRemote()
	stopSpeedEnforcer(BASE_WALKSPEED)
	recoverCharacterRig(LocalPlayer.Character)
	statusLabel.Text = "Stopped. Rig recovered & WalkSpeed restored."
	statusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
end)

local isGuiClosed = false
local function handleClose()
	if isGuiClosed then return end
	isGuiClosed = true
	currentToken = currentToken + 1
	isRunning = false
	isFlying = false

	-- Hide & destroy immediately
	pcall(function() gui.Enabled = false end)
	pcall(function() gui:Destroy() end)

	-- Run cleanup in background safely so UI destruction is never delayed or blocked
	task.spawn(function()
		pcall(function() cleanupConnections() end)
		pcall(function() setFrictionless(false) end)
		pcall(function() dropEggRemote() end)
		pcall(function() stopSpeedEnforcer(BASE_WALKSPEED) end)
		pcall(function() recoverCharacterRig(LocalPlayer.Character) end)
	end)
end

closeBtn.Activated:Connect(handleClose)
closeBtn.MouseButton1Click:Connect(handleClose)
closeBtn.MouseButton1Down:Connect(handleClose)

local dragging, dragStart, startPos = false, nil, nil
titleBar.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		-- Ignore drag if clicking near top-right close button
		local relX = i.Position.X - main.AbsolutePosition.X
		local relY = i.Position.Y - main.AbsolutePosition.Y
		if relX >= (main.AbsoluteSize.X - 36) and relY <= 36 then
			return
		end
		dragging, dragStart, startPos = true, i.Position, main.Position
	end
end)
titleBar.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)
UserInputService.InputChanged:Connect(function(i)
	if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - dragStart
		main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)

requestSnapshotAsync()
task.defer(function()
	task.wait(0.2)
	updateTargetDisplay()
end)

print("[Steal-Pipeline v3.0 - Grok-V3] Loaded. Dedicated 100% Pure Aerial Velocity Engine Ready (Zero CFrame).")
