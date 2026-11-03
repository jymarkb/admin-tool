--[=[
    ================================================================================
    FOREST STRIKE DROPPER (Auto-Loop Edition)
    ================================================================================
    Purpose:
        Streamlined event-driven dropper for the Forest Biome with full Auto-Loop:
          1. Picks up an egg at the Forest Nest.
          2. Fires RE/GuardPatrol/ForestStrike on demand.
          3. Waits for the server strike packet (RE/GuardPatrol/SpeedTollOffer / Ragdoll).
          4. Instantly teleports to Pen (SavedLocation) during Hit Authority.
          5. Drops the egg into the pen (RF/EggWorld/AskFieldEggDrop).
          6. AUTO-LOOP: Teleports back to the Forest Nest with empty hands, picks
             up the next egg, and repeats the cycle automatically!
          
    Safety & Cleanliness:
        - Zero Metamethod Hooks: No __namecall or __index hooks (zero kicks).
        - Zero Guessing Timers: Driven by actual server strike events (0.1s response).
        - 100% Standalone with draggable floating UI, location markers, and clipboard logging.
        - Strict Anti-Bloat: Root locals <= 20.
    ================================================================================
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Cleanup any previous instance
if _G.ForestDropper_Cleanup then
    pcall(_G.ForestDropper_Cleanup)
    _G.ForestDropper_Cleanup = nil
end

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer and LocalPlayer.Character
local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
local RootPart = Character and (Character:FindFirstChild("HumanoidRootPart") or Character.PrimaryPart)

local Config = {
    GuiName = "ForestDropperCleanGui",
    DropSpamCount = 8,
    DropSpamInterval = 0.03,
    PositionSettleTime = 0.12,
    StrikeTimeout = 1.20,
    ReturnDelay = 0.50,
    NestScanRadius = 35.0,
    MaxLogs = 300,
    SampleGuardCFrame = CFrame.new(
        605.572266, 69.3371735, -325.887329,
        0.70000118, 0, -0.714141667,
        0, 1, 0,
        0.714141667, 0, 0.70000118
    ),
    Theme = {
        Bg = Color3.fromRGB(20, 22, 30),
        Card = Color3.fromRGB(28, 32, 44),
        Border = Color3.fromRGB(65, 140, 255),
        TextPrimary = Color3.fromRGB(240, 245, 255),
        TextDim = Color3.fromRGB(150, 165, 185),
        Green = Color3.fromRGB(80, 225, 130),
        Yellow = Color3.fromRGB(255, 205, 75),
        Red = Color3.fromRGB(255, 95, 95),
        Cyan = Color3.fromRGB(75, 205, 255),
    }
}

local State = {
    Enabled = true,
    AutoLoop = true,
    SavedLocation = Vector3.new(949.147, 70.724, -412.289),
    StartLocation = Vector3.new(600.0, 71.4, -322.0),
    IsActive = false,
    IsCarrying = false,
    CurrentEggUid = nil,
    Deliveries = 0,
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
    print(string.format("[Dropper] %s", entry))
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

Remotes.FieldCarry = Helpers.getNetRemote("RE/EggWorld/FieldEggCarry")
Remotes.ForestStrike = Helpers.getNetRemote("RE/GuardPatrol/ForestStrike")
Remotes.Rouse = Helpers.getNetRemote("RE/GuardPatrol/Rouse")
Remotes.SpeedTollOffer = Helpers.getNetRemote("RE/GuardPatrol/SpeedTollOffer")
Remotes.RigRefresh = Helpers.getNetRemote("RE/RigSync/Refresh")
Remotes.AskDrop = Helpers.getNetRemote("RF/EggWorld/AskFieldEggDrop")
Remotes.AskCarry = Helpers.getNetRemote("RF/EggWorld/AskFieldEggCarry")

-- Guard Resolution
Helpers.getForestGuard = function()
    local ws = workspace
    local areas = ws:FindFirstChild("World") and ws.World:FindFirstChild("Areas")
    local guardAreas = areas and areas:FindFirstChild("GuardAreas")
    if guardAreas then
        local forest = guardAreas:FindFirstChild("Forest")
        if forest then
            return forest:FindFirstChild("Guard") or forest:FindFirstChild("ForestGuardAuthored")
        end
    end
    return nil
end

Helpers.rouseForestGuard = function()
    local guard = Helpers.getForestGuard()
    local event = Remotes.Rouse
    if event and guard then
        pcall(function()
            if typeof(firesignal) == "function" then
                firesignal(event.OnClientEvent, guard)
            end
        end)
    end
end

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

-- Anti-Ragdoll & Physics Reset
Helpers.nullifyRagdoll = function()
    if RootPart and RootPart.Parent then
        pcall(function()
            RootPart.AssemblyLinearVelocity = Vector3.zero
            RootPart.AssemblyAngularVelocity = Vector3.zero
        end)
    end
    if Character then
        pcall(function()
            Character:SetAttribute("RagdollEndTime", 0)
            Character:SetAttribute("RagdollTime", 0)
            Character:SetAttribute("IsRagdoll", false)
            Character:SetAttribute("Ragdolled", false)
        end)
    end
    if Humanoid and Humanoid.Parent and Humanoid.Health > 0 then
        pcall(function()
            Humanoid.PlatformStand = false
            Humanoid.Sit = false
            Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end
end

-- Egg Drop Invocations
Engine.dropEggSpam = function(count)
    count = count or Config.DropSpamCount
    local rf = Remotes.AskDrop or Helpers.getNetRemote("RF/EggWorld/AskFieldEggDrop")
    if not rf then
        Helpers.log("ERROR: AskFieldEggDrop remote not found", "ERROR")
        return
    end

    for i = 1, count do
        task.spawn(function()
            local ok, res = pcall(function()
                return rf:InvokeServer({ Reason = "PlayerRequest" })
            end)
            if not ok or res == false then
                pcall(function() rf:InvokeServer() end)
            end
        end)
        if i < count then
            task.wait(Config.DropSpamInterval)
        end
    end
end

-- Find and Pickup Nearby Forest Egg
Helpers.tryPickupNearbyEgg = function(centerPos, radius)
    radius = radius or Config.NestScanRadius
    centerPos = centerPos or (RootPart and RootPart.Position)
    if not centerPos then return false end

    local rfCarry = Remotes.AskCarry or Helpers.getNetRemote("RF/EggWorld/AskFieldEggCarry")
    local ws = workspace
    local areas = ws:FindFirstChild("World") and ws.World:FindFirstChild("Areas")
    local guardAreas = areas and areas:FindFirstChild("GuardAreas")
    local forestNests = guardAreas and guardAreas:FindFirstChild("Forest") and guardAreas.Forest:FindFirstChild("Nests")

    local candidatePrompts = {}
    local candidateUids = {}

    local function scanModel(m)
        if not m then return end
        for _, desc in ipairs(m:GetDescendants()) do
            if desc:IsA("ProximityPrompt") then
                local pPart = desc.Parent
                local pPos = pPart and ((pPart:IsA("BasePart") and pPart.Position) or (pPart:IsA("Model") and pPart:GetPivot().Position))
                if pPos and (pPos - centerPos).Magnitude <= radius then
                    table.insert(candidatePrompts, desc)
                end
            elseif desc:IsA("Model") or desc:IsA("BasePart") then
                local uid = desc:GetAttribute("Uid") or desc:GetAttribute("EggUid") or (desc.Name:find("Slot_") and desc.Name)
                local pPos = (desc:IsA("BasePart") and desc.Position) or (desc:IsA("Model") and desc:GetPivot().Position)
                if uid and pPos and (pPos - centerPos).Magnitude <= radius then
                    table.insert(candidateUids, { Uid = uid, Pos = pPos })
                end
            end
        end
    end

    scanModel(forestNests)
    scanModel(areas and areas:FindFirstChild("EggSlotsClient"))
    scanModel(ws:FindFirstChild("AreaEggSlotsClient"))
    scanModel(ws:FindFirstChild("ClientRenderedAssets"))

    -- 1. Try triggering proximity prompt
    for _, prompt in ipairs(candidatePrompts) do
        local ok = Helpers.triggerPrompt(prompt)
        if ok then
            Helpers.log("Triggered egg ProximityPrompt", "PICKUP")
            return true
        end
    end

    -- 2. Try invoking AskFieldEggCarry on candidate UIDs
    if rfCarry then
        for _, c in ipairs(candidateUids) do
            local payload = { Uid = c.Uid }
            if c.Uid:find("Slot_") then
                payload.FirstAreaSlotKey = "Forest:" .. c.Uid
            end
            local ok, res = pcall(function()
                return rfCarry:InvokeServer(payload)
            end)
            if ok and res == true then
                Helpers.log(string.format("Picked up egg via remote: %s", tostring(c.Uid)), "PICKUP")
                return true
            end
        end
    end

    return false
end

-- Return to Forest Nest & Continue Farm Loop
Engine.returnToNestAndPickup = function()
    if not State.Enabled or not State.AutoLoop then return end
    if State.IsActive or State.IsCarrying then return end

    task.spawn(function()
        task.wait(Config.ReturnDelay or 0.5)
        if not State.AutoLoop or State.IsActive or State.IsCarrying then return end

        local nestPos = State.StartLocation
        if not nestPos then
            UI.setStatus("Nest location not set!", Config.Theme.Yellow)
            return
        end

        UI.setStatus("Returning to Forest Nest...", Config.Theme.Cyan)
        Helpers.log(string.format("Teleporting back to nest at V3(%.1f, %.1f, %.1f)", nestPos.X, nestPos.Y, nestPos.Z), "RETURN")

        -- Teleport with empty hands (100% permitted by server)
        if RootPart and RootPart.Parent then
            RootPart.CFrame = CFrame.new(nestPos)
            RootPart.AssemblyLinearVelocity = Vector3.zero
            RootPart.AssemblyAngularVelocity = Vector3.zero
        end

        task.wait(0.25)

        -- Search for nearby egg and trigger pickup
        local attempts = 0
        while State.AutoLoop and not State.IsCarrying and not State.IsActive and attempts < 12 do
            attempts = attempts + 1
            local picked = Helpers.tryPickupNearbyEgg(nestPos, Config.NestScanRadius or 35.0)
            if picked or State.IsCarrying then
                break
            end
            task.wait(0.25)
        end

        if not State.IsCarrying and not State.IsActive then
            UI.setStatus("Waiting for egg to spawn at nest...", Config.Theme.Yellow)
        end
    end)
end

-- Core Dropper Execution
Engine.executeDrop = function(eggUid)
    if not State.Enabled then return end
    if State.IsActive then return end
    if not State.SavedLocation then
        UI.setStatus("Drop Location not set! Click 'Set Drop' first.", Config.Theme.Yellow)
        return
    end

    State.IsActive = true
    State.CurrentEggUid = eggUid
    local startTime = os.clock()

    UI.setStatus("⚡ Forest Strike fired! Waiting for Hit Authority...", Config.Theme.Cyan)
    Helpers.log(string.format("Starting drop routine for UID %s", tostring(eggUid)), "DROPPER")

    -- Capture nest start location automatically if close to a nest
    if RootPart and RootPart.Parent and not State.StartLocation then
        State.StartLocation = RootPart.Position
    end

    -- Step 1: Fire ForestStrike on demand
    local strikeRemote = Remotes.ForestStrike or Helpers.getNetRemote("RE/GuardPatrol/ForestStrike")
    if strikeRemote then
        local guard = Helpers.getForestGuard()
        local guardCFrame = (guard and guard:GetPivot()) or Config.SampleGuardCFrame

        local ok, err = pcall(function()
            strikeRemote:FireServer({
                GuardCFrame = guardCFrame,
                EggUid = eggUid,
            })
        end)
        if ok then
            Helpers.log("ForestStrike:FireServer sent OK!", "STRIKE")
        else
            Helpers.log("ForestStrike failed: " .. tostring(err), "ERROR")
        end
    end

    -- Rouse guard as redundant backup
    Helpers.rouseForestGuard()

    -- Step 2: Listen for Strike Event (Event-Driven Hit Authority Trigger)
    local strikeConfirmed = false
    local strikeConns = {}

    local function onStrikeEvent(sourceName)
        if strikeConfirmed then return end
        strikeConfirmed = true
        Helpers.log(string.format("Strike event confirmed via %s (+%.3fs)", sourceName, os.clock() - startTime), "STRIKE")

        -- Cleanup temporary strike listeners immediately
        for _, c in ipairs(strikeConns) do pcall(function() c:Disconnect() end) end
        table.clear(strikeConns)

        -- Step 3: INSTANT HIT AUTHORITY TELEPORT TO PEN
        if RootPart and RootPart.Parent then
            RootPart.CFrame = CFrame.new(State.SavedLocation)
            RootPart.AssemblyLinearVelocity = Vector3.zero
            RootPart.AssemblyAngularVelocity = Vector3.zero
        end

        Helpers.nullifyRagdoll()

        -- Step 4: SPAM DROP REMOTE AT PEN
        task.spawn(function()
            Engine.dropEggSpam(Config.DropSpamCount)
        end)

        -- Step 5: Settle position at pen
        local settleStart = os.clock()
        while (os.clock() - settleStart < Config.PositionSettleTime) do
            if RootPart and RootPart.Parent then
                RootPart.CFrame = CFrame.new(State.SavedLocation)
                RootPart.AssemblyLinearVelocity = Vector3.zero
            end
            RunService.Heartbeat:Wait()
        end

        -- Step 6: Verify delivery
        local currentPos = RootPart and RootPart.Position or Vector3.zero
        local distFromDrop = (currentPos - State.SavedLocation).Magnitude

        if distFromDrop <= 25.0 then
            State.Deliveries = State.Deliveries + 1
            UI.setDeliveries(State.Deliveries)
            UI.setStatus("✓ Success! Egg dropped in pen.", Config.Theme.Green)
            Helpers.log(string.format("SUCCESS: Egg delivered in %.3fs (Error: %.1f studs, Total: %d)", os.clock() - startTime, distFromDrop, State.Deliveries), "SUCCESS")

            -- Trigger Auto-Loop Return if enabled
            if State.AutoLoop then
                task.delay(0.4, function()
                    if State.AutoLoop and not State.IsActive then
                        Engine.returnToNestAndPickup()
                    end
                end)
            end
        else
            UI.setStatus(string.format("⚠️ Rubberbanded (%.0fst from drop).", distFromDrop), Config.Theme.Red)
            Helpers.log(string.format("FAILED: Rubberband detected (%.1f studs from drop)", distFromDrop), "WARN")
        end

        State.IsActive = false
    end

    -- Hook SpeedTollOffer (Primary Guard Strike Remote)
    if Remotes.SpeedTollOffer then
        table.insert(strikeConns, Remotes.SpeedTollOffer.OnClientEvent:Connect(function()
            onStrikeEvent("SpeedTollOffer")
        end))
    end

    -- Hook RigSync Refresh (Ragdoll Action)
    if Remotes.RigRefresh then
        table.insert(strikeConns, Remotes.RigRefresh.OnClientEvent:Connect(function(payloadJson)
            if typeof(payloadJson) == "string" and string.find(payloadJson, "Ragdoll", 1, true) then
                onStrikeEvent("RigSync:Ragdoll")
            end
        end))
    end

    -- Hook Character RagdollEndTime
    if Character then
        table.insert(strikeConns, Character.AttributeChanged:Connect(function(attr)
            if attr == "RagdollEndTime" then
                local v = Character:GetAttribute("RagdollEndTime") or 0
                if typeof(v) == "number" and v > 0 then
                    onStrikeEvent("Attr:RagdollEndTime")
                end
            end
        end))
    end

    -- Safety Timeout
    task.delay(Config.StrikeTimeout, function()
        if not strikeConfirmed then
            for _, c in ipairs(strikeConns) do pcall(function() c:Disconnect() end) end
            table.clear(strikeConns)
            State.IsActive = false
            UI.setStatus("Timeout: Strike packet did not arrive.", Config.Theme.Yellow)
            Helpers.log("Strike timeout expired without hit confirmation", "WARN")
        end
    end)
end

-- Event Listeners
Engine.initListeners = function()
    -- Automatically trigger when egg is picked up
    if Remotes.FieldCarry then
        Helpers.addConn(Remotes.FieldCarry.OnClientEvent:Connect(function(args)
            if typeof(args) == "table" then
                if args.IsCarrying == true or (args.Uid and args.IsCarrying ~= false) then
                    State.IsCarrying = true
                    local eggUid = args.Uid or State.CurrentEggUid
                    if eggUid and not State.IsActive then
                        Helpers.log(string.format("Carry detected: %s", tostring(eggUid)), "PICKUP")
                        Engine.executeDrop(eggUid)
                    end
                elseif args.IsCarrying == false then
                    State.IsCarrying = false
                end
            end
        end))
    end

    -- Character lifecycle tracking
    local function hookCharacter(char)
        if not char then return end
        Character = char
        Humanoid = char:WaitForChild("Humanoid", 5) or char:FindFirstChildOfClass("Humanoid")
        RootPart = char:WaitForChild("HumanoidRootPart", 5) or char.PrimaryPart
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
    main.Size = UDim2.new(0, 320, 0, 235)
    main.Position = UDim2.new(0.5, -160, 0.4, -115)
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
    title.Text = "⚡ Forest Dropper (Auto-Loop)"
    title.TextColor3 = Config.Theme.Cyan
    title.TextSize = 13
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = main

    -- Close Button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 22, 0, 22)
    closeBtn.Position = UDim2.new(1, -26, 0, 6)
    closeBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Config.Theme.TextDim
    closeBtn.TextSize = 11
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.Parent = main
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(closeBtn.MouseButton1Click:Connect(function()
        if _G.ForestDropper_Cleanup then
            pcall(_G.ForestDropper_Cleanup)
            _G.ForestDropper_Cleanup = nil
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
            UI.setStatus("Dropper Enabled", Config.Theme.Green)
        else
            toggleBtn.Text = "OFF"
            toggleBtn.TextColor3 = Config.Theme.Red
            toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
            UI.setStatus("Dropper Disabled", Config.Theme.Red)
        end
    end))

    -- 1. Pen Location Card
    local penCard = Instance.new("Frame")
    penCard.Size = UDim2.new(1, -20, 0, 36)
    penCard.Position = UDim2.new(0, 10, 0, 32)
    penCard.BackgroundColor3 = Config.Theme.Card
    penCard.BorderSizePixel = 0
    penCard.Parent = main
    Instance.new("UICorner", penCard).CornerRadius = UDim.new(0, 6)

    local penLabel = Instance.new("TextLabel")
    penLabel.Size = UDim2.new(1, -95, 1, 0)
    penLabel.Position = UDim2.new(0, 8, 0, 0)
    penLabel.BackgroundTransparency = 1
    penLabel.Text = string.format("Pen: (%.1f, %.1f, %.1f)", State.SavedLocation.X, State.SavedLocation.Y, State.SavedLocation.Z)
    penLabel.TextColor3 = Config.Theme.TextPrimary
    penLabel.TextSize = 10
    penLabel.Font = Enum.Font.Gotham
    penLabel.TextXAlignment = Enum.TextXAlignment.Left
    penLabel.Parent = penCard
    UI.Elements.PenLabel = penLabel

    local setPenBtn = Instance.new("TextButton")
    setPenBtn.Size = UDim2.new(0, 80, 0, 24)
    setPenBtn.Position = UDim2.new(1, -85, 0.5, -12)
    setPenBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 180)
    setPenBtn.Text = "📍 Set Pen"
    setPenBtn.TextColor3 = Color3.new(1, 1, 1)
    setPenBtn.TextSize = 10
    setPenBtn.Font = Enum.Font.GothamBold
    setPenBtn.Parent = penCard
    Instance.new("UICorner", setPenBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(setPenBtn.MouseButton1Click:Connect(function()
        if RootPart and RootPart.Parent then
            State.SavedLocation = RootPart.Position
            penLabel.Text = string.format("Pen: (%.1f, %.1f, %.1f)", State.SavedLocation.X, State.SavedLocation.Y, State.SavedLocation.Z)
            UI.setStatus("Pen location updated!", Config.Theme.Green)
            Helpers.log(string.format("Pen location set to V3(%.1f, %.1f, %.1f)", State.SavedLocation.X, State.SavedLocation.Y, State.SavedLocation.Z), "LOCATION")
        end
    end))

    -- 2. Nest Location Card
    local nestCard = Instance.new("Frame")
    nestCard.Size = UDim2.new(1, -20, 0, 36)
    nestCard.Position = UDim2.new(0, 10, 0, 72)
    nestCard.BackgroundColor3 = Config.Theme.Card
    nestCard.BorderSizePixel = 0
    nestCard.Parent = main
    Instance.new("UICorner", nestCard).CornerRadius = UDim.new(0, 6)

    local nestLabel = Instance.new("TextLabel")
    nestLabel.Size = UDim2.new(1, -95, 1, 0)
    nestLabel.Position = UDim2.new(0, 8, 0, 0)
    nestLabel.BackgroundTransparency = 1
    nestLabel.Text = string.format("Nest: (%.1f, %.1f, %.1f)", State.StartLocation.X, State.StartLocation.Y, State.StartLocation.Z)
    nestLabel.TextColor3 = Config.Theme.TextPrimary
    nestLabel.TextSize = 10
    nestLabel.Font = Enum.Font.Gotham
    nestLabel.TextXAlignment = Enum.TextXAlignment.Left
    nestLabel.Parent = nestCard
    UI.Elements.NestLabel = nestLabel

    local setNestBtn = Instance.new("TextButton")
    setNestBtn.Size = UDim2.new(0, 80, 0, 24)
    setNestBtn.Position = UDim2.new(1, -85, 0.5, -12)
    setNestBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 80)
    setNestBtn.Text = "📍 Set Nest"
    setNestBtn.TextColor3 = Color3.new(1, 1, 1)
    setNestBtn.TextSize = 10
    setNestBtn.Font = Enum.Font.GothamBold
    setNestBtn.Parent = nestCard
    Instance.new("UICorner", setNestBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(setNestBtn.MouseButton1Click:Connect(function()
        if RootPart and RootPart.Parent then
            State.StartLocation = RootPart.Position
            nestLabel.Text = string.format("Nest: (%.1f, %.1f, %.1f)", State.StartLocation.X, State.StartLocation.Y, State.StartLocation.Z)
            UI.setStatus("Nest location updated!", Config.Theme.Green)
            Helpers.log(string.format("Nest location set to V3(%.1f, %.1f, %.1f)", State.StartLocation.X, State.StartLocation.Y, State.StartLocation.Z), "LOCATION")
        end
    end))

    -- Info: Status Banner
    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -20, 0, 32)
    status.Position = UDim2.new(0, 10, 0, 112)
    status.BackgroundColor3 = Config.Theme.Card
    status.Text = "Status: Ready · Auto-Loop is ON"
    status.TextColor3 = Config.Theme.Green
    status.TextSize = 11
    status.Font = Enum.Font.Gotham
    status.TextWrapped = true
    status.Parent = main
    Instance.new("UICorner", status).CornerRadius = UDim.new(0, 6)
    UI.Elements.Status = status

    -- Info: Stats Row
    local statsLabel = Instance.new("TextLabel")
    statsLabel.Size = UDim2.new(1, -20, 0, 18)
    statsLabel.Position = UDim2.new(0, 10, 0, 148)
    statsLabel.BackgroundTransparency = 1
    statsLabel.Text = "Deliveries: 0 | Auto-Loop: Active"
    statsLabel.TextColor3 = Config.Theme.TextDim
    statsLabel.TextSize = 10
    statsLabel.Font = Enum.Font.Gotham
    statsLabel.TextXAlignment = Enum.TextXAlignment.Left
    statsLabel.Parent = main
    UI.Elements.StatsLabel = statsLabel

    -- Bottom Buttons: Auto-Loop Toggle + Test Drop + Copy Log
    local loopBtn = Instance.new("TextButton")
    loopBtn.Size = UDim2.new(0, 96, 0, 26)
    loopBtn.Position = UDim2.new(0, 10, 0, 172)
    loopBtn.BackgroundColor3 = Color3.fromRGB(35, 75, 45)
    loopBtn.Text = "Loop: ON"
    loopBtn.TextColor3 = Config.Theme.Green
    loopBtn.TextSize = 10
    loopBtn.Font = Enum.Font.GothamBold
    loopBtn.Parent = main
    Instance.new("UICorner", loopBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(loopBtn.MouseButton1Click:Connect(function()
        State.AutoLoop = not State.AutoLoop
        if State.AutoLoop then
            loopBtn.Text = "Loop: ON"
            loopBtn.TextColor3 = Config.Theme.Green
            loopBtn.BackgroundColor3 = Color3.fromRGB(35, 75, 45)
            UI.setStatus("Auto-Loop Enabled. Starting cycle...", Config.Theme.Green)
            if not State.IsCarrying and not State.IsActive then
                Engine.returnToNestAndPickup()
            end
        else
            loopBtn.Text = "Loop: OFF"
            loopBtn.TextColor3 = Config.Theme.Red
            loopBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
            UI.setStatus("Auto-Loop Disabled.", Config.Theme.Red)
        end
    end))

    local testBtn = Instance.new("TextButton")
    testBtn.Size = UDim2.new(0, 96, 0, 26)
    testBtn.Position = UDim2.new(0, 112, 0, 172)
    testBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
    testBtn.Text = "⚡ Test Drop"
    testBtn.TextColor3 = Config.Theme.Cyan
    testBtn.TextSize = 10
    testBtn.Font = Enum.Font.GothamBold
    testBtn.Parent = main
    Instance.new("UICorner", testBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(testBtn.MouseButton1Click:Connect(function()
        local uid = State.CurrentEggUid or "TestEgg_Manual"
        Engine.executeDrop(uid)
    end))

    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(0, 96, 0, 26)
    copyBtn.Position = UDim2.new(0, 214, 0, 172)
    copyBtn.BackgroundColor3 = Color3.fromRGB(35, 55, 45)
    copyBtn.Text = "📋 Copy Log"
    copyBtn.TextColor3 = Config.Theme.Green
    copyBtn.TextSize = 10
    copyBtn.Font = Enum.Font.GothamBold
    copyBtn.Parent = main
    Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(copyBtn.MouseButton1Click:Connect(function()
        local okCopy, count = Helpers.copyLogs()
        if okCopy then
            copyBtn.Text = "✓ (" .. tostring(count) .. ")"
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

UI.setDeliveries = function(count)
    if UI.Elements.StatsLabel and UI.Elements.StatsLabel.Parent then
        local loopStatus = State.AutoLoop and "Active" or "Paused"
        UI.Elements.StatsLabel.Text = string.format("Deliveries: %d | Auto-Loop: %s", count, loopStatus)
    end
end

-- Full Cleanup Routine
local function fullCleanup()
    State.Enabled = false
    State.AutoLoop = false
    State.IsActive = false
    Helpers.disconnectAll()
    if UI.Elements.ScreenGui and UI.Elements.ScreenGui.Parent then
        pcall(function() UI.Elements.ScreenGui:Destroy() end)
    end
    print("[ForestDropper] Cleaned up cleanly.")
end

_G.ForestDropper_Cleanup = fullCleanup

-- Startup
UI.init()
Engine.initListeners()
Helpers.log("Forest Dropper loaded. Auto-Loop ready.", "SYSTEM")
