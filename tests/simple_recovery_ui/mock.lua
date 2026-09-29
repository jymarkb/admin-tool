--[[ Offline Roblox mock for simple_recovery_ui.lua (test-only, never shipped).
Provides: virtual clock + coroutine scheduler, instance tree with signals,
Humanoid/Motor6D behaviour, a workspace that integrates AssemblyLinearVelocity
into Position and honours Humanoid:MoveTo, and instrumentation for writes,
remote calls and state changes. ]]

local M = { vclock = 0, serverOffset = 50000, threads = {}, coThread = {}, errors = {},
	prints = {}, connections = {}, writes = {}, violations = {}, remoteCalls = {},
	moveToCalls = {}, stateEnabled = {}, promptFires = {}, touchFires = {},
	writesArmed = false, simulating = false }

local realPrint = print
_G.print = function(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
	local text = table.concat(parts, " ")
	M.prints[#M.prints + 1] = text
	realPrint(text)
end
_G.warn = _G.print
os = { clock = function() return M.vclock end }

local function newVector3(x, y, z)
	local v = { X = x or 0, Y = y or 0, Z = z or 0, __typename = "Vector3" }
	v.Magnitude = math.sqrt(v.X^2 + v.Y^2 + v.Z^2)
	local mt
	mt = {
		__index = function(self, key)
			if key == "Unit" then
				local m = self.Magnitude
				if m > 0 then return newVector3(self.X/m, self.Y/m, self.Z/m) end
				return newVector3(0, 0, 0)
			end
			if key == "Lerp" then
				return function(a, other, alpha)
					local t = alpha or 0
					return newVector3(a.X + (other.X - a.X) * t,
						a.Y + (other.Y - a.Y) * t,
						a.Z + (other.Z - a.Z) * t)
				end
			end
			return nil
		end,
		__add = function(a,b) return newVector3(a.X+b.X, a.Y+b.Y, a.Z+b.Z) end,
		__sub = function(a,b) return newVector3(a.X-b.X, a.Y-b.Y, a.Z-b.Z) end,
		__div = function(a,b) return newVector3(a.X/b, a.Y/b, a.Z/b) end,
		__mul = function(a,b) return newVector3(a.X*b, a.Y*b, a.Z*b) end,
		__tostring = function(s) return string.format("%.1f, %.1f, %.1f", s.X, s.Y, s.Z) end,
	}
	return setmetatable(v, mt)
end
Vector3 = { new = newVector3, zero = newVector3(0,0,0) }
UDim = { new = function(s,o) return { Scale = s or 0, Offset = o or 0 } end }
UDim2 = { new = function(sx,ox,sy,oy) return { X = UDim.new(sx,ox), Y = UDim.new(sy,oy) } end,
	fromOffset = function(x,y) return UDim2.new(0,x,0,y) end }
Color3 = { new = function(r,g,b) return { R=r or 0, G=g or 0, B=b or 0 } end,
	fromRGB = function(r,g,b) return Color3.new((r or 0)/255,(g or 0)/255,(b or 0)/255) end }

local enumCache, enumSections = {}, {}
local function enumItem(enumName, itemName)
	enumCache[enumName] = enumCache[enumName] or {}
	if not enumCache[enumName][itemName] then
		local item = { EnumType = enumName, Name = itemName }
		setmetatable(item, { __tostring = function(s) return "Enum." .. s.EnumType .. "." .. s.Name end })
		enumCache[enumName][itemName] = item
	end
	return enumCache[enumName][itemName]
end
M.enumItem = enumItem
Enum = setmetatable({}, { __index = function(_, section)
	if not enumSections[section] then
		enumSections[section] = setmetatable({}, { __index = function(_, item) return enumItem(section, item) end })
	end
	return enumSections[section]
end })

local SIGNALS = { Heartbeat=true, Stepped=true, StateChanged=true, HealthChanged=true, Changed=true,
	AttributeChanged=true, CharacterAdded=true, MouseButton1Click=true, FocusLost=true,
	InputBegan=true, InputEnded=true, InputChanged=true, ChildAdded=true, ChildRemoved=true }
local spawnCallback
local function newSignal(name)
	local signal = { _name = name, _conns = {} }
	function signal:Connect(fn)
		local conn = { fn = fn, disconnected = false }
		function conn:Disconnect() self.disconnected = true end
		table.insert(self._conns, conn)
		M.connections[#M.connections + 1] = conn
		return conn
	end
	function signal:Fire(...)
		local args = { ... }
		for _, conn in ipairs(self._conns) do
			if not conn.disconnected then spawnCallback(conn.fn, table.unpack(args)) end
		end
	end
	function signal:AliveCount()
		local n = 0
		for _, c in ipairs(self._conns) do if not c.disconnected then n = n + 1 end end
		return n
	end
	return signal
end

local ISA = { Instance={}, Folder={"Instance"}, Model={"Instance"}, BasePart={"Instance"},
	Part={"BasePart"}, Humanoid={"Instance"}, Tool={"Instance"}, Motor6D={"Instance"},
	RemoteFunction={"Instance"}, ScreenGui={"Instance"}, Frame={"Instance"}, TextLabel={"Instance"},
	TextButton={"Instance"}, TextBox={"Instance"}, PlayerGui={"Instance"}, Player={"Instance"},
	Players={"Instance"}, Workspace={"Instance"}, RunService={"Instance"},
	UserInputService={"Instance"}, ReplicatedStorage={"Instance"}, DataModel={"Instance"},
	ProximityPrompt={"Instance"} }
local ALLOWED = { WalkSpeed=true, Enabled=true, PlatformStand=true, Sit=true, AutoRotate=true,
	Health=true, Name=true, AssemblyLinearVelocity=true, AssemblyAngularVelocity=true,
	Massless=true, CanCollide=true }
local FORBIDDEN = { CFrame=true, Position=true, Anchored=true, Velocity=true, JumpPower=true, NetworkOwner=true }
local METHODS, InstanceMT = {}, {}
function InstanceMT.__index(self, key)
	local props = rawget(self, "_props")
	if props and props[key] ~= nil then return props[key] end
	if SIGNALS[key] then
		local signals = rawget(self, "_signals")
		signals[key] = signals[key] or newSignal(key)
		return signals[key]
	end
	local extra = rawget(self, "_extra")
	if extra and extra[key] ~= nil then return extra[key] end
	if METHODS[key] then return METHODS[key] end
	for _, child in ipairs(rawget(self, "_children")) do
		if tostring(rawget(child, "_props").Name) == tostring(key) then return child end
	end
	return nil
end
function InstanceMT.__newindex(self, key, value)
	if key == "Parent" then
		local old = rawget(self, "_parent")
		if old then
			local siblings = rawget(old, "_children")
			for i = #siblings, 1, -1 do if siblings[i] == self then table.remove(siblings, i) end end
		end
		rawset(self, "_parent", value)
		rawget(self, "_props").Parent = value
		if value then table.insert(rawget(value, "_children"), self) end
		return
	end
	local props = rawget(self, "_props")
	if not props then props = {}; rawset(self, "_props", props) end
	props[key] = value
	if rawget(self, "_isFixture") and not M.simulating then
		M.writes[#M.writes + 1] = { inst = self, key = key, value = value }
		if M.writesArmed then
			if FORBIDDEN[key] then
				M.violations[#M.violations + 1] = { inst = self, key = key, kind = "forbidden" }
			elseif not ALLOWED[key] then
				M.violations[#M.violations + 1] = { inst = self, key = key, kind = "unexpected" }
			end
		end
	end
end
function METHODS:GetChildren() local out = {}
	for _, c in ipairs(rawget(self, "_children")) do out[#out + 1] = c end return out end
function METHODS:GetDescendants() local out = {}
	local function walk(node) for _, c in ipairs(rawget(node, "_children")) do out[#out+1]=c; walk(c) end end
	walk(self) return out end
function METHODS:FindFirstChild(name)
	for _, c in ipairs(rawget(self, "_children")) do
		if tostring(rawget(c, "_props").Name) == name then return c end end return nil end
function METHODS:WaitForChild(name) return self:FindFirstChild(name) end
function METHODS:FindFirstChildOfClass(cls)
	for _, c in ipairs(rawget(self, "_children")) do if c.ClassName == cls then return c end end return nil end
local function classIsA(node, cls)
	if node.ClassName == cls then return true end
	for _, a in ipairs(ISA[node.ClassName] or {}) do if a == cls then return true end end
	return false
end
function METHODS:FindFirstChildWhichIsA(cls, recursive)
	for _, c in ipairs(rawget(self, "_children")) do if classIsA(c, cls) then return c end end
	if recursive then
		for _, c in ipairs(rawget(self, "_children")) do
			local found = c:FindFirstChildWhichIsA(cls, true)
			if found then return found end end end
	return nil
end
function METHODS:IsA(cls) return classIsA(self, cls) end
function METHODS:GetAttribute(name) return rawget(self, "_attributes")[name] end
function METHODS:SetAttribute(name, value) rawget(self, "_attributes")[name] = value end
function METHODS:GetState() return rawget(self, "_props")._State or enumItem("HumanoidStateType", "Running") end
function METHODS:ChangeState(newState)
	local props = rawget(self, "_props")
	if props._State == newState then return end
	local previous = props._State
	props._State = newState
	self.StateChanged:Fire(self, newState, previous)
end
function METHODS:SetStateEnabled(state, enabled)
	M.stateEnabled[#M.stateEnabled + 1] = { state = state, enabled = enabled } end
function METHODS:MoveTo(position)
	M.moveToCalls[#M.moveToCalls + 1] = { inst = self, position = position, t = M.vclock }
	rawget(self, "_extra").walkTarget = position
end
function METHODS:Destroy()
	local parent = rawget(self, "_parent")
	if parent then
		local siblings = rawget(parent, "_children")
		for i = #siblings, 1, -1 do if siblings[i] == self then table.remove(siblings, i) end end end
	rawset(self, "_parent", nil)
	rawget(self, "_props").Parent = nil
end
function METHODS:InvokeServer(...)
	M.remoteCalls[#M.remoteCalls + 1] = { inst = self, args = { ... } }
	local responder = rawget(self, "_extra").invokeResponder
	if responder then return responder(...) end
	return nil
end
function M.new(className, name, parent, props)
	local instance = setmetatable({ ClassName = className, _children = {}, _parent = nil,
		_props = { Name = name or className, ClassName = className },
		_attributes = {}, _signals = {}, _extra = {} }, InstanceMT)
	if props then for k, v in pairs(props) do if k ~= "Parent" then instance._props[k] = v end end end
	rawset(instance, "_isFixture", true)
	if parent then instance.Parent = parent end
	return instance
end
function M.setExtra(instance, key, value) instance._extra[key] = value end
Instance = { new = function(className)
	local instance = M.new(className, className, nil, nil)
	rawset(instance, "_isFixture", false)
	return instance
end }
_G.Instance = Instance

local function resumeThread(thread)
	if thread.cancelled or thread.dead then return end
	local ok, err = coroutine.resume(thread.co)
	if not ok then thread.dead = true; M.errors[#M.errors + 1] = tostring(err) end
	if coroutine.status(thread.co) == "dead" then thread.dead = true end
end
task = {}
local function makeThread(fn, args, wake)
	local thread = { co = coroutine.create(function() fn(table.unpack(args)) end),
		wake = wake, dead = false, cancelled = false }
	M.coThread[thread.co] = thread
	M.threads[#M.threads + 1] = thread
	return thread
end
function task.spawn(fn, ...) local t = makeThread(fn, { ... }, M.vclock); resumeThread(t); return t end
function task.defer(fn, ...) return makeThread(fn, { ... }, M.vclock + 0.0001) end
function task.wait(seconds)
	local co = coroutine.running()
	local thread = co and M.coThread[co]
	if thread then thread.wake = M.vclock + (seconds or 0) end
	coroutine.yield()
	return M.vclock
end
function task.cancel(thread) if type(thread) == "table" then thread.cancelled = true end end
function task.delay(seconds, fn, ...)
	local args = { ... }
	task.spawn(function() task.wait(seconds); fn(table.unpack(args)) end)
end
spawnCallback = function(fn, ...) return task.spawn(fn, ...) end

function M.build()
	local game = M.new("DataModel", "game", nil, { JobId = "mock", PlaceId = 1 })
	local services = {}
	local function service(cls, name) services[name] = M.new(cls, name, game, {}); return services[name] end
	local players = service("Players", "Players")
	local runService = service("RunService", "RunService")
	local workspace = service("Workspace", "Workspace")
	local replicated = service("ReplicatedStorage", "ReplicatedStorage")
	service("UserInputService", "UserInputService")
	M.setExtra(game, "GetService", function(_, name) return services[name] end)
	M.setExtra(workspace, "GetServerTimeNow", function() return M.vclock + M.serverOffset end)

	local packages = M.new("Folder", "Packages", replicated, {})
	local networking = M.new("Folder", "Networking", packages, {})
	local carryRemote = M.new("RemoteFunction", "RF/EggWorld/AskFieldEggCarry", networking, {})
	M.new("RemoteFunction", "RF/EggWorld/AskFieldEggDrop", networking, {})
	local snapshotRemote = M.new("RemoteFunction", "RF/EggWorld/AskFieldEggSnapshot", networking, {})
	M.setExtra(snapshotRemote, "invokeResponder", function() return { Records = {} } end)

	local slots = M.new("Folder", "AreaEggSlotsClient", workspace, {})
	local forestSlot = M.new("Model", "Forest Egg Slot", slots, {})
	local forestPart = M.new("Part", "Hitbox", forestSlot, { Position = newVector3(300, 70, 0) })
	local snowSlot = M.new("Model", "Snow Egg Slot", slots, {})
	local snowPart = M.new("Part", "Hitbox", snowSlot, { Position = newVector3(1500, 67, 0) })
	local promptPart = M.new("Part", "ForestPrompt", workspace, { Position = newVector3(300, 70, 0) })
	local prompt = M.new("ProximityPrompt", "CarryPrompt", promptPart, {})

	local player = M.new("Player", "TestPlayer", players, { UserId = 42 })
	local playerGui = M.new("PlayerGui", "PlayerGui", player, {})
	M.new("Backpack", "Backpack", player, {})
	local character = M.new("Model", "TestCharacter", workspace, {})
	local humanoid = M.new("Humanoid", "Humanoid", character, { WalkSpeed = 16, Health = 100,
		MaxHealth = 100, PlatformStand = false, Sit = false, AutoRotate = true,
		_State = enumItem("HumanoidStateType", "Running") })
	local root = M.new("Part", "HumanoidRootPart", character, { Position = newVector3(0, 70, 0),
		Anchored = false, Massless = false, CanCollide = true,
		AssemblyLinearVelocity = newVector3(0, 0, 0), AssemblyAngularVelocity = newVector3(0, 0, 0) })
	local held = M.new("Part", "CarriedPart", character, { Massless = false, CanCollide = true })
	local joints = {}
	for _, name in ipairs({ "Neck", "Waist", "LeftShoulder", "RightShoulder", "LeftHip", "RightHip" }) do
		joints[name] = M.new("Motor6D", name, character, { Enabled = true })
	end
	player.Character = character
	players.LocalPlayer = player
	M.services = services
	M.fixture = { game = game, services = services, workspace = workspace, player = player,
		playerGui = playerGui, character = character, humanoid = humanoid, root = root,
		held = held, joints = joints, forestPart = forestPart, snowPart = snowPart,
		carryRemote = carryRemote, snapshotRemote = snapshotRemote, heartbeat = runService.Heartbeat }
	return M.fixture
end
function M.install()
	local fixture = M.build()
	_G.game = fixture.game
	_G.workspace = fixture.workspace
	return fixture
end
_G.fireproximityprompt = function(prompt) M.promptFires[#M.promptFires + 1] = { prompt = prompt } end
_G.firetouchinterest = function(a, b, state) M.touchFires[#M.touchFires + 1] = { a = a, b = b, state = state } end

function M.pump(seconds, step)
	step = step or 0.02
	local target = M.vclock + seconds
	local guard = 0
	while M.vclock < target do
		guard = guard + 1
		if guard > 100000 then error("pump guard") end
		local dt = math.min(step, target - M.vclock)
		M.vclock = M.vclock + dt

		local hum, root = M.fixture.humanoid, M.fixture.root
		local velocity = root._props.AssemblyLinearVelocity
		M.simulating = true
		if velocity and (velocity.X ~= 0 or velocity.Y ~= 0 or velocity.Z ~= 0) then
			root._props.Position = newVector3(root._props.Position.X + velocity.X * dt,
				root._props.Position.Y + velocity.Y * dt,
				root._props.Position.Z + velocity.Z * dt)
		end
		local walkTarget = hum._extra.walkTarget
		if walkTarget and hum._props._State ~= enumItem("HumanoidStateType", "Physics") then
			local delta = walkTarget - root._props.Position
			local dist = math.sqrt(delta.X^2 + delta.Z^2)
			local stepDist = (hum._props.WalkSpeed or 16) * dt
			if dist > 0.01 then
				if dist <= stepDist then
					root._props.Position = newVector3(walkTarget.X, root._props.Position.Y, walkTarget.Z)
				else
					root._props.Position = newVector3(
						root._props.Position.X + delta.X / dist * stepDist,
						root._props.Position.Y,
						root._props.Position.Z + delta.Z / dist * stepDist)
				end
			end
		end
		M.simulating = false

		local moved = true
		while moved do
			moved = false
			for _, thread in ipairs(M.threads) do
				if not thread.dead and not thread.cancelled and thread.wake <= M.vclock then
					resumeThread(thread); moved = true end
			end
		end
		if #M.threads > 200 then
			local kept = {}
			for _, thread in ipairs(M.threads) do
				if not thread.dead and not thread.cancelled then kept[#kept + 1] = thread end
			end
			M.threads = kept
		end
		M.fixture.heartbeat:Fire(dt)
	end
end

function M.setPosition(x, y, z)
	M.simulating = true
	M.fixture.root._props.Position = newVector3(x, y, z)
	M.fixture.root._props.AssemblyLinearVelocity = newVector3(0, 0, 0)
	M.simulating = false
end
function M.simulateRagdoll(duration)
	local f = M.fixture
	M.simulating = true
	f.player:SetAttribute("RagdollEndTime", M.vclock + M.serverOffset + (duration or 5))
	for _, joint in pairs(f.joints) do joint._props.Enabled = false end
	f.humanoid._props.PlatformStand = true
	f.humanoid._props._State = enumItem("HumanoidStateType", "Physics")
	M.simulating = false
	f.humanoid.StateChanged:Fire(f.humanoid, f.humanoid._props._State)
end
function M.endRagdoll()
	local f = M.fixture
	M.simulating = true
	f.player:SetAttribute("RagdollEndTime", M.vclock + M.serverOffset - 1)
	M.simulating = false
	f.player.AttributeChanged:Fire("RagdollEndTime")
end
function M.clearRagdoll()
	M.simulating = true
	local f = M.fixture
	f.humanoid._props._State = enumItem("HumanoidStateType", "Running")
	f.humanoid._props.PlatformStand = false
	for _, joint in pairs(f.joints) do joint._props.Enabled = true end
	f.player:SetAttribute("RagdollEndTime", M.vclock + M.serverOffset - 1)
	M.simulating = false
	M.endRagdoll()
end
function M.remoteCallsFor(fragment)
	local out = {}
	for _, call in ipairs(M.remoteCalls) do
		if string.find(tostring(call.inst.Name), fragment, 1, true) then out[#out + 1] = call end
	end
	return out
end
function M.aliveConnections()
	local n = 0
	for _, c in ipairs(M.connections) do if not c.disconnected then n = n + 1 end end
	return n
end
function M.violationText()
	if #M.violations == 0 then return "none" end
	local lines = {}
	for i = 1, math.min(#M.violations, 4) do
		local v = M.violations[i]
		lines[#lines + 1] = string.format("%s.%s (%s)", tostring(v.inst.Name), tostring(v.key), tostring(v.kind))
	end
	return table.concat(lines, ", ")
end
function M.findDescendantByName(node, name)
	for _, d in ipairs(node:GetDescendants()) do
		if tostring(d.Name) == name then return d end
	end
	return nil
end
function M.allMotorsEnabled()
	for _, joint in pairs(M.fixture.joints) do
		if not joint._props.Enabled then return false end
	end
	return true
end
M.install()
_G.MOCK = M
return M
