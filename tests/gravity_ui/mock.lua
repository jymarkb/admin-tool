--[[ Offline mock for simple_gravity_ui.lua (luau-web).
     Minimal Roblox surface: Workspace.Gravity + GetPropertyChangedSignal, PlayerGui, the GUI classes the
     panel uses, UserInputService drag input, plus a character that must not be written to.
     M.guiParents records where each ScreenGui got parented, so the gethui / PlayerGui paths are testable. ]]
local M = {}
M.connections = {}
M.threads = {}
M.coThread = {}
M.errors = {}
M.writes = {}
M.remoteCalls = {}
M.guiParents = {}
M.trace = {}
M.vclock = 0
M.prints = {}

local function newSignal(name)
	local signal = { _name = name, _handlers = {}, _once = {}, _yielders = {} }
	function signal:Connect(fn)
		local conn = { _signal = self, fn = fn, disconnected = false, connected = true }
		self._handlers[conn] = true
		M.connections[#M.connections + 1] = conn
		function conn:Disconnect()
			if self.disconnected then return end
			self.disconnected = true
			self._signal._handlers[self] = nil
		end
		return conn
	end
	function signal:Once(fn) local c = self:Connect(function(...) c:Disconnect() fn(...) end) return c end
	function signal:Fire(...)
		local args = { ... }
		for conn in pairs(self._handlers) do
			if not conn.disconnected then
				local ok, err = pcall(conn.fn, table.unpack(args))
				if not ok then M.errors[#M.errors + 1] = tostring(err) end
			end
		end
	end
	return signal
end

local ISA = { Instance = {}, Folder = { "Instance" }, Model = { "Instance" }, Part = { "Instance" },
	Humanoid = { "Instance" }, ScreenGui = { "Instance" }, Frame = { "Instance" }, TextLabel = { "Instance" },
	TextButton = { "Instance" }, TextBox = { "Instance" }, UICorner = { "Instance" }, UIListLayout = { "Instance" },
	PlayerGui = { "Instance" }, Player = { "Instance" }, Players = { "Instance" }, Workspace = { "Instance" },
	UserInputService = { "Instance" }, RunService = { "Instance" }, DataModel = { "Instance" } }

local SIGNALS = { Name = true, Activated = true, FocusLost = true, InputBegan = true, InputChanged = true,
	InputEnded = true, Changed = true, ChildAdded = true, ChildRemoved = true, Heartbeat = true, Destroying = true }

local METHODS, InstanceMT = {}, {}
function InstanceMT.__index(self, key)
	local props = rawget(self, "_props")
	if props and props[key] ~= nil then return props[key] end
	if SIGNALS[key] then
		local signals = rawget(self, "_signals")
		signals[key] = signals[key] or newSignal(key)
		return signals[key]
	end
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
			if rawget(self, "_props").ClassName == "ScreenGui" then
				M.guiParents[#M.guiParents + 1] = tostring(rawget(value, "_props").Name)
				M.drive(function() value.ChildAdded:Fire(self) end)
			end
		end
		return
	end
	local props = rawget(self, "_props")
	if not props then props = {}; rawset(self, "_props", props) end
	local previous = props[key]
	props[key] = value
	if key == "Gravity" then M.trace[#M.trace + 1] = { "write", value } end
	if rawget(self, "_isFixture") then
		M.writes[#M.writes + 1] = { inst = self, key = key, value = value }
	end
	if previous ~= value then
		local signals = rawget(self, "_signals")
		-- real Roblox fires property-changed signals whoever wrote the value (server or client)
		local propSignal = rawget(self, "_propSignals")[key]
		if propSignal then
			if key == "Gravity" then M.trace[#M.trace + 1] = { "fire", self._props.Gravity } end
			propSignal:Fire()
		end
		local changed = signals.Changed
		if changed and changed._handlers and next(changed._handlers) then changed:Fire(key) end
	end
end

function METHODS:GetChildren() local out = {}
	for _, c in ipairs(rawget(self, "_children")) do out[#out + 1] = c end return out end
function METHODS:GetDescendants() local out = {}
	local function walk(node) for _, c in ipairs(rawget(node, "_children")) do out[#out + 1] = c walk(c) end end
	walk(self) return out end
function METHODS:FindFirstChild(name)
	for _, c in ipairs(rawget(self, "_children")) do
		if tostring(rawget(c, "_props").Name) == name then return c end end return nil end
function METHODS:WaitForChild(name) return self:FindFirstChild(name) end
function METHODS:FindFirstChildOfClass(cls)
	for _, c in ipairs(rawget(self, "_children")) do if c.ClassName == cls then return c end end return nil end
function METHODS:IsA(cls)
	if self.ClassName == cls then return true end
	for _, a in ipairs(ISA[self.ClassName] or {}) do if a == cls then return true end end
	return false
end
function METHODS:GetPropertyChangedSignal(prop)
	local store = rawget(self, "_propSignals")
	store[prop] = store[prop] or newSignal(prop .. "Changed")
	return store[prop]
end
function METHODS:GetFullName()
	local parts, node = {}, self
	while node do
		if node.ClassName == "DataModel" then break end
		parts[#parts + 1] = tostring(rawget(node, "_props").Name)
		node = rawget(node, "_parent")
	end
	local out = {}
	for i = #parts, 1, -1 do out[#out + 1] = parts[i] end
	return table.concat(out, ".")
end
function METHODS:Destroy()
	local parent = rawget(self, "_parent")
	if parent then
		local siblings = rawget(parent, "_children")
		for i = #siblings, 1, -1 do if siblings[i] == self then table.remove(siblings, i) end end
	end
	local signals = rawget(self, "_signals")
	if signals.Destroying then signals.Destroying:Fire() end
	rawset(self, "_parent", nil)
	rawget(self, "_props").Parent = nil
	for _, child in ipairs(rawget(self, "_children")) do child:Destroy() end
end
function METHODS:FireServer(...) M.remoteCalls[#M.remoteCalls + 1] = { inst = self, kind = "FireServer" } end
function METHODS:InvokeServer(...) M.remoteCalls[#M.remoteCalls + 1] = { inst = self, kind = "InvokeServer" } end

local function newInstance(className, name, parent, props)
	local instance = setmetatable({ ClassName = className, _children = {}, _parent = nil,
		_props = { Name = name or className, ClassName = className }, _signals = {}, _propSignals = {},
		_isFixture = true }, InstanceMT)
	if props then for k, v in pairs(props) do if k ~= "Parent" then instance._props[k] = v end end end
	if parent then instance.Parent = parent end
	return instance
end
M.new = newInstance

Vector3 = { new = function(x, y, z) return { X = x or 0, Y = y or 0, Z = z or 0 } end }
UDim = { new = function(s, o) return { Scale = s or 0, Offset = o or 0 } end }
UDim2 = { new = function(sx, ox, sy, oy) return { X = UDim.new(sx, ox), Y = UDim.new(sy, oy) } end,
	fromOffset = function(x, y) return UDim2.new(0, x, 0, y) end }
Color3 = { new = function(r, g, b) return { R = r or 0, G = g or 0, B = b or 0 } end,
	fromRGB = function(r, g, b) return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end }
Enum = setmetatable({}, { __index = function(_, section)
	return setmetatable({}, { __index = function(_, item) return { EnumType = section, Name = item } end }) end })
Instance = { new = function(className)
	local instance = newInstance(className, className, nil, nil)
	rawset(instance, "_isFixture", false)
	return instance
end }
_G.Instance = Instance

-- task shims on a virtual clock
local function resumeThread(thread)
	if thread.cancelled or thread.dead then return end
	local ok, err = coroutine.resume(thread.co)
	if not ok then thread.dead = true; M.errors[#M.errors + 1] = tostring(err) end
	if coroutine.status(thread.co) == "dead" then thread.dead = true end
end
local function makeThread(fn, args, wake)
	local thread = { co = coroutine.create(function() fn(table.unpack(args)) end), wake = wake,
		dead = false, cancelled = false }
	M.coThread[thread.co] = thread
	M.threads[#M.threads + 1] = thread
	return thread
end
task = {}
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
local baseOs = os
os = setmetatable({ clock = function() return M.vclock end, time = baseOs.time, date = baseOs.date,
	difftime = baseOs.difftime }, { __index = baseOs })

function M.build()
	local game = newInstance("DataModel", "game", nil, {})
	local services = {}
	local function service(cls, name) services[name] = newInstance(cls, name, game, {}) return services[name] end
	local players = service("Players", "Players")
	service("RunService", "RunService")
	local uis = service("UserInputService", "UserInputService")
	local coreGui = service("CoreGui", "CoreGui")
	local workspace = service("Workspace", "Workspace")
	workspace._props.Gravity = 196.2
	local player = newInstance("Player", "mackyhohohoho", players, { UserId = 9521640019 })
	local playerGui = newInstance("PlayerGui", "PlayerGui", player, {})
	local character = newInstance("Model", "mackyhohohoho", workspace, {})
	local humanoid = newInstance("Humanoid", "Humanoid", character, { Health = 100, WalkSpeed = 16 })
	local root = newInstance("Part", "HumanoidRootPart", character, { Position = Vector3.new(0, 70, 0) })
	player.Character = character
	players.LocalPlayer = player
	game.GetService = function(_, name)
		assert(services[name], "unknown service " .. tostring(name))
		return services[name]
	end
	M.services = services
	M.game = game
	M.workspace = workspace
	M.coreGui = coreGui
	M.playerGui = playerGui
	M.player = player
	M.character = character
	M.humanoid = humanoid
	M.root = root
	return M
end

function M.drive(fn)
	local ok, err = pcall(fn)
	if not ok then error(err) end
end
function M.pump(seconds, step)
	step = step or 0.02
	local target = M.vclock + seconds
	local guard = 0
	while M.vclock < target do
		guard = guard + 1
		if guard > 200000 then error("pump guard") end
		M.vclock = M.vclock + math.min(step, target - M.vclock)
		for _, thread in ipairs(M.threads) do
			if not thread.dead and not thread.cancelled and thread.wake <= M.vclock then resumeThread(thread) end
		end
	end
end
function M.aliveConnections()
	local n = 0
	for _, conn in ipairs(M.connections) do if not conn.disconnected then n = n + 1 end end
	return n
end
function M.findDescendantByName(node, name)
	if rawget(node, "_props") and tostring(rawget(node, "_props").Name) == name then return node end
	for _, child in ipairs(rawget(node, "_children")) do
		local found = M.findDescendantByName(child, name)
		if found then return found end
	end
	return nil
end
function M.button(name) return M.findDescendantByName(M.playerGui, name) end
function M.click(name)
	local item = M.button(name)
	assert(item, "no button named " .. name)
	M.drive(function() item.Activated:Fire() end)
	M.pump(0.05)
end
function M.writtenTo(inst)
	for _, w in ipairs(M.writes) do if w.inst == inst then return w end end
	return nil
end
function M.reset()
	M.writes = {}
	M.remoteCalls = {}
	M.errors = {}
end

M.build()
M.writes = {}      -- fixture setup (Parent/Character assignment) is not the script writing
M.trace = {}
_G.game = M.game
_G.workspace = M.workspace
_G.MOCK = M
-- an executor with gethui: the first load must parent the panel to the hidden container
_G.gethui = function() return M.services.CoreGui end
return M
