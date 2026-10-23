--[[
    Minimal Roblox environment stub for long-run testing of EggGoToUI_v11.lua.

    Goal: let the *real* script run unmodified under LuaJIT with a virtual clock,
    so the test can drive Auto Farm + Auto Fishing for hours of simulated time and
    observe remote traffic, log growth, memory and recovery behaviour.

    Not a Roblox emulator. Only the surface the script touches is implemented;
    unknown members raise an explicit error instead of silently returning nil so
    the harness fails loudly when the script starts using something new.
]]

local Stub = {}

---------------------------------------------------------------------------
-- time / task scheduler (single-threaded, waits advance a virtual clock)
---------------------------------------------------------------------------
Stub.now = 0
Stub.waitCount = 0
Stub.maxTime = 60 * 60          -- virtual seconds before the run is aborted
Stub.maxWaits = 20e6
Stub.pending = {}

local function guard()
    if Stub.now > Stub.maxTime then error("virtual time budget exceeded") end
    if Stub.waitCount > Stub.maxWaits then error("too many task.wait calls (runaway loop)") end
end

function Stub.step(seconds)
    Stub.waitCount = Stub.waitCount + 1
    Stub.tick(seconds)
end

-- Real coroutines: Lua 5.2+ allows yielding through pcall, so the script's
-- pcall-wrapped loops suspend correctly and the driver controls interleaving
-- (which is what makes race conditions observable).
Stub.coros = {}
Stub.errors = {}

local function schedule(f, delay)
    local co = coroutine.create(f)
    table.insert(Stub.coros, { co = co, wake = Stub.now + (delay or 0) })
end
Stub.schedule = schedule

local taskLib = {
    wait = function(t) coroutine.yield(t or 0) end,
    spawn = function(f) schedule(f, 0) end,
    delay = function(t, f) schedule(f, t) end,
    defer = function(f) schedule(f, 0) end,
}

-- Advance the clock, resume everything that is due. One resume per coroutine per
-- tick keeps the ordering deterministic and lets the driver interleave events.
function Stub.tick(dt)
    Stub.now = Stub.now + (dt or 0.1)
    guard()
    local resumed = 0
    local i = 1
    while i <= #Stub.coros do
        local item = Stub.coros[i]
        if item.wake <= Stub.now then
            local ok, res = coroutine.resume(item.co)
            if not ok then
                table.insert(Stub.errors, tostring(res))
                table.remove(Stub.coros, i)
            elseif coroutine.status(item.co) == "dead" then
                table.remove(Stub.coros, i)
            else
                item.wake = Stub.now + (tonumber(res) or 0)
                i = i + 1
            end
            resumed = resumed + 1
            if resumed > 400 then break end
        else
            i = i + 1
        end
    end
end

---------------------------------------------------------------------------
-- value types
---------------------------------------------------------------------------
local Vector3 = {}
local Vector2Stub = { X = 0, Y = 0 }
Vector3.__index = Vector3
function Vector3.new(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3) end
Vector3.zero = Vector3.new(0, 0, 0)
function Vector3.__add(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
function Vector3.__sub(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
function Vector3.__mul(a, b)
    if type(b) == "number" then return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
    if type(a) == "number" then return Vector3.new(b.X * a, b.Y * a, b.Z * a) end
    return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
function Vector3.__div(a, b) return Vector3.new(a.X / b, a.Y / b, a.Z / b) end
function Vector3.__eq(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
function Vector3.__tostring(v) return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z) end
Vector3.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then
        local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
        if m < 1e-9 then return Vector3.new(0, 0, 0) end
        return Vector3.new(v.X / m, v.Y / m, v.Z / m)
    end
    return rawget(Vector3, k)
end
Vector3.Dot = nil -- provided as method below (v:Dot(other))
local vmeta = getmetatable(Vector3.new())
vmeta.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then
        local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
        if m < 1e-9 then return Vector3.new(0, 0, 0) end
        return Vector3.new(v.X / m, v.Y / m, v.Z / m)
    end
    if k == "Dot" then return function(self, o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end end
    return nil
end

local CFrame = {}
CFrame.__index = CFrame
function CFrame.new(a, b, c)
    local pos
    if type(a) == "table" and a.X then pos = a
    elseif type(a) == "number" then pos = Vector3.new(a, b or 0, c or 0)
    else pos = Vector3.new(0, 0, 0) end
    return setmetatable({ Position = pos, _look = Vector3.new(0, 0, -1) }, CFrame)
end
function CFrame.lookAt(from, to)
    local d = Vector3.new(to.X - from.X, to.Y - from.Y, to.Z - from.Z)
    local u = d.Unit
    return setmetatable({ Position = from, _look = u }, CFrame)
end
CFrame.__index = function(cf, k)
    if k == "Position" then return rawget(cf, "Position") end
    if k == "LookVector" then return rawget(cf, "_look") end
    if k == "RightVector" then
        local l = rawget(cf, "_look")
        return Vector3.new(-l.Z, 0, l.X)
    end
    return nil
end
CFrame.__sub = function(a, b) return CFrame.new(Vector3.new(a.Position.X - b.Position.X, a.Position.Y - b.Position.Y, a.Position.Z - b.Position.Z)) end
CFrame.__mul = function(a, b) return a end

local Color3 = {}
function Color3.new(r, g, b) return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, { __index = Color3 }) end
function Color3.fromRGB(r, g, b) return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end

local UDim = {}
function UDim.new(s, o) return { Scale = s or 0, Offset = o or 0 } end
local UDim2 = {}
function UDim2.new(xs, xo, ys, yo)
    return { X = { Scale = xs or 0, Offset = xo or 0 }, Y = { Scale = ys or 0, Offset = yo or 0 } }
end
function UDim2.fromOffset(x, y)
    return { X = { Scale = 0, Offset = x or 0 }, Y = { Scale = 0, Offset = y or 0 } }
end
function UDim2.fromScale(x, y)
    return { X = { Scale = x or 0, Offset = 0 }, Y = { Scale = y or 0, Offset = 0 } }
end

local Enum = setmetatable({}, {
    __index = function(_, enumName)
        return setmetatable({}, { __index = function(_, item) return { Name = item, Value = 0, EnumType = enumName } end })
    end,
})
Enum.Font = { Gotham = "Gotham", GothamBold = "GothamBold", Code = "Code" }
Enum.TextXAlignment = { Left = "Left", CenterX = "CenterX" }
Enum.TextYAlignment = { Top = "Top" }
Enum.TextTruncate = { AtEnd = "AtEnd" }
Enum.SortOrder = { LayoutOrder = "LayoutOrder" }
Enum.AutomaticSize = { Y = "Y", X = "X", None = "None" }
Enum.UserInputType = { MouseButton1 = "MouseButton1", Touch = "Touch", MouseMovement = "MouseMovement" }
Enum.KeyCode = { E = "E", Q = "Q", Space = "Space" }

---------------------------------------------------------------------------
-- instances
---------------------------------------------------------------------------
Stub.registry = {}         -- name -> instance (last created with that name)
Stub.instances = {}        -- all created instances
Stub.created = {}          -- class -> created count (leak forensics)
Stub.children = setmetatable({}, { __mode = "k" })

local Instance

local knownMethods
knownMethods = {
    FindFirstChild = function(self, name, recursive)
        for _, c in ipairs(Stub.children[self] or {}) do
            if c.Name == name then return c end
        end
        if recursive then
            for _, c in ipairs(Stub.children[self] or {}) do
                local f = knownMethods.FindFirstChild(c, name, true)
                if f then return f end
            end
        end
        return nil
    end,
    FindFirstChildOfClass = function(self, class)
        for _, c in ipairs(Stub.children[self] or {}) do
            if c.ClassName == class then return c end
        end
        return nil
    end,
    FindFirstChildWhichIsA = function(self, class, recursive)
        for _, c in ipairs(Stub.children[self] or {}) do
            if c.ClassName == class then return c end
        end
        if recursive then
            for _, c in ipairs(Stub.children[self] or {}) do
                local f = knownMethods.FindFirstChildWhichIsA(c, class, true)
                if f then return f end
            end
        end
        return nil
    end,
    WaitForChild = function(self, name) return knownMethods.FindFirstChild(self, name) or Instance.new("Folder", self) end,
    GetChildren = function(self) return Stub.children[self] or {} end,
    GetDescendants = function(self)
        local out = {}
        local function walk(node)
            for _, c in ipairs(Stub.children[node] or {}) do
                table.insert(out, c)
                walk(c)
            end
        end
        walk(self)
        return out
    end,
    IsA = function(self, class)
        if self.ClassName == class then return true end
        local parents = {
            Part = "BasePart", MeshPart = "BasePart", UnionOperation = "BasePart",
            Folder = "Instance", Model = "Instance", Tool = "BackpackItem",
            TextButton = "GuiButton", TextLabel = "GuiObject", Frame = "GuiObject",
            ScrollingFrame = "GuiObject", RemoteFunction = "Instance", Humanoid = "Instance",
        }
        local p = parents[self.ClassName]
        while p do
            if p == class then return true end
            p = parents[p]
        end
        return false
    end,
    Destroy = function(self)
        rawset(self, "_destroyed", true)
        local p = rawget(self, "_parent")
        if p and Stub.children[p] then
            for i, c in ipairs(Stub.children[p]) do
                if c == self then table.remove(Stub.children[p], i) break end
            end
        end
        self.Parent = nil
    end,
    GetPivot = function(self) return CFrame.new(self._position or Vector3.new(0, 0, 0)) end,
    GetAttribute = function(self, k) return (self._attrs or {})[k] end,
    SetAttribute = function(self, k, v)
        self._attrs = self._attrs or {}
        self._attrs[k] = v
        local ls = self._attrListeners and self._attrListeners[k]
        if ls then for _, fn in ipairs({ table.unpack(ls) }) do fn() end end
    end,
    GetAttributeChangedSignal = function(self, prop)
        return { Connect = function(_, fn)
            self._attrListeners = self._attrListeners or {}
            self._attrListeners[prop] = self._attrListeners[prop] or {}
            table.insert(self._attrListeners[prop], fn)
            return { Disconnect = function() end }
        end }
    end,
    GetPropertyChangedSignal = function(self, prop)
        return { Connect = function(_, fn)
            self._propListeners = self._propListeners or {}
            self._propListeners[prop] = self._propListeners[prop] or {}
            table.insert(self._propListeners[prop], fn)
            return { Disconnect = function() end }
        end }
    end,
    InvokeServer = function(self) return Stub.onInvoke and Stub.onInvoke(self) or nil end,
    FireServer = function(self) Stub.fireCount = (Stub.fireCount or 0) + 1 end,
    Move = function(self, dir) rawset(self, "MoveDirection", dir or Vector3.new(0, 0, 0)) end,
    MoveTo = function(self, pos)
        local char = self.Parent
        local root = char and knownMethods.FindFirstChild(char, "HumanoidRootPart")
        if root and pos then root._position = pos end
    end,
    EquipTool = function(self, tool)
        local char = self.Parent
        if char and tool then tool.Parent = char; tool._equipped = true end
        self._equipped = tool
    end,
    UnequipTools = function(self)
        local char = self.Parent
        local bp = LocalPlayer and LocalPlayer:FindFirstChild("Backpack")
        if char and bp then
            for _, c in ipairs({ table.unpack(Stub.children[char] or {}) }) do
                if c.ClassName == "Tool" then c.Parent = bp; c._equipped = false end
            end
        end
        self._equipped = nil
    end,
    InputHoldBegin = function() end,
    InputHoldEnd = function() end,
    GetFocusedTextBox = function() return nil end,
    JSONEncode = function(_, v) return "{}" end,
    GetTagged = function() return Stub.tagged or {} end,
    UnequipTools = function(self) self._equipped = nil end,
}

Stub.signals = setmetatable({}, { __mode = "k" })
function Stub.signal(owner)
    local sig = { _handlers = {} }
    Stub.signals[owner] = Stub.signals[owner] or {}
    table.insert(Stub.signals[owner], sig)
    function sig:Connect(fn)
        table.insert(self._handlers, fn)
        return { Disconnect = function() end, _fn = fn }
    end
    return sig
end
function defaultSignal(owner, key)
    owner._sigs = owner._sigs or {}
    local sig = owner._sigs[key]
    if not sig then
        sig = { _handlers = {}, _key = key, _owner = owner }
        function sig:Connect(fn)
            table.insert(self._handlers, fn)
            return { Disconnect = function()
                for i, h in ipairs(self._handlers) do if h == fn then table.remove(self._handlers, i) break end end
            end, _fn = fn }
        end
        function sig:Fire(...)
            for _, fn in ipairs({ table.unpack(self._handlers) }) do fn(...) end
        end
        function sig:HandlerCount() return #self._handlers end
        owner._sigs[key] = sig
    end
    return sig
end
Stub.defaultSignal = defaultSignal
Stub.fire = function(obj, key, ...)
    local sig = obj and obj._sigs and obj._sigs[key]
    if sig then sig:Fire(...) end
end

---------------------------------------------------------------------------
-- optional profiling (opt-in; completely inert unless Stub.prof.enabled).
-- Measures wall-clock CPU spent inside the script's calls into the Roblox API,
-- which is what shows up as frame time / hitch in the real client.
---------------------------------------------------------------------------
Stub.prof = { enabled = false, calls = {}, cpu = {}, names = {}, order = {} }

local function profAdd(key, dt)
    local p = Stub.prof
    if p.calls[key] == nil then
        p.calls[key] = 0
        p.cpu[key] = 0
        table.insert(p.order, key)
        p.names[key] = key
    end
    p.calls[key] = p.calls[key] + 1
    p.cpu[key] = p.cpu[key] + dt
end
Stub.profAdd = profAdd

function Stub.profReset()
    Stub.prof.calls, Stub.prof.cpu, Stub.prof.order = {}, {}, {}
end

function Stub.profReport()
    local out = {}
    for _, key in ipairs(Stub.prof.order) do
        table.insert(out, { name = key, calls = Stub.prof.calls[key], cpu = Stub.prof.cpu[key] })
    end
    table.sort(out, function(a, b) return a.cpu > b.cpu end)
    return out
end

-- live instances (Destroy only unparents in the stub, so track it explicitly)
function Stub.liveInstances()
    local n = 0
    for _, inst in ipairs(Stub.instances) do
        if not rawget(inst, "_destroyed") then n = n + 1 end
    end
    return n
end

-- total connected handlers across every signal ever handed to the script
function Stub.handlerCount()
    local n = 0
    for _, inst in ipairs(Stub.instances) do
        local sigs = inst._sigs
        if sigs then
            for _, sig in pairs(sigs) do n = n + #sig._handlers end
        end
    end
    for _, list in pairs(Stub.signals) do
        for _, sig in ipairs(list) do n = n + #sig._handlers end
    end
    return n
end

local okSet = {
    Visible = true, Parent = true, Name = true, Text = true, Value = true,
    WalkSpeed = true, Health = true, ClockTime = true, CanCollide = true,
}

Instance = {}
Instance.new = function(class, parent)
    local t0 = os.clock()
    local obj = {
        ClassName = class,
        _name = class,
        _parent = nil,
        _attrs = {},
        -- Property writes must go through __newindex every time, otherwise the
        -- second write to e.g. Lighting.ClockTime would bypass change listeners.
        _props = { Visible = true },
    }
    setmetatable(obj, {
        __index = function(t, k)
            local raw = rawget(t, k)
            if raw ~= nil then return raw end
            if k == "Name" then return rawget(t, "_name") end
            if k == "Parent" then return rawget(t, "_parent") end
            local props = rawget(t, "_props")
            if props and props[k] ~= nil then return props[k] end
            if knownMethods[k] then
                if not Stub.prof.enabled then return knownMethods[k] end
                local cache = t._profWrap
                if not cache then cache = {}; rawset(t, "_profWrap", cache) end
                local w = cache[k]
                if not w then
                    local fn = knownMethods[k]
                    w = function(self2, ...)
                        local t0 = os.clock()
                        local res = table.pack(fn(self2, ...))
                        profAdd(k, os.clock() - t0)
                        return table.unpack(res, 1, res.n)
                    end
                    cache[k] = w
                end
                return w
            end
            if k == "CFrame" then return CFrame.new(t._position or Vector3.new(0, 0, 0)) end
            if k == "Position" then return t._position or Vector3.new(0, 0, 0) end
            if k == "AssemblyLinearVelocity" then return t._velocity or Vector3.new(0, 0, 0) end
            if k == "MoveDirection" then return t.MoveDirection or Vector3.new(0, 0, 0) end
            if k == "AbsolutePosition" then return Vector2Stub end
            if k == "AbsoluteSize" then return Vector2Stub end
            if k == "PrimaryPart" then return nil end
            if k == "Anchored" or k == "Sit" or k == "PlatformStand" or k == "Jump" then return false end
            -- dot-access to a child, e.g. ReplicatedStorage.Packages.Networking
            local kids = Stub.children[t]
            if kids then
                for _, c in ipairs(kids) do
                    if c._name == k then return c end
                end
            end
            if k == "MouseButton1Click" or k == "FocusLost" or k == "InputBegan" or k == "InputEnded"
                or k == "InputChanged" or k == "MouseButton1Down" or k == "Heartbeat" or k == "Stepped"
                or k == "CharacterAdded" or k == "OnClientEvent" or k == "Activated"
                or k == "ChildAdded" or k == "ChildRemoved" or k == "DescendantAdded"
                or k == "StateChanged" or k == "AncestryChanged" then
                return defaultSignal(t, k)
            end
            return nil
        end,
        __newindex = function(t, k, v)
            if k == "Parent" then
                local old = rawget(t, "_parent")
                if old and Stub.children[old] then
                    for i, c in ipairs(Stub.children[old]) do
                        if c == t then table.remove(Stub.children[old], i) break end
                    end
                end
                rawset(t, "_parent", v)
                if v then
                    Stub.children[v] = Stub.children[v] or {}
                    table.insert(Stub.children[v], t)
                end
                return
            end
            if k == "Name" then rawset(t, "_name", v); Stub.registry[v] = t; return end
            if k == "Position" or k == "CFrame" then
                if type(v) == "table" and v.Position then rawset(t, "_position", v.Position)
                elseif type(v) == "table" and v.X then rawset(t, "_position", v) end
                return
            end
            if k == "AssemblyLinearVelocity" then rawset(t, "_velocity", v); return end
            t._props = rawget(t, "_props") or {}
            t._props[k] = v
            if Stub.prof.enabled then profAdd("write:" .. tostring(k), 0) end
            local ls = t._propListeners and t._propListeners[k]
            if ls then
                for _, fn in ipairs({ table.unpack(ls) }) do fn() end
            end
        end,
        __tostring = function(t) return "Instance<" .. tostring(rawget(t, "_name")) .. ">" end,
    })
    table.insert(Stub.instances, obj)
    Stub.created[class] = (Stub.created[class] or 0) + 1
    if Stub.prof.enabled then profAdd("Instance.new", os.clock() - t0) end
    if parent then obj.Parent = parent end
    Stub.registry[obj._name] = obj
    return obj
end

Stub.Vector3 = Vector3
Stub.CFrame = CFrame
Stub.Instance = Instance

---------------------------------------------------------------------------
-- services / game
---------------------------------------------------------------------------
local services = {}
local function svc(name)
    services[name] = services[name] or Instance.new(name)
    return services[name]
end
Stub.svc = svc

Stub.players = Instance.new("Players")
local localPlayer = Instance.new("Player")
localPlayer.Name = "LocalPlayer"
localPlayer.UserId = 1
local charm = Instance.new("Model"); charm.Name = "Character"
local hum = Instance.new("Humanoid"); hum.Name = "Humanoid"; hum.Health = 100; hum.WalkSpeed = 16
hum.Parent = charm
local hrp = Instance.new("Part"); hrp.Name = "HumanoidRootPart"; hrp.Parent = charm
hrp.Position = Vector3.new(0, 0, 0)
localPlayer.Character = charm
local backpack = Instance.new("Folder"); backpack.Name = "Backpack"; backpack.Parent = localPlayer
local rod = Instance.new("Tool"); rod.Name = "Haunted Rod [X1]"; rod.Parent = backpack
Stub.backpack = backpack
Stub.rod = rod
localPlayer.Parent = Stub.players
Stub.player = localPlayer
Stub.humanoid = hum
Stub.root = hrp
Stub.players.LocalPlayer = localPlayer

local rs = Instance.new("ReplicatedStorage")
Stub.replicatedStorage = rs
local packages = Instance.new("Folder"); packages.Name = "Packages"; packages.Parent = rs
local networking = Instance.new("Folder"); networking.Name = "Networking"; networking.Parent = packages
Stub.networking = networking

-- Remote stubs the script resolves by exact name.
local remoteNames = {
    "RF/Fishing/Cast", "RF/Fishing/Reel", "RE/Fishing/Hold",
    "RF/HalloweenDimension/AskCarryEgg", "RF/HalloweenDimension/AskDropEgg",
    "RF/EggWorld/AskFieldEggCarry", "RF/EggWorld/AskFieldEggSnapshot",
    "RF/ProfileMirror/FetchProfile", "RE/PetSatchel/SellSelection",
    "RF/EggWorld/AskLiveSnapshot",
    "RE/EggWorld/FieldEggShifted", "RE/EggWorld/FieldEggBatchShifted",
    "RE/EggWorld/FieldEggRaritiesShown", "RE/EggWorld/FieldEggGone",
    "RE/EggWorld/FieldEggCycleCountdown",
}
Stub.remotes = {}
for _, n in ipairs(remoteNames) do
    local class = n:sub(1, 3) == "RE/" and "RemoteEvent" or "RemoteFunction"
    local r = Instance.new(class)
    r.Name = n
    r.Parent = networking
    -- a real signal so tests can deliver server->client payloads with Stub.fire
    r.OnClientEvent = defaultSignal(r, "OnClientEvent")
    Stub.remotes[n] = r
end

local workspace = Instance.new("Workspace")
Stub.workspace = workspace
local hwDim = Instance.new("Model"); hwDim.Name = "HalloweenDimension"; hwDim.Parent = workspace
local worldEggs = Instance.new("Folder"); worldEggs.Name = "WorldEggs"; worldEggs.Parent = hwDim
Stub.worldEggs = worldEggs
local camera = Instance.new("Camera"); camera.Name = "CurrentCamera"; camera.Parent = workspace
workspace.CurrentCamera = camera

local lighting = svc("Lighting")
lighting.ClockTime = 12

Stub.eggSeq = 0
function Stub.addEgg(species, rarity, zone, pos)
    Stub.eggSeq = Stub.eggSeq + 1
    local model = Instance.new("Model")
    model.Name = species:gsub("%s", "") .. "Egg" .. Stub.eggSeq
    local hitbox = Instance.new("Part"); hitbox.Name = "Hitbox"; hitbox.Parent = model
    hitbox.Position = pos or Vector3.new(Stub.eggSeq * 10, 0, 0)
    model.PreparedSourceName = nil
    model:SetAttribute("PreparedSourceName", species)
    model:SetAttribute("HalloweenEggUid", "uid" .. Stub.eggSeq)
    model:SetAttribute("HalloweenEggCanPickUp", true)
    model:SetAttribute("Zone", zone or 1)
    model:SetAttribute("Rarity", rarity)
    model.Parent = worldEggs
    return model
end

---------------------------------------------------------------------------
-- global environment
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- optional game config modules (ReplicatedStorage.Data.Assets.Configs)
---------------------------------------------------------------------------
-- Injected on demand so other scripts that never read the config folder keep
-- the plain environment. `require` of a ModuleScript returns its payload.
function Stub.installSpeciesConfigs(entries)
    local data = Instance.new("Folder")
    data.Name = "Data"
    data.Parent = rs
    local assets = Instance.new("Folder")
    assets.Name = "Assets"
    assets.Parent = data
    local configs = Instance.new("Folder")
    configs.Name = "Configs"
    configs.Parent = assets
    for _, entry in ipairs(entries or {}) do
        local mod = Instance.new("ModuleScript")
        mod.Name = entry.name
        local payload = {}
        for k, v in pairs(entry) do
            if k ~= "name" then payload[k] = v end
        end
        rawset(mod, "_moduleData", payload)
        mod.Parent = configs
    end
    return configs
end

function Stub.buildEnv()
    local env = {
        task = taskLib,
        Vector3 = Vector3,
        CFrame = CFrame,
        Color3 = Color3,
        UDim = UDim,
        UDim2 = UDim2,
        Enum = Enum,
        Instance = Instance,
        os = { clock = function() return Stub.now end, date = os.date, time = os.time },
        table = setmetatable({ clear = function(t) for k in pairs(t) do t[k] = nil end end }, { __index = table }),
        math = setmetatable({ clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end }, { __index = math }),
        game = {
            GetService = function(_, name)
                if name == "Players" then return Stub.players end
                if name == "ReplicatedStorage" then return rs end
                if name == "Workspace" then return workspace end
                if name == "Lighting" then return lighting end
                return svc(name)
            end,
        },
        Workspace = workspace,
        Players = Stub.players,
        ReplicatedStorage = rs,
        HttpService = { JSONEncode = function(_, v) return "{}" end },
        CollectionService = { GetTagged = function() return {} end },
        UserInputService = svc("UserInputService"),
        RunService = svc("RunService"),
        Vector2 = { new = function(x, y) return { X = x or 0, Y = y or 0 } end },
        typeof = function(v)
            if type(v) == "table" then
                local mt = getmetatable(v)
                if mt == Vector3 then return "Vector3" end
                if mt == CFrame then return "CFrame" end
                if v.ClassName then return "Instance" end
                if v.R then return "Color3" end
            end
            return type(v)
        end,
        warn = function(...) Stub.warnings = Stub.warnings or {}; table.insert(Stub.warnings, table.concat({ ... }, " ")) end,
        print = function(...) Stub.logs = Stub.logs or {}; table.insert(Stub.logs, table.concat({ ... }, " ")) end,
        setclipboard = function() end,
        require = function(mod)
            if type(mod) == "table" then
                local payload = rawget(mod, "_moduleData")
                if payload ~= nil then return payload end
            end
            return _G.require(mod)
        end,
        gethui = nil,
    }
    env._G = env
    -- Fall back to the real stdlib for pcall/string/table/ipairs/select/... but
    -- keep every overridden entry above in front of it.
    setmetatable(env, { __index = _G })
    return env
end

return Stub
