--[[ Offline mock for advanced_scanner_v3.lua (luau-web). Modelled on the real Advanced Scanner v2 dump:
     ReplicatedStorage.Packages.Networking.* remotes, BossFlightRemotes.BeginFlight, Player attributes
     (RagdollEndTime / AreaId), leaderstats, and the Workspace tree with "Trunk" false positives. ]]
local M = {}
M.connections = {}
M.threads = {}
M.coThread = {}
M.errors = {}
M.writes = {}
M.violations = {}
M.outgoingCalls = {}     -- FireServer / FireAllClients / InvokeServer attempts
M.remoteCalls = {}
M.writesArmed = false
M.simulating = false
M.vclock = 0
M.serverOffset = 1790689722   -- fixed fake epoch so RagdollEndTime math looks real
M.prints = {}
M.clipboard = nil

local function newVector3(x, y, z)
	local v = { X = x or 0, Y = y or 0, Z = z or 0 }
	v.Magnitude = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	local mt = {
		__index = function(self, key)
			if key == "Magnitude" then return math.sqrt(self.X^2 + self.Y^2 + self.Z^2) end
			if key == "Unit" then
				local m = math.sqrt(self.X^2 + self.Y^2 + self.Z^2)
				if m > 0 then return newVector3(self.X/m, self.Y/m, self.Z/m) end
				return newVector3(0, 0, 0)
			end
			if key == "Lerp" then
				return function(a, other, alpha)
					local t = alpha or 0
					return newVector3(a.X + (other.X - a.X) * t, a.Y + (other.Y - a.Y) * t,
						a.Z + (other.Z - a.Z) * t)
				end
			end
			return nil
		end,
		__add = function(a, b) return newVector3(a.X+b.X, a.Y+b.Y, a.Z+b.Z) end,
		__sub = function(a, b) return newVector3(a.X-b.X, a.Y-b.Y, a.Z-b.Z) end,
		__div = function(a, b) return newVector3(a.X/b, a.Y/b, a.Z/b) end,
		__mul = function(a, b) return newVector3(a.X*b, a.Y*b, a.Z*b) end,
		__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end,
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

local function clockString(epoch)
	local secs = math.floor(epoch) % 86400
	return string.format("%02d:%02d:%02d", math.floor(secs/3600), math.floor(secs%3600/60), secs%60)
end
DateTime = {
	fromUnixTimestamp = function(t)
		return { Format = function(_, fmt) return clockString(t) end }
	end,
	now = function() return { Format = function(_, fmt) return clockString(M.serverOffset + M.vclock) end } end,
}
_G.setclipboard = function(text) M.clipboard = text end
_G.gethui = nil

local SIGNALS = { Heartbeat=true, Stepped=true, StateChanged=true, HealthChanged=true, Changed=true,
	AttributeChanged=true, CharacterAdded=true, MouseButton1Click=true, FocusLost=true, OnClientEvent=true,
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
	BaseRemoteEvent={"Instance"}, RemoteEvent={"BaseRemoteEvent"}, UnreliableRemoteEvent={"BaseRemoteEvent"},
	RemoteFunction={"Instance"}, ScreenGui={"Instance"}, Frame={"Instance"}, TextLabel={"Instance"},
	TextButton={"Instance"}, TextBox={"Instance"}, ScrollingFrame={"Instance"}, UIListLayout={"Instance"},
	UICorner={"Instance"}, PlayerGui={"Instance"}, Player={"Instance"}, Players={"Instance"},
	Workspace={"Instance"}, RunService={"Instance"}, UserInputService={"Instance"},
	ReplicatedStorage={"Instance"}, DataModel={"Instance"}, ProximityPrompt={"Instance"},
	StringValue={"Instance"}, IntValue={"Instance"}, NumberValue={"Instance"}, Animation={"Instance"},
	Sound={"Instance"}, Backpack={"Instance"} }
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
		if value then
			local sibs = rawget(value, "_children")
			local found = false
			for _, c in ipairs(sibs) do if c == self then found = true break end end
			if not found then table.insert(sibs, self) end
		end
		return
	end
	local props = rawget(self, "_props")
	if not props then props = {}; rawset(self, "_props", props) end
	props[key] = value
	if rawget(self, "_isFixture") and not M.simulating then
		M.writes[#M.writes + 1] = { inst = self, key = key, value = value }
		if M.writesArmed then
			M.violations[#M.violations + 1] = { inst = self, key = key, kind = "write" }
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
function METHODS:IsA(cls) return classIsA(self, cls) end
function METHODS:GetAttributes()
	local out = {}
	for k, v in pairs(rawget(self, "_attributes")) do out[k] = v end
	return out
end
function METHODS:GetAttribute(name) return rawget(self, "_attributes")[name] end
function METHODS:SetAttribute(name, value) rawget(self, "_attributes")[name] = value end
function METHODS:GetFullName()
	local parts, node = {}, self
	while node do
		if node.ClassName == "DataModel" then break end   -- real GetFullName omits "game."
		parts[#parts + 1] = tostring(rawget(node, "_props").Name)
		node = rawget(node, "_parent")
	end
	local out = {}
	for i = #parts, 1, -1 do out[#out + 1] = parts[i] end
	return table.concat(out, ".")
end
function METHODS:GetState() return rawget(self, "_props")._State or enumItem("HumanoidStateType", "Running") end
function METHODS:ChangeState(newState)
	local props = rawget(self, "_props")
	if props._State == newState then return end
	local previous = props._State
	props._State = newState
	self.StateChanged:Fire(self, newState, previous)
end
function METHODS:GetNetworkOwner() return rawget(self, "_extra").networkOwner end
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
	M.outgoingCalls[#M.outgoingCalls + 1] = { inst = self, kind = "InvokeServer" }
	M.violations[#M.violations + 1] = { inst = self, kind = "invoke" }
	local responder = rawget(self, "_extra").invokeResponder
	if responder then return responder(...) end
	return nil
end
function METHODS:FireServer(...)
	M.outgoingCalls[#M.outgoingCalls + 1] = { inst = self, kind = "FireServer" }
	M.violations[#M.violations + 1] = { inst = self, kind = "fire" }
end
function METHODS:FireAllClients(...)
	M.outgoingCalls[#M.outgoingCalls + 1] = { inst = self, kind = "FireAllClients" }
	M.violations[#M.violations + 1] = { inst = self, kind = "fire" }
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
	task.spawn(function() task.wait(seconds) fn(table.unpack(args)) end)
end
spawnCallback = function(fn, ...) return task.spawn(fn, ...) end
-- the sandbox's os table is readonly: shadow it with a proxy whose clock is the virtual clock
local baseOs = os
os = setmetatable({ clock = function() return M.vclock end, time = baseOs.time, date = baseOs.date,
	difftime = baseOs.difftime }, { __index = baseOs })

function M.build()
	local game = M.new("DataModel", "game", nil, { JobId = "mock", PlaceId = 1 })
	local services = {}
	local function service(cls, name) services[name] = M.new(cls, name, game, {}) return services[name] end
	local players = service("Players", "Players")
	local runService = service("RunService", "RunService")
	local workspace = service("Workspace", "Workspace")
	local replicated = service("ReplicatedStorage", "ReplicatedStorage")
	service("UserInputService", "UserInputService")
	M.setExtra(game, "GetService", function(_, name) return services[name] end)
	M.setExtra(workspace, "GetServerTimeNow", function() return M.serverOffset + M.vclock end)

	-- remotes exactly like the real dump (subset)
	local packages = M.new("Folder", "Packages", replicated, {})
	local networking = M.new("Folder", "Networking", packages, {})
	local function re(name) return M.new("RemoteEvent", name, networking, {}) end
	local function rf(name) return M.new("RemoteFunction", name, networking, {}) end
	local watchTargets = {
		re("RE/BossEvent/BlackHoleHit"), re("RE/BossEvent/HazardHit"), re("RE/BossEvent/Vfx"),
		re("RE/BossEvent/HealthShifted"), re("RE/BossEvent/StateShifted"),
		re("RE/ScrambleBoss/HazardHit"), re("RE/ScrambleBoss/Transition"),
		re("RE/Limpness/WriteLimpness"), re("RE/ZoneProbe/AnchorForZone"),
		re("RE/RigSync/CorrectionBegan"), re("RE/SharedFx/JoltOnce"),
		re("RE/GuardPatrol/ForestStrike"), re("RE/EggWorld/FieldEggCarry"),
		re("RE/EggWorld/FieldEggCycleCountdown"), re("RE/Treadmill/SpeedGained"),
		re("RE/Telemetry/SubmitIdleState"),
	}
	local snapshotRF = rf("RF/EggWorld/AskFieldEggSnapshot")
	rf("RF/EggWorld/AskFieldEggCarry")
	rf("RF/EggWorld/AskFieldEggDrop")
	rf("RF/EggWorld/AskLiveSnapshot")
	local bossFlight = M.new("RemoteEvent", "BeginFlight", M.new("Folder", "BossFlightRemotes", replicated, {}), {})
	local adBoost = M.new("RemoteEvent", "LogTelemetry", M.new("Folder", "AdEggBoostRemotes", replicated, {}), {})

	-- world tree with the Trunk/running false positives from the real dump
	local world = M.new("Model", "World", workspace, {})
	local build = M.new("Model", "Build", world, {})
	local cherry = M.new("Model", "CherryBlossomZone", build, {})
	local props = M.new("Folder", "Props", cherry, {})
	local z10 = M.new("Folder", "Zone10Props", props, {})
	local trees = M.new("Folder", "Trees", z10, {})
	local tree2 = M.new("Model", "Tree2", trees, {})
	M.new("Model", "Trunk", tree2, {})
	local plots = M.new("Folder", "Plots", workspace, {})
	local plot1 = M.new("Folder", "1", plots, {})
	M.new("Model", "TreadmillUpgrade", plot1, {})
	M.new("Part", "TreadmillBottom", plot1, {})
	local renders = M.new("Folder", "__ClientTreadmillRenders", workspace, {})
	M.new("Tool", "TreadmillRender_1", renders, {})
	M.new("Sound", "Running", workspace, {})   -- real "running" match, not a false positive

	-- player
	local player = M.new("Player", "mackyhohohoho", players, { UserId = 42 })
	local playerGui = M.new("PlayerGui", "PlayerGui", player, {})
	local leaderstats = M.new("Folder", "leaderstats", player, {})
	M.new("IntValue", "Money/s", leaderstats, { Value = 18108437162 })
	M.new("IntValue", "Speed", leaderstats, { Value = 3830785622 })
	player._attributes = { __UG = true, AreaId = "Jungle", CashPackAmount1 = 24000,
		RagdollEndTime = M.serverOffset + M.vclock + 3.0,
		JoinTick = M.serverOffset - 14294.7, ProfileReady = true }

	-- character
	local character = M.new("Model", "TestCharacter", workspace, {})
	local humanoid = M.new("Humanoid", "Humanoid", character, { WalkSpeed = 16, Health = 100,
		MaxHealth = 100, PlatformStand = false, Sit = false, AutoRotate = true,
		_State = enumItem("HumanoidStateType", "Running") })
	local root = M.new("Part", "HumanoidRootPart", character, { Position = newVector3(0, 70, 0),
		Anchored = false, Massless = false, CanCollide = true,
		AssemblyLinearVelocity = newVector3(0, 0, 0), AssemblyAngularVelocity = newVector3(0, 0, 0) })
	player.Character = character
	players.LocalPlayer = player

	M.services = services
	M.fixture = { game = game, services = services, workspace = workspace, replicated = replicated,
		player = player, playerGui = playerGui, character = character, humanoid = humanoid, root = root,
		heartbeat = runService.Heartbeat, watchTargets = watchTargets, snapshotRF = snapshotRF,
		bossFlight = bossFlight, adBoost = adBoost, tree2 = tree2, plot1 = plot1, leaderstats = leaderstats }
	return M.fixture
end
function M.install()
	local fixture = M.build()
	_G.game = fixture.game
	_G.workspace = fixture.workspace
	return fixture
end

function M.pump(seconds, step)
	step = step or 0.02
	local target = M.vclock + seconds
	local guard = 0
	while M.vclock < target do
		guard = guard + 1
		if guard > 200000 then error("pump guard") end
		local dt = math.min(step, target - M.vclock)
		M.vclock = M.vclock + dt
		-- integrate root velocity so a "hit" actually moves the character
		local hum, root = M.fixture.humanoid, M.fixture.root
		local velocity = root._props.AssemblyLinearVelocity
		M.simulating = true
		if velocity and (velocity.X ~= 0 or velocity.Y ~= 0 or velocity.Z ~= 0) then
			root._props.Position = newVector3(root._props.Position.X + velocity.X * dt,
				root._props.Position.Y + velocity.Y * dt,
				root._props.Position.Z + velocity.Z * dt)
		end
		M.simulating = false
		M.fixture.heartbeat:Fire(dt)
		-- run any woken threads
		for _, thread in ipairs(M.threads) do
			if not thread.dead and not thread.cancelled and thread.wake <= M.vclock then
				resumeThread(thread)
			end
		end
		local keep = {}
		for _, thread in ipairs(M.threads) do
			if not thread.dead and not thread.cancelled then keep[#keep + 1] = thread end
		end
		if #M.threads > 256 then M.threads = keep end
	end
end

-- ---- driver helpers (all simulate the game, so they never count as scanner writes)
function M.drive(fn)
	M.simulating = true
	local ok, err = pcall(fn)
	M.simulating = false
	if not ok then error(err) end
end
function M.setVelocity(x, y, z)
	M.drive(function() M.fixture.root._props.AssemblyLinearVelocity = newVector3(x, y, z) end)
end
function M.setAttribute(inst, name, value)
	inst._attributes[name] = value
	M.drive(function() inst.AttributeChanged:Fire(name, value) end)
end
function M.setWalkSpeed(hum, value)
	M.drive(function()
		hum._props.WalkSpeed = value
		hum.Changed:Fire("WalkSpeed")
	end)
end
function M.setProp(inst, prop, value)
	M.drive(function()
		inst._props[prop] = value
		inst.Changed:Fire(prop)
	end)
end
function M.setHealth(hum, value)
	M.drive(function()
		hum._props.Health = value
		hum.HealthChanged:Fire(value)
	end)
end
function M.addChild(parent, child)
	child.Parent = parent
	M.drive(function() parent.ChildAdded:Fire(child) end)
end
function M.removeChild(parent, child)
	child.Parent = nil
	M.drive(function() parent.ChildRemoved:Fire(child) end)
end
function M.fireRemote(re, ...)
	local args = { ... }
	M.drive(function() re.OnClientEvent:Fire(table.unpack(args)) end)
end
function M.serverNow() return M.serverOffset + M.vclock end

function M.aliveConnections()
	local n = 0
	for _, conn in ipairs(M.connections) do if not conn.disconnected then n = n + 1 end end
	return n
end
function M.findDescendantByName(node, name)
	if tostring(node._props.Name) == name then return node end
	for _, child in ipairs(node._children) do
		local found = M.findDescendantByName(child, name)
		if found then return found end
	end
	return nil
end
function M.journalText()
	local API = _G.ADVANCED_SCANNER_V3
	if not API then return "" end
	local parts = {}
	for _, e in ipairs(API.journal()) do parts[#parts + 1] = e.line end
	return table.concat(parts, "\n")
end
function M.reset() -- fresh state between scenario phases (keeps the fixture)
	M.writesArmed = true
	M.violations = {}
	M.outgoingCalls = {}
end
M.install()   -- build the fixture at load time, before the scanner chunk runs
_G.MOCK = M
return M
