--[=[
    ================================================================================
    SPEED MULTIPLIER TEST (Standalone High-Velocity Escape Engine)
    ================================================================================
    Purpose:
        Standalone test script to apply configurable speed multipliers (2.0x, 3.0x, etc.)
        via direct linear velocity, bypassing server RigSync walkspeed throttling
        and outrunning Biome Guards before their 1.0s wake delay expires.
        
    Design & Safety Contract:
        1. 100% Standalone: Runs completely independently (v12 not required).
        2. Zero Metamethod Hooks: No __namecall or __index hooks (zero kicks).
        3. Zero Collision Tampering: No CanTouch modification.
        4. AssemblyLinearVelocity Drive: Directly drives X/Z horizontal velocity
           along Humanoid.MoveDirection while preserving vertical gravity/jumping.
        5. Live RigSync & Carry Synchronization: Tracks base speed from RigSync
           and carry states from RE/EggWorld/FieldEggCarry.
        6. Clean Connection Lifecycle: Tracks all connections with _G cleanup.
        7. Strict Anti-Bloat: Root locals <= 20.
        8. Multiplier Presets & Custom Input: 1.0x, 1.5x, 2.0x, 2.5x, 3.0x, custom.
    ================================================================================
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Cleanup any previous instance
if _G.SpeedMultiplier_Cleanup then
    pcall(_G.SpeedMultiplier_Cleanup)
    _G.SpeedMultiplier_Cleanup = nil
end

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer and LocalPlayer.Character
local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
local RootPart = Character and (Character:FindFirstChild("HumanoidRootPart") or Character.PrimaryPart)

local Config = {
    GuiName = "SpeedMultiplierTestGui",
    DefaultMultiplier = 2.0,
    DefaultBaseSpeed = 270.0,
    MaxLogs = 300,
    Theme = {
        Bg = Color3.fromRGB(18, 20, 28),
        CardBg = Color3.fromRGB(25, 29, 42),
        Border = Color3.fromRGB(60, 130, 240),
        TextPrimary = Color3.fromRGB(240, 245, 255),
        TextDim = Color3.fromRGB(150, 165, 185),
        Green = Color3.fromRGB(80, 220, 120),
        Yellow = Color3.fromRGB(255, 205, 75),
        Red = Color3.fromRGB(255, 95, 95),
        Cyan = Color3.fromRGB(70, 200, 255),
        BtnActive = Color3.fromRGB(45, 95, 180),
        BtnInactive = Color3.fromRGB(32, 38, 54),
    }
}

local State = {
    Enabled = true,
    Multiplier = Config.DefaultMultiplier,
    BaseSpeed = Config.DefaultBaseSpeed,
    EggMultiplier = 1.0,
    IsCarrying = false,
    CurrentUid = nil,
    Logs = {},
}

local Connections = {}
local Remotes = {}
local Helpers = {}
local Engine = {}
local UI = { Elements = {}, PresetButtons = {} }

-- Connection Management
Helpers.addConn = function(conn)
    if conn then
        table.insert(Connections, conn)
    end
    return conn
end

Helpers.disconnectAll = function()
    for _, conn in ipairs(Connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(Connections)
end

-- Logging System
Helpers.log = function(msg, tag)
    tag = tag or "INFO"
    local timestamp = os.date("%H:%M:%S")
    local entry = string.format("[%s] [%s] %s", timestamp, tag, tostring(msg))
    table.insert(State.Logs, entry)
    if #State.Logs > (Config.MaxLogs or 300) then
        table.remove(State.Logs, 1)
    end
    print(string.format("[SpeedMult] %s", entry))
end

Helpers.copyLogs = function()
    local text = table.concat(State.Logs, "\n")
    if #text == 0 then
        text = string.format("[%s] [INFO] Log is empty.", os.date("%H:%M:%S"))
    end
    local ok = false
    if typeof(setclipboard) == "function" then
        ok = pcall(setclipboard, text)
    elseif typeof(toclipboard) == "function" then
        ok = pcall(toclipboard, text)
    end
    return ok, #State.Logs
end

-- Networking Resolution
Helpers.getNetRemote = function(path)
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")
    if not net then return nil end
    return net:FindFirstChild(path)
end

Remotes.RigRefresh = Helpers.getNetRemote("RE/RigSync/Refresh")
Remotes.FieldCarry = Helpers.getNetRemote("RE/EggWorld/FieldEggCarry")
Remotes.SpeedTollOffer = Helpers.getNetRemote("RE/GuardPatrol/SpeedTollOffer")

-- Physics: Zero friction tuning so feet don't snag at high speeds
Helpers.applyZeroFriction = function(char)
    if not char then return end
    local zeroFriction = PhysicalProperties.new(0.7, 0, 0, 100, 100)
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then
            pcall(function() p.CustomPhysicalProperties = zeroFriction end)
        end
    end
end

-- Physics Velocity Engine
Engine.updateVelocity = function()
    if not State.Enabled then return end
    if not (Character and Humanoid and Humanoid.Parent and Humanoid.Health > 0 and RootPart and RootPart.Parent) then
        return
    end

    local moveDir = Humanoid.MoveDirection
    local effectiveBase = State.BaseSpeed * State.EggMultiplier
    local targetSpeed = effectiveBase * State.Multiplier

    if moveDir.Magnitude > 0.05 then
        local dir = moveDir.Unit
        RootPart.AssemblyLinearVelocity = Vector3.new(
            dir.X * targetSpeed,
            RootPart.AssemblyLinearVelocity.Y,
            dir.Z * targetSpeed
        )
    else
        -- Grounded deceleration: stop horizontal velocity when player stops input
        if Humanoid.FloorMaterial ~= Enum.Material.Air then
            RootPart.AssemblyLinearVelocity = Vector3.new(0, RootPart.AssemblyLinearVelocity.Y, 0)
        end
    end
end

-- Network Listeners
Engine.initListeners = function()
    -- 1. Heartbeat physics driver
    Helpers.addConn(RunService.Heartbeat:Connect(function()
        Engine.updateVelocity()
    end))

    -- 2. RigSync Speed Sync
    if Remotes.RigRefresh then
        Helpers.addConn(Remotes.RigRefresh.OnClientEvent:Connect(function(payloadJson, ...)
            if typeof(payloadJson) == "string" then
                if string.find(payloadJson, "SetWalkSpeed", 1, true) then
                    -- Extract parsed speed argument
                    local speedVal = payloadJson:match("%[([%d%.]+)%]")
                    if speedVal then
                        local parsed = tonumber(speedVal)
                        if parsed and parsed > 50 then
                            State.BaseSpeed = parsed / (State.EggMultiplier > 0 and State.EggMultiplier or 1.0)
                            UI.updateDisplay()
                        end
                    end
                elseif string.find(payloadJson, "Ragdoll", 1, true) then
                    -- Anti-ragdoll clear
                    if Character then
                        Character:SetAttribute("RagdollEndTime", 0)
                        Character:SetAttribute("IsRagdoll", false)
                    end
                    Helpers.log("RigSync Ragdoll suppressed", "ANTI-RAGDOLL")
                end
            end
        end))
    end

    -- 3. Egg Carry State Sync
    if Remotes.FieldCarry then
        Helpers.addConn(Remotes.FieldCarry.OnClientEvent:Connect(function(args)
            if typeof(args) == "table" then
                if args.IsCarrying == true or (args.Uid and args.IsCarrying ~= false) then
                    State.IsCarrying = true
                    State.CurrentUid = args.Uid or State.CurrentUid
                    State.EggMultiplier = tonumber(args.SpeedMultiplier) or 0.96
                    Helpers.log(string.format("Carry ACTIVE (Uid: %s, EggMult: %.3f)", tostring(State.CurrentUid:sub(1, 8)), State.EggMultiplier), "CARRY")
                elseif args.IsCarrying == false then
                    State.IsCarrying = false
                    State.EggMultiplier = 1.0
                    Helpers.log("Carry INACTIVE (EggMult reset to 1.0)", "CARRY")
                end
                UI.updateDisplay()
            end
        end))
    end

    -- 4. Guard SpeedTollOffer Alert
    if Remotes.SpeedTollOffer then
        Helpers.addConn(Remotes.SpeedTollOffer.OnClientEvent:Connect(function(tollId, amount)
            Helpers.log(string.format("⚠️ Guard SpeedTollOffer arrived! (TollId: %s)", tostring(tollId)), "GUARD")
            if Character then
                Character:SetAttribute("RagdollEndTime", 0)
                Character:SetAttribute("IsRagdoll", false)
            end
        end))
    end

    -- 5. Character Lifecycle
    local function hookCharacter(char)
        if not char then return end
        Character = char
        Humanoid = char:WaitForChild("Humanoid", 5) or char:FindFirstChildOfClass("Humanoid")
        RootPart = char:WaitForChild("HumanoidRootPart", 5) or char.PrimaryPart
        Helpers.applyZeroFriction(char)

        if Humanoid and Humanoid.WalkSpeed > 50 then
            State.BaseSpeed = Humanoid.WalkSpeed
        end

        Helpers.addConn(char.AttributeChanged:Connect(function(attr)
            if attr == "RagdollEndTime" or attr == "IsRagdoll" then
                local endTime = char:GetAttribute("RagdollEndTime") or 0
                if typeof(endTime) == "number" and endTime > 0 then
                    char:SetAttribute("RagdollEndTime", 0)
                    char:SetAttribute("IsRagdoll", false)
                end
            end
        end))
    end

    if LocalPlayer then
        Helpers.addConn(LocalPlayer.CharacterAdded:Connect(hookCharacter))
        if LocalPlayer.Character then hookCharacter(LocalPlayer.Character) end
    end
end

-- UI Builder
UI.init = function()
    local parent = (gethui and gethui())
        or (game:GetService("CoreGui"):FindFirstChild("RobloxGui") and game:GetService("CoreGui"))
        or (LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui"))
    if not parent then return end

    local existing = parent:FindFirstChild(Config.GuiName)
    if existing then pcall(function() existing:Destroy() end) end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = Config.GuiName
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 99999
    screenGui.Parent = parent

    local main = Instance.new("Frame")
    main.Name = "MainFrame"
    main.Size = UDim2.new(0, 320, 0, 195)
    main.Position = UDim2.new(0, 30, 0.5, -95)
    main.BackgroundColor3 = Config.Theme.Bg
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.Parent = screenGui

    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", main)
    stroke.Color = Config.Theme.Border
    stroke.Thickness = 1.5

    -- Title Bar
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -60, 0, 26)
    title.Position = UDim2.new(0, 10, 0, 4)
    title.BackgroundTransparency = 1
    title.Text = "⚡ Speed Multiplier Test"
    title.TextColor3 = Config.Theme.Cyan
    title.TextSize = 13
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = main

    -- Close Button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 22, 0, 22)
    closeBtn.Position = UDim2.new(1, -26, 0, 6)
    closeBtn.BackgroundColor3 = Color3.fromRGB(40, 45, 60)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Config.Theme.TextDim
    closeBtn.TextSize = 11
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.Parent = main
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(closeBtn.MouseButton1Click:Connect(function()
        if _G.SpeedMultiplier_Cleanup then
            pcall(_G.SpeedMultiplier_Cleanup)
            _G.SpeedMultiplier_Cleanup = nil
        end
    end))

    -- Toggle Button
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Size = UDim2.new(0, 24, 0, 22)
    toggleBtn.Position = UDim2.new(1, -54, 0, 6)
    toggleBtn.BackgroundColor3 = Color3.fromRGB(35, 75, 45)
    toggleBtn.Text = "ON"
    toggleBtn.TextColor3 = Config.Theme.Green
    toggleBtn.TextSize = 10
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.Parent = main
    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(toggleBtn.MouseButton1Click:Connect(function()
        State.Enabled = not State.Enabled
        if State.Enabled then
            toggleBtn.Text = "ON"
            toggleBtn.TextColor3 = Config.Theme.Green
            toggleBtn.BackgroundColor3 = Color3.fromRGB(35, 75, 45)
            Helpers.log("Speed Multiplier enabled", "STATE")
        else
            toggleBtn.Text = "OFF"
            toggleBtn.TextColor3 = Config.Theme.Red
            toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
            Helpers.log("Speed Multiplier disabled", "STATE")
        end
        UI.updateDisplay()
    end))

    -- Speed Stats Banner
    local statsBanner = Instance.new("Frame")
    statsBanner.Size = UDim2.new(1, -20, 0, 46)
    statsBanner.Position = UDim2.new(0, 10, 0, 32)
    statsBanner.BackgroundColor3 = Config.Theme.CardBg
    statsBanner.BorderSizePixel = 0
    statsBanner.Parent = main
    Instance.new("UICorner", statsBanner).CornerRadius = UDim.new(0, 6)

    local speedLabel = Instance.new("TextLabel")
    speedLabel.Size = UDim2.new(1, -12, 0, 22)
    speedLabel.Position = UDim2.new(0, 6, 0, 2)
    speedLabel.BackgroundTransparency = 1
    speedLabel.Text = "Velocity Speed: 540.0 studs/s (2.0x)"
    speedLabel.TextColor3 = Config.Theme.Green
    speedLabel.TextSize = 12
    speedLabel.Font = Enum.Font.GothamBold
    speedLabel.TextXAlignment = Enum.TextXAlignment.Left
    speedLabel.Parent = statsBanner
    UI.Elements.SpeedLabel = speedLabel

    local subLabel = Instance.new("TextLabel")
    subLabel.Size = UDim2.new(1, -12, 0, 18)
    subLabel.Position = UDim2.new(0, 6, 0, 24)
    subLabel.BackgroundTransparency = 1
    subLabel.Text = "Base: 270.0 | EggMult: 1.000 | Normal"
    subLabel.TextColor3 = Config.Theme.TextDim
    subLabel.TextSize = 10
    subLabel.Font = Enum.Font.Gotham
    subLabel.TextXAlignment = Enum.TextXAlignment.Left
    subLabel.Parent = statsBanner
    UI.Elements.SubLabel = subLabel

    -- Preset Multiplier Buttons: 1.0x, 1.5x, 2.0x, 2.5x, 3.0x
    local presets = { 1.0, 1.5, 2.0, 2.5, 3.0 }
    local btnWidth = 56
    local gap = 5
    for i, p in ipairs(presets) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, btnWidth, 0, 24)
        btn.Position = UDim2.new(0, 10 + (i - 1) * (btnWidth + gap), 0, 84)
        btn.BackgroundColor3 = (State.Multiplier == p) and Config.Theme.BtnActive or Config.Theme.BtnInactive
        btn.Text = string.format("%.1fx", p)
        btn.TextColor3 = (State.Multiplier == p) and Config.Theme.TextPrimary or Config.Theme.TextDim
        btn.TextSize = 11
        btn.Font = Enum.Font.GothamBold
        btn.Parent = main
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

        UI.PresetButtons[p] = btn

        Helpers.addConn(btn.MouseButton1Click:Connect(function()
            State.Multiplier = p
            Helpers.log(string.format("Multiplier set to %.1fx", p), "INPUT")
            UI.updatePresets()
            UI.updateDisplay()
        end))
    end

    -- Custom Multiplier Input Row
    local customLabel = Instance.new("TextLabel")
    customLabel.Size = UDim2.new(0, 100, 0, 24)
    customLabel.Position = UDim2.new(0, 10, 0, 114)
    customLabel.BackgroundTransparency = 1
    customLabel.Text = "Custom Mult:"
    customLabel.TextColor3 = Config.Theme.TextDim
    customLabel.TextSize = 11
    customLabel.Font = Enum.Font.Gotham
    customLabel.TextXAlignment = Enum.TextXAlignment.Left
    customLabel.Parent = main

    local customBox = Instance.new("TextBox")
    customBox.Size = UDim2.new(0, 80, 0, 24)
    customBox.Position = UDim2.new(0, 115, 0, 114)
    customBox.BackgroundColor3 = Config.Theme.CardBg
    customBox.Text = tostring(State.Multiplier)
    customBox.TextColor3 = Config.Theme.Cyan
    customBox.TextSize = 11
    customBox.Font = Enum.Font.GothamBold
    customBox.ClearTextOnFocus = false
    customBox.Parent = main
    Instance.new("UICorner", customBox).CornerRadius = UDim.new(0, 4)
    UI.Elements.CustomBox = customBox

    local applyBtn = Instance.new("TextButton")
    applyBtn.Size = UDim2.new(0, 100, 0, 24)
    applyBtn.Position = UDim2.new(0, 210, 0, 114)
    applyBtn.BackgroundColor3 = Color3.fromRGB(40, 75, 120)
    applyBtn.Text = "Apply Custom"
    applyBtn.TextColor3 = Config.Theme.TextPrimary
    applyBtn.TextSize = 11
    applyBtn.Font = Enum.Font.GothamBold
    applyBtn.Parent = main
    Instance.new("UICorner", applyBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(applyBtn.MouseButton1Click:Connect(function()
        local val = tonumber(customBox.Text)
        if val and val > 0 and val <= 10.0 then
            State.Multiplier = val
            Helpers.log(string.format("Custom multiplier applied: %.2fx", val), "INPUT")
            UI.updatePresets()
            UI.updateDisplay()
        else
            customBox.Text = tostring(State.Multiplier)
        end
    end))

    -- Copy Log Button
    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(1, -20, 0, 26)
    copyBtn.Position = UDim2.new(0, 10, 0, 148)
    copyBtn.BackgroundColor3 = Color3.fromRGB(35, 55, 45)
    copyBtn.Text = "📋 Copy Log"
    copyBtn.TextColor3 = Config.Theme.Green
    copyBtn.TextSize = 11
    copyBtn.Font = Enum.Font.GothamBold
    copyBtn.Parent = main
    Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(copyBtn.MouseButton1Click:Connect(function()
        local okCopy, count = Helpers.copyLogs()
        if okCopy then
            copyBtn.Text = "✓ Copied (" .. tostring(count) .. " lines)!"
            copyBtn.TextColor3 = Color3.fromRGB(150, 255, 170)
        else
            copyBtn.Text = "⚠️ Failed to copy"
            copyBtn.TextColor3 = Config.Theme.Yellow
        end
        task.delay(2.0, function()
            if copyBtn and copyBtn.Parent then
                copyBtn.Text = "📋 Copy Log"
                copyBtn.TextColor3 = Config.Theme.Green
            end
        end)
    end))

    UI.Elements.ScreenGui = screenGui
    UI.updateDisplay()
end

UI.updatePresets = function()
    for p, btn in pairs(UI.PresetButtons) do
        if btn and btn.Parent then
            local active = (math.abs(State.Multiplier - p) < 0.01)
            btn.BackgroundColor3 = active and Config.Theme.BtnActive or Config.Theme.BtnInactive
            btn.TextColor3 = active and Config.Theme.TextPrimary or Config.Theme.TextDim
        end
    end
end

UI.updateDisplay = function()
    if not (UI.Elements.SpeedLabel and UI.Elements.SpeedLabel.Parent) then return end

    local effectiveBase = State.BaseSpeed * State.EggMultiplier
    local targetSpeed = effectiveBase * State.Multiplier

    if State.Enabled then
        UI.Elements.SpeedLabel.Text = string.format("Velocity Speed: %.1f studs/s (%.2fx)", targetSpeed, State.Multiplier)
        UI.Elements.SpeedLabel.TextColor3 = Config.Theme.Green
    else
        UI.Elements.SpeedLabel.Text = "Velocity Speed: DISABLED (Normal Walk)"
        UI.Elements.SpeedLabel.TextColor3 = Config.Theme.Red
    end

    local carryDesc = State.IsCarrying and string.format("Carrying (%s)", State.CurrentUid and State.CurrentUid:sub(1, 6) or "Egg") or "Empty Hands"
    UI.Elements.SubLabel.Text = string.format("Base: %.1f | EggMult: %.3f | %s", State.BaseSpeed, State.EggMultiplier, carryDesc)

    if UI.Elements.CustomBox and UI.Elements.CustomBox.Parent and not UI.Elements.CustomBox:IsFocused() then
        UI.Elements.CustomBox.Text = string.format("%.2f", State.Multiplier)
    end
end

-- Full Cleanup Routine
local function fullCleanup()
    State.Enabled = false
    Helpers.disconnectAll()
    if UI.Elements.ScreenGui and UI.Elements.ScreenGui.Parent then
        pcall(function() UI.Elements.ScreenGui:Destroy() end)
    end
    print("[SpeedMultiplierTest] Cleaned up cleanly.")
end

_G.SpeedMultiplier_Cleanup = fullCleanup

-- Startup
UI.init()
Engine.initListeners()
Helpers.log("Standalone Speed Multiplier Engine loaded", "SYSTEM")
