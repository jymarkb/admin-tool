--[[
CLIENT CONFIG / PHYSICS SNAPSHOT SCANNER v1.0
Standalone companion to scanner-2.8.lua; does not modify it or movement scripts.
Audit reference: origin/main 9493534 (scanner-2.8.lua and 1.8-data-support.txt).

MANUAL: Snapshot on join, Pin baseline, then Snapshot before/after a working or
failed flight and around the suspected five-minute boundary. Add a label first.
Compare against pinned baseline or previous capture. Save/Copy JSON before
rejoining; paste that JSON in the output box and Import baseline after rejoin.

READ-ONLY GAME OBSERVATION: no remote invocation, module execution, code hooks,
state forcing, ownership changes, physics edits, or hidden-property access.
Only the scanner's own UI, local buffers, connections, and optional user-requested
export file are changed. Passive RemoteEvent observation is OFF by default.

COVERAGE: all enumerated client-visible service descendants except CoreGui,
CorePackages and this scanner's UI; all readable attributes/tags/ValueBase values;
curated documented property families below; humanoid states, controllers, joints,
constraints, parts, settings, scripts/remotes, animation tracks and telemetry.
Roblox has no general runtime property enumerator. Protected properties and
server-only variables, module locals, nonreplicated tables and server logic are
NOT visible. Source is read only if permission allows it; never require/decompile.

LIMITS ARE REPORTED. A capture is time-sliced, NOT an atomic server snapshot.
Streaming, respawn and rejoin can add/remove instances without any config change.
Same-run diffs match instance identity; imported/cross-run diffs match paths and
flag duplicate-path ambiguity. Clipped strings/tables cannot prove equality.
GetNetworkOwner unavailable != nil/server ownership. Position/velocity mismatch
is a heuristic, not proof of a CFrame write or an anti-cheat decision.
The 300s marker is scanner elapsed time, NOT a discovered server reset timer.
]]

local CONFIG = {
	MAX_NODES = 30000, MAX_SCAN_SECONDS = 60, SLICE_SECONDS = 0.004,
	MAX_DEPTH = 128, MAX_QUEUE = 60000, MAX_NOTICES = 200, MAX_STRING_BYTES = 32768, MAX_TABLE_ITEMS = 100,
	MAX_VALUE_DEPTH = 6, MAX_WATCHED = 1600, MAX_CONNECTIONS = 6000,
	MAX_REMOTE_WATCHED = 128, EVENT_CAP = 3000, EVENTS_PER_SECOND = 100,
	SAMPLE_CAP = 600, SAMPLE_INTERVAL = 0.1, MAX_PENDING = 3000,
	MAX_DIFF_DETAILS = 12000, MAX_REPORT_BYTES = 2 * 1024 * 1024, MAX_EXPORT_BYTES = 32 * 1024 * 1024,
	PAGE_BYTES = 12000,
}
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer
while not player do
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
	player = Players.LocalPlayer
end
local playerGui = player:WaitForChild("PlayerGui")
local GUI_NAME = "ClientConfigSnapshotScanner"
local startedAt = os.clock()
local sessionId = tostring(os.time()) .. ":" .. tostring(startedAt)
pcall(function() sessionId = HttpService:GenerateGUID(false) end)
local alive, busy, scanToken = true, false, 0
local gui, statusLabel, outputBox, labelInput, hudLabel, pageLabel
local baseline, previous, current = nil, nil, nil
local comparePrevious = false
local captureNumber = 0
local connections = {}
local ids = setmetatable({}, { __mode = "k" })
local nextId = 0
local watched, remoteWatches = {}, {}
local remoteCandidates = setmetatable({}, { __mode = "k" })
local watchEnabled, remoteEnabled = true, false
local watchCount, watchConnections, remoteCount = 0, 0, 0
local watchSkipped, watchDenied, remoteSkipped = 0, 0, 0
local samplingErrors, watchReadErrors, serviceConnectionFailures = 0, 0, 0
local pending, pendingHead, pendingTail, pendingDropped = {}, 1, 0, 0
local lastDiff, viewText, viewPage = nil, "Take a manual snapshot to begin.", 1
local compareSnapshots, renderReport

local function read(object, property)
	local ok, value = pcall(function() return object[property] end)
	if ok then return true, value end
	return false, tostring(value)
end
local function isA(object, class)
	local ok, result = pcall(function() return object:IsA(class) end)
	return ok and result == true
end
local function idFor(object)
	if not ids[object] then nextId += 1; ids[object] = "i" .. tostring(nextId) end
	return ids[object]
end
local function pathFor(object)
	local ok, value = pcall(function() return object:GetFullName() end)
	return ok and value or "<unavailable path>"
end
local function clockInfo()
	local ok, server = pcall(function() return Workspace:GetServerTimeNow() end)
	return { scannerAge = os.clock() - startedAt, monotonic = os.clock(), unix = os.time(),
		serverTime = ok and server or "unavailable" }
end
local function excluded(object)
	if not object then return true end
	if gui and (object == gui or object:IsDescendantOf(gui)) then return true end
	local top = object
	while top and top.Parent and top.Parent ~= game do top = top.Parent end
	return top and (top.Name == "CoreGui" or top.Name == "CorePackages") or false
end
local function canonical(value)
	if type(value) ~= "table" then
		if type(value) == "string" then return string.format("%q", value) end
		if type(value) == "number" then return string.format("%.17g", value) end
		return tostring(value)
	end
	local keys, pieces = {}, {}
	for key in pairs(value) do table.insert(keys, key) end
	table.sort(keys, function(a, b) return type(a) .. tostring(a) < type(b) .. tostring(b) end)
	for _, key in ipairs(keys) do table.insert(pieces, canonical(key) .. ":" .. canonical(value[key])) end
	return "{" .. table.concat(pieces, ",") .. "}"
end
local function numberData(value)
	return value == value and math.abs(value) < math.huge and value or tostring(value)
end
local function encode(value, depth, seen)
	depth, seen = depth or 0, seen or {}
	local kind = typeof(value)
	if kind == "nil" then return { type = "nil" } end
	if kind == "boolean" then return { type = kind, value = value } end
	if kind == "number" then
		return { type = kind, value = numberData(value) }
	end
	if kind == "string" then
		local clipped = #value > CONFIG.MAX_STRING_BYTES
		local text = clipped and value:sub(1, CONFIG.MAX_STRING_BYTES) or value
		local utfOk, valid = pcall(utf8.len, text)
		if not utfOk or not valid then
			return { type = "bytes", hex = (text:gsub(".", function(c) return string.format("%02x", c:byte()) end)),
				bytes = #value, truncated = clipped }
		end
		return { type = kind, value = text, bytes = #value, truncated = clipped }
	end
	if kind == "Instance" then return { type = kind, id = idFor(value), path = pathFor(value), class = value.ClassName } end
	if kind == "Vector3" then return { type = kind, x = numberData(value.X), y = numberData(value.Y), z = numberData(value.Z) } end
	if kind == "Vector2" then return { type = kind, x = numberData(value.X), y = numberData(value.Y) } end
	if kind == "CFrame" then
		local components = { value:GetComponents() }
		for i, component in ipairs(components) do components[i] = numberData(component) end
		return { type = kind, components = components }
	end
	if kind == "Color3" then return { type = kind, r = numberData(value.R), g = numberData(value.G), b = numberData(value.B) } end
	if kind == "UDim" then return { type = kind, scale = numberData(value.Scale), offset = numberData(value.Offset) } end
	if kind == "UDim2" then return { type = kind, x = encode(value.X), y = encode(value.Y) } end
	if kind == "PhysicalProperties" then
		return { type = kind, density = numberData(value.Density), friction = numberData(value.Friction), elasticity = numberData(value.Elasticity),
			frictionWeight = numberData(value.FrictionWeight), elasticityWeight = numberData(value.ElasticityWeight) }
	end
	if kind == "NumberRange" then return { type = kind, min = numberData(value.Min), max = numberData(value.Max) } end
	if kind == "NumberSequence" or kind == "ColorSequence" then
		local points = {}
		for _, point in ipairs(value.Keypoints) do
			table.insert(points, { time = numberData(point.Time), value = encode(point.Value), envelope = kind == "NumberSequence" and numberData(point.Envelope) or nil })
		end
		return { type = kind, points = points }
	end
	if kind == "table" then
		if seen[value] then return { type = "cycle" } end
		if depth >= CONFIG.MAX_VALUE_DEPTH then return { type = kind, depthLimited = true } end
		seen[value] = true
		local entries, clipped = {}, false
		for key, item in pairs(value) do
			if #entries >= CONFIG.MAX_TABLE_ITEMS then clipped = true; break end
			table.insert(entries, { key = encode(key, depth + 1, seen), value = encode(item, depth + 1, seen) })
		end
		seen[value] = nil
		table.sort(entries, function(a, b) return canonical(a.key) < canonical(b.key) end)
		return { type = kind, entries = entries, truncated = clipped }
	end
	-- EnumItems and less common value types keep their Roblox type and display
	-- form. These are explicitly display-only, not full property reflection.
	return { type = kind, display = tostring(value), displayOnly = kind ~= "EnumItem" and kind ~= "BrickColor" }
end
local function unavailable(detail)
	return { type = "unavailable", reason = tostring(detail):sub(1, 240) }
end
local function safeEncoded(fn)
	local ok, value = pcall(fn)
	if not ok then return unavailable(value) end
	local converted, result = pcall(encode, value)
	return converted and result or unavailable(result)
end
local function ring(capacity)
	return { capacity = capacity, items = {}, next = 1, count = 0, overwritten = 0 }
end
local function push(buffer, value)
	if buffer.count == buffer.capacity then buffer.overwritten += 1 else buffer.count += 1 end
	buffer.items[buffer.next] = value
	buffer.next = buffer.next % buffer.capacity + 1
end
local function ringValues(buffer)
	local result = {}
	local first = buffer.count == buffer.capacity and buffer.next or 1
	for i = 0, buffer.count - 1 do table.insert(result, buffer.items[(first + i - 1) % buffer.capacity + 1]) end
	return result
end
local events, samples = ring(CONFIG.EVENT_CAP), ring(CONFIG.SAMPLE_CAP)
local eventSequence, eventRateWindow, eventRateCount, eventRateDropped = 0, 0, 0, 0
local function event(kind, object, detail)
	if not alive or not watchEnabled then return end
	local second = math.floor(os.clock())
	if second ~= eventRateWindow then eventRateWindow, eventRateCount = second, 0 end
	eventSequence += 1
	if eventRateCount >= CONFIG.EVENTS_PER_SECOND then eventRateDropped += 1; return end
	eventRateCount += 1
	push(events, { sequence = eventSequence, time = clockInfo(), kind = kind,
		id = object and idFor(object) or nil, path = object and pathFor(object) or nil, detail = detail })
end
local function message(text)
	if statusLabel and statusLabel.Parent then statusLabel.Text = text end
end

-- Readable-property allowlists; missing/protected members are explicitly recorded.
-- Static settings are separate from continuously changing motion / animation data.
local PROPERTY_GROUPS = {
	{ "ValueBase", "Value", "" },
	{ "Workspace", "Gravity FallenPartsDestroyHeight StreamingEnabled StreamingMinRadius StreamingTargetRadius StreamingIntegrityMode PhysicsSteppingMethod SignalBehavior AirDensity GlobalWind", "DistributedGameTime" },
	{ "Player", "UserId AccountAge Character AutoJumpEnabled CameraMode CameraMinZoomDistance CameraMaxZoomDistance DevComputerMovementMode DevTouchMovementMode ReplicationFocus SimulationRadius MaximumSimulationRadius", "" },
	{ "Humanoid", "WalkSpeed JumpPower JumpHeight UseJumpPower HipHeight AutoRotate AutomaticScalingEnabled PlatformStand Sit EvaluateStateMachine BreakJointsOnDeath RequiresNeck RigType MaxHealth MaxSlopeAngle AutoJumpEnabled", "Health FloorMaterial MoveDirection WalkToPoint WalkToPart RootPart SeatPart Jump" },
	{ "BasePart", "Anchored CanCollide CanTouch CanQuery Massless RootPriority CollisionGroup Material MaterialVariant CustomPhysicalProperties CurrentPhysicalProperties Size", "CFrame AssemblyLinearVelocity AssemblyAngularVelocity Mass AssemblyMass AssemblyCenterOfMass AssemblyRootPart ReceiveAge NetworkIsSleeping" },
	{ "Model", "PrimaryPart ModelStreamingMode", "WorldPivot" },
	{ "JointInstance", "Enabled Part0 Part1 C0 C1", "Active" },
	{ "Motor6D", "", "Transform" },
	{ "WeldConstraint", "Enabled Part0 Part1", "Active" },
	{ "Attachment", "CFrame Axis SecondaryAxis", "WorldCFrame" },
	{ "Constraint", "Enabled Attachment0 Attachment1 Visible", "Active" },
	{ "BallSocketConstraint", "LimitsEnabled TwistLimitsEnabled UpperAngle TwistLowerAngle TwistUpperAngle MaxFrictionTorque Restitution Radius", "" },
	{ "HingeConstraint", "ActuatorType AngularSpeed AngularVelocity LimitsEnabled LowerAngle UpperAngle MotorMaxTorque ServoMaxTorque TargetAngle Restitution", "CurrentAngle" },
	{ "LinearVelocity", "VectorVelocity LineVelocity PlaneVelocity VelocityConstraintMode RelativeTo ForceLimitsEnabled ForceLimitMode MaxForce MaxAxesForce MaxPlanarAxesForce PrimaryTangentAxis SecondaryTangentAxis LineDirection", "" },
	{ "AngularVelocity", "AngularVelocity MaxTorque RelativeTo ReactionTorqueEnabled", "" },
	{ "VectorForce", "Force RelativeTo ApplyAtCenterOfMass", "" },
	{ "Torque", "Torque RelativeTo", "" },
	{ "AlignPosition", "Mode Position MaxForce MaxVelocity Responsiveness RigidityEnabled ReactionForceEnabled ApplyAtCenterOfMass ForceLimitMode MaxAxesForce ForceRelativeTo", "" },
	{ "AlignOrientation", "Mode CFrame MaxTorque MaxAngularVelocity Responsiveness RigidityEnabled ReactionTorqueEnabled PrimaryAxisOnly AlignType PrimaryAxis SecondaryAxis", "" },
	{ "BodyVelocity", "Velocity MaxForce P", "" },
	{ "BodyPosition", "Position MaxForce P D", "" },
	{ "BodyGyro", "CFrame MaxTorque P D", "" },
	{ "BodyForce", "Force", "" },
	{ "BodyAngularVelocity", "AngularVelocity MaxTorque P", "" },
	{ "SpringConstraint", "Damping Stiffness FreeLength LimitsEnabled MinLength MaxLength MaxForce", "CurrentLength" },
	{ "RopeConstraint", "Length Restitution WinchEnabled WinchSpeed WinchForce WinchResponsiveness WinchTarget", "CurrentDistance" },
	{ "ControllerManager", "BaseMoveSpeed BaseTurnSpeed ActiveController RootPart GroundSensor ClimbSensor UpDirection", "MovingDirection FacingDirection" },
	{ "ControllerBase", "BalanceRigidityEnabled MoveSpeedFactor", "" },
	{ "GroundController", "AccelerationTime DecelerationTime Friction FrictionWeight GroundOffset TurnSpeedFactor BalanceSpeed", "" },
	{ "AirController", "MaintainLinearMomentum MaintainAngularMomentum MoveMaxForce TurnMaxTorque", "" },
	{ "ControllerPartSensor", "SensorMode UpdateType SearchDistance", "SensedPart HitFrame HitNormal" },
	{ "BaseScript", "Enabled Disabled RunContext", "" },
	{ "LuaSourceContainer", "Source", "" },
	{ "Animation", "AnimationId", "" },
	{ "GuiObject", "Visible Active Interactable Selectable", "Position Size" },
	{ "LayerCollector", "Enabled ResetOnSpawn", "" },
	{ "TextLabel", "", "Text" }, { "TextButton", "", "Text" }, { "TextBox", "", "Text" },
	{ "BodyThrust", "Force Location", "" },
	{ "PrismaticConstraint", "ActuatorType LimitsEnabled LowerLimit UpperLimit Speed TargetPosition MotorMaxForce MotorMaxAcceleration ServoMaxForce LinearResponsiveness", "CurrentPosition" },
	{ "NetworkSettings", "IncomingReplicationLag PrintPhysicsErrors PrintStreamInstanceQuota", "" },
	{ "ProximityPrompt", "Enabled MaxActivationDistance RequiresLineOfSight HoldDuration ActionText ObjectText", "" },
	{ "Camera", "CameraType CameraSubject FieldOfView", "CFrame Focus ViewportSize" },
	{ "Lighting", "ClockTime Brightness GlobalShadows Ambient OutdoorAmbient", "" },
	{ "SoundService", "RespectFilteringEnabled DistanceFactor DopplerScale RolloffScale", "" },
	{ "Stats", "", "DataReceiveKbps DataSendKbps PhysicsReceiveKbps PhysicsSendKbps PhysicsStepTimeMs HeartbeatTimeMs InstanceCount PrimitivesCount MovingPrimitivesCount ContactsCount" },
	{ "UserGameSettings", "ControlMode ComputerMovementMode TouchMovementMode RotationType SavedQualityLevel MouseSensitivity GamepadCameraSensitivity", "" },
	{ "PhysicsSettings", "PhysicsEnvironmentalThrottle AllowSleep ThrottleAdjustTime AreAssembliesShown AreOwnersShown", "" },
}
local propertyCache = {}
local function propertiesFor(object)
	local class = object.ClassName
	if propertyCache[class] then return propertyCache[class] end
	local static, motion = { Name = true, Archivable = true }, {}
	for _, group in ipairs(PROPERTY_GROUPS) do
		if isA(object, group[1]) then
			for prop in group[2]:gmatch("%S+") do static[prop] = true end
			for prop in group[3]:gmatch("%S+") do motion[prop] = true end
		end
	end
	propertyCache[class] = { static = static, motion = motion }
	return propertyCache[class]
end
local function disconnectWatch(object)
	local entry = watched[object]
	if entry then
		for _, connection in ipairs(entry.connections) do connection:Disconnect(); watchConnections -= 1 end
		watched[object] = nil; watchCount -= 1
	end
	if remoteWatches[object] then remoteWatches[object]:Disconnect(); remoteWatches[object] = nil; remoteCount -= 1 end
end
local function remoteMatches(object)
	local name = string.lower(object.Name)
	for _, word in ipairs({ "guard", "ragdoll", "speed", "movement", "zone", "config", "state", "treadmill", "physics" }) do
		if name:find(word, 1, true) then return true end
	end
	return false
end
local function attachRemote(object)
	if not remoteEnabled or not watchEnabled or remoteWatches[object] or not remoteMatches(object) then return end
	if remoteCount >= CONFIG.MAX_REMOTE_WATCHED then remoteSkipped += 1; return end
	local ok, connection = pcall(function()
		return object.OnClientEvent:Connect(function(...)
			if alive and watchEnabled and remoteEnabled then event("REMOTE_EVENT", object, encode(table.pack(...))) end
		end)
	end)
	if ok then remoteWatches[object] = connection; remoteCount += 1 else watchDenied += 1 end
end
local function watchNode(object, attributes)
	if not watchEnabled or not alive or excluded(object) then return end
	if isA(object, "RemoteEvent") or isA(object, "UnreliableRemoteEvent") then
		remoteCandidates[object] = true; attachRemote(object)
	end
	if watched[object] then return end
	local character = player.Character
	local localRig = character and (object == character or object:IsDescendantOf(character))
	local eligible = object == player or object == Workspace or localRig or isA(object, "ValueBase")
		or isA(object, "Configuration") or isA(object, "BaseScript") or isA(object, "Humanoid") or isA(object, "Constraint")
		or isA(object, "ControllerManager") or (attributes and next(attributes) ~= nil)
	if not eligible then return end
	if watchCount >= CONFIG.MAX_WATCHED or watchConnections >= CONFIG.MAX_CONNECTIONS then watchSkipped += 1; return end
	local entry = { connections = {}, attributes = {}, properties = {} }
	watched[object] = entry; watchCount += 1
	for key, value in pairs(attributes or {}) do entry.attributes[key] = encode(value) end
	local function connect(signalGetter, handler)
		if watchConnections >= CONFIG.MAX_CONNECTIONS then watchSkipped += 1; return end
		local ok, connection = pcall(function() return signalGetter():Connect(handler) end)
		if ok then table.insert(entry.connections, connection); watchConnections += 1 else watchDenied += 1 end
	end
	connect(function() return object.AttributeChanged end, function(name)
		local new = safeEncoded(function() return object:GetAttribute(name) end)
		local old = entry.attributes[name] or encode(nil)
		if canonical(old) ~= canonical(new) then event("ATTRIBUTE", object, { name = name, before = old, after = new }) end
		entry.attributes[name] = new
	end)
	for prop in pairs(propertiesFor(object).static) do
		-- Source and geometry size are snapshot-only. All ValueBase values and
		-- scalar/physical controls on eligible instances are watched where allowed.
		if prop ~= "Source" and prop ~= "Name" and prop ~= "Archivable" and prop ~= "Size" then
			local property = prop
			local ok, value = read(object, property)
			if ok then
				entry.properties[property] = encode(value)
				connect(function() return object:GetPropertyChangedSignal(property) end, function()
					local new = safeEncoded(function() return object[property] end)
					local old = entry.properties[property]
					if canonical(old) ~= canonical(new) then event("PROPERTY", object, { name = property, before = old, after = new }) end
					entry.properties[property] = new
				end)
			end
		end
	end
	if isA(object, "Humanoid") then
		connect(function() return object.StateChanged end, function(old, new)
			event("HUMANOID_STATE", object, { before = encode(old), after = encode(new) })
		end)
	end
end
local function enqueue(object)
	if not watchEnabled or excluded(object) then return end
	if pendingTail - pendingHead + 1 >= CONFIG.MAX_PENDING then pendingDropped += 1; return end
	pendingTail += 1; pending[pendingTail] = object
end

local function countValueLimits(value, counts)
	if type(value) ~= "table" then return end
	if value.type == "unavailable" then counts.unavailable += 1 end
	if value.truncated then counts.truncated += 1 end
	if value.depthLimited then counts.depthLimited += 1 end
	if value.displayOnly then counts.displayOnly += 1 end
	for _, child in pairs(value) do countValueLimits(child, counts) end
end
local function readRecord(object, entry, snapshot)
	local record = { id = idFor(object), path = entry.path, class = object.ClassName,
		ambiguousPath = entry.ambiguous or false, fields = {}, motion = {}, sampledAt = os.clock() - startedAt }
	local function property(prop, destination)
		local ok, value = read(object, prop)
		if ok then destination["P/" .. prop] = safeEncoded(function() return value end)
		else
			destination["P/" .. prop] = unavailable(value)
			local key = record.class .. "." .. prop
			local failure = snapshot.readFailures[key] or { count = 0, example = tostring(value):sub(1, 240) }
			failure.count += 1; snapshot.readFailures[key] = failure
		end
	end
	local spec = propertiesFor(object)
	for prop in pairs(spec.static) do property(prop, record.fields) end
	for prop in pairs(spec.motion) do property(prop, record.motion) end
	local attrOK, attrs = pcall(function() return object:GetAttributes() end)
	record.attributesReadable = attrOK
	if attrOK then
		for key, value in pairs(attrs) do record.fields["A/" .. key] = safeEncoded(function() return value end) end
	else record.fields["AttributesAccess"] = unavailable(attrs) end
	record.fields.Tags = safeEncoded(function()
		local tags = CollectionService:GetTags(object); table.sort(tags); return tags
	end)
	if isA(object, "Humanoid") then
		record.motion.State = safeEncoded(function() return object:GetState() end)
		for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
			record.fields["StateEnabled/" .. state.Name] = safeEncoded(function() return object:GetStateEnabled(state) end)
		end
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if object == root then
		record.motion.NetworkOwner = safeEncoded(function() return object:GetNetworkOwner() end)
		record.motion.Grounded = safeEncoded(function() return object:IsGrounded() end)
	end
	local watchOK = pcall(watchNode, object, attrOK and attrs or nil)
	if not watchOK then watchReadErrors += 1 end
	countValueLimits(record.fields, snapshot.valueLimits)
	countValueLimits(record.motion, snapshot.valueLimits)
	return record
end
local function collectRoots()
	local roots, found, failures = {}, {}, {}
	local function add(object, path)
		if object and not found[object] then found[object] = true; table.insert(roots, { object = object, path = path, root = true }) end
	end
	-- Stable focus aliases make a rejoined local character comparable without
	-- depending on traversal order. Instance identity is still retained.
	add(player, "@LocalPlayer")
	add(player.Character, "@Character")
	add(game, "game") -- DataModel attributes can also carry replicated settings.
	local children = game:GetChildren()
	local priority = { ReplicatedStorage = 1, Workspace = 2, Players = 3 }
	table.sort(children, function(a, b)
		local pa, pb = priority[a.ClassName] or 10, priority[b.ClassName] or 10
		return pa == pb and a.ClassName < b.ClassName or pa < pb
	end)
	for _, child in ipairs(children) do
		if not excluded(child) then add(child, "game/" .. child.ClassName) end
	end
	for name, getter in pairs({ UserSettings = function() return UserSettings() end, Settings = function() return settings() end }) do
		local ok, value = pcall(getter)
		if ok and value then add(value, "@" .. name) else failures[name] = tostring(value):sub(1, 240) end
	end
	return roots, failures
end
local frameStats = { count = 0, totalDt = 0, maxDt = 0, over100ms = 0 }
local function extraContext()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local result = {
		player = encode(player), character = encode(char),
		placeId = safeEncoded(function() return game.PlaceId end),
		placeVersion = safeEncoded(function() return game.PlaceVersion end),
		gameId = safeEncoded(function() return game.GameId end), jobId = safeEncoded(function() return game.JobId end),
		privateServerId = safeEncoded(function() return game.PrivateServerId end),
		privateServerOwnerId = safeEncoded(function() return game.PrivateServerOwnerId end),
		clientNetworkPing = safeEncoded(function() return player:GetNetworkPing() end),
		joinTick = safeEncoded(function() return player:GetAttribute("JoinTick") end),
		frameCount = frameStats.count, meanDt = frameStats.count > 0 and frameStats.totalDt / frameStats.count or 0,
		maxDt = frameStats.maxDt, framesOver100ms = frameStats.over100ms,
		animations = {},
	}
	local ok, tracks = pcall(function() return hum and hum:GetPlayingAnimationTracks() or {} end)
	if ok then
		for _, track in ipairs(tracks) do
			local item = { id = idFor(track) }
			for _, key in ipairs({ "Animation", "Priority", "Speed", "TimePosition", "WeightCurrent", "WeightTarget", "IsPlaying", "Looped", "Length" }) do
				item[key] = safeEncoded(function() return track[key] end)
			end
			item.AnimationId = safeEncoded(function() return track.Animation and track.Animation.AnimationId end)
			table.insert(result.animations, item)
		end
	else result.animationError = tostring(tracks) end
	result.collisionGroups = safeEncoded(function()
		local physics = game:GetService("PhysicsService")
		local groups = physics:GetRegisteredCollisionGroups()
		local matrix = {}
		for _, a in ipairs(groups) do
			matrix[a.name] = {}
			for _, b in ipairs(groups) do matrix[a.name][b.name] = physics:CollisionGroupsAreCollidable(a.name, b.name) end
		end
		return matrix
	end)
	return result
end
local function notice(snapshot, text)
	if #snapshot.notices < CONFIG.MAX_NOTICES then table.insert(snapshot.notices, text)
	else snapshot.noticesOmitted = (snapshot.noticesOmitted or 0) + 1 end
end
local function collectSnapshot(label, token)
	captureNumber += 1
	local roots, rootFailures = collectRoots()
	local snapshot = { schemaVersion = 1, sessionId = sessionId, captureId = captureNumber, label = label,
		started = clockInfo(), records = {}, count = 0, complete = true, readFailures = {},
		valueLimits = { unavailable = 0, truncated = 0, depthLimited = 0, displayOnly = 0 },
		rootFailures = rootFailures, limits = table.clone(CONFIG), notices = {}, roots = {}, eventStart = eventSequence }
	if next(rootFailures) then snapshot.complete = false; notice(snapshot, "Some Settings roots are unavailable; see rootFailures.") end
	for _, root in ipairs(roots) do table.insert(snapshot.roots, root.path) end
	local queue, cursor, seen = roots, 1, {}
	local sliceStart, progressAt = os.clock(), 0
	while cursor <= #queue do
		if not alive or token ~= scanToken then return nil end
		if snapshot.count >= CONFIG.MAX_NODES or os.clock() - snapshot.started.monotonic > CONFIG.MAX_SCAN_SECONDS then
			snapshot.complete = false; notice(snapshot, "Node/time limit reached; missing objects are UNKNOWN, not proven removed."); break
		end
		local entry = queue[cursor]; cursor += 1
		local object = entry.object
		if not seen[object] and not excluded(object) then
			seen[object] = true
			if not object.Parent and not entry.root then
				snapshot.complete = false; notice(snapshot, "An object left the tree during capture: " .. entry.path)
			else
				local ok, record = pcall(readRecord, object, entry, snapshot)
				if ok then snapshot.records[record.id] = record; snapshot.count += 1
				else snapshot.complete = false; notice(snapshot, "Read race/error: " .. entry.path .. " " .. tostring(record):sub(1, 240)) end
				local childOK, children = pcall(function() return object:GetChildren() end)
				if childOK then
					local counts, ordinals = {}, {}
					for _, child in ipairs(children) do
						local key = child.ClassName .. ":" .. string.format("%q", child.Name)
						counts[key] = (counts[key] or 0) + 1
					end
					for _, child in ipairs(children) do
						if not excluded(child) then
							local key = child.ClassName .. ":" .. string.format("%q", child.Name)
							ordinals[key] = (ordinals[key] or 0) + 1
							if (entry.depth or 0) < CONFIG.MAX_DEPTH and #queue < CONFIG.MAX_QUEUE then
								table.insert(queue, { object = child, path = entry.path .. "/" .. key .. "#" .. ordinals[key],
									depth = (entry.depth or 0) + 1, ambiguous = entry.ambiguous or counts[key] > 1 })
							else snapshot.complete = false; notice(snapshot, "Depth/queue limit: " .. entry.path) end
						end
					end
				else snapshot.complete = false; notice(snapshot, "Children unavailable: " .. entry.path) end
			end
		end
		if os.clock() - progressAt > 0.25 then progressAt = os.clock(); message("Capturing " .. snapshot.count .. " objects… UI stays responsive; Cancel is available.") end
		if os.clock() - sliceStart >= CONFIG.SLICE_SECONDS then RunService.Heartbeat:Wait(); sliceStart = os.clock() end
	end
	if not alive or token ~= scanToken then return nil end
	snapshot.context = extraContext()
	countValueLimits(snapshot.context, snapshot.valueLimits)
	snapshot.finished = clockInfo(); snapshot.eventEnd = eventSequence
	snapshot.coverage = {
		noticesOmitted = snapshot.noticesOmitted or 0,
		samplingErrors = samplingErrors, watchReadErrors = watchReadErrors, serviceConnectionFailures = serviceConnectionFailures,
		watched = watchCount, connections = watchConnections, watchSkippedAttempts = watchSkipped, watchDenied = watchDenied,
		remoteWatchEnabled = remoteEnabled, remoteWatched = remoteCount, remoteSkippedAttempts = remoteSkipped,
		journalOverwritten = events.overwritten, journalRateDropped = eventRateDropped, pendingDropped = pendingDropped,
		samplesOverwritten = samples.overwritten,
	}
	notice(snapshot, "Client-visible / allowlisted properties only. Protected reads, clipped values, nonreplicated state and server code are not observable.")
	notice(snapshot, "CoreGui, CorePackages and scanner UI excluded. Snapshot is time-sliced, not atomic. Incoming remote events are keyword-filtered and optional; no RemoteFunction traffic is intercepted.")
	return snapshot
end

local function comparable(value, crossSession)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, item in pairs(value) do
		if not (crossSession and value.type == "Instance" and key == "id") then copy[key] = comparable(item, crossSession) end
	end
	return copy
end
compareSnapshots = function(before, after, yieldCheck)
	local cross = before.sessionId ~= after.sessionId
	local result = { crossSession = cross, beforeLabel = before.label, afterLabel = after.label,
		counts = {}, details = {}, motionDetails = {}, omittedDetails = 0, ambiguousMatches = 0, unknownMissing = 0 }
	local function add(kind, path, key, old, new)
		result.counts[kind] = (result.counts[kind] or 0) + 1
		local motionBudget = math.floor(CONFIG.MAX_DIFF_DETAILS * 0.2)
		local isMotion = kind == "MOTION_OR_STATE"
		local target = isMotion and result.motionDetails or result.details
		local limit = isMotion and motionBudget or CONFIG.MAX_DIFF_DETAILS - motionBudget
		if #target < limit then
			table.insert(target, { kind = kind, path = path, key = key, before = old, after = new })
		else result.omittedDetails += 1 end
	end
	local oldByKey, newByKey = {}, {}
	for id, record in pairs(before.records) do oldByKey[cross and record.path or id] = record end
	for id, record in pairs(after.records) do newByKey[cross and record.path or id] = record end
	local function fields(a, b, bucket, kind)
		local keys = {}
		for key in pairs(a[bucket]) do keys[key] = true end
		for key in pairs(b[bucket]) do keys[key] = true end
		for key in pairs(keys) do
			local old, new = a[bucket][key], b[bucket][key]
			if key:sub(1, 2) == "A/" and (not a.attributesReadable or not b.attributesReadable) then
				result.unknownMissing += 1
			elseif canonical(comparable(old, cross)) ~= canonical(comparable(new, cross)) then
				local inaccessible = (type(old) == "table" and old.type == "unavailable") or (type(new) == "table" and new.type == "unavailable")
				add(inaccessible and "ACCESS_CHANGED" or kind, b.path, key, old, new)
			end
		end
	end
	local processed, ordered = 0, {}
	for key in pairs(newByKey) do table.insert(ordered, key) end
	local function priority(record)
		if record.path:sub(1, 1) == "@" then return "0" .. record.path end
		if record.class:find("Value") or record.class == "Configuration" then return "1" .. record.path end
		return "2" .. record.path
	end
	table.sort(ordered, function(a, b) return priority(newByKey[a]) < priority(newByKey[b]) end)
	for _, key in ipairs(ordered) do
		local record = newByKey[key]
		local old = oldByKey[key]
		if not old then
			add(before.complete and "ADDED_INSTANCE" or "NEWLY_OBSERVED", record.path, record.class, nil, encode(record.class))
		else
			if cross and (old.ambiguousPath or record.ambiguousPath) then result.ambiguousMatches += 1 end
			if old.path ~= record.path then add("RENAMED_OR_MOVED", record.path, "path", encode(old.path), encode(record.path)) end
			if old.class ~= record.class then add("CLASS_CHANGED", record.path, "class", encode(old.class), encode(record.class)) end
			fields(old, record, "fields", "CONFIG_OR_ATTRIBUTE")
			fields(old, record, "motion", "MOTION_OR_STATE")
		end
		processed += 1
		if yieldCheck and processed % 32 == 0 and not yieldCheck() then result.cancelled = true; return result end
	end
	for key, record in pairs(oldByKey) do
		if not newByKey[key] then
			if after.complete then add("REMOVED_OR_STREAMED_OUT", record.path, record.class, encode(record.class), nil)
			else result.unknownMissing += 1 end
		end
	end
	for _, key in ipairs({ "placeId", "placeVersion", "gameId", "jobId", "privateServerId", "privateServerOwnerId", "collisionGroups" }) do
		local a, b = before.context[key], after.context[key]
		if canonical(a) ~= canonical(b) then add("ENVIRONMENT", "@context", key, a, b) end
	end
	if canonical(comparable(before.context.animations, cross)) ~= canonical(comparable(after.context.animations, cross)) then
		add("MOTION_OR_STATE", "@context", "animations", before.context.animations, after.context.animations)
	end
	for _, item in ipairs(result.motionDetails) do table.insert(result.details, item) end
	result.motionDetails = nil
	table.sort(result.details, function(a, b) return a.kind .. a.path .. a.key < b.kind .. b.path .. b.key end)
	return result
end

local function describe(value)
	local text = canonical(value)
	return #text <= 600 and text or text:sub(1, 600) .. "… [display shortened; use JSON]"
end
local function showPage()
	local pages = math.max(1, math.ceil(#viewText / CONFIG.PAGE_BYTES))
	viewPage = math.clamp(viewPage, 1, pages)
	if outputBox then outputBox.Text = viewText:sub((viewPage - 1) * CONFIG.PAGE_BYTES + 1, viewPage * CONFIG.PAGE_BYTES) end
	if pageLabel then pageLabel.Text = string.format("Page %d/%d · %d bytes · Copy buttons export all pages. Paste JSON here, then Import.", viewPage, pages, #viewText) end
end
local function show(text)
	viewText, viewPage = text, 1
	showPage()
end
renderReport = function()
	if not current then show("No current snapshot. Take Snapshot first. Imported baseline is retained if present."); return end
	local reference = comparePrevious and previous or baseline
	local lines = {
		"CLIENT CONFIG / PHYSICS SNAPSHOT SCANNER v1.0 — READ ONLY",
		"No five-minute config reset is assumed or proven by this scanner.",
		string.format("Capture #%d: %s | scanner age %.3fs | server time %s", current.captureId, current.label, current.started.scannerAge, tostring(current.started.serverTime)),
		string.format("Objects: %d | enumerated tree complete: %s | capture span %.3fs", current.count, tostring(current.complete), current.finished.monotonic - current.started.monotonic),
		"Comparison: " .. (reference and tostring(reference.label) or "none") .. (comparePrevious and " [previous]" or " [pinned baseline]"),
		"Scope roots: " .. table.concat(current.roots, ", "),
		string.format("Watchers %d / %d | skipped attempts %d | denied %d | passive remote listeners %d (enabled=%s)", watchCount, CONFIG.MAX_WATCHED, watchSkipped, watchDenied, remoteCount, tostring(remoteEnabled)),
		string.format("Journal retained %d; overwritten %d; rate-dropped %d | telemetry retained %d; overwritten %d | watch queue dropped %d", events.count, events.overwritten, eventRateDropped, samples.count, samples.overwritten, pendingDropped),
		"A/ = attributes; P/ = properties. Values are typed: false, zero, nil and unavailable are different.",
		"Motion/state changes are NOT automatically configuration changes. Streaming / respawn / normal scripts can explain differences.",
		"Protected reads are listed in JSON readFailures. Clipped/table-depth/display-only values may hide changes.",
		"Roots with unavailable children, scan limits or capture races prevent definitive removal claims.",
	}
	local reportBytes, clippedLines = #table.concat(lines, "\n"), 0
	local function addLine(text)
		if reportBytes + #text + 1 > CONFIG.MAX_REPORT_BYTES then clippedLines += 1; return end
		reportBytes += #text + 1; table.insert(lines, text)
	end
	if current.valueLimits then addLine("Typed value limits: " .. canonical(current.valueLimits)) end
	for _, notice in ipairs(current.notices) do addLine( "NOTICE: " .. notice) end
	if lastDiff and reference then
		addLine( "\n===== DIFFERENCE COUNTS =====")
		local keys = {}; for key in pairs(lastDiff.counts) do table.insert(keys, key) end; table.sort(keys)
		for _, key in ipairs(keys) do addLine( key .. ": " .. lastDiff.counts[key]) end
		addLine( string.format("Unknown missing fields/objects: %d | omitted diff details: %d | ambiguous path matches: %d", lastDiff.unknownMissing, lastDiff.omittedDetails, lastDiff.ambiguousMatches))
		if lastDiff.crossSession then addLine( "CROSS-RUN: matched by canonical path, not identity. Duplicate names / replacement objects can make comparisons ambiguous.") end
		if not next(lastDiff.counts) then addLine( "No differences detected in comparable captured fields. This does not rule out hidden, clipped, or transient changes.") end
		addLine( "\n===== CHANGES (CONFIG / ENVIRONMENT BEFORE MOTION) =====")
		for _, change in ipairs(lastDiff.details) do
			addLine( string.format("[%s] %s :: %s\n  BEFORE %s\n  AFTER  %s", change.kind, change.path, change.key, describe(change.before), describe(change.after)))
		end
	end
	addLine( "\n===== LOCAL PLAYER / CHARACTER CONFIGURATION =====")
	local idsSorted = {}; for id in pairs(current.records) do table.insert(idsSorted, id) end
	table.sort(idsSorted, function(a, b) return current.records[a].path < current.records[b].path end)
	for _, id in ipairs(idsSorted) do
		local record = current.records[id]
		if record.path == "@LocalPlayer" or record.class == "Humanoid" or record.path == "@Character" or record.class:find("Value") then
			addLine( record.path .. " [" .. record.class .. "]")
			local keys = {}; for key in pairs(record.fields) do table.insert(keys, key) end; table.sort(keys)
			for _, key in ipairs(keys) do addLine( "  " .. key .. " = " .. describe(record.fields[key])) end
		end
	end
	addLine( "\n===== RETAINED CHANGE JOURNAL SINCE REFERENCE CAPTURE START =====")
	local from = reference and reference.sessionId == sessionId and reference.eventStart or 0
	for _, item in ipairs(ringValues(events)) do
		if item.sequence > from then
			addLine( string.format("#%d age=%.3fs %s %s %s", item.sequence, item.time.scannerAge, item.kind, item.path or "", describe(item.detail)))
		end
	end
	addLine( "\nUse Copy JSON / Save JSON for full current snapshot, detailed diff, retained journal and telemetry. Exports can contain player identifiers and game-visible data; review before sharing.")
	if clippedLines > 0 then table.insert(lines, "REPORT LIMIT: " .. clippedLines .. " lines omitted. JSON contains the captured snapshot/diff details.") end
	show(table.concat(lines, "\n"))
end
local function recompute(token)
	local reference = comparePrevious and previous or baseline
	lastDiff = nil
	if current and reference then
		local slice = os.clock()
		local computed = compareSnapshots(reference, current, function()
			if not alive or token ~= scanToken then return false end
			if os.clock() - slice > CONFIG.SLICE_SECONDS then RunService.Heartbeat:Wait(); slice = os.clock() end
			return alive and token == scanToken
		end)
		if alive and token == scanToken then lastDiff = computed end
	end
end
local function capture(label)
	if busy then message("Scan/comparison already running. Cancel it first."); return end
	busy = true; scanToken += 1
	local token = scanToken
	task.spawn(function()
		local ok, snapshot = pcall(collectSnapshot, tostring(label or "manual"):sub(1, 256), token)
		if not alive or token ~= scanToken then return end
		if not ok or not snapshot then busy = false; message("Capture failed; previous snapshots preserved: " .. tostring(snapshot)); return end
		previous, current = current, snapshot
		if not baseline then baseline = snapshot end
		event("SNAPSHOT", nil, { label = snapshot.label, count = snapshot.count, complete = snapshot.complete })
		local reportOK, reportError = pcall(function() recompute(token); if token == scanToken and alive then renderReport() end end)
		if token == scanToken then
			busy = false
			message(reportOK and ("Snapshot ready. " .. (snapshot.complete and "Check readFailures/limits too." or "PARTIAL — see notices.")) or "Captured; report error: " .. tostring(reportError))
		end
	end)
end
local function exportJSON()
	if not current then return nil, "Take a snapshot first." end
	local reference = comparePrevious and previous or baseline
	local bundle = {
		format = "client-config-snapshot", scannerVersion = "1.0", schemaVersion = 1, exportedAt = clockInfo(), snapshot = current,
		propertyFamilies = PROPERTY_GROUPS,
		reference = reference and { sessionId = reference.sessionId, captureId = reference.captureId, label = reference.label } or nil,
		diff = lastDiff, journal = ringValues(events), telemetry = ringValues(samples),
		journalCoverage = { firstRetained = events.count > 0 and ringValues(events)[1].sequence or nil,
			lastIssued = eventSequence, overwritten = events.overwritten, rateDropped = eventRateDropped,
			watchEnabled = watchEnabled, remoteEnabled = remoteEnabled, watchSkippedAttempts = watchSkipped,
			remoteSkippedAttempts = remoteSkipped, pendingDropped = pendingDropped, samplingErrors = samplingErrors,
			watchReadErrors = watchReadErrors, serviceConnectionFailures = serviceConnectionFailures },
		limitations = "Client-visible allowlisted data, not atomic; clipped and inaccessible data, unwatched transient changes, streaming and unknown server-only state remain possible. No remotes invoked.",
	}
	local ok, text = pcall(function() return HttpService:JSONEncode(bundle) end)
	if not ok then return nil, "JSON encoding failed: " .. tostring(text) end
	if #text > CONFIG.MAX_EXPORT_BYTES then return nil, "Export exceeds 32 MiB limit. Reduce MAX_NODES / property scope for another capture, or deliberately raise MAX_EXPORT_BYTES." end
	return text
end
local function validateSnapshot(snapshot)
	if type(snapshot) ~= "table" or snapshot.schemaVersion ~= 1 or type(snapshot.records) ~= "table"
		or type(snapshot.sessionId) ~= "string" or type(snapshot.label) ~= "string"
		or type(snapshot.captureId) ~= "number" or type(snapshot.complete) ~= "boolean"
		or type(snapshot.context) ~= "table" then return false, "Not a supported snapshot." end
	local visited = 0
	local function bounded(value, depth)
		visited += 1
		if visited > 4000000 or depth > 32 then return false end
		if type(value) == "table" then for key, child in pairs(value) do if not bounded(key, depth + 1) or not bounded(child, depth + 1) then return false end end end
		return type(value) ~= "number" or (value == value and math.abs(value) < math.huge)
	end
	if not bounded(snapshot, 0) then return false, "Imported snapshot nesting/value budget exceeded." end
	local count, paths = 0, {}
	for id, record in pairs(snapshot.records) do
		count += 1
		if count > CONFIG.MAX_NODES or type(id) ~= "string" or type(record) ~= "table"
			or record.id ~= id or type(record.path) ~= "string" or type(record.class) ~= "string"
			or type(record.fields) ~= "table" or type(record.motion) ~= "table" then return false, "Invalid/oversized records." end
		if paths[record.path] then return false, "Duplicate canonical paths in import." end
		paths[record.path] = true
	end
	if snapshot.count ~= count then return false, "Record count mismatch." end
	if type(snapshot.eventStart) ~= "number" or type(snapshot.started) ~= "table"
		or type(snapshot.started.scannerAge) ~= "number" then return false, "Missing capture timing." end
	return true
end
local function importBaseline(text)
	if busy then return false, "Wait for the active scan/comparison." end
	if #text > CONFIG.MAX_EXPORT_BYTES then return false, "Import exceeds 32 MiB." end
	local ok, bundle = pcall(function() return HttpService:JSONDecode(text) end)
	if not ok or type(bundle) ~= "table" then return false, "Paste complete exported JSON, not one page or a text report." end
	local snapshot = bundle.snapshot or bundle
	local valid, reason = validateSnapshot(snapshot)
	if not valid then return false, reason end
	baseline = snapshot; comparePrevious = false
	return true, "Imported baseline: " .. snapshot.label .. ". Take a new snapshot to compare."
end

-- UI: no gameplay edits, automatic scans, automatic exports or clipboard reads.
local oldGui = playerGui:FindFirstChild(GUI_NAME)
if oldGui then oldGui:Destroy() end
gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME; gui.ResetOnSpawn = false; gui.DisplayOrder = 1000; gui.Parent = playerGui
local panel = Instance.new("Frame")
panel.Size = UDim2.new(0.9, 0, 0.88, 0); panel.Position = UDim2.new(0.05, 0, 0.06, 0)
panel.BackgroundColor3 = Color3.fromRGB(17, 22, 31); panel.BorderSizePixel = 0; panel.Parent = gui
local function textLabel(text, y, height)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -20, 0, height); label.Position = UDim2.fromOffset(10, y)
	label.BackgroundTransparency = 1; label.TextColor3 = Color3.fromRGB(204, 224, 241)
	label.TextSize = 11; label.Font = Enum.Font.Code; label.TextWrapped = true; label.Text = text; label.Parent = panel
	return label
end
local titleLabel = textLabel("CONFIG / PHYSICS SNAPSHOT SCANNER · READ ONLY", 4, 24)
titleLabel.Size = UDim2.new(1, -180, 0, 24)
local function button(text, column, y, callback)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0.25, -12, 0, 28); b.Position = UDim2.new(column * 0.25, 6, 0, y)
	b.BackgroundColor3 = Color3.fromRGB(42, 66, 92); b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold; b.TextSize = 10; b.TextWrapped = true; b.Text = text; b.Parent = panel
	b.Activated:Connect(callback); return b
end
local function idleAction(fn)
	if busy then message("Scan/comparison running. Wait or Cancel."); return end
	fn()
end
local function refreshComparison()
	busy = true; scanToken += 1
	local token = scanToken
	task.spawn(function()
		local ok, err = pcall(function() recompute(token); if alive and token == scanToken then renderReport() end end)
		if token == scanToken then busy = false; if not ok then message("Comparison error: " .. tostring(err)) end end
	end)
end
local function clipboard(text)
	local copy = setclipboard or toclipboard
	if typeof(copy) ~= "function" then return false end
	local ok, result = pcall(copy, text)
	return ok and result ~= false
end
local snapshotButton = button("SNAPSHOT", 0, 32, function() capture(labelInput.Text) end)
local compareButton
local baselineButton = button("PIN BASELINE", 1, 32, function()
	idleAction(function()
		if not current then message("Take a snapshot first."); return end
		baseline = current; comparePrevious = false; compareButton.Text = "DIFF: BASELINE"; refreshComparison(); message("Pinned: " .. baseline.label)
	end)
end)
compareButton = button("DIFF: BASELINE", 2, 32, function()
	idleAction(function()
		comparePrevious = not comparePrevious
		compareButton.Text = comparePrevious and "DIFF: PREVIOUS" or "DIFF: BASELINE"
		refreshComparison()
	end)
end)
local cancelButton = button("CANCEL SCAN", 3, 32, function()
	scanToken += 1; busy = false; message("Capture/comparison cancelled. Completed snapshots retained.")
end)
local watchButton
watchButton = button("WATCH: ON", 0, 66, function()
	watchEnabled = not watchEnabled; watchButton.Text = watchEnabled and "WATCH: ON" or "WATCH: OFF"
	if not watchEnabled then
		local objects = {}; for object in pairs(watched) do table.insert(objects, object) end
		for _, object in ipairs(objects) do disconnectWatch(object) end
		for object, connection in pairs(remoteWatches) do connection:Disconnect(); remoteWatches[object] = nil end
		remoteCount = 0; pending = {}; pendingHead, pendingTail = 1, 0
	else enqueue(player); enqueue(player.Character); enqueue(Workspace) end
	message(watchEnabled and "Take a snapshot to attach broad attribute/config watchers." or "Live journal and movement sampling paused; manual snapshots still work.")
end)
local remoteButton
remoteButton = button("REMOTE EVENTS: OFF", 1, 66, function()
	remoteEnabled = not remoteEnabled
	remoteButton.Text = remoteEnabled and "REMOTE EVENTS: ON" or "REMOTE EVENTS: OFF"
	if remoteEnabled then for object in pairs(remoteCandidates) do attachRemote(object) end
	else for object, connection in pairs(remoteWatches) do connection:Disconnect(); remoteWatches[object] = nil end; remoteCount = 0 end
	message("Passive matching RemoteEvents only; no remote requests or RemoteFunction hooks.")
end)
local copyReportButton = button("COPY REPORT", 2, 66, function()
	idleAction(function()
		renderReport()
		message(clipboard(viewText) and "Full report copied." or "Clipboard unavailable. Select/copy pages manually, or use Save JSON.")
	end)
end)
local copyJSONButton = button("COPY JSON", 3, 66, function()
	idleAction(function()
		local text, err = exportJSON(); if not text then message(err); return end
		show(text); message(clipboard(text) and "Full JSON copied; save it before rejoining." or "Clipboard unavailable. Save JSON or concatenate all pages exactly.")
	end)
end)
local exportNumber = 0
local saveButton = button("SAVE JSON FILE", 0, 100, function()
	idleAction(function()
		if typeof(writefile) ~= "function" then message("File API unavailable. Use Copy JSON instead."); return end
		local text, err = exportJSON(); if not text then message(err); return end
		exportNumber += 1
		local name = "config-snapshot-" .. sessionId:gsub("[^%w%-]", "_") .. "-" .. current.captureId .. "-" .. exportNumber .. ".json"
		local ok, failure = pcall(writefile, name, text)
		message(ok and "Saved in executor file workspace: " .. name or "Save failed: " .. tostring(failure))
	end)
end)
local importButton = button("IMPORT PASTED JSON", 1, 100, function()
	local ok, result = importBaseline(outputBox.Text)
	message(result)
	if ok then compareButton.Text = "DIFF: BASELINE"; refreshComparison() end
end)
button("PREVIOUS PAGE", 2, 100, function() viewPage -= 1; showPage() end)
button("NEXT PAGE", 3, 100, function() viewPage += 1; showPage() end)
labelInput = Instance.new("TextBox")
labelInput.Size = UDim2.new(1, -20, 0, 28); labelInput.Position = UDim2.fromOffset(10, 136)
labelInput.BackgroundColor3 = Color3.fromRGB(31, 39, 53); labelInput.TextColor3 = Color3.new(1, 1, 1)
labelInput.Text = "fresh join / working / failed / after 5 minutes"; labelInput.ClearTextOnFocus = false
labelInput.TextSize = 11; labelInput.Font = Enum.Font.Code; labelInput.Parent = panel
hudLabel = textLabel("Scanner age 0s. Manual capture only.", 166, 24)
statusLabel = textLabel("Take a baseline now, then manually capture working and failing conditions. No game properties are changed.", 190, 30)
outputBox = Instance.new("TextBox")
outputBox.Size = UDim2.new(1, -20, 1, -270); outputBox.Position = UDim2.fromOffset(10, 224)
outputBox.BackgroundColor3 = Color3.fromRGB(8, 12, 18); outputBox.TextColor3 = Color3.fromRGB(196, 217, 235)
outputBox.TextSize = 10; outputBox.Font = Enum.Font.Code; outputBox.TextXAlignment = Enum.TextXAlignment.Left
outputBox.TextYAlignment = Enum.TextYAlignment.Top; outputBox.TextWrapped = false
outputBox.MultiLine = true; outputBox.ClearTextOnFocus = false; outputBox.Parent = panel
pageLabel = textLabel("", 0, 20); pageLabel.Position = UDim2.new(0, 10, 1, -42)
local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(60, 20); closeButton.Position = UDim2.new(1, -70, 1, -21)
closeButton.Text = "CLOSE"; closeButton.Parent = panel
closeButton.Activated:Connect(function() gui:Destroy() end)
local minimizeButton = Instance.new("TextButton")
minimizeButton.Size = UDim2.fromOffset(84, 20); minimizeButton.Position = UDim2.new(1, -160, 0, 4)
minimizeButton.Text = "MINIMIZE"; minimizeButton.Parent = panel
local minimized, savedVisibility = false, {}
minimizeButton.Activated:Connect(function()
	minimized = not minimized
	if minimized then
		for _, child in ipairs(panel:GetChildren()) do
			if child:IsA("GuiObject") and child ~= titleLabel and child ~= minimizeButton and child ~= closeButton then
				savedVisibility[child] = child.Visible; child.Visible = false
			end
		end
		panel.Size = UDim2.new(0.9, 0, 0, 28); minimizeButton.Text = "RESTORE"
	else
		panel.Size = UDim2.new(0.9, 0, 0.88, 0); minimizeButton.Text = "MINIMIZE"
		for child, visible in pairs(savedVisibility) do if child.Parent then child.Visible = visible end end
		savedVisibility = {}
	end
end)
showPage()

-- Lightweight live journal. Discovery only queues work; property inspection is
-- budgeted on Heartbeat. No per-frame world rescans or per-event UI rebuilding.
local lastRoot, lastPosition, lastSampleAt, lastDisplacement = nil, nil, nil, nil
local nextSample, nextHud, nextBoundary = 0, 0, 300
local phaseFrame, preFrame = 0, nil
local function addConnection(getter, callback)
	local ok, connection = pcall(function() return getter():Connect(callback) end)
	if ok then table.insert(connections, connection) else serviceConnectionFailures += 1 end
end
local function movementSample()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum then lastRoot, lastPosition, lastSampleAt, lastDisplacement = nil, nil, nil, nil; return end
	local now, pos, velocity = os.clock(), root.Position, root.AssemblyLinearVelocity
	if root ~= lastRoot then lastPosition, lastSampleAt, lastDisplacement = nil, nil, nil end
	local dt = lastSampleAt and now - lastSampleAt or nil
	local displacement = lastPosition and pos - lastPosition or Vector3.zero
	local estimated = dt and dt > 0 and displacement.Magnitude / dt or 0
	local ground = safeEncoded(function()
		local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char }
		local hit = Workspace:Raycast(pos, Vector3.new(0, -200, 0), params)
		-- No fabricated ground height on ray miss.
		return hit and { part = hit.Instance, y = hit.Position.Y, clearance = pos.Y - hit.Position.Y, material = hit.Material } or nil
	end)
	local item = { time = clockInfo(), rootId = idFor(root), dt = dt, position = encode(pos),
		velocity = encode(velocity), angularVelocity = encode(root.AssemblyAngularVelocity),
		displacementSpeed = estimated, physicalSpeed = velocity.Magnitude, state = safeEncoded(function() return hum:GetState() end),
		walkSpeed = hum.WalkSpeed, anchored = root.Anchored, platformStand = hum.PlatformStand,
		ground = ground, networkOwner = safeEncoded(function() return root:GetNetworkOwner() end),
		ragdollEndTime = safeEncoded(function() return player:GetAttribute("RagdollEndTime") end) }
	push(samples, item)
	if dt and (displacement.Magnitude >= 100 or estimated > velocity.Magnitude * 2.5 + 100) then
		event("POSITION_VELOCITY_MISMATCH", root, { distance = displacement.Magnitude, dt = dt,
			positionSpeed = estimated, physicalSpeed = velocity.Magnitude, note = "heuristic only; not proof of CFrame writes/server correction" })
	end
	if lastDisplacement and lastDisplacement.Magnitude > 1 and displacement.Magnitude > 5 then
		local dot = lastDisplacement.Unit:Dot(displacement.Unit)
		if dot < -0.6 then event("DIRECTION_REVERSAL", root, { dot = dot, distance = displacement.Magnitude }) end
	end
	lastRoot, lastPosition, lastSampleAt, lastDisplacement = root, pos, now, displacement
end
addConnection(function() return game.DescendantAdded end, function(object)
	if not excluded(object) then event("INSTANCE_ADDED", object, { class = object.ClassName }); enqueue(object) end
end)
addConnection(function() return game.DescendantRemoving end, function(object)
	if not excluded(object) then event("INSTANCE_LEAVING_TREE", object, { class = object.ClassName, note = "may be reparenting, streaming or destruction" }) end
	disconnectWatch(object)
end)
addConnection(function() return player.CharacterAdded end, function(character)
	lastRoot = nil; event("RESPAWN", character, {}); enqueue(character)
end)
addConnection(function() return player.CharacterRemoving end, function(character)
	event("CHARACTER_REMOVING", character, {}); lastRoot = nil
end)
-- Match physics phases by an explicit step counter, not equality of two
-- os.clock() calls (the v2.8 render/heartbeat equality is unreliable).
addConnection(function() return RunService.PreSimulation end, function(dt)
	phaseFrame += 1
	local char = player.Character; local root = char and char:FindFirstChild("HumanoidRootPart")
	preFrame = watchEnabled and root and { frame = phaseFrame, root = root, position = root.Position,
		velocity = root.AssemblyLinearVelocity, dt = dt, time = os.clock() } or nil
end)
addConnection(function() return RunService.PostSimulation end, function(dt)
	if not preFrame or preFrame.frame ~= phaseFrame or not preFrame.root.Parent then return end
	local delta = (preFrame.root.Position - preFrame.position).Magnitude
	local tolerance = math.max(preFrame.velocity.Magnitude, preFrame.root.AssemblyLinearVelocity.Magnitude) * math.max(dt, 0.001) + 10
	if watchEnabled and delta > tolerance then event("PHYSICS_PHASE_DELTA", preFrame.root, {
		frame = phaseFrame, displacement = delta, dt = dt, elapsed = os.clock() - preFrame.time,
		note = "same-step heuristic; source of movement is unknown" }) end
	preFrame = nil
end)
addConnection(function() return RunService.Heartbeat end, function(dt)
	if not alive then return end
	frameStats.count += 1; frameStats.totalDt += dt; frameStats.maxDt = math.max(frameStats.maxDt, dt)
	if dt > 0.1 then frameStats.over100ms += 1 end
	local workStart, processed = os.clock(), 0
	while watchEnabled and pendingHead <= pendingTail and processed < 10 and os.clock() - workStart < CONFIG.SLICE_SECONDS do
		local object = pending[pendingHead]; pending[pendingHead] = nil; pendingHead += 1; processed += 1
		if object and object.Parent then
			local ok = pcall(function() watchNode(object, object:GetAttributes()) end)
			if not ok then watchReadErrors += 1 end
		end
	end
	if pendingHead > pendingTail then pending, pendingHead, pendingTail = {}, 1, 0 end
	local age = os.clock() - startedAt
	if age >= nextBoundary then
		event("300_SECOND_MARKER", nil, { age = age, note = "scanner elapsed marker only; NOT evidence of a server config reset" })
		nextBoundary = (math.floor(age / 300) + 1) * 300
	end
	if watchEnabled and os.clock() >= nextSample then
		nextSample = os.clock() + CONFIG.SAMPLE_INTERVAL
		local ok = pcall(movementSample)
		if not ok then samplingErrors += 1 end
	end
	if os.clock() >= nextHud then
		nextHud = os.clock() + 1
		local join = player:GetAttribute("JoinTick")
		local serverOK, server = pcall(function() return Workspace:GetServerTimeNow() end)
		local joinAge = serverOK and typeof(join) == "number" and server >= join and server - join < 86400 * 30
			and string.format("%.0fs", server - join) or "unavailable"
		hudLabel.Text = string.format("Scanner age %.0fs · next 300s marker %.0fs · JoinTick-derived age %s (attribute semantics unverified) · watched %d", age, nextBoundary - age, joinAge, watchCount)
	end
end)
gui.Destroying:Connect(function()
	if not alive then return end
	alive = false; scanToken += 1; busy = false
	for _, connection in ipairs(connections) do connection:Disconnect() end
	local objects = {}; for object in pairs(watched) do table.insert(objects, object) end
	for _, object in ipairs(objects) do disconnectWatch(object) end
	for _, connection in pairs(remoteWatches) do connection:Disconnect() end
	remoteWatches = {}; remoteCount = 0; pending = {}; pendingHead, pendingTail = 1, 0
	baseline, previous, current, lastDiff = nil, nil, nil, nil
end)
enqueue(player); enqueue(player.Character); enqueue(Workspace)
event("SCANNER_READY", nil, { session = sessionId, manual = true, remoteObservation = false })
