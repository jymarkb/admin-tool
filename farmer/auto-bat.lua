--[[
    AUTO MULTI-BAT / TOOL SWING v2 (Optimized High-Performance Engine)
    ==================================================================
    Features & Optimizations:
      1. Zero-Re-equip Bypass: If tool is already in Character, skips EquipTool and 0 delay.
      2. Dynamic Active Inventory: Automatically filters out unowned tools (0 dead cycles).
      3. 5-Weapon Support:
           - Titan Axe (bat)
           - Scramble Sword (bat)
           - Pumpkin Scythe (bat)
           - The Scrambler (tool)
           - Cricket's Banjo (tool)
      4. Cooldown-Aware Paced Mode (0.60s / 5 = 0.12s -> 8.33 hits/sec, 100% clean hits).
      5. Turbo Mode Toggle: Frame-by-frame burst switching for maximum packet speed.
      6. Startup Caching & Scope Hygiene: Zero redundant lp.Character / Backpack querying.
      7. Connection Hygiene: All UI & lifecycle events cleanly disconnected on cleanup.
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

-- Lifecycle Tracking
if LocalPlayer then
    addConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
        Character = newChar
        Humanoid = newChar:WaitForChild("Humanoid", 5) or newChar:FindFirstChildOfClass("Humanoid")
    end))
    addConnection(LocalPlayer.CharacterRemoving:Connect(function()
        Character = nil
        Humanoid = nil
    end))
end

-- ======================
-- TOOL CONFIGURATION
-- ======================
-- 5 weapons: 3 bats + 2 tools
local TOOLS = {
    { name = "Titan Axe",       type = "bat"  },
    { name = "Scramble Sword",  type = "bat"  },
    { name = "Pumpkin Scythe",  type = "bat"  },
    { name = "The Scrambler",   type = "tool" },
    { name = "Cricket's Banjo", type = "tool" },
}

local COOLDOWN_PER_BAT = 0.60  -- Server-side weapon swing cooldown (seconds)

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
-- STATE
-- ======================
local enabled     = false
local swinging    = false
local turboMode   = false
local swingCount  = 0
local seq         = 0

-- ======================
-- INVENTORY & TOOL HELPERS
-- ======================
local function matchToolName(inst, baseName)
    if not inst or not inst:IsA("Tool") then return false end
    local gName = inst:GetAttribute("GearName")
    if gName and gName == baseName then return true end
    local tName = inst.Name
    if tName == baseName or tName:find(baseName, 1, true) then return true end
    return false
end

local function resolveTool(baseName)
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

local function getActiveTools()
    local active = {}
    for _, entry in ipairs(TOOLS) do
        local inst = resolveTool(entry.name)
        if inst then
            table.insert(active, {
                name     = entry.name,
                type     = entry.type,
                instance = inst,
            })
        end
    end
    return active
end

-- Zero-thrashing fast equip: no-op if tool is already equipped in Character!
local function equipToolFast(tool)
    if not tool or not Humanoid then return false end
    if tool.Parent == Character then
        return true -- already equipped, 0 wait needed!
    end
    pcall(function() Humanoid:EquipTool(tool) end)
    task.wait() -- exactly 1 frame yield for engine equip resolution
    return true
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
frame.Size = UDim2.new(0, 290, 0, 180)
frame.Position = UDim2.new(1, -310, 0, 20)
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
title.Text = "🏏 Multi-Bat Swing (5 Bats)"
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
closeBtn.TextColor3 = Color3.new(1,1,1)
closeBtn.TextSize = 12
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 18)
status.Position = UDim2.new(0, 8, 0, 32)
status.BackgroundTransparency = 1
status.Text = "Ready"
status.TextColor3 = Color3.fromRGB(200, 200, 160)
status.TextSize = 12
status.Font = Enum.Font.Gotham
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = frame

local toolLabel = Instance.new("TextLabel")
toolLabel.Size = UDim2.new(1, -16, 0, 16)
toolLabel.Position = UDim2.new(0, 8, 0, 50)
toolLabel.BackgroundTransparency = 1
toolLabel.Text = "Current: -"
toolLabel.TextColor3 = Color3.fromRGB(180, 200, 220)
toolLabel.TextSize = 11
toolLabel.Font = Enum.Font.Code
toolLabel.TextXAlignment = Enum.TextXAlignment.Left
toolLabel.Parent = frame

local countLabel = Instance.new("TextLabel")
countLabel.Size = UDim2.new(1, -16, 0, 16)
countLabel.Position = UDim2.new(0, 8, 0, 68)
countLabel.BackgroundTransparency = 1
countLabel.Text = "Swings: 0"
countLabel.TextColor3 = Color3.fromRGB(180, 200, 160)
countLabel.TextSize = 11
countLabel.Font = Enum.Font.Gotham
countLabel.TextXAlignment = Enum.TextXAlignment.Left
countLabel.Parent = frame

-- Mode toggle button: Paced (Clean hits) vs Turbo (Burst)
local modeBtn = Instance.new("TextButton")
modeBtn.Size = UDim2.new(1, -16, 0, 24)
modeBtn.Position = UDim2.new(0, 8, 0, 88)
modeBtn.BackgroundColor3 = Color3.fromRGB(35, 95, 60)
modeBtn.Text = "⚡ Mode: Paced (0.12s @ 8.3/s)"
modeBtn.TextColor3 = Color3.new(1, 1, 1)
modeBtn.TextSize = 11
modeBtn.Font = Enum.Font.GothamBold
modeBtn.Parent = frame
Instance.new("UICorner", modeBtn).CornerRadius = UDim.new(0, 5)

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(0, 125, 0, 28)
startBtn.Position = UDim2.new(0, 10, 1, -38)
startBtn.BackgroundColor3 = Color3.fromRGB(180, 110, 40)
startBtn.Text = "START"
startBtn.TextColor3 = Color3.new(1,1,1)
startBtn.TextSize = 13
startBtn.Font = Enum.Font.GothamBold
startBtn.Parent = frame
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 6)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0, 125, 0, 28)
stopBtn.Position = UDim2.new(1, -135, 1, -38)
stopBtn.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
stopBtn.Text = "STOP"
stopBtn.TextColor3 = Color3.new(1,1,1)
stopBtn.TextSize = 13
stopBtn.Font = Enum.Font.GothamBold
stopBtn.Parent = frame
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 6)

local function setStatus(t, col)
    status.Text = t
    status.TextColor3 = col or Color3.fromRGB(200, 200, 160)
end

local function updateModeUi(activeCount)
    activeCount = activeCount or 5
    if turboMode then
        modeBtn.Text = "🔥 Mode: Turbo (Max Packets)"
        modeBtn.BackgroundColor3 = Color3.fromRGB(180, 75, 40)
    else
        local d = activeCount > 0 and (COOLDOWN_PER_BAT / activeCount) or 0.12
        local rate = d > 0 and (1.0 / d) or 8.3
        modeBtn.Text = string.format("⚡ Mode: Paced (%.2fs @ %.1f/s)", d, rate)
        modeBtn.BackgroundColor3 = Color3.fromRGB(35, 95, 60)
    end
end

-- ======================
-- SWING LOOP
-- ======================
local function startSwinging()
    if swinging then return end
    swinging = true
    enabled = true

    task.spawn(function()
        local lastUiUpdate = 0
        local currentIndex = 1

        while enabled do
            -- Re-check Character / Humanoid if character died/respawned
            if not Character or not Character.Parent or not Humanoid or not Humanoid.Parent or Humanoid.Health <= 0 then
                Character = LocalPlayer and LocalPlayer.Character
                Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
                if not Character or not Humanoid or Humanoid.Health <= 0 then
                    setStatus("Waiting for respawn...", Color3.fromRGB(200, 180, 100))
                    task.wait(0.5)
                    continue
                end
            end

            local activeList = getActiveTools()
            local activeCount = #activeList

            if activeCount == 0 then
                setStatus("No configured tools found", Color3.fromRGB(255, 120, 80))
                toolLabel.Text = "Current: None (waiting...)"
                task.wait(0.5)
                continue
            end

            if currentIndex > activeCount then
                currentIndex = 1
            end

            local entry = activeList[currentIndex]
            local toolName = entry.name
            local toolType = entry.type
            local toolInst = entry.instance

            if not (toolInst and toolInst.Parent) then
                toolInst = resolveTool(toolName)
                entry.instance = toolInst
            end

            local tStart = os.clock()

            if toolInst and Humanoid and Humanoid.Health > 0 then
                -- 1. Fast equip (no-op if already held in hand)
                equipToolFast(toolInst)

                -- 2. Fire server remote
                local fireOk = false
                if toolType == "bat" then
                    seq = seq + 1
                    local token = myUidStr .. ":" .. seq .. ":" .. math.floor(os.clock() * 1000)
                    fireOk = pcall(function()
                        RE_BatSwing:FireServer(nil, token)
                    end)
                else
                    fireOk = pcall(function()
                        RE_ToolTrigger:FireServer(toolInst)
                    end)
                end

                if fireOk then
                    swingCount = swingCount + 1
                    local now = os.clock()
                    if (now - lastUiUpdate) >= 0.05 then
                        lastUiUpdate = now
                        countLabel.Text = "Swings: " .. swingCount
                        toolLabel.Text = "Current: " .. toolName .. " [" .. currentIndex .. "/" .. activeCount .. "]"
                        setStatus("Swinging: " .. toolName, Color3.fromRGB(255, 200, 100))
                    end
                else
                    setStatus("Fire failed: " .. toolName, Color3.fromRGB(255, 120, 80))
                end
            end

            currentIndex = currentIndex + 1
            if currentIndex > activeCount then
                currentIndex = 1
            end

            -- 3. Optimal Pacing Delay
            if turboMode then
                task.wait() -- minimum 1 frame yield
            else
                local elapsed = os.clock() - tStart
                local paceInterval = COOLDOWN_PER_BAT / math.max(activeCount, 1)
                local waitTime = paceInterval - elapsed
                if waitTime > 0.002 then
                    task.wait(waitTime)
                else
                    task.wait()
                end
            end
        end

        swinging = false
        countLabel.Text = "Swings: " .. swingCount
        setStatus("Stopped", Color3.fromRGB(200, 180, 100))
    end)
end

-- ======================
-- BUTTONS & WIRING
-- ======================
addConnection(startBtn.MouseButton1Click:Connect(function()
    enabled = true
    stroke.Color = Color3.fromRGB(220, 160, 60)
    startSwinging()
end))

addConnection(stopBtn.MouseButton1Click:Connect(function()
    enabled = false
    stroke.Color = Color3.fromRGB(120, 90, 50)
    setStatus("Stopping...", Color3.fromRGB(200, 180, 100))
end))

addConnection(modeBtn.MouseButton1Click:Connect(function()
    turboMode = not turboMode
    local count = #getActiveTools()
    updateModeUi(count > 0 and count or 5)
end))

local function cleanup()
    enabled = false
    disconnectAll()
    if gui and gui.Parent then pcall(function() gui:Destroy() end) end
    _G.AutoMultiSwing_Cleanup = nil
end

_G.AutoMultiSwing_Cleanup = cleanup
addConnection(closeBtn.MouseButton1Click:Connect(cleanup))

-- Initial inventory check
local initialTools = getActiveTools()
updateModeUi(#initialTools > 0 and #initialTools or 5)
setStatus("Ready – press START", Color3.fromRGB(200, 200, 160))
toolLabel.Text = "Active Tools: " .. #initialTools .. " / " .. #TOOLS

end)

if not ok then
    warn("[AutoMultiSwing] " .. tostring(err))
end
