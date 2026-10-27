--[[
    AUTO FISHING ENGINE (Clean & Modular)
    =====================================
    Features:
      1. Exact Proven Location: Halloween Bank stand (-5695.6, -203.7, -7370.9) & reel target (-5668.5, -206.5, -7368.9).
      2. Dynamic Rod Detection: Works with any rod in hand or Backpack (Haunted Rod, Basic Rod, etc.) with zero-re-equip bypass.
      3. Clean Fishing Cycle: RE/Fishing/Hold (0.40s) -> RF/Fishing/Cast -> wait (Wait+1.10s) -> RF/Fishing/Reel (up to 2 retries).
      4. Auto-Walk to Bank: Smooth walkToSpot if character drifts > 8 studs away from stand.
      5. Zero Metamethod Overhead: Standalone, pure client remote execution without global hooking.
      6. Compact HUD & Connection Hygiene: Sleek 270x160 UI; 100% listeners cleaned via _G.SimpleAutoFish_Cleanup.
]]

local ok, err = pcall(function()

if _G.SimpleAutoFish_Cleanup then pcall(_G.SimpleAutoFish_Cleanup) end
_G.SimpleAutoFish_Cleanup = nil

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

local Character = LocalPlayer and LocalPlayer.Character
local Humanoid  = Character and Character:FindFirstChildOfClass("Humanoid")
local RootPart  = Character and Character:FindFirstChild("HumanoidRootPart")
local Backpack  = LocalPlayer and LocalPlayer:FindFirstChildOfClass("Backpack")

-- ======================
-- CONNECTIONS & LIFECYCLE
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

if LocalPlayer then
    addConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
        Character = newChar
        Humanoid = newChar:WaitForChild("Humanoid", 5) or newChar:FindFirstChildOfClass("Humanoid")
        RootPart = newChar:WaitForChild("HumanoidRootPart", 5) or newChar:FindFirstChild("HumanoidRootPart")
    end))
    addConnection(LocalPlayer.CharacterRemoving:Connect(function()
        Character = nil
        Humanoid = nil
        RootPart = nil
    end))
end

-- ======================
-- CONFIG (Proven Exact Coordinates & Timing)
-- ======================
local Config = {
    CHAR_POS         = Vector3.new(-5695.6, -203.7, -7370.9),  -- Halloween Fishing Bank Stand
    CAST_POS         = Vector3.new(-5668.5, -206.5, -7368.9),  -- Water Reel Target Coordinates
    CLICKS           = 13,
    HOLD_DELAY       = 0.40,       -- Charge time
    CAST_POWER_MIN   = 0.72,       -- Safe power range
    CAST_POWER_MAX   = 0.90,
    EXTRA_WAIT       = 1.10,       -- Bite window buffer
    CYCLE_PAUSE      = 0.40,       -- Reset delay
    MAX_REEL_RETRIES = 2,
}

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

local Remotes = {
    Hold = getNet("RE/Fishing/Hold"),
    Cast = getNet("RF/Fishing/Cast"),
    Reel = getNet("RF/Fishing/Reel"),
}

if not (Remotes.Hold and Remotes.Cast and Remotes.Reel) then
    error("Fishing remotes not found")
end

-- ======================
-- STATE
-- ======================
local State = {
    Enabled    = false,
    Running    = false,
    CatchCount = 0,
}

-- ======================
-- ROD & NAVIGATION LOGIC
-- ======================
local function isRod(tool)
    if not (tool and tool:IsA("Tool")) then return false end
    local gName = tool:GetAttribute("GearName")
    if gName and gName:lower():find("rod", 1, true) then return true end
    return tool.Name:lower():find("rod", 1, true) ~= nil
end

local function ensureRodEquipped()
    if Character then
        for _, t in ipairs(Character:GetChildren()) do
            if isRod(t) then return true end -- already in hand
        end
    end
    local bp = Backpack or (LocalPlayer and LocalPlayer:FindFirstChildOfClass("Backpack"))
    if bp then
        for _, t in ipairs(bp:GetChildren()) do
            if isRod(t) then
                if Humanoid then
                    pcall(function() Humanoid:EquipTool(t) end)
                    task.wait(0.2)
                end
                return true
            end
        end
    end
    return false
end

local function walkToSpot()
    local hrp = RootPart or (Character and Character:FindFirstChild("HumanoidRootPart"))
    local hum = Humanoid or (Character and Character:FindFirstChildOfClass("Humanoid"))
    if not (hrp and hum) then return false end

    if hum.Sit then hum.Sit = false end
    if hum.PlatformStand then hum.PlatformStand = false end

    local diff = Vector3.new(Config.CHAR_POS.X - hrp.Position.X, 0, Config.CHAR_POS.Z - hrp.Position.Z)
    if diff.Magnitude <= 4.0 then return true end

    hum.WalkToPoint = Config.CHAR_POS
    hum:MoveTo(Config.CHAR_POS)

    local t0 = os.clock()
    while State.Enabled and (os.clock() - t0 < 25.0) do
        if not (Character and hrp.Parent and hum.Health > 0) then return false end
        local d = Vector3.new(Config.CHAR_POS.X - hrp.Position.X, 0, Config.CHAR_POS.Z - hrp.Position.Z).Magnitude
        if d <= 3.5 then
            pcall(function()
                hrp.AssemblyLinearVelocity = Vector3.zero
                hum:Move(Vector3.zero, false)
            end)
            return true
        end
        hum:MoveTo(Config.CHAR_POS)
        task.wait(0.1)
    end
    return false
end

-- ======================
-- UI SETUP (Compact 270x160 HUD matching auto-bat.lua)
-- ======================
local function getSafeParent()
    if typeof(gethui) == "function" then
        local a, b = pcall(gethui)
        if a and b then return b end
    end
    local a, b = pcall(function() return game:GetService("CoreGui") end)
    if a and b then return b end
    return LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

local GUI_NAME = "AutoFishingGui"
local parentUi = getSafeParent()
pcall(function()
    if parentUi:FindFirstChild(GUI_NAME) then parentUi[GUI_NAME]:Destroy() end
end)

local UI = {}
UI.Gui = Instance.new("ScreenGui")
UI.Gui.Name = GUI_NAME
UI.Gui.ResetOnSpawn = false
UI.Gui.Parent = parentUi

local W, H = 270, 160
UI.Frame = Instance.new("Frame")
UI.Frame.Size = UDim2.new(0, W, 0, H)
UI.Frame.Position = UDim2.new(1, -W - 20, 0, 80)
UI.Frame.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
UI.Frame.BorderSizePixel = 0
UI.Frame.Active = true
UI.Frame.Draggable = true
UI.Frame.Parent = UI.Gui
Instance.new("UICorner", UI.Frame).CornerRadius = UDim.new(0, 8)

UI.Stroke = Instance.new("UIStroke")
UI.Stroke.Color = Color3.fromRGB(60, 140, 220)
UI.Stroke.Thickness = 1.5
UI.Stroke.Parent = UI.Frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -50, 0, 26)
title.Position = UDim2.new(0, 10, 0, 4)
title.BackgroundTransparency = 1
title.Text = "🎣 Auto Fishing v2"
title.TextColor3 = Color3.fromRGB(120, 210, 255)
title.TextSize = 13
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = UI.Frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 24, 0, 22)
closeBtn.Position = UDim2.new(1, -30, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(150, 45, 45)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.TextSize = 11
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = UI.Frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

UI.StatusLbl = Instance.new("TextLabel")
UI.StatusLbl.Size = UDim2.new(1, -20, 0, 20)
UI.StatusLbl.Position = UDim2.new(0, 10, 0, 34)
UI.StatusLbl.BackgroundTransparency = 1
UI.StatusLbl.Text = "Ready – press START"
UI.StatusLbl.TextColor3 = Color3.fromRGB(200, 200, 160)
UI.StatusLbl.TextSize = 10.5
UI.StatusLbl.Font = Enum.Font.Gotham
UI.StatusLbl.TextXAlignment = Enum.TextXAlignment.Left
UI.StatusLbl.Parent = UI.Frame

UI.CountLbl = Instance.new("TextLabel")
UI.CountLbl.Size = UDim2.new(1, -20, 0, 20)
UI.CountLbl.Position = UDim2.new(0, 10, 0, 56)
UI.CountLbl.BackgroundTransparency = 1
UI.CountLbl.Text = "Catches: 0"
UI.CountLbl.TextColor3 = Color3.fromRGB(140, 220, 160)
UI.CountLbl.TextSize = 11
UI.CountLbl.Font = Enum.Font.GothamBold
UI.CountLbl.TextXAlignment = Enum.TextXAlignment.Left
UI.CountLbl.Parent = UI.Frame

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(0, 118, 0, 36)
startBtn.Position = UDim2.new(0, 10, 1, -46)
startBtn.BackgroundColor3 = Color3.fromRGB(35, 130, 70)
startBtn.Text = "▶ START"
startBtn.TextColor3 = Color3.new(1, 1, 1)
startBtn.TextSize = 12
startBtn.Font = Enum.Font.GothamBold
startBtn.Parent = UI.Frame
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 6)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0, 118, 0, 36)
stopBtn.Position = UDim2.new(1, -128, 1, -46)
stopBtn.BackgroundColor3 = Color3.fromRGB(130, 50, 50)
stopBtn.Text = "⏹ STOP"
stopBtn.TextColor3 = Color3.new(1, 1, 1)
stopBtn.TextSize = 12
stopBtn.Font = Enum.Font.GothamBold
stopBtn.Parent = UI.Frame
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 6)

local function setStatus(msg, col)
    UI.StatusLbl.Text = msg
    UI.StatusLbl.TextColor3 = col or Color3.fromRGB(200, 200, 160)
end

-- ======================
-- FISHING CYCLE
-- ======================
local function startFishing()
    if State.Running then return end
    State.Running = true

    task.spawn(function()
        while State.Enabled do
            -- 1. Ensure at fishing spot
            local hrp = RootPart or (Character and Character:FindFirstChild("HumanoidRootPart"))
            if hrp and Vector3.new(Config.CHAR_POS.X - hrp.Position.X, 0, Config.CHAR_POS.Z - hrp.Position.Z).Magnitude > 8.0 then
                setStatus("Walking to fishing spot...", Color3.fromRGB(255, 200, 100))
                walkToSpot()
                if not State.Enabled then break end
                pcall(function()
                    local r = RootPart or (Character and Character:FindFirstChild("HumanoidRootPart"))
                    if r then r.CFrame = CFrame.lookAt(r.Position, Vector3.new(Config.CAST_POS.X, r.Position.Y, Config.CAST_POS.Z)) end
                end)
            end

            -- 2. Ensure rod equipped
            if not ensureRodEquipped() then
                setStatus("No Fishing Rod found in hand/backpack!", Color3.fromRGB(255, 120, 80))
                task.wait(2.0)
                continue
            end

            -- 3. Hold charge
            setStatus("Charging cast...", Color3.fromRGB(160, 200, 255))
            pcall(function() Remotes.Hold:FireServer() end)
            task.wait(Config.HOLD_DELAY)
            if not State.Enabled then break end

            -- 4. Cast with randomized proven power
            local power = math.floor((Config.CAST_POWER_MIN + math.random() * (Config.CAST_POWER_MAX - Config.CAST_POWER_MIN)) * 1000) / 1000
            setStatus(string.format("Casting (power %.2f)...", power), Color3.fromRGB(160, 200, 255))

            local castOk, castData = pcall(function()
                return Remotes.Cast:InvokeServer(power, Config.CAST_POS)
            end)

            if not castOk or typeof(castData) ~= "table" or not castData.Id then
                setStatus("Cast failed, retrying in 2s...", Color3.fromRGB(255, 160, 60))
                task.wait(2.0)
                continue
            end

            local fishId = castData.Id
            local waitTime = (tonumber(castData.Wait) or 3.0) + Config.EXTRA_WAIT
            setStatus(string.format("Waiting for bite (%.1fs)...", waitTime), Color3.fromRGB(180, 210, 255))
            task.wait(waitTime)
            if not State.Enabled then break end

            -- 5. Reel with retries
            local success, caughtItem = false, nil
            for attempt = 1, Config.MAX_REEL_RETRIES + 1 do
                setStatus(attempt == 1 and "Reeling in..." or string.format("Reeling (retry %d)...", attempt - 1), Color3.fromRGB(100, 220, 140))
                local ok, ret1, ret2 = pcall(function()
                    return Remotes.Reel:InvokeServer(fishId, "Caught", Config.CLICKS)
                end)
                if ok and ret1 == true then
                    success = true
                    caughtItem = ret2
                    break
                end
                if attempt <= Config.MAX_REEL_RETRIES then
                    task.wait(0.25)
                end
            end

            -- 6. Result & feedback
            if success then
                State.CatchCount = State.CatchCount + 1
                UI.CountLbl.Text = "Catches: " .. State.CatchCount
                local itemName = (typeof(caughtItem) == "table" and (caughtItem.DisplayName or caughtItem.Id or caughtItem.Name)) or "Catch!"
                local rarity = (typeof(caughtItem) == "table" and caughtItem.Rarity) or ""
                local rPrefix = (rarity ~= "" and rarity ~= "Unknown") and ("[" .. rarity .. "] ") or ""
                setStatus(string.format("Caught #%d: %s%s", State.CatchCount, rPrefix, itemName), Color3.fromRGB(100, 255, 140))
            else
                setStatus("Reel failed, resetting...", Color3.fromRGB(255, 100, 80))
            end

            task.wait(Config.CYCLE_PAUSE)
        end

        State.Running = false
        setStatus("Stopped", Color3.fromRGB(200, 180, 100))
    end)
end

-- ======================
-- BUTTON WIRING & CLEANUP
-- ======================
addConnection(startBtn.MouseButton1Click:Connect(function()
    State.Enabled = true
    UI.Stroke.Color = Color3.fromRGB(60, 200, 100)
    setStatus("Starting...", Color3.fromRGB(120, 220, 140))
    startFishing()
end))

addConnection(stopBtn.MouseButton1Click:Connect(function()
    State.Enabled = false
    UI.Stroke.Color = Color3.fromRGB(60, 140, 220)
    setStatus("Stopping...", Color3.fromRGB(200, 180, 100))
end))

local function cleanup()
    State.Enabled = false
    disconnectAll()
    if UI.Gui and UI.Gui.Parent then pcall(function() UI.Gui:Destroy() end) end
    _G.SimpleAutoFish_Cleanup = nil
end

_G.SimpleAutoFish_Cleanup = cleanup
addConnection(closeBtn.MouseButton1Click:Connect(cleanup))

end)

if not ok then
    warn("[AutoFishing] " .. tostring(err))
end
