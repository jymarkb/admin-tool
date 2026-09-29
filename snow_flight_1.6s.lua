--[[
=====================================================================
 SNOW / BIOME FLIGHT — FIXED 1.6 SECOND STRAIGHT FLIGHT  v1.0
 -------------------------------------------------------------------
 NEW separate script. It does NOT modify or replace
 "grok-v3-target-fix.lua" or "test-ragdoll-good-recovery.lua".

 WHAT IT DOES
   When you get hit (or when you press FLY NOW) it:
     1. forces the character back into Running, exactly the way
        test-ragdoll-good-recovery.lua does
        (motors re-enabled, PlatformStand/Sit cleared, GettingUp then
         Running), so a ragdoll event does not stop it,
     2. flies in a straight line toward the selected biome egg
        (SNOW by default) using ONLY AssemblyLinearVelocity,
     3. keeps flying for exactly 1.6 seconds total, then stops.

   There is NO bait egg, NO guard wait, NO parabolic arc and NO
   post-landing freeze hold. Straight line, 1.6 s.

 SPEED
   1.6 s is the total flight duration, so the speed is derived from the
   distance:  speed = distance / 1.6.
   MAX_SPEED (default 3000 studs/s) is a safety clamp. If the target is
   far enough that the required speed would exceed it, the status line
   says so and the flight will stop short instead of exceeding the cap.

 WHAT IT CHANGES WHILE RUNNING (all restored afterwards)
   * HumanoidRootPart.AssemblyLinearVelocity / AssemblyAngularVelocity
   * Humanoid state forced to Running while flying
   * Motor6D.Enabled re-enabled if the game disables them
   * Humanoid.WalkSpeed forced to RUN_WALKSPEED while flying
   * character part CustomPhysicalProperties set frictionless while
     flying, then restored

 WHAT IT NEVER DOES
   * no CFrame writes, no Position writes, no anchoring, no teleport
   * no Motor6D or Humanoid state changes outside of a flight
   * no egg carry / drop / strike remote calls
   * the only remote it ever touches is the read-only egg snapshot
     query, and only if the workspace slot search finds no target

 EXPECTATION SETTING
   Writing velocity is a client request, not server permission. If the
   server enforces its own position/speed authority you can still be
   corrected mid-flight; this script cannot override that.

 USAGE
   1) Execute this file.
   2) Pick the biome with the target button (starts on SNOW).
   3) Get hit while carrying an egg -> flight starts automatically.
      Or press FLY NOW at any time.
   4) The status line reports distance, speed, duration and the
      remaining gap when the flight ends.
=====================================================================
]]

--==================================================
-- SERVICES
--==================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

do
	local waited = 0

	while not LocalPlayer and waited < 10 do

		task.wait(0.25)
		waited = waited + 0.25
		LocalPlayer = Players.LocalPlayer
	end
end

if not LocalPlayer then

	warn("[Snow Flight 1.6s] LocalPlayer not available; aborting.")

	return
end

--==================================================
-- CONFIG
--==================================================

local CONFIG = {
	FLIGHT_DURATION = 1.6,   -- total flight time in seconds
	RUN_WALKSPEED = 500.0,   -- forced while flying (same as grok-v3)
	MAX_SPEED = 3000.0,      -- velocity clamp; distance/1.6 above this stops short
	TARGET_Y_OFFSET = 3.0,   -- land 3 studs above the egg part (same as grok-v3)
	ARRIVE_TOLERANCE = 5.0,  -- stop early when this close after 0.25s
	MIN_ARRIVE_ELAPSED = 0.25,
	MOTOR_RECHECK = 0.10,    -- seconds between Motor6D/state re-assertions
	STATE_RETRY = 0.10,      -- seconds between ChangeState(Running) retries
	AUTO_ON_HIT = true,      -- fly automatically when a hit/ragdoll is seen
	HOLD_ONLY = true,        -- auto-flight only while holding an egg
	HIT_COOLDOWN = 2.0,      -- minimum seconds between automatic flights
	ZERO_FRICTION = true,    -- frictionless while flying (grok-v3 behaviour)
}

local TARGET_BIOMES = {
	"Snow", "Jungle", "Desert", "Ocean", "Volcano", "Abyss Ocean",
	"Prehistoric", "Cosmic", "Cherry Blossom", "Titan", "Light Dark",
}

local selectedBiomeIndex = 1                 -- SNOW first
local selectedBiome = TARGET_BIOMES[selectedBiomeIndex]

--==================================================
-- STATE
--==================================================

local connections = {}
local scriptAlive = true
local isFlying = false
local flightToken = 0
local lastAutoHit = 0
local autoOnHit = CONFIG.AUTO_ON_HIT
local savedWalkSpeed = nil
local originalPhysicalProperties = {}
local zeroFriction = PhysicalProperties.new(0.7, 0, 0, 100, 100)
local lastReport = nil
local cachedSnapshot = nil
local lastMotorCheck = 0
local lastStateAssert = 0
local lastKnownHealth = nil

local gui, statusLabel, statsLabel, biomeButton, autoButton, flyButton

--==================================================
-- SMALL HELPERS
--==================================================

local function safe(fn, ...)

	local ok, a, b, c = pcall(fn, ...)

	if ok then
		return true, a, b, c
	end

	return false, nil
end

local function connect(signal, callback)

	if not signal then
		return nil
	end

	local ok, conn = safe(function()
		return signal:Connect(callback)
	end)

	if ok and conn then
		connections[#connections + 1] = conn
	end

	return conn
end

local function disconnectAll()

	for _, conn in ipairs(connections) do

		safe(function()
			conn:Disconnect()
		end)
	end

	connections = {}
end

local function getCharacter()
	return LocalPlayer.Character
end

local function getRoot()
	local character = getCharacter()

	return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local character = getCharacter()

	return character and character:FindFirstChildOfClass("Humanoid")
end

local function setStatus(text)

	if statusLabel then
		statusLabel.Text = text
	end
end

local function isHoldingEgg()

	local character = getCharacter()

	if not character then
		return false
	end

	local ok, children = safe(function()
		return character:GetChildren()
	end)

	if ok and type(children) == "table" then

		for _, child in ipairs(children) do

			local name = string.lower(tostring(child.Name))

			local okIsTool, isTool = safe(function()
				return child:IsA("Tool")
			end)

			if okIsTool and isTool then
				return true
			end

			if string.find(name, "egg", 1, true) then
				return true
			end
		end
	end

	local carrying = LocalPlayer:GetAttribute("IsCarrying")

	return carrying == true
end

--==================================================
-- TARGET RESOLUTION (READ-ONLY)
--==================================================

-- 1) Preferred: the client-rendered workspace slots. No remote call.
local function getWorkspaceEgg(biome)

	local okArea, area = safe(function()
		return Workspace:FindFirstChild("AreaEggSlotsClient")
	end)

	if not okArea or not area then
		return nil
	end

	local normBiome = string.lower(tostring(biome or ""))

	local okChildren, slots = safe(function()
		return area:GetChildren()
	end)

	if not okChildren or type(slots) ~= "table" then
		return nil
	end

	for _, slot in ipairs(slots) do

		local slotName = string.lower(tostring(slot.Name))

		if string.find(slotName, normBiome, 1, true) then

			local okPart, part = safe(function()
				return slot:FindFirstChildWhichIsA("BasePart", true)
			end)

			if okPart and part then

				return {
					Uid = tostring(slot.Name),
					AreaId = biome,
					AssetCategory = tostring(slot.Name),
					Position = part.Position,
					Source = "workspace slot",
				}
			end
		end
	end

	return nil
end

-- Accepts a real Vector3 and also a plain {X, Y, Z} table, because a
-- server snapshot may serialise vectors.
local function asVector3(value)

	if typeof(value) == "Vector3" then
		return value
	end

	if type(value) == "table"
		and type(value.X) == "number"
		and type(value.Y) == "number"
		and type(value.Z) == "number" then

		return Vector3.new(value.X, value.Y, value.Z)
	end

	return nil
end

-- Accepts a real CFrame and a serialised CFrame-like table.
local function asCFramePosition(value)

	if typeof(value) == "CFrame" then
		return value.Position
	end

	if type(value) == "table" and value.Position ~= nil then
		return asVector3(value.Position)
	end

	return nil
end

local function extractTargetPosition(record)

	if type(record) ~= "table" then
		return nil
	end

	-- Same field preference as grok-v3-target-fix.lua
	local bounds = asCFramePosition(record.BoundsCFrame)

	if bounds then
		return bounds
	end

	local bottom = asCFramePosition(record.BottomCFrame)

	if bottom then
		return bottom
	end

	return asVector3(
		record.Position or record.Pos or record.pos or record.P
	)
end

local function parseSnapshotEggs(raw)

	local records = {}

	if type(raw) ~= "table" then
		return records
	end

	local source = raw.Records

	if type(source) ~= "table" then
		source = raw.records
	end

	if type(source) ~= "table" then
		return records
	end

	for _, rec in pairs(source) do

		if type(rec) == "table" then

			local pos = extractTargetPosition(rec)
			local uid = rec.Uid or rec.uid or rec.UID or rec.Id or rec.id
			local area = rec.AreaId or rec.areaId or rec.Area or rec.Biome or rec.biome
			local category = rec.AssetCategory or rec.assetCategory or rec.Category

			if uid and pos then

				records[#records + 1] = {
					Uid = tostring(uid),
					AreaId = tostring(area or "Unknown"),
					AssetCategory = tostring(category or "Egg"),
					Position = pos,
					CarrierUserId = rec.CarrierUserId or rec.carrierUserId,
					Source = "server snapshot",
				}
			end
		end
	end

	return records
end

-- 2) Fallback: read-only snapshot query. Only used when the workspace
--    slot search finds nothing.
local function fetchSnapshot(forceRefresh)

	if not forceRefresh and cachedSnapshot and #cachedSnapshot > 0 then
		return cachedSnapshot
	end

	local okRemote, remote = safe(function()
		return ReplicatedStorage.Packages.Networking
			["RF/EggWorld/AskFieldEggSnapshot"]
	end)

	if not okRemote or not remote then
		return {}
	end

	local okInvoke, result = safe(function()
		return remote:InvokeServer()
	end)

	if okInvoke and type(result) == "table" then

		cachedSnapshot = parseSnapshotEggs(result)

		return cachedSnapshot
	end

	return {}
end

local function getTargetEgg(biome)

	local workspaceEgg = getWorkspaceEgg(biome)

	if workspaceEgg then
		return workspaceEgg
	end

	local eggs = fetchSnapshot(false)
	local normBiome = string.lower(tostring(biome or ""))

	for _, egg in ipairs(eggs) do

		if string.lower(tostring(egg.AreaId)) == normBiome then

			local carrier = egg.CarrierUserId

			if carrier == nil or carrier == 0 or carrier == "" then
				return egg
			end
		end
	end

	return nil
end

--==================================================
-- FORCED RUNNING (same approach as test-ragdoll-good-recovery.lua)
--==================================================

local function enableMotors(character)

	local count = 0

	local ok, descendants = safe(function()
		return character:GetDescendants()
	end)

	if not ok or type(descendants) ~= "table" then
		return 0
	end

	for _, descendant in ipairs(descendants) do

		local okMotor, isMotor = safe(function()
			return descendant:IsA("Motor6D")
		end)

		if okMotor and isMotor then

			local okEnabled, enabled = safe(function()
				return descendant.Enabled
			end)

			if okEnabled and not enabled then

				safe(function()
					descendant.Enabled = true
				end)

				count = count + 1
			end
		end
	end

	return count
end

-- One-shot: motors on, states cleared, GettingUp -> Running.
local function forceRunOnce()

	local humanoid = getHumanoid()
	local character = getCharacter()

	if not humanoid or not character then
		return
	end

	enableMotors(character)

	safe(function()
		humanoid.PlatformStand = false
	end)

	safe(function()
		humanoid.Sit = false
	end)

	safe(function()
		humanoid.AutoRotate = true
	end)

	safe(function()
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end)

	task.wait()

	if not scriptAlive then
		return
	end

	local ok, state = safe(function()
		return humanoid:GetState()
	end)

	if ok and state == Enum.HumanoidStateType.Physics then
		safe(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)

		task.wait()
	end

	safe(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
	end)
end

-- Called every frame of the flight: keeps re-asserting Running so a
-- ragdoll event cannot take the flight over.
local function keepRunning(humanoid)

	local now = os.clock()

	if now - lastMotorCheck >= CONFIG.MOTOR_RECHECK then

		lastMotorCheck = now

		local character = getCharacter()

		if character then
			enableMotors(character)
		end
	end

	if now - lastStateAssert < CONFIG.STATE_RETRY then
		return
	end

	local okState, state = safe(function()
		return humanoid:GetState()
	end)

	if not okState then
		return
	end

	local ragdollStates =
		state == Enum.HumanoidStateType.Physics
		or state == Enum.HumanoidStateType.FallingDown
		or state == Enum.HumanoidStateType.GettingUp
		or state == Enum.HumanoidStateType.Ragdoll

	if ragdollStates then

		lastStateAssert = now

		safe(function()
			humanoid.PlatformStand = false
		end)

		safe(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)

		safe(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end)
	end
end

--==================================================
-- WALKSPEED + FRICTION
--==================================================

local function applyFrictionless(enable)

	if not CONFIG.ZERO_FRICTION then
		return
	end

	local character = getCharacter()

	if not character then
		return
	end

	local ok, descendants = safe(function()
		return character:GetDescendants()
	end)

	if not ok or type(descendants) ~= "table" then
		return
	end

	for _, descendant in ipairs(descendants) do

		local okPart, isPart = safe(function()
			return descendant:IsA("BasePart")
		end)

		if okPart and isPart then

			if enable then

				if originalPhysicalProperties[descendant] == nil then

					originalPhysicalProperties[descendant] =
						descendant.CustomPhysicalProperties
				end

				safe(function()
					descendant.CustomPhysicalProperties = zeroFriction
				end)

			else

				local original = originalPhysicalProperties[descendant]

				safe(function()
					descendant.CustomPhysicalProperties = original
				end)

				originalPhysicalProperties[descendant] = nil
			end
		end
	end
end

local function enforceWalkSpeed()

	local humanoid = getHumanoid()

	if not humanoid then
		return
	end

	if savedWalkSpeed == nil then

		local ok, value = safe(function()
			return humanoid.WalkSpeed
		end)

		if ok then
			savedWalkSpeed = value
		end
	end

	safe(function()
		humanoid.WalkSpeed = CONFIG.RUN_WALKSPEED
	end)
end

local function restoreWalkSpeed()

	if savedWalkSpeed == nil then
		return
	end

	local humanoid = getHumanoid()

	if humanoid then

		safe(function()
			humanoid.WalkSpeed = savedWalkSpeed
		end)
	end

	savedWalkSpeed = nil
end

--==================================================
-- FLIGHT
--==================================================

local activeFlight = nil

local function report(text)

	lastReport = text

	setStatus(text)

	if statsLabel then
		statsLabel.Text = text
	end
end

local function endFlight(reason)

	local flight = activeFlight

	if not flight then
		return
	end

	activeFlight = nil
	isFlying = false

	local root = getRoot()

	local travelled = 0
	local remaining = 0

	if root then

		travelled = (root.Position - flight.origin).Magnitude
		remaining = (flight.target - root.Position).Magnitude

		if reason == "arrived" then

			safe(function()
				root.AssemblyLinearVelocity = Vector3.zero
			end)

			safe(function()
				root.AssemblyAngularVelocity = Vector3.zero
			end)
		end
	end

	restoreWalkSpeed()
	applyFrictionless(false)

	local elapsed = os.clock() - flight.t0
	local averageSpeed = elapsed > 0 and (travelled / elapsed) or 0

	report(string.format(
		"%s | flew %.0f studs in %.2fs (avg %.0f studs/s) | gap to %s: %.0f studs",
		reason == "arrived" and "ARRIVED" or "TIME UP (1.6s)",
		travelled,
		elapsed,
		averageSpeed,
		tostring(selectedBiome),
		remaining
	))
end

local function startFlight(reason)

	if isFlying then
		return false
	end

	local character = getCharacter()
	local root = getRoot()
	local humanoid = getHumanoid()

	if not character or not root or not humanoid then

		report("No living character/humanoid.")

		return false
	end

	local okHealth, health = safe(function()
		return humanoid.Health
	end)

	if okHealth and health <= 0 then

		report("Character is dead; not flying.")

		return false
	end

	local okAnchored, anchored = safe(function()
		return root.Anchored
	end)

	if okAnchored and anchored then

		report("HumanoidRootPart is anchored; not flying.")

		return false
	end

	local target = getTargetEgg(selectedBiome)

	if not target then

		report(
			"No " .. tostring(selectedBiome)
				.. " egg target found (workspace slots and snapshot empty)."
		)

		return false
	end

	local targetPosition =
		target.Position + Vector3.new(0, CONFIG.TARGET_Y_OFFSET, 0)

	local distance = (targetPosition - root.Position).Magnitude
	local requiredSpeed = distance / CONFIG.FLIGHT_DURATION
	local capped = requiredSpeed > CONFIG.MAX_SPEED

	if capped then

		report(string.format(
			"Target %.0f studs away needs %.0f studs/s; capped at %.0f "
				.. "(will stop short).",
			distance,
			requiredSpeed,
			CONFIG.MAX_SPEED
		))
	end

	isFlying = true
	flightToken = flightToken + 1

	activeFlight = {
		token = flightToken,
		target = targetPosition,
		origin = root.Position,
		t0 = os.clock(),
		distance = distance,
		requiredSpeed = requiredSpeed,
		capped = capped,
		source = target.Source,
		reason = reason,
	}

	applyFrictionless(true)
	enforceWalkSpeed()

	task.spawn(forceRunOnce)

	report(string.format(
		"FLYING to %s (%s) | %.0f studs | %.0f studs/s | %.1fs",
		tostring(selectedBiome),
		tostring(target.Source),
		distance,
		math.min(requiredSpeed, CONFIG.MAX_SPEED),
		CONFIG.FLIGHT_DURATION
	))

	return true
end

--==================================================
-- FLIGHT LOOP
--==================================================

connect(RunService.Heartbeat, function(dt)

	if not scriptAlive or not isFlying or not activeFlight then
		return
	end

	local flight = activeFlight
	local root = getRoot()
	local humanoid = getHumanoid()

	if not root or not humanoid then

		endFlight("character lost")

		return
	end

	local okHealth, health = safe(function()
		return humanoid.Health
	end)

	if okHealth and health <= 0 then

		endFlight("died")

		return
	end

	keepRunning(humanoid)
	enforceWalkSpeed()

	local elapsed = os.clock() - flight.t0
	local remainingTime = math.max(CONFIG.FLIGHT_DURATION - elapsed, 0.001)
	local delta = flight.target - root.Position

	-- Straight line, no arc: velocity = remaining distance / remaining time.
	local desired = delta / remainingTime

	if desired.Magnitude > CONFIG.MAX_SPEED then
		desired = desired.Unit * CONFIG.MAX_SPEED
	end

	safe(function()
		root.AssemblyLinearVelocity = desired
	end)

	safe(function()
		root.AssemblyAngularVelocity = Vector3.zero
	end)

	local distanceLeft = delta.Magnitude

	if distanceLeft < CONFIG.ARRIVE_TOLERANCE
		and elapsed > CONFIG.MIN_ARRIVE_ELAPSED then

		endFlight("arrived")

		return
	end

	if elapsed >= CONFIG.FLIGHT_DURATION then
		endFlight("time")
	end
end)

--==================================================
-- HIT DETECTION (auto flight)
--==================================================

local function shouldAutoFly()

	if not autoOnHit or isFlying or not scriptAlive then
		return false
	end

	if os.clock() - lastAutoHit < CONFIG.HIT_COOLDOWN then
		return false
	end

	if CONFIG.HOLD_ONLY and not isHoldingEgg() then
		return false
	end

	return true
end

local function autoFly(reason)

	if not shouldAutoFly() then
		return
	end

	lastAutoHit = os.clock()

	startFlight(reason)
end

local function bindCharacterWatch(character)

	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if not humanoid then
		return
	end

	-- HealthChanged fires AFTER the property changed, so the drop is
	-- measured against the health value remembered from the last event.
	local okHealth, initialHealth = safe(function()
		return humanoid.Health
	end)

	lastKnownHealth = okHealth and initialHealth or nil

	connect(humanoid.HealthChanged, function(newHealth)

		if isFlying then
			return
		end

		local previous = lastKnownHealth
		lastKnownHealth = newHealth

		if typeof(previous) == "number" and typeof(newHealth) == "number"
			and newHealth < previous then

			local drop = previous - newHealth

			if drop >= 1 then
				autoFly(string.format("hit: health -%.0f", drop))
			end
		end
	end)

	connect(humanoid.StateChanged, function(_, newState)

		if isFlying then
			return
		end

		if newState == Enum.HumanoidStateType.Physics
			or newState == Enum.HumanoidStateType.FallingDown then

			autoFly("hit: " .. tostring(newState))
		end
	end)

	connect(humanoid.Changed, function(property)

		if property == "PlatformStand" and not isFlying then

			local okStand, standing = safe(function()
				return humanoid.PlatformStand
			end)

			if okStand and standing then
				autoFly("hit: PlatformStand")
			end
		end
	end)
end

-- RagdollEndTime is the same server-time attribute the recovery script uses.
connect(LocalPlayer.AttributeChanged, function(name)

	if name == "RagdollEndTime" and not isFlying then

		local okEnd, ragdollEnd = safe(function()
			return LocalPlayer:GetAttribute("RagdollEndTime")
		end)

		local okNow, now = safe(function()
			return Workspace:GetServerTimeNow()
		end)

		if okEnd and okNow and typeof(ragdollEnd) == "number"
			and ragdollEnd > now then

			autoFly("hit: ragdoll")
		end
	end
end)

connect(LocalPlayer.CharacterAdded, function(character)

	safe(function()
		applyFrictionless(false)
	end)

	restoreWalkSpeed()

	isFlying = false
	activeFlight = nil

	bindCharacterWatch(character)
end)

--==================================================
-- GUI
--==================================================

local function makeButton(parent, text, x, y, width, height)

	local button = Instance.new("TextButton")

	button.Name = "Btn_" .. string.gsub(text, "%W", "")
	button.Text = text
	button.Size = UDim2.new(0, width, 0, height)
	button.Position = UDim2.new(0, x, 0, y)
	button.BackgroundColor3 = Color3.fromRGB(38, 48, 66)
	button.TextColor3 = Color3.fromRGB(228, 236, 248)
	button.TextSize = 13
	button.Font = Enum.Font.SourceSans
	button.Parent = parent

	return button
end

local function refreshBiomeButton()

	if biomeButton then

		biomeButton.Text =
			"TARGET BIOME: [" .. tostring(selectedBiome) .. "]  (click to switch)"
	end
end

local function refreshAutoButton()

	if autoButton then

		autoButton.Text = "Auto on hit: " .. (autoOnHit and "ON" or "OFF")
		autoButton.BackgroundColor3 = autoOnHit
			and Color3.fromRGB(40, 84, 56)
			or Color3.fromRGB(38, 48, 66)
	end
end

local function buildGui()

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "SnowFlight16"
	gui.ResetOnSpawn = false
	gui.Parent = playerGui or LocalPlayer:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Main"
	frame.Size = UDim2.new(0, 430, 0, 190)
	frame.Position = UDim2.new(0, 40, 0, 120)
	frame.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local title = Instance.new("TextLabel")
	title.Text = "Straight Flight  1.6s  (force Running, no ragdoll hold)"
	title.Size = UDim2.new(1, -12, 0, 22)
	title.Position = UDim2.new(0, 6, 0, 4)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(210, 230, 250)
	title.TextSize = 13
	title.Font = Enum.Font.SourceSansBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = frame

	biomeButton = makeButton(frame, "TARGET BIOME: [Snow]", 6, 30, 300, 26)
	flyButton = makeButton(frame, "FLY NOW (1.6s)", 312, 30, 112, 26)
	flyButton.BackgroundColor3 = Color3.fromRGB(32, 74, 116)

	autoButton = makeButton(frame, "Auto on hit: ON", 6, 60, 150, 24)
	local stopButton = makeButton(frame, "STOP", 162, 60, 80, 24)
	local closeButton = makeButton(frame, "CLOSE", 248, 60, 80, 24)
	closeButton.BackgroundColor3 = Color3.fromRGB(96, 40, 44)

	statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.Text = "Waiting for a hit (or press FLY NOW)."
	statusLabel.Size = UDim2.new(1, -12, 0, 44)
	statusLabel.Position = UDim2.new(0, 6, 0, 90)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.fromRGB(150, 210, 170)
	statusLabel.TextSize = 12
	statusLabel.Font = Enum.Font.SourceSans
	statusLabel.TextWrapped = true
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextYAlignment = Enum.TextYAlignment.Top
	statusLabel.Parent = frame

	statsLabel = Instance.new("TextLabel")
	statsLabel.Name = "Stats"
	statsLabel.Text = ""
	statsLabel.Size = UDim2.new(1, -12, 0, 40)
	statsLabel.Position = UDim2.new(0, 6, 0, 138)
	statsLabel.BackgroundTransparency = 1
	statsLabel.TextColor3 = Color3.fromRGB(170, 180, 195)
	statsLabel.TextSize = 11
	statsLabel.Font = Enum.Font.Code
	statsLabel.TextWrapped = true
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	statsLabel.TextYAlignment = Enum.TextYAlignment.Top
	statsLabel.Parent = frame

	-- dragging
	local dragging = false
	local dragStart, startPos

	connect(frame.InputBegan, function(input)

		if input and input.UserInputType == Enum.UserInputType.MouseButton1 then

			dragging = true
			dragStart = input.Position
			startPos = frame.Position
		end
	end)

	connect(UserInputService.InputChanged, function(input)

		if dragging and input then

			local delta = input.Position - dragStart

			frame.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end)

	connect(UserInputService.InputEnded, function(input)

		if input and input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	connect(biomeButton.MouseButton1Click, function()

		selectedBiomeIndex = (selectedBiomeIndex % #TARGET_BIOMES) + 1
		selectedBiome = TARGET_BIOMES[selectedBiomeIndex]

		cachedSnapshot = nil
		refreshBiomeButton()
	end)

	connect(flyButton.MouseButton1Click, function()

		startFlight("manual")
	end)

	connect(autoButton.MouseButton1Click, function()

		autoOnHit = not autoOnHit
		refreshAutoButton()
	end)

	connect(stopButton.MouseButton1Click, function()

		if isFlying then
			endFlight("stopped by user")
		else
			report("Not flying.")
		end
	end)

	connect(closeButton.MouseButton1Click, function()

		stopEverything("closed by user")
	end)

	refreshBiomeButton()
	refreshAutoButton()
end

--==================================================
-- START / STOP
--==================================================

function stopEverything(reason)

	if not scriptAlive then
		return
	end

	scriptAlive = false

	if isFlying then

		isFlying = false
		activeFlight = nil

		restoreWalkSpeed()
		applyFrictionless(false)
	end

	disconnectAll()

	if gui then

		safe(function()
			gui:Destroy()
		end)

		gui = nil
	end

	if _G.SNOW_FLIGHT_1_6S and _G.SNOW_FLIGHT_1_6S.stop == stopEverything then
		_G.SNOW_FLIGHT_1_6S = nil
	end

	print("[Snow Flight 1.6s] stopped (" .. tostring(reason or "?") .. ")")
end

do

	local previous = _G.SNOW_FLIGHT_1_6S

	if type(previous) == "table" and type(previous.stop) == "function" then

		safe(function()
			previous.stop("replaced by a newer run")
		end)
	end
end

safe(buildGui)
bindCharacterWatch(getCharacter())

_G.SNOW_FLIGHT_1_6S = {
	version = "1.0",
	flightDuration = CONFIG.FLIGHT_DURATION,
	maxSpeed = CONFIG.MAX_SPEED,
	stop = stopEverything,
	fly = startFlight,
	stopFlight = function()
		endFlight("stopped")
	end,
	selectBiome = function(name)

		for index, biome in ipairs(TARGET_BIOMES) do

			if string.lower(biome) == string.lower(tostring(name)) then

				selectedBiomeIndex = index
				selectedBiome = biome
				cachedSnapshot = nil
				refreshBiomeButton()

				return true
			end
		end

		return false
	end,
	getBiome = function()
		return selectedBiome
	end,
	-- read-only inspector: shows what the target resolver actually found
	targetInfo = function()

		local target = getTargetEgg(selectedBiome)

		if not target then
			return nil
		end

		return {
			Uid = target.Uid,
			AreaId = target.AreaId,
			Source = target.Source,
			X = target.Position.X,
			Y = target.Position.Y,
			Z = target.Position.Z,
		}
	end,
	isFlying = function()
		return isFlying
	end,
	lastReport = function()
		return lastReport
	end,
	state = function()

		return {
			alive = scriptAlive,
			flying = isFlying,
			biome = selectedBiome,
			autoOnHit = autoOnHit,
			walkSpeedSaved = savedWalkSpeed,
		}
	end,
}
