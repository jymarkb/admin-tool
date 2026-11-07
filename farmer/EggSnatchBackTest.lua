--[=[
    ================================================================================
    EGG SNATCH-BACK TEST (Standalone Guard Strike Recovery Engine)
    ================================================================================
    Purpose:
        Standalone test script to verify automatic dropped-egg snatch-back when
        struck by a Biome Guard / Boss.
        
    Design & Safety Contract:
        1. 100% Standalone: Does NOT require EggGoToUI_v12.lua to be running.
        2. Zero Metamethod Hooks: No __namecall or __index hooking (zero kicks).
        3. Zero Collision Tampering: Never modifies CanTouch, joints, or collision groups.
        4. Anti-Ragdoll & Knockback Nullification: Cancels strike knockback velocity
           immediately to keep the player right next to the dropped egg.
        5. Rapid Re-Pickup Burst: Re-invokes RF/EggWorld/AskFieldEggCarry and triggers
           dropped egg ProximityPrompts within < 100ms of the guard strike.
        6. Clean Connection Lifecycle: Tracks all connections in a table with _G cleanup.
        7. Strict Anti-Bloat: Root locals <= 20.
        8. Diagnostic Event Log: Logs all events with one-click "📋 Copy Log" to clipboard.
    ================================================================================
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Cleanup any previous instance
if _G.EggSnatchBack_Cleanup then
    pcall(_G.EggSnatchBack_Cleanup)
    _G.EggSnatchBack_Cleanup = nil
end

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer and LocalPlayer.Character
local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
local RootPart = Character and (Character:FindFirstChild("HumanoidRootPart") or Character.PrimaryPart)

local Config = {
    GuiName = "EggSnatchBackTestGui",
    MaxBurstAttempts = 10,
    BurstInterval = 0.04,
    MaxPickupRange = 25.0,
    MaxLogs = 300,
    Theme = {
        Bg = Color3.fromRGB(18, 20, 28),
        Border = Color3.fromRGB(60, 130, 240),
        TextPrimary = Color3.fromRGB(240, 245, 255),
        TextDim = Color3.fromRGB(150, 165, 185),
        Green = Color3.fromRGB(80, 220, 120),
        Yellow = Color3.fromRGB(255, 205, 75),
        Red = Color3.fromRGB(255, 95, 95),
        Cyan = Color3.fromRGB(70, 200, 255),
    }
}

local State = {
    Enabled = true,
    LastCarriedUid = nil,
    LastEggSlotKey = nil,
    LastDropPosition = nil,
    IsCarrying = false,
    RecoveryCount = 0,
    LastStrikeTime = 0,
    IsSnatching = false,
    Logs = {},
}

local Connections = {}
local Remotes = {}
local Helpers = {}
local Engine = {}
local UI = { Elements = {} }

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
    print(string.format("[EggSnatchBack] %s", entry))
end

Helpers.copyLogs = function()
    local text = table.concat(State.Logs, "\n")
    if #text == 0 then
        text = string.format("[%s] [INFO] Log is empty. Perform an egg pickup and let a guard strike to record events.", os.date("%H:%M:%S"))
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

Remotes.AskCarry = Helpers.getNetRemote("RF/EggWorld/AskFieldEggCarry")
Remotes.FieldCarry = Helpers.getNetRemote("RE/EggWorld/FieldEggCarry")
Remotes.FieldShifted = Helpers.getNetRemote("RE/EggWorld/FieldEggShifted")
Remotes.SpeedTollOffer = Helpers.getNetRemote("RE/GuardPatrol/SpeedTollOffer")
Remotes.SpeedTollWarning = Helpers.getNetRemote("RE/GuardPatrol/SpeedTollWarning")
Remotes.RigRefresh = Helpers.getNetRemote("RE/RigSync/Refresh")

-- Proximity Prompt Triggering
Helpers.triggerPrompt = function(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    local ok = pcall(function()
        if typeof(fireproximityprompt) == "function" then
            fireproximityprompt(prompt)
        elseif prompt.InputHoldBegin then
            prompt:InputHoldBegin()
            task.wait(prompt.HoldDuration or 0.1)
            prompt:InputHoldEnd()
        end
    end)
    return ok
end

-- Find dropped egg instance near player
Helpers.findNearbyDroppedEgg = function(uid, maxDist)
    maxDist = maxDist or Config.MaxPickupRange
    if not (RootPart and RootPart.Parent) then return nil end
    local rootPos = RootPart.Position

    -- Check Workspace areas for egg models with matching UID or nearby dropped parts
    local areas = workspace:FindFirstChild("World")
        and workspace.World:FindFirstChild("Areas")
    if not areas then return nil end

    local bestEgg, bestDist = nil, maxDist
    for _, container in ipairs({ areas:FindFirstChild("EggSlotsClient"), areas:FindFirstChild("GuardAreas") }) do
        if container then
            for _, desc in ipairs(container:GetDescendants()) do
                if desc:IsA("Model") or desc:IsA("BasePart") then
                    local eggUid = desc:GetAttribute("Uid") or desc:GetAttribute("EggUid") or desc.Name
                    local pos = (desc:IsA("BasePart") and desc.Position) or (desc:IsA("Model") and desc:GetPivot().Position)
                    if pos then
                        local dist = (pos - rootPos).Magnitude
                        if dist <= bestDist then
                            if uid and (eggUid == uid or string.find(tostring(desc.Name), uid, 1, true)) then
                                return desc
                            elseif not bestEgg then
                                bestEgg = desc
                                bestDist = dist
                            end
                        end
                    end
                end
            end
        end
    end
    return bestEgg
end

-- Anti-Ragdoll & Knockback Neutralizer
Helpers.nullifyRagdollAndKnockback = function()
    -- 1. Freeze linear velocity immediately to prevent knockback displacement
    if RootPart and RootPart.Parent then
        pcall(function()
            RootPart.AssemblyLinearVelocity = Vector3.zero
            RootPart.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    -- 2. Clear character ragdoll attributes instantly
    if Character then
        pcall(function()
            Character:SetAttribute("RagdollEndTime", 0)
            Character:SetAttribute("RagdollTime", 0)
            Character:SetAttribute("IsRagdoll", false)
            Character:SetAttribute("Ragdolled", false)
        end)
    end

    if LocalPlayer then
        pcall(function()
            LocalPlayer:SetAttribute("RagdollEndTime", 0)
            LocalPlayer:SetAttribute("IsRagdoll", false)
        end)
    end

    -- 3. Stand up humanoid immediately
    if Humanoid and Humanoid.Parent and Humanoid.Health > 0 then
        pcall(function()
            Humanoid.PlatformStand = false
            Humanoid.Sit = false
            Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end
end

-- Core Snatch-Back Engine
Engine.snatchBack = function(triggerSource)
    if not State.Enabled then return end
    if State.IsSnatching then return end

    local targetUid = State.LastCarriedUid
    if not targetUid or targetUid == "" then
        UI.setStatus("Drop detected, but no cached Egg UID!", Config.Theme.Yellow)
        Helpers.log("Drop event occurred but LastCarriedUid was nil/empty", "WARN")
        return
    end

    State.IsSnatching = true
    State.LastStrikeTime = os.clock()
    local startTime = os.clock()
    UI.setStatus("⚡ Snatching dropped egg (" .. tostring(targetUid:sub(1, 8)) .. ")...", Config.Theme.Cyan)
    Helpers.log(string.format("Snatch-back started for UID %s (Trigger: %s)", tostring(targetUid), tostring(triggerSource)), "SNATCH")

    task.spawn(function()
        -- Step 1: Nullify ragdoll and knockback continuously across initial burst
        Helpers.nullifyRagdollAndKnockback()

        local rf = Remotes.AskCarry or Helpers.getNetRemote("RF/EggWorld/AskFieldEggCarry")
        local recovered = false

        for attempt = 1, Config.MaxBurstAttempts do
            Helpers.nullifyRagdollAndKnockback()

            -- Try ProximityPrompt if egg model exists nearby
            local promptTriggered = false
            local eggInst = Helpers.findNearbyDroppedEgg(targetUid, Config.MaxPickupRange)
            if eggInst then
                local prompt = eggInst:FindFirstChildWhichIsA("ProximityPrompt", true)
                if prompt then
                    promptTriggered = Helpers.triggerPrompt(prompt)
                end
            end

            -- Invoke AskFieldEggCarry
            local remoteSuccess = false
            if rf then
                local payload = { Uid = targetUid }
                if State.LastEggSlotKey then
                    payload.FirstAreaSlotKey = State.LastEggSlotKey
                end

                local ok, res = pcall(function()
                    return rf:InvokeServer(payload)
                end)

                if (ok and res == true) or State.IsCarrying then
                    remoteSuccess = true
                    recovered = true
                    Helpers.log(string.format("Attempt %d: Carry re-granted via remote! (ok=%s, res=%s)", attempt, tostring(ok), tostring(res)), "SUCCESS")
                    break
                end
            end

            task.wait(Config.BurstInterval)
            if State.IsCarrying then
                recovered = true
                Helpers.log(string.format("Attempt %d: IsCarrying confirmed true!", attempt), "SUCCESS")
                break
            end
        end

        State.IsSnatching = false

        if recovered or State.IsCarrying then
            State.RecoveryCount = State.RecoveryCount + 1
            local elapsed = (os.clock() - startTime) * 1000
            UI.setRecoveryCount(State.RecoveryCount)
            UI.setStatus("✓ Recovered! Run away from Guard!", Config.Theme.Green)
            Helpers.log(string.format("RECOVERY SUCCESSFUL! Snatched egg back in %.1fms (Total: %d)", elapsed, State.RecoveryCount), "SUCCESS")

            -- Small safety jump/impulse to avoid ground stickiness
            pcall(function()
                if Humanoid and Humanoid.Parent then
                    Humanoid:ChangeState(Enum.HumanoidStateType.Running)
                end
            end)
        else
            UI.setStatus("Snatch attempt finished (" .. tostring(triggerSource) .. ")", Config.Theme.Yellow)
            Helpers.log("Snatch burst ended without carry confirmation", "WARN")
        end
    end)
end

-- Event Listeners
Engine.initListeners = function()
    -- 1. Track Egg Carry Start
    if Remotes.FieldCarry then
        Helpers.addConn(Remotes.FieldCarry.OnClientEvent:Connect(function(args)
            if typeof(args) == "table" then
                if args.IsCarrying == true or (args.Uid and args.IsCarrying ~= false) then
                    State.IsCarrying = true
                    State.LastCarriedUid = args.Uid or State.LastCarriedUid
                    UI.setCarriedUid(State.LastCarriedUid)
                    UI.setStatus("Holding Egg: " .. tostring(State.LastCarriedUid:sub(1, 8)), Config.Theme.Green)
                    Helpers.log(string.format("Egg carry confirmed (Uid: %s, SpeedMult: %s)", tostring(State.LastCarriedUid), tostring(args.SpeedMultiplier or 1.0)), "CARRY")
                elseif args.IsCarrying == false then
                    State.IsCarrying = false
                    Helpers.log("Egg carry revoked by server (IsCarrying = false)", "DROP")
                    if State.LastCarriedUid and not State.IsSnatching then
                        Engine.snatchBack("FieldEggCarry:Dropped")
                    end
                end
            end
        end))
    end

    -- 2. Track Egg Shifted (Drop coordinates and despawn tracking)
    if Remotes.FieldShifted then
        Helpers.addConn(Remotes.FieldShifted.OnClientEvent:Connect(function(args)
            if typeof(args) == "table" then
                if args.DroppedAt and State.LastCarriedUid then
                    if args.BoundsCFrame then
                        State.LastDropPosition = args.BoundsCFrame.Position
                        Helpers.log(string.format("FieldEggShifted dropped at V3(%.1f, %.1f, %.1f)", args.BoundsCFrame.Position.X, args.BoundsCFrame.Position.Y, args.BoundsCFrame.Position.Z), "DROP")
                    else
                        Helpers.log("FieldEggShifted dropped egg detected", "DROP")
                    end
                    if not State.IsSnatching and not State.IsCarrying then
                        Engine.snatchBack("FieldEggShifted:Dropped")
                    end
                elseif args.NestId and State.LastCarriedUid then
                    -- Egg was returned to nest by server
                    if not State.IsCarrying then
                        UI.setStatus("Egg returned to nest (" .. tostring(args.NestId) .. ")", Config.Theme.TextDim)
                        Helpers.log(string.format("Egg returned to nest: %s", tostring(args.NestId)), "DESPAWN")
                    end
                end
            end
        end))
    end

    -- 3. Guard SpeedTollOffer (Immediate Strike Trigger)
    if Remotes.SpeedTollOffer then
        Helpers.addConn(Remotes.SpeedTollOffer.OnClientEvent:Connect(function(tollId, amount)
            Helpers.log(string.format("Guard SpeedTollOffer received! TollId=%s Amount=%s", tostring(tollId), tostring(amount)), "GUARD")
            Helpers.nullifyRagdollAndKnockback()
            if State.LastCarriedUid and not State.IsSnatching then
                Engine.snatchBack("Guard:SpeedTollOffer")
            end
        end))
    end

    -- 4. RigSync Ragdoll Detection
    if Remotes.RigRefresh then
        Helpers.addConn(Remotes.RigRefresh.OnClientEvent:Connect(function(payloadJson, ...)
            if typeof(payloadJson) == "string" and string.find(payloadJson, "Ragdoll", 1, true) then
                Helpers.log("RigSync Refresh Ragdoll event detected", "RAGDOLL")
                Helpers.nullifyRagdollAndKnockback()
                if State.LastCarriedUid and not State.IsSnatching and not State.IsCarrying then
                    Engine.snatchBack("RigSync:Ragdoll")
                end
            end
        end))
    end

    -- 5. Character Attribute Shifts (RagdollEndTime anti-ragdoll)
    local function hookCharacter(char)
        if not char then return end
        Character = char
        Humanoid = char:WaitForChild("Humanoid", 5) or char:FindFirstChildOfClass("Humanoid")
        RootPart = char:WaitForChild("HumanoidRootPart", 5) or char.PrimaryPart

        Helpers.addConn(char.AttributeChanged:Connect(function(attr)
            if attr == "RagdollEndTime" or attr == "IsRagdoll" or attr == "Ragdolled" then
                local endTime = char:GetAttribute("RagdollEndTime") or 0
                if typeof(endTime) == "number" and endTime > 0 then
                    Helpers.log(string.format("Attribute changed: %s = %.2f (Nullifying instantly)", attr, endTime), "ANTI-RAGDOLL")
                    Helpers.nullifyRagdollAndKnockback()
                    if State.LastCarriedUid and not State.IsSnatching and not State.IsCarrying then
                        Engine.snatchBack("AttributeChanged:Ragdoll")
                    end
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
    main.Size = UDim2.new(0, 320, 0, 155)
    main.Position = UDim2.new(0, 30, 0.5, -80)
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
    title.Text = "⚡ Egg Snatch-Back Test"
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
        if _G.EggSnatchBack_Cleanup then
            pcall(_G.EggSnatchBack_Cleanup)
            _G.EggSnatchBack_Cleanup = nil
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
            UI.setStatus("Snatch-Back Enabled", Config.Theme.Green)
            Helpers.log("Snatch-Back manually enabled", "STATE")
        else
            toggleBtn.Text = "OFF"
            toggleBtn.TextColor3 = Config.Theme.Red
            toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
            UI.setStatus("Snatch-Back Disabled", Config.Theme.Red)
            Helpers.log("Snatch-Back manually disabled", "STATE")
        end
    end))

    -- Info: Cached UID
    local uidLabel = Instance.new("TextLabel")
    uidLabel.Size = UDim2.new(1, -20, 0, 18)
    uidLabel.Position = UDim2.new(0, 10, 0, 34)
    uidLabel.BackgroundTransparency = 1
    uidLabel.Text = "Target UID: None (Pick up an egg to track)"
    uidLabel.TextColor3 = Config.Theme.TextDim
    uidLabel.TextSize = 11
    uidLabel.Font = Enum.Font.Gotham
    uidLabel.TextXAlignment = Enum.TextXAlignment.Left
    uidLabel.Parent = main
    UI.Elements.UidLabel = uidLabel

    -- Info: Recoveries Count
    local countLabel = Instance.new("TextLabel")
    countLabel.Size = UDim2.new(1, -20, 0, 18)
    countLabel.Position = UDim2.new(0, 10, 0, 56)
    countLabel.BackgroundTransparency = 1
    countLabel.Text = "Recoveries: 0"
    countLabel.TextColor3 = Config.Theme.TextPrimary
    countLabel.TextSize = 11
    countLabel.Font = Enum.Font.GothamBold
    countLabel.TextXAlignment = Enum.TextXAlignment.Left
    countLabel.Parent = main
    UI.Elements.CountLabel = countLabel

    -- Info: Status Banner
    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -20, 0, 36)
    status.Position = UDim2.new(0, 10, 0, 80)
    status.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    status.Text = "Status: Idle (Ready to protect)"
    status.TextColor3 = Config.Theme.TextPrimary
    status.TextSize = 11
    status.Font = Enum.Font.Gotham
    status.TextWrapped = true
    status.Parent = main
    Instance.new("UICorner", status).CornerRadius = UDim.new(0, 6)
    UI.Elements.Status = status

    -- Manual Test Snatch Button
    local testBtn = Instance.new("TextButton")
    testBtn.Size = UDim2.new(0, 145, 0, 24)
    testBtn.Position = UDim2.new(0, 10, 0, 122)
    testBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
    testBtn.Text = "⚡ Test Snatch"
    testBtn.TextColor3 = Config.Theme.Cyan
    testBtn.TextSize = 11
    testBtn.Font = Enum.Font.GothamBold
    testBtn.Parent = main
    Instance.new("UICorner", testBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(testBtn.MouseButton1Click:Connect(function()
        Engine.snatchBack("ManualButtonClick")
    end))

    -- Copy Log Button
    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(0, 145, 0, 24)
    copyBtn.Position = UDim2.new(0, 165, 0, 122)
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
            copyBtn.Text = "✓ Copied (" .. tostring(count) .. ")!"
            copyBtn.TextColor3 = Color3.fromRGB(150, 255, 170)
        else
            copyBtn.Text = "⚠️ Failed"
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
end

UI.setStatus = function(text, color)
    if UI.Elements.Status and UI.Elements.Status.Parent then
        UI.Elements.Status.Text = "Status: " .. tostring(text)
        if color then
            UI.Elements.Status.TextColor3 = color
        end
    end
end

UI.setCarriedUid = function(uid)
    if UI.Elements.UidLabel and UI.Elements.UidLabel.Parent then
        if uid then
            UI.Elements.UidLabel.Text = "Target UID: " .. tostring(uid:sub(1, 16)) .. "..."
            UI.Elements.UidLabel.TextColor3 = Config.Theme.TextPrimary
        else
            UI.Elements.UidLabel.Text = "Target UID: None"
            UI.Elements.UidLabel.TextColor3 = Config.Theme.TextDim
        end
    end
end

UI.setRecoveryCount = function(count)
    if UI.Elements.CountLabel and UI.Elements.CountLabel.Parent then
        UI.Elements.CountLabel.Text = "Recoveries: " .. tostring(count)
        UI.Elements.CountLabel.TextColor3 = Config.Theme.Green
    end
end

-- Full Cleanup Routine
local function fullCleanup()
    State.Enabled = false
    Helpers.disconnectAll()
    if UI.Elements.ScreenGui and UI.Elements.ScreenGui.Parent then
        pcall(function() UI.Elements.ScreenGui:Destroy() end)
    end
    print("[EggSnatchBackTest] Cleaned up cleanly.")
end

_G.EggSnatchBack_Cleanup = fullCleanup

-- Startup
UI.init()
Engine.initListeners()
Helpers.log("Standalone Snatch-Back Engine loaded successfully", "SYSTEM")
