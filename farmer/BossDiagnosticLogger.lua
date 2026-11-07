--[[
    ========================================================================
    ⚡ BOSS & GUARD DIAGNOSTIC TELEMETRY LOGGER (Zero-Hook, Zero-Kick)
    ========================================================================
    A 100% passive diagnostic monitor to capture and record exactly what happens
    during Boss encounters, Guard Patrols, and Strikes across ALL biomes.

    Features:
      1. 🛡️ Passive Remote Event Sniffing (ZERO Metamethod Hooks, ZERO Disconnects):
         - GuardPatrol: ForestStrike, ForestHandoff, SpeedTollOffer, SpeedTollWarning, Rouse, EnabledShifted
         - BossEvent: HazardHit, BlackHoleHit, BossDamaged, HealthShifted, StateShifted, Vfx
         - PumpkinBoss: HazardHit, Hazard, CannonFire, Transition, Drops
         - ScrambleBoss: HazardHit, Hazard, Transition, Fx
         - GhostBoss: Suction, Defeated
         - RigSync: RE/RigSync/Refresh (Action, Arguments, Sequence)
         - EggWorld: FieldEggCarry, OwnerDropped, FieldEggShifted
      2. 📍 Physical Telemetry & Proximity Radar:
         - Tracks player (X, Y, Z), altitude Y, linear velocity, fling spikes.
         - Scans closest Guard & Boss models across all biomes with real-time distance.
         - Ragdoll timer & PlatformStand / Sit tracking.
      3. 📋 Export Options:
         - Live scrolling console on HUD.
         - "COPY LOG" button (copies full session history to clipboard).
         - "SAVE FILE" button (saves directly to boss-diagnostic.log via writefile).
      4. 🔒 Zero Character Tampering:
         - Does not alter CanTouch, CanCollide, or CanQuery on player (no physics kicks).
         - Root local budget strictly <= 30.
    ========================================================================
]]

local ok, err = pcall(function()

if _G.BossDiagnosticLogger_Cleanup then pcall(_G.BossDiagnosticLogger_Cleanup) end
_G.BossDiagnosticLogger_Cleanup = nil

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
    Background = Color3.fromRGB(15, 17, 24),
    Header     = Color3.fromRGB(24, 28, 40),
    Border     = Color3.fromRGB(50, 75, 115),
    ConsoleBg  = Color3.fromRGB(10, 11, 16),
    TextLight  = Color3.fromRGB(230, 235, 250),
    TextDim    = Color3.fromRGB(140, 150, 175),
    GreenLog   = Color3.fromRGB(100, 230, 130),
    RedAlert   = Color3.fromRGB(255, 95, 95),
    YellowWarn = Color3.fromRGB(255, 205, 75),
    BlueInfo   = Color3.fromRGB(90, 175, 255),
    PurpleBoss = Color3.fromRGB(200, 130, 255),
}

Config.MonitoredRemotes = {
    -- Guard Patrol
    { Path = "RE/GuardPatrol/ForestStrike",       Label = "GUARD: ForestStrike",       Color = Config.Theme.RedAlert },
    { Path = "RE/GuardPatrol/ForestHandoff",      Label = "GUARD: ForestHandoff",      Color = Config.Theme.RedAlert },
    { Path = "RE/GuardPatrol/SpeedTollOffer",     Label = "GUARD: SpeedTollOffer",     Color = Config.Theme.YellowWarn },
    { Path = "RE/GuardPatrol/SpeedTollWarning",   Label = "GUARD: SpeedTollWarning",   Color = Config.Theme.YellowWarn },
    { Path = "RE/GuardPatrol/Rouse",              Label = "GUARD: Rouse",              Color = Config.Theme.YellowWarn },
    { Path = "RE/GuardPatrol/EnabledShifted",     Label = "GUARD: EnabledShifted",     Color = Config.Theme.BlueInfo },
    { Path = "RE/GuardOnboarding/LiveStateShifted", Label = "GUARD: LiveStateShifted", Color = Config.Theme.BlueInfo },

    -- Boss Events & Hazards (All Biomes)
    { Path = "RE/BossEvent/HazardHit",            Label = "BOSS: HazardHit",           Color = Config.Theme.RedAlert },
    { Path = "RE/BossEvent/BlackHoleHit",         Label = "BOSS: BlackHoleHit",        Color = Config.Theme.RedAlert },
    { Path = "RE/BossEvent/BossDamaged",          Label = "BOSS: BossDamaged",         Color = Config.Theme.PurpleBoss },
    { Path = "RE/BossEvent/HealthShifted",        Label = "BOSS: HealthShifted",       Color = Config.Theme.PurpleBoss },
    { Path = "RE/BossEvent/StateShifted",         Label = "BOSS: StateShifted",        Color = Config.Theme.PurpleBoss },
    { Path = "RE/BossEvent/Vfx",                  Label = "BOSS: Vfx",                 Color = Config.Theme.BlueInfo },

    -- Biome Specific Bosses
    { Path = "RE/PumpkinBoss/HazardHit",          Label = "PUMPKIN: HazardHit",        Color = Config.Theme.RedAlert },
    { Path = "RE/PumpkinBoss/Hazard",             Label = "PUMPKIN: Hazard",           Color = Config.Theme.YellowWarn },
    { Path = "RE/PumpkinBoss/CannonFire",         Label = "PUMPKIN: CannonFire",       Color = Config.Theme.YellowWarn },
    { Path = "RE/PumpkinBoss/Transition",         Label = "PUMPKIN: Transition",       Color = Config.Theme.PurpleBoss },
    { Path = "RE/ScrambleBoss/HazardHit",         Label = "SCRAMBLE: HazardHit",       Color = Config.Theme.RedAlert },
    { Path = "RE/ScrambleBoss/Hazard",            Label = "SCRAMBLE: Hazard",          Color = Config.Theme.YellowWarn },
    { Path = "RE/ScrambleBoss/Transition",        Label = "SCRAMBLE: Transition",      Color = Config.Theme.PurpleBoss },
    { Path = "RE/GhostBoss/Suction",              Label = "GHOST: Suction",            Color = Config.Theme.YellowWarn },
    { Path = "RE/GhostBoss/Defeated",             Label = "GHOST: Defeated",           Color = Config.Theme.GreenLog },

    -- Rig Sync / Ragdoll / Speeds
    { Path = "RE/RigSync/Refresh",                Label = "RIGSYNC: Refresh",          Color = Config.Theme.BlueInfo },

    -- Egg Actions
    { Path = "RE/EggWorld/FieldEggCarry",         Label = "EGG: FieldEggCarry",        Color = Config.Theme.YellowWarn },
    { Path = "RE/EggWorld/OwnerDropped",          Label = "EGG: OwnerDropped",         Color = Config.Theme.RedAlert },
    { Path = "RE/EggWorld/FieldEggShifted",       Label = "EGG: FieldEggShifted",      Color = Config.Theme.BlueInfo },
}

State.LogEntries = {}
State.MaxLogEntries = 500
State.NearestGuardName = "None"
State.NearestGuardDist = 9999
State.NearestBossName = "None"
State.NearestBossDist = 9999
State.CurrentBiome = "Unknown"
State.CarriedEggName = "None"

-- Format value helper for parameters
local function formatArg(val, depth)
    depth = depth or 0
    if depth > 2 then return "..." end
    local t = typeof(val)
    if t == "string" then
        if #val > 80 then return string.format("%q...", val:sub(1, 80)) end
        return string.format("%q", val)
    elseif t == "number" then
        return string.format("%.3f", val)
    elseif t == "Vector3" then
        return string.format("V3(%.1f, %.1f, %.1f)", val.X, val.Y, val.Z)
    elseif t == "CFrame" then
        local p = val.Position
        return string.format("CF(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z)
    elseif t == "table" then
        local parts = {}
        local count = 0
        for k, v in pairs(val) do
            count = count + 1
            if count <= 4 then
                table.insert(parts, tostring(k) .. "=" .. formatArg(v, depth + 1))
            end
        end
        if count > 4 then table.insert(parts, string.format("...+%d more", count - 4)) end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "Instance" then
        return "<" .. val.ClassName .. ":" .. val.Name .. ">"
    end
    return tostring(val)
end

Engine.log = function(msg, color)
    local timestamp = os.date("%H:%M:%S")
    local line = string.format("[%s] %s", timestamp, msg)
    table.insert(State.LogEntries, { Text = line, Color = color or Config.Theme.TextLight })
    if #State.LogEntries > State.MaxLogEntries then
        table.remove(State.LogEntries, 1)
    end
    print("[BossDiag] " .. line)
    if UI.appendLogLine then
        pcall(UI.appendLogLine, line, color or Config.Theme.TextLight)
    end
end

-- ============================================================================
-- PROXIMITY RADAR: GUARDS, BOSSES, AND TELEMETRY
-- ============================================================================
Engine.updateProximity = function()
    if not (RootPart and RootPart.Parent) then return end
    local pPos = RootPart.Position

    -- 1. Scan Biome Guards
    local bestGName, bestGDist = "None", 9999
    pcall(function()
        local guardAreas = Workspace:FindFirstChild("World")
            and Workspace.World:FindFirstChild("Areas")
            and Workspace.World.Areas:FindFirstChild("GuardAreas")
        if guardAreas then
            for _, area in ipairs(guardAreas:GetChildren()) do
                for _, model in ipairs(area:GetChildren()) do
                    if model:IsA("Model") and (model.Name:lower():find("guard") or model.Name:find("Guard")) then
                        local pv = model:GetPivot().Position
                        local d = (pv - pPos).Magnitude
                        if d < bestGDist then
                            bestGDist = math.floor(d * 10) / 10
                            bestGName = string.format("%s/%s", area.Name, model.Name)
                        end
                    end
                end
            end
        end
        local guards = Workspace:FindFirstChild("_Guards")
        if guards then
            for _, g in ipairs(guards:GetChildren()) do
                if g:IsA("Model") then
                    local pv = g:GetPivot().Position
                    local d = (pv - pPos).Magnitude
                    if d < bestGDist then
                        bestGDist = math.floor(d * 10) / 10
                        bestGName = g.Name
                    end
                end
            end
        end
    end)
    State.NearestGuardName = bestGName
    State.NearestGuardDist = bestGDist

    -- 2. Scan Bosses & Monsters
    local bestBName, bestBDist = "None", 9999
    pcall(function()
        local function checkContainer(cont)
            if not cont then return end
            for _, m in ipairs(cont:GetChildren()) do
                if m:IsA("Model") then
                    local nm = m.Name:lower()
                    if nm:find("boss") or nm:find("scramble") or nm:find("pumpkin") or nm:find("monster") then
                        local pv = m:GetPivot().Position
                        local d = (pv - pPos).Magnitude
                        if d < bestBDist then
                            bestBDist = math.floor(d * 10) / 10
                            bestBName = m.Name
                        end
                    end
                end
            end
        end
        checkContainer(Workspace)
        checkContainer(Workspace:FindFirstChild("Transient"))
        checkContainer(Workspace:FindFirstChild("HalloweenDimension") and Workspace.HalloweenDimension:FindFirstChild("Monsters"))
    end)
    State.NearestBossName = bestBName
    State.NearestBossDist = bestBDist

    -- 3. Detect Carried Egg
    local carried = "None"
    if Character then
        for _, c in ipairs(Character:GetChildren()) do
            if c:IsA("Tool") and (c.Name:lower():find("egg") or c:GetAttribute("IsEgg")) then
                carried = c.Name
                break
            end
        end
    end
    State.CarriedEggName = carried
end

-- ============================================================================
-- PASSIVE REMOTE EVENT HOOKS (ZERO HOOKMETAMETHOD, 100% RELIABLE)
-- ============================================================================
Engine.hookRemotes = function()
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")
    if not net then
        Engine.log("⚠️ Packages.Networking not found yet. Retrying in 1s...", Config.Theme.YellowWarn)
        task.delay(1.0, Engine.hookRemotes)
        return
    end

    local hookedCount = 0
    for _, item in ipairs(Config.MonitoredRemotes) do
        local rem = net:FindFirstChild(item.Path)
        if rem and rem:IsA("RemoteEvent") then
            hookedCount = hookedCount + 1
            addConnection(rem.OnClientEvent:Connect(function(...)
                local args = table.pack(...)
                local argStrs = {}
                for i = 1, math.min(args.n, 3) do
                    table.insert(argStrs, formatArg(args[i]))
                end

                local pPos = RootPart and RootPart.Position or Vector3.zero
                local vMag = RootPart and RootPart.AssemblyLinearVelocity.Magnitude or 0
                local statusMsg = string.format("%s | Player:(%.0f, %.0f, %.0f) V:%.1f | Args: %s",
                    item.Label, pPos.X, pPos.Y, pPos.Z, vMag, table.concat(argStrs, ", "))

                Engine.log(statusMsg, item.Color)

                -- If this is a hit event, log an immediate snapshot of surrounding danger
                if item.Label:find("Hit") or item.Label:find("Strike") or item.Label:find("Handoff") then
                    Engine.updateProximity()
                    local dangerMsg = string.format("💥 IMPACT CONTEXT: Guard=%s (%.1fst), Boss=%s (%.1fst), Egg=%s",
                        State.NearestGuardName, State.NearestGuardDist, State.NearestBossName, State.NearestBossDist, State.CarriedEggName)
                    Engine.log(dangerMsg, Config.Theme.RedAlert)
                end
            end))
        end
    end
    Engine.log(string.format("✓ Sniffing %d active Boss & Guard RemoteEvents.", hookedCount), Config.Theme.GreenLog)
end

-- ============================================================================
-- CHARACTER TELEMETRY & ATTRIBUTE HOOKS
-- ============================================================================
Engine.bindCharacter = function(newChar)
    Character = newChar
    Humanoid  = newChar:WaitForChild("Humanoid", 5) or newChar:FindFirstChildOfClass("Humanoid")
    RootPart  = newChar:WaitForChild("HumanoidRootPart", 5) or newChar:FindFirstChild("HumanoidRootPart")

    if Humanoid then
        addConnection(Humanoid.StateChanged:Connect(function(oldState, newState)
            if newState == Enum.HumanoidStateType.Ragdoll or newState == Enum.HumanoidStateType.Physics then
                local p = RootPart and RootPart.Position or Vector3.zero
                Engine.log(string.format("⚠️ RAGDOLL DETECTED: State=%s at (%.0f, %.0f, %.0f)", tostring(newState.Name), p.X, p.Y, p.Z), Config.Theme.RedAlert)
            end
        end))

        addConnection(Humanoid:GetPropertyChangedSignal("PlatformStand"):Connect(function()
            if Humanoid.PlatformStand then
                Engine.log("⚠️ PlatformStand=true (Character knocked down)", Config.Theme.RedAlert)
            end
        end))
    end

    if RootPart then
        -- Fling detector
        addConnection(RunService.Heartbeat:Connect(function()
            if RootPart and RootPart.Parent then
                local vel = RootPart.AssemblyLinearVelocity
                if vel.Magnitude > 180 then
                    Engine.log(string.format("🚀 FLING DETECTED: LinearVelocity = %.1f studs/s!", vel.Magnitude), Config.Theme.YellowWarn)
                end
            end
        end))
    end
end

if LocalPlayer then
    addConnection(LocalPlayer.CharacterAdded:Connect(Engine.bindCharacter))
    addConnection(LocalPlayer.CharacterRemoving:Connect(function()
        Character, Humanoid, RootPart = nil, nil, nil
    end))
    if LocalPlayer.Character then Engine.bindCharacter(LocalPlayer.Character) end

    -- Monitor player attributes for RagdollEndTime
    addConnection(LocalPlayer.AttributeChanged:Connect(function(attr)
        if attr:lower():find("ragdoll") or attr:lower():find("stun") then
            local val = LocalPlayer:GetAttribute(attr)
            Engine.log(string.format("📋 ATTRIBUTE SHIFT: %s = %s", attr, tostring(val)), Config.Theme.YellowWarn)
        end
    end))
end

-- ============================================================================
-- USER INTERFACE
-- ============================================================================
UI.init = function()
    local GUI_NAME = "BossDiagnosticLoggerUI"
    pcall(function()
        if CoreGui:FindFirstChild(GUI_NAME) then CoreGui[GUI_NAME]:Destroy() end
        local pg = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if pg and pg:FindFirstChild(GUI_NAME) then pg[GUI_NAME]:Destroy() end
    end)

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = GUI_NAME
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 99999
    local parentOk = pcall(function() screenGui.Parent = CoreGui end)
    if not parentOk or not screenGui.Parent then
        screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end

    local W, H = 520, 360
    local main = Instance.new("Frame")
    main.Name = "MainFrame"
    main.Size = UDim2.new(0, W, 0, H)
    main.Position = UDim2.new(0.5, -W/2, 0.40, -H/2)
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
    titleLbl.Text = "📡 BOSS & GUARD DIAGNOSTIC LOGGER"
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

    -- Live Telemetry HUD Bar
    local hud = Instance.new("TextLabel")
    hud.Size = UDim2.new(1, -20, 0, 24)
    hud.Position = UDim2.new(0, 10, 0, 38)
    hud.BackgroundColor3 = Color3.fromRGB(20, 23, 34)
    hud.Text = "Pos: (0, 0, 0) | Guard: None | Boss: None | Egg: None"
    hud.TextColor3 = Config.Theme.TextLight
    hud.Font = Enum.Font.GothamBold
    hud.TextSize = 9.5
    hud.Parent = main
    Instance.new("UICorner", hud).CornerRadius = UDim.new(0, 5)

    -- Console Scroll Box
    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -20, 1, -112)
    scroll.Position = UDim2.new(0, 10, 0, 68)
    scroll.BackgroundColor3 = Config.Theme.ConsoleBg
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 5
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = main
    Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

    local listLayout = Instance.new("UIListLayout")
    listLayout.Padding = UDim.new(0, 2)
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Parent = scroll

    -- Action Buttons Footer
    local function makeButton(x, w, text, color)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, w, 0, 28)
        btn.Position = UDim2.new(0, x, 1, -36)
        btn.BackgroundColor3 = color
        btn.Text = text
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 10.5
        btn.Parent = main
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
        return btn
    end

    local copyBtn  = makeButton(10, 110, "📋 COPY LOG", Color3.fromRGB(45, 120, 210))
    local saveBtn  = makeButton(126, 110, "💾 SAVE FILE", Color3.fromRGB(40, 150, 75))
    local clearBtn = makeButton(242, 90, "🗑️ CLEAR", Color3.fromRGB(90, 95, 115))

    local statusFeedback = Instance.new("TextLabel")
    statusFeedback.Size = UDim2.new(1, -345, 0, 28)
    statusFeedback.Position = UDim2.new(0, 340, 1, -36)
    statusFeedback.BackgroundTransparency = 1
    statusFeedback.Text = "Ready · Sniffing Events"
    statusFeedback.TextColor3 = Config.Theme.TextDim
    statusFeedback.Font = Enum.Font.Gotham
    statusFeedback.TextSize = 9.5
    statusFeedback.TextXAlignment = Enum.TextXAlignment.Right
    statusFeedback.Parent = main

    UI.Elements = {
        ScreenGui      = screenGui,
        Scroll         = scroll,
        ListLayout     = listLayout,
        Hud            = hud,
        StatusFeedback = statusFeedback,
    }

    UI.appendLogLine = function(text, color)
        if not scroll or not scroll.Parent then return end
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -8, 0, 15)
        lbl.BackgroundTransparency = 1
        lbl.Text = text
        lbl.TextColor3 = color
        lbl.Font = Enum.Font.Code
        lbl.TextSize = 9.5
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = scroll

        scroll.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y + 20)
        task.defer(function()
            if scroll and scroll.Parent then
                scroll.CanvasPosition = Vector2.new(0, math.max(0, scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteSize.Y + 15))
            end
        end)
    end

    -- Update HUD loop (2 Hz)
    task.spawn(function()
        while screenGui and screenGui.Parent do
            task.wait(0.5)
            Engine.updateProximity()
            if RootPart and RootPart.Parent and hud and hud.Parent then
                local p = RootPart.Position
                hud.Text = string.format("Pos:(%.0f, %.0f, %.0f) | Guard:%s (%.0fst) | Boss:%s (%.0fst) | Egg:%s",
                    p.X, p.Y, p.Z, State.NearestGuardName, State.NearestGuardDist, State.NearestBossName, State.NearestBossDist, State.CarriedEggName)
            end
        end
    end)

    -- Button Listeners
    addConnection(copyBtn.MouseButton1Click:Connect(function()
        local fullText = {}
        for _, entry in ipairs(State.LogEntries) do
            table.insert(fullText, entry.Text)
        end
        local combined = table.concat(fullText, "\n")
        local okCopy = false
        if typeof(setclipboard) == "function" then
            pcall(setclipboard, combined)
            okCopy = true
        elseif typeof(toclipboard) == "function" then
            pcall(toclipboard, combined)
            okCopy = true
        end
        statusFeedback.Text = okCopy and "✓ Copied to clipboard!" or "⚠️ setclipboard unavailable"
        statusFeedback.TextColor3 = okCopy and Config.Theme.GreenLog or Config.Theme.YellowWarn
        task.delay(2.5, function()
            if statusFeedback and statusFeedback.Parent then
                statusFeedback.Text = "Ready · Sniffing Events"
                statusFeedback.TextColor3 = Config.Theme.TextDim
            end
        end)
    end))

    addConnection(saveBtn.MouseButton1Click:Connect(function()
        local fullText = {}
        for _, entry in ipairs(State.LogEntries) do
            table.insert(fullText, entry.Text)
        end
        local combined = table.concat(fullText, "\n")
        local fileName = "boss-diagnostic.log"
        local okSave = false
        if typeof(writefile) == "function" then
            local okWrite, errWrite = pcall(writefile, fileName, combined)
            okSave = okWrite
        end
        statusFeedback.Text = okSave and ("✓ Saved " .. fileName) or "⚠️ writefile failed/unsupported"
        statusFeedback.TextColor3 = okSave and Config.Theme.GreenLog or Config.Theme.YellowWarn
        task.delay(2.5, function()
            if statusFeedback and statusFeedback.Parent then
                statusFeedback.Text = "Ready · Sniffing Events"
                statusFeedback.TextColor3 = Config.Theme.TextDim
            end
        end)
    end))

    addConnection(clearBtn.MouseButton1Click:Connect(function()
        table.clear(State.LogEntries)
        for _, c in ipairs(scroll:GetChildren()) do
            if c:IsA("TextLabel") then c:Destroy() end
        end
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        statusFeedback.Text = "Logs Cleared"
    end))

    addConnection(closeBtn.MouseButton1Click:Connect(Engine.cleanup))
end

-- Full Cleanup
Engine.cleanup = function()
    disconnectAll()
    if UI.Elements and UI.Elements.ScreenGui and UI.Elements.ScreenGui.Parent then
        pcall(function() UI.Elements.ScreenGui:Destroy() end)
    end
    if _G.BossDiagnosticLogger_Cleanup == Engine.cleanup then
        _G.BossDiagnosticLogger_Cleanup = nil
    end
    print("[BossDiag] Logger unmounted and cleaned up.")
end

_G.BossDiagnosticLogger_Cleanup = Engine.cleanup

-- Startup
UI.init()
Engine.hookRemotes()
Engine.log("=== BOSS & GUARD DIAGNOSTIC LOGGER STARTED ===", Config.Theme.GreenLog)
Engine.log("Passive Sniffer Active: Walk into any biome/boss to record exact events.", Config.Theme.TextDim)

end) -- end pcall

if not ok then
    warn("[BossDiag] Failed to load: " .. tostring(err))
end
