--[[
    AUTO MULTI-BAT / TOOL SWING v3 (Single-Path Combat Engine)
    =========================================================
    One trigger path, shared by every weapon. Measured with
    farmer/test_auto_bat_trigger_race.py at 68 ms ping (one-way 34 ms):

      logic                        per_weapon  global_strict  swap_negates
      paced rotation (v2 default)     7.50          1.50          7.50
      turbo rotation (v2 turbo)       7.50          1.67         29.98
      target UI click (v2 target)     1.50          1.50          1.50
      this script (swap + fire)       7.50          1.67         29.98

    The in-game server rule is "global 0.60 s cooldown, negated by a weapon
    swap", so the swap+fire cycle wins by 4x. Everything else was overhead:

      1. ONE fire path: equipNext -> FireServer. No mode toggle, no second
         remote path, no per-swing weapon rescans (inventory is cached and
         invalidated by Backpack/Character events only).
      2. Hot loop never touches the UI. Labels are rendered by a separate
         5 Hz tick, so the swing loop does zero string work.
      3. 60 stud TP: locking a target teleports you to TP_OFFSET studs from
         them whenever they are inside TP_RANGE, so the server sees you in
         range at the moment the swing is validated (34 ms later).
      4. Sure hit: the locked target's Humanoid.HealthChanged is the only
         hit signal the game exposes. A health drop counts a hit; WHIFF_LIMIT
         swings with no drop re-teleports to close the gap (knockback) and
         keeps swinging.
      5. Connection hygiene: char/backpack/target/UI listeners are tracked
         and disconnected on rebind and cleanup.
]]

local ok, err = pcall(function()

if _G.AutoMultiSwing_Cleanup then pcall(_G.AutoMultiSwing_Cleanup) end
_G.AutoMultiSwing_Cleanup = nil

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local t0 = os.clock()
    while not LocalPlayer and (os.clock() - t0 < 3) do
        task.wait(0.1)
        LocalPlayer = Players.LocalPlayer
    end
end

local myUidStr  = tostring(LocalPlayer and LocalPlayer.UserId or 0)
local Character = LocalPlayer and LocalPlayer.Character
local Humanoid  = Character and Character:FindFirstChildOfClass("Humanoid")
local Backpack  = LocalPlayer and LocalPlayer:FindFirstChildOfClass("Backpack")

-- ======================
-- CONFIG
-- ======================
-- 5 weapons: 3 bats + 2 throw-tools
local TOOLS = {
    { name = "Titan Axe",       type = "bat"  },
    { name = "Scramble Sword",  type = "bat"  },
    { name = "Pumpkin Scythe",  type = "bat"  },
    { name = "The Scrambler",   type = "tool" },
    { name = "Cricket's Banjo", type = "tool" },
}

local COOLDOWN          = 0.60   -- server swing cooldown (seconds)
local RESPECT_COOLDOWN  = false  -- true only if the server ever enforces a
                                 -- per-weapon cooldown that swapping cannot
                                 -- negate (then this caps at 8.3 hits/s)
local TP_RANGE          = 60     -- max studs a target may be away to lock/TP
local TP_OFFSET         = 4      -- land this close to the target
local WHIFF_LIMIT       = 12     -- swings without a health drop -> re-TP
local UI_INTERVAL       = 0.20   -- 5 Hz HUD / distance refresh
local OUT_OF_RANGE      = "Target beyond " .. TP_RANGE .. " studs"

-- ======================
-- CONNECTION MANAGEMENT
-- ======================
local connections = {}
local function addConnection(conn)
    table.insert(connections, conn)
    return conn
end

local function disconnectAll()
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)
end

-- ======================
-- REMOTES
-- ======================
local function getNet(name)
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    return ReplicatedStorage:FindFirstChild(name, true)
end

local RE_BatSwing    = getNet("RE/BatSwing/Trigger")
local RE_ToolTrigger = getNet("RE/ToolTrigger/Trigger")

if not RE_BatSwing then error("RE/BatSwing/Trigger not found") end
if not RE_ToolTrigger then error("RE/ToolTrigger/Trigger not found") end

-- ======================
-- STATE (grouped to stay inside the root-local budget)
-- ======================
local State = {
    enabled       = false,
    running       = false,
    seq           = 0,
    swings        = 0,
    hits          = 0,
    index         = 1,
    target        = nil,
    whiffs        = 0,
    weapons       = nil,   -- cached array of {name, type, tool}
    cacheDirty    = true,
    lastSwingAt   = {},
    targetHealth  = nil,
    lastHealth    = nil,
    myRoot        = nil,   -- cached root parts: no FindFirstChild in the hot loop
    targetRoot    = nil,
    rateSwings    = 0,
    rateAt        = 0,
    rate          = 0,
}

local targetConns = {}
local watchBackpack -- forward declaration: the lifecycle hook below uses it

-- ======================
-- LIFECYCLE
-- ======================
if LocalPlayer then
    addConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
        Character = newChar
        Humanoid = newChar:WaitForChild("Humanoid", 5) or newChar:FindFirstChildOfClass("Humanoid")
        Backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
        State.cacheDirty = true
    end))
    addConnection(LocalPlayer.CharacterRemoving:Connect(function()
        Character = nil
        Humanoid = nil
    end))
    addConnection(LocalPlayer.ChildAdded:Connect(function(child)
        if not child:IsA("Backpack") then return end
        Backpack = child
        State.cacheDirty = true
        watchBackpack(child)
    end))
end

local function ensureCharacter()
    local healthy = Character and Character.Parent and Humanoid and Humanoid.Parent
        and Humanoid.Health > 0
    if not healthy then
        Character = LocalPlayer and LocalPlayer.Character
        Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
        State.myRoot = nil
        healthy = Character ~= nil and Character.Parent ~= nil
            and Humanoid ~= nil and Humanoid.Health > 0
    end
    if healthy and not State.myRoot then
        State.myRoot = Character:FindFirstChild("HumanoidRootPart")
    end
    return healthy
end

-- ======================
-- INVENTORY CACHE (rebuilt only on Backpack/Character changes)
-- ======================
local function matchToolName(inst, baseName)
    if not inst or not inst:IsA("Tool") then return false end
    local gName = inst:GetAttribute("GearName")
    if gName and gName == baseName then return true end
    local tName = inst.Name
    if tName == baseName or tName:find(baseName, 1, true) then return true end
    return false
end

local function findTool(baseName)
    if Character then
        for _, item in ipairs(Character:GetChildren()) do
            if matchToolName(item, baseName) then return item end
        end
    end
    if not Backpack or not Backpack.Parent then
        Backpack = LocalPlayer and LocalPlayer:FindFirstChildOfClass("Backpack")
    end
    if Backpack then
        for _, item in ipairs(Backpack:GetChildren()) do
            if matchToolName(item, baseName) then return item end
        end
    end
    return nil
end

local function rebuildCache()
    local list = {}
    for _, entry in ipairs(TOOLS) do
        local tool = findTool(entry.name)
        if tool then
            table.insert(list, { name = entry.name, type = entry.type, tool = tool })
        end
    end
    State.weapons = list
    State.cacheDirty = false
    if State.index > #list then State.index = 1 end
end

-- ======================
-- TARGETING / 60 STUD TP
-- ======================
local function rootOf(player)
    local char = player and player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

-- Teleport next to the target so the server validates the swing with us in
-- range. Only fires inside TP_RANGE; returns the distance for the HUD.
local function tpToTarget(player)
    local myRoot = Character and Character:FindFirstChild("HumanoidRootPart")
    local theirRoot = rootOf(player)
    if not myRoot or not theirRoot then return nil end
    local delta = theirRoot.Position - myRoot.Position
    local dist = delta.Magnitude
    if dist > TP_RANGE or dist <= TP_OFFSET then return dist end
    myRoot.CFrame = CFrame.new(theirRoot.Position - delta.Unit * TP_OFFSET, theirRoot.Position)
    return TP_OFFSET
end

local function unbindTargetSignals()
    if State.targetHealth then
        pcall(function() State.targetHealth:Disconnect() end)
    end
    State.targetHealth = nil
    State.targetRoot = nil
    for _, conn in ipairs(targetConns) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(targetConns)
end

-- Humanoid.HealthChanged is the only hit confirmation the game pushes to us.
local function bindTargetSignals(player)
    unbindTargetSignals()
    if not player then return end

    local function watch(character)
        local hum = character and character:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        State.targetRoot = character:FindFirstChild("HumanoidRootPart")
        if State.targetHealth then pcall(function() State.targetHealth:Disconnect() end) end
        State.lastHealth = hum.Health
        State.targetHealth = hum.HealthChanged:Connect(function(hp)
            local prev = State.lastHealth
            State.lastHealth = hp
            if prev and hp < prev then
                State.hits = State.hits + 1
                State.whiffs = 0
            end
        end)
    end

    watch(player.Character)
    table.insert(targetConns, player.CharacterAdded:Connect(watch))
end

local function setTarget(player)
    if State.target == player then player = nil end -- click again to unlock
    State.target = player
    State.whiffs = 0
    bindTargetSignals(player)
    if player then tpToTarget(player) end
end

-- ======================
-- THE ONLY FIRE PATH
-- ======================
local function equipAndFire(entry, target)
    local tool = entry.tool
    if not tool or not tool.Parent then
        State.cacheDirty = true
        return false
    end

    if tool.Parent ~= Character then
        pcall(function() Humanoid:EquipTool(tool) end)
        -- the swap must reach the server before the swing: the equip frame is
        -- kept, and it is the only cost this cycle pays for the negate trick
        task.wait()
    end

    if entry.type == "bat" then
        State.seq = State.seq + 1
        local token = myUidStr .. ":" .. State.seq .. ":" .. math.floor(os.clock() * 1000)
        return (pcall(function() RE_BatSwing:FireServer(target, token) end))
    end
    return (pcall(function() RE_ToolTrigger:FireServer(tool) end))
end

-- ======================
-- UI
-- ======================
local function getSafeParent()
    if typeof(gethui) == "function" then
        local a, b = pcall(gethui)
        if a and b then return b end
    end
    local a, b = pcall(function() return game:GetService("CoreGui") end)
    if a and b then return b end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local gui = Instance.new("ScreenGui")
gui.Name = "AutoMultiSwing"
gui.ResetOnSpawn = false
gui.Parent = getSafeParent()

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 300, 0, 330)
frame.Position = UDim2.new(1, -320, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(220, 140, 60)
stroke.Thickness = 1.5
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -50, 0, 26)
title.Position = UDim2.new(0, 10, 0, 4)
title.BackgroundTransparency = 1
title.Text = "🏏 Multi-Bat Swing (single path)"
title.TextColor3 = Color3.fromRGB(255, 190, 100)
title.TextSize = 14
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 22)
closeBtn.Position = UDim2.new(1, -34, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(150, 45, 45)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.TextSize = 12
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 18)
status.Position = UDim2.new(0, 8, 0, 30)
status.BackgroundTransparency = 1
status.Text = "Ready"
status.TextColor3 = Color3.fromRGB(200, 200, 160)
status.TextSize = 12
status.Font = Enum.Font.Gotham
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = frame

local stats = Instance.new("TextLabel")
stats.Size = UDim2.new(1, -16, 0, 16)
stats.Position = UDim2.new(0, 8, 0, 48)
stats.BackgroundTransparency = 1
stats.Text = "swings 0 · hits 0 · 0.0/s"
stats.TextColor3 = Color3.fromRGB(180, 200, 160)
stats.TextSize = 11
stats.Font = Enum.Font.Code
stats.TextXAlignment = Enum.TextXAlignment.Left
stats.Parent = frame

local targetLabel = Instance.new("TextLabel")
targetLabel.Size = UDim2.new(1, -16, 0, 16)
targetLabel.Position = UDim2.new(0, 8, 0, 64)
targetLabel.BackgroundTransparency = 1
targetLabel.Text = "Target: none (world swings)"
targetLabel.TextColor3 = Color3.fromRGB(180, 200, 220)
targetLabel.TextSize = 11
targetLabel.Font = Enum.Font.Code
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.Parent = frame

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -16, 0, 180)
scroll.Position = UDim2.new(0, 8, 0, 84)
scroll.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.Parent = frame
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.Parent = scroll

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(0, 130, 0, 28)
startBtn.Position = UDim2.new(0, 10, 1, -36)
startBtn.BackgroundColor3 = Color3.fromRGB(180, 110, 40)
startBtn.Text = "START"
startBtn.TextColor3 = Color3.new(1, 1, 1)
startBtn.TextSize = 13
startBtn.Font = Enum.Font.GothamBold
startBtn.Parent = frame
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 6)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0, 130, 0, 28)
stopBtn.Position = UDim2.new(1, -140, 1, -36)
stopBtn.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
stopBtn.Text = "STOP"
stopBtn.TextColor3 = Color3.new(1, 1, 1)
stopBtn.TextSize = 13
stopBtn.Font = Enum.Font.GothamBold
stopBtn.Parent = frame
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 6)

local function setStatus(text, color)
    status.Text = text
    status.TextColor3 = color or Color3.fromRGB(200, 200, 160)
end

-- ---- recycled player rows (never created/destroyed per tick) ----
local rows = {}

local function acquireRow(index)
    local row = rows[index]
    if row then return row end

    local holder = Instance.new("Frame")
    holder.Size = UDim2.new(1, -8, 0, 34)
    holder.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
    holder.BorderSizePixel = 0
    holder.Parent = scroll
    Instance.new("UICorner", holder).CornerRadius = UDim.new(0, 5)

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, -120, 0, 16)
    nameLabel.Position = UDim2.new(0, 8, 0, 2)
    nameLabel.BackgroundTransparency = 1
    nameLabel.TextSize = 12
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.Parent = holder

    local distLabel = Instance.new("TextLabel")
    distLabel.Size = UDim2.new(1, -120, 0, 14)
    distLabel.Position = UDim2.new(0, 8, 0, 18)
    distLabel.BackgroundTransparency = 1
    distLabel.TextSize = 10
    distLabel.Font = Enum.Font.Code
    distLabel.TextXAlignment = Enum.TextXAlignment.Left
    distLabel.Parent = holder

    local lockBtn = Instance.new("TextButton")
    lockBtn.Size = UDim2.new(0, 60, 0, 24)
    lockBtn.Position = UDim2.new(1, -68, 0.5, -12)
    lockBtn.TextColor3 = Color3.new(1, 1, 1)
    lockBtn.TextSize = 11
    lockBtn.Font = Enum.Font.GothamBold
    lockBtn.Text = "TP+LOCK"
    lockBtn.BackgroundColor3 = Color3.fromRGB(60, 90, 130)
    lockBtn.Parent = holder
    Instance.new("UICorner", lockBtn).CornerRadius = UDim.new(0, 4)

    row = { holder = holder, nameLabel = nameLabel, distLabel = distLabel, lockBtn = lockBtn, player = nil }
    -- bound once, reads row.player on click, so no reconnect churn
    addConnection(lockBtn.MouseButton1Click:Connect(function()
        if row.player then setTarget(row.player) end
    end))
    rows[index] = row
    return row
end

-- 5 Hz render tick: the only place labels are written
local function renderUi()
    local myRoot = Character and Character:FindFirstChild("HumanoidRootPart")
    local myPos = myRoot and myRoot.Position

    local players = Players:GetPlayers()
    local used = 0
    for _, player in ipairs(players) do
        local dist
        local theirRoot = rootOf(player)
        if myPos and theirRoot then
            dist = (theirRoot.Position - myPos).Magnitude
        end
        used = used + 1
        local row = acquireRow(used)
        row.player = player
        row.holder.Visible = true
        row.nameLabel.Text = player.Name
        if player == State.target then
            row.nameLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
            row.lockBtn.Text = "LOCKED"
        else
            row.nameLabel.TextColor3 = player == LocalPlayer
                and Color3.fromRGB(120, 220, 140) or Color3.fromRGB(220, 220, 230)
            row.lockBtn.Text = "TP+LOCK"
        end
        if dist then
            row.distLabel.Text = string.format("%.1f studs", dist)
            local inRange = dist <= TP_RANGE
            row.distLabel.TextColor3 = inRange and Color3.fromRGB(120, 220, 140)
                or Color3.fromRGB(220, 140, 80)
            row.lockBtn.BackgroundColor3 = inRange and Color3.fromRGB(60, 130, 90)
                or Color3.fromRGB(90, 70, 60)
        else
            row.distLabel.Text = "no character"
            row.distLabel.TextColor3 = Color3.fromRGB(140, 140, 150)
            row.lockBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
        end
    end
    for i = used + 1, #rows do
        rows[i].holder.Visible = false
        rows[i].player = nil
    end
    scroll.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y + 8)

    local now = os.clock()
    local elapsed = now - State.rateAt
    if elapsed >= 0.5 then
        State.rate = (State.swings - State.rateSwings) / elapsed
        State.rateSwings = State.swings
        State.rateAt = now
    end
    stats.Text = string.format("swings %d · hits %d · %.1f/s",
        State.swings, State.hits, State.rate)
    if State.target then
        local dist = myPos and rootOf(State.target)
        targetLabel.Text = "Target: " .. State.target.Name
            .. (dist and string.format(" · %.1f studs", (dist.Position - myPos).Magnitude) or "")
    else
        targetLabel.Text = "Target: none (world swings)"
    end
    if not State.enabled then
        setStatus(State.swings > 0 and "Stopped" or "Ready – press START",
            Color3.fromRGB(200, 180, 100))
    end
end

-- ======================
-- COMBAT LOOP (one path for every weapon)
-- ======================
local function combatLoop()
    while State.enabled do
        if not ensureCharacter() then
            setStatus("Waiting for respawn...", Color3.fromRGB(200, 180, 100))
            task.wait(0.5)
            continue
        end

        if State.cacheDirty or not State.weapons then rebuildCache() end
        local list = State.weapons
        if #list == 0 then
            setStatus("No configured weapons found", Color3.fromRGB(255, 120, 80))
            task.wait(0.5)
            continue
        end

        if State.index > #list then State.index = 1 end
        local entry = list[State.index]
        State.index = (State.index % #list) + 1

        -- A single owned weapon cannot swap, so the negate trick cannot apply:
        -- gate it on the real cooldown instead of spamming 60 packets/s.
        if RESPECT_COOLDOWN or #list == 1 then
            local last = State.lastSwingAt[entry.name] or -1e9
            local waitFor = COOLDOWN - (os.clock() - last)
            if waitFor > 0 then
                task.wait(waitFor)
                continue
            end
        end

        local target = State.target
        if target and not target.Parent then
            State.target = nil
            target = nil
            unbindTargetSignals()
        end

        -- never spend a swing at a target the server would reject on distance
        if target and State.myRoot and State.targetRoot then
            if (State.targetRoot.Position - State.myRoot.Position).Magnitude > TP_RANGE then
                setStatus(OUT_OF_RANGE, Color3.fromRGB(220, 140, 80))
                task.wait(0.1)
                continue
            end
        end

        if equipAndFire(entry, target) then
            State.swings = State.swings + 1
            State.lastSwingAt[entry.name] = os.clock()
            if target then
                State.whiffs = State.whiffs + 1
                if State.whiffs >= WHIFF_LIMIT then
                    State.whiffs = 0
                    tpToTarget(target) -- knocked back / drifted: close the gap
                end
            end
        end

        task.wait() -- single wait frame; the swap frame was spent above
    end
    State.running = false
end

local function startCombat()
    if State.running then return end
    State.running = true
    State.enabled = true
    State.rateSwings = State.swings
    State.rateAt = os.clock()
    stroke.Color = Color3.fromRGB(220, 160, 60)
    setStatus("Swinging", Color3.fromRGB(255, 200, 100))
    task.spawn(combatLoop)
end

-- ======================
-- WIRING
-- ======================
addConnection(startBtn.MouseButton1Click:Connect(startCombat))

addConnection(stopBtn.MouseButton1Click:Connect(function()
    State.enabled = false
    stroke.Color = Color3.fromRGB(120, 90, 50)
    setStatus("Stopping...", Color3.fromRGB(200, 180, 100))
end))

function watchBackpack(bp)
    if not bp then return end
    addConnection(bp.ChildAdded:Connect(function() State.cacheDirty = true end))
    addConnection(bp.ChildRemoved:Connect(function() State.cacheDirty = true end))
end
watchBackpack(Backpack)

local uiRunning = true
task.spawn(function()
    while uiRunning and gui.Parent do
        local a, b = pcall(renderUi)
        if not a then setStatus("UI: " .. tostring(b), Color3.fromRGB(255, 120, 80)) end
        task.wait(UI_INTERVAL)
    end
end)

local function cleanup()
    State.enabled = false
    uiRunning = false
    unbindTargetSignals()
    disconnectAll()
    if gui and gui.Parent then pcall(function() gui:Destroy() end) end
    _G.AutoMultiSwing_Cleanup = nil
end

_G.AutoMultiSwing_Cleanup = cleanup
addConnection(closeBtn.MouseButton1Click:Connect(cleanup))

rebuildCache()
setStatus("Ready – press START", Color3.fromRGB(200, 200, 160))
stats.Text = string.format("weapons %d / %d", #State.weapons, #TOOLS)

end)

if not ok then
    warn("[AutoMultiSwing] " .. tostring(err))
end
