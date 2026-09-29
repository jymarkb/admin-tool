--[[
=====================================================================
 PICKUP TIMELINE SCANNER  v1.0
 -------------------------------------------------------------------
 READ-ONLY. Answers one question:
   "What is visibly happening on the CLIENT right after an egg pickup?"

 It records a timestamped timeline of:
   * client-visible RemoteEvent traffic .......... OPT-IN, OFF BY DEFAULT
   * attribute changes (player / character / tools / value objects)
   * Humanoid state transitions
   * Motor6D enable/disable flips
   * WalkSpeed / JumpPower / physics property changes
   * tools and egg-candidate objects appearing or disappearing
   * manual Marks (A / B) with a full snapshot and a diff

 After any pickup-like client event it automatically takes a snapshot of
 the current values, waits ~1 second, takes another one and prints the
 diff. That shows which observable values moved after the pickup, and in
 what order, instead of guessing.

 LIMITS - what this file can NOT show you:
   * It cannot see server-side logic, hidden debuff formulas, or how a
     carry restriction is enforced. It only shows client-visible effects.
   * RemoteFunctions cannot be observed safely (connecting
     OnClientInvoke would hijack them), so they are listed but never
     connected.
   * A client-side velocity/position change proves the client changed its
     own assembly. It does not prove the server accepted the motion.

 SAFETY PROMISE
   * It never writes to gameplay state: no velocity, CFrame, Humanoid,
     joint, attribute, tag, tool or physics writes.
   * It never invokes or fires any remote.
   * The only instances it creates are its own ScreenGui and UI objects.
   * Close disconnects every connection it made and destroys its GUI.

 ADVANCED (optional, read-only)
   _G.PICKUP_TIMELINE_SCANNER exposes: stop(), mark("A"), compare(),
   pollOnce(), capture("label"), report(full), exportJson(), journal(),
   counters(), state(), setObserve(bool), discoverRemotes(bool).

 USAGE
   1) Execute this file (fresh join is best).
   2) Press "Mark A"  -> walk / pick up the egg -> press "Mark B".
   3) Press "Compare A -> B" if you want the manual before/after diff.
   4) Turn "Observe remotes: ON" if you want the exact client event list.
   5) Press "Copy Report" or "Save JSON" and paste the result back.

 Rerunning this file is safe: an older still-running copy is stopped first
 (this is different from scripts that leak connections when rerun).
=====================================================================
]]

--==================================================
-- CONFIG / LIMITS
--==================================================

local CONFIG = {
	POLL_INTERVAL = 0.25,        -- seconds between property polls
	JOINT_SCAN_INTERVAL = 1.0,   -- seconds between full Motor6D scans
	JOURNAL_CAP = 4000,          -- stored timeline entries
	JOURNAL_PAGE = 40,           -- lines per report page
	MAX_TEXT_BYTES = 24000,      -- rendered report text cap
	MAX_JSON_BYTES = 2 * 1024 * 1024,
	EVENT_WINDOW = 10,           -- rate-limit window (seconds)
	EVENT_MAX = 300,             -- max logged events per window
	REMOTE_CAP = 128,            -- discovered remotes kept
	REMOTE_WATCH_CAP = 96,       -- remotes connected when opt-in is ON
	REMOTE_DEPTH = 4,            -- discovery BFS depth from game
	REMOTE_NODES = 30000,        -- discovery BFS node cap
	FOCUS_PARTS_CAP = 24,        -- character parts polled for physics props
	TOOLS_CAP = 32,              -- tools tracked per container
	ATTR_CAP = 64,               -- attributes read per instance
	TAG_CAP = 32,                -- tags read per instance
	ARG_DEPTH = 3,               -- remote argument format depth
	ARG_ITEMS = 6,               -- remote argument format width
	STR_CAP = 160,               -- string cap in log lines
	AUTO_DIFF_CAP = 8,           -- automatic post-event diffs kept
	AUTO_DIFF_DELAY = 1.0,       -- seconds after event to diff
	AUTO_DIFF_MIN_GAP = 1.25,    -- min gap between auto-diffs
	SNAPSHOT_KEYS_CAP = 900,     -- keys per snapshot
}

local AUTO_DIFF_KEYWORDS = {
	"carry", "drop", "egg", "wear", "doff", "hatch", "owner",
}

local WATCH_KEYWORDS = {
	"egg", "carry", "guard", "treadmill", "ragdoll", "speed", "stun",
	"toll", "verdict", "zone", "probe", "owner", "hatch", "wear",
	"doff", "drop", "shift",
}

--==================================================
-- SMALL SAFE HELPERS
--==================================================

local function safeCall(fn, ...)

	if type(fn) ~= "function" then
		return false, nil
	end

	local ok, a, b, c = pcall(fn, ...)

	if ok then
		return true, a, b, c
	end

	return false, nil
end

local function truncate(text, cap)

	text = tostring(text)

	if #text <= cap then
		return text
	end

	return string.sub(text, 1, cap - 3) .. "..."
end

-- Canonical, comparable string for any value we log or diff.
local function vkey(value)

	local kind = typeof(value)

	if kind == "number" then

		if value ~= value then
			return "nan"
		end

		if value == math.huge then
			return "inf"
		end

		if value == -math.huge then
			return "-inf"
		end

		if value == math.floor(value) and math.abs(value) < 1e15 then
			return string.format("%d", value)
		end

		local text = string.format("%.6f", value)
		text = string.gsub(text, "0+$", "")
		text = string.gsub(text, "%.$", "")

		return text

	elseif kind == "boolean" then

		return value and "true" or "false"

	elseif kind == "string" then

		return truncate(value, CONFIG.STR_CAP)

	elseif kind == "Vector3" then

		return string.format(
			"(x=%s y=%s z=%s)",
			vkey(value.X),
			vkey(value.Y),
			vkey(value.Z)
		)

	elseif kind == "Vector2" then

		return string.format(
			"(x=%s y=%s)",
			vkey(value.X),
			vkey(value.Y)
		)

	elseif kind == "CFrame" then

		return "CFrame"

	elseif kind == "Color3" then

		return string.format(
			"Color3(%s,%s,%s)",
			vkey(value.R),
			vkey(value.G),
			vkey(value.B)
		)

	elseif kind == "EnumItem" then

		return tostring(value)

	elseif kind == "Instance" then

		return value.ClassName .. "/" .. truncate(value.Name, 60)

	elseif kind == "table" then

		local keys = {}

		for key in pairs(value) do

			if #keys >= 12 then
				break
			end

			keys[#keys + 1] = key
		end

		table.sort(
			keys,
			function(a, b)
				return tostring(a) < tostring(b)
			end
		)

		local parts = {}

		for _, key in ipairs(keys) do

			parts[#parts + 1] =
				tostring(key) .. "=" .. vkey(value[key])
		end

		return "{" .. table.concat(parts, ",") .. "}"

	end

	return truncate(tostring(value), CONFIG.STR_CAP)
end

local function shortPath(instance)

	local ok, path = safeCall(function()
		return instance:GetFullName()
	end)

	if ok and type(path) == "string" then
		return truncate(path, 110)
	end

	local okName, name = safeCall(function()
		return instance.Name
	end)

	return truncate(tostring(name or "?"), 110)
end

--==================================================
-- SERVICES / PLAYER
--==================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- Bounded wait so this never hangs if the environment is unusual.
do

	local waited = 0

	while not LocalPlayer and waited < 10 do

		task.wait(0.25)
		waited = waited + 0.25
		LocalPlayer = Players.LocalPlayer
	end
end

if not LocalPlayer then

	warn("[Pickup Scanner] LocalPlayer not available; aborting.")

	return
end

--==================================================
-- RERUN GUARD (stop an older still-running copy)
--==================================================

do

	local previous = _G.PICKUP_TIMELINE_SCANNER

	if type(previous) == "table" then

		safeCall(function()
			previous.stop("replaced by a newer run")
		end)
	end
end

--==================================================
-- STATE
--==================================================

local scriptAlive = true
local paused = false
local observeRemotes = false
local connections = {}
local threads = {}
local remotes = {}
local remoteConnections = {}
local watchedAttributes = {}
local attributeConnections = {}
local descendantConnections = {}
local focusRoots = {}
local journal = {}
local journalDropped = 0
local errorCount = 0
local truncatedCount = 0
local autoDiffs = {}
local pendingDiffs = {}
local lastAutoDiff = 0
local counters = {
	events = 0,
	eventDrops = 0,
	attrChanges = 0,
	stateChanges = 0,
	jointFlips = 0,
	propChanges = 0,
	toolChanges = 0,
	marks = 0,
	compares = 0,
}
local eventTimes = {}

local t0 = os.clock()
local pollPrev = {}
local lastJointScan = 0
local jointsPrev = {}
local characterParts = {}
local markA = nil
local markB = nil
local lastCompare = nil
local reportPage = 1

-- Forward declarations: poll() calls these, and they are defined further
-- down. Without this, poll() would resolve them as nil globals.
local snapshotFromPollPrev
local scheduleAutoDiff
local pumpAutoDiffs
local reflectObserveButton
local stopScanner

local function nowSeconds()
	return os.clock()
end

local function elapsedMs()
	return (nowSeconds() - t0) * 1000
end

local function serverNow()

	local ok, value = safeCall(function()
		return Workspace:GetServerTimeNow()
	end)

	if ok and type(value) == "number" then
		return value
	end

	return nil
end

local function stamp()

	local ms = elapsedMs()
	local minutes = math.floor(ms / 60000)
	local seconds = (ms % 60000) / 1000

	return string.format(
		"%02d:%06.3f",
		minutes,
		seconds
	)
end

--==================================================
-- JOURNAL
--==================================================

local function rateAllowed()

	local now = nowSeconds()
	local kept = {}

	for _, time in ipairs(eventTimes) do

		if now - time < CONFIG.EVENT_WINDOW then
			kept[#kept + 1] = time
		end
	end

	eventTimes = kept

	if #eventTimes >= CONFIG.EVENT_MAX then
		return false
	end

	eventTimes[#eventTimes + 1] = now

	return true
end

local function addEntry(category, text, options)

	options = options or {}

	if paused and not options.force then
		return
	end

	if not scriptAlive and not options.force then
		return
	end

	if #journal >= CONFIG.JOURNAL_CAP then

		table.remove(journal, 1)
		journalDropped = journalDropped + 1
	end

	journal[#journal + 1] = {
		t = elapsedMs(),
		cat = category,
		text = truncate(text, 400),
		server = serverNow(),
	}
end

local function note(text)
	addEntry("NOTE", text)
end

--==================================================
-- CONNECTION / THREAD REGISTRY
--==================================================

local function connect(signal, callback)

	if not signal then
		return nil
	end

	local ok, conn = safeCall(function()
		return signal:Connect(callback)
	end)

	if ok and conn then

		connections[#connections + 1] = conn

		return conn
	end

	errorCount = errorCount + 1

	return nil
end

local function disconnectAll()

	for _, conn in ipairs(connections) do

		safeCall(function()
			conn:Disconnect()
		end)
	end

	connections = {}
	remoteConnections = {}
end

local function spawn(fn)

	local ok, thread = safeCall(function()
		return task.spawn(fn)
	end)

	if ok and thread then
		threads[#threads + 1] = thread
	end

	return ok
end

--==================================================
-- INSTANCE READERS (never write)
--==================================================

local function readAttributes(instance, into)

	if #into >= CONFIG.ATTR_CAP then
		truncatedCount = truncatedCount + 1
		return
	end

	local ok, names = safeCall(function()
		return instance:GetAttributes()
	end)

	if not ok or type(names) ~= "table" then
		return
	end

	table.sort(names)

	local used = 0

	for _, name in ipairs(names) do

		if used >= CONFIG.ATTR_CAP then
			truncatedCount = truncatedCount + 1
			break
		end

		local okValue, value = safeCall(function()
			return instance:GetAttribute(name)
		end)

		if okValue then

			into[#into + 1] = {
				key = shortPath(instance) .. " @" .. tostring(name),
				value = vkey(value),
			}

			used = used + 1

		else
			errorCount = errorCount + 1
		end
	end
end

local function readTags(instance, into)

	local ok, tags = safeCall(function()
		return instance:GetTags()
	end)

	if not ok or type(tags) ~= "table" then
		return
	end

	table.sort(tags)

	local used = 0

	for _, tag in ipairs(tags) do

		if used >= CONFIG.TAG_CAP then
			truncatedCount = truncatedCount + 1
			break
		end

		into[#into + 1] = {
			key = shortPath(instance) .. " #tag",
			value = tostring(tag),
		}

		used = used + 1
	end
end

local function readProperty(instance, propertyName, into)

	local ok, value = safeCall(function()
		return instance[propertyName]
	end)

	if ok then

		into[#into + 1] = {
			key = shortPath(instance) .. "." .. propertyName,
			value = vkey(value),
		}

	else
		errorCount = errorCount + 1
	end
end

local HUMAN_SCAN_PROPS = {
	"WalkSpeed", "JumpPower", "JumpHeight", "Health", "MaxHealth",
	"PlatformStand", "AutoRotate", "Sit",
}

local PART_SCAN_PROPS = {
	"Massless", "CanCollide", "Anchored", "RootPriority",
}

local TOOL_SCAN_PROPS = {
	"Enabled", "CanBeDropped", "RequiresHandle",
}

local function safeFindOfClass(parent, className)

	if not parent then
		return nil
	end

	local ok, found = safeCall(function()
		return parent:FindFirstChildOfClass(className)
	end)

	if ok then
		return found
	end

	return nil
end

local function safeFindChild(parent, name)

	if not parent then
		return nil
	end

	local ok, found = safeCall(function()
		return parent:FindFirstChild(name)
	end)

	if ok then
		return found
	end

	return nil
end

local function isEggName(name)

	name = string.lower(tostring(name or ""))

	return string.find(name, "egg", 1, true) ~= nil
end

local function collectTools(player, into)

	local containers = {}

	local backpack = safeFindOfClass(player, "Backpack")

	if backpack then
		containers[#containers + 1] = backpack
	end

	local character = player.Character

	if character then
		containers[#containers + 1] = character
	end

	local count = 0

	for _, container in ipairs(containers) do

		local ok, children = safeCall(function()
			return container:GetChildren()
		end)

		if ok and type(children) == "table" then

			for _, child in ipairs(children) do

				local okTool, isTool = safeCall(function()
					return child:IsA("Tool")
				end)

				if okTool and isTool then

					if count >= CONFIG.TOOLS_CAP then
						truncatedCount = truncatedCount + 1
						break
					end

					count = count + 1

					into[#into + 1] = {
						key = shortPath(child) .. " (tool in "
							.. container.Name .. ")",
						value = "egg-candidate="
							.. (isEggName(child.Name) and "true" or "false"),
					}

					for _, propertyName in ipairs(TOOL_SCAN_PROPS) do
						readProperty(child, propertyName, into)
					end

					readAttributes(child, into)
				end
			end
		end
	end

	return count
end

local function collectCharacterParts(character, into)

	local count = 0

	local ok, children = safeCall(function()
		return character:GetChildren()
	end)

	if not ok or type(children) ~= "table" then
		return 0
	end

	for _, child in ipairs(children) do

		local okPart, isPart = safeCall(function()
			return child:IsA("BasePart")
		end)

		if okPart and isPart then

			if count >= CONFIG.FOCUS_PARTS_CAP then
				truncatedCount = truncatedCount + 1
				break
			end

			count = count + 1

			for _, propertyName in ipairs(PART_SCAN_PROPS) do
				readProperty(child, propertyName, into)
			end

			readProperty(child, "AssemblyLinearVelocity", into)
			readProperty(child, "AssemblyAngularVelocity", into)
		end
	end

	return count
end

local function collectClientRenderedAssets(player, into)

	local ok, children = safeCall(function()
		return Workspace:GetChildren()
	end)

	if not ok or type(children) ~= "table" then
		return
	end

	local userId = tostring(player.UserId)

	for _, child in ipairs(children) do

		local name = tostring(child.Name)

		local looksLocal =
			string.find(name, "ClientRendered", 1, true) ~= nil
			or string.find(name, "LocalAssets", 1, true) ~= nil

		if looksLocal then

			local okChildren, subChildren = safeCall(function()
				return child:GetChildren()
			end)

			if okChildren and type(subChildren) == "table" then

				for _, model in ipairs(subChildren) do

					local modelName = tostring(model.Name)

					if string.find(modelName, userId, 1, true) then

						into[#into + 1] = {
							key = shortPath(model) .. " (local asset model)",
							value = "matches UserId",
						}
					end
				end
			end
		end
	end
end

--==================================================
-- FOCUS INSTANCES
--==================================================

local function focusInstances()

	local list = {}

	local function add(label, instance)

		if instance then
			list[#list + 1] = {
				label = label,
				inst = instance,
			}
		end
	end

	add("LocalPlayer", LocalPlayer)

	local character = LocalPlayer.Character

	add("Character", character)

	if character then

		add("Humanoid", safeFindOfClass(character, "Humanoid"))

		add("HRP", safeFindChild(character, "HumanoidRootPart"))
	end

	add("Backpack", safeFindOfClass(LocalPlayer, "Backpack"))

	local leaderstats = safeFindChild(LocalPlayer, "leaderstats")

	if leaderstats then

		local ok, children = safeCall(function()
			return leaderstats:GetChildren()
		end)

		if ok and type(children) == "table" then

			for index = 1, math.min(#children, 6) do
				add(
					"leaderstats[" .. tostring(index) .. "]",
					children[index]
				)
			end
		end
	end

	return list
end

--==================================================
-- SNAPSHOT
--==================================================

local function snapshot(label)

	local pairsOut = {}
	local info = {}

	local function addPair(key, value)

		if #pairsOut >= CONFIG.SNAPSHOT_KEYS_CAP then
			truncatedCount = truncatedCount + 1
			return
		end

		pairsOut[#pairsOut + 1] = {
			key = key,
			value = value,
		}
	end

	local character = LocalPlayer.Character

	for _, entry in ipairs(focusInstances()) do

		readAttributes(entry.inst, pairsOut)
		readTags(entry.inst, pairsOut)

		local okClass, className = safeCall(function()
			return entry.inst.ClassName
		end)

		if okClass and className == "Humanoid" then

			for _, propertyName in ipairs(HUMAN_SCAN_PROPS) do
				readProperty(entry.inst, propertyName, pairsOut)
			end

			local okState, state = safeCall(function()
				return entry.inst:GetState()
			end)

			if okState then
				addPair(
					shortPath(entry.inst) .. ".State",
					tostring(state)
				)
			end

		elseif okClass and className == "BasePart" then

			for _, propertyName in ipairs(PART_SCAN_PROPS) do
				readProperty(entry.inst, propertyName, pairsOut)
			end

			readProperty(entry.inst, "AssemblyLinearVelocity", pairsOut)
			readProperty(entry.inst, "AssemblyAngularVelocity", pairsOut)
			readProperty(entry.inst, "Position", pairsOut)
		end
	end

	if character then

		collectCharacterParts(character, pairsOut)
		collectTools(LocalPlayer, pairsOut)
		collectClientRenderedAssets(LocalPlayer, pairsOut)

		local okDesc, descendants = safeCall(function()
			return character:GetDescendants()
		end)

		if okDesc and type(descendants) == "table" then

			local disabled = {}

			for _, descendant in ipairs(descendants) do

				local okMotor, isMotor = safeCall(function()
					return descendant:IsA("Motor6D")
				end)

				if okMotor and isMotor then

					local okEnabled, enabled = safeCall(function()
						return descendant.Enabled
					end)

					if okEnabled and not enabled then
						disabled[#disabled + 1] = tostring(descendant.Name)
					end
				end
			end

			table.sort(disabled)

			info.disabledMotorCount = #disabled
			info.disabledMotors = table.concat(disabled, ",")

			addPair("Humanoid disabled Motor6D count", tostring(#disabled))
			addPair("Humanoid disabled Motor6D names", truncate(info.disabledMotors, CONFIG.STR_CAP))
		end
	end

	local okJoints = pcall(function()

		local flat = {}

		for _, pair in ipairs(pairsOut) do
			flat[pair.key] = pair.value
		end

		info.flat = flat
	end)

	if not okJoints then
		errorCount = errorCount + 1
	end

	info.label = label
	info.t = elapsedMs()
	info.server = serverNow()
	info.count = #pairsOut

	return info
end

--==================================================
-- DIFF
--==================================================

local function diffSnapshots(before, after)

	local lines = {}

	if not before or not after then
		return lines, 0
	end

	local beforeFlat = before.flat or {}
	local afterFlat = after.flat or {}
	local seen = {}
	local changed = 0

	local function record(key, text)

		if changed >= 40 then
			lines[#lines + 1] = "... diff capped at 40 lines"
			return
		end

		changed = changed + 1
		lines[#lines + 1] = text
	end

	local keys = {}

	for key in pairs(beforeFlat) do

		keys[#keys + 1] = key
		seen[key] = true
	end

	for key in pairs(afterFlat) do

		if not seen[key] then
			keys[#keys + 1] = key
		end
	end

	table.sort(keys)

	for _, key in ipairs(keys) do

		local oldValue = beforeFlat[key]
		local newValue = afterFlat[key]

		if oldValue ~= newValue then

			if oldValue == nil then

				record(
					key,
					"+ " .. key .. " = " .. tostring(newValue)
				)

			elseif newValue == nil then

				record(
					key,
					"- " .. key .. " (was " .. tostring(oldValue) .. ")"
				)

			else

				record(
					key,
					"~ " .. key .. ": " .. tostring(oldValue)
						.. " -> " .. tostring(newValue)
				)
			end
		end
	end

	return lines, changed
end

--==================================================
-- POLLING
--==================================================

local function scanJoints(character, logFlips)

	local current = {}

	local okDesc, descendants = safeCall(function()
		return character:GetDescendants()
	end)

	if not okDesc or type(descendants) ~= "table" then
		return current
	end

	for _, descendant in ipairs(descendants) do

		local okMotor, isMotor = safeCall(function()
			return descendant:IsA("Motor6D")
		end)

		if okMotor and isMotor then

			local okEnabled, enabled = safeCall(function()
				return descendant.Enabled
			end)

			if okEnabled then

				local name = tostring(descendant.Name)
				current[name] = enabled and "on" or "off"
			end
		end
	end

	if logFlips then

		for name, value in pairs(current) do

			local previous = jointsPrev[name]

			if previous and previous ~= value then

				counters.jointFlips = counters.jointFlips + 1

				addEntry(
					"JOINT",
					name .. ": " .. previous .. " -> " .. value
				)
			end
		end
	end

	return current
end

local function poll()

	local character = LocalPlayer.Character

	local pairsOut = {}

	for _, entry in ipairs(focusInstances()) do

		readAttributes(entry.inst, pairsOut)

		local okClass, className = safeCall(function()
			return entry.inst.ClassName
		end)

		if okClass and className == "Humanoid" then

			for _, propertyName in ipairs(HUMAN_SCAN_PROPS) do
				readProperty(entry.inst, propertyName, pairsOut)
			end
		end
	end

	if character then

		characterParts = {}

		local ok, children = safeCall(function()
			return character:GetChildren()
		end)

		if ok and type(children) == "table" then

			for _, child in ipairs(children) do

				local okPart, isPart = safeCall(function()
					return child:IsA("BasePart")
				end)

				if okPart and isPart then

					if #characterParts >= CONFIG.FOCUS_PARTS_CAP then
						break
					end

					characterParts[#characterParts + 1] = child
				end
			end
		end

		for _, part in ipairs(characterParts) do

			for _, propertyName in ipairs(PART_SCAN_PROPS) do
				readProperty(part, propertyName, pairsOut)
			end

			readProperty(part, "AssemblyLinearVelocity", pairsOut)
			readProperty(part, "AssemblyAngularVelocity", pairsOut)
		end

		local currentTools = {}

		collectTools(LocalPlayer, pairsOut)

		local backpack = safeFindOfClass(LocalPlayer, "Backpack")

		if backpack then

			local okChildren, children = safeCall(function()
				return backpack:GetChildren()
			end)

			if okChildren and type(children) == "table" then

				for _, child in ipairs(children) do

					local okTool, isTool = safeCall(function()
						return child:IsA("Tool")
					end)

					if okTool and isTool then
						currentTools["backpack:" .. child.Name] = true
					end
				end
			end
		end

		local okCharChildren, charChildren = safeCall(function()
			return character:GetChildren()
		end)

		if okCharChildren and type(charChildren) == "table" then

			for _, child in ipairs(charChildren) do

				local okTool, isTool = safeCall(function()
					return child:IsA("Tool")
				end)

				if okTool and isTool then
					currentTools["character:" .. child.Name] = true
				end
			end
		end

		for key in pairs(currentTools) do

			if not pollPrev["tool:" .. key] then

				counters.toolChanges = counters.toolChanges + 1

				local isEgg = isEggName(key)

				addEntry(
					"TOOL",
					"+ " .. key .. (isEgg and "  [EGG-CANDIDATE]" or "")
				)

				if isEgg then
					scheduleAutoDiff(
						"egg tool appear: " .. key,
						snapshotFromPollPrev()
					)
				end

				pollPrev["tool:" .. key] = true
			end
		end

		for key in pairs(pollPrev) do

			if string.sub(key, 1, 5) == "tool:" then

				local toolKey = string.sub(key, 6)

				if not currentTools[toolKey] then

					counters.toolChanges = counters.toolChanges + 1

					addEntry("TOOL", "- " .. toolKey)

					if isEggName(toolKey) then
						scheduleAutoDiff(
							"egg tool gone: " .. toolKey,
							snapshotFromPollPrev()
						)
					end

					pollPrev[key] = nil
				end
			end
		end

		if nowSeconds() - lastJointScan >= CONFIG.JOINT_SCAN_INTERVAL then

			lastJointScan = nowSeconds()
			jointsPrev = scanJoints(character, true)
		end

		local disabledMotors = {}

		for name, value in pairs(jointsPrev) do

			if value == "off" then
				disabledMotors[#disabledMotors + 1] = name
			end
		end

		table.sort(disabledMotors)

		pairsOut[#pairsOut + 1] = {
			key = "Humanoid disabled Motor6D count",
			value = tostring(#disabledMotors),
		}

		pairsOut[#pairsOut + 1] = {
			key = "Humanoid disabled Motor6D names",
			value = table.concat(disabledMotors, ","),
		}

		local humanoid = safeFindOfClass(character, "Humanoid")

		if humanoid then

			local okState, state = safeCall(function()
				return humanoid:GetState()
			end)

			if okState then

				pairsOut[#pairsOut + 1] = {
					key = shortPath(humanoid) .. ".State",
					value = tostring(state),
				}
			end
		end
	end

	local changes = {}

	for _, pair in ipairs(pairsOut) do

		local previous = pollPrev[pair.key]

		if previous ~= nil and previous ~= pair.value then

			changes[#changes + 1] = {
				key = pair.key,
				old = previous,
				new = pair.value,
			}
		end

		pollPrev[pair.key] = pair.value
	end

	for _, change in ipairs(changes) do

		counters.propChanges = counters.propChanges + 1

		addEntry(
			"PROP",
			change.key .. ": " .. change.old .. " -> " .. change.new
		)
	end

	return pairsOut
end

--==================================================
-- HUMANOID STATE WATCH
--==================================================

local humanoidConnections = {}

local function watchHumanoid(character)

	for _, conn in ipairs(humanoidConnections) do

		safeCall(function()
			conn:Disconnect()
		end)
	end

	humanoidConnections = {}
	attributeConnections = {}
	descendantConnections = {}
	watchedAttributes = {}

	if not character then
		return
	end

	local humanoid = safeFindOfClass(character, "Humanoid")

	if not humanoid then
		return
	end

	local okState, initialState = safeCall(function()
		return humanoid:GetState()
	end)

	if okState then
		addEntry("STATE", "state: " .. tostring(initialState))
	end

	humanoidConnections[#humanoidConnections + 1] = connect(
		humanoid.StateChanged,
		function(_, newState)

			counters.stateChanges = counters.stateChanges + 1

			addEntry("STATE", "state -> " .. tostring(newState))
		end
	)

end

--==================================================
-- ATTRIBUTE WATCH
--==================================================

local function watchInstanceAttributes(instance)

	if not instance or watchedAttributes[instance] then
		return
	end

	local count = 0

	for _ in pairs(watchedAttributes) do

		count = count + 1

		if count >= 128 then
			return
		end
	end

	watchedAttributes[instance] = true

	local signal = instance.AttributeChanged

	if signal then

		local conn = connect(
			signal,
			function(name)

				counters.attrChanges = counters.attrChanges + 1

				local okValue, value = safeCall(function()
					return instance:GetAttribute(name)
				end)

				addEntry(
					"ATTR",
					shortPath(instance) .. " @" .. tostring(name)
						.. " = "
						.. (okValue and vkey(value) or "<unreadable>")
				)
			end
		)

		if conn then
			attributeConnections[#attributeConnections + 1] = conn
		end
	end
end

-- New instances that appear inside a watched container (for example a tool
-- entering the character or backpack) get their own attribute hook.
local function connectDescendantWatch(container)

	if not container then
		return
	end

	local signal = container.DescendantAdded

	if not signal then
		return
	end

	local conn = connect(signal, function(child)
		watchInstanceAttributes(child)
	end)

	if conn then
		descendantConnections[#descendantConnections + 1] = conn
	end
end

-- Rebuilds the watch set. Old attribute hooks are disconnected first, so
-- repeated rebuilds cannot leak connections.
local function rebuildFocusWatches()

	for _, conn in ipairs(attributeConnections) do

		safeCall(function()
			conn:Disconnect()
		end)
	end

	for _, conn in ipairs(descendantConnections) do

		safeCall(function()
			conn:Disconnect()
		end)
	end

	attributeConnections = {}
	descendantConnections = {}
	watchedAttributes = {}

	for _, entry in ipairs(focusInstances()) do

		watchInstanceAttributes(entry.inst)
		connectDescendantWatch(entry.inst)

		local okDesc, descendants = safeCall(function()
			return entry.inst:GetDescendants()
		end)

		if okDesc and type(descendants) == "table" then

			local used = 0

			for _, descendant in ipairs(descendants) do

				if used >= 64 then
					break
				end

				used = used + 1

				watchInstanceAttributes(descendant)
			end
		end
	end
end

--==================================================
-- REMOTES (DISCOVERY ONLY UNLESS OPT-IN)
--==================================================

local function isRemote(instance)

	local okEvent, isEvent = safeCall(function()
		return instance:IsA("RemoteEvent")
	end)

	if okEvent and isEvent then
		return "RemoteEvent"
	end

	local okFunction, isFunction = safeCall(function()
		return instance:IsA("RemoteFunction")
	end)

	if okFunction and isFunction then
		return "RemoteFunction"
	end

	local okUnreliable, isUnreliable = safeCall(function()
		return instance:IsA("UnreliableRemoteEvent")
	end)

	if okUnreliable and isUnreliable then
		return "UnreliableRemoteEvent"
	end

	return nil
end

local function remoteFolderName(instance)

	local okParent, parent = safeCall(function()
		return instance.Parent
	end)

	if okParent and parent then

		local okName, name = safeCall(function()
			return parent.Name
		end)

		if okName and name and name ~= "game" then
			return tostring(name)
		end
	end

	return "?"
end

local function remoteMatchesWatch(instance)

	local text = string.lower(shortPath(instance))

	for _, keyword in ipairs(WATCH_KEYWORDS) do

		if string.find(text, keyword, 1, true) then
			return true
		end
	end

	return false
end

local function discoverRemotes(full)

	remotes = {}

	local queue = {}
	local visited = 0
	local depthLimit = full and math.huge or CONFIG.REMOTE_DEPTH

	local rootChildren = game:GetChildren()

	table.sort(
		rootChildren,
		function(a, b)
			return tostring(a.Name) < tostring(b.Name)
		end
	)

	for _, child in ipairs(rootChildren) do
		queue[#queue + 1] = {
			inst = child,
			depth = 1,
		}
	end

	local cursor = 1

	while cursor <= #queue do

		local item = queue[cursor]
		cursor = cursor + 1

		if visited >= CONFIG.REMOTE_NODES then
			truncatedCount = truncatedCount + 1
			break
		end

		visited = visited + 1

		local instance = item.inst
		local name = tostring(instance.Name)

		if visited % 500 == 0 then
			task.wait()
		end

		local skip =
			name == "CoreGui"
			or name == "CorePackages"
			or name == "PickupTimelineScanner"

		if not skip then

			local kind = isRemote(instance)

			if kind then

				if #remotes < CONFIG.REMOTE_CAP then

					remotes[#remotes + 1] = {
						inst = instance,
						kind = kind,
						path = shortPath(instance),
						folder = remoteFolderName(instance),
						watch = remoteMatchesWatch(instance),
					}

				else
					truncatedCount = truncatedCount + 1
				end
			end

			if item.depth < depthLimit then

				local okChildren, children = safeCall(function()
					return instance:GetChildren()
				end)

				if okChildren and type(children) == "table" then

					for _, child in ipairs(children) do
						queue[#queue + 1] = {
							inst = child,
							depth = item.depth + 1,
						}
					end
				end
			end
		end

	end

	local events = 0
	local functions = 0
	local watched = 0

	for _, remote in ipairs(remotes) do

		if remote.kind == "RemoteFunction" then
			functions = functions + 1
		else
			events = events + 1
		end

		if remote.watch then
			watched = watched + 1
		end
	end

	addEntry(
		"NOTE",
		"remote discovery: " .. tostring(#remotes)
			.. " found (" .. tostring(events) .. " events, "
			.. tostring(functions) .. " functions), "
			.. tostring(watched) .. " match watch keywords"
	)
end

local function formatArg(value, depth, seen)

	depth = depth or 0

	if depth > CONFIG.ARG_DEPTH then
		return "..."
	end

	local kind = typeof(value)

	if kind == "Instance" then

		local okClass, className = safeCall(function()
			return value.ClassName
		end)

		return (okClass and tostring(className) or "Instance")
			.. "/" .. truncate(value.Name, 40)

	elseif kind == "table" then

		seen = seen or {}

		if seen[value] then
			return "<cycle>"
		end

		seen[value] = true

		local parts = {}
		local count = 0

		for key, item in pairs(value) do

			if count >= CONFIG.ARG_ITEMS then
				parts[#parts + 1] = "..."
				break
			end

			count = count + 1

			parts[#parts + 1] =
				truncate(tostring(key), 24) .. "="
					.. formatArg(item, depth + 1, seen)
		end

		seen[value] = nil

		return "{" .. table.concat(parts, ",") .. "}"

	elseif kind == "string" then

		return "\"" .. truncate(value, CONFIG.STR_CAP) .. "\""
	end

	return vkey(value)
end

local function formatArgs(...)

	local count = select("#", ...)
	local parts = {}
	local limit = math.min(count, CONFIG.ARG_ITEMS)

	for index = 1, limit do

		parts[#parts + 1] = formatArg(
			(select(index, ...)),
			0,
			nil
		)
	end

	if count > CONFIG.ARG_ITEMS then
		parts[#parts + 1] = "+" .. tostring(count - CONFIG.ARG_ITEMS) .. " more"
	end

	return "(" .. table.concat(parts, ", ") .. ")"
end

-- "before" state for an auto-diff: the values seen by the previous poll.
-- This matters for events that are detected by the poll itself (an egg tool
-- appearing), where a fresh snapshot would already contain the change.
function snapshotFromPollPrev()

	local flat = {}

	for key, value in pairs(pollPrev) do

		if string.sub(key, 1, 5) == "tool:" then

			flat[key] = tostring(value)

		else
			flat[key] = value
		end
	end

	return {
		flat = flat,
		t = elapsedMs(),
		server = serverNow(),
		count = 0,
		label = "poll-before",
	}
end

function scheduleAutoDiff(reason, before)

	if #autoDiffs + #pendingDiffs >= CONFIG.AUTO_DIFF_CAP then
		return
	end

	local now = nowSeconds()
	local startAt = now

	-- Clustered events (a carry event plus the tool appearing) each deserve
	-- their own diff, so delay the next one instead of dropping it.
	if now - lastAutoDiff < CONFIG.AUTO_DIFF_MIN_GAP then
		startAt = lastAutoDiff + CONFIG.AUTO_DIFF_MIN_GAP
	end

	lastAutoDiff = startAt

	pendingDiffs[#pendingDiffs + 1] = {
		fireAt = startAt + CONFIG.AUTO_DIFF_DELAY,
		reason = reason,
		before = before or snapshot("auto-before " .. reason),
	}
end

function pumpAutoDiffs()

	if #pendingDiffs == 0 then
		return
	end

	local now = nowSeconds()
	local kept = {}

	for _, pending in ipairs(pendingDiffs) do

		if now >= pending.fireAt then

			local after = snapshot("auto-after " .. pending.reason)
			local lines, changed = diffSnapshots(pending.before, after)
			local elapsed = (after.t - pending.before.t) / 1000

			autoDiffs[#autoDiffs + 1] = {
				reason = pending.reason,
				afterSeconds = elapsed,
				changed = changed,
				lines = lines,
			}

			counters.autoDiffs = (counters.autoDiffs or 0) + 1

			if changed == 0 then

				addEntry(
					"DIFF",
					"after " .. pending.reason .. " (+"
						.. string.format("%.2f", elapsed)
						.. "s): no watched value changed"
				)

			else

				for _, line in ipairs(lines) do
					addEntry("DIFF", line .. "   [after " .. pending.reason .. "]")
				end
			end

		else
			kept[#kept + 1] = pending
		end
	end

	pendingDiffs = kept
end

local function attachRemoteObservers()

	for _, conn in ipairs(remoteConnections) do

		safeCall(function()
			conn:Disconnect()
		end)
	end

	remoteConnections = {}

	if not observeRemotes then
		return
	end

	local used = 0

	for _, remote in ipairs(remotes) do

		if used >= CONFIG.REMOTE_WATCH_CAP then
			truncatedCount = truncatedCount + 1
			break
		end

		-- Only RemoteEvents. Connecting a RemoteFunction's OnClientInvoke
		-- would hijack it, so functions are never touched.
		if remote.kind == "RemoteEvent" and remote.watch then

			used = used + 1

			local conn = connect(
				remote.inst.OnClientEvent,
				function(...)

					if not rateAllowed() then

						counters.eventDrops = counters.eventDrops + 1

						if counters.eventDrops % 25 == 1 then

							addEntry(
								"EVENT",
								"[dropped] rate limit reached ("
									.. tostring(counters.eventDrops)
									.. " dropped)"
							)
						end

						return
					end

					counters.events = counters.events + 1

					local text = string.format("%s %s", remote.path, formatArgs(...))

					addEntry("EVENT", text)

					local lower = string.lower(remote.path)

					for _, keyword in ipairs(AUTO_DIFF_KEYWORDS) do

						if string.find(lower, keyword, 1, true) then
							scheduleAutoDiff(remote.path)
							break
						end
					end
				end
			)

			if conn then
				remoteConnections[#remoteConnections + 1] = conn
			end
		end
	end

	addEntry(
		"NOTE",
		observeRemotes
			and ("remote observation ON (" .. tostring(used) .. " events watched)")
			or "remote observation OFF",
		{ force = true }
	)
end

local function setObserve(enabled)

	observeRemotes = enabled and true or false

	attachRemoteObservers()

	if reflectObserveButton then
		reflectObserveButton()
	end
end

--==================================================
-- MARKS / COMPARE
--==================================================

local function setMark(slot)

	counters.marks = counters.marks + 1

	local captured = snapshot("mark " .. slot)

	if slot == "A" then
		markA = captured
	else
		markB = captured
	end

	addEntry(
		"MARK",
		"mark " .. slot .. " captured (" .. tostring(captured.count)
			.. " values)"
	)
end

local function compare()

	if not markA or not markB then
		return false
	end

	counters.compares = counters.compares + 1

	local lines, changed = diffSnapshots(markA, markB)

	lastCompare = {
		changed = changed,
		lines = lines,
		seconds = (markB.t - markA.t) / 1000,
	}

	return true
end

--==================================================
-- REPORT / JSON
--==================================================

local function journalFrom(index, count)

	local out = {}
	local first = math.max(1, index)
	local last = math.min(#journal, first + count - 1)

	for position = first, last do

		local entry = journal[position]

		out[#out + 1] = entry
	end

	return out
end

local function renderJournal(entries)

	local lines = {}

	for _, entry in ipairs(entries) do

		local ms = entry.t
		local minutes = math.floor(ms / 60000)
		local seconds = (ms % 60000) / 1000

		lines[#lines + 1] = string.format(
			"[%02d:%06.3f] %-6s %s",
			minutes,
			seconds,
			entry.cat,
			entry.text
		)
	end

	return lines
end

local function reportText(full)

	local lines = {}

	lines[#lines + 1] = "PICKUP TIMELINE SCANNER v1.0  (read-only)"
	lines[#lines + 1] = "player: " .. tostring(LocalPlayer.Name)
	lines[#lines + 1] = "jobId: " .. tostring(game.JobId)
	lines[#lines + 1] = "elapsed: " .. string.format("%.1fs", elapsedMs() / 1000)
	lines[#lines + 1] = "journal: " .. tostring(#journal)
		.. " entries, dropped(oldest): " .. tostring(journalDropped)
	lines[#lines + 1] = "counters: events=" .. tostring(counters.events)
		.. " eventDrops=" .. tostring(counters.eventDrops)
		.. " attr=" .. tostring(counters.attrChanges)
		.. " state=" .. tostring(counters.stateChanges)
		.. " joints=" .. tostring(counters.jointFlips)
		.. " props=" .. tostring(counters.propChanges)
		.. " tools=" .. tostring(counters.toolChanges)
		.. " errors=" .. tostring(errorCount)
		.. " truncated=" .. tostring(truncatedCount)
	lines[#lines + 1] = "observe remotes: "
		.. (observeRemotes and "ON" or "OFF")
		.. "   paused: " .. (paused and "YES" or "no")
	lines[#lines + 1] = ""

	lines[#lines + 1] = "=== AUTO-DIFFS AFTER PICKUP-LIKE EVENTS ==="

	if #autoDiffs == 0 then

		lines[#lines + 1] =
			"(none yet - turn Observe remotes ON and pick up an egg)"
	else

		for _, diff in ipairs(autoDiffs) do

			lines[#lines + 1] = string.format(
				"-- %s  (+%.2fs, %d changes)",
				diff.reason,
				diff.afterSeconds,
				diff.changed
			)

			if #diff.lines == 0 then
				lines[#lines + 1] = "   (no watched value changed)"
			else

				for _, line in ipairs(diff.lines) do
					lines[#lines + 1] = "   " .. line
				end
			end
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "=== MANUAL COMPARE (A -> B) ==="

	if not lastCompare then

		lines[#lines + 1] = "(press Mark A, then Mark B, then Compare)"
	else

		lines[#lines + 1] = string.format(
			"%d changes over %.2fs",
			lastCompare.changed,
			lastCompare.seconds
		)

		if #lastCompare.lines == 0 then
			lines[#lines + 1] = "(no watched value changed)"
		else

			for _, line in ipairs(lastCompare.lines) do
				lines[#lines + 1] = "   " .. line
			end
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "=== TIMELINE ==="

	if full then

		for _, line in ipairs(renderJournal(journal)) do
			lines[#lines + 1] = line
		end

	else

		local pageCount = math.max(
			1,
			math.ceil(#journal / CONFIG.JOURNAL_PAGE)
		)

		if reportPage > pageCount then
			reportPage = pageCount
		end

		local first = 1 + (reportPage - 1) * CONFIG.JOURNAL_PAGE

		lines[#lines + 1] = "(page "
			.. tostring(reportPage) .. "/" .. tostring(pageCount)
			.. " - use Prev / Next)"

		for _, line in ipairs(
			renderJournal(
				journalFrom(first, CONFIG.JOURNAL_PAGE)
			)
		) do

			lines[#lines + 1] = line
		end
	end

	local text = table.concat(lines, "\n")

	if #text > CONFIG.MAX_TEXT_BYTES then

		text = string.sub(text, 1, CONFIG.MAX_TEXT_BYTES)
			.. "\n... (report truncated at "
			.. tostring(CONFIG.MAX_TEXT_BYTES) .. " bytes)"
	end

	return text
end

local function jsonEscape(text)

	text = tostring(text)

	text = string.gsub(text, "\\", "\\\\")
	text = string.gsub(text, "\"", "\\\"")
	text = string.gsub(text, "\n", "\\n")
	text = string.gsub(text, "\r", "\\r")
	text = string.gsub(text, "\t", "\\t")

	return "\"" .. text .. "\""
end

local jsonEncode

local function jsonValue(value, depth, seen)

	local kind = typeof(value)

	if depth > 6 then
		return "\"...\""
	end

	if kind == "number" then

		if value ~= value or value == math.huge or value == -math.huge then
			return "null"
		end

		return vkey(value)

	elseif kind == "boolean" then
		return value and "true" or "false"

	elseif kind == "string" then
		return jsonEscape(value)

	elseif kind == "table" then

		seen = seen or {}

		if seen[value] then
			return "null"
		end

		seen[value] = true

		local isArray = true
		local count = 0
		local maxIndex = 0

		for key in pairs(value) do

			count = count + 1

			if type(key) ~= "number" or key < 1
				or key ~= math.floor(key) then

				isArray = false

			elseif key > maxIndex then

				maxIndex = key
			end
		end

		if isArray and maxIndex ~= count then
			isArray = false
		end

		local out

		if isArray and count > 0 then

			local parts = {}

			for index = 1, count do
				parts[#parts + 1] = jsonValue(value[index], depth + 1, seen)
			end

			out = "[" .. table.concat(parts, ",") .. "]"

		elseif isArray then

			out = "[]"

		else

			local parts = {}
			local keys = {}

			for key in pairs(value) do
				keys[#keys + 1] = key
			end

			table.sort(
				keys,
				function(a, b)
					return tostring(a) < tostring(b)
				end
			)

			for _, key in ipairs(keys) do
				parts[#parts + 1] = jsonEscape(key)
					.. ":" .. jsonValue(value[key], depth + 1, seen)
			end

			out = "{" .. table.concat(parts, ",") .. "}"
		end

		seen[value] = nil

		return out
	end

	return jsonEscape(vkey(value))
end

function jsonEncode(value)

	return jsonValue(value, 0, nil)
end

local function exportJson()

	local payload = {
		tool = "pickup-timeline-scanner",
		version = "1.0",
		readOnly = true,
		place = tostring(game.PlaceId),
		jobId = tostring(game.JobId),
		player = tostring(LocalPlayer.Name),
		userId = tostring(LocalPlayer.UserId),
		serverTimeNow = serverNow(),
		observeRemotes = observeRemotes,
		paused = paused,
		counters = {
			events = counters.events,
			eventDrops = counters.eventDrops,
			attrChanges = counters.attrChanges,
			stateChanges = counters.stateChanges,
			jointFlips = counters.jointFlips,
			propChanges = counters.propChanges,
			toolChanges = counters.toolChanges,
			marks = counters.marks,
			compares = counters.compares,
			autoDiffs = counters.autoDiffs or 0,
			journalDropped = journalDropped,
			errors = errorCount,
			truncated = truncatedCount,
		},
		limits = CONFIG,
		marks = {
			A = markA and {
				label = markA.label,
				t = markA.t,
				server = markA.server,
				count = markA.count,
				values = markA.flat,
			} or nil,
			B = markB and {
				label = markB.label,
				t = markB.t,
				server = markB.server,
				count = markB.count,
				values = markB.flat,
			} or nil,
		},
		compare = lastCompare,
		autoDiffs = autoDiffs,
		journal = journal,
	}

	local json = jsonEncode(payload)

	if #json > CONFIG.MAX_JSON_BYTES then

		payload.journal = journalFrom(
			math.max(1, #journal - 800),
			800
		)
		payload.truncated = true

		json = jsonEncode(payload)
	end

	return json
end

--==================================================
-- GUI
--==================================================

local screenGui
local mainFrame
local titleBar
local statusLabel
local textArea
local textLabel
local observeButton
local pauseButton
local body
local pageLabel

local function makeButton(parent, text, x, y, width, height)

	local button = Instance.new("TextButton")

	button.Name = "Btn_" .. string.gsub(text, "%W", "")
	button.Text = text
	button.Size = UDim2.new(0, width, 0, height)
	button.Position = UDim2.new(0, x, 0, y)
	button.BackgroundColor3 = Color3.fromRGB(38, 42, 54)
	button.TextColor3 = Color3.fromRGB(230, 234, 240)
	button.TextSize = 13
	button.Font = Enum.Font.SourceSans
	button.Parent = parent

	return button
end

local function setStatus(text)

	if statusLabel then
		statusLabel.Text = text
	end
end

local function refreshStatus()

	setStatus(
		"journal " .. tostring(#journal)
			.. " | events " .. tostring(counters.events)
			.. " | drops " .. tostring(counters.eventDrops)
			.. " | " .. (paused and "PAUSED" or "watching")
	)
end

local function render()

	if not textLabel then
		return
	end

	local text = reportText(false)
	local lineCount = 1

	for _ in string.gmatch(text, "\n") do
		lineCount = lineCount + 1
	end

	textLabel.Text = text
	textLabel.Size = UDim2.new(0, 600, 0, math.max(1, lineCount) * 15 + 8)

	if textArea then
		textArea.CanvasSize =
			UDim2.new(0, 600, 0, math.max(1, lineCount) * 15 + 8)
	end

	if pageLabel then

		local pages = math.max(
			1,
			math.ceil(#journal / CONFIG.JOURNAL_PAGE)
		)

		pageLabel.Text = "page " .. tostring(reportPage)
			.. "/" .. tostring(pages)
	end

	refreshStatus()
end

function reflectObserveButton()

	if observeButton then

		observeButton.Text = "Observe remotes: "
			.. (observeRemotes and "ON" or "OFF")
		observeButton.BackgroundColor3 = observeRemotes
			and Color3.fromRGB(48, 92, 60)
			or Color3.fromRGB(38, 42, 54)
	end
end

local function buildGui()

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PickupTimelineScanner"
	screenGui.ResetOnSpawn = false

	local playerGui = safeFindOfClass(LocalPlayer, "PlayerGui")

	if playerGui then
		screenGui.Parent = playerGui
	else

		local coreGui = game:GetService("CoreGui")

		screenGui.Parent = coreGui
	end

	mainFrame = Instance.new("Frame")
	mainFrame.Name = "Main"
	mainFrame.Size = UDim2.new(0, 620, 0, 430)
	mainFrame.Position = UDim2.new(0, 40, 0, 90)
	mainFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	mainFrame.BorderSizePixel = 0
	mainFrame.Parent = screenGui

	titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 26)
	titleBar.BackgroundColor3 = Color3.fromRGB(30, 34, 44)
	titleBar.BorderSizePixel = 0
	titleBar.Parent = mainFrame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Text = "Pickup Timeline Scanner (read-only)"
	title.Size = UDim2.new(0, 340, 1, 0)
	title.Position = UDim2.new(0, 8, 0, 0)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(235, 238, 245)
	title.TextSize = 14
	title.Font = Enum.Font.SourceSansBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = titleBar

	statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.Text = "starting..."
	statusLabel.Size = UDim2.new(0, 190, 1, 0)
	statusLabel.Position = UDim2.new(1, -222, 0, 0)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.fromRGB(160, 200, 170)
	statusLabel.TextSize = 12
	statusLabel.Font = Enum.Font.SourceSans
	statusLabel.TextXAlignment = Enum.TextXAlignment.Right
	statusLabel.Parent = titleBar

	body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 1, -26)
	body.Position = UDim2.new(0, 0, 0, 26)
	body.BackgroundTransparency = 1
	body.Parent = mainFrame

	local markAButton = makeButton(body, "Mark A", 6, 6, 78, 22)
	local markBButton = makeButton(body, "Mark B", 88, 6, 78, 22)
	local compareButton = makeButton(body, "Compare A->B", 170, 6, 104, 22)
	local copyButton = makeButton(body, "Copy Report", 278, 6, 92, 22)
	local saveButton = makeButton(body, "Save JSON", 374, 6, 84, 22)
	local clearButton = makeButton(body, "Clear", 462, 6, 60, 22)

	local prevButton = makeButton(body, "Prev", 6, 32, 52, 22)
	local nextButton = makeButton(body, "Next", 62, 32, 52, 22)

	pageLabel = Instance.new("TextLabel")
	pageLabel.Name = "Page"
	pageLabel.Text = "page 1/1"
	pageLabel.Size = UDim2.new(0, 110, 0, 22)
	pageLabel.Position = UDim2.new(0, 118, 0, 32)
	pageLabel.BackgroundTransparency = 1
	pageLabel.TextColor3 = Color3.fromRGB(180, 186, 196)
	pageLabel.TextSize = 12
	pageLabel.Font = Enum.Font.SourceSans
	pageLabel.TextXAlignment = Enum.TextXAlignment.Left
	pageLabel.Parent = body

	observeButton = makeButton(body, "Observe remotes: OFF", 240, 32, 146, 22)
	pauseButton = makeButton(body, "Pause", 390, 32, 60, 22)

	local closeButton = makeButton(body, "Close", 532, 32, 78, 22)
	closeButton.BackgroundColor3 = Color3.fromRGB(96, 40, 44)
	connect(closeButton.MouseButton1Click, function()

		if stopScanner then
			stopScanner("closed by user")
		end
	end)

	textArea = Instance.new("ScrollingFrame")
	textArea.Name = "Report"
	textArea.Size = UDim2.new(0, 608, 0, 342)
	textArea.Position = UDim2.new(0, 6, 0, 60)
	textArea.BackgroundColor3 = Color3.fromRGB(14, 16, 20)
	textArea.BorderSizePixel = 0
	textArea.ScrollBarThickness = 6
	textArea.CanvasSize = UDim2.new(0, 600, 0, 400)
	textArea.Parent = body

	textLabel = Instance.new("TextLabel")
	textLabel.Name = "Lines"
	textLabel.Text = ""
	textLabel.Size = UDim2.new(0, 600, 0, 400)
	textLabel.Position = UDim2.new(0, 0, 0, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.TextColor3 = Color3.fromRGB(214, 220, 230)
	textLabel.TextSize = 12
	textLabel.Font = Enum.Font.Code
	textLabel.TextXAlignment = Enum.TextXAlignment.Left
	textLabel.TextYAlignment = Enum.TextYAlignment.Top
	textLabel.TextWrapped = true
	textLabel.Parent = textArea

	-- Drag by title bar.
	local dragging = false
	local dragStart, startPos

	connect(titleBar.InputBegan, function(input)

		if input and input.UserInputType == Enum.UserInputType.MouseButton1 then

			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
		end
	end)

	connect(UserInputService.InputChanged, function(input)

		if dragging and input then

			local delta = input.Position - dragStart

			mainFrame.Position = UDim2.new(
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

	connect(markAButton.MouseButton1Click, function()
		setMark("A")
		render()
	end)

	connect(markBButton.MouseButton1Click, function()
		setMark("B")
		render()
	end)

	connect(compareButton.MouseButton1Click, function()

		if compare() then
			render()
		else
			note("compare needs Mark A and Mark B first")
			render()
		end
	end)

	connect(copyButton.MouseButton1Click, function()

		local text = reportText(true)

		if type(setclipboard) == "function" then

			local ok = pcall(setclipboard, text)

			note(ok and "report copied to clipboard"
				or "clipboard failed")
		else
			note("clipboard not available in this executor")
		end

		render()
	end)

	connect(saveButton.MouseButton1Click, function()

		local json = exportJson()
		local saved = false

		if type(writefile) == "function" then

			local name = "pickup_timeline_"
				.. tostring(math.floor(nowSeconds()))
				.. ".json"

			saved = pcall(writefile, name, json)

			if saved then
				note("saved " .. name .. " (" .. tostring(#json) .. " bytes)")
			else
				note("writefile failed; use Copy Report instead")
			end

		elseif type(setclipboard) == "function" then

			saved = pcall(setclipboard, json)

			note(saved and "JSON copied to clipboard (no writefile)"
				or "JSON export failed")
		else
			note("no writefile/setclipboard available; use Copy Report")
		end

		render()
	end)

	connect(clearButton.MouseButton1Click, function()

		journal = {}
		journalDropped = 0
		reportPage = 1

		note("journal cleared")
		render()
	end)

	connect(prevButton.MouseButton1Click, function()

		reportPage = math.max(1, reportPage - 1)
		render()
	end)

	connect(nextButton.MouseButton1Click, function()

		reportPage = reportPage + 1
		render()
	end)

	connect(observeButton.MouseButton1Click, function()

		setObserve(not observeRemotes)
		render()
	end)

	connect(pauseButton.MouseButton1Click, function()

		paused = not paused

		pauseButton.Text = paused and "Resume" or "Pause"

		if not paused then
			addEntry("NOTE", "resumed", { force = true })
		end

		render()
	end)

	local minimizeButton = makeButton(titleBar, "-", 0, 0, 22, 20)
	minimizeButton.Name = "Minimize"
	minimizeButton.Position = UDim2.new(1, -26, 0, 3)

	local minimized = false

	connect(minimizeButton.MouseButton1Click, function()

		minimized = not minimized

		body.Visible = not minimized
		mainFrame.Size = minimized
			and UDim2.new(0, 620, 0, 26)
			or UDim2.new(0, 620, 0, 430)

		minimizeButton.Text = minimized and "+" or "-"
	end)

	reflectObserveButton()
end

--==================================================
-- MAIN LOOPS
--==================================================

local function pollLoop()

	while scriptAlive do

		local ok, err = safeCall(poll)

		if not ok then

			errorCount = errorCount + 1

			if errorCount <= 3 then

				addEntry(
					"NOTE",
					"poll error: " .. truncate(tostring(err), 120)
				)
			end
		end

		safeCall(pumpAutoDiffs)

		task.wait(CONFIG.POLL_INTERVAL)
	end
end

local function renderLoop()

	local lastRender = 0

	while scriptAlive do

		local now = nowSeconds()

		if now - lastRender >= 0.25 then

			lastRender = now

			safeCall(render)
		end

		task.wait(0.2)
	end
end

--==================================================
-- STOP
--==================================================

function stopScanner(reason)

	if not scriptAlive then
		return
	end

	scriptAlive = false

	addEntry("NOTE", "stopping: " .. tostring(reason or "?"), { force = true })

	disconnectAll()

	for _, conn in ipairs(humanoidConnections) do

		safeCall(function()
			conn:Disconnect()
		end)
	end

	humanoidConnections = {}
	attributeConnections = {}
	descendantConnections = {}
	watchedAttributes = {}

	for _, thread in ipairs(threads) do

		safeCall(function()
			task.cancel(thread)
		end)
	end

	threads = {}

	if screenGui then

		safeCall(function()
			screenGui:Destroy()
		end)
	end

	screenGui = nil

	if _G.PICKUP_TIMELINE_SCANNER and _G.PICKUP_TIMELINE_SCANNER.stop == stopScanner then
		_G.PICKUP_TIMELINE_SCANNER = nil
	end

	print("[Pickup Timeline Scanner] stopped (" .. tostring(reason or "?") .. ")")
end

--==================================================
-- CHARACTER LIFECYCLE
--==================================================

local function onCharacterAdded(character)

	addEntry("NOTE", "character added: " .. truncate(tostring(character), 60))

	rebuildFocusWatches()
	watchHumanoid(character)
	scanJoints(character, false)
end

connect(LocalPlayer.CharacterAdded, onCharacterAdded)

--==================================================
-- START
--==================================================

safeCall(buildGui)

safeCall(function()
	rebuildFocusWatches()
end)

safeCall(function()
	watchHumanoid(LocalPlayer.Character)
end)

safeCall(function()
	scanJoints(LocalPlayer.Character, false)
end)

spawn(function()
	discoverRemotes(false)
end)

spawn(pollLoop)
spawn(renderLoop)

addEntry(
	"NOTE",
	"scanner started (read-only). Mark A -> pick up egg -> Mark B -> Compare. "
		.. "Turn Observe remotes ON to capture client events."
)

addEntry(
	"NOTE",
	"remote observation OFF (opt-in; press the button to watch client events)"
)

render()

_G.PICKUP_TIMELINE_SCANNER = {
	version = "1.0",
	stop = stopScanner,
	mark = setMark,
	compare = compare,
	pollOnce = poll,
	capture = snapshot,
	report = reportText,
	exportJson = exportJson,
	journal = function()
		return journalFrom(1, #journal)
	end,
	counters = function()
		return counters
	end,
	state = function()
		return {
			alive = scriptAlive,
			paused = paused,
			observeRemotes = observeRemotes,
			journal = #journal,
			dropped = journalDropped,
			errors = errorCount,
		}
	end,
	setObserve = setObserve,
	discoverRemotes = discoverRemotes,
}
