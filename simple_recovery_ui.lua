--[[
=====================================================================
 SIMPLE RECOVERY UI  v1.0
 -------------------------------------------------------------------
 A small, self-contained tool. It does not modify any other script.

 WHAT IT GIVES YOU
   1. WALK TO FOREST EGG   - walks the character to the forest egg slot
                             using Humanoid:MoveTo (no velocity writes,
                             no CFrame writes, normal animation)
   2. PICK UP EGG          - tries the pickup the same way grok-v3 does:
                             carry remote + proximity prompts + hitbox
                             touch, repeatedly, until you hold it
   3. RECOVERY PULSE       - the pulse logic from
                             "test-ragdoll-good-recovery.lua":
                               * restores every disabled Motor6D
                               * clears PlatformStand / Sit
                               * re-enables Ragdoll / FallingDown /
                                 Physics states
                               * ChangeState(GettingUp) -> short wait ->
                                 ChangeState(Running)
                             It arms itself automatically the moment a
                             pickup is triggered, and can be toggled by
                             hand at any time.

   The pulse deliberately does NOT write AssemblyLinearVelocity, exactly
   like the original recovery script.

   ONE THING TO EXPECT
   The original pulse repeats while the game's ragdoll window is still
   open (RagdollEndTime in the future), roughly every 0.20 s. That is the
   behaviour being copied, and it is why the log shows several pulses in
   a row - each one is visible there so you can see exactly when the game
   let go.

   4. STRAIGHT FLIGHT      - grok-v3's own flight formula:
                             walk a waypoint forward along the path by one
                             frame, then set the velocity that covers the
                             remaining gap in exactly that frame, clamped at
                             AERIAL_SPEED * 1.5 (1125 studs/s - scaled up
                             only when the target is farther than grok could
                             reach in the flight time, e.g. Cosmic).
                             The path is straight (peakArc = 0) instead of
                             grok's parabolic arc, and the target comes from
                             the same place grok takes it: a FRESH read-only
                             AskFieldEggSnapshot, with the workspace slot
                             folder only as a fallback.

                             It starts as soon as a pulse has restored
                             control - no ragdoll rollover, no post-landing
                             freeze hold. While flying, the joints and the
                             Running state are re-asserted every frame so the
                             character cannot roll over or ragdoll out of it.

                             1.6 s is the only fixed number: speed is
                             auto-calculated as remaining distance /
                             remaining time.

 TRIGGERS (same checks as the recovery script)
   * LocalPlayer attribute RagdollEndTime is in the server's future
   * Humanoid state Physics / FallingDown
   * Humanoid.PlatformStand == true
   * two or more disabled Motor6D

 SAFETY
   * no CFrame / Position / Anchored writes anywhere
   * no velocity writes at all - walking is Humanoid:MoveTo
   * never calls the drop / strike remotes
   * Close disconnects everything it connected and destroys its GUI

 LIMITS
   MoveTo is a request like any other: if the server disagrees (stun,
   carry restriction, blocked path) the walk simply makes no progress -
   the status line reports that instead of pretending it worked.
=====================================================================
]]

--==================================================
-- SERVICES
--==================================================

local Players = game:GetService("Players")
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

	warn("[Simple Recovery UI] LocalPlayer not available; aborting.")

	return
end

--==================================================
-- CONFIG
--==================================================

local CONFIG = {
	BIOME = "Forest",

	WALK_SPEED = 60.0,          -- written to WalkSpeed while walking
	WALK_ARRIVE_DIST = 4.0,     -- stop when this close to the egg
	WALK_TIMEOUT = 30.0,        -- give up after this many seconds
	WALK_RETARGET = 0.2,        -- re-issue MoveTo this often
	WALK_RESTORE_SPEED = true,  -- restore the original WalkSpeed when done

	PICKUP_BURST = 3.0,         -- keep trying this long
	PICKUP_INTERVAL = 0.12,
	PROMPT_RADIUS = 16.0,

	PULSE_COOLDOWN = 0.20,      -- seconds between pulses (as in the original)
	PULSE_SETTLE = 0.05,        -- settle wait at the end of a pulse
	PULSE_AUTO_ARM = true,      -- arm the pulse when a pickup is triggered

	-- flight: mechanics from grok-v3-target-fix.lua, but STRAIGHT (no arc)
	-- and started the moment the pulse has restored control, so there is no
	-- ragdoll rollover and no post-landing hold.
	FLIGHT_BIOME = "Snow",      -- destination biome egg
	FLIGHT_DURATION = 1.6,      -- TOTAL flight time (the only constant)
	AERIAL_SPEED = 750.0,       -- grok-v3's planning speed
	GROK_CLAMP_FACTOR = 1.5,    -- grok-v3 clamps at AERIAL_SPEED * this
	                            -- (1125). For targets further than
	                            -- AERIAL_SPEED * FLIGHT_DURATION the clamp
	                            -- scales with the distance so the target is
	                            -- still reachable inside the flight time.
	SPEED_LIMIT = nil,          -- optional absolute cap in studs/s
	TARGET_Y_OFFSET = 3.0,
	ARRIVE_TOLERANCE = 5.0,
	FLY_RUN_WALKSPEED = 500.0,  -- grok-v3 forces this while flying
	NEUTRALISE_PARTS = true,    -- grok-v3 egg-mass neutralisation, restored
	                            -- again when the flight ends
	FLY_AFTER_PULSE = true,     -- pulse -> straight flight automatically
	FLIGHT_COOLDOWN = 2.0,      -- min seconds between automatic flights
}

local REMOTE_CARRY = "RF/EggWorld/AskFieldEggCarry"

--==================================================
-- STATE
--==================================================

local scriptAlive = true
local connections = {}
local pulseEnabled = false
local pulseActive = false
local lastPulseTime = 0
local pulseCount = 0
local walking = false
local walkToken = 0
local pickupCount = 0
local savedWalkSpeed = nil
local log = {}

-- flight state (grok-v3 mechanics)
local isFlying = false
local flightToken = 0
local lastFlightTime = -math.huge
local flyAfterPulse = CONFIG.FLY_AFTER_PULSE
local flightData = nil
local savedFlyWalkSpeed = nil
local originalPartPhysics = {}

local gui, statusLabel, logLabel, walkButton, pickupButton, autoButton
local pulseButton, speedBox, biomeButton, flyAfterButton

-- forward declarations (used by functions defined further down)
local flyAfterPulseIfReady
local startFlight

--==================================================
-- HELPERS
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

local function note(text)

	log[#log + 1] = {
		t = os.clock(),
		text = text,
	}

	while #log > 60 do
		table.remove(log, 1)
	end

	if logLabel then

		local lines = {}

		for index = math.max(1, #log - 9), #log do

			local entry = log[index]

			lines[#lines + 1] = string.format(
				"[%7.2fs] %s",
				entry.t % 1000,
				entry.text
			)
		end

		logLabel.Text = table.concat(lines, "\n")
	end
end

local function setStatus(text)

	if statusLabel then
		statusLabel.Text = text
	end
end

--==================================================
-- EGG TARGETING (READ-ONLY)
--==================================================

local function getWorkspaceEgg(biome)

	local okArea, area = safe(function()
		return Workspace:FindFirstChild("AreaEggSlotsClient")
	end)

	if not okArea or not area then
		return nil
	end

	local wanted = string.lower(tostring(biome or ""))

	local okSlots, slots = safe(function()
		return area:GetChildren()
	end)

	if not okSlots or type(slots) ~= "table" then
		return nil
	end

	for _, slot in ipairs(slots) do

		if string.find(string.lower(tostring(slot.Name)), wanted, 1, true) then

			local okPart, part = safe(function()
				return slot:FindFirstChildWhichIsA("BasePart", true)
			end)

			if okPart and part then

				return {
					Uid = tostring(slot.Name),
					Position = part.Position,
					Source = "workspace slot",
				}
			end
		end
	end

	return nil
end

local function getRemote(subPath)

	local ok, remote = safe(function()
		return ReplicatedStorage.Packages.Networking[subPath]
	end)

	return ok and remote or nil
end

local function getForestEgg()

	local workspaceEgg = getWorkspaceEgg(CONFIG.BIOME)

	if workspaceEgg then
		return workspaceEgg
	end

	-- fall back to the read-only snapshot query
	local remote = getRemote("RF/EggWorld/AskFieldEggSnapshot")

	if not remote then
		return nil
	end

	local ok, result = safe(function()
		return remote:InvokeServer()
	end)

	if not ok or type(result) ~= "table" then
		return nil
	end

	local records = result.Records or result.records

	if type(records) ~= "table" then
		return nil
	end

	local wanted = string.lower(CONFIG.BIOME)

	for _, record in pairs(records) do

		if type(record) == "table" then

			local area = string.lower(tostring(
				record.AreaId or record.areaId or record.Area
					or record.Biome or record.biome or ""
			))

			local carrier = record.CarrierUserId or record.carrierUserId
			local bounds = record.BoundsCFrame or record.BottomCFrame
			local position = nil

			if typeof(bounds) == "CFrame" then
				position = bounds.Position
			elseif type(bounds) == "table" and bounds.Position then
				position = bounds.Position
			end

			if not position then

				local p = record.Position or record.Pos

				if typeof(p) == "Vector3" then
					position = p
				elseif type(p) == "table" and p.X and p.Y and p.Z then
					position = Vector3.new(p.X, p.Y, p.Z)
				end
			end

			if area == wanted and position
				and (carrier == nil or carrier == 0 or carrier == "") then

				return {
					Uid = tostring(record.Uid or record.uid or ""),
					Position = position,
					Source = "server snapshot",
				}
			end
		end
	end

	return nil
end

--==================================================
-- RAGDOLL DETECTION (same checks as the recovery script)
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
-- RECOVERY PULSE (logic from test-ragdoll-good-recovery.lua)
--==================================================

local function recoveryPulse(humanoid, character)

	if not humanoid or not character then
		return
	end

	local now = os.clock()

	if now - lastPulseTime < CONFIG.PULSE_COOLDOWN then
		return
	end

	if pulseActive then
		return
	end

	pulseActive = true
	lastPulseTime = now
	pulseCount = pulseCount + 1

	-- 1. Do NOT write AssemblyLinearVelocity here (as in the original).

	-- 2. Restore Motor6D joints
	local motorsRestored = 0

	local okDesc, descendants = safe(function()
		return character:GetDescendants()
	end)

	if okDesc and type(descendants) == "table" then

		for _, object in ipairs(descendants) do

			local okMotor, isMotor = safe(function()
				return object:IsA("Motor6D")
			end)

			if okMotor and isMotor then

				local okEnabled, enabled = safe(function()
					return object.Enabled
				end)

				if okEnabled and not enabled then

					local okSet = safe(function()
						object.Enabled = true
					end)

					if okSet then
						motorsRestored = motorsRestored + 1
					end
				end
			end
		end
	end

	-- 3. Restore Humanoid control
	safe(function()
		humanoid.PlatformStand = false
	end)

	safe(function()
		humanoid.Sit = false
	end)

	safe(function()
		humanoid.AutoRotate = true
	end)

	-- 4. Re-enable the humanoid states
	safe(function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
	end)

	-- 5. Ask the Humanoid to recover
	safe(function()
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end)

	task.wait()

	if not scriptAlive then
		pulseActive = false
		return
	end

	if humanoid.Parent then

		safe(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end)
	end

	note(string.format(
		"pulse #%d: %d motor(s) restored, GettingUp -> Running",
		pulseCount,
		motorsRestored
	))

	-- 6. Let physics settle
	task.wait(CONFIG.PULSE_SETTLE)

	pulseActive = false

	-- 7. Straight flight from the restored stance (no rollover, no ragdoll)
	flyAfterPulseIfReady()
end

--==================================================
-- FLIGHT (mechanics from grok-v3-target-fix.lua, straight line)
--==================================================

-- grok-v3's neutraliseEggPhysics: carried parts stop pushing the character
-- around. Here the originals are stored and put back when the flight ends.
local function neutraliseParts(enable)

	if not CONFIG.NEUTRALISE_PARTS then
		return
	end

	local character = getCharacter()

	if not character then
		return
	end

	local okDesc, descendants = safe(function()
		return character:GetDescendants()
	end)

	if not okDesc or type(descendants) ~= "table" then
		return
	end

	for _, descendant in ipairs(descendants) do

		local okPart, isPart = safe(function()
			return descendant:IsA("BasePart")
		end)

		if okPart and isPart and descendant.Name ~= "HumanoidRootPart" then

			if enable then

				if originalPartPhysics[descendant] == nil then

					originalPartPhysics[descendant] = {
						massless = descendant.Massless,
						collide = descendant.CanCollide,
					}
				end

				safe(function()
					descendant.Massless = true
					descendant.CanCollide = false
				end)

			else

				local original = originalPartPhysics[descendant]

				if original then

					safe(function()
						descendant.Massless = original.massless
						descendant.CanCollide = original.collide
					end)

					originalPartPhysics[descendant] = nil
				end
			end
		end
	end
end

-- grok-v3's speed enforcer, used only while the flight is active.
local function enforceFlyWalkSpeed()

	local humanoid = getHumanoid()

	if not humanoid then
		return
	end

	if savedFlyWalkSpeed == nil then

		local ok, value = safe(function()
			return humanoid.WalkSpeed
		end)

		savedFlyWalkSpeed = ok and value or nil
	end

	safe(function()
		humanoid.WalkSpeed = CONFIG.FLY_RUN_WALKSPEED
	end)
end

local function restoreFlyWalkSpeed()

	local humanoid = getHumanoid()

	if humanoid and savedFlyWalkSpeed ~= nil then

		safe(function()
			humanoid.WalkSpeed = savedFlyWalkSpeed
		end)
	end

	savedFlyWalkSpeed = nil
end

-- Keeps the character on its feet for the whole flight: joints on, state
-- Running, no rollover. This is the pulse's steps 2-5 re-applied per frame.
local function keepOnFeet()

	local humanoid = getHumanoid()
	local character = getCharacter()

	if not humanoid or not character then
		return
	end

	local okDesc, descendants = safe(function()
		return character:GetDescendants()
	end)

	if okDesc and type(descendants) == "table" then

		for _, object in ipairs(descendants) do

			local okMotor, isMotor = safe(function()
				return object:IsA("Motor6D")
			end)

			if okMotor and isMotor then

				local okEnabled, enabled = safe(function()
					return object.Enabled
				end)

				if okEnabled and not enabled then

					safe(function()
						object.Enabled = true
					end)
				end
			end
		end
	end

	safe(function()
		humanoid.PlatformStand = false
	end)

	safe(function()
		humanoid.AutoRotate = true
	end)

	local okState, state = safe(function()
		return humanoid:GetState()
	end)

	if okState and (state == Enum.HumanoidStateType.Physics
		or state == Enum.HumanoidStateType.FallingDown
		or state == Enum.HumanoidStateType.GettingUp
		or state == Enum.HumanoidStateType.Ragdoll) then

		safe(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)

		safe(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end)
	end
end

--==================================================
-- TARGET RESOLUTION (grok-v3 order: snapshot first, workspace second)
--==================================================

local snapshotCache = nil

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

local function extractPosition(record)

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

-- grok-v3 reads the egg table from the read-only snapshot remote.
local function parseSnapshot(raw)

	local records = {}

	if type(raw) ~= "table" then
		return records
	end

	local source = raw.Records or raw.records

	if type(source) ~= "table" then
		return records
	end

	for _, record in pairs(source) do

		if type(record) == "table" then

			local position = extractPosition(record)
			local uid = record.Uid or record.uid or record.UID
				or record.Id or record.id
			local area = record.AreaId or record.areaId or record.Area
				or record.Biome or record.biome or record.AreaName
				or record.areaName or record.Zone or record.zone
			local category = record.AssetCategory or record.assetCategory
				or record.Category

			if position then

				records[#records + 1] = {
					Uid = tostring(uid or "?"),
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

	if not forceRefresh and snapshotCache then
		return snapshotCache
	end

	local remote = getRemote("RF/EggWorld/AskFieldEggSnapshot")

	if not remote then
		return {}
	end

	local ok, result = safe(function()
		return remote:InvokeServer()
	end)

	if ok and type(result) == "table" then
		snapshotCache = parseSnapshot(result)
	else
		snapshotCache = {}
	end

	return snapshotCache
end

local function isEggAvailable(egg)

	local carrier = egg.CarrierUserId

	return carrier == nil or carrier == 0 or carrier == ""
end

-- Exact match first (grok-v3 behaviour), then a looser contains match so
-- names like "Cosmic Realm" still resolve for "Cosmic".
local function matchBiome(eggArea, wanted)

	local area = string.lower(tostring(eggArea or ""))
	local target = string.lower(tostring(wanted or ""))

	if area == target then
		return true
	end

	if string.find(area, target, 1, true) then
		return true
	end

	if string.find(target, area, 1, true) and #area > 2 then
		return true
	end

	return false
end

local function biomeList(records)

	local seen, names = {}, {}

	for _, record in ipairs(records) do

		local name = tostring(record.AreaId)

		if not seen[name] then
			seen[name] = true
			names[#names + 1] = name
		end
	end

	table.sort(names)

	return names
end

-- Bounded workspace search: any container whose name mentions the biome
-- and an egg, in case the slot folder is named differently.
local function findInWorkspace(biome)

	local wanted = string.lower(tostring(biome or ""))

	local function partOf(container)

		local okPart, part = safe(function()
			return container:FindFirstChildWhichIsA("BasePart", true)
		end)

		return okPart and part or nil
	end

	local okArea, area = safe(function()
		return Workspace:FindFirstChild("AreaEggSlotsClient")
	end)

	if okArea and area then

		local okSlots, slots = safe(function()
			return area:GetChildren()
		end)

		if okSlots and type(slots) == "table" then

			for _, slot in ipairs(slots) do

				if matchBiome(slot.Name, biome) then

					local part = partOf(slot)

					if part then

						return {
							Uid = tostring(slot.Name),
							AreaId = tostring(biome),
							AssetCategory = tostring(slot.Name),
							Position = part.Position,
							Source = "AreaEggSlotsClient",
						}
					end
				end
			end
		end
	end

	-- bounded sweep for other egg folders (never a full workspace deep scan)
	local okChildren, children = safe(function()
		return Workspace:GetChildren()
	end)

	if not okChildren or type(children) ~= "table" then
		return nil
	end

	local visited = 0

	for _, child in ipairs(children) do

		local okDesc, descendants = safe(function()
			return child:GetDescendants()
		end)

		if okDesc and type(descendants) == "table" then

			for _, descendant in ipairs(descendants) do

				visited = visited + 1

				if visited > 20000 then
					return nil
				end

				local name = string.lower(tostring(descendant.Name))

				if string.find(name, wanted, 1, true)
					and string.find(name, "egg", 1, true) then

					local part = partOf(descendant)

					if part then

						return {
							Uid = tostring(descendant.Name),
							AreaId = tostring(biome),
							AssetCategory = tostring(descendant.Name),
							Position = part.Position,
							Source = "workspace (" .. tostring(child.Name) .. ")",
						}
					end
				end
			end
		end
	end

	return nil
end

local lastResolveInfo = nil

-- grok-v3 resolves from a FRESH snapshot, then falls back to the workspace.
local function resolveTarget(biome)

	local records = fetchSnapshot(true)

	for _, record in ipairs(records) do

		if matchBiome(record.AreaId, biome) and isEggAvailable(record) then

			lastResolveInfo = {
				found = true,
				from = "server snapshot",
				records = #records,
				biomes = biomeList(records),
			}

			return record
		end
	end

	local workspaceEgg = findInWorkspace(biome)

	if workspaceEgg then

		lastResolveInfo = {
			found = true,
			from = workspaceEgg.Source,
			records = #records,
			biomes = biomeList(records),
		}

		return workspaceEgg
	end

	lastResolveInfo = {
		found = false,
		from = "none",
		records = #records,
		biomes = biomeList(records),
	}

	return nil
end

--==================================================
-- FLIGHT (grok-v3 velocity mechanics, straight path)
--==================================================

local function neutraliseParts(enable)

	if not CONFIG.NEUTRALISE_PARTS then
		return
	end

	local character = getCharacter()

	if not character then
		return
	end

	local okDesc, descendants = safe(function()
		return character:GetDescendants()
	end)

	if not okDesc or type(descendants) ~= "table" then
		return
	end

	for _, descendant in ipairs(descendants) do

		local okPart, isPart = safe(function()
			return descendant:IsA("BasePart")
		end)

		if okPart and isPart and descendant.Name ~= "HumanoidRootPart" then

			if enable then

				if originalPartPhysics[descendant] == nil then

					originalPartPhysics[descendant] = {
						massless = descendant.Massless,
						collide = descendant.CanCollide,
					}
				end

				safe(function()
					descendant.Massless = true
					descendant.CanCollide = false
				end)

			else

				local original = originalPartPhysics[descendant]

				if original then

					safe(function()
						descendant.Massless = original.massless
						descendant.CanCollide = original.collide
					end)

					originalPartPhysics[descendant] = nil
				end
			end
		end
	end
end

local function enforceFlyWalkSpeed()

	local humanoid = getHumanoid()

	if not humanoid then
		return
	end

	if savedFlyWalkSpeed == nil then

		local ok, value = safe(function()
			return humanoid.WalkSpeed
		end)

		savedFlyWalkSpeed = ok and value or nil
	end

	safe(function()
		humanoid.WalkSpeed = CONFIG.FLY_RUN_WALKSPEED
	end)
end

local function restoreFlyWalkSpeed()

	local humanoid = getHumanoid()

	if humanoid and savedFlyWalkSpeed ~= nil then

		safe(function()
			humanoid.WalkSpeed = savedFlyWalkSpeed
		end)
	end

	savedFlyWalkSpeed = nil
end

-- Keeps the character on its feet for the whole flight: joints on, state
-- Running, no rollover and no ragdoll take-over.
local function keepOnFeet()

	local humanoid = getHumanoid()
	local character = getCharacter()

	if not humanoid or not character then
		return
	end

	local okDesc, descendants = safe(function()
		return character:GetDescendants()
	end)

	if okDesc and type(descendants) == "table" then

		for _, object in ipairs(descendants) do

			local okMotor, isMotor = safe(function()
				return object:IsA("Motor6D")
			end)

			if okMotor and isMotor then

				local okEnabled, enabled = safe(function()
					return object.Enabled
				end)

				if okEnabled and not enabled then

					safe(function()
						object.Enabled = true
					end)
				end
			end
		end
	end

	safe(function()
		humanoid.PlatformStand = false
	end)

	safe(function()
		humanoid.AutoRotate = true
	end)

	local okState, state = safe(function()
		return humanoid:GetState()
	end)

	if okState and (state == Enum.HumanoidStateType.Physics
		or state == Enum.HumanoidStateType.FallingDown
		or state == Enum.HumanoidStateType.GettingUp
		or state == Enum.HumanoidStateType.Ragdoll) then

		safe(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)

		safe(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end)
	end
end

local function endFlight(reason)

	if not isFlying then
		return
	end

	local flight = flightData
	local root = getRoot()

	isFlying = false
	flightData = nil
	lastFlightTime = os.clock()

	local travelled = 0
	local remaining = 0

	if root and flight then

		travelled = (root.Position - flight.launch).Magnitude
		remaining = (flight.landing - root.Position).Magnitude

		safe(function()
			root.AssemblyLinearVelocity = Vector3.zero
		end)

		safe(function()
			root.AssemblyAngularVelocity = Vector3.zero
		end)
	end

	restoreFlyWalkSpeed()
	neutraliseParts(false)

	local elapsed = flight and (os.clock() - flight.t0) or 0
	local average = elapsed > 0 and (travelled / elapsed) or 0

	note(string.format(
		"flight %s | flew %.0f studs in %.2fs (avg %.0f studs/s) | gap %.0f",
		reason or "ended",
		travelled,
		elapsed,
		average,
		remaining
	))

	setStatus(string.format(
		"%s | flew %.0f studs of %.0f in %.1fs | gap %.0f studs",
		(remaining <= CONFIG.ARRIVE_TOLERANCE) and "ARRIVED" or "TIME UP",
		travelled,
		flight and flight.distance or 0,
		CONFIG.FLIGHT_DURATION,
		remaining
	))
end

startFlight = function(reason)

	if isFlying or not scriptAlive then
		return false
	end

	local root = getRoot()
	local humanoid = getHumanoid()

	if not root or not humanoid then

		setStatus("No character to fly with.")

		return false
	end

	local okHealth, health = safe(function()
		return humanoid.Health
	end)

	if okHealth and health <= 0 then

		setStatus("Character is dead; not flying.")

		return false
	end

	local target = resolveTarget(CONFIG.FLIGHT_BIOME)

	if not target then

		local info = lastResolveInfo or {}

		local biomes = info.biomes and #info.biomes > 0
			and table.concat(info.biomes, ", ")
			or "none"

		local message = string.format(
			"No %s target. snapshot: %d record(s), biomes seen: %s",
			tostring(CONFIG.FLIGHT_BIOME),
			info.records or 0,
			biomes
		)

		note(message)
		setStatus(message)

		return false
	end

	local landing = target.Position + Vector3.new(0, CONFIG.TARGET_Y_OFFSET, 0)

	local started = os.clock()
	local distance = (landing - root.Position).Magnitude

	-- grok-v3 clamps at AERIAL_SPEED * 1.5. For a target farther than
	-- AERIAL_SPEED * FLIGHT_DURATION that clamp is scaled up, otherwise a
	-- distant biome (Cosmic) could never be reached in the flight time.
	local grokClamp = CONFIG.AERIAL_SPEED * CONFIG.GROK_CLAMP_FACTOR
	local neededAverage = distance / CONFIG.FLIGHT_DURATION
	local clampSpeed = math.max(grokClamp, neededAverage * CONFIG.GROK_CLAMP_FACTOR)

	isFlying = true
	flightToken = flightToken + 1

	flightData = {
		token = flightToken,
		launch = root.Position,
		landing = landing,
		t0 = started,
		duration = CONFIG.FLIGHT_DURATION,
		distance = distance,
		clampSpeed = clampSpeed,
		peakArc = 0,                      -- straight flight: no arc
		source = target.Source,
	}

	keepOnFeet()
	enforceFlyWalkSpeed()
	neutraliseParts(true)

	note(string.format(
		"flight started to %s (%s) | %.0f studs | clamp %.0f | %.1fs | %s",
		tostring(CONFIG.FLIGHT_BIOME),
		tostring(target.Source),
		distance,
		clampSpeed,
		CONFIG.FLIGHT_DURATION,
		tostring(reason or "manual")
	))

	setStatus(string.format(
		"FLYING straight to %s | %.0f studs | 1.6s",
		tostring(CONFIG.FLIGHT_BIOME),
		distance
	))

	return true
end

-- One frame of flight. This is grok-v3's own formula: walk a waypoint
-- forward along the path by one frame and set the velocity that reaches it
-- in exactly that frame, clamped. peakArc is 0 so the path is straight.
local function flightStep(dt)

	if not isFlying or not flightData then
		return
	end

	local flight = flightData
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

	keepOnFeet()
	enforceFlyWalkSpeed()

	dt = math.max(dt or 0, 0.001)

	local elapsed = os.clock() - flight.t0
	local prog = math.clamp(elapsed / flight.duration, 0, 1)

	local nextProg = math.clamp((elapsed + math.max(dt, 0.016)) / flight.duration, 0, 1)
	local arcY = flight.peakArc * math.sin(nextProg * math.pi)
	local waypoint = flight.launch:Lerp(flight.landing, nextProg)
		+ Vector3.new(0, arcY, 0)

	local neededVel = (waypoint - root.Position) / dt

	if neededVel.Magnitude > flight.clampSpeed then
		neededVel = neededVel.Unit * flight.clampSpeed
	end

	if CONFIG.SPEED_LIMIT and neededVel.Magnitude > CONFIG.SPEED_LIMIT then
		neededVel = neededVel.Unit * CONFIG.SPEED_LIMIT
	end

	safe(function()
		root.AssemblyLinearVelocity = neededVel
	end)

	safe(function()
		root.AssemblyAngularVelocity = Vector3.zero
	end)

	-- grok-v3 ends here; this build flies the full configured time
	if prog >= 1 then
		endFlight("1.6s elapsed")
	end
end

--==================================================
-- HEARTBEAT: flight first, then the recovery pulse
--==================================================

connect(game:GetService("RunService").Heartbeat, function(dt)

	if not scriptAlive then
		return
	end

	if isFlying then
		flightStep(dt)
		return
	end

	if not pulseEnabled then
		return
	end

	local humanoid = getHumanoid()
	local character = getCharacter()

	if not humanoid or not character then
		return
	end

	if getRagdollReason() then
		recoveryPulse(humanoid, character)
	end
end)

-- Starts the flight once a pulse has finished restoring control.
flyAfterPulseIfReady = function()

	if not flyAfterPulse or isFlying or not scriptAlive then
		return false
	end

	if os.clock() - lastFlightTime < CONFIG.FLIGHT_COOLDOWN then
		return false
	end

	return startFlight("after pulse")
end

--==================================================
-- WALK TO THE EGG
--==================================================

local function stopWalking(message, restore)

	walking = false
	walkToken = walkToken + 1

	local humanoid = getHumanoid()
	local root = getRoot()

	if humanoid and root then

		-- stop the move intent without writing any position
		safe(function()
			humanoid:MoveTo(root.Position)
		end)
	end

	if restore and CONFIG.WALK_RESTORE_SPEED and savedWalkSpeed ~= nil then

		if humanoid then

			safe(function()
				humanoid.WalkSpeed = savedWalkSpeed
			end)
		end

		savedWalkSpeed = nil
	end

	if walkButton then
		walkButton.Text = "WALK TO FOREST EGG"
	end

	if message then
		setStatus(message)
	end
end

local function walkToForestEgg()

	if walking then

		stopWalking("Walk stopped.", true)

		return
	end

	local egg = getForestEgg()

	if not egg then

		setStatus("No Forest egg found (no workspace slot, snapshot empty).")

		return
	end

	local humanoid = getHumanoid()
	local root = getRoot()

	if not humanoid or not root then

		setStatus("No character to walk with.")

		return
	end

	walkToken = walkToken + 1

	local token = walkToken

	walking = true

	if walkButton then
		walkButton.Text = "STOP WALKING"
	end

	if savedWalkSpeed == nil then

		local ok, value = safe(function()
			return humanoid.WalkSpeed
		end)

		savedWalkSpeed = ok and value or nil
	end

	safe(function()
		humanoid.WalkSpeed = CONFIG.WALK_SPEED
	end)

	note(string.format(
		"walking to %s (%s) at (%.0f, %.0f)",
		tostring(egg.Uid),
		tostring(egg.Source),
		egg.Position.X,
		egg.Position.Z
	))

	task.spawn(function()

		local started = os.clock()
		local lastRetarget = 0
		local lastPosition = nil
		local stalledSince = nil

		while scriptAlive and walking and token == walkToken do

			local currentHumanoid = getHumanoid()
			local currentRoot = getRoot()

			if not currentHumanoid or not currentRoot then
				stopWalking("Character unavailable; walk cancelled.", true)
				return
			end

			-- Do not fight a ragdoll; let the pulse deal with it.
			if not getRagdollReason() then

				local delta = egg.Position - currentRoot.Position
				local flat = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)

				if flat <= CONFIG.WALK_ARRIVE_DIST then

					stopWalking(string.format(
						"Arrived at %s (%.1f studs away). Ready to pick up.",
						tostring(egg.Uid),
						flat
					), true)

					return
				end

				local now = os.clock()

				if now - lastRetarget >= CONFIG.WALK_RETARGET then

					lastRetarget = now

					safe(function()
						currentHumanoid:MoveTo(egg.Position)
					end)
				end

				-- progress reporting
				if lastPosition then

					local moved = (currentRoot.Position - lastPosition).Magnitude

					if moved < 0.15 then

						if not stalledSince then
							stalledSince = now
						end

						if now - stalledSince > 2.5 then

							stopWalking(
								"Walk is not making progress (server may be "
									.. "holding the character). Stopped.",
								true
							)

							return
						end
					else
						stalledSince = nil
					end
				end

				lastPosition = currentRoot.Position

				setStatus(string.format(
					"Walking to %s ... %.0f studs left",
					tostring(egg.Uid),
					flat
				))
			end

			if os.clock() - started >= CONFIG.WALK_TIMEOUT then

				stopWalking("Walk timed out.", true)

				return
			end

			task.wait(0.05)
		end
	end)
end

--==================================================
-- PICKUP
--==================================================

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

			-- Only real Tools count. Matching on the word "egg" alone made
			-- decorative parts that merely have "egg" in the name look like a
			-- carried egg.
			if okTool and isTool
				and not string.find(name, "trap", 1, true) then

				return true
			end
		end
	end

	-- the game's own flag, when it publishes one
	if LocalPlayer:GetAttribute("IsCarrying") == true then
		return true
	end

	return false
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

		for _, descendant in ipairs(Workspace:GetDescendants()) do

			if descendant:IsA("ProximityPrompt") then

				local part = descendant.Parent

				if part and part:IsA("BasePart")
					and (part.Position - origin).Magnitude <= CONFIG.PROMPT_RADIUS then

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

local function pickUpEgg()

	if isHoldingEgg() then

		setStatus("Already holding an egg.")

		return
	end

	local egg = getForestEgg()

	if not egg then

		setStatus("No Forest egg found to pick up.")

		return
	end

	local character = getCharacter()

	if not character then

		setStatus("No character.")

		return
	end

	-- Arm the recovery pulse the moment the pickup is triggered.
	if CONFIG.PULSE_AUTO_ARM and not pulseEnabled then

		pulseEnabled = true

		if pulseButton then
			pulseButton.Text = "RECOVERY PULSE: ON"
			pulseButton.BackgroundColor3 = Color3.fromRGB(40, 84, 56)
		end

		note("recovery pulse armed by pickup")
	end

	local remote = getRemote(REMOTE_CARRY)

	if not remote then

		setStatus("Carry remote not found (ReplicatedStorage.Packages.Networking).")

		return
	end

	pickupCount = pickupCount + 1

	note(string.format(
		"pickup attempt #%d on %s",
		pickupCount,
		tostring(egg.Uid)
	))

	local started = os.clock()

	task.spawn(function()

		local attempts = 0

		while scriptAlive and os.clock() - started < CONFIG.PICKUP_BURST do

			if isHoldingEgg() then

				setStatus("Picked up " .. tostring(egg.Uid) .. ".")

				note("holding: " .. tostring(egg.Uid))

				return
			end

			if getRagdollReason() then

				setStatus("Ragdoll during pickup - the pulse is handling it.")

			end

			attempts = attempts + 1

			task.spawn(function()

				safe(function()
					remote:InvokeServer({ Uid = tostring(egg.Uid) })
				end)
			end)

			triggerEggPrompts()
			touchEggHitbox(egg.Uid)

			task.wait(CONFIG.PICKUP_INTERVAL)
		end

		if not isHoldingEgg() then

			setStatus(string.format(
				"Pickup not confirmed after %d attempts (the game decides).",
				attempts
			))

			note("pickup unconfirmed after " .. tostring(attempts) .. " attempts")
		end
	end)
end

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

local function refreshPulseButton()

	if not pulseButton then
		return
	end

	pulseButton.Text = "RECOVERY PULSE: " .. (pulseEnabled and "ON" or "OFF")
	pulseButton.BackgroundColor3 = pulseEnabled
		and Color3.fromRGB(40, 84, 56)
		or Color3.fromRGB(38, 48, 66)
end

local function buildGui()

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "SimpleRecoveryUI"
	gui.ResetOnSpawn = false
	gui.Parent = playerGui or LocalPlayer:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Main"
	frame.Size = UDim2.new(0, 430, 0, 268)
	frame.Position = UDim2.new(0, 40, 0, 110)
	frame.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Text = "Simple Recovery UI  -  walk, pick up, recover"
	title.Size = UDim2.new(1, -12, 0, 22)
	title.Position = UDim2.new(0, 6, 0, 4)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(210, 230, 250)
	title.TextSize = 13
	title.Font = Enum.Font.SourceSansBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = frame

	frame.Size = UDim2.new(0, 430, 0, 300)

	walkButton = makeButton(frame, "WALK TO FOREST EGG", 6, 30, 200, 26)
	pickupButton = makeButton(frame, "PICK UP EGG", 212, 30, 120, 26)
	pickupButton.BackgroundColor3 = Color3.fromRGB(32, 74, 116)

	autoButton = makeButton(frame, "WALK + PICK UP", 338, 30, 86, 26)
	pulseButton = makeButton(frame, "RECOVERY PULSE: OFF", 6, 62, 200, 26)
	refreshPulseButton()

	local speedLabel = Instance.new("TextLabel")
	speedLabel.Name = "SpeedLabel"
	speedLabel.Text = "Walk speed:"
	speedLabel.Size = UDim2.new(0, 70, 0, 26)
	speedLabel.Position = UDim2.new(0, 212, 0, 62)
	speedLabel.BackgroundTransparency = 1
	speedLabel.TextColor3 = Color3.fromRGB(180, 190, 205)
	speedLabel.TextSize = 12
	speedLabel.Font = Enum.Font.SourceSans
	speedLabel.TextXAlignment = Enum.TextXAlignment.Right
	speedLabel.Parent = frame

	speedBox = Instance.new("TextBox")
	speedBox.Name = "SpeedBox"
	speedBox.Text = tostring(CONFIG.WALK_SPEED)
	speedBox.Size = UDim2.new(0, 60, 0, 26)
	speedBox.Position = UDim2.new(0, 286, 0, 62)
	speedBox.BackgroundColor3 = Color3.fromRGB(28, 33, 44)
	speedBox.TextColor3 = Color3.fromRGB(230, 236, 245)
	speedBox.TextSize = 13
	speedBox.Font = Enum.Font.Code
	speedBox.ClearTextOnFocus = false
	speedBox.Parent = frame

	local closeButton = makeButton(frame, "CLOSE", 350, 62, 74, 26)
	closeButton.BackgroundColor3 = Color3.fromRGB(96, 40, 44)

	-- flight row
	biomeButton = makeButton(frame, "TARGET BIOME: [Snow]", 6, 94, 200, 26)

	local flyButton = makeButton(frame, "FLY NOW (1.6s)", 212, 94, 120, 26)
	flyButton.BackgroundColor3 = Color3.fromRGB(32, 74, 116)

	flyAfterButton = makeButton(frame, "AUTO FLY: ON", 338, 94, 86, 26)
	flyAfterButton.TextSize = 11

	statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.Text = "Ready. Walk to the forest egg, then pick it up."
	statusLabel.Size = UDim2.new(1, -12, 0, 34)
	statusLabel.Position = UDim2.new(0, 6, 0, 126)
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
	logLabel.Size = UDim2.new(1, -12, 0, 130)
	logLabel.Position = UDim2.new(0, 6, 0, 164)
	logLabel.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
	logLabel.TextColor3 = Color3.fromRGB(200, 208, 220)
	logLabel.TextSize = 11
	logLabel.Font = Enum.Font.Code
	logLabel.TextWrapped = true
	logLabel.TextXAlignment = Enum.TextXAlignment.Left
	logLabel.TextYAlignment = Enum.TextYAlignment.Top
	logLabel.Parent = frame

	-- drag by the title bar
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

	connect(speedBox.FocusLost, function()

		local value = tonumber(speedBox.Text)

		if value and value == value and value > 0 and value <= 2000 then

			CONFIG.WALK_SPEED = value

		else
			speedBox.Text = tostring(CONFIG.WALK_SPEED)
		end
	end)

	connect(walkButton.MouseButton1Click, function()
		walkToForestEgg()
	end)

	connect(pickupButton.MouseButton1Click, function()
		pickUpEgg()
	end)

	connect(autoButton.MouseButton1Click, function()

		if walking or isHoldingEgg() then
			setStatus("Already walking or already holding an egg.")
			return
		end

		walkToForestEgg()
		setStatus("Walking... pickup will follow automatically.")

		task.spawn(function()

			local token = walkToken
			local started = os.clock()

			while scriptAlive and walking and token == walkToken
				and os.clock() - started < CONFIG.WALK_TIMEOUT + 5 do

				task.wait(0.1)
			end

			if scriptAlive and not walking and not isHoldingEgg() then
				pickUpEgg()
			end
		end)
	end)

	connect(pulseButton.MouseButton1Click, function()

		pulseEnabled = not pulseEnabled
		refreshPulseButton()

		note("recovery pulse " .. (pulseEnabled and "ON" or "OFF"))
	end)

	connect(biomeButton.MouseButton1Click, function()

		local biomes = {
			"Snow", "Jungle", "Desert", "Ocean", "Volcano", "Abyss Ocean",
			"Prehistoric", "Cosmic", "Cherry Blossom", "Titan", "Light Dark",
		}

		local index = 1

		for position, name in ipairs(biomes) do

			if name == CONFIG.FLIGHT_BIOME then
				index = position
				break
			end
		end

		CONFIG.FLIGHT_BIOME = biomes[(index % #biomes) + 1]
		biomeButton.Text = "TARGET BIOME: [" .. CONFIG.FLIGHT_BIOME .. "]"
	end)

	connect(flyButton.MouseButton1Click, function()

		if isFlying then
			setStatus("Already flying.")
		else
			startFlight("manual")
		end
	end)

	connect(flyAfterButton.MouseButton1Click, function()

		flyAfterPulse = not flyAfterPulse

		flyAfterButton.Text = flyAfterPulse and "AUTO FLY: ON" or "AUTO FLY: OFF"
		flyAfterButton.BackgroundColor3 = flyAfterPulse
			and Color3.fromRGB(40, 84, 56)
			or Color3.fromRGB(38, 48, 66)
	end)

	flyAfterButton.Text = flyAfterPulse and "AUTO FLY: ON" or "AUTO FLY: OFF"
	flyAfterButton.BackgroundColor3 = flyAfterPulse
		and Color3.fromRGB(40, 84, 56)
		or Color3.fromRGB(38, 48, 66)

	connect(closeButton.MouseButton1Click, function()
		stopEverything("closed by user")
	end)
end

--==================================================
-- CHARACTER LIFECYCLE
--==================================================

connect(LocalPlayer.CharacterAdded, function(character)

	note("character respawned")

	walking = false
	walkToken = walkToken + 1
	savedWalkSpeed = nil

	if walkButton then
		walkButton.Text = "WALK TO FOREST EGG"
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
	walking = false
	walkToken = walkToken + 1
	pulseEnabled = false
	pulseActive = false

	if isFlying then

		isFlying = false
		flightData = nil

		local root = getRoot()

		if root then

			safe(function()
				root.AssemblyLinearVelocity = Vector3.zero
			end)

			safe(function()
				root.AssemblyAngularVelocity = Vector3.zero
			end)
		end

		restoreFlyWalkSpeed()
		neutraliseParts(false)
	end

	local humanoid = getHumanoid()

	if humanoid and savedWalkSpeed ~= nil then

		safe(function()
			humanoid.WalkSpeed = savedWalkSpeed
		end)
	end

	savedWalkSpeed = nil

	disconnectAll()

	if gui then

		safe(function()
			gui:Destroy()
		end)

		gui = nil
	end

	if _G.SIMPLE_RECOVERY_UI
		and _G.SIMPLE_RECOVERY_UI.stop == stopEverything then

		_G.SIMPLE_RECOVERY_UI = nil
	end

	print("[Simple Recovery UI] stopped (" .. tostring(reason or "?") .. ")")
end

--==================================================
-- START
--==================================================

do

	local previous = _G.SIMPLE_RECOVERY_UI

	if type(previous) == "table" and type(previous.stop) == "function" then

		safe(function()
			previous.stop("replaced by a newer run")
		end)
	end
end

safe(buildGui)

note("ready (read/write scope: humanoid move + joints/state only)")

_G.SIMPLE_RECOVERY_UI = {
	version = "1.0",
	config = CONFIG,
	stop = stopEverything,
	walk = walkToForestEgg,
	stopWalking = function()
		stopWalking("Walk stopped.", true)
	end,
	pickUp = pickUpEgg,
	setPulse = function(enabled)

		pulseEnabled = enabled and true or false
		refreshPulseButton()
	end,
	pulse = function()
		return {
			enabled = pulseEnabled,
			active = pulseActive,
			count = pulseCount,
		}
	end,
	forcePulse = function()

		local humanoid = getHumanoid()
		local character = getCharacter()

		if humanoid and character then
			recoveryPulse(humanoid, character)
		end
	end,
	fly = startFlight,
	-- shows what the resolver can actually see right now
	diagnose = function()

		local records = fetchSnapshot(true)
		local names = biomeList(records)

		return {
			biome = CONFIG.FLIGHT_BIOME,
			snapshotRecords = #records,
			snapshotBiomes = names,
			resolved = resolveTarget(CONFIG.FLIGHT_BIOME) ~= nil,
			info = lastResolveInfo,
		}
	end,
	setFlyAfterPulse = function(enabled)

		flyAfterPulse = enabled and true or false

		if flyAfterButton then
			flyAfterButton.Text = flyAfterPulse and "AUTO FLY: ON" or "AUTO FLY: OFF"
		end
	end,
	setBiome = function(name)

		CONFIG.FLIGHT_BIOME = tostring(name)

		if biomeButton then
			biomeButton.Text = "TARGET BIOME: [" .. CONFIG.FLIGHT_BIOME .. "]"
		end
	end,
	flight = function()

		return {
			flying = isFlying,
			autoFly = flyAfterPulse,
			biome = CONFIG.FLIGHT_BIOME,
			duration = CONFIG.FLIGHT_DURATION,
			count = flightToken,
		}
	end,
	status = function()
		return statusLabel and statusLabel.Text or ""
	end,
	logText = function()

		local lines = {}

		for _, entry in ipairs(log) do
			lines[#lines + 1] = string.format("[%7.2fs] %s", entry.t % 1000, entry.text)
		end

		return table.concat(lines, "\n")
	end,
	-- raw entries ({ t = os.clock(), text = ... }) for timing checks
	log = function()
		return log
	end,
	state = function()

		return {
			alive = scriptAlive,
			walking = walking,
			holding = isHoldingEgg(),
			pulseEnabled = pulseEnabled,
			pulseCount = pulseCount,
			ragdollReason = getRagdollReason(),
		}
	end,
	target = function()

		local egg = getForestEgg()

		if not egg then
			return nil
		end

		return {
			Uid = egg.Uid,
			Source = egg.Source,
			X = egg.Position.X,
			Y = egg.Position.Y,
			Z = egg.Position.Z,
		}
	end,
}
