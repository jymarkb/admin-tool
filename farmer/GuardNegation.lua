--[[
    GUARD NEGATION & INVISIBILITY CONTROLLER
    =========================================
    Dedicated protection engine against Guard Patrol mechanics (Forest & all biomes):
      1. 🛡️ Outgoing Remote Strike Negation:
         - Hooks __namecall to intercept and drop client-reported RE/GuardPatrol/ForestStrike
           and RE/GuardPatrol/ForestHandoff (prevents server egg confiscation and strike ragdoll).
      2. 👻 Hitbox & Spatial Invisibility:
         - Enforces CanTouch = false (disables .Touched events on guard colliders).
         - Enforces CanQuery = false (makes character invisible to guard raycasts and spatial queries).
         - Enforces non-root CanCollide = false (prevents collision bump displacement).
      3. 👁️ Visual Invisibility (Stealth Mode):
         - Toggles transparency and shadow on character parts, decals, and accessories.
      4. ⚡ Master Toggle & Telemetry:
         - Tracks live negated strike and handoff counters.
         - Clean lifecycle binding on CharacterAdded/Removing and zero memory leaks.
]]

local ok, err = pcall(function()

if _G.GuardNegation_Cleanup then pcall(_G.GuardNegation_Cleanup) end
_G.GuardNegation_Cleanup = nil

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local CoreGui           = game:GetService("CoreGui")
local RunService        = game:GetService("RunService")
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

-- ============================================================================
-- CONNECTION MANAGEMENT
-- ============================================================================
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

-- ============================================================================
-- MODULE TABLES (Anti-Bloat Root Local Budget <= 30)
-- ============================================================================
local Config  = {}
local State   = {}
local UI      = {}
local Engine  = {}

Config.Theme = {
    Background = Color3.fromRGB(16, 18, 26),
    Header     = Color3.fromRGB(24, 28, 40),
    Border     = Color3.fromRGB(55, 65, 95),
    GreenOn    = Color3.fromRGB(42, 160, 80),
    RedOff     = Color3.fromRGB(180, 50, 50),
    BlueActive = Color3.fromRGB(50, 120, 220),
    TextLight  = Color3.fromRGB(230, 235, 250),
    TextDim    = Color3.fromRGB(150, 160, 185),
    YellowWarn = Color3.fromRGB(255, 200, 70),
}

State.RemoteNegationActive  = true   -- Intercepts ForestStrike & ForestHandoff
State.HitboxInvisActive     = true   -- CanTouch = false & CanQuery = false
State.VisualInvisActive     = false  -- Transparency = 1
State.HooksInstalled        = false
State.NegatedStrikesCount   = 0
State.NegatedHandoffsCount  = 0
State.OriginalTransparency  = {}

-- ============================================================================
-- ENGINE: GUARD REMOTE NEGATION (__namecall hook)
-- ============================================================================
Engine.installHooks = function()
    if typeof(hookmetamethod) ~= "function" or State.HooksInstalled then return end
    State.HooksInstalled = true

    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if State.RemoteNegationActive and method == "FireServer" and typeof(self) == "Instance" and self:IsA("RemoteEvent") then
            local rName = self.Name
            if rName == "ForestStrike" then
                State.NegatedStrikesCount = State.NegatedStrikesCount + 1
                if UI.updateCounters then pcall(UI.updateCounters) end
                return -- Drop outgoing strike report
            elseif rName == "ForestHandoff" then
                State.NegatedHandoffsCount = State.NegatedHandoffsCount + 1
                if UI.updateCounters then pcall(UI.updateCounters) end
                return -- Drop outgoing egg confiscation handoff
            end
        end
        return oldNamecall(self, ...)
    end))
end

-- ============================================================================
-- ENGINE: HITBOX & SPATIAL INVISIBILITY (CanTouch & CanQuery)
-- ============================================================================
Engine.applyHitboxInvisibility = function(char)
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            if State.HitboxInvisActive then
                pcall(function()
                    part.CanTouch = false
                    part.CanQuery = false
                    if part.Name ~= "HumanoidRootPart" then
                        part.CanCollide = false
                    end
                end)
            else
                pcall(function()
                    part.CanTouch = true
                    part.CanQuery = true
                    if part.Name ~= "HumanoidRootPart" then
                        part.CanCollide = true
                    end
                end)
            end
        end
    end
end

-- ============================================================================
-- ENGINE: VISUAL INVISIBILITY (Transparency & Decals)
-- ============================================================================
Engine.applyVisualInvisibility = function(char)
    if not char then return end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
            if State.VisualInvisActive then
                if State.OriginalTransparency[d] == nil then
                    State.OriginalTransparency[d] = d.Transparency
                end
                pcall(function()
                    d.Transparency = 1
                    d.CastShadow = false
                end)
            else
                local orig = State.OriginalTransparency[d] or 0
                pcall(function()
                    d.Transparency = orig
                    d.CastShadow = true
                end)
            end
        elseif d:IsA("Decal") then
            if State.VisualInvisActive then
                if State.OriginalTransparency[d] == nil then
                    State.OriginalTransparency[d] = d.Transparency
                end
                pcall(function() d.Transparency = 1 end)
            else
                local orig = State.OriginalTransparency[d] or 0
                pcall(function() d.Transparency = orig end)
            end
        end
    end
end

Engine.applyAll = function(char)
    local targetChar = char or Character
    if not targetChar then return end
    Engine.applyHitboxInvisibility(targetChar)
    Engine.applyVisualInvisibility(targetChar)
end

-- ============================================================================
-- LIFECYCLE & INCOMING GUARD WARNINGS
-- ============================================================================
if LocalPlayer then
    addConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
        Character = newChar
        Humanoid  = newChar:WaitForChild("Humanoid", 5) or newChar:FindFirstChildOfClass("Humanoid")
        RootPart  = newChar:WaitForChild("HumanoidRootPart", 5) or newChar:FindFirstChild("HumanoidRootPart")
        table.clear(State.OriginalTransparency)
        task.wait(0.2)
        Engine.applyAll(newChar)
    end))
    addConnection(LocalPlayer.CharacterRemoving:Connect(function()
        Character = nil
        Humanoid  = nil
        RootPart  = nil
        table.clear(State.OriginalTransparency)
    end))
end

-- Monitor incoming GuardPatrol events for HUD alerts
pcall(function()
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")
    if net then
        local toll = net:FindFirstChild("RE/GuardPatrol/SpeedTollOffer")
        if toll and toll:IsA("RemoteEvent") then
            addConnection(toll.OnClientEvent:Connect(function(...)
                if UI.Elements and UI.Elements.AlertLabel then
                    UI.Elements.AlertLabel.Text = "⚠️ Guard Proximity Alert: SpeedTollOffer"
                    UI.Elements.AlertLabel.TextColor3 = Config.Theme.YellowWarn
                    task.delay(2.5, function()
                        if UI.Elements and UI.Elements.AlertLabel then
                            UI.Elements.AlertLabel.Text = "Status: Monitoring Guard Patrol"
                            UI.Elements.AlertLabel.TextColor3 = Config.Theme.TextDim
                        end
                    end)
                end
            end))
        end
        local warn = net:FindFirstChild("RE/GuardPatrol/SpeedTollWarning")
        if warn and warn:IsA("RemoteEvent") then
            addConnection(warn.OnClientEvent:Connect(function(...)
                if UI.Elements and UI.Elements.AlertLabel then
                    UI.Elements.AlertLabel.Text = "⚠️ Guard Proximity Alert: SpeedTollWarning"
                    UI.Elements.AlertLabel.TextColor3 = Config.Theme.YellowWarn
                end
            end))
        end
    end
end)

-- ============================================================================
-- USER INTERFACE
-- ============================================================================
UI.Elements = {}

UI.updateCounters = function()
    if UI.Elements.CounterLabel and UI.Elements.CounterLabel.Parent then
        UI.Elements.CounterLabel.Text = string.format("Strikes Negated: %d  |  Handoffs Negated: %d", State.NegatedStrikesCount, State.NegatedHandoffsCount)
    end
end

UI.syncButtons = function()
    local e = UI.Elements
    if not e.BtnRemote then return end
    e.BtnRemote.Text = State.RemoteNegationActive and "🛡️ Remote Strike Negation: ON" or "🛡️ Remote Strike Negation: OFF"
    e.BtnRemote.BackgroundColor3 = State.RemoteNegationActive and Config.Theme.GreenOn or Config.Theme.RedOff

    e.BtnHitbox.Text = State.HitboxInvisActive and "👻 Hitbox Invisibility: ON" or "👻 Hitbox Invisibility: OFF"
    e.BtnHitbox.BackgroundColor3 = State.HitboxInvisActive and Config.Theme.GreenOn or Config.Theme.RedOff

    e.BtnVisual.Text = State.VisualInvisActive and "👁️ Visual Invisibility: ON" or "👁️ Visual Invisibility: OFF"
    e.BtnVisual.BackgroundColor3 = State.VisualInvisActive and Config.Theme.GreenOn or Config.Theme.RedOff
end

UI.init = function()
    local guiName = "GuardNegationControllerUI"
    pcall(function()
        if CoreGui:FindFirstChild(guiName) then CoreGui[guiName]:Destroy() end
        local pg = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if pg and pg:FindFirstChild(guiName) then pg[guiName]:Destroy() end
    end)

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = guiName
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 99999
    local parentOk = pcall(function() screenGui.Parent = CoreGui end)
    if not parentOk or not screenGui.Parent then
        screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end

    local W, H = 310, 260
    local main = Instance.new("Frame")
    main.Name = "MainFrame"
    main.Size = UDim2.new(0, W, 0, H)
    main.Position = UDim2.new(0.5, -W/2, 0.35, -H/2)
    main.BackgroundColor3 = Config.Theme.Background
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.Parent = screenGui

    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
    local mainStroke = Instance.new("UIStroke", main)
    mainStroke.Color = Config.Theme.Border
    mainStroke.Thickness = 1.5

    -- Header
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 32)
    header.BackgroundColor3 = Config.Theme.Header
    header.BorderSizePixel = 0
    header.Parent = main
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 8)

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -36, 1, 0)
    titleLbl.Position = UDim2.new(0, 10, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "🛡️ GUARD NEGATION & INVISIBILITY"
    titleLbl.TextColor3 = Config.Theme.TextLight
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 11.5
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = header

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 22, 0, 22)
    closeBtn.Position = UDim2.new(1, -28, 0, 5)
    closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 60)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 11
    closeBtn.Parent = header
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

    -- Button Helper
    local function createButton(yOffset, h, text, defaultColor)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, -20, 0, h)
        btn.Position = UDim2.new(0, 10, 0, yOffset)
        btn.BackgroundColor3 = defaultColor
        btn.Text = text
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.Parent = main
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
        return btn
    end

    local btnRemote   = createButton(40, 32, "🛡️ Remote Strike Negation: ON", Config.Theme.GreenOn)
    local btnHitbox   = createButton(78, 32, "👻 Hitbox Invisibility: ON", Config.Theme.GreenOn)
    local btnVisual   = createButton(116, 32, "👁️ Visual Invisibility: OFF", Config.Theme.RedOff)
    local btnMaster   = createButton(154, 32, "⚡ MASTER: FULL IMMUNITY", Config.Theme.BlueActive)

    -- Counters and Status
    local counterLbl = Instance.new("TextLabel")
    counterLbl.Size = UDim2.new(1, -20, 0, 24)
    counterLbl.Position = UDim2.new(0, 10, 0, 192)
    counterLbl.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
    counterLbl.Text = "Strikes Negated: 0  |  Handoffs Negated: 0"
    counterLbl.TextColor3 = Color3.fromRGB(120, 230, 150)
    counterLbl.Font = Enum.Font.GothamBold
    counterLbl.TextSize = 10
    counterLbl.Parent = main
    Instance.new("UICorner", counterLbl).CornerRadius = UDim.new(0, 5)

    local alertLbl = Instance.new("TextLabel")
    alertLbl.Size = UDim2.new(1, -20, 0, 24)
    alertLbl.Position = UDim2.new(0, 10, 0, 222)
    alertLbl.BackgroundTransparency = 1
    alertLbl.Text = "Status: Monitoring Guard Patrol"
    alertLbl.TextColor3 = Config.Theme.TextDim
    alertLbl.Font = Enum.Font.Gotham
    alertLbl.TextSize = 9.5
    alertLbl.Parent = main

    UI.Elements = {
        ScreenGui    = screenGui,
        MainFrame    = main,
        BtnRemote    = btnRemote,
        BtnHitbox    = btnHitbox,
        BtnVisual    = btnVisual,
        BtnMaster    = btnMaster,
        CounterLabel = counterLbl,
        AlertLabel   = alertLbl,
        CloseBtn     = closeBtn,
    }

    -- Button Listeners
    addConnection(btnRemote.MouseButton1Click:Connect(function()
        State.RemoteNegationActive = not State.RemoteNegationActive
        UI.syncButtons()
    end))

    addConnection(btnHitbox.MouseButton1Click:Connect(function()
        State.HitboxInvisActive = not State.HitboxInvisActive
        Engine.applyHitboxInvisibility(Character)
        UI.syncButtons()
    end))

    addConnection(btnVisual.MouseButton1Click:Connect(function()
        State.VisualInvisActive = not State.VisualInvisActive
        Engine.applyVisualInvisibility(Character)
        UI.syncButtons()
    end))

    addConnection(btnMaster.MouseButton1Click:Connect(function()
        local target = not (State.RemoteNegationActive and State.HitboxInvisActive and State.VisualInvisActive)
        State.RemoteNegationActive = target
        State.HitboxInvisActive    = target
        State.VisualInvisActive    = target
        Engine.applyAll(Character)
        UI.syncButtons()
    end))

    addConnection(closeBtn.MouseButton1Click:Connect(function()
        Engine.cleanup()
    end))
end

-- Full Cleanup
Engine.cleanup = function()
    State.RemoteNegationActive = false
    State.HitboxInvisActive    = false
    State.VisualInvisActive    = false
    Engine.applyAll(Character)
    disconnectAll()
    if UI.Elements and UI.Elements.ScreenGui and UI.Elements.ScreenGui.Parent then
        pcall(function() UI.Elements.ScreenGui:Destroy() end)
    end
    if _G.GuardNegation_Cleanup == Engine.cleanup then
        _G.GuardNegation_Cleanup = nil
    end
    print("[GuardNegation] Cleaned up and unmounted successfully.")
end

_G.GuardNegation_Cleanup = Engine.cleanup

-- Initialization
Engine.installHooks()
Engine.applyAll(Character)
UI.init()
UI.syncButtons()

print("[GuardNegation] Initialized successfully. Forest strikes & handoffs protected.")

end) -- end pcall

if not ok then
    warn("[GuardNegation] Failed to load: " .. tostring(err))
end
