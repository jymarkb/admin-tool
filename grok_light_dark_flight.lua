--[[
GROK LIGHT / DARK FLIGHT v1.0 -- standalone; admin_v6_escape.lua is untouched.
Reference: origin/main:grok-v3-target-fix.lua at a7b5ecd90630335a65f232e2ff13d90ab100e533.

AUDIT OF THE SUPPLIED FOREST -> COSMIC SCANNER LOG
* #0014 enters Physics BEFORE the velocity flight. #0062-66 recovers to
  GettingUp / Running / Freefall while flight continues. Natural guard setup
  differs from v6.8's immediate manual launch; causality is NOT established.
* The route advances roughly 2700 studs from #0018 to #0152, with reported
  velocity usually near 750 and capped at 1125. It is not a 1000-stud run.
* #0127 reverses 19.3 studs; #0129 resumes forward after a logging gap.
  This reference run is not evidence of zero corrections.
* scanner_v3.1.lua computes CF from position differences, not intercepted
  CFrame writes. CFRAME_BURST / ZERO_HORIZ at touchdown can reflect a sample
  after velocity was zeroed. Net=nil does not prove network ownership.
* The log says Holding=true throughout. The reference CALLS Drop, but this
  log does not establish successful drop. This test intentionally KEEPS bait.
* The scanner still labels the destination TRANSIT. The user's Cosmic label
  is not independently verified by a biome/arrival acknowledgement in this log.

THIS TEST
Forest bait -> confirmed carry -> natural guard Physics/ragdoll evidence ->
fresh exact Light Dark snapshot target -> reference sine arc -> hold/settle.
Cosmic toggle is an A/B baseline; NEVER silently substitutes it for Light Dark.
Uses actual target position +3 Y, NOT Cosmic coordinates or a Snow Y floor.
750 baseline / 1125 absolute cap; duration = distance / 750, not <=1.5 seconds.
Longer travel is deliberate. No relay hops, extra speed, teleport fallback,
forced states, joint edits, platform stand, anchoring, or CFrame movement.
Local arrival is checked, not inferred from elapsed time. Large corrections
abort rather than starting an unlimited catch-up flight. Late correction
observation is read-only after physics restoration; it is not server approval.

USAGE: Close v6.8/Grok and other movement/recovery scripts first. Start near a
Forest egg (within 300 studs). Press START. The script obtains/keeps Forest
bait and waits at most 15s for a natural guard reaction. It does NOT pick up a
Light Dark egg or deliver the bait. Stop/Close restores owned properties.
An in-flight InvokeServer cannot be recalled; no new carry is sent after Stop.
Mock tests cannot establish live server acceptance or fix rubberbanding.
]]

local Players                = game:GetService("Players")
local Workspace              = game:GetService("Workspace")
local RunService             = game:GetService("RunService")
local ReplicatedStorage      = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
	task.wait(0.1)
	LocalPlayer = Players.LocalPlayer
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------

local selectedBiome       = "Light Dark"
local dynamicBaseWalkSpeed = 16.0

local RUN_WALKSPEED       = 500 -- reference preparation / flight / hold enforcer
local AERIAL_BASE_SPEED   = 750
local MIN_ARC_DURATION    = 0.35
local MAX_ROUTE_TIME_S    = 60 -- refuse unusually distant/malformed targets
local ARRIVAL_GRACE_S     = 2 -- bounded extra time; never increase speed
local STRIKE_TIMEOUT_S    = 15
local MAX_BACKTRACK       = 80 -- allows the logged 19-stud correction, not a reset
local MAX_FRAME_GAP       = 0.5 -- refuse a large stale-command catch-up
local MIN_HOLD_S          = 0.85
local MAX_HOLD_S          = 3.5
local HOLD_DEAD_ZONE      = 1.2
local FINAL_SETTLE_S      = 0.20
local ARRIVAL_RADIUS      = 5.5
local CARRY_TIMEOUT_S     = 3
local REMOTE_TIMEOUT_S    = 3
local FLIGHT_ANIM_ID      = "rbxassetid://102039335618606"

local GUI_NAME = "GrokLightDarkFlightV1"

local currentToken        = 0
local isRunning           = false
local isFlying            = false
local cachedSnapshot      = nil
local runCharacter        = nil
local flightTrack         = nil
local flightRoot          = nil
local originalPhysicalProperties = {}
local originalCarriedProperties = {}
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
	local line = string.format("[LightDark v1.0] %s t=%.3f run=%d %s | %s",
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
		os.clock(), phase, dt, pos.X, pos.Y, pos.Z, horizontalDistance(pos, destination), state.Name,
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
	if flightSpeedChangedConnection then flightSpeedChangedConnection:Disconnect() end
	if flightSpeedConnection then flightSpeedConnection:Disconnect() end
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
	-- A timed-out or carry-confirmation snapshot may still be in flight.
	-- Never label that older response a fresh post-strike destination.
	if forceRefresh and pendingRemotes["RF/EggWorld/AskFieldEggSnapshot"] then
		traceRun("SNAPSHOT_BUSY", "Earlier snapshot still pending; refusing stale target reuse. Retry after it finishes.")
		return {}
	end
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

-- Exact normalized area names only; never fuzzy-match an unrelated biome.
local function chooseEgg(eggs, biome, origin, allowOwn)
	local best, nearest = nil, math.huge
	for _, egg in ipairs(eggs) do
		if cleanString(egg.AreaId) == cleanString(biome)
			and (isEggAvailable(egg) or (allowOwn and tonumber(egg.CarrierUserId) == LocalPlayer.UserId)) then
			-- Prefer this player's confirmed Forest bait if already held.
			if allowOwn and hasTargetEggAttribute(egg.Uid) then return egg end
			local distance = (egg.Position - origin).Magnitude
			if distance < nearest then best, nearest = egg, distance end
		end
	end
	return best
end

local function describeAreas(eggs)
	local seen, areas = {}, {}
	for _, egg in ipairs(eggs) do
		if not seen[egg.AreaId] then seen[egg.AreaId] = true; table.insert(areas, egg.AreaId) end
	end
	table.sort(areas)
	return table.concat(areas, ", ")
end

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
	local duration = math.max(distance / AERIAL_BASE_SPEED, MIN_ARC_DURATION)
	if duration > MAX_ROUTE_TIME_S then return false, "Route exceeds 60-second budget; check target metadata" end
	local cutoff = duration + ARRIVAL_GRACE_S
	local speedLimit = AERIAL_BASE_SPEED * 1.5
	local lastPosition = launchFrom
	local flatRoute = Vector3.new(landingPos.X - launchFrom.X, 0, landingPos.Z - launchFrom.Z)
	local forward = flatRoute.Magnitude > 0.001 and flatRoute.Unit or Vector3.zero
	local furthestProgress = 0
	local peakArc = math.clamp(distance * 0.035, 8, 26)
	local startedAt = os.clock()
	local command = Vector3.zero
	local peakObservedY = launchFrom.Y
	local nextProgressLog = 0
	traceRun("FLIGHT_START", string.format("route=%s mode=GROK_V3_ARC distance=%.1f planned=%.3fs cutoff=%.2fs speedCap=%.1f",
		routeName, distance, duration, cutoff, speedLimit))

	while true do
		local dt = RunService.Heartbeat:Wait()
		root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		local elapsed = os.clock() - startedAt
		peakObservedY = math.max(peakObservedY, root.Position.Y)
		sampleFlight("ARC", dt, root, hum, command, landingPos)
		if elapsed >= nextProgressLog then
			nextProgressLog = elapsed + 0.5
			traceRun("ARC_PROGRESS", string.format("elapsed=%.3fs remaining=%.1f y=%.1f peakY=%.1f walkSpeed=%.1f",
				elapsed, horizontalDistance(root.Position, landingPos), root.Position.Y, peakObservedY, hum.WalkSpeed))
		end
		if root.Anchored then return false, "Character anchored during arc" end
		if dt > MAX_FRAME_GAP then return false, "Frame gap over 0.5s; refusing stale catch-up" end
		local displacement = root.Position - lastPosition
		local fromLaunch = root.Position - launchFrom
		local progress = fromLaunch.X * forward.X + fromLaunch.Z * forward.Z
		furthestProgress = math.max(furthestProgress, progress)
		if furthestProgress - progress > MAX_BACKTRACK
			or displacement.Magnitude > speedLimit * math.max(dt, 0.001) + 100 then
			traceRun("CORRECTION", string.format("step=%.1f backtrack=%.1f", displacement.Magnitude, furthestProgress - progress))
			return false, "Large displacement/correction observed; refusing catch-up"
		end
		lastPosition = root.Position
		-- Scheduled progress=1 is not proof of arrival.
		if elapsed >= cutoff then return false, "Route timed out; no teleport fallback" end
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
		-- flight when the game resets the character all the way back to Forest.
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

----------------------------------------------------------------
-- REFERENCE LAUNCH SETUP (NATURAL GUARD REACTION, NEVER FORCED)
----------------------------------------------------------------

local function glideToBait(targetPos, myToken)
	local root, hum, reason = getRunRig(myToken)
	if not root then return false, reason end
	if (root.Position - targetPos).Magnitude > 300 then
		return false, "Start within 300 studs of a Forest bait egg"
	end
	flightRoot = root
	applyFlightFriction()
	startFlightSpeedEnforcer(myToken, hum)
	hum:Move(Vector3.zero)
	hum:MoveTo(root.Position)
	local started = os.clock()
	while os.clock() - started < 2.5 do
		local dt = RunService.Heartbeat:Wait()
		root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		if root.Anchored then return false, "Anchored while approaching bait" end
		if dt > MAX_FRAME_GAP then return false, "Frame gap during bait approach" end
		local diff = targetPos - root.Position
		local flat = Vector3.new(diff.X, 0, diff.Z)
		if flat.Magnitude <= 2.2 and math.abs(diff.Y) <= 6 then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			return true
		end
		-- Reference 280 glide; shorten the final step so it cannot oscillate
		-- forever past the small 2.2-stud bait radius on a slow client.
		local horizontal = flat.Magnitude > 0.001
			and flat.Unit * math.min(280, flat.Magnitude / math.max(dt, 0.001)) or Vector3.zero
		root.AssemblyLinearVelocity = horizontal + Vector3.new(0, math.clamp(diff.Y * 4, -15, 15), 0)
		root.AssemblyAngularVelocity = Vector3.zero
	end
	return false, "Forest bait approach timed out"
end

local function naturalStrikeReason(root, hum)
	local timer = LocalPlayer:GetAttribute("RagdollEndTime")
	if typeof(timer) == "number" and timer > serverNow() then return "active RagdollEndTime" end
	local state = hum:GetState()
	if state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.Ragdoll
		or state == Enum.HumanoidStateType.FallingDown then return "state=" .. state.Name end
	local disabled = 0
	for _, item in ipairs(runCharacter:GetDescendants()) do
		if item:IsA("Motor6D") and not item.Enabled then disabled += 1 end
	end
	if disabled >= 2 then return "disabled motors=" .. tostring(disabled) end
	return nil
end

local function waitForNaturalStrike(myToken)
	local root, hum, reason = getRunRig(myToken)
	if not root then return false, reason end
	local anchorPos = root.Position -- read only: NOT anchoring the part
	local started = os.clock()
	while os.clock() - started < STRIKE_TIMEOUT_S do
		root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		if root.Anchored then return false, "Anchored during guard wait" end
		local evidence = naturalStrikeReason(root, hum)
		if evidence then
			traceRun("GUARD_OBSERVED", string.format("%s wait=%.3fs timer=%s state=%s", evidence,
				os.clock() - started, tostring(LocalPlayer:GetAttribute("RagdollEndTime")), hum:GetState().Name))
			return true
		end
		local delta = anchorPos - root.Position
		-- Velocity or displacement alone is not proof of a guard strike.
		if delta.Magnitude > 15 then return false, "Displaced while waiting without guard-state evidence" end
		hum:Move(Vector3.zero)
		hum:MoveTo(root.Position)
		root.AssemblyLinearVelocity = delta.Magnitude > 0.4 and delta * 6 or Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		neutraliseEggPhysics(runCharacter)
		RunService.Heartbeat:Wait()
	end
	return false, "No natural guard reaction in 15s; no flight launched"
end

local function observeAfterRelease(myToken, destination)
	local started = os.clock()
	while os.clock() - started < 1 do
		RunService.Heartbeat:Wait()
		local root, hum, reason = getRunRig(myToken)
		if not root then return false, reason end
		-- Read-only observation: never pin the player after physics restoration.
		if root.Anchored then return false, "Anchored after release" end
		if horizontalDistance(root.Position, destination) > 20 or math.abs(root.Position.Y - destination.Y) > 35 then
			traceRun("POST_RELEASE_DISPLACEMENT", string.format("error=%.1f state=%s", (root.Position - destination).Magnitude, hum:GetState().Name))
			return false, "Displaced after release; possible correction, no retry"
		end
	end
	traceRun("OBSERVED", "1s after release stayed near target locally; NOT server acceptance or delivery proof")
	return true
end

local function conflictingController()
	for _, name in ipairs({"GrokEscapeFlightV6", "GrokAerialVelocityEngineV3"}) do
		if PlayerGui:FindFirstChild(name) then return name end
	end
	return nil
end

local function startRoute(statusLabel, finished)
	if isRunning then return end
	local conflict = conflictingController()
	if conflict then statusLabel.Text = "Close " .. conflict .. " before starting this test."; return end
	currentToken += 1
	local myToken = currentToken
	local biome = selectedBiome -- UI changes cannot redirect an active run
	isRunning = true
	runCharacter = LocalPlayer.Character
	captureBaseSpeed()
	table.clear(diagnosticLines)
	table.clear(flightSamples)
	local function status(text)
		if currentToken ~= myToken then return end
		traceRun("STATUS", text)
		if statusLabel.Parent then statusLabel.Text = text end
	end
	task.spawn(function()
		local ok, completed, reason = xpcall(function()
			local root, _, rigError = getRunRig(myToken)
			if not root then return false, rigError end
			if root.Anchored then return false, "Character is anchored" end
			status("[1/6] Resolving Forest bait and " .. biome .. " from live metadata...")
			local eggs = fetchSnapshot(true, myToken)
			root, _, rigError = getRunRig(myToken)
			if not root then return false, rigError end
			traceRun("AREAS", describeAreas(eggs))
			if not chooseEgg(eggs, biome, root.Position, false) then
				return false, "No available exact " .. biome .. " target; see Areas log. No fallback used."
			end
			local bait = chooseEgg(eggs, "Forest", root.Position, true)
			if not bait then return false, "No Forest bait in snapshot" end
			-- Never replace a different egg the player is already carrying.
			local existingUid = LocalPlayer:GetAttribute("EggUid")
			if existingUid ~= nil and tostring(existingUid) ~= "" and tostring(existingUid) ~= bait.Uid then
				return false, "Already carrying a different egg; release it manually before testing"
			end
			status("[2/6] Approaching Forest bait; 280-stud/s bounded velocity glide...")
			local reached, approachError = glideToBait(bait.Position + Vector3.new(0, 3, 0), myToken)
			if not reached then return false, approachError end
			status("[3/6] Confirming Forest bait carry...")
			if not carryEggRemote(bait.Uid, myToken) then return false, "Forest carry request failed" end
			if not confirmCarry(bait.Uid, myToken) then return false, "Forest bait ownership not confirmed" end
			traceRun("BAIT_CONFIRMED", bait.Uid .. "; keeping bait (no Drop remote)")
			status("[4/6] Waiting for natural guard reaction (max 15s); no forced ragdoll...")
			local struck, strikeError = waitForNaturalStrike(myToken)
			if not struck then return false, strikeError end

			-- Same fresh-target stage as Grok-v3, but bounded/cancellable.
			local resolveStarted = os.clock()
			eggs = fetchSnapshot(true, myToken)
			root, _, rigError = getRunRig(myToken)
			if not root then return false, rigError end
			local target = chooseEgg(eggs, biome, root.Position, false)
			if not target then return false, "Fresh " .. biome .. " target unavailable; not flying to stale coordinates" end
			local destination = target.Position + Vector3.new(0, 3, 0)
			local timer = LocalPlayer:GetAttribute("RagdollEndTime")
			traceRun("LAUNCH_CONTEXT", string.format("target=%s area=%s pos=(%.1f,%.1f,%.1f) resolve=%.3fs state=%s ragdollLeft=%.3f EggUid=%s",
				target.Uid, target.AreaId, destination.X, destination.Y, destination.Z, os.clock() - resolveStarted,
				select(2, getRunRig(myToken)):GetState().Name, typeof(timer) == "number" and math.max(0, timer - serverNow()) or 0,
				tostring(LocalPlayer:GetAttribute("EggUid"))))
			status("[5/6] Flying to " .. biome .. " at 750 baseline / 1125 cap; distance-based duration...")
			local arrived, flightError = executeReferenceVelocityFlight(myToken, destination, "Forest→" .. biome)
			if not arrived then return false, flightError end
			status("[6/6] Near target locally; stabilizing, then observing release...")
			local stable, holdError = stabilizeVelocityFlight(myToken, destination, biome)
			if not stable then return false, holdError end
			cleanupRun()
			return observeAfterRelease(myToken, destination)
		end, debug.traceback)
		if currentToken ~= myToken then return end
		cleanupRun()
		isRunning = false
		runCharacter = nil
		if not ok or not completed then
			status("STOPPED: " .. tostring(ok and reason or completed))
		else
			status("Near " .. biome .. " after local release check. Not a delivery/server acknowledgement.")
		end
		if finished then finished() end
	end)
end

-- GUI
local oldGui = PlayerGui:FindFirstChild(GUI_NAME)
if oldGui then oldGui:Destroy() end
local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.Parent = PlayerGui
local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(350, 416)
panel.Position = UDim2.new(1, -360, 0.12, 0)
panel.BackgroundColor3 = Color3.fromRGB(18, 21, 32)
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)
local function label(text, y, height)
	local node = Instance.new("TextLabel")
	node.Size = UDim2.new(1, -24, 0, height)
	node.Position = UDim2.fromOffset(12, y)
	node.BackgroundTransparency = 1
	node.TextColor3 = Color3.fromRGB(210, 220, 240)
	node.Font = Enum.Font.Code
	node.TextSize = 11
	node.TextWrapped = true
	node.Text = text
	node.Parent = panel
	return node
end
local function button(text, y, callback)
	local node = Instance.new("TextButton")
	node.Size = UDim2.new(1, -24, 0, 30)
	node.Position = UDim2.fromOffset(12, y)
	node.BackgroundColor3 = Color3.fromRGB(48, 74, 110)
	node.TextColor3 = Color3.new(1, 1, 1)
	node.Font = Enum.Font.GothamBold
	node.TextSize = 11
	node.Text = text
	node.Parent = panel
	node.Activated:Connect(callback)
	return node
end
label("GROK · FOREST → LIGHT / DARK · v1.0", 8, 24)
label("Standalone guard-launch test. Close other movement scripts. Start near Forest bait. Keeps bait; no auto-drop.", 34, 44)
local statusLabel = label("Ready. Natural guard reaction required; no forced state. Longer routes take longer than 2 seconds.", 190, 52)
local logBox = Instance.new("TextBox")
logBox.Size = UDim2.new(1, -24, 0, 82)
logBox.Position = UDim2.fromOffset(12, 246)
logBox.BackgroundColor3 = Color3.fromRGB(10, 13, 20)
logBox.TextColor3 = Color3.fromRGB(180, 205, 225)
logBox.TextSize = 10
logBox.Font = Enum.Font.Code
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.MultiLine = true
logBox.ClearTextOnFocus = false
logBox.TextWrapped = false
logBox.Text = "Diagnostics appear here after a run. Copy logs for the full buffer."
logBox.Parent = panel
local function refreshLog() logBox.Text = getDiagnosticsText() end
local targetButton
local startButton
targetButton = button("TARGET: LIGHT DARK (click for Cosmic comparison)", 82, function()
	if isRunning then return end
	selectedBiome = selectedBiome == "Light Dark" and "Cosmic" or "Light Dark"
	targetButton.Text = "TARGET: " .. selectedBiome .. " (click to switch)"
	startButton.Text = "START: FOREST → " .. selectedBiome
end)
startButton = button("START: FOREST → Light Dark", 118, function() startRoute(statusLabel, refreshLog) end)
local stopButton = button("STOP (does not drop bait)", 154, function()
	stopRun("Stop button")
	statusLabel.Text = "Stopped. Owned physics restored; bait not dropped."
	refreshLog()
end)
local copyButton = button("COPY / REFRESH LOGS", 334, function()
	refreshLog()
	local copy = setclipboard or toclipboard
	if typeof(copy) == "function" then pcall(copy, logBox.Text) end
end)
local closed = false
local removing = LocalPlayer.CharacterRemoving:Connect(function(character)
	if character == runCharacter then
		stopRun("Character removed")
		statusLabel.Text = "Stopped: character removed."
		refreshLog()
	end
end)
local function close()
	if closed then return end
	closed = true
	stopRun("GUI closed")
	removing:Disconnect()
	gui:Destroy()
end
local closeButton = button("CLOSE", 370, close)
gui.Destroying:Connect(close)
traceRun("READY", "Separate Light Dark test; 750 baseline, 1125 cap, natural guard launch, no CFrame movement. Close other controllers first.")
