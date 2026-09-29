--[[=========================================================================
	GROK-V3 FORWARD FLIGHT + OPTIONAL TEST CONTROLS v6.8
	+ Simple button: fly 1000 studs forward using Grok-v3 AssemblyLinearVelocity
	+ New forward flight is independent of eggs, biomes, boss hits and ragdoll
	+ Existing Snow/legacy CFrame tests remain available under Other controls
	+ Snow flight stays velocity-only; separate manual test uses chunked CFrame
	+ Planned travel <=1.5s, travel cutoff 1.9s; no false arrival on timeout
	+ No boss wait, no ragdoll prerequisite and no automatic egg drop
	+ No forced humanoid states, joint edits, anchoring or PlatformStand writes

	Reference: origin/main grok-v3-target-fix.lua (a7b5ecd), read-only.
	Ports its next-frame sine arc, 500 WalkSpeed enforcement, carried-part
	neutralization, zero-friction, dead-zone hold and final velocity settle.
	Ragdoll is supported, never required. Boss wait and bait drop are omitted.
	Retains explicit arrival/cutoff checks instead of assuming progress=1 means
	arrival. This port does not establish that server corrections are resolved.
	Its 750 studs/s is a baseline, not a sub-two-second guarantee: derive the
	command speed from route length and the capped duration for this test.
	The egg is kept carried; reaching Forest is not a delivery acknowledgement.
	Runtime game corrections can still prevent arrival; copy diagnostics.
	Manual snap defaults: 10 studs/chunk, 1000 studs total, 0.05s interval.
	Forward means the horizontal character-facing direction captured at Start.
	Each manual-forward write is at most one chunk; no rollback catch-up.
	Separate Old CFrame → Forest control ports main's v6.0 profile: 78-stud
	steps, five-frame rise to Y=112.5, three-frame descent to (612,74,-325).
	Both manual controls skip egg pickup and share Emergency Stop. Legacy
	timeout/cancellation never performs the old unconditional final teleport.
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

local selectedBiome       = "Snow" -- deliberately locked for this test
local dynamicBaseWalkSpeed = 16.0
local FOREST_LANDING      = Vector3.new(612.2, 70.7, -325.0)

local RUN_WALKSPEED       = 500 -- reference flight/hold speed enforcer, not approach
local AERIAL_BASE_SPEED   = 750
local MIN_ARC_DURATION    = 0.35
local MAX_ARC_DURATION    = 1.5
local FLIGHT_CUTOFF_S     = 1.9 -- travel only, never extended by corrections
local MIN_HOLD_S          = 0.85
local MAX_HOLD_S          = 3.5
local HOLD_DEAD_ZONE      = 1.2
local FINAL_SETTLE_S      = 0.20
local ARRIVAL_RADIUS      = 5.5
local CARRY_TIMEOUT_S     = 3
local REMOTE_TIMEOUT_S    = 3
local FLIGHT_ANIM_ID      = "rbxassetid://102039335618606"

local MANUAL_FLIGHT_DISTANCE = 1000
local LEGACY_STEP_SIZE    = 78
local LEGACY_CRUISE_Y     = 112.5
local LEGACY_TIMEOUT_S    = 2.5
local LEGACY_LANDING      = Vector3.new(612, 74, -325) -- main: FOREST_LANDING.Y + 3
local SNAP_MAX_STEPS      = 10000
local SNAP_TIMEOUT_S      = 300
local GUI_NAME            = "GrokEscapeFlightV6"

local currentToken        = 0
local isRunning           = false
local isFlying            = false
local cachedSnapshot      = nil
local runCharacter        = nil
local flightTrack         = nil
local flightRoot          = nil
local originalPhysicalProperties = {}
local originalCarriedProperties = {}
local legacyCollisions = {}
local flightSpeedConnection = nil
local flightSpeedChangedConnection = nil
local updatingFlightSpeed = false
local zeroFriction = PhysicalProperties.new(0.7, 0, 0, 100, 100)

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

-- Separate the small, high-level run log from a rolling flight-frame tail so
-- high FPS cannot evict the target, carry timing or final abort explanation.
local diagnosticLines = {}
local flightSamples = {}
local MAX_DIAGNOSTIC_LINES = 200
local MAX_FLIGHT_SAMPLES = 24

local function traceRun(tag, message)
	local wallTime = os.date and os.date("%H:%M:%S") or "clock"
	local line = string.format("[Steal-Pipeline v6.8] %s t=%.3f run=%d %s | %s",
		wallTime, os.clock(), currentToken, tag, message)
	table.insert(diagnosticLines, line)
	if #diagnosticLines > MAX_DIAGNOSTIC_LINES then table.remove(diagnosticLines, 1) end
	print(line)
end

local function sampleFlight(phase, dt, root, hum, commandedVelocity, destination)
	local pos, vel = root.Position, root.AssemblyLinearVelocity
	local state = hum:GetState()
	local line = string.format(
		"t=%.3f %s dt=%.4f pos=(%.1f,%.1f,%.1f) remaining=%.1f state=%s floor=%s anchored=%s platform=%s vel=(%.1f,%.1f,%.1f) command=(%.1f,%.1f,%.1f)",
		os.clock(), phase, dt, pos.X, pos.Y, pos.Z, horizontalDistance(pos, destination or FOREST_LANDING), state.Name,
		tostring(hum.FloorMaterial), tostring(root.Anchored), tostring(hum.PlatformStand), vel.X, vel.Y, vel.Z,
		commandedVelocity.X, commandedVelocity.Y, commandedVelocity.Z)
	table.insert(flightSamples, line)
	if #flightSamples > MAX_FLIGHT_SAMPLES then table.remove(flightSamples, 1) end
end

local function getDiagnosticsText()
	return table.concat(diagnosticLines, "\n") .. "\n\nLAST VELOCITY FLIGHT OBSERVATIONS:\n"
		.. table.concat(flightSamples, "\n")
end

----------------------------------------------------------------
-- REVERSIBLE FLIGHT FRICTION / CLEANUP
----------------------------------------------------------------

local function applyFlightFriction()
	for _, part in ipairs(runCharacter:GetDescendants()) do
		if part:IsA("BasePart") then
			if originalPhysicalProperties[part] == nil then
				-- A wrapper preserves nil/default material properties correctly.
				originalPhysicalProperties[part] = { value = part.CustomPhysicalProperties }
			end
			part.CustomPhysicalProperties = zeroFriction
		end
	end
end

-- Port of neutraliseEggPhysics from the reference. Record every touched part
-- so default values, false collision flags and reparented eggs restore exactly.
local function neutraliseEggPhysics(char)
	local function neutralise(part)
		if originalCarriedProperties[part] == nil then
			originalCarriedProperties[part] = { massless = part.Massless, collide = part.CanCollide }
		end
		part.Massless = true
		part.CanCollide = false
	end
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Parent ~= char then
			neutralise(part)
		end
	end
	local assets = Workspace:FindFirstChild("ClientRenderedAssets")
	if assets then
		local ownerToken = "%f[%d]" .. tostring(LocalPlayer.UserId) .. "%f[%D]"
		for _, model in ipairs(assets:GetChildren()) do
			-- Same player-named rendered assets as the reference, but match a
			-- complete numeric ID rather than a substring of another player's ID.
			if model.Name:find(ownerToken) then
				for _, part in ipairs(model:GetDescendants()) do
					if part:IsA("BasePart") then neutralise(part) end
				end
			end
		end
	end
end

local function enforceFlightSpeed(myToken)
	local _, hum = getRunRig(myToken)
	if hum and not updatingFlightSpeed and math.abs(hum.WalkSpeed - RUN_WALKSPEED) > 0.1 then
		updatingFlightSpeed = true
		local ok, err = pcall(function() hum.WalkSpeed = RUN_WALKSPEED end)
		updatingFlightSpeed = false
		if not ok then error(err) end
	end
end

local function startFlightSpeedEnforcer(myToken, hum)
	flightSpeedChangedConnection = hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		enforceFlightSpeed(myToken)
	end)
	flightSpeedConnection = RunService.Heartbeat:Connect(function()
		enforceFlightSpeed(myToken)
	end)
	enforceFlightSpeed(myToken)
end

local function cleanupRun()
	-- Disconnect first, otherwise restoration would trigger the enforcer.
	if flightSpeedChangedConnection then flightSpeedChangedConnection:Disconnect(); flightSpeedChangedConnection = nil end
	if flightSpeedConnection then flightSpeedConnection:Disconnect(); flightSpeedConnection = nil end
	updatingFlightSpeed = false
	for part, original in pairs(originalCarriedProperties) do
		pcall(function() part.Massless = original.massless; part.CanCollide = original.collide end)
		originalCarriedProperties[part] = nil
	end
	-- Legacy noclip is applied before carried-part neutralization, so restore
	-- its original collision values last (including false/noncolliding roots).
	for part, original in pairs(legacyCollisions) do
		pcall(function() part.CanCollide = original end)
		legacyCollisions[part] = nil
	end
	for part, original in pairs(originalPhysicalProperties) do
		pcall(function() part.CustomPhysicalProperties = original.value end)
		originalPhysicalProperties[part] = nil
	end
	if flightRoot then
		pcall(function()
			flightRoot.AssemblyLinearVelocity = Vector3.zero
			flightRoot.AssemblyAngularVelocity = Vector3.zero
		end)
		flightRoot = nil
	end
	if flightTrack then
		pcall(function() flightTrack:Stop(0.1); flightTrack:Destroy() end)
		flightTrack = nil
	end
	isFlying = false
	restoreBaseSpeed()
	local hum = runCharacter and runCharacter:FindFirstChildOfClass("Humanoid")
	local root = runCharacter and runCharacter:FindFirstChild("HumanoidRootPart")
	if hum and root then
		pcall(function() hum:Move(Vector3.zero); hum:MoveTo(root.Position) end)
	end
end

local function stopRun(reason)
	if isRunning then traceRun("STOP", reason or "Emergency Stop") end
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
	local startedAt = os.clock()
	local function report(outcome)
		if myToken and currentToken == myToken and isRunning then
			traceRun("REMOTE", string.format("%s %s elapsed=%.3fs", subPath, outcome, os.clock() - startedAt))
		end
	end
	local rf = getRemote(subPath)
	if not rf then report("missing"); return false, nil end
	if myToken and not getRunRig(myToken) then return false, nil end
	local request = pendingRemotes[subPath]
	if request and subPath ~= "RF/EggWorld/AskFieldEggSnapshot" then
		report("already pending")
		return false, nil
	end
	report(request and "waiting on pending request" or "request started")
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
		if confirmedWhileWaiting and confirmedWhileWaiting() then
			report("target UID replicated before response")
			return true, nil
		end
		if os.clock() >= deadline then report("timed out"); return false, nil end
		RunService.Heartbeat:Wait()
	end
	if myToken and not getRunRig(myToken) then return false, nil end
	report(request.ok and ("response type=" .. typeof(request.result) .. (request.result == false and " (false)" or ""))
		or "invocation failed")
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
-- OPTIONAL POST-ARRIVAL RAGDOLL CHECK / PURE ASSEMBLY VELOCITY ARC
----------------------------------------------------------------

local function serverNow()
	local ok, value = pcall(function() return Workspace:GetServerTimeNow() end)
	return ok and value or os.time()
end

local function ragdollTimerExpired()
	local endTime = LocalPlayer:GetAttribute("RagdollEndTime")
	return typeof(endTime) ~= "number" or endTime <= 0 or serverNow() >= endTime + 0.15
end

local function executeReferenceVelocityFlight(myToken, landingPos, routeName)
	local root, hum, reason = getRunRig(myToken)
	if not root then return false, reason end
	if root.Anchored then return false, "Character is anchored" end

	isFlying = true
	flightRoot = root
	applyFlightFriction()
	neutraliseEggPhysics(runCharacter)
	startFlightSpeedEnforcer(myToken, hum)
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

	table.clear(flightSamples)
	local launchFrom = root.Position
	local distance = horizontalDistance(launchFrom, landingPos)
	local duration = math.clamp(distance / AERIAL_BASE_SPEED, MIN_ARC_DURATION, MAX_ARC_DURATION)
	local speedLimit = math.max(AERIAL_BASE_SPEED, (landingPos - launchFrom).Magnitude / duration) * 1.5
	local peakArc = math.clamp(distance * 0.035, 8, 26)
	local startedAt = os.clock()
	local command = Vector3.zero
	local peakObservedY = launchFrom.Y
	local nextProgressLog = 0
	traceRun("FLIGHT_START", string.format("route=%s mode=GROK_V3_ARC distance=%.1f planned=%.3fs cutoff=%.2fs speedCap=%.1f",
		routeName, distance, duration, FLIGHT_CUTOFF_S, speedLimit))

	while true do
		local dt = RunService.Heartbeat:Wait()
		root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		local elapsed = os.clock() - startedAt
		peakObservedY = math.max(peakObservedY, root.Position.Y)
		sampleFlight("ARC", dt, root, hum, command, landingPos)
		if elapsed >= nextProgressLog then
			nextProgressLog = elapsed + 0.25
			traceRun("ARC_PROGRESS", string.format("elapsed=%.3fs remaining=%.1f y=%.1f peakY=%.1f walkSpeed=%.1f",
				elapsed, horizontalDistance(root.Position, landingPos), root.Position.Y, peakObservedY, hum.WalkSpeed))
		end
		if root.Anchored then return false, "Character anchored during arc" end
		-- Do not mistake scheduled progress=1 for arrival. A late frame or
		-- position reset fails the timing test instead of extending the flight.
		if elapsed >= FLIGHT_CUTOFF_S then
			return false, "Sub-2s arc missed destination; no teleport fallback"
		end
		if (landingPos - root.Position).Magnitude <= ARRIVAL_RADIUS and elapsed >= 0.25 then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			traceRun("FLIGHT_ARRIVED", string.format("travel=%.3fs error=%.2f rise=%.1f; stabilization begins separately",
				elapsed, (landingPos - root.Position).Magnitude, peakObservedY - launchFrom.Y))
			return true
		end

		applyFlightFriction()
		neutraliseEggPhysics(runCharacter)
		enforceFlightSpeed(myToken)
		-- Direct port of grok-v3-target-fix.lua's flight calculation: its
		-- look-ahead floor and velocity divisor are deliberately different.
		-- No added gravity term or 0.1s dt clamp from the previous adaptation.
		local nextProgress = math.clamp((elapsed + math.max(dt, 0.016)) / duration, 0, 1)
		local arcY = peakArc * math.sin(nextProgress * math.pi)
		local targetWaypoint = launchFrom:Lerp(landingPos, nextProgress) + Vector3.new(0, arcY, 0)
		command = (targetWaypoint - root.Position) / math.max(dt, 0.001)
		if command.Magnitude > speedLimit then command = command.Unit * speedLimit end
		root.AssemblyLinearVelocity = command
		root.AssemblyAngularVelocity = Vector3.zero
		-- Physics/Ragdoll/FallingDown are allowed throughout. Never ChangeState,
		-- toggle PlatformStand or edit motors/constraints to force recovery.
	end
end

local function executeEscapeFlightToForest(myToken)
	return executeReferenceVelocityFlight(myToken, FOREST_LANDING, "Snow→Forest")
end

local function stabilizeVelocityFlight(myToken, landingPos, destinationName)
	local startedAt = os.clock()
	local command = Vector3.zero
	local settled = false
	while os.clock() - startedAt < MAX_HOLD_S do
		local dt = RunService.Heartbeat:Wait()
		local root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		sampleFlight("STABILIZE", dt, root, hum, command, landingPos)
		if root.Anchored then return false, "Character anchored during stabilization" end
		local delta = landingPos - root.Position
		-- Do not turn the reference's delta*4 hold into an unbounded second
		-- flight when the game resets the character all the way back to Snow.
		if delta.Magnitude > 15 then return false, "Displaced from " .. destinationName .. " during stabilization" end
		neutraliseEggPhysics(runCharacter)
		enforceFlightSpeed(myToken)
		command = delta.Magnitude > HOLD_DEAD_ZONE and delta * 4 or Vector3.zero
		root.AssemblyLinearVelocity = command
		root.AssemblyAngularVelocity = Vector3.zero
		if os.clock() - startedAt >= MIN_HOLD_S and ragdollTimerExpired()
			and delta.Magnitude <= ARRIVAL_RADIUS then
			settled = true
			break
		end
	end
	if not settled then return false, destinationName .. " reached, but stabilization did not finish within 3.5s" end

	-- Reference final settle: zero velocities for 0.20s without editing state,
	-- joints, CFrame or position. Check cancellation after every yield.
	local settleStartedAt = os.clock()
	while os.clock() - settleStartedAt < FINAL_SETTLE_S do
		local dt = RunService.Heartbeat:Wait()
		local root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		sampleFlight("FINAL_SETTLE", dt, root, hum, Vector3.zero, landingPos)
		if root.Anchored then return false, "Character anchored during final settle" end
		if (landingPos - root.Position).Magnitude > ARRIVAL_RADIUS then
			return false, destinationName .. " arrival lost during final settle"
		end
		if not ragdollTimerExpired() then return false, "Ragdoll timer restarted during final settle" end
		enforceFlightSpeed(myToken)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	traceRun("STABILIZED", string.format("hold=%.3fs; reference dead-zone hold and final settle complete", os.clock() - startedAt))
	return true
end

local function stabilizeAtForest(myToken)
	return stabilizeVelocityFlight(myToken, FOREST_LANDING, "Forest")
end

----------------------------------------------------------------
-- SIMPLE MANUAL GROK-V3 FLIGHT: 1000 STUDS FORWARD PER CLICK
----------------------------------------------------------------

local function executeForwardVelocityFlight(statusLabel)
	if isRunning then
		if statusLabel and statusLabel.Parent then
			statusLabel.Text = "Movement already running. Stop it first; clicks are not queued."
		end
		return
	end
	currentToken += 1
	local myToken = currentToken
	isRunning = true
	runCharacter = LocalPlayer.Character
	captureBaseSpeed()
	table.clear(diagnosticLines)
	table.clear(flightSamples)
	local function status(text, color)
		if currentToken == myToken and statusLabel and statusLabel.Parent then
			statusLabel.Text = text
			statusLabel.TextColor3 = color
		end
	end

	task.spawn(function()
		local ok, completed, reason = xpcall(function()
			local root, _, rigError = getRunRig(myToken)
			if not root then return false, rigError end
			if root.Anchored then return false, "Character is anchored" end
			-- Reading facing is not CFrame movement. Freeze a world-space target
			-- for THIS click; do not follow later camera/character turns.
			local look = root.CFrame.LookVector
			local forward = Vector3.new(look.X, 0, look.Z)
			if forward.Magnitude < 0.001 then return false, "Face horizontally before clicking Fly" end
			local origin = root.Position
			local destination = origin + forward.Unit * MANUAL_FLIGHT_DISTANCE
			traceRun("FORWARD_TARGET", string.format("distance=1000 origin=(%.1f,%.1f,%.1f) target=(%.1f,%.1f,%.1f)",
				origin.X, origin.Y, origin.Z, destination.X, destination.Y, destination.Z))
			status("Flying 1000 studs forward — Grok-v3 velocity arc...", Color3.fromRGB(80, 210, 255))
			-- Exactly the same controller as the Snow return; no CFrame fallback,
			-- carry/snapshot remote, boss wait, drop, or forced ragdoll in this mode.
			local arrived, flightError = executeReferenceVelocityFlight(myToken, destination, "Manual forward 1000")
			if not arrived then return false, flightError end
			status("Destination reached; settling velocity...", Color3.fromRGB(255, 200, 120))
			return stabilizeVelocityFlight(myToken, destination, "Forward destination")
		end, debug.traceback)
		if currentToken ~= myToken then return end
		cleanupRun()
		isRunning = false
		runCharacter = nil
		if not ok or not completed then
			local message = tostring(ok and reason or completed)
			traceRun("FORWARD_ABORTED", message)
			status("Stopped: " .. message, Color3.fromRGB(255, 100, 100))
		else
			traceRun("FORWARD_COMPLETE", "1000-stud forward target reached locally; ready for next click")
			status("Flight complete. Click again for another 1000 studs.", Color3.fromRGB(100, 255, 170))
		end
	end)
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
	table.clear(diagnosticLines)
	table.clear(flightSamples)
	traceRun("RUN_START", string.format("test=Snow→Forest mode=GROK_V3_ARC plannedMax=%.2fs cutoff=%.2fs; immediate pickup escape, no drop; post-arrival hold separate",
		MAX_ARC_DURATION, FLIGHT_CUTOFF_S))

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
			traceRun("GROUND_ARRIVED", "Target approach finished")

			updateStatus("[3/5] Confirming target carry...", Color3.fromRGB(255, 160, 80))
			local carryStartedAt = os.clock()
			if not carryEggRemote(targetEgg.Uid, myToken) then return false, "Carry request failed or timed out" end
			if not confirmCarry(targetEgg.Uid, myToken) then return false, "Target carry not confirmed" end
			traceRun("CARRY_READY", string.format("uid=%s elapsed=%.3fs", targetEgg.Uid, os.clock() - carryStartedAt))

			-- Launch straight after target-specific carry confirmation. Do not
			-- wait for a guard strike/ragdoll and do not release the carried egg.
			updateStatus("[4/5] Egg secured → immediate Forest flight...", Color3.fromRGB(255, 180, 100))
			local arrived, flightError = executeEscapeFlightToForest(myToken)
			if not arrived then return false, flightError end

			updateStatus("[5/5] Forest reached; stabilizing...", Color3.fromRGB(100, 255, 170))
			local stable, holdError = stabilizeAtForest(myToken)
			if not stable then return false, holdError end
			return true
		end, debug.traceback)

		-- A stopped/older coroutine must not clean up or overwrite a newer run.
		if currentToken ~= myToken then return end
		cleanupRun()
		isRunning = false
		runCharacter = nil
		if not ok then
			traceRun("ERROR_DETAIL", tostring(completed))
			warn("[Steal-Pipeline v6.8] " .. tostring(completed))
			updateStatus("ERROR: Flight stopped; controls restored.", Color3.fromRGB(255, 80, 80))
		elseif not completed then
			updateStatus("ABORTED: " .. tostring(reason), Color3.fromRGB(255, 80, 80))
		else
			updateStatus("Forest reached. No drop requested; verify egg in-game.", Color3.fromRGB(100, 255, 170))
		end
	end)
end

----------------------------------------------------------------
-- MANUAL CHUNKED CFRAME TEST (independent of eggs / Snow flight)
----------------------------------------------------------------

local function parseSnapSettings(chunkText, distanceText, delayText)
	local function numberInRange(text, low, high)
		local value = tonumber(text)
		if not value or value ~= value or value < low or value > high then return nil end
		return value
	end
	local chunk = numberInRange(chunkText, 0.1, 1000)
	local distance = numberInRange(distanceText, 1, 100000)
	local delay = numberInRange(delayText, 0, 5)
	if not chunk then return nil, "Chunk size must be 0.1–1000 studs" end
	if not distance then return nil, "Distance must be 1–100000 studs" end
	if not delay then return nil, "Interval must be 0–5 seconds" end
	local steps = math.ceil(distance / chunk)
	if steps > SNAP_MAX_STEPS then return nil, "Too many chunks (maximum 10000)" end
	if steps * math.max(delay, 1 / 60) > SNAP_TIMEOUT_S then
		return nil, "Requested run exceeds the 300-second test limit"
	end
	return { chunk = chunk, distance = distance, delay = delay, steps = steps }
end

local function runChunkedSnap(settings, myToken, onProgress)
	local root, hum, reason = getRunRig(myToken)
	if not root then return false, reason end
	if root.Anchored then return false, "Character is anchored" end
	local facing = root.CFrame.LookVector
	local forward = Vector3.new(facing.X, 0, facing.Z)
	if forward.Magnitude < 0.001 then return false, "Face horizontally before starting" end
	forward = forward.Unit -- frozen for the entire test; camera/turning cannot redirect it
	local origin = root.Position
	local expected = origin
	local tolerance = math.clamp(settings.chunk * 0.25, 0.5, 2)
	local startedAt = os.clock()
	local nextStepAt = startedAt
	local traveled, steps = 0, 0
	-- Share the existing Stop/respawn velocity cleanup, but never enable flight
	-- friction, egg physics, animation, or the 500-WalkSpeed enforcer here.
	flightRoot = root
	hum:Move(Vector3.zero)
	hum:MoveTo(root.Position)
	hum.WalkSpeed = 0
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	traceRun("SNAP_START", string.format("chunk=%.3f total=%.3f interval=%.3fs steps=%d forward=(%.3f,0,%.3f)",
		settings.chunk, settings.distance, settings.delay, settings.steps, forward.X, forward.Z))

	while true do
		-- Always yield: even interval=0 permits only one chunk per Heartbeat.
		-- Validate again after the wait so Stop/respawn cannot cause a late snap.
		RunService.Heartbeat:Wait()
		root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		if root.Anchored then return false, "Character anchored during chunked snap" end
		local displacement = horizontalDistance(root.Position, expected)
		if displacement > tolerance then
			traceRun("SNAP_INTERRUPTED", string.format("external horizontal movement=%.2f studs after %d chunks", displacement, steps))
			return false, "Position changed externally; stopped without a catch-up snap"
		end
		-- Observe the final chunk on a later frame before claiming completion.
		if steps >= settings.steps then
			traceRun("SNAP_COMPLETE", string.format("chunks=%d commanded=%.3f netXZ=%.3f elapsed=%.3fs",
				steps, traveled, horizontalDistance(root.Position, origin), os.clock() - startedAt))
			return true
		end
		if os.clock() - startedAt >= SNAP_TIMEOUT_S then return false, "Chunked snap timed out" end
		if os.clock() >= nextStepAt then
			local step = math.min(settings.chunk, settings.distance - traveled)
			-- Offset the CURRENT CFrame, preserving rotation and current height.
			-- Never jump to an absolute endpoint or add missed chunks after a lag.
			root.CFrame = root.CFrame + forward * step
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			expected = root.Position
			traveled = math.min(settings.distance, traveled + step)
			steps += 1
			nextStepAt = os.clock() + settings.delay
			if steps == 1 or steps % 10 == 0 or steps == settings.steps then
				traceRun("SNAP_PROGRESS", string.format("chunk=%d/%d commanded=%.3f/%.3f", steps, settings.steps, traveled, settings.distance))
				if onProgress then onProgress(steps, traveled) end
			end
		end
	end
end

local function executeChunkedSnap(chunkText, distanceText, delayText, statusLabel)
	if isRunning then return end
	local settings, inputError = parseSnapSettings(chunkText, distanceText, delayText)
	if not settings then
		if statusLabel and statusLabel.Parent then
			statusLabel.Text = "INPUT ERROR: " .. inputError
			statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
		end
		return
	end
	currentToken += 1
	local myToken = currentToken
	isRunning = true
	runCharacter = LocalPlayer.Character
	captureBaseSpeed()
	table.clear(diagnosticLines)
	table.clear(flightSamples)
	local function status(text, color)
		if currentToken == myToken and statusLabel and statusLabel.Parent then
			statusLabel.Text = text
			statusLabel.TextColor3 = color
		end
	end
	task.spawn(function()
		local ok, completed, reason = xpcall(function()
			return runChunkedSnap(settings, myToken, function(steps, traveled)
				status(string.format("Forward snap: %d/%d chunks | %.1f/%.1f studs",
					steps, settings.steps, traveled, settings.distance), Color3.fromRGB(80, 210, 255))
			end)
		end, debug.traceback)
		if currentToken ~= myToken then return end
		cleanupRun()
		isRunning = false
		runCharacter = nil
		if not ok or not completed then
			local message = tostring(ok and reason or completed)
			traceRun("SNAP_ABORTED", message)
			status("SNAP STOPPED: " .. message, Color3.fromRGB(255, 100, 100))
		else
			status(string.format("Forward snap complete: %g studs in %d chunks.", settings.distance, settings.steps),
				Color3.fromRGB(100, 255, 170))
		end
	end)
end

----------------------------------------------------------------
-- MANUAL OLD CFRAME → FOREST (main's v6.0 movement profile)
----------------------------------------------------------------

local function applyLegacyPhysics()
	applyFlightFriction()
	for _, part in ipairs(runCharacter:GetDescendants()) do
		if part:IsA("BasePart") then
			if legacyCollisions[part] == nil then legacyCollisions[part] = part.CanCollide end
			part.CanCollide = false
		end
	end
	neutraliseEggPhysics(runCharacter)
end

local function runLegacyCFrame(myToken)
	local root, hum, reason = getRunRig(myToken)
	if not root then return false, reason end
	if root.Anchored then return false, "Character is anchored" end
	isFlying = true
	flightRoot = root
	applyLegacyPhysics()
	hum:Move(Vector3.zero)
	hum:MoveTo(root.Position)
	hum.WalkSpeed = 0
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	pcall(function()
		local animation = Instance.new("Animation")
		animation.AnimationId = FLIGHT_ANIM_ID
		local animator = hum:FindFirstChildOfClass("Animator") or hum
		local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
		animation:Destroy()
		if ok then
			flightTrack = track
			track.Priority = Enum.AnimationPriority.Movement
			track:Play()
		end
	end)

	local startedAt = os.clock()
	local expected = root.Position
	local function nextFrame()
		RunService.Heartbeat:Wait()
		root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		if root.Anchored then return false, "Character anchored during old CFrame flight" end
		if os.clock() - startedAt >= LEGACY_TIMEOUT_S then
			return false, "Old CFrame timed out; no forced Forest teleport"
		end
		if horizontalDistance(root.Position, expected) > 3 then
			return false, "Old CFrame interrupted by external movement; no catch-up teleport"
		end
		applyLegacyPhysics()
		return true
	end

	-- Settle one frame as in the original, but revalidate before every write.
	local ready, frameError = nextFrame()
	if not ready then return false, frameError end
	local startPos = root.Position
	local offset = Vector3.new(LEGACY_LANDING.X - startPos.X, 0, LEGACY_LANDING.Z - startPos.Z)
	local totalDist = offset.Magnitude
	local direction = totalDist > 0.001 and offset.Unit or Vector3.new(-1, 0, 0)
	local traveled = 0
	traceRun("LEGACY_START", string.format("source=main/v6.0 distance=%.1f step=78 cruiseY=112.5 timeout=2.5s", totalDist))

	local function moveTo(pos, verticalVelocity)
		root.CFrame = CFrame.new(pos, pos + direction)
		root.AssemblyLinearVelocity = Vector3.new(0, verticalVelocity, 0)
		root.AssemblyAngularVelocity = Vector3.zero
		expected = pos
	end

	if totalDist >= 10 then
		for i = 1, 5 do
			ready, frameError = nextFrame()
			if not ready then return false, frameError end
			traveled = math.min(traveled + LEGACY_STEP_SIZE, totalDist)
			local xz = startPos + direction * traveled
			moveTo(Vector3.new(xz.X, startPos.Y + (LEGACY_CRUISE_Y - startPos.Y) * (i / 5), xz.Z), -8)
		end
		traceRun("LEGACY_CRUISE", "Locked Forest heading; zero horizontal velocity")
		while horizontalDistance(root.Position, LEGACY_LANDING) > 25 do
			ready, frameError = nextFrame()
			if not ready then return false, frameError end
			local remaining = horizontalDistance(root.Position, LEGACY_LANDING)
			local step = remaining < 120 and math.clamp(remaining * 0.5, 28, LEGACY_STEP_SIZE) or LEGACY_STEP_SIZE
			traveled = math.min(traveled + step, totalDist)
			local xz = startPos + direction * traveled
			moveTo(Vector3.new(xz.X, LEGACY_CRUISE_Y, xz.Z), -10)
		end
	end

	-- Only descend after actual proximity, not after a timeout, X-only exit,
	-- or cancellation. Preserve main's three-frame descent and landing height.
	if horizontalDistance(root.Position, LEGACY_LANDING) > 25 then
		return false, "Old CFrame did not reach Forest; descent skipped"
	end
	traceRun("LEGACY_DESCENT", "Three-frame descent to (612,74,-325)")
	local descentStart = root.Position
	for i = 1, 3 do
		ready, frameError = nextFrame()
		if not ready then return false, frameError end
		moveTo(descentStart:Lerp(LEGACY_LANDING, i / 3), i == 3 and 0 or -12)
	end
	ready, frameError = nextFrame()
	if not ready then return false, frameError end
	if (root.Position - LEGACY_LANDING).Magnitude > ARRIVAL_RADIUS then
		return false, "Old CFrame arrival was displaced"
	end
	traceRun("LEGACY_COMPLETE", string.format("Forest reached locally in %.3fs", os.clock() - startedAt))
	return true
end

local function executeLegacyCFrame(statusLabel)
	if isRunning then return end
	currentToken += 1
	local myToken = currentToken
	isRunning = true
	runCharacter = LocalPlayer.Character
	captureBaseSpeed()
	table.clear(diagnosticLines)
	table.clear(flightSamples)
	if statusLabel and statusLabel.Parent then
		statusLabel.Text = "Manual old CFrame → Forest | 78-stud steps, Y=112.5"
		statusLabel.TextColor3 = Color3.fromRGB(255, 190, 100)
	end
	task.spawn(function()
		local ok, completed, reason = xpcall(function() return runLegacyCFrame(myToken) end, debug.traceback)
		if currentToken ~= myToken then return end
		cleanupRun()
		isRunning = false
		runCharacter = nil
		local text
		if not ok or not completed then
			text = "OLD CFRAME STOPPED: " .. tostring(ok and reason or completed)
			traceRun("LEGACY_ABORTED", text)
		else
			text = "Old CFrame complete: Forest reached locally."
		end
		if statusLabel and statusLabel.Parent then
			statusLabel.Text = text
			statusLabel.TextColor3 = ok and completed and Color3.fromRGB(100, 255, 170) or Color3.fromRGB(255, 100, 100)
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
main.Size = UDim2.new(0, 460, 0, 538)
main.Visible = false -- compact forward-flight panel is the default UI
main.Position = UDim2.new(0.03, 0, 0.12, 0)
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
title.Text = "SNOW ESCAPE + MANUAL CFRAME v6.8"
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
statusLabel.Text = "Choose Snow flight, chunked forward snap, or old CFrame → Forest. Stop cancels the active mode."
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
biomeBtn.Text = "TEST ROUTE: SNOW → FOREST (locked)"
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
stealBtn.Text = "TEST SNOW → FOREST (<2s TRAVEL)"
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
footer.Size = UDim2.new(1, -20, 0, 26)
footer.Position = UDim2.new(0, 10, 0, 234)
footer.BackgroundTransparency = 1
footer.Text = "v6.8: Grok-v3 flight port | Arc ≤1.5s, cutoff 1.9s\nNo boss wait or egg drop. Post-arrival hold is separate."
footer.TextColor3 = Color3.fromRGB(120, 140, 175)
footer.TextSize = 9
footer.Font = Enum.Font.Code
footer.TextWrapped = true
footer.Parent = main

local snapHeading = Instance.new("TextLabel")
snapHeading.Size = UDim2.new(1, -20, 0, 20)
snapHeading.Position = UDim2.fromOffset(10, 306)
snapHeading.BackgroundTransparency = 1
snapHeading.Text = "MANUAL FORWARD CFRAME — independent of egg pickup"
snapHeading.TextColor3 = Color3.fromRGB(120, 220, 255)
snapHeading.TextSize = 10
snapHeading.Font = Enum.Font.GothamBold
snapHeading.Parent = main

local function makeSnapInput(column, label, defaultText)
	local caption = Instance.new("TextLabel")
	caption.Size = UDim2.new(1 / 3, -20, 0, 16)
	caption.Position = UDim2.new(column / 3, 10, 0, 330)
	caption.BackgroundTransparency = 1
	caption.Text = label
	caption.TextColor3 = Color3.fromRGB(180, 200, 220)
	caption.TextSize = 10
	caption.Font = Enum.Font.Code
	caption.Parent = main
	local input = Instance.new("TextBox")
	input.Size = UDim2.new(1 / 3, -20, 0, 28)
	input.Position = UDim2.new(column / 3, 10, 0, 348)
	input.BackgroundColor3 = Color3.fromRGB(28, 39, 58)
	input.TextColor3 = Color3.new(1, 1, 1)
	input.Text = defaultText
	input.PlaceholderText = defaultText
	input.ClearTextOnFocus = false
	input.MultiLine = false
	input.TextSize = 12
	input.Font = Enum.Font.Code
	input.Parent = main
	Instance.new("UICorner", input).CornerRadius = UDim.new(0, 4)
	return input
end
local snapChunkInput = makeSnapInput(0, "Chunk (studs)", "10")
local snapDistanceInput = makeSnapInput(1, "Total (studs)", "1000")
local snapDelayInput = makeSnapInput(2, "Interval (seconds)", "0.05")

local snapStartBtn = Instance.new("TextButton")
snapStartBtn.Size = UDim2.new(1, -20, 0, 32)
snapStartBtn.Position = UDim2.fromOffset(10, 384)
snapStartBtn.BackgroundColor3 = Color3.fromRGB(105, 65, 165)
snapStartBtn.Text = "SNAP FORWARD IN CHUNKS"
snapStartBtn.TextColor3 = Color3.new(1, 1, 1)
snapStartBtn.TextSize = 11
snapStartBtn.Font = Enum.Font.GothamBold
snapStartBtn.Parent = main
Instance.new("UICorner", snapStartBtn).CornerRadius = UDim.new(0, 5)
snapStartBtn.Activated:Connect(function()
	executeChunkedSnap(snapChunkInput.Text, snapDistanceInput.Text, snapDelayInput.Text, statusLabel)
end)

local snapHint = Instance.new("TextLabel")
snapHint.Size = UDim2.new(1, -20, 0, 18)
snapHint.Position = UDim2.fromOffset(10, 422)
snapHint.BackgroundTransparency = 1
snapHint.Text = "Locks horizontal facing at Start. Interval 0 = one chunk per frame."
snapHint.TextColor3 = Color3.fromRGB(150, 170, 200)
snapHint.TextSize = 9
snapHint.Font = Enum.Font.Code
snapHint.Parent = main

local legacyHeading = Instance.new("TextLabel")
legacyHeading.Size = UDim2.new(1, -20, 0, 18)
legacyHeading.Position = UDim2.fromOffset(10, 448)
legacyHeading.BackgroundTransparency = 1
legacyHeading.Text = "OLD CFRAME FROM MAIN — Forest, Y=112.5, 78-stud steps"
legacyHeading.TextColor3 = Color3.fromRGB(255, 200, 120)
legacyHeading.TextSize = 10
legacyHeading.Font = Enum.Font.GothamBold
legacyHeading.Parent = main

local legacyStartBtn = Instance.new("TextButton")
legacyStartBtn.Size = UDim2.new(1, -20, 0, 32)
legacyStartBtn.Position = UDim2.fromOffset(10, 470)
legacyStartBtn.BackgroundColor3 = Color3.fromRGB(145, 85, 35)
legacyStartBtn.Text = "OLD CFRAME → FOREST (MANUAL)"
legacyStartBtn.TextColor3 = Color3.new(1, 1, 1)
legacyStartBtn.TextSize = 11
legacyStartBtn.Font = Enum.Font.GothamBold
legacyStartBtn.Parent = main
Instance.new("UICorner", legacyStartBtn).CornerRadius = UDim.new(0, 5)
legacyStartBtn.Activated:Connect(function() executeLegacyCFrame(statusLabel) end)

local legacyHint = Instance.new("TextLabel")
legacyHint.Size = UDim2.new(1, -20, 0, 26)
legacyHint.Position = UDim2.fromOffset(10, 506)
legacyHint.BackgroundTransparency = 1
legacyHint.Text = "Starts at your current position; no egg pickup or drop.\nSeparate from forward-snap inputs. Emergency Stop cancels any mode."
legacyHint.TextColor3 = Color3.fromRGB(150, 170, 200)
legacyHint.TextSize = 9
legacyHint.Font = Enum.Font.Code
legacyHint.Parent = main

-- Small independent panel: the new flight button never invokes a CFrame mode.
local forwardFlightPanel = Instance.new("Frame")
forwardFlightPanel.Name = "SimpleForwardVelocityFlight"
forwardFlightPanel.Size = UDim2.fromOffset(300, 172)
forwardFlightPanel.Position = UDim2.new(1, -310, 0.12, 0)
forwardFlightPanel.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
forwardFlightPanel.BorderSizePixel = 0
forwardFlightPanel.Parent = gui
Instance.new("UICorner", forwardFlightPanel).CornerRadius = UDim.new(0, 8)

local forwardFlightTitle = Instance.new("TextLabel")
forwardFlightTitle.Size = UDim2.new(1, -42, 0, 24)
forwardFlightTitle.Position = UDim2.fromOffset(10, 6)
forwardFlightTitle.BackgroundTransparency = 1
forwardFlightTitle.Text = "GROK-V3 · VELOCITY FLIGHT"
forwardFlightTitle.TextColor3 = Color3.fromRGB(120, 220, 255)
forwardFlightTitle.TextSize = 11
forwardFlightTitle.Font = Enum.Font.GothamBold
forwardFlightTitle.Parent = forwardFlightPanel

local forwardFlightCloseBtn = Instance.new("TextButton")
forwardFlightCloseBtn.Size = UDim2.fromOffset(22, 22)
forwardFlightCloseBtn.Position = UDim2.new(1, -28, 0, 6)
forwardFlightCloseBtn.BackgroundColor3 = Color3.fromRGB(140, 45, 45)
forwardFlightCloseBtn.Text = "X"
forwardFlightCloseBtn.TextColor3 = Color3.new(1, 1, 1)
forwardFlightCloseBtn.Parent = forwardFlightPanel

local forwardFlightBtn = Instance.new("TextButton")
forwardFlightBtn.Size = UDim2.new(1, -20, 0, 40)
forwardFlightBtn.Position = UDim2.fromOffset(10, 38)
forwardFlightBtn.BackgroundColor3 = Color3.fromRGB(35, 120, 170)
forwardFlightBtn.Text = "FLY FORWARD 1000 STUDS"
forwardFlightBtn.TextColor3 = Color3.new(1, 1, 1)
forwardFlightBtn.TextSize = 13
forwardFlightBtn.Font = Enum.Font.GothamBold
forwardFlightBtn.Parent = forwardFlightPanel
Instance.new("UICorner", forwardFlightBtn).CornerRadius = UDim.new(0, 6)

local forwardFlightStatus = Instance.new("TextLabel")
forwardFlightStatus.Size = UDim2.new(1, -20, 0, 44)
forwardFlightStatus.Position = UDim2.fromOffset(10, 84)
forwardFlightStatus.BackgroundTransparency = 1
forwardFlightStatus.Text = "Face a direction, then click. No egg needed.\nPure velocity; no CFrame movement or boss wait."
forwardFlightStatus.TextColor3 = Color3.fromRGB(180, 210, 235)
forwardFlightStatus.TextSize = 10
forwardFlightStatus.TextWrapped = true
forwardFlightStatus.Font = Enum.Font.Code
forwardFlightStatus.Parent = forwardFlightPanel
forwardFlightBtn.Activated:Connect(function() executeForwardVelocityFlight(forwardFlightStatus) end)

local forwardFlightStopBtn = Instance.new("TextButton")
forwardFlightStopBtn.Size = UDim2.new(0.35, -10, 0, 26)
forwardFlightStopBtn.Position = UDim2.fromOffset(10, 136)
forwardFlightStopBtn.BackgroundColor3 = Color3.fromRGB(130, 45, 45)
forwardFlightStopBtn.Text = "Stop"
forwardFlightStopBtn.TextColor3 = Color3.new(1, 1, 1)
forwardFlightStopBtn.TextSize = 11
forwardFlightStopBtn.Font = Enum.Font.GothamBold
forwardFlightStopBtn.Parent = forwardFlightPanel
forwardFlightStopBtn.Activated:Connect(function()
	stopRun("Manual flight Stop")
	forwardFlightStatus.Text = "Stopped. Ready for another click."
	statusLabel.Text = "Stopped. Velocity cleared."
end)

local otherControlsBtn = Instance.new("TextButton")
otherControlsBtn.Size = UDim2.new(0.65, -20, 0, 26)
otherControlsBtn.Position = UDim2.new(0.35, 10, 0, 136)
otherControlsBtn.BackgroundColor3 = Color3.fromRGB(50, 65, 90)
otherControlsBtn.Text = "Other controls / logs"
otherControlsBtn.TextColor3 = Color3.new(1, 1, 1)
otherControlsBtn.TextSize = 10
otherControlsBtn.Font = Enum.Font.GothamBold
otherControlsBtn.Parent = forwardFlightPanel

-- Both buttons work independently of the scanner. Clipboard is optional;
-- the selectable snapshot is the fallback when the executor has no clipboard.
local copyDiagnosticsBtn = Instance.new("TextButton")
copyDiagnosticsBtn.Size = UDim2.new(0.5, -15, 0, 26)
copyDiagnosticsBtn.Position = UDim2.new(0, 10, 0, 268)
copyDiagnosticsBtn.BackgroundColor3 = Color3.fromRGB(50, 80, 130)
copyDiagnosticsBtn.Text = "Copy run diagnostics"
copyDiagnosticsBtn.TextColor3 = Color3.new(1, 1, 1)
copyDiagnosticsBtn.TextSize = 10
copyDiagnosticsBtn.Font = Enum.Font.GothamBold
copyDiagnosticsBtn.Parent = main

local viewDiagnosticsBtn = copyDiagnosticsBtn:Clone()
viewDiagnosticsBtn.Position = UDim2.new(0.5, 5, 0, 268)
viewDiagnosticsBtn.Text = "View diagnostics"
viewDiagnosticsBtn.Parent = main

local diagnosticsPanel = Instance.new("Frame")
diagnosticsPanel.Size = UDim2.new(1, -12, 1, -40)
diagnosticsPanel.Position = UDim2.new(0, 6, 0, 34)
diagnosticsPanel.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
diagnosticsPanel.ZIndex = 20
diagnosticsPanel.Visible = false
diagnosticsPanel.Parent = main

local diagnosticsTitle = Instance.new("TextLabel")
diagnosticsTitle.Size = UDim2.new(1, -12, 0, 24)
diagnosticsTitle.Position = UDim2.fromOffset(6, 0)
diagnosticsTitle.BackgroundTransparency = 1
diagnosticsTitle.Text = "Diagnostics snapshot — select text to copy manually"
diagnosticsTitle.TextColor3 = Color3.fromRGB(180, 220, 255)
diagnosticsTitle.TextSize = 10
diagnosticsTitle.Font = Enum.Font.Code
diagnosticsTitle.ZIndex = 21
diagnosticsTitle.Parent = diagnosticsPanel

local diagnosticsScroll = Instance.new("ScrollingFrame")
diagnosticsScroll.Size = UDim2.new(1, -12, 1, -60)
diagnosticsScroll.Position = UDim2.fromOffset(6, 26)
diagnosticsScroll.BackgroundTransparency = 1
diagnosticsScroll.CanvasSize = UDim2.fromOffset(0, 0)
diagnosticsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
diagnosticsScroll.ScrollBarThickness = 6
diagnosticsScroll.ZIndex = 21
diagnosticsScroll.Parent = diagnosticsPanel

local diagnosticsText = Instance.new("TextBox")
diagnosticsText.Size = UDim2.new(1, -10, 0, 0)
diagnosticsText.AutomaticSize = Enum.AutomaticSize.Y
diagnosticsText.BackgroundTransparency = 1
diagnosticsText.ClearTextOnFocus = false
diagnosticsText.MultiLine = true
diagnosticsText.TextWrapped = true
diagnosticsText.TextXAlignment = Enum.TextXAlignment.Left
diagnosticsText.TextYAlignment = Enum.TextYAlignment.Top
diagnosticsText.TextColor3 = Color3.fromRGB(210, 225, 240)
diagnosticsText.TextSize = 10
diagnosticsText.Font = Enum.Font.Code
diagnosticsText.ZIndex = 22
diagnosticsText.Parent = diagnosticsScroll

local function showDiagnostics()
	-- Do not stream updates into a focused TextBox and erase the selection.
	diagnosticsText.Text = getDiagnosticsText()
	diagnosticsPanel.Visible = true
end

local refreshDiagnosticsBtn = copyDiagnosticsBtn:Clone()
refreshDiagnosticsBtn.Position = UDim2.new(0, 6, 1, -30)
refreshDiagnosticsBtn.Text = "Refresh snapshot"
refreshDiagnosticsBtn.ZIndex = 21
refreshDiagnosticsBtn.Parent = diagnosticsPanel
refreshDiagnosticsBtn.Activated:Connect(showDiagnostics)

local closeDiagnosticsBtn = refreshDiagnosticsBtn:Clone()
closeDiagnosticsBtn.Position = UDim2.new(0.5, 5, 1, -30)
closeDiagnosticsBtn.Text = "Back to controls"
closeDiagnosticsBtn.Parent = diagnosticsPanel
closeDiagnosticsBtn.Activated:Connect(function() diagnosticsPanel.Visible = false end)
viewDiagnosticsBtn.Activated:Connect(showDiagnostics)
copyDiagnosticsBtn.Activated:Connect(function()
	local clipboardWriter = setclipboard or toclipboard
	if typeof(clipboardWriter) == "function" then
		local ok, result = pcall(clipboardWriter, getDiagnosticsText())
		if ok and result ~= false then
			copyDiagnosticsBtn.Text = "Copied diagnostics"
			return
		end
	end
	showDiagnostics()
end)

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

-- No egg/network scanning is needed for the simple forward-flight panel.
otherControlsBtn.Activated:Connect(function()
	main.Visible = not main.Visible
	if main.Visible and not isRunning then task.spawn(updateTargetDisplay) end
end)

-- Test scope is intentionally fixed; no biome cycling until this route works.
biomeBtn.AutoButtonColor = false
biomeBtn.Active = false

refreshBtn.MouseButton1Click:Connect(function()
	if isRunning then return end
	statusLabel.Text = "Refreshing..."
	cachedSnapshot = nil
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
	statusLabel.Text = "Stopped. Velocity cleared; no additional drop sent."
	forwardFlightStatus.Text = "Stopped. Ready for another click."
	statusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
end)

local isGuiClosed = false
local characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(function(char)
	if char == runCharacter then
		stopRun("Character removed")
		statusLabel.Text = "Stopped: character removed."
		forwardFlightStatus.Text = "Stopped: character removed. Click after respawning."
	end
end)
local function handleClose()
	if isGuiClosed then return end
	isGuiClosed = true
	stopRun("GUI closed")
	characterRemovingConnection:Disconnect()
	gui:Destroy()
end
closeBtn.Activated:Connect(handleClose)
forwardFlightCloseBtn.Activated:Connect(handleClose)
gui.Destroying:Connect(handleClose)

captureBaseSpeed()

traceRun("READY", "Ready: simple Grok-v3 velocity button flies 1000 studs forward per click. Other tests are optional; one mode at a time.")
