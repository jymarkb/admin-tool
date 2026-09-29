--[[
=====================================================================
 BAIT → RAGDOLL → RECOVER → 1.6s FLIGHT  v1.0
 -------------------------------------------------------------------
 NEW separate script. "grok-v3-target-fix.lua",
 "test-ragdoll-good-recovery.lua" and "snow_flight_1.6s.lua" are all
 left untouched.

 PIPELINE (same order you asked for)
   1. GLIDE  to a Forest bait egg (velocity only, 280 studs/s)
   2. BAIT   try to pick it up (carry remote + prompts + hitbox touch)
   3. DETECT ragdoll / hit
   4. PAUSE  the normal velocity writer  + zero the assembly velocity
   5. RESTORE Motor6D  (re-enable every disabled joint)
   6. RESTORE Humanoid control (PlatformStand/Sit cleared,
      GettingUp -> Running, re-asserted for the whole flight)
   7. FLIGHT exactly 1.6 s straight to the target biome egg
      (SNOW by default) using ONLY AssemblyLinearVelocity

   Every stage is timestamped in the on-screen log, so you can see the
   order happen instead of trusting it.

 SPEED
   1.6 s is the total flight duration: speed = distance / 1.6,
   recomputed every frame. MAX_SPEED (default 3000 studs/s) is a safety
   clamp; if the target needs more, the flight ends short and the log
   says so.

 WHAT IT WRITES
   * HumanoidRootPart AssemblyLinearVelocity / AssemblyAngularVelocity
   * Humanoid state (forced to Running while flying)
   * Motor6D.Enabled (re-enable only)
   * Humanoid.WalkSpeed (forced 500, original restored at the end)
   * CustomPhysicalProperties (frictionless while flying, restored)

 WHAT IT NEVER DOES
   * no CFrame writes, no Position writes, no anchoring, no teleport
   * no egg drop / strike / guard remote calls
   * the carry remote and the read-only snapshot remote are invoked only
     in the bait stage, exactly like grok-v3-target-fix.lua does

 EXPECTATION SETTING
   Picking up is a client request; the game decides whether you actually
   hold the egg and whether you get ragdolled. Forcing Running and
   writing velocity are also requests - if the server keeps authority
   during the stun you can still be corrected mid-flight.

 USAGE
   1) Execute this file.
   2) Press "RUN PIPELINE" and watch the stage line / log.
   3) Or press "FLY NOW (1.6s)" to skip straight to a flight.
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

	warn("[Bait-Flight] LocalPlayer not available; aborting.")

	return
end

--==================================================
-- CONFIG
--==================================================

local CONFIG = {
	-- stages
	BAIT_GLIDE_SPEED = 280.0,     -- grok-v3 used 280 for the forest glide
	BAIT_GLIDE_TIMEOUT = 2.5,
	BAIT_ARRIVE_DIST = 2.2,
	BAIT_BURST_S = 2.2,           -- how long we keep trying to pick up
	BAIT_ATTEMPT_INTERVAL = 0.12,
	STRIKE_TIMEOUT_S = 15.0,      -- max wait for the ragdoll/hit

	-- recovery
	RESTORE_RETRY = 0.10,

	-- flight
	FLIGHT_DURATION = 1.6,        -- TOTAL flight time
	MAX_SPEED = 3000.0,
	TARGET_Y_OFFSET = 3.0,
	ARRIVE_TOLERANCE = 5.0,
	MIN_ARRIVE_ELAPSED = 0.25,

	-- behaviour
	RUN_WALKSPEED = 500.0,
	AUTO_ON_HIT = true,           -- idle + hit while carrying -> recover + fly
	HIT_COOLDOWN = 2.0,
	ZERO_FRICTION = true,
	PROMPT_RADIUS = 16.0,
}

local TARGET_BIOMES = {
	"Snow", "Jungle", "Desert", "Ocean", "Volcano", "Abyss Ocean",
	"Prehistoric", "Cosmic", "Cherry Blossom", "Titan", "Light Dark",
}

local BAIT_BIOME = "Forest"

local selectedBiomeIndex = 1
local selectedBiome = TARGET_BIOMES[selectedBiomeIndex]   -- SNOW first

--==================================================
-- STATE
--==================================================

local scriptStart = os.clock()
local scriptAlive = true

local connections = {}
local pipeline = {
	running = false,
	stage = "IDLE",
	token = 0,
}
local writer = {
	active = false,   -- a normal (glide) velocity writer is running
	paused = false,   -- paused because a ragdoll/hit was detected
}
local isFlying = false
local lastAutoHit = 0
local autoOnHit = CONFIG.AUTO_ON_HIT
local savedWalkSpeed = nil
local originalPhysicalProperties = {}
local zeroFriction = PhysicalProperties.new(0.7, 0, 0, 100, 100)
local lastReport = ""
local lastMotorCheck = 0
local lastStateAssert = 0
local lastKnownHealth = nil
local cachedSnapshot = nil

local pipelineLog = {}
local gui, stageLabel, statusLabel, logLabel, biomeButton, autoButton

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

local function setReport(text)

	lastReport = text

	if statusLabel then
		statusLabel.Text = text
	end
end

local function logEvent(text)

	pipelineLog[#pipelineLog + 1] = {
		t = os.clock() - scriptStart,
		stage = pipeline.stage,
		text = text,
	}

	while #pipelineLog > 200 do
		table.remove(pipelineLog, 1)
	end
end

local function setStage(name)

	pipeline.stage = name

	if stageLabel then
		stageLabel.Text = "STAGE: " .. name
	end
end

local function zeroVelocity()

	local root = getRoot()

	if not root then
		return
	end

	safe(function()
		root.AssemblyLinearVelocity = Vector3.zero
	end)

	safe(function()
		root.AssemblyAngularVelocity = Vector3.zero
	end)
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
			local okTool, isTool = safe(function()
				return child:IsA("Tool")
			end)

			if (okTool and isTool) or string.find(name, "egg", 1, true) then

				if not string.find(name, "trap", 1, true) then
					return true
				end
			end
		end
	end

	return LocalPlayer:GetAttribute("IsCarrying") == true
end

--==================================================
-- REMOTE HELPERS (same paths as grok-v3-target-fix.lua)
--==================================================

local function getRemote(subPath)

	local ok, remote = safe(function()
		return ReplicatedStorage.Packages.Networking[subPath]
	end)

	return ok and remote or nil
end

local function carryEggRemote(uid)

	local remote = getRemote("RF/EggWorld/AskFieldEggCarry")

	if not remote or not uid then
		return false
	end

	task.spawn(function()

		safe(function()
			remote:InvokeServer({ Uid = tostring(uid) })
		end)
	end)

	return true
end

local function triggerEggPrompts()

	safe(function()

		if type(fireproximityprompt) ~= "function" then
			return
		end

		local root = getRoot()

		if not root then
			return
		end

		local origin = root.Position
		local maxDistance = CONFIG.PROMPT_RADIUS

		for _, descendant in ipairs(Workspace:GetDescendants()) do

			if descendant:IsA("ProximityPrompt") then

				local part = descendant.Parent

				if part and part:IsA("BasePart")
					and (part.Position - origin).Magnitude <= maxDistance then

					pcall(function()
						fireproximityprompt(descendant, 0)
					end)
				end
			end
		end
	end)
end

local function touchEggHitbox(uid)

	safe(function()

		if type(firetouchinterest) ~= "function" then
			return
		end

		local root = getRoot()

		if not root or not uid then
			return
		end

		local area = Workspace:FindFirstChild("AreaEggSlotsClient")

		if not area then
			return
		end

		local eggModel = area:FindFirstChild(tostring(uid))

		if not eggModel then
			return
		end

		local hitbox = eggModel:FindFirstChild("Hitbox")
			or eggModel:FindFirstChildWhichIsA("BasePart")

		if not hitbox then
			return
		end

		firetouchinterest(root, hitbox, 0)

		task.defer(function()

			safe(function()
				firetouchinterest(root, hitbox, 1)
			end)
		end)
	end)
end

--==================================================
-- TARGET RESOLUTION (READ-ONLY)
--==================================================

local function getWorkspaceEgg(biome)

	local okArea, area = safe(function()
		return Workspace:FindFirstChild("AreaEggSlotsClient")
	end)

	if not okArea or not area then
		return nil
	end

	local normBiome = string.lower(tostring(biome or ""))

	local okSlots, slots = safe(function()
		return area:GetChildren()
	end)

	if not okSlots or type(slots) ~= "table" then
		return nil
	end

	for _, slot in ipairs(slots) do

		if string.find(string.lower(tostring(slot.Name)), normBiome, 1, true) then

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

	for _, record in pairs(source) do

		if type(record) == "table" then

			local position = extractTargetPosition(record)
			local uid = record.Uid or record.uid or record.UID or record.Id or record.id
			local area = record.AreaId or record.areaId or record.Area or record.Biome or record.biome
			local category = record.AssetCategory or record.assetCategory or record.Category

			if uid and position then

				records[#records + 1] = {
					Uid = tostring(uid),
					AreaId = tostring(area or "Unknown"),
					AssetCategory = tostring(category or "Egg"),
					Position = position,
					CarrierUserId = record.CarrierUserId or record.carrierUserId,
					Source = "server snapshot",
				}
			end
		end
	end

	return records
end

local function fetchSnapshot(forceRefresh)

	if not forceRefresh and cachedSnapshot and #cachedSnapshot > 0 then
		return cachedSnapshot
	end

	local remote = getRemote("RF/EggWorld/AskFieldEggSnapshot")

	if not remote then
		return {}
	end

	local ok, result = safe(function()
		return remote:InvokeServer()
	end)

	if ok and type(result) == "table" then

		cachedSnapshot = parseSnapshotEggs(result)

		return cachedSnapshot
	end

	return {}
end

local function isEggAvailable(egg)

	local carrier = egg.CarrierUserId

	return carrier == nil or carrier == 0 or carrier == ""
end

local function getTargetEgg(biome)

	local workspaceEgg = getWorkspaceEgg(biome)

	if workspaceEgg then
		return workspaceEgg
	end

	local normBiome = string.lower(tostring(biome or ""))

	for _, egg in ipairs(fetchSnapshot(false)) do

		if string.lower(tostring(egg.AreaId)) == normBiome and isEggAvailable(egg) then
			return egg
		end
	end

	return nil
end

local function getForestBait()

	local workspaceEgg = getWorkspaceEgg(BAIT_BIOME)

	if workspaceEgg then
		return workspaceEgg
	end

	for _, egg in ipairs(fetchSnapshot(false)) do

		if string.lower(tostring(egg.AreaId)) == string.lower(BAIT_BIOME)
			and isEggAvailable(egg) then

			return egg
		end
	end

	return nil
end

--==================================================
-- RAGDOLL DETECTION
--==================================================

local function disabledMotorCount(character)

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
				count = count + 1
			end
		end
	end

	return count
end

-- Returns a reason string when the character looks ragdolled / hit.
local function getRagdollReason()

	local humanoid = getHumanoid()
	local character = getCharacter()

	if not humanoid or not character then
		return nil
	end

	local okEnd, ragdollEnd = safe(function()
		return LocalPlayer:GetAttribute("RagdollEndTime")
	end)

	if okEnd and type(ragdollEnd) == "number" then

		local okNow, now = safe(function()
			return Workspace:GetServerTimeNow()
		end)

		if okNow and type(now) == "number" and ragdollEnd > now then
			return "RagdollEndTime"
		end
	end

	local okState, state = safe(function()
		return humanoid:GetState()
	end)

	if okState then

		if state == Enum.HumanoidStateType.Physics then
			return "state Physics"
		end

		if state == Enum.HumanoidStateType.FallingDown then
			return "state FallingDown"
		end
	end

	local okStand, standing = safe(function()
		return humanoid.PlatformStand
	end)

	if okStand and standing then
		return "PlatformStand"
	end

	if disabledMotorCount(character) >= 2 then
		return "disabled Motor6D"
	end

	return nil
end

--==================================================
-- RECOVERY (same approach as test-ragdoll-good-recovery.lua)
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

-- Step 5 + 6 of the pipeline: joints back on, humanoid control back.
local function restoreMotor6D()

	local character = getCharacter()

	if not character then
		return 0
	end

	return enableMotors(character)
end

local function restoreHumanoidControl(waitBetween)

	local humanoid = getHumanoid()

	if not humanoid then
		return false
	end

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

	if waitBetween then
		task.wait()
	end

	safe(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
	end)

	local ok, state = safe(function()
		return humanoid:GetState()
	end)

	return ok and tostring(state) or "unknown"
end

-- Re-asserted for the whole flight so a stun cannot take it over.
local function keepControl()

	local now = os.clock()

	if now - lastMotorCheck >= CONFIG.RESTORE_RETRY then

		lastMotorCheck = now

		local character = getCharacter()

		if character then
			enableMotors(character)
		end
	end

	if now - lastStateAssert < CONFIG.RESTORE_RETRY then
		return
	end

	local humanoid = getHumanoid()

	if not humanoid then
		return
	end

	local ok, state = safe(function()
		return humanoid:GetState()
	end)

	if not ok then
		return
	end

	if state == Enum.HumanoidStateType.Physics
		or state == Enum.HumanoidStateType.FallingDown
		or state == Enum.HumanoidStateType.GettingUp
		or state == Enum.HumanoidStateType.Ragdoll then

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
-- STAGE 4: PAUSE THE NORMAL VELOCITY WRITER
--==================================================

local function pauseNormalVelocityWriter()

	local wasRunning = writer.active

	writer.active = false
	writer.paused = true

	logEvent("normal velocity writer PAUSED (was "
		.. (wasRunning and "running" or "idle") .. ")")

	zeroVelocity()
end

local function resumeNormalVelocityWriter()

	writer.paused = false
end

--==================================================
-- STAGE 1: GLIDE (the normal velocity writer)
--==================================================

local function glideTo(targetPosition, token, timeoutS)

	local started = os.clock()

	writer.active = true
	writer.paused = false

	local arrived = false

	while scriptAlive and token == pipeline.token and writer.active do

		if os.clock() - started >= timeoutS then
			break
		end

		if getRagdollReason() then
			break
		end

		local root = getRoot()

		if not root then
			break
		end

		local diff = targetPosition - root.Position
		local horizontal = math.sqrt(diff.X * diff.X + diff.Z * diff.Z)

		if horizontal <= CONFIG.BAIT_ARRIVE_DIST then
			arrived = true
			break
		end

		if horizontal > 0.001 then

			local direction = Vector3.new(diff.X, 0, diff.Z).Unit
			local vertical = math.clamp(diff.Y * 4, -15, 15)

			safe(function()
				root.AssemblyLinearVelocity = Vector3.new(
					direction.X * CONFIG.BAIT_GLIDE_SPEED,
					vertical,
					direction.Z * CONFIG.BAIT_GLIDE_SPEED
				)
			end)

			safe(function()
				root.AssemblyAngularVelocity = Vector3.zero
			end)
		end

		enforceWalkSpeed()

		RunService.Heartbeat:Wait()
	end

	writer.active = false

	return arrived
end

--==================================================
-- STAGE 7: THE 1.6 SECOND FLIGHT
--==================================================

local function flyTo(targetPosition, token, duration)

	local root = getRoot()
	local humanoid = getHumanoid()

	if not root or not humanoid then
		return false, 0, 0
	end

	local origin = root.Position
	local started = os.clock()

	isFlying = true
	writer.paused = true

	applyFrictionless(true)
	enforceWalkSpeed()

	local arrived = false

	while scriptAlive and token == pipeline.token do

		RunService.Heartbeat:Wait()

		local elapsed = os.clock() - started

		root = getRoot()
		humanoid = getHumanoid()

		if not root or not humanoid then
			break
		end

		local okHealth, health = safe(function()
			return humanoid.Health
		end)

		if okHealth and health <= 0 then
			break
		end

		keepControl()
		enforceWalkSpeed()

		local remainingTime = math.max(duration - elapsed, 0.001)
		local delta = targetPosition - root.Position

		if delta.Magnitude > 0.001 then

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
		end

		if delta.Magnitude < CONFIG.ARRIVE_TOLERANCE
			and elapsed > CONFIG.MIN_ARRIVE_ELAPSED then

			arrived = true
			break
		end

		if elapsed >= duration then
			break
		end
	end

	isFlying = false

	zeroVelocity()
	applyFrictionless(false)
	restoreWalkSpeed()

	local finalRoot = getRoot()
	local travelled = 0
	local remaining = 0

	if finalRoot then

		travelled = (finalRoot.Position - origin).Magnitude
		remaining = (targetPosition - finalRoot.Position).Magnitude
	end

	return arrived, travelled, remaining
end

--==================================================
-- PIPELINE
--==================================================

local function baitForestEgg(token)

	local bait = getForestBait()

	if not bait then
		return nil
	end

	setStage("GLIDING")
	logEvent(string.format(
		"gliding to %s bait (%s) at (%.0f, %.0f)",
		BAIT_BIOME,
		tostring(bait.Source),
		bait.Position.X,
		bait.Position.Z
	))

	glideTo(bait.Position, token, CONFIG.BAIT_GLIDE_TIMEOUT)

	if not scriptAlive or token ~= pipeline.token then
		return nil
	end

	if getRagdollReason() then

		logEvent("ragdoll detected during the glide - skipping the pickup attempt")

		return bait
	end

	setStage("BAITING")
	logEvent("attempting pickup of " .. tostring(bait.Uid))

	local started = os.clock()

	while scriptAlive and token == pipeline.token
		and os.clock() - started < CONFIG.BAIT_BURST_S do

		if getRagdollReason() then
			break
		end

		carryEggRemote(bait.Uid)
		triggerEggPrompts()
		touchEggHitbox(bait.Uid)

		task.wait(CONFIG.BAIT_ATTEMPT_INTERVAL)
	end

	return bait
end

local function waitForHit(token)

	local reason = getRagdollReason()

	if reason then
		return reason
	end

	setStage("WAITING_HIT")
	logEvent(string.format(
		"waiting for ragdoll/hit (timeout %.0fs)",
		CONFIG.STRIKE_TIMEOUT_S
	))

	local started = os.clock()

	while scriptAlive and token == pipeline.token do

		reason = getRagdollReason()

		if reason then
			return reason
		end

		if os.clock() - started >= CONFIG.STRIKE_TIMEOUT_S then
			return nil
		end

		task.wait(0.05)
	end

	return nil
end

local function recover(token)

	setStage("RECOVERING")

	-- 4. pause the normal velocity writer and stop the avatar
	pauseNormalVelocityWriter()

	-- 5. restore Motor6D
	local motors = restoreMotor6D()
	logEvent("Motor6D restored: " .. tostring(motors) .. " joint(s) re-enabled")

	if not scriptAlive or token ~= pipeline.token then
		return
	end

	-- 6. restore Humanoid control
	local state = restoreHumanoidControl(true)
	logEvent("Humanoid control restored: " .. tostring(state))
end

local function flyToBiome(token)

	local target = getTargetEgg(selectedBiome)

	if not target then

		setStage("IDLE")

		local message = "No " .. tostring(selectedBiome)
			.. " egg target found; flight skipped."

		logEvent(message)
		setReport(message)

		return false
	end

	local targetPosition =
		target.Position + Vector3.new(0, CONFIG.TARGET_Y_OFFSET, 0)

	local root = getRoot()
	local distance = root and (targetPosition - root.Position).Magnitude or 0

	setStage("FLYING")

	logEvent(string.format(
		"flight started to %s (%s) | %.0f studs | %.0f studs/s | %.1fs",
		tostring(selectedBiome),
		tostring(target.Source),
		distance,
		distance / CONFIG.FLIGHT_DURATION,
		CONFIG.FLIGHT_DURATION
	))

	local arrived, travelled, remaining =
		flyTo(targetPosition, token, CONFIG.FLIGHT_DURATION)

	logEvent(string.format(
		"flight ended (%s) | travelled %.0f studs | gap %.0f studs",
		arrived and "arrived" or "1.6s elapsed",
		travelled,
		remaining
	))

	setReport(string.format(
		"%s | flew %.0f studs of %.0f in %.1fs | gap %.0f studs",
		arrived and "ARRIVED" or "TIME UP",
		travelled,
		distance,
		CONFIG.FLIGHT_DURATION,
		remaining
	))

	return true
end

local function runPipeline(token, reason)

	pipeline.running = true
	writer.paused = false

	logEvent("pipeline started: " .. tostring(reason or "manual"))

	local bait = baitForestEgg(token)

	if scriptAlive and token == pipeline.token then

		if getRagdollReason() then
			recover(token)
			flyToBiome(token)
		else

			local hitReason = waitForHit(token)

			if not scriptAlive or token ~= pipeline.token then

				pipeline.running = false
				return
			end

			if hitReason then

				logEvent("ragdoll/hit detected: " .. tostring(hitReason))

				recover(token)
				flyToBiome(token)

			else

				logEvent("no hit within the timeout - pipeline stopped")

				setReport("No ragdoll/hit seen within "
					.. tostring(CONFIG.STRIKE_TIMEOUT_S) .. "s.")

				setStage("IDLE")
			end
		end
	end

	resumeNormalVelocityWriter()

	if scriptAlive then
		restoreWalkSpeed()
		applyFrictionless(false)
	end

	if pipeline.stage ~= "IDLE" then
		setStage("DONE")
	end

	pipeline.running = false
end

local function startPipeline(reason)

	if pipeline.running or isFlying then
		return false
	end

	pipeline.token = pipeline.token + 1

	local token = pipeline.token

	task.spawn(function()

		local ok = safe(function()
			runPipeline(token, reason)
		end)

		if not ok then

			pipeline.running = false
			writer.active = false
			writer.paused = false

			logEvent("pipeline error (see console)")
		end
	end)

	return true
end

-- Recover + fly only, for a hit while idle (no bait stage).
local function startRecoveryFlight(reason)

	if pipeline.running or isFlying then
		return false
	end

	pipeline.token = pipeline.token + 1

	local token = pipeline.token

	pipeline.running = true

	task.spawn(function()

		safe(function()

			logEvent("hit while idle: recover + fly (" .. tostring(reason) .. ")")

			recover(token)

			if scriptAlive and token == pipeline.token then
				flyToBiome(token)
			end

			resumeNormalVelocityWriter()

			if scriptAlive then
				restoreWalkSpeed()
				applyFrictionless(false)
			end

			setStage("IDLE")
			pipeline.running = false
		end)
	end)

	return true
end

-- Manual flight: skip the pipeline, use the current state as-is.
local function startFlight(reason)

	if isFlying or pipeline.running then
		return false
	end

	pipeline.token = pipeline.token + 1

	local token = pipeline.token

	pipeline.running = true

	task.spawn(function()

		safe(function()

			logEvent("manual flight (" .. tostring(reason) .. ")")

			recover(token)
			flyToBiome(token)

			resumeNormalVelocityWriter()

			if scriptAlive then
				restoreWalkSpeed()
				applyFrictionless(false)
			end

			setStage("IDLE")
			pipeline.running = false
		end)
	end)

	return true
end

--==================================================
-- AUTOMATIC RECOVERY ON HIT (while idle)
--==================================================

local function autoRecover(reason)

	if not autoOnHit or isFlying or pipeline.running or not scriptAlive then
		return
	end

	if os.clock() - lastAutoHit < CONFIG.HIT_COOLDOWN then
		return
	end

	if not isHoldingEgg() then
		return
	end

	lastAutoHit = os.clock()

	startRecoveryFlight(reason)
end

local function bindCharacterWatch(character)

	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if not humanoid then
		return
	end

	local okHealth, initialHealth = safe(function()
		return humanoid.Health
	end)

	lastKnownHealth = okHealth and initialHealth or nil

	connect(humanoid.HealthChanged, function(newHealth)

		local previous = lastKnownHealth
		lastKnownHealth = newHealth

		if type(previous) == "number" and type(newHealth) == "number"
			and newHealth < previous and (previous - newHealth) >= 1 then

			autoRecover(string.format("health -%.0f", previous - newHealth))
		end
	end)

	connect(humanoid.StateChanged, function(_, newState)

		if newState == Enum.HumanoidStateType.Physics
			or newState == Enum.HumanoidStateType.FallingDown then

			autoRecover("state " .. tostring(newState))
		end
	end)

	connect(humanoid.Changed, function(property)

		if property == "PlatformStand" then

			local okStand, standing = safe(function()
				return humanoid.PlatformStand
			end)

			if okStand and standing then
				autoRecover("PlatformStand")
			end
		end
	end)
end

connect(LocalPlayer.AttributeChanged, function(name)

	if name ~= "RagdollEndTime" then
		return
	end

	local okEnd, ragdollEnd = safe(function()
		return LocalPlayer:GetAttribute("RagdollEndTime")
	end)

	local okNow, now = safe(function()
		return Workspace:GetServerTimeNow()
	end)

	if okEnd and okNow and type(ragdollEnd) == "number"
		and type(now) == "number" and ragdollEnd > now then

		autoRecover("ragdoll attribute")
	end
end)

connect(LocalPlayer.CharacterAdded, function(character)

	safe(function()
		applyFrictionless(false)
	end)

	restoreWalkSpeed()

	isFlying = false
	pipeline.running = false

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

		biomeButton.Text = "TARGET BIOME: [" .. tostring(selectedBiome)
			.. "]  (click to switch)"
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

local function render()

	if not logLabel then
		return
	end

	local lines = {}

	for index = math.max(1, #pipelineLog - 11), #pipelineLog do

		local entry = pipelineLog[index]

		lines[#lines + 1] = string.format(
			"[%6.2fs] %-10s %s",
			entry.t,
			entry.stage,
			entry.text
		)
	end

	logLabel.Text = table.concat(lines, "\n")
end

local function buildGui()

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "BaitRecoveryFlight"
	gui.ResetOnSpawn = false
	gui.Parent = playerGui or LocalPlayer:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Main"
	frame.Size = UDim2.new(0, 520, 0, 300)
	frame.Position = UDim2.new(0, 40, 0, 90)
	frame.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local title = Instance.new("TextLabel")
	title.Text = "Forest bait -> ragdoll -> recover -> 1.6s flight"
	title.Size = UDim2.new(1, -12, 0, 22)
	title.Position = UDim2.new(0, 6, 0, 4)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(210, 230, 250)
	title.TextSize = 13
	title.Font = Enum.Font.SourceSansBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = frame

	stageLabel = Instance.new("TextLabel")
	stageLabel.Name = "Stage"
	stageLabel.Text = "STAGE: IDLE"
	stageLabel.Size = UDim2.new(1, -12, 0, 20)
	stageLabel.Position = UDim2.new(0, 6, 0, 28)
	stageLabel.BackgroundTransparency = 1
	stageLabel.TextColor3 = Color3.fromRGB(255, 210, 120)
	stageLabel.TextSize = 13
	stageLabel.Font = Enum.Font.Code
	stageLabel.TextXAlignment = Enum.TextXAlignment.Left
	stageLabel.Parent = frame

	biomeButton = makeButton(frame, "TARGET BIOME: [Snow]", 6, 54, 300, 26)
	local runButton = makeButton(frame, "RUN PIPELINE (Forest bait)", 312, 54, 202, 26)
	runButton.BackgroundColor3 = Color3.fromRGB(32, 74, 116)

	local flyButton = makeButton(frame, "FLY NOW (1.6s)", 6, 86, 150, 24)
	local stopButton = makeButton(frame, "STOP", 162, 86, 80, 24)
	autoButton = makeButton(frame, "Auto on hit: ON", 248, 86, 150, 24)
	local closeButton = makeButton(frame, "CLOSE", 404, 86, 110, 24)
	closeButton.BackgroundColor3 = Color3.fromRGB(96, 40, 44)

	statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.Text = "Idle. Press RUN PIPELINE."
	statusLabel.Size = UDim2.new(1, -12, 0, 32)
	statusLabel.Position = UDim2.new(0, 6, 0, 116)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.fromRGB(150, 210, 170)
	statusLabel.TextSize = 12
	statusLabel.Font = Enum.Font.SourceSans
	statusLabel.TextWrapped = true
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextYAlignment = Enum.TextYAlignment.Top
	statusLabel.Parent = frame

	logLabel = Instance.new("TextLabel")
	logLabel.Name = "Log"
	logLabel.Text = ""
	logLabel.Size = UDim2.new(1, -12, 0, 136)
	logLabel.Position = UDim2.new(0, 6, 0, 152)
	logLabel.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
	logLabel.TextColor3 = Color3.fromRGB(200, 208, 220)
	logLabel.TextSize = 11
	logLabel.Font = Enum.Font.Code
	logLabel.TextWrapped = true
	logLabel.TextXAlignment = Enum.TextXAlignment.Left
	logLabel.TextYAlignment = Enum.TextYAlignment.Top
	logLabel.Parent = frame

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

	connect(runButton.MouseButton1Click, function()

		if not startPipeline("manual") then
			setReport("Pipeline already running (or flying).")
		end
	end)

	connect(flyButton.MouseButton1Click, function()

		if not startFlight("manual") then
			setReport("Busy: pipeline running or already flying.")
		end
	end)

	connect(autoButton.MouseButton1Click, function()

		autoOnHit = not autoOnHit
		refreshAutoButton()
	end)

	connect(stopButton.MouseButton1Click, function()

		if pipeline.running or isFlying then

			pipeline.token = pipeline.token + 1
			pipeline.running = false
			isFlying = false

			zeroVelocity()
			restoreWalkSpeed()
			applyFrictionless(false)

			writer.active = false
			writer.paused = false

			logEvent("stopped by user")
			setStage("IDLE")
			setReport("Stopped.")
		else
			setReport("Nothing running.")
		end
	end)

	connect(closeButton.MouseButton1Click, function()

		stopEverything("closed by user")
	end)

	refreshBiomeButton()
	refreshAutoButton()
end

--==================================================
-- RENDER LOOP
--==================================================

task.spawn(function()

	while scriptAlive do

		safe(render)

		task.wait(0.2)
	end
end)

--==================================================
-- STOP
--==================================================

function stopEverything(reason)

	if not scriptAlive then
		return
	end

	scriptAlive = false

	pipeline.token = pipeline.token + 1
	pipeline.running = false
	isFlying = false

	zeroVelocity()
	restoreWalkSpeed()
	applyFrictionless(false)

	disconnectAll()

	if gui then

		safe(function()
			gui:Destroy()
		end)

		gui = nil
	end

	if _G.BAIT_RECOVERY_FLIGHT
		and _G.BAIT_RECOVERY_FLIGHT.stop == stopEverything then

		_G.BAIT_RECOVERY_FLIGHT = nil
	end

	print("[Bait-Flight] stopped (" .. tostring(reason or "?") .. ")")
end

--==================================================
-- START
--==================================================

do

	local previous = _G.BAIT_RECOVERY_FLIGHT

	if type(previous) == "table" and type(previous.stop) == "function" then

		safe(function()
			previous.stop("replaced by a newer run")
		end)
	end
end

safe(buildGui)
bindCharacterWatch(getCharacter())

logEvent("script loaded (read/write scope: own GUI + velocity/state/joints)")

_G.BAIT_RECOVERY_FLIGHT = {
	version = "1.0",
	config = CONFIG,
	stop = stopEverything,
	start = startPipeline,
	fly = startFlight,
	recoverOnly = startRecoveryFlight,
	stage = function()
		return pipeline.stage
	end,
	running = function()
		return pipeline.running
	end,
	flying = function()
		return isFlying
	end,
	writer = function()
		return {
			active = writer.active,
			paused = writer.paused,
		}
	end,
	report = function()
		return lastReport
	end,
	log = function()
		return pipelineLog
	end,
	logText = function()

		local lines = {}

		for _, entry in ipairs(pipelineLog) do

			lines[#lines + 1] = string.format(
				"[%6.2fs] %s: %s",
				entry.t,
				entry.stage,
				entry.text
			)
		end

		return table.concat(lines, "\n")
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
	baitInfo = function()

		local bait = getForestBait()

		if not bait then
			return nil
		end

		return {
			Uid = bait.Uid,
			Source = bait.Source,
			X = bait.Position.X,
			Y = bait.Position.Y,
			Z = bait.Position.Z,
		}
	end,
	ragdollReason = function()
		return getRagdollReason()
	end,
	isHoldingEgg = isHoldingEgg,
}
